// akit-flow-guard.ts: written by AKit (docs/design/flows.md F15, F16). Loaded first into each flow
// step's child Pi with -e. Answers Pi's `tool_call` with { block: true, reason } for every call the
// step's rules forbid, and appends a deviation line to the run's events.jsonl. The rules come from
// the JSON file named in AKIT_FLOW_GUARD, written by the runner (akit-flow.ts) for this attempt.

import { appendFileSync, lstatSync, readFileSync, realpathSync } from "node:fs";
import { dirname, isAbsolute, relative, resolve, sep } from "node:path";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { redact } from "./flow-core.ts";

/** What one step attempt may do; the runner writes it, the guard only reads it. */
export interface GuardRules {
	run: string;
	step: string;
	attempt: number;
	/** Allowed tool names; any other tool, built-in, extension or `mcp__`, is blocked. */
	tools: string[];
	/** Paths `edit` / `write` may touch, relative to the worktree; empty: anywhere in the worktree. */
	paths: string[];
	bash: boolean;
	/** The run's worktree: writes outside it are always blocked. */
	root: string;
	/** The run's events.jsonl, where blocked calls go as deviations (F16). */
	events: string;
	/** The run records folder (`<main checkout>/.pi/akit-flow`): `edit` / `write` there is always blocked. */
	records?: string;
}

/** Pi's built-in tools: a step without a tool list may use these, and nothing else. */
export const DEFAULT_TOOLS = ["read", "bash", "edit", "write", "grep", "find", "ls"];
/** The runner's own tool for the child; always allowed. */
export const HANDOFF_TOOL = "flow_handoff";

/** Tools that start other agents or flows: blocked in every step, listed or not (D28). The names
 * are pi-subagents' tools (subagent, subagent_wait, contact_supervisor) and AKit's own akit_flow. */
export function isSubagentTool(name: string): boolean {
	return name === "akit_flow" || name === "contact_supervisor" || /^subagents?(_|$)/.test(name);
}

const WRITE_TOOLS = new Set(["edit", "write"]);

/** Glob of a step path: `**` any depth, `*` and `?` within one name; a plain path also covers
 * everything below it. */
function matches(pattern: string, path: string): boolean {
	const clean = pattern.replace(/^\.\//, "").replace(/\/+$/, "");
	if (!/[*?]/.test(clean)) return path === clean || path.startsWith(`${clean}/`);
	const source = clean.split(/(\*\*\/?|\*|\?)/).map((part) =>
		part === "**/" ? "(?:.*/)?" : part === "**" ? ".*" : part === "*" ? "[^/]*" : part === "?" ? "[^/]" : part.replace(/[.+^${}()|[\]\\]/g, "\\$&")).join("");
	return new RegExp(`^${source}$`).test(path);
}

/** `rel` (from path.relative) stays below its base. */
function below(rel: string): boolean {
	return rel !== ".." && !rel.startsWith(`..${sep}`) && !rel.startsWith("../") && !isAbsolute(rel);
}

/** The real path of `target`'s nearest existing parent joined with the rest, or undefined when the
 * target itself is a symlink (a write through it could leave the worktree). */
function realTarget(target: string): string | undefined {
	try {
		if (lstatSync(target).isSymbolicLink()) return undefined;
	} catch {
		// Not there yet: a new file.
	}
	let parent = target;
	const rest: string[] = [];
	for (;;) {
		try {
			return resolve(realpathSync(parent), ...rest.reverse());
		} catch {
			const up = dirname(parent);
			if (up === parent) return target;
			rest.push(parent.slice(up.length).replace(/^[\\/]+/, ""));
			parent = up;
		}
	}
}

/** The worktree-relative path of a write, or undefined when it leaves the worktree, lexically or
 * through a symlink. */
function inside(root: string, target: string): string | undefined {
	const lexical = resolve(root, target);
	const rel = relative(root, lexical);
	if (rel === "") return ".";
	if (!below(rel)) return undefined;
	let realRoot = root;
	try {
		realRoot = realpathSync(root);
	} catch {
		// The root is gone; the lexical path still counts.
		return rel.split("\\").join("/");
	}
	const real = realTarget(lexical);
	if (real === undefined) return undefined;
	const realRel = relative(realRoot, real);
	if (realRel !== "" && !below(realRel)) return undefined;
	return rel.split("\\").join("/");
}

/** `target` is in the run records folder. */
function inRecords(records: string, root: string, target: string): boolean {
	const abs = resolve(root, target);
	for (const base of [records, (() => { try { return realpathSync(records); } catch { return records; } })()]) {
		for (const t of [abs, realTarget(abs) ?? abs]) {
			const rel = relative(base, t);
			if (rel === "" || below(rel)) return true;
		}
	}
	return false;
}

function filePath(input: Record<string, unknown>): string {
	const value = input.path ?? input.file_path ?? input.filePath;
	return typeof value === "string" ? value : "";
}

/** A short, redacted summary of a call's input for the deviation line: never file contents. */
export function inputSummary(tool: string, input: Record<string, unknown>): string {
	if (WRITE_TOOLS.has(tool) || tool === "read") return filePath(input);
	if (tool === "bash" && typeof input.command === "string") return redact(input.command).slice(0, 120);
	return Object.keys(input).sort().join(", ");
}

/** Why the rules forbid this call, or undefined when it may run. */
export function forbidden(rules: GuardRules, tool: string, input: Record<string, unknown>): { rule: string; reason: string } | undefined {
	if (tool === HANDOFF_TOOL) return undefined;
	if (isSubagentTool(tool)) return { rule: "subagent", reason: `Step ${rules.step} may not start other agents (${tool}); another agent is another step of the flow.` };
	if (!rules.tools.includes(tool)) return { rule: "tool-not-allowed", reason: `The tool ${tool} is not in step ${rules.step}'s tools (${rules.tools.join(", ") || "none"}).` };
	if (tool === "bash" && !rules.bash) return { rule: "bash", reason: `Step ${rules.step} may not run bash: its writes are limited to ${rules.paths.join(", ")}.` };
	if (WRITE_TOOLS.has(tool)) {
		if (rules.records && inRecords(rules.records, rules.root, filePath(input)))
			return { rule: "path", reason: `${filePath(input)} is in the flow's run records; only the runner writes there.` };
		const rel = inside(rules.root, filePath(input));
		if (rel === undefined) return { rule: "path", reason: `${filePath(input) || "(no path)"} is outside the flow's worktree.` };
		if (rules.paths.length > 0 && !rules.paths.some((p) => matches(p, rel)))
			return { rule: "path", reason: `Step ${rules.step} may change only ${rules.paths.join(", ")}; ${rel} is not one of them.` };
	}
	return undefined;
}

export function readRules(path: string): GuardRules {
	return JSON.parse(readFileSync(path, "utf8")) as GuardRules;
}

/** The `tool_call` handler; exported for the tests. */
export function guardHandler(rules: GuardRules) {
	return (event: { toolName: string; input: Record<string, unknown> }): { block: true; reason: string } | undefined => {
		const input = event.input && typeof event.input === "object" ? event.input : {};
		const no = forbidden(rules, event.toolName, input);
		if (!no) return undefined;
		const line = {
			schema: "akit-flow-event/1", type: "deviation", time: new Date().toISOString(), step: rules.step, attempt: rules.attempt,
			rule: no.rule, tool: event.toolName, input: inputSummary(event.toolName, input), action: "blocked",
		};
		try {
			appendFileSync(rules.events, `${JSON.stringify(line)}\n`);
		} catch {
			// The block holds even when the log can't be written.
		}
		return { block: true, reason: `Blocked by the AKit flow guard: ${no.reason}` };
	};
}

export default function akitFlowGuard(pi: ExtensionAPI): void {
	const path = process.env.AKIT_FLOW_GUARD;
	if (!path) {
		// A flow step child (it has a handoff file) without rules fails closed; plain Pi is untouched.
		if (process.env.AKIT_FLOW_HANDOFF) {
			const reason = "Blocked by the AKit flow guard: the step's rules are missing (AKIT_FLOW_GUARD is not set).";
			pi.on("tool_call", (event) => (event.toolName === HANDOFF_TOOL ? undefined : { block: true, reason }));
		}
		return;
	}
	let handler: ReturnType<typeof guardHandler>;
	try {
		handler = guardHandler(readRules(path));
	} catch (error) {
		// Rules that can't be read block everything but the handoff: the step fails closed.
		const reason = `Blocked by the AKit flow guard: its rules can't be read (${(error as Error).message}).`;
		pi.on("tool_call", (event) => (event.toolName === HANDOFF_TOOL ? undefined : { block: true, reason }));
		return;
	}
	pi.on("tool_call", (event) => handler(event));
}
