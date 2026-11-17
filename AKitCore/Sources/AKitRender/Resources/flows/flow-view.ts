// flow-view.ts: written by AKit (docs/design/flows.md F18). Pure: no Pi, no files. What the Pi row
// and the step overlay show for this Pi process's run, built from the child's JSON events.

import { type Flow, redact } from "./flow-core.ts";

export type StepState = "pending" | "running" | "done" | "failed";

export type Entry =
	| { kind: "tool"; id: string; name: string; args: string; status: "running" | "ok" | "error" }
	| { kind: "text"; text: string };

export interface StepView {
	id: string;
	model: string;
	state: StepState;
	/** Input + output tokens Pi reported; undefined until a message gave them. */
	tokens?: number;
	/** The latest attempt's tool calls and assistant text, as Pi shows them: never tool output. */
	entries: Entry[];
}

export interface RunView {
	flow: string;
	run: string;
	steps: StepView[];
	deviations: number;
}

export function newView(flow: Flow, run: string): RunView {
	return { flow: flow.name, run, steps: flow.steps.map((s) => ({ id: s.id, model: s.model, state: "pending", entries: [] })), deviations: 0 };
}

/** A tool call's short arguments, as Pi's own line shows them; redacted (A21). */
export function shortArgs(name: string, args: unknown): string {
	const a = (args && typeof args === "object" ? args : {}) as Record<string, unknown>;
	let text: string;
	if (name === "bash" && typeof a.command === "string") text = a.command;
	else if (typeof a.path === "string") text = a.path;
	else if (typeof a.pattern === "string") text = a.pattern;
	else text = Object.keys(a).sort().join(", ");
	text = redact(text).replace(/\s+/g, " ").trim();
	return text.length > 80 ? `${text.slice(0, 79)}…` : text;
}

/** Adds one child event to its step; returns true when the view changed. */
export function viewEvent(step: StepView, event: Record<string, unknown>): boolean {
	if (event.type === "tool_execution_start" && typeof event.toolName === "string") {
		step.entries.push({ kind: "tool", id: String(event.toolCallId ?? ""), name: event.toolName, args: shortArgs(event.toolName, event.args), status: "running" });
		return true;
	}
	if (event.type === "tool_execution_end") {
		const entry = [...step.entries].reverse().find((e) => e.kind === "tool" && e.id === String(event.toolCallId ?? "") && e.status === "running");
		if (entry && entry.kind === "tool") entry.status = event.isError ? "error" : "ok";
		return Boolean(entry);
	}
	if (event.type !== "message_end") return false;
	const message = event.message as Record<string, unknown> | undefined;
	if (message?.role !== "assistant") return false;
	const usage = (message.usage ?? {}) as Record<string, unknown>;
	if (typeof usage.input === "number" || typeof usage.output === "number")
		step.tokens = (step.tokens ?? 0) + (Number(usage.input) || 0) + (Number(usage.output) || 0);
	const content = Array.isArray(message.content) ? message.content : [];
	const text = content.filter((p) => p?.type === "text" && typeof p.text === "string").map((p) => p.text as string).join("\n").trim();
	if (text) step.entries.push({ kind: "text", text: redact(text) });
	return true;
}

function count(tokens: number): string {
	return tokens >= 1_000_000 ? `${(tokens / 1_000_000).toFixed(1)}M` : tokens >= 1000 ? `${Math.round(tokens / 1000)}k` : String(tokens);
}

const MARK: Record<StepState, string> = { pending: "○", running: "●", done: "✓", failed: "✗" };

/** `1 plan ✓ m 12k  2 code ● 3k  3 checks ○   ⚠ 1   alt+1…3 view`: model's last name part, tokens. */
export function rowLine(view: RunView, keys: string[]): string {
	const parts = view.steps.map((s, i) => [`${i + 1} ${s.id} ${MARK[s.state]}`, s.state === "pending" ? "" : s.model.split("/").pop() ?? "",
		s.tokens !== undefined ? count(s.tokens) : ""].filter(Boolean).join(" "));
	let line = parts.join("  ");
	if (view.deviations > 0) line += `   ⚠ ${view.deviations}`;
	line += keys.length > 0 ? `   ${keys[0]}${keys.length > 1 ? `…${keys[keys.length - 1].split("+").pop()}` : ""} view` : "   /flow show <n>";
	return line;
}

/** The overlay's lines for step n (1-based). */
export function overlayLines(view: RunView, n: number): string[] {
	const step = view.steps[n - 1];
	if (!step) return [`Flow ${view.flow} has no step ${n}.`];
	const lines = [`Flow ${view.flow} · step ${n} ${step.id} ${MARK[step.state]} · ${step.model}${step.tokens !== undefined ? ` · ${count(step.tokens)} tokens` : ""}`, ""];
	if (step.entries.length === 0) lines.push(step.state === "pending" ? "Not started." : "No events in this Pi yet.");
	for (const e of step.entries) {
		if (e.kind === "tool") lines.push(`${e.status === "running" ? "…" : e.status === "ok" ? "✓" : "✗"} ${e.name} ${e.args}`.trimEnd());
		else lines.push(...e.text.split("\n"));
	}
	lines.push("", "Esc closes");
	return lines;
}

/** Pi 1.0.4's default keys (core/keybindings.js and pi-tui's keybindings.js, the installed copy):
 * the step shortcuts must not take one of them. */
export const BUILTIN_KEYS = new Set([
	"alt+b", "alt+backspace", "alt+d", "alt+delete", "alt+down", "alt+enter", "alt+f", "alt+left", "alt+p", "alt+q", "alt+right", "alt+up",
	"alt+v", "alt+y", "alt+z", "backspace", "ctrl+-", "ctrl+a", "ctrl+b", "ctrl+backspace", "ctrl+c", "ctrl+d", "ctrl+down", "ctrl+e", "ctrl+f",
	"ctrl+g", "ctrl+k", "ctrl+l", "ctrl+left", "ctrl+n", "ctrl+o", "ctrl+p", "ctrl+q", "ctrl+r", "ctrl+right", "ctrl+s", "ctrl+shift+down",
	"ctrl+shift+f", "ctrl+shift+up", "ctrl+t", "ctrl+u", "ctrl+up", "ctrl+v", "ctrl+w", "ctrl+x", "ctrl+y", "ctrl+z", "delete", "down", "end",
	"enter", "escape", "home", "left", "right", "shift+ctrl+o", "shift+ctrl+p", "shift+enter", "shift+l", "shift+t", "shift+tab", "tab", "up",
	"ctrl+shift+n", "ctrl+shift+t", "alt+shift+t", "ctrl+alt+]", "ctrl+]", "ctrl+shift+g", "ctrl+home", "ctrl+end",
]);

/** `alt+1` … `alt+9`, without the keys Pi or the user's keybindings.json already use (a clash
 * means no shortcut for that step; `/flow show` still works). */
export function pickShortcuts(steps: number, taken: Iterable<string>): string[] {
	const used = new Set([...BUILTIN_KEYS, ...[...taken].map((k) => k.toLowerCase())]);
	const keys: string[] = [];
	for (let n = 1; n <= Math.min(steps, 9); n++) if (!used.has(`alt+${n}`)) keys.push(`alt+${n}`);
	return keys;
}
