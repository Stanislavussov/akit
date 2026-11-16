// akit-flow.ts against a fake `pi` on PATH, in a temporary fake HOME and a temporary git project.
import assert from "node:assert/strict";
import { execFileSync, spawn, spawnSync } from "node:child_process";
import { cpSync, existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, beforeEach, test } from "node:test";
import akitFlow, { flowCommand } from "../../../AKitCore/Sources/AKitRender/Resources/flows/akit-flow.ts";
import type { ExtensionCommandContext } from "../../../AKitCore/Sources/AKitRender/Resources/flows/pi-adapter.ts";

const repo = join(import.meta.dirname, "..", "..", "..");
let root: string, project: string, piDir: string, messages: { text: string; level?: string }[];
const saved = { HOME: process.env.HOME, PATH: process.env.PATH };

function ctx(): ExtensionCommandContext {
	return {
		cwd: project, hasUI: false, signal: undefined, waitForIdle: async () => {},
		ui: {
			notify: (text: string, level?: string) => messages.push({ text, level }),
			setStatus: () => {}, setWidget: () => {}, confirm: async () => false, select: async () => undefined,
			input: async () => undefined, editor: async () => undefined,
		},
	} as ExtensionCommandContext;
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
	execFileSync("git", ["init", "-q"], { cwd: project });
	mkdirSync(join(project, ".pi", "skills", "tdd"), { recursive: true });
	writeFileSync(join(project, ".pi", "skills", "tdd", "SKILL.md"), "---\nname: tdd\n---\n");
	process.env.HOME = home;
	process.env.PATH = `${bin}:${saved.PATH}`;
	process.env.FAKE_PI_DIR = piDir;
	messages = [];
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

function calls(): { step: string; args: string[]; stdinNull: boolean }[] {
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

test("the extension registers /flow", () => {
	const names: string[] = [];
	akitFlow({ registerCommand: (name: string) => names.push(name), on: () => () => {} } as never);
	assert.deepEqual(names, ["flow"]);
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
	assert.equal(chk[chk.indexOf("-t") + 1], "read,bash");
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
	assert.deepEqual(h.step, { index: 2, id: "implement", attempt: 1 });
	assert.deepEqual(h.next, { step: "checks" });
	assert.match(calls()[2].args.at(-1) ?? "", /Handoff from the step "implement"/);
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
