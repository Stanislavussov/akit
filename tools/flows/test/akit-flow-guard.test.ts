// akit-flow-guard.ts: its tool_call handler called directly with fake events.
import assert from "node:assert/strict";
import { mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, beforeEach, test } from "node:test";
import akitFlowGuard, { type GuardRules, guardHandler } from "../../../AKitCore/Sources/AKitRender/Resources/flows/akit-flow-guard.ts";
import { redact } from "../../../AKitCore/Sources/AKitRender/Resources/flows/flow-core.ts";
import type { ExtensionAPI } from "../../../AKitCore/Sources/AKitRender/Resources/flows/pi-adapter.ts";

let root: string, events: string;

beforeEach(() => {
	root = realpathSync(mkdtempSync(join(tmpdir(), "akit-flow-guard-")));
	mkdirSync(join(root, "worktree"));
	events = join(root, "events.jsonl");
});

afterEach(() => rmSync(root, { recursive: true, force: true }));

function rules(extra: Partial<GuardRules> = {}): GuardRules {
	return { run: "r1", step: "tests", attempt: 2, tools: ["read", "edit", "write", "bash"], paths: [], bash: true, root: join(root, "worktree"), events, ...extra };
}

function deviations(): Record<string, unknown>[] {
	try {
		return readFileSync(events, "utf8").trim().split("\n").filter(Boolean).map((l) => JSON.parse(l));
	} catch {
		return [];
	}
}

function blocked(r: GuardRules, toolName: string, input: Record<string, unknown>, rule: string) {
	const answer = guardHandler(r)({ toolName, input });
	assert.equal(answer?.block, true, `${toolName} is blocked`);
	assert.match(answer?.reason ?? "", /AKit flow guard/);
	const last = deviations().at(-1);
	assert.equal(last?.type, "deviation");
	assert.equal(last?.rule, rule);
	assert.equal(last?.tool, toolName);
	assert.equal(last?.step, "tests");
	assert.equal(last?.attempt, 2);
	assert.equal(last?.action, "blocked");
	return last;
}

test("a built-in tool not in the step's list is blocked with a deviation", () => {
	blocked(rules({ tools: ["read"] }), "write", { path: "a.ts", content: "x" }, "tool-not-allowed");
});

test("an mcp__ tool not in the list is blocked", () => {
	const line = blocked(rules(), "mcp__gitlab__create_mr", { title: "t", token: "secret-value" }, "tool-not-allowed");
	assert.equal(line?.input, "title, token", "only the input's keys, never its values");
});

test("subagent tools are blocked even when listed", () => {
	for (const tool of ["subagent", "subagent_wait", "contact_supervisor", "akit_flow"]) blocked(rules({ tools: [tool, "read"] }), tool, {}, "subagent");
});

test("edit outside the step's paths, or outside the worktree, is blocked", () => {
	const r = rules({ paths: ["tests/**", "README.md"], bash: false });
	blocked(r, "edit", { path: "src/main.ts", edits: [] }, "path");
	blocked(r, "write", { path: join(root, "elsewhere.txt"), content: "x" }, "path");
	blocked(rules(), "write", { path: "../outside.txt", content: "x" }, "path");
	assert.equal(guardHandler(r)({ toolName: "edit", input: { path: "tests/unit/a.test.ts", edits: [] } }), undefined);
	assert.equal(guardHandler(r)({ toolName: "write", input: { path: join(root, "worktree", "README.md"), content: "x" } }), undefined);
});

test("bash in a write-restricted step is blocked, its command redacted in the log", () => {
	const line = blocked(rules({ paths: ["tests/**"], bash: false }), "bash", { command: "GITLAB_TOKEN=xxxx curl x" }, "bash");
	assert.equal(line?.input, "GITLAB_TOKEN=*** curl x");
});

test("allowed tools and flow_handoff pass, with no deviation", () => {
	const h = guardHandler(rules({ tools: ["read", "bash"] }));
	assert.equal(h({ toolName: "read", input: { path: "src/a.ts" } }), undefined);
	assert.equal(h({ toolName: "bash", input: { command: "ls" } }), undefined);
	assert.equal(h({ toolName: "flow_handoff", input: { outcome: "done" } }), undefined);
	assert.deepEqual(deviations(), []);
});

test("the extension reads AKIT_FLOW_GUARD; unreadable rules block all but flow_handoff", () => {
	const handlers: ((e: { toolName: string; input: Record<string, unknown> }) => unknown)[] = [];
	const fake = { on: (_: string, h: (e: { toolName: string; input: Record<string, unknown> }) => unknown) => handlers.push(h) } as unknown as ExtensionAPI;
	const saved = process.env.AKIT_FLOW_GUARD;
	try {
		const file = join(root, "rules.json");
		writeFileSync(file, JSON.stringify(rules({ tools: ["read"] })));
		process.env.AKIT_FLOW_GUARD = file;
		akitFlowGuard(fake);
		assert.equal((handlers[0]({ toolName: "bash", input: {} }) as { block?: boolean })?.block, true);
		process.env.AKIT_FLOW_GUARD = join(root, "missing.json");
		akitFlowGuard(fake);
		assert.equal((handlers[1]({ toolName: "read", input: {} }) as { block?: boolean })?.block, true);
		assert.equal(handlers[1]({ toolName: "flow_handoff", input: {} }), undefined);
	} finally {
		if (saved === undefined) delete process.env.AKIT_FLOW_GUARD;
		else process.env.AKIT_FLOW_GUARD = saved;
	}
});

test("redact hides env-like secrets and bearer tokens", () => {
	assert.equal(redact("API_KEY=abc OTHER=1 Authorization: Bearer xyz.123"), "API_KEY=*** OTHER=1 Authorization:*** ***");
	assert.equal(redact("ghp_abcdefghijklmnop1234 and password: \"a b\""), "*** and password:***");
});

test("a symlink inside the worktree that points outside does not let a write escape", () => {
	const outside = join(root, "outside");
	mkdirSync(outside);
	symlinkSync(outside, join(root, "worktree", "link"));
	writeFileSync(join(outside, "f.txt"), "x");
	symlinkSync(join(outside, "f.txt"), join(root, "worktree", "file-link"));
	blocked(rules(), "write", { path: "link/evil.ts", content: "x" }, "path");
	blocked(rules(), "write", { path: "link/deep/new/evil.ts", content: "x" }, "path");
	blocked(rules(), "edit", { path: "file-link", edits: [] }, "path");
	mkdirSync(join(root, "worktree", "src"));
	assert.equal(guardHandler(rules())({ toolName: "write", input: { path: "src/new/deep/a.ts", content: "x" } }), undefined);
	assert.equal(guardHandler(rules())({ toolName: "write", input: { path: "..env.sample", content: "x" } }), undefined, "a name starting with .. stays inside");
	blocked(rules(), "write", { path: "../escape.ts", content: "x" }, "path");
});

test("edit and write into the run records are always blocked", () => {
	const records = join(root, "worktree", ".pi", "akit-flow");
	mkdirSync(join(records, "runs", "r1"), { recursive: true });
	blocked(rules({ records }), "write", { path: ".pi/akit-flow/runs/r1/events.jsonl", content: "x" }, "path");
	assert.equal(guardHandler(rules({ records }))({ toolName: "write", input: { path: ".pi/other.json", content: "x" } }), undefined);
});

test("a flow child (AKIT_FLOW_HANDOFF set) without AKIT_FLOW_GUARD blocks all but flow_handoff", () => {
	const handlers: ((e: { toolName: string; input: Record<string, unknown> }) => unknown)[] = [];
	const fake = { on: (_: string, h: (e: { toolName: string; input: Record<string, unknown> }) => unknown) => handlers.push(h) } as unknown as ExtensionAPI;
	const saved = { g: process.env.AKIT_FLOW_GUARD, h: process.env.AKIT_FLOW_HANDOFF };
	try {
		delete process.env.AKIT_FLOW_GUARD;
		delete process.env.AKIT_FLOW_HANDOFF;
		akitFlowGuard(fake);
		assert.equal(handlers.length, 0, "plain Pi gets no guard");
		process.env.AKIT_FLOW_HANDOFF = join(root, "part.json");
		akitFlowGuard(fake);
		assert.equal((handlers[0]({ toolName: "read", input: {} }) as { block?: boolean })?.block, true);
		assert.equal(handlers[0]({ toolName: "flow_handoff", input: {} }), undefined);
	} finally {
		if (saved.g === undefined) delete process.env.AKIT_FLOW_GUARD;
		else process.env.AKIT_FLOW_GUARD = saved.g;
		if (saved.h === undefined) delete process.env.AKIT_FLOW_HANDOFF;
		else process.env.AKIT_FLOW_HANDOFF = saved.h;
	}
});

test("redact hides GitHub, AWS, URL and --password secrets", () => {
	assert.equal(redact("ghs_abcdefghijklmnop1234"), "***");
	assert.equal(redact("ghu_abcdefghijklmnop1234"), "***");
	assert.equal(redact("github_pat_11ABCDEFG0123456789_abcdefghijklmnop"), "***");
	assert.equal(redact("aws AKIAIOSFODNN7EXAMPLE x"), "aws *** x");
	assert.equal(redact("git clone https://user:hunter2@example.com/r.git"), "git clone https://***@example.com/r.git");
	assert.equal(redact("mysql --password hunter2 db"), "mysql --password *** db");
	assert.equal(redact("mysql -p hunter2 db"), "mysql -p *** db");
	assert.equal(redact("ls -la src"), "ls -la src");
});
