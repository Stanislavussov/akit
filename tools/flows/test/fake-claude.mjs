#!/usr/bin/env node
// A fake `claude` for the Flows tests (a claude-code step, F21). Every call is logged to
// FAKE_PI_DIR/claude-calls.jsonl. config.claude: per call "done", "failed:<reason>" or "error"
// (an is_error result with no structured output). It prints one JSON result, as `claude -p
// --output-format json` does, with the handoff as structured_output.
import { appendFileSync, existsSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";

const dir = process.env.FAKE_PI_DIR;
const config = JSON.parse(readFileSync(join(dir, "config.json"), "utf8"));
const args = process.argv.slice(2);
const prompt = args[args.indexOf("-p") + 1];
const step = /step "([^"]+)"/.exec(prompt)?.[1] ?? "?";
appendFileSync(join(dir, "claude-calls.jsonl"), `${JSON.stringify({ step, args, cwd: process.cwd() })}\n`);
const countFile = join(dir, `claude-count-${step}`);
const n = existsSync(countFile) ? Number(readFileSync(countFile, "utf8")) : 0;
writeFileSync(countFile, String(n + 1));
const list = config.claude ?? ["done"];
const answer = list[Math.min(n, list.length - 1)];
const session = args[args.indexOf("--session-id") + 1];
const usage = { input_tokens: 300, output_tokens: 40, cache_read_input_tokens: 200 };
if (answer === "error") {
	console.log(JSON.stringify({ type: "result", is_error: true, result: "Execution error", session_id: session, usage, total_cost_usd: 0.02 }));
} else {
	const [outcome, reason] = answer.split(":");
	console.log(JSON.stringify({
		type: "result", is_error: false, result: "reviewed", session_id: session, usage, total_cost_usd: 0.02,
		structured_output: { goal: `${step} goal`, done: [`claude did ${step}`], files: [], open_questions: [], notes: `notes of ${step} from claude`, outcome, reason: reason ?? "" },
	}));
}
