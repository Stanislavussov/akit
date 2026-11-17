#!/usr/bin/env node
// A fake `pi` for the Flows tests. FAKE_PI_DIR/config.json says the version, the help text and each
// step's outcomes; every call is logged to FAKE_PI_DIR/calls.jsonl. It writes a session file in
// --session-dir and, as the model calling flow_handoff, the handoff part to AKIT_FLOW_HANDOFF.
// config.handoff[step]: per call "tool" (default), "line" (only a last `outcome:` line) or "none".
import { appendFileSync, existsSync, fstatSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";

const dir = process.env.FAKE_PI_DIR;
const config = JSON.parse(readFileSync(join(dir, "config.json"), "utf8"));
const args = process.argv.slice(2);
const FLAGS = ["--mode <mode>", "--session-dir <dir>", "--no-skills, -ns", "--skill <path>", "--no-extensions, -ne",
	"--extension, -e <path>", "--model <pattern>", "--thinking <level>", "--tools, -t <tools>"];
if (args[0] === "--version") {
	console.log(config.version ?? "1.0.4");
	process.exit(0);
}
if (args[0] === "--help") {
	const missing = config.missing ?? [];
	for (const flag of FLAGS) if (!missing.some((m) => flag.startsWith(m + " ") || flag.startsWith(m + ","))) console.log(`  ${flag}   description`);
	process.exit(0);
}
const prompt = args[args.length - 1];
const step = /step "([^"]+)"/.exec(prompt)?.[1] ?? "?";
appendFileSync(join(dir, "calls.jsonl"), `${JSON.stringify({ step, args, pid: process.pid, stdinNull: fstatSync(0).isCharacterDevice() })}\n`);
const countFile = join(dir, `count-${step}`);
const n = existsSync(countFile) ? Number(readFileSync(countFile, "utf8")) : 0;
writeFileSync(countFile, String(n + 1));
const list = config.outcomes?.[step] ?? ["done"];
const outcome = list[Math.min(n, list.length - 1)];
const modes = config.handoff?.[step] ?? ["tool"];
const mode = modes[Math.min(n, modes.length - 1)];
const session = `sess-${step}-${n + 1}`;
const sessionDir = args[args.indexOf("--session-dir") + 1];
mkdirSync(sessionDir, { recursive: true });
writeFileSync(join(sessionDir, `2026-11-17T12-00-00-000Z_${session}.jsonl`), `${JSON.stringify({ type: "session", version: 3, id: session })}\n`);
const [kind, reason] = outcome.split(":");
if (mode === "tool") {
	writeFileSync(process.env.AKIT_FLOW_HANDOFF, JSON.stringify({
		goal: `${step} goal`, done: [`did ${step}`], files: [{ path: `src/${step}.ts`, change: "added" }], open_questions: [],
		notes: `notes of ${step}`, outcome: kind, reason: reason ?? "",
	}));
}
const out = (v) => process.stdout.write(`${JSON.stringify(v)}\n`);
out({ type: "session", version: 3, id: session, cwd: process.cwd() });
out({ type: "agent_start" });
out({ type: "something_new", data: 1 });
out({ type: "message_end", message: { role: "assistant", content: [{ type: "text", text: mode === "line" ? `worked on ${step}\noutcome: ${outcome}` : `worked on ${step}` }],
	usage: { input: 100, output: 20, cacheRead: 5, cost: { total: 0.01 } } } });
out({ type: "agent_end" });
