// akit-flow.ts against a fake `pi` on PATH, in a temporary fake HOME and a temporary git project.
import assert from "node:assert/strict";
import { execFileSync, spawn, spawnSync } from "node:child_process";
import { cpSync, existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, beforeEach, test } from "node:test";
import akitFlow, { flowCommand, startTool } from "../../../AKitCore/Sources/AKitRender/Resources/flows/akit-flow.ts";
import { checksGreen } from "../../../AKitCore/Sources/AKitRender/Resources/flows/flow-record.ts";
import type { ExtensionCommandContext } from "../../../AKitCore/Sources/AKitRender/Resources/flows/pi-adapter.ts";

const repo = join(import.meta.dirname, "..", "..", "..");
let root: string, project: string, piDir: string, messages: { text: string; level?: string }[];
let widgets: { lines?: string[]; placement?: string }[] = [];
const saved = { HOME: process.env.HOME, PATH: process.env.PATH };
// Commits in the fake project and the run's worktree need a name; the fake HOME has no git config.
for (const key of ["GIT_AUTHOR_NAME", "GIT_COMMITTER_NAME"]) process.env[key] = "Flow Test";
for (const key of ["GIT_AUTHOR_EMAIL", "GIT_COMMITTER_EMAIL"]) process.env[key] = "flow@example.com";

function ctx(): ExtensionCommandContext {
	return {
		cwd: project, hasUI: false, signal: undefined, waitForIdle: async () => {},
		ui: {
			notify: (text: string, level?: string) => messages.push({ text, level }),
			setStatus: () => {}, setWidget: (_key: string, lines?: string[], options?: { placement?: string }) => widgets.push({ lines, placement: options?.placement }),
			confirm: async () => false, select: async () => undefined,
			input: async () => undefined, editor: async () => undefined,
		},
	} as unknown as ExtensionCommandContext;
}

beforeEach(() => {
	root = realpathSync(mkdtempSync(join(tmpdir(), "akit-flow-test-")));
	const home = join(root, "home");
	project = join(root, "project");
	piDir = join(root, "pi");
	const bin = join(root, "bin");
	for (const d of [home, project, piDir, bin]) mkdirSync(d, { recursive: true });
	cpSync(join(import.meta.dirname, "fake-pi.mjs"), join(bin, "pi"));
	execFileSync("chmod", ["+x", join(bin, "pi")]);
	execFileSync("git", ["init", "-q", "-b", "main"], { cwd: project });
	execFileSync("git", ["commit", "-q", "--allow-empty", "-m", "init"], { cwd: project });
	mkdirSync(join(project, ".pi", "skills", "tdd"), { recursive: true });
	writeFileSync(join(project, ".pi", "skills", "tdd", "SKILL.md"), "---\nname: tdd\n---\n");
	process.env.HOME = home;
	process.env.PATH = `${bin}:${saved.PATH}`;
	process.env.FAKE_PI_DIR = piDir;
	messages = [];
	widgets = [];
	pi({});
});

afterEach(() => {
	process.env.HOME = saved.HOME;
	process.env.PATH = saved.PATH;
	rmSync(root, { recursive: true, force: true });
});

function pi(config: Record<string, unknown>) {
	writeFileSync(join(piDir, "config.json"), JSON.stringify(config));
}

function flow(steps: Record<string, unknown>[], extra: Record<string, unknown> = {}) {
	mkdirSync(join(project, ".pi", "flows"), { recursive: true });
	// JSON is YAML; the runner reads it without the yaml package.
	writeFileSync(join(project, ".pi", "flows", "feature.yaml"), JSON.stringify({ "akit-flow-format": 1, name: "feature", minPi: "1.0.4", steps, ...extra }));
}

const fourSteps = (implementLoops = 3) => [
	{ id: "plan", agent: "planner", model: "m/a", skills: ["tdd"] },
	{ id: "implement", agent: "implementer", model: "m/a", thinking: "high", maxLoops: implementLoops },
	{ id: "checks", agent: "checker", model: "m/a", tools: ["read", "bash"], routes: { "failed:*": "implement" } },
	{ id: "review", agent: "reviewer", model: "m/b" },
];

function calls(): { step: string; args: string[]; cwd: string; stdinNull: boolean }[] {
	const path = join(piDir, "calls.jsonl");
	return existsSync(path) ? readFileSync(path, "utf8").trim().split("\n").map((l) => JSON.parse(l)) : [];
}

function onlyRun(): string {
	const runs = join(project, ".pi", "akit-flow", "runs");
	const names = readdirSync(runs);
	assert.equal(names.length, 1);
	assert.match(names[0], /^\d{8}-\d{4}-[0-9a-f]{4}$/);
	return join(runs, names[0]);
}

function events(run: string): Record<string, unknown>[] {
	return readFileSync(join(run, "events.jsonl"), "utf8").trim().split("\n").map((l) => JSON.parse(l));
}

test("the extension registers /flow and the tool akit_flow", () => {
	const names: string[] = [];
	const tools: { name: string; parameters: { required: string[] } }[] = [];
	const shortcuts: string[] = [];
	akitFlow({ registerCommand: (name: string) => names.push(name), registerTool: (t: never) => tools.push(t), on: () => () => {},
		registerShortcut: (key: string) => shortcuts.push(key) } as never);
	assert.deepEqual(names, ["flow"]);
	assert.deepEqual(shortcuts, ["alt+1", "alt+2", "alt+3", "alt+4", "alt+5", "alt+6", "alt+7", "alt+8", "alt+9"]);
	assert.deepEqual(tools.map((t) => t.name), ["akit_flow"]);
	assert.deepEqual(tools[0].parameters.required, ["task"]);
});

test("a 4-step flow runs in order and is recorded", async () => {
	flow(fourSteps());
	await flowCommand("feature add CSV export", ctx());
	assert.deepEqual(calls().map((c) => c.step), ["plan", "implement", "checks", "review"]);
	const run = onlyRun();
	const first = calls()[0];
	const a = first.args;
	assert.deepEqual(a.slice(0, 5), ["--mode", "json", "--session-dir", join(run, "sessions"), "-ns"]);
	assert.equal(a[a.indexOf("--skill") + 1], join(project, ".pi", "skills", "tdd"));
	assert.ok(a.includes("-ne") && a.includes("--model") && !a.includes("-p"));
	assert.match(a[a.length - 1], /Task: add CSV export/);
	assert.ok(first.stdinNull, "stdin is /dev/null");
	const impl = calls()[1].args;
	assert.equal(impl[impl.indexOf("--thinking") + 1], "high");
	const chk = calls()[2].args;
	assert.equal(chk[chk.indexOf("-t") + 1], "read,bash,flow_handoff");
	const ev = events(run);
	assert.ok(ev.every((e) => e.schema === "akit-flow-event/1"));
	assert.deepEqual(ev.map((e) => e.type), ["run-start", "step-start", "step-end", "step-start", "step-end", "step-start", "step-end", "step-start", "step-end", "run-end"]);
	assert.deepEqual(ev[2].tokens, { input: 100, output: 20, cache_read: 5, cost: 0.01 });
	assert.equal(ev[2].unknownEvents, 1);
	assert.equal(ev.at(-1)?.stop, "done");
	const cache = JSON.parse(readFileSync(join(run, "run.json"), "utf8"));
	assert.equal(cache.schema, "akit-flow-run/1");
	assert.equal(cache.pi, "1.0.4");
	assert.equal(cache.piFeatures["--session-dir"], true);
	assert.equal(cache.status, "done");
	assert.ok(!existsSync(join(run, "lock")), "lock released");
	assert.ok(!readdirSync(run).some((n) => n.includes(".tmp-")), "no temp file left");
	const handoffs = readdirSync(join(run, "handoffs")).sort();
	assert.deepEqual(handoffs, ["01-plan-a1-sess-plan-1.json", "02-implement-a1-sess-implement-1.json", "03-checks-a1-sess-checks-1.json", "04-review-a1-sess-review-1.json"]);
	const h = JSON.parse(readFileSync(join(run, "handoffs", handoffs[1]), "utf8"));
	assert.equal(h.schema, "akit-flow-handoff/1");
	assert.equal(h.run, run.split("/").pop());
	assert.equal(h.flow, "feature");
	assert.deepEqual(h.step, { index: 2, id: "implement", attempt: 1 });
	assert.deepEqual(h.next, { step: "checks" });
	assert.deepEqual(h.from, { outcome: "done", reason: "" });
	assert.equal(h.goal, "implement goal");
	assert.deepEqual(h.done, ["did implement"]);
	assert.deepEqual(h.files, [{ path: "src/implement.ts", change: "added" }]);
	assert.equal(h.deviations, 0);
	// The handoff names the child's session, and that session file is in <run>/sessions.
	assert.equal(h.session, "sess-implement-1");
	assert.match(h.session_file, /^sessions\/.*sess-implement-1\.jsonl$/);
	assert.ok(existsSync(join(run, h.session_file)));
	assert.equal(JSON.parse(readFileSync(join(run, h.session_file), "utf8")).id, h.session);
	assert.ok(!readdirSync(join(run, "handoffs")).some((n) => n.endsWith(".part")), "no handoff part left");
	assert.ok(calls()[0].args.some((a) => a.endsWith("akit-flow-handoff.ts")), "the child loads the handoff tool");
	assert.match(calls()[2].args.at(-1) ?? "", /Handoff from the step "implement"/);
	assert.match(calls()[2].args.at(-1) ?? "", /"goal": "implement goal"/);
	assert.match(messages.at(-1)?.text ?? "", /done/);
});

test("a failed check routes back to implement", async () => {
	flow(fourSteps());
	pi({ outcomes: { checks: ["failed", "done"] } });
	await flowCommand("feature fix it", ctx());
	assert.deepEqual(calls().map((c) => c.step), ["plan", "implement", "checks", "implement", "checks", "review"]);
	const ev = events(onlyRun());
	const starts = ev.filter((e) => e.type === "step-start" && e.step === "implement").map((e) => e.attempt);
	assert.deepEqual(starts, [1, 2]);
	assert.equal(ev.at(-1)?.stop, "done");
});

test("the visit cap stops the run", async () => {
	flow(fourSteps(2));
	pi({ outcomes: { checks: ["failed"] } });
	await flowCommand("feature fix it", ctx());
	assert.deepEqual(calls().map((c) => c.step), ["plan", "implement", "checks", "implement", "checks"]);
	const end = events(onlyRun()).at(-1);
	assert.equal(end?.type, "run-end");
	assert.equal(end?.stop, "visit-cap");
	assert.equal(end?.step, "implement");
	assert.match(messages.at(-1)?.text ?? "", /max loops/);
});

test("no route for a failed step stops loudly with a deviation", async () => {
	flow(fourSteps());
	pi({ outcomes: { plan: ["blocked"] } });
	await flowCommand("feature x", ctx());
	const ev = events(onlyRun());
	assert.ok(ev.some((e) => e.type === "deviation" && e.rule === "no-route"));
	assert.equal(ev.at(-1)?.stop, "no-route");
});

test("resume refuses while the lock's pid is alive, and goes on after it", async () => {
	flow(fourSteps());
	pi({ outcomes: { plan: ["blocked"] } });
	await flowCommand("feature x", ctx());
	// A run that crashed in "implement": no run-end, a lock held by a live process.
	const run = onlyRun();
	const lines = readFileSync(join(run, "events.jsonl"), "utf8").trim().split("\n").filter((l) => !/"run-end"|"deviation"/.test(l));
	lines[lines.length - 1] = lines[lines.length - 1].replace(/"outcome":"blocked"/, '"outcome":"done"');
	lines.push(JSON.stringify({ schema: "akit-flow-event/1", type: "step-start", step: "implement", attempt: 1 }));
	writeFileSync(join(run, "events.jsonl"), `${lines.join("\n")}\n`);
	const holder = spawn("sleep", ["30"]);
	try {
		writeFileSync(join(run, "lock"), `${holder.pid}\n`);
		const before = calls().length;
		messages = [];
		await flowCommand("resume", ctx());
		assert.match(messages.at(-1)?.text ?? "", new RegExp(`running in process ${holder.pid}; resume refused`));
		assert.equal(calls().length, before, "no child started");
	} finally {
		holder.kill();
	}
	await new Promise((r) => holder.on("exit", r));
	pi({});
	await flowCommand("resume", ctx());
	assert.deepEqual(calls().slice(1).map((c) => c.step), ["implement", "checks", "review"]);
	const ev = events(run);
	assert.deepEqual(ev.filter((e) => e.type === "step-start" && e.step === "implement").map((e) => e.attempt), [1, 2]);
	assert.equal(ev.at(-1)?.stop, "done");
});

test("an old Pi gets the version and missing-feature message", async () => {
	flow(fourSteps());
	pi({ version: "0.9.0", missing: ["--session-dir", "--skill"] });
	await flowCommand("feature x", ctx());
	const text = messages.at(-1)?.text ?? "";
	assert.match(text, /Pi 0\.9\.0 can't run the flow feature/);
	assert.match(text, /needs Pi 1\.0\.4 or newer/);
	assert.match(text, /Missing: --session-dir, --skill/);
	assert.equal(calls().length, 0);
	assert.ok(!existsSync(join(project, ".pi", "akit-flow")), "no run folder");
});

test("a Pi newer than testedPi runs with one warning", async () => {
	flow(fourSteps());
	pi({ version: "9.0.0" });
	await flowCommand("feature x", ctx());
	await flowCommand("feature y", ctx());
	assert.equal(messages.filter((m) => /newer than 1\.0\.4/.test(m.text)).length, 1);
	assert.equal(calls().length, 8);
});

test("a flow file newer than the runner refuses with run Apply", async () => {
	flow(fourSteps(), { "akit-flow-format": 2 });
	await flowCommand("feature x", ctx());
	assert.match(messages.at(-1)?.text ?? "", /run Apply in AKit/);
	assert.equal(calls().length, 0);
});

test("flows come from ~/.pi/agent/flows when the project has none", async () => {
	const folder = join(process.env.HOME ?? "", ".pi", "agent", "flows");
	mkdirSync(folder, { recursive: true });
	writeFileSync(join(folder, "quick.yaml"), JSON.stringify({ "akit-flow-format": 1, name: "quick", steps: [{ id: "do", agent: "a", model: "m" }] }));
	await flowCommand("just do it", ctx());
	assert.deepEqual(calls().map((c) => c.step), ["do"]);
});

test("make test-flows fails clearly without node", () => {
	const r = spawnSync("make", ["-s", "-C", repo, "check-node"], { env: { PATH: "/usr/bin:/bin", HOME: process.env.HOME }, encoding: "utf8" });
	assert.notEqual(r.status, 0);
	assert.match(r.stdout + r.stderr, /Node\.js .* not found/);
});

function deviations(run: string): Record<string, unknown>[] {
	return events(run).filter((e) => e.type === "deviation");
}

test("a step without flow_handoff reruns once with a deviation", async () => {
	flow(fourSteps());
	pi({ handoff: { plan: ["none", "tool"] } });
	await flowCommand("feature x", ctx());
	assert.deepEqual(calls().map((c) => c.step), ["plan", "plan", "implement", "checks", "review"]);
	const run = onlyRun();
	assert.deepEqual(deviations(run).map((d) => [d.rule, d.action]), [["handoff-missing", "rerun"]]);
	const h = JSON.parse(readFileSync(join(run, "handoffs", "01-plan-a1-sess-plan-2.json"), "utf8"));
	assert.equal(h.deviations, 1);
	assert.equal(events(run).at(-1)?.stop, "done");
});

test("a step without flow_handoff twice stops the run", async () => {
	flow(fourSteps());
	pi({ handoff: { implement: ["none"] } });
	await flowCommand("feature x", ctx());
	assert.deepEqual(calls().map((c) => c.step), ["plan", "implement", "implement"]);
	const run = onlyRun();
	assert.deepEqual(deviations(run).map((d) => [d.rule, d.action]), [["handoff-missing", "rerun"], ["handoff-missing", "stopped"]]);
	const end = events(run).at(-1);
	assert.equal(end?.stop, "no-handoff");
	assert.equal(end?.step, "implement");
	assert.match(messages.at(-1)?.text ?? "", /without flow_handoff/);
});

test("an outcome line without flow_handoff is the fallback, logged", async () => {
	flow(fourSteps());
	pi({ handoff: { checks: ["line"] }, outcomes: { checks: ["failed:tests", "done"] } });
	await flowCommand("feature x", ctx());
	assert.deepEqual(calls().map((c) => c.step), ["plan", "implement", "checks", "implement", "checks", "review"]);
	const fallbacks = deviations(onlyRun()).filter((d) => d.rule === "handoff-fallback");
	assert.deepEqual(fallbacks.map((d) => d.detail), ["outcome: failed:tests", "outcome: done"]);
});

/** A check script for the project: exits 1 with a failing line the first `fails` times, then 0. */
function checkScript(fails: number) {
	writeFileSync(join(project, "check.mjs"), `import { existsSync, readFileSync, writeFileSync } from "node:fs";
const n = existsSync("check-count") ? Number(readFileSync("check-count", "utf8")) : 0;
writeFileSync("check-count", String(n + 1));
for (let i = 1; i <= 50; i++) console.log("line " + i);
if (n < ${fails}) { console.error("1 test failed: export writes no header"); process.exit(1); }
console.log("all tests passed");
`);
	execFileSync("git", ["add", "check.mjs"], { cwd: project });
	execFileSync("git", ["commit", "-q", "-m", "check script"], { cwd: project });
}

const checkedSteps = () => [
	{ id: "plan", agent: "planner", model: "m/a" },
	{ id: "implement", agent: "implementer", model: "m/a" },
	{ id: "checks", agent: "checker", model: "m/a", checks: ["node check.mjs"], routes: { "failed:*": "implement" } },
];

test("the runner runs the checks; red routes back with the evidence", async () => {
	flow(checkedSteps());
	checkScript(1);
	await flowCommand("feature x", ctx());
	assert.deepEqual(calls().map((c) => c.step), ["plan", "implement", "checks", "implement", "checks"]);
	const run = onlyRun();
	const ends = events(run).filter((e) => e.type === "step-end" && e.step === "checks");
	// The model said done both times; the first time the checks were red.
	assert.deepEqual(ends.map((e) => [e.outcome, e.reason]), [["failed", "checks"], ["done", ""]]);
	assert.deepEqual(deviations(run).map((d) => d.rule), ["check-failed"]);
	const second = calls()[3].args.at(-1) ?? "";
	assert.match(second, /The check `node check\.mjs` exited 1/);
	assert.match(second, /1 test failed: export writes no header/);
	// One evidence file per attempt: the rerun does not overwrite attempt 1.
	const first = JSON.parse(readFileSync(join(run, "evidence", "03-checks-a1-checks.json"), "utf8"));
	assert.deepEqual(first.step, { id: "checks", attempt: 1 });
	assert.notEqual(first.checks[0].exit, 0);
	const evidence = JSON.parse(readFileSync(join(run, "evidence", "03-checks-a2-checks.json"), "utf8"));
	assert.equal(evidence.schema, "akit-flow-evidence/1");
	assert.deepEqual(evidence.step, { id: "checks", attempt: 2 });
	assert.equal(evidence.checks[0].command, "node check.mjs");
	assert.equal(evidence.checks[0].exit, 0);
	assert.equal(evidence.checks[0].tail.length, 40);
	assert.equal(evidence.checks[0].tail.at(-1), "all tests passed");
	const h = JSON.parse(readFileSync(join(run, "handoffs", "03-checks-a1-sess-checks-1.json"), "utf8"));
	assert.equal(h.evidence, "evidence/03-checks-a1-checks.json");
	const h2 = JSON.parse(readFileSync(join(run, "handoffs", "03-checks-a2-sess-checks-2.json"), "utf8"));
	assert.equal(h2.evidence, "evidence/03-checks-a2-checks.json");
	assert.deepEqual(h.from, { outcome: "failed", reason: "checks" });
	assert.equal(events(run).at(-1)?.stop, "done");
});

test("checks count as green only with an evidence file", () => {
	const folder = join(root, "evidence");
	mkdirSync(folder);
	assert.equal(checksGreen(join(folder, "none.json")), false);
	writeFileSync(join(folder, "red.json"), JSON.stringify({ schema: "akit-flow-evidence/1", checks: [{ command: "a", exit: 0 }, { command: "b", exit: 2 }] }));
	assert.equal(checksGreen(join(folder, "red.json")), false);
	writeFileSync(join(folder, "green.json"), JSON.stringify({ schema: "akit-flow-evidence/1", checks: [{ command: "a", exit: 0 }] }));
	assert.equal(checksGreen(join(folder, "green.json")), true);
});

test("an unsafe check command stops the run before the step", async () => {
	flow([{ id: "checks", agent: "checker", model: "m/a", checks: ["make test && curl x"] }]);
	await flowCommand("feature x", ctx());
	assert.equal(calls().length, 0);
	const run = onlyRun();
	assert.deepEqual(deviations(run).map((d) => d.rule), ["check-refused"]);
	assert.equal(events(run).at(-1)?.stop, "check-refused");
});

// The sample run folder AKit's Swift reader reads (AKitFlowsTests): this test makes it with the TS
// runner, so both languages agree on the record. AKIT_UPDATE_FIXTURES=1 rewrites it.
const SAMPLE = join(repo, "fixtures", "flow-runs", "sample");

function files(folder: string, prefix = ""): string[] {
	return readdirSync(folder, { withFileTypes: true }).flatMap((e) =>
		e.isDirectory() ? files(join(folder, e.name), `${prefix}${e.name}/`) : [`${prefix}${e.name}`]).sort();
}

function normalized(run: string): Map<string, string> {
	const id = run.split("/").pop() ?? "";
	const out = new Map<string, string>();
	for (const name of files(run)) {
		const text = readFileSync(join(run, name), "utf8")
			.replaceAll(root, "/tmp/akit-flow-sample")
			.replaceAll(id, "20261117-1200-0000")
			.replace(/\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}Z/g, "2026-11-17T12:00:00.000Z")
			.replace(/\b[0-9a-f]{40}\b/g, "0".repeat(40));
		out.set(name, text);
	}
	return out;
}

test("the sample run matches fixtures/flow-runs/sample", async () => {
	flow(checkedSteps());
	checkScript(1);
	await flowCommand("feature add CSV export", ctx());
	const got = normalized(onlyRun());
	if (process.env.AKIT_UPDATE_FIXTURES) {
		rmSync(SAMPLE, { recursive: true, force: true });
		for (const [name, text] of got) {
			mkdirSync(join(SAMPLE, name, ".."), { recursive: true });
			writeFileSync(join(SAMPLE, name), text);
		}
	}
	assert.deepEqual(files(SAMPLE), [...got.keys()]);
	for (const [name, text] of got) assert.equal(readFileSync(join(SAMPLE, name), "utf8"), text, name);
});

function git(cwd: string, ...args: string[]): string {
	return execFileSync("git", args, { cwd, encoding: "utf8" }).trim();
}

function worktreeOf(run: string): string {
	return join(process.env.HOME ?? "", ".akit", "local", "flows", "runs", run.split("/").pop() ?? "", "worktree");
}

/** Flow-* trailers of the run branch's commits, oldest first. */
function trailers(worktree: string): string[] {
	return git(worktree, "log", "--reverse", "--format=%(trailers:key=Flow-Step,valueonly,separator=)/%(trailers:key=Flow-Attempt,valueonly,separator=)/%(trailers:key=Flow-Gate,valueonly,separator=)", "main..HEAD")
		.split("\n").filter(Boolean);
}

const twoSteps = () => [
	{ id: "plan", agent: "planner", model: "m/a" },
	{ id: "implement", agent: "implementer", model: "m/a" },
	{ id: "review", agent: "reviewer", model: "m/b" },
];

test("a run works in its own worktree outside the project and commits each step", async () => {
	flow(twoSteps());
	pi({ writes: { implement: { "src/export.ts": "export {}\n" } } });
	await flowCommand("feature add CSV export", ctx());
	const run = onlyRun();
	const id = run.split("/").pop() ?? "";
	const tree = worktreeOf(run);
	assert.ok(!tree.startsWith(project + "/"), "worktree is outside the project tree");
	assert.ok(calls().every((c) => realpathSync(c.cwd) === tree), "children run in the worktree");
	assert.equal(git(tree, "branch", "--show-current"), `akit-flow/${id}`);
	assert.deepEqual(trailers(tree), ["plan/1/", "implement/1/", "review/1/"]);
	const body = git(tree, "log", "-1", "--format=%B", "HEAD~1");
	assert.match(body, /^implement goal\n\nFlow-Run: \d{8}-\d{4}-[0-9a-f]{4}\nFlow-Step: implement\nFlow-Attempt: 1$/);
	assert.equal(git(tree, "show", "--name-only", "--format=", "HEAD~1"), "src/export.ts");
	assert.ok(!existsSync(join(project, "src")), "the main checkout is untouched");
	assert.ok(existsSync(join(project, ".pi", "akit-flow", "runs", id, "events.jsonl")), "records live in the main checkout");
	const ends = events(run).filter((e) => e.type === "step-end");
	assert.equal(ends[1].commit, git(tree, "rev-parse", "HEAD~1"));
	const cache = JSON.parse(readFileSync(join(run, "run.json"), "utf8"));
	assert.equal(cache.worktree, tree);
	assert.equal(cache.branch, `akit-flow/${id}`);
});

test("a project without a commit refuses to start", async () => {
	rmSync(join(project, ".git"), { recursive: true });
	execFileSync("git", ["init", "-q"], { cwd: project });
	flow(twoSteps());
	await flowCommand("feature x", ctx());
	assert.match(messages.at(-1)?.text ?? "", /no commit yet/);
	assert.equal(calls().length, 0);
});

/** Events without the lines after `keep` (the index of the last kept line): a crash at that point. */
function cutEvents(run: string, keep: number) {
	const lines = readFileSync(join(run, "events.jsonl"), "utf8").trim().split("\n").slice(0, keep + 1);
	writeFileSync(join(run, "events.jsonl"), `${lines.join("\n")}\n`);
}

test("killed mid-step: resume resets to the last step commit and reruns the step, attempt + 1", async () => {
	flow(twoSteps());
	pi({ writes: { implement: { "src/half.ts": "half done\n" } }, outcomes: { implement: ["blocked"] } });
	await flowCommand("feature x", ctx());
	const run = onlyRun();
	const tree = worktreeOf(run);
	// The crash: implement started and wrote a file, then the extension died (no commit, no step-end).
	git(tree, "reset", "-q", "--hard", "HEAD~1");
	mkdirSync(join(tree, "src"));
	writeFileSync(join(tree, "src", "half.ts"), "half done\n");
	cutEvents(run, events(run).findIndex((e) => e.type === "step-start" && e.step === "implement"));
	rmSync(join(run, "run.json"));
	pi({});
	const asked: string[] = [];
	const c = ctx();
	c.ui.confirm = async (title: string) => (asked.push(title), true);
	await flowCommand("resume", c);
	assert.deepEqual(asked, ["Reset the flow's worktree?"]);
	assert.deepEqual(calls().map((x) => x.step), ["plan", "implement", "implement", "review"]);
	const starts = events(run).filter((e) => e.type === "step-start" && e.step === "implement").map((e) => e.attempt);
	assert.deepEqual(starts, [1, 2]);
	assert.ok(!existsSync(join(tree, "src", "half.ts")), "the half-done file was reset");
	assert.deepEqual(trailers(tree), ["plan/1/", "implement/2/", "review/1/"]);
	// run.json was deleted; resume rebuilt it from the events.
	const cache = JSON.parse(readFileSync(join(run, "run.json"), "utf8"));
	assert.equal(cache.status, "done");
	assert.equal(cache.flow, "feature");
	assert.equal(cache.worktree, tree);
	assert.deepEqual(cache.state.visits, { plan: 1, implement: 2, review: 1 });
	// The rerun step got the last finished step's handoff.
	assert.match(calls()[2].args.at(-1) ?? "", /Handoff from the step "plan"/);
});

test("killed after the step commit, before step-end: resume does not rerun the step", async () => {
	flow(twoSteps());
	await flowCommand("feature x", ctx());
	const run = onlyRun();
	const tree = worktreeOf(run);
	// The crash: implement's commit is there, its step-end and everything after are not.
	git(tree, "reset", "-q", "--hard", "HEAD~1");
	cutEvents(run, events(run).findIndex((e) => e.type === "step-start" && e.step === "implement"));
	await flowCommand("resume", ctx());
	assert.deepEqual(calls().map((x) => x.step), ["plan", "implement", "review", "review"]);
	const recovered = events(run).find((e) => e.type === "step-end" && e.step === "implement");
	assert.equal(recovered?.recovered, true);
	assert.equal(recovered?.outcome, "done");
	assert.deepEqual(trailers(tree), ["plan/1/", "implement/1/", "review/1/"]);
	assert.equal(events(run).at(-1)?.stop, "done");
});

test("uncommitted changes at resume: it asks, and a no resets nothing", async () => {
	flow(twoSteps());
	pi({ hang: ["implement"], writes: { implement: { "src/mine.ts": "keep me\n" } } });
	const controller = new AbortController();
	const running = flowCommand("feature x", ctx(), controller.signal);
	await waitFor(() => existsSync(join(piDir, "hang-implement.json")));
	controller.abort();
	await running;
	const run = onlyRun();
	const tree = worktreeOf(run);
	pi({});
	const before = calls().length;
	let asked = 0;
	const c = ctx();
	c.ui.confirm = async () => (asked++, false);
	messages = [];
	await flowCommand("resume", c);
	assert.equal(asked, 1);
	assert.equal(readFileSync(join(tree, "src", "mine.ts"), "utf8"), "keep me\n", "no reset");
	assert.equal(calls().length, before, "no child started");
	assert.match(messages.at(-1)?.text ?? "", /nothing was reset/);
	assert.ok(!existsSync(join(run, "lock")), "lock released");
});

async function waitFor(ok: () => boolean, ms = 10_000) {
	const end = Date.now() + ms;
	while (!ok()) {
		if (Date.now() > end) throw new Error("timed out");
		await new Promise((r) => setTimeout(r, 25));
	}
}

function alive(pid: number): boolean {
	try {
		process.kill(pid, 0);
		return true;
	} catch {
		return false;
	}
}

test("abort kills the child's process group: no orphan is left", async () => {
	flow(twoSteps());
	pi({ hang: ["plan"] });
	const controller = new AbortController();
	const running = flowCommand("feature x", ctx(), controller.signal);
	await waitFor(() => existsSync(join(piDir, "hang-plan.json")));
	const { pid, grandchild } = JSON.parse(readFileSync(join(piDir, "hang-plan.json"), "utf8"));
	assert.ok(alive(pid) && alive(grandchild));
	controller.abort();
	await running;
	await waitFor(() => !alive(pid) && !alive(grandchild), 3000);
	const end = events(onlyRun()).at(-1);
	assert.equal(end?.type, "step-end");
	assert.equal(end?.reason, "aborted");
});

test("STOP halts before the next step; gate edits are committed before it on resume", async () => {
	flow(twoSteps());
	pi({ stop: ["plan"] });
	await flowCommand("feature x", ctx());
	assert.deepEqual(calls().map((x) => x.step), ["plan"]);
	const run = onlyRun();
	const tree = worktreeOf(run);
	const halt = events(run).at(-1);
	assert.equal(halt?.type, "halted");
	assert.equal(halt?.next, "implement");
	assert.ok(!events(run).some((e) => e.type === "run-end"));
	assert.match(messages.at(-1)?.text ?? "", /halted by STOP before step implement/);
	// While halted, the user edits the worktree (as at a gate).
	writeFileSync(join(tree, "notes.md"), "my edit\n");
	pi({});
	await flowCommand("resume", ctx());
	assert.ok(!existsSync(join(run, "STOP")), "resume removed STOP");
	assert.deepEqual(calls().map((x) => x.step), ["plan", "implement", "review"]);
	assert.deepEqual(trailers(tree), ["plan/1/", "//plan", "implement/1/", "review/1/"]);
	assert.equal(git(tree, "show", "HEAD:notes.md"), "my edit");
	assert.equal(events(run).at(-1)?.stop, "done");
});

const gated = () => [
	{ id: "plan", agent: "planner", model: "m/a" },
	{ id: "implement", agent: "implementer", model: "m/a" },
	{ id: "review", agent: "reviewer", model: "m/b", gate: true, routes: { "failed:sent-back": "implement" } },
];

/** A ctx with a UI that answers the gate from lists and records what it showed. */
function gateCtx(choices: string[], notes: string[] = []) {
	const shown = { editors: [] as { title: string; text: string }[], selects: [] as string[] };
	const c = ctx();
	(c as { hasUI: boolean }).hasUI = true;
	c.ui.editor = async (title: string, text?: string) => {
		shown.editors.push({ title, text: text ?? "" });
		return title.startsWith("Send Back") ? notes.shift() : text;
	};
	c.ui.select = async (title: string) => (shown.selects.push(title), choices.shift());
	return { c, shown };
}

test("Approve at a gate continues, after the diff of the run branch", async () => {
	flow(gated());
	pi({ writes: { implement: { "src/export.ts": "export const csv = 1;\n" } } });
	const { c, shown } = gateCtx(["Approve"]);
	await flowCommand("feature x", c);
	const run = onlyRun();
	assert.deepEqual(calls().map((x) => x.step), ["plan", "implement", "review"]);
	assert.deepEqual(shown.selects, ["Gate after step review"]);
	const diff = shown.editors[0];
	assert.match(diff.title, /akit-flow\/.* against its base \(read only/);
	assert.match(diff.text, /src\/export\.ts/);
	assert.match(diff.text, /\+export const csv = 1;/);
	assert.deepEqual(events(run).filter((e) => e.type === "gate").map((e) => e.answer), ["approve"]);
	assert.deepEqual(deviations(run), []);
	assert.equal(events(run).at(-1)?.stop, "done");
});

test("Send Back routes failed:sent-back with a deviation and gives the note to that step", async () => {
	flow(gated());
	const { c } = gateCtx(["Send Back", "Approve"], ["The CSV needs a header row."]);
	await flowCommand("feature x", c);
	const run = onlyRun();
	assert.deepEqual(calls().map((x) => x.step), ["plan", "implement", "review", "implement", "review"]);
	assert.deepEqual(deviations(run).map((d) => [d.rule, d.detail]), [["sent-back", "The CSV needs a header row."]]);
	assert.deepEqual(events(run).filter((e) => e.type === "gate").map((e) => e.answer), ["send-back", "approve"]);
	const back = calls()[3].args.at(-1) ?? "";
	assert.match(back, /sent the work back at the gate after the step "review"/);
	assert.match(back, /The CSV needs a header row\./);
	assert.deepEqual(events(run).filter((e) => e.type === "step-start" && e.step === "implement").map((e) => e.attempt), [1, 2]);
	assert.equal(events(run).at(-1)?.stop, "done");
});

test("a gate without an answer halts; resume asks again", async () => {
	flow(gated());
	await flowCommand("feature x", ctx());
	const run = onlyRun();
	assert.equal(events(run).at(-1)?.type, "halted");
	assert.match(messages.at(-1)?.text ?? "", /waits at the gate after step review/);
	const { c } = gateCtx(["Approve"]);
	await flowCommand("resume", c);
	assert.deepEqual(calls().map((x) => x.step), ["plan", "implement", "review"]);
	assert.equal(events(run).at(-1)?.stop, "done");
});

test("akit_flow without a yes starts nothing", async () => {
	flow(twoSteps());
	const c = ctx();
	(c as { hasUI: boolean }).hasUI = true;
	const asked: string[] = [];
	c.ui.confirm = async (title: string, message: string) => (asked.push(`${title} ${message}`), false);
	const text = await startTool({ flow: "feature", task: "add CSV export" }, c);
	assert.match(text, /did not confirm; no flow was started/);
	assert.deepEqual(asked, ["Start a flow? The model asks to run the flow feature for: add CSV export"]);
	assert.equal(calls().length, 0);
	assert.ok(!existsSync(join(project, ".pi", "akit-flow")), "no run folder");
	// No UI to ask in: nothing starts either.
	assert.match(await startTool({ task: "x" }, ctx()), /no flow was started/);
	assert.equal(calls().length, 0);
});

test("akit_flow with a yes runs the flow", async () => {
	flow(twoSteps());
	const c = ctx();
	(c as { hasUI: boolean }).hasUI = true;
	c.ui.confirm = async () => true;
	const text = await startTool({ task: "add CSV export" }, c);
	const run = onlyRun();
	assert.match(text, new RegExp(`Flow run ${run.split("/").pop()} has ended`));
	assert.deepEqual(calls().map((x) => x.step), ["plan", "implement", "review"]);
	assert.match(calls()[0].args.at(-1) ?? "", /Task: add CSV export/);
});

test("a child loads only the guard, the handoff tool and the step's named extensions, with its rules", async () => {
	flow([
		{ id: "plan", agent: "planner", model: "m/a", extensions: ["gitlab.ts"] },
		{ id: "review", agent: "reviewer", model: "m/b", paths: ["docs/**"] },
	], { tools: ["read", "edit"] });
	await flowCommand("feature add CSV export", ctx());
	const flows = join(repo, "AKitCore", "Sources", "AKitRender", "Resources", "flows");
	const ext = (args: string[]) => args.flatMap((a, i) => (args[i - 1] === "-e" ? [a] : []));
	const [plan, review] = calls().map((c) => c.args);
	assert.ok(plan.indexOf("-ne") < plan.indexOf("-e"), "-ne comes before the -e list");
	assert.deepEqual(ext(plan), [join(flows, "akit-flow-guard.ts"), join(flows, "akit-flow-handoff.ts"), join(project, ".pi", "extensions", "gitlab.ts")]);
	assert.deepEqual(ext(review), [join(flows, "akit-flow-guard.ts"), join(flows, "akit-flow-handoff.ts")]);
	const run = onlyRun();
	const rules = JSON.parse(readFileSync(join(run, "guard", "02-review-a1.json"), "utf8"));
	assert.deepEqual(rules.tools, ["read", "edit"], "a step without tools gets the flow's");
	assert.deepEqual(rules.paths, ["docs/**"]);
	assert.equal(rules.bash, false, "a write-restricted step has no bash by default");
	assert.equal(rules.events, join(run, "events.jsonl"));
	assert.equal(JSON.parse(readFileSync(join(run, "guard", "01-plan-a1.json"), "utf8")).bash, true);
});

test("the row below the editor follows this Pi's run; /flow show opens a step", async () => {
	flow(fourSteps());
	await flowCommand("feature add CSV export", ctx());
	assert.ok(widgets.length > 0 && widgets.every((w) => w.placement === "belowEditor"));
	assert.ok(widgets.some((w) => /1 plan ● a/.test(w.lines?.[0] ?? "")), "a running step shows ● and its model");
	assert.match(widgets.at(-1)?.lines?.[0] ?? "", /^1 plan ✓ a 120  2 implement ✓ a 120  3 checks ✓ a 120  4 review ✓ b 120 {3}alt\+1…4 view$/, "shortcuts of the registered extension, up to the step count");
	await flowCommand("show 9", ctx());
	assert.match(messages.at(-1)?.text ?? "", /Usage: \/flow show <1-4>/);
	await flowCommand("show 2", ctx());
	assert.match(messages.at(-1)?.text ?? "", /step 2 implement ✓[\s\S]*worked on implement[\s\S]*Esc closes/, "without custom UI the overlay text is a message");
});
