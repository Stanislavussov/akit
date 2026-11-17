// pi-adapter.ts: written by AKit (docs/design/flows.md F20). The only file that talks to Pi: the
// `pi` command (version, features, child runs) and the extension API. A Pi change touches only this.
//
// The child spawn and the JSON event parsing are adapted from Pi's example extension
// examples/extensions/subagent/index.ts (@earendil-works/pi-coding-agent 1.5.2, MIT licence,
// Copyright (c) Mario Zechner and contributors). Changes: own flags (no -p, no --no-session),
// stdin /dev/null, own process group killed as a group, unknown fields kept as unknown.

import { execFile, spawn } from "node:child_process";
import { existsSync, readdirSync } from "node:fs";
import { readFile } from "node:fs/promises";
import type { ExtensionAPI, ExtensionCommandContext, ExtensionContext } from "@earendil-works/pi-coding-agent";

export type { ExtensionAPI, ExtensionCommandContext, ExtensionContext };

/** The Pi command; tests put a fake `pi` first on PATH. */
export const PI = process.env.AKIT_FLOW_PI ?? "pi";

/** Flags the runner needs; without one the run refuses (F20). */
export const REQUIRED_FLAGS = ["--mode", "--session-dir", "--no-skills", "--skill", "--no-extensions", "--extension", "--model"] as const;
/** Flags with a fallback: `--thinking` → `--model M:<level>`, `--tools` → left out (the guard enforces). */
export const OPTIONAL_FLAGS = ["--thinking", "--tools"] as const;

export interface PiInfo {
	version: string | undefined;
	/** Flag → found in `pi --help`. */
	features: Record<string, boolean>;
	/** Extension API features found at load. */
	api: Record<string, boolean>;
}

function run(command: string, args: string[]): Promise<{ code: number | null; stdout: string; stderr: string }> {
	return new Promise((resolve) => {
		execFile(command, args, { timeout: 20_000, maxBuffer: 4 * 1024 * 1024 }, (error, stdout, stderr) => {
			const code = error ? (typeof (error as { code?: unknown }).code === "number" ? (error as { code: number }).code : null) : 0;
			resolve({ code, stdout: String(stdout), stderr: String(stderr) });
		});
	});
}

/** `pi --version` and the flags in `pi --help`; features are checked, not guessed from the version. */
export async function detectPi(ctx?: ExtensionContext): Promise<PiInfo> {
	const version = await run(PI, ["--version"]);
	const help = await run(PI, ["--help"]);
	const match = /(\d+\.\d+\.\d+[\w.-]*)/.exec(version.stdout + version.stderr);
	const text = help.stdout + help.stderr;
	const features: Record<string, boolean> = {};
	for (const flag of [...REQUIRED_FLAGS, ...OPTIONAL_FLAGS]) {
		features[flag] = new RegExp(`(^|[\\s,])${flag.replace(/-/g, "\\-")}(?=[\\s,=<]|$)`, "m").test(text);
	}
	const ui = ctx?.ui as unknown as Record<string, unknown> | undefined;
	const api: Record<string, boolean> = {
		setWidget: typeof ui?.setWidget === "function",
		setStatus: typeof ui?.setStatus === "function",
		confirm: typeof ui?.confirm === "function",
		editor: typeof ui?.editor === "function",
		custom: typeof ui?.custom === "function",
	};
	return { version: version.code === 0 && match ? match[1] : undefined, features, api };
}

/** The required flags this Pi lacks. */
export function missingFlags(info: PiInfo): string[] {
	return REQUIRED_FLAGS.filter((flag) => !info.features[flag]);
}

/** Reads a flow file. Pi ships the `yaml` package; without it the file must be JSON (JSON is YAML). */
export async function readFlowFile(path: string): Promise<unknown> {
	const text = await readFile(path, "utf8");
	try {
		const name = "yaml";
		const yaml = (await import(name)) as { parse: (text: string) => unknown };
		return yaml.parse(text);
	} catch {
		return JSON.parse(text);
	}
}

export interface ChildOptions {
	cwd: string;
	sessionDir: string;
	model: string;
	thinking?: string;
	skills: string[];
	tools: string[];
	/** `-e` paths: the guard, akit-record, the step's own list (F15). */
	extensions: string[];
	prompt: string;
	info: PiInfo;
	/** Added to the child's environment (AKIT_FLOW_HANDOFF). */
	env?: Record<string, string>;
	signal?: AbortSignal;
}

/** The child command (flows.md, "Child command form"); no `-p`, the task is the prompt argument. */
export function childArgs(o: ChildOptions): string[] {
	const args = ["--mode", "json", "--session-dir", o.sessionDir, "-ns"];
	for (const skill of o.skills) args.push("--skill", skill);
	args.push("-ne");
	for (const ext of o.extensions) args.push("-e", ext);
	if (o.thinking && o.info.features["--thinking"]) args.push("--model", o.model, "--thinking", o.thinking);
	else args.push("--model", o.thinking ? `${o.model}:${o.thinking}` : o.model);
	// `-t` is a hint (the guard enforces); it would also hide the runner's own flow_handoff.
	if (o.tools.length > 0 && o.info.features["--tools"]) args.push("-t", [...o.tools, "flow_handoff"].join(","));
	args.push("--", o.prompt);
	return args;
}

/** A token field Pi did not give is undefined (unknown), never zero (F20). */
export interface Tokens {
	input?: number;
	output?: number;
	cacheRead?: number;
	cost?: number;
}

export interface ChildResult {
	code: number | null;
	signal: string | null;
	aborted: boolean;
	spawnError?: string;
	/** The session id from the child's session header, when Pi gave one. */
	session?: string;
	/** The last assistant text. */
	text: string;
	tokens: Tokens;
	/** Event types this runner does not know, counted. */
	unknownEvents: number;
	badLines: number;
	stderr: string;
	pid?: number;
}

function add(total: number | undefined, value: unknown): number | undefined {
	return typeof value === "number" && total !== undefined ? total + value : undefined;
}

/** Tolerant reader of Pi's JSON events: known types are parsed, the rest counted. */
export function readEvent(line: string, result: ChildResult, seen: { assistant: boolean }): void {
	if (!line.trim()) return;
	let event: Record<string, unknown>;
	try {
		const parsed = JSON.parse(line) as unknown;
		if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) throw new Error("not an object");
		event = parsed as Record<string, unknown>;
	} catch {
		result.badLines++;
		return;
	}
	if (event.type === "session") {
		if (typeof event.id === "string") result.session = event.id;
		return;
	}
	if (event.type !== "message_end") {
		if (typeof event.type !== "string" || !KNOWN_EVENTS.has(event.type)) result.unknownEvents++;
		return;
	}
	const message = event.message as Record<string, unknown> | undefined;
	if (!message || message.role !== "assistant") return;
	const usage = (message.usage ?? {}) as Record<string, unknown>;
	const cost = usage.cost as Record<string, unknown> | number | undefined;
	if (!seen.assistant) {
		seen.assistant = true;
		result.tokens = { input: 0, output: 0, cacheRead: 0, cost: 0 };
	}
	result.tokens.input = add(result.tokens.input, usage.input);
	result.tokens.output = add(result.tokens.output, usage.output);
	result.tokens.cacheRead = add(result.tokens.cacheRead, usage.cacheRead);
	result.tokens.cost = add(result.tokens.cost, typeof cost === "number" ? cost : cost?.total);
	const content = message.content;
	if (Array.isArray(content)) {
		const text = content
			.filter((part): part is { type: string; text: string } => part?.type === "text" && typeof part.text === "string")
			.map((part) => part.text)
			.join("\n");
		if (text) result.text = text;
	} else if (typeof content === "string") {
		result.text = content;
	}
}

const KNOWN_EVENTS = new Set([
	"agent_start", "agent_end", "turn_start", "turn_end", "message_start", "message_update",
	"tool_execution_start", "tool_execution_update", "tool_execution_end", "auto_compaction_start",
	"auto_compaction_end", "auto_retry_start", "auto_retry_end",
]);

/** Starts one child in its own process group; stdin is /dev/null; abort kills the whole group. */
export function runChild(o: ChildOptions): Promise<ChildResult> {
	const result: ChildResult = { code: null, signal: null, aborted: false, text: "", tokens: {}, unknownEvents: 0, badLines: 0, stderr: "" };
	const seen = { assistant: false };
	return new Promise((resolve) => {
		let buffer = "";
		let settled = false;
		let killTimer: ReturnType<typeof setTimeout> | undefined;
		const finish = () => {
			if (settled) return;
			settled = true;
			if (killTimer) clearTimeout(killTimer);
			o.signal?.removeEventListener("abort", abort);
			resolve(result);
		};
		const proc = spawn(PI, childArgs(o), {
			cwd: o.cwd, shell: false, detached: true, stdio: ["ignore", "pipe", "pipe"], env: { ...process.env, ...o.env },
		});
		result.pid = proc.pid;
		const killGroup = (sig: NodeJS.Signals) => {
			if (proc.pid === undefined) return;
			try {
				process.kill(-proc.pid, sig);
			} catch {
				// The group is gone already.
			}
		};
		function abort() {
			if (proc.exitCode !== null || proc.signalCode !== null) return;
			result.aborted = true;
			killGroup("SIGTERM");
			killTimer = setTimeout(() => killGroup("SIGKILL"), 5000);
		}
		proc.stdout.on("data", (data: Buffer) => {
			buffer += data.toString();
			const lines = buffer.split("\n");
			buffer = lines.pop() ?? "";
			for (const line of lines) readEvent(line, result, seen);
		});
		proc.stderr.on("data", (data: Buffer) => {
			result.stderr = (result.stderr + data.toString()).slice(-8000);
		});
		proc.on("close", (code, signal) => {
			if (buffer.trim()) readEvent(buffer, result, seen);
			result.code = code;
			result.signal = signal;
			finish();
		});
		proc.on("error", (error) => {
			result.spawnError = error.message;
			finish();
		});
		if (o.signal) {
			if (o.signal.aborted) abort();
			else o.signal.addEventListener("abort", abort, { once: true });
		}
	});
}

/** The child's session file in its --session-dir: Pi names it `<time>_<session id>.jsonl`. */
export function sessionFile(sessionDir: string, session: string | undefined): string | undefined {
	if (!session || !existsSync(sessionDir)) return undefined;
	return readdirSync(sessionDir).find((name) => name.endsWith(".jsonl") && name.includes(session));
}

/** Extension API calls the runner makes. */
export function registerFlowCommand(pi: ExtensionAPI, handler: (args: string, ctx: ExtensionCommandContext) => Promise<void>): void {
	pi.registerCommand("flow", {
		description: "Run an AKit flow: /flow [name] <task>, /flow resume",
		handler,
	});
}

/** The tool `akit_flow`: the model may start a flow when the user asks in words (F11). */
export function registerStartTool(pi: ExtensionAPI, handler: (params: { flow?: string; task: string }, ctx: ExtensionContext) => Promise<string>): void {
	pi.registerTool({
		name: "akit_flow",
		label: "AKit flow",
		description: "Start an AKit flow (a fixed chain of agent steps) when the user asks for one in words, e.g. \"do it by the Feature flow\". The user is asked to confirm first.",
		parameters: {
			type: "object",
			properties: {
				flow: { type: "string", description: "The flow's name; leave out for the project's default flow." },
				task: { type: "string", description: "The task for the flow, as the user said it." },
			},
			required: ["task"],
			additionalProperties: false,
		},
		async execute(_id, params, _signal, _update, ctx) {
			return { content: [{ type: "text", text: await handler(params as { flow?: string; task: string }, ctx) }], details: undefined };
		},
	});
}

export function onShutdown(pi: ExtensionAPI, handler: () => void): void {
	pi.on("session_shutdown", () => handler());
}

export function say(ctx: ExtensionContext, message: string, level: "info" | "warning" | "error" = "info"): void {
	if (typeof ctx.ui?.notify === "function") ctx.ui.notify(message, level);
}

export function status(ctx: ExtensionContext, text: string | undefined): void {
	if (typeof ctx.ui?.setStatus === "function") ctx.ui.setStatus("akit-flow", text);
}
