// claude-adapter.ts: written by AKit (docs/design/flows.md F21). A step with `harness: claude-code`
// runs as a headless Claude Code child instead of a Pi child: `claude -p` with no customizations,
// only read-only tools, nobody to answer permission prompts, and the handoff as the structured
// output of a JSON schema (Claude can't load Pi's flow_handoff tool). The runner treats the answer
// like a flow_handoff part. Claude steps are read-only (AKit's check refuses edit and write), since
// Pi's guard can't watch a Claude child; Claude's own tool list and permission rules do instead.

import { HANDOFF_PARAMETERS } from "./akit-flow-handoff.ts";
import { type ChildOptions, type ChildResult, runChild } from "./pi-adapter.ts";

export const CLAUDE = process.env.AKIT_FLOW_CLAUDE ?? "claude";

/** Pi's tool names → Claude Code's. edit and write have none: a Claude step is read-only. */
export const CLAUDE_TOOLS: Record<string, string> = { read: "Read", grep: "Grep", find: "Glob", ls: "Glob", bash: "Bash" };

/** Pi's thinking levels → Claude Code's `--effort` (low … max). */
const EFFORT: Record<string, string> = { off: "low", minimal: "low", low: "low", medium: "medium", high: "high", xhigh: "xhigh", max: "max" };

/** The child command: `-p` with the prompt, one JSON result, no CLAUDE.md, skills, hooks, plugins
 * or MCP servers, and every permission prompt denied. */
export function claudeArgs(o: ChildOptions & { sessionId: string }): string[] {
	const tools = [...new Set((o.tools.length > 0 ? o.tools : ["read", "grep", "find", "ls"]).map((t) => CLAUDE_TOOLS[t]).filter(Boolean))];
	const args = ["-p", o.prompt, "--output-format", "json", "--model", o.model, "--tools", tools.join(","),
		"--safe-mode", "--strict-mcp-config", "--permission-prompts", "none", "--session-id", o.sessionId,
		"--json-schema", JSON.stringify(HANDOFF_PARAMETERS)];
	const effort = o.thinking ? EFFORT[o.thinking] : undefined;
	if (effort) args.push("--effort", effort);
	return args;
}

/** Claude Code's one `{"type":"result", …}` line: tokens, cost, the answer and the structured output. */
export function readClaudeLine(line: string, result: ChildResult): void {
	if (!line.trim()) return;
	let event: Record<string, unknown>;
	try {
		event = JSON.parse(line) as Record<string, unknown>;
	} catch {
		result.badLines++;
		return;
	}
	if (event.type !== "result") {
		result.unknownEvents++;
		return;
	}
	if (typeof event.session_id === "string") result.session = event.session_id;
	if (typeof event.result === "string") result.text = event.result;
	const usage = (event.usage ?? {}) as Record<string, unknown>;
	const number = (v: unknown) => (typeof v === "number" ? v : undefined);
	result.tokens = {
		input: number(usage.input_tokens), output: number(usage.output_tokens), cacheRead: number(usage.cache_read_input_tokens),
		cost: number(event.total_cost_usd),
	};
	result.structured = event.is_error === true ? undefined : event.structured_output;
}

/** Runs one Claude Code step child (own process group, stdin /dev/null, abort kills the group). */
export function runClaudeChild(o: ChildOptions & { sessionId: string }): Promise<ChildResult> {
	return runChild(o, CLAUDE, claudeArgs(o), readClaudeLine);
}
