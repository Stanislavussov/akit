// akit-skill-modes.ts with a fake `pi` object and a fake `akit` script, in a temporary fake HOME.
import assert from "node:assert/strict";
import { chmodSync, cpSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync, utimesSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, beforeEach, test } from "node:test";
import akitSkillModes, { type Answer, applyModes, body, expand, STATUS } from "../../../AKitCore/Sources/AKitSkills/Resources/akit-skill-modes.ts";

let root: string, home: string, akit: string, calls: string, answerFile: string;
const savedHome = process.env.HOME;

beforeEach(() => {
	root = realpathSync(mkdtempSync(join(tmpdir(), "akit-skill-modes-")));
	home = join(root, "home");
	mkdirSync(join(home, ".akit", "local"), { recursive: true });
	akit = join(root, "akit");
	cpSync(join(import.meta.dirname, "fake-akit.mjs"), akit);
	chmodSync(akit, 0o755);
	calls = join(root, "calls.jsonl");
	answerFile = join(root, "answer.json");
	process.env.HOME = home;
	process.env.FAKE_AKIT_CALLS = calls;
	process.env.FAKE_AKIT_ANSWER = answerFile;
	process.env.FAKE_AKIT_MODE = "good";
	setAnswer({});
});

afterEach(() => {
	process.env.HOME = savedHome;
	rmSync(root, { recursive: true, force: true });
});

function setAnswer(part: Partial<Answer>) {
	const answer: Answer = { version: 1, project: "example.com/team/app", modes: {}, renames: {}, problems: [], ...part };
	writeFileSync(answerFile, JSON.stringify(answer));
}

function asked(): { args: string[]; stdin: { skills: { name: string }[] } }[] {
	try {
		return readFileSync(calls, "utf8").trim().split("\n").filter(Boolean).map((line) => JSON.parse(line));
	} catch {
		return [];
	}
}

function skill(name: string, scope = "user", manual = false) {
	const filePath = `/skills/${name}/SKILL.md`;
	return { name, description: `does ${name}`, filePath, baseDir: `/skills/${name}`, disableModelInvocation: manual,
		sourceInfo: { path: filePath, source: "local", scope, origin: "top-level", baseDir: `/skills/${name}` } };
}

function fakePi(skills: ReturnType<typeof skill>[]) {
	const handlers = new Map<string, ((event: any, ctx: any) => any)[]>();
	const status: (string | undefined)[] = [];
	const notices: string[] = [];
	const ctx = { cwd: join(root, "repo"), ui: { setStatus: (key: string, text?: string) => { assert.equal(key, STATUS); status.push(text); }, notify: (text: string) => notices.push(text) } };
	const pi = {
		on: (name: string, handler: (event: any, ctx: any) => any) => handlers.set(name, [...(handlers.get(name) ?? []), handler]),
		getCommands: () => skills.map((s) => ({ name: `skill:${s.name}`, description: s.description, source: "skill", sourceInfo: s.sourceInfo })),
	};
	const emit = async (name: string, event: any) => {
		let result: any;
		for (const handler of handlers.get(name) ?? []) result = await handler(event, ctx);
		return result;
	};
	/** One run: before_agent_start with a fresh copy of the base options, as Pi does. */
	const run = async () => {
		const options = { skills: skills.map((s) => ({ ...s })) };
		await emit("before_agent_start", { type: "before_agent_start", prompt: "hi", systemPromptOptions: options });
		return options.skills;
	};
	return { pi, emit, run, status, notices, ctx };
}

function load(skills: ReturnType<typeof skill>[], timeoutMs = 3000, found = true) {
	const fake = fakePi(skills);
	akitSkillModes(fake.pi, { akit: () => (found ? akit : undefined), timeoutMs });
	return fake;
}

const brief = (skills: any[]) => skills.map((s) => `${s.name}:${s.disableModelInvocation ? "manual" : "auto"}`).join(",");

test("a run gets the project's modes: off left out, manual and auto set, temporary untouched, renames added", async () => {
	setAnswer({
		modes: { tdd: "auto", lint: "manual", review: "off" },
		renames: { "my-review": { original: "review", file: "/home/me/.agents/skills/review/SKILL.md", baseDir: "/home/me/.agents/skills/review", description: "mine", mode: "manual", from: "skill" } },
	});
	const base = [skill("tdd", "user", true), skill("lint"), skill("review", "project"), skill("flow", "temporary"), skill("plain", "user", true)];
	const fake = load(base);
	const skills = await fake.run();
	assert.equal(brief(skills), "tdd:auto,lint:manual,flow:auto,plain:manual,my-review:manual");
	const mine = skills[skills.length - 1];
	assert.equal(mine.filePath, "/home/me/.agents/skills/review/SKILL.md");
	assert.equal(mine.description, "mine");
	assert.equal(mine.sourceInfo.scope, "user");
	// Pi's own skill objects are never changed.
	assert.equal(base[0].disableModelInvocation, true);
	assert.deepEqual(asked()[0].args, ["skills", "resolve", "--harness", "pi", "--cwd", join(root, "repo"), "--json"]);
	assert.deepEqual(asked()[0].stdin.skills.map((s) => s.name), ["tdd", "lint", "review", "flow", "plain"]);
	assert.deepEqual(fake.status, [undefined]);
});

test("a temporary skill keeps its mode even when the project names it", () => {
	const answer: Answer = { version: 1, project: "p", modes: { flow: "off" }, renames: {}, problems: [] };
	assert.equal(brief(applyModes([skill("flow", "temporary", true)], answer)), "flow:manual");
});

test("akit is asked once per folder and modes file; a change of the file or a new session asks again", async () => {
	const fake = load([skill("tdd")]);
	await fake.emit("session_start", { type: "session_start", reason: "startup" });
	await fake.run();
	await fake.run();
	assert.equal(asked().length, 1);
	const file = join(home, ".akit", "local", "skill-modes.json");
	writeFileSync(file, "{}");
	await fake.run();
	assert.equal(asked().length, 2);
	utimesSync(file, new Date(), new Date(Date.now() + 5000));
	await fake.run();
	assert.equal(asked().length, 3);
	await fake.emit("session_start", { type: "session_start", reason: "new" });
	await fake.run();
	assert.equal(asked().length, 4);
});

for (const [mode, expected] of [["slow", /not applied, akit didn't answer in 0.3 s/], ["bad", /not applied, akit's answer is not JSON/],
	["fail", /not applied, akit exited with 3: akit: broken/], ["wrong", /not applied, akit's answer is not a skill modes answer/]] as const) {
	test(`a ${mode} akit changes nothing and says so in the status line`, async () => {
		process.env.FAKE_AKIT_MODE = mode;
		setAnswer({ modes: { tdd: "off" } });
		const fake = load([skill("tdd", "user", true)], 300);
		const started = Date.now();
		const skills = await fake.run();
		assert.ok(Date.now() - started < 2000);
		assert.equal(brief(skills), "tdd:manual");
		assert.match(fake.status.at(-1) ?? "", expected);
	});
}

test("without akit nothing changes; the next success clears the status line", async () => {
	setAnswer({ modes: { tdd: "auto" } });
	const fake = fakePi([skill("tdd", "user", true)]);
	let found = false;
	akitSkillModes(fake.pi, { akit: () => (found ? akit : undefined) });
	assert.equal(brief(await fake.run()), "tdd:manual");
	assert.match(fake.status.at(-1) ?? "", /not applied, akit not found/);
	found = true;
	await fake.emit("session_start", { type: "session_start", reason: "new" });
	assert.equal(brief(await fake.run()), "tdd:auto");
	assert.equal(fake.status.at(-1), undefined);
});

test("a modes file AKit can't read shows in the status line", async () => {
	setAnswer({ problems: [{ kind: "file", message: "~/.akit/local/skill-modes.json is not valid JSON" }] });
	const fake = load([skill("tdd")]);
	await fake.run();
	assert.equal(fake.status.at(-1), "skill modes: not applied, ~/.akit/local/skill-modes.json is not valid JSON");
	setAnswer({ problems: [{ kind: "entry", message: "x" }, { kind: "entry", message: "y" }] });
	writeFileSync(join(home, ".akit", "local", "skill-modes.json"), "{}");
	await fake.run();
	assert.equal(fake.status.at(-1), "skill modes: 2 entries skipped (akit doctor)");
});

test("/skill: of an off skill is refused, my-NAME is expanded as Pi expands /skill:, the rest passes", async () => {
	const mine = join(root, "mine", "review");
	mkdirSync(mine, { recursive: true });
	writeFileSync(join(mine, "SKILL.md"), "---\r\nname: review\r\ndescription: mine\r\n---\r\n\r\nMy steps.\r\n");
	setAnswer({
		modes: { lint: "off" },
		renames: {
			"my-review": { original: "review", file: join(mine, "SKILL.md"), baseDir: mine, description: "mine", mode: "manual", from: "skill" },
			"my-old": { original: "old", file: "/x/SKILL.md", baseDir: "/x", description: "d", mode: "off", from: "project" },
		},
	});
	const fake = load([skill("lint"), skill("review", "project"), skill("tdd")]);
	assert.deepEqual(await fake.emit("input", { type: "input", text: "hello", source: "interactive" }), { action: "continue" });
	assert.equal(asked().length, 0);
	assert.deepEqual(await fake.emit("input", { type: "input", text: "/skill:lint now", source: "interactive" }), { action: "handled" });
	assert.deepEqual(fake.notices, ["lint is off in this project (akit skills mode lint --reset)"]);
	assert.deepEqual(await fake.emit("input", { type: "input", text: "/skill:my-old", source: "interactive" }), { action: "handled" });
	assert.deepEqual(await fake.emit("input", { type: "input", text: "/skill:tdd", source: "interactive" }), { action: "continue" });
	const expanded = await fake.emit("input", { type: "input", text: "/skill:my-review  check it ", source: "interactive" });
	assert.deepEqual(expanded, {
		action: "transform",
		text: `<skill name="my-review" location="${join(mine, "SKILL.md")}">\nReferences are relative to ${mine}.\n\nMy steps.\n</skill>\n\ncheck it`,
	});
	assert.equal(asked().length, 1);
});

test("the body is cut as Pi cuts it", () => {
	assert.equal(body("﻿---\nname: x\n---\n\n  text\n\n"), "text");
	assert.equal(body("no header\n"), "no header");
	assert.equal(body("---\nname: x\nno end"), "---\nname: x\nno end");
	const rename = { original: "x", file: "/f/SKILL.md", baseDir: "/f", description: "", mode: "auto" as const, from: "skill" };
	assert.equal(expand("my-x", rename, "", () => "---\na: b\n---\nB"), `<skill name="my-x" location="/f/SKILL.md">\nReferences are relative to /f.\n\nB\n</skill>`);
});
