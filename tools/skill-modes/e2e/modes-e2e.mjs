// End to end: skill modes in the installed Pi (its SDK, pi-ai's faux model, a fake home).
// `make test-skill-modes-pi` builds this checkout's akit, then runs this. The extension is
// installed with `akit skills extension install --yes` and modes are set with `akit skills mode`,
// both against the fake home only. Exit 0 with "skipped" when Pi isn't installed.
//   node tools/skill-modes/e2e/modes-e2e.mjs AKIT_BINARY
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";

const akit = process.argv[2];
if (!akit || !existsSync(akit)) {
	console.error("use: node modes-e2e.mjs AKIT_BINARY");
	process.exit(2);
}

/** The pi-coding-agent package folder: $PI_PACKAGE_DIR, else the one behind `pi` on the PATH. */
function piPackage() {
	if (process.env.PI_PACKAGE_DIR) return process.env.PI_PACKAGE_DIR;
	let bin;
	try {
		bin = execFileSync("/usr/bin/which", ["pi"], { encoding: "utf8" }).trim();
	} catch {
		return undefined;
	}
	let folder = dirname(realpathSync(bin));
	for (let i = 0; i < 8 && folder !== "/"; i++, folder = dirname(folder)) {
		const manifest = join(folder, "package.json");
		if (existsSync(manifest) && JSON.parse(readFileSync(manifest, "utf8")).name === "@earendil-works/pi-coding-agent") return folder;
	}
	return undefined;
}

const pkg = piPackage();
if (!pkg) {
	console.log("skipped: Pi is not installed (no pi on the PATH; set PI_PACKAGE_DIR to its package folder)");
	process.exit(0);
}
const aiCandidates = [join(pkg, "node_modules/@earendil-works/pi-ai"), join(dirname(pkg), "pi-ai")];
const aiFolder = aiCandidates.find((folder) => existsSync(join(folder, "dist/index.js")));
if (!aiFolder) {
	console.log(`skipped: pi-ai not found next to ${pkg}`);
	process.exit(0);
}
const version = JSON.parse(readFileSync(join(pkg, "package.json"), "utf8")).version;

const root = realpathSync(mkdtempSync(join(tmpdir(), "akit-modes-e2e-")));
const home = join(root, "home"), agent = join(home, ".pi/agent"), project = join(root, "repo");
const skill = (dir, name, manual, text = `body of ${name}`) => {
	mkdirSync(join(dir, name), { recursive: true });
	writeFileSync(join(dir, name, "SKILL.md"), `---\nname: ${name}\ndescription: desc of ${name}\n${manual ? "disable-model-invocation: true\n" : ""}---\n${text}\n`);
};
try {
	skill(join(home, ".agents/skills"), "m1", true);
	skill(join(home, ".agents/skills"), "m2", true);
	skill(join(home, ".agents/skills"), "a1", false);
	skill(join(home, ".agents/skills"), "review", true, "MY OWN REVIEW STEPS");
	skill(join(project, ".agents/skills"), "t1", false);
	skill(join(project, ".agents/skills"), "review", false, "the team's review");
	mkdirSync(join(project, ".git"), { recursive: true });
	writeFileSync(join(project, ".git/config"), '[remote "origin"]\n\turl = git@example.com:team/repo.git\n');
	mkdirSync(agent, { recursive: true });
	writeFileSync(join(agent, "settings.json"), "{}");

	const env = { ...process.env, HOME: home, PI_CODING_AGENT_DIR: agent, AKIT_PROJECTS_ROOT: join(home, "Projects"),
		PATH: `${dirname(akit)}:${process.env.PATH}` };
	const run = (args) => execFileSync(akit, args, { cwd: project, env, encoding: "utf8" });
	run(["skills", "extension", "install", "--yes"]);
	assert.ok(existsSync(join(agent, "extensions/akit-skill-modes.ts")), "the extension is installed");
	run(["skills", "mode", "m1", "auto", "--yes"]);
	run(["skills", "mode", "a1", "manual", "--yes"]);
	run(["skills", "mode", "t1", "off", "--yes"]);
	run(["skills", "mode", "my-review", "auto", "--yes"]);
	Object.assign(process.env, { HOME: home, PI_CODING_AGENT_DIR: agent, AKIT_PROJECTS_ROOT: env.AKIT_PROJECTS_ROOT, PATH: env.PATH });

	const pi = await import(join(pkg, "dist/index.js"));
	const ai = await import(join(aiFolder, "dist/index.js"));
	const faux = ai.fauxProvider();
	const calls = [];
	const reply = (context) => {
		calls.push(context);
		return ai.fauxAssistantMessage("ok");
	};
	faux.setResponses(Array(20).fill(reply));
	const settings = pi.SettingsManager.create(project, agent, { projectTrusted: true });
	const loader = new pi.DefaultResourceLoader({ cwd: project, agentDir: agent, settingsManager: settings });
	await loader.reload();
	const runtime = await pi.ModelRuntime.create({ authPath: join(agent, "auth.json"), modelsPath: null, refreshOnCreate: false });
	runtime.registerNativeProvider(faux.provider);
	const { session } = await pi.createAgentSession({ cwd: project, agentDir: agent, model: faux.getModel(), modelRuntime: runtime,
		resourceLoader: loader, sessionManager: pi.SessionManager.inMemory(project), settingsManager: settings });
	await session.bindExtensions?.({});

	const text = (context) => JSON.stringify(context.messages ?? []) + JSON.stringify(context.systemPrompt ?? "");
	const listed = (context) => [...new Set([...text(context).matchAll(/<name>([^<]+)<\\?\/name>/g)].map((m) => m[1]))].sort();
	await session.prompt("hello");
	assert.deepEqual(listed(calls.at(-1)), ["m1", "my-review", "review"], "Auto skills only: m1 and a1 swapped, t1 off, my-review added");
	const before = calls.length;
	await session.prompt("/skill:t1 do it");
	assert.equal(calls.length, before, "/skill: of an off skill never reaches the model");
	await session.prompt("/skill:my-review check this");
	const last = text(calls.at(-1));
	assert.ok(last.includes("MY OWN REVIEW STEPS"), "/skill:my-review runs the personal skill");
	assert.ok(last.includes(`location=\\"${join(home, ".agents/skills/review/SKILL.md")}\\"`), "with Pi's block");
	await session.prompt("/skill:review check");
	assert.ok(text(calls.at(-1)).includes("the team's review"), "/skill:review stays the team's");
	session.dispose();
	console.log(`passed on Pi ${version}`);
} finally {
	rmSync(root, { recursive: true, force: true });
}
