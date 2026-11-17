// flow-record.ts: written by AKit (docs/design/flows.md F4, F9). The run record in
// <main checkout>/.pi/akit-flow/runs/<run-id>/: events.jsonl (the truth, append-only), run.json
// (a cache, written atomically), handoffs/, evidence/, sessions/, lock. AKit's FlowRun reader reads it.

import { spawn } from "node:child_process";
import { appendFileSync, existsSync, mkdirSync, readdirSync, readFileSync, renameSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import type { Outcome, Visits } from "./flow-core.ts";
import type { Tokens } from "./pi-adapter.ts";

export const RUN_SCHEMA = "akit-flow-run/1";
export const EVENT_SCHEMA = "akit-flow-event/1";
export const HANDOFF_SCHEMA = "akit-flow-handoff/1";
export const EVIDENCE_SCHEMA = "akit-flow-evidence/1";
/** Lines of a check's output kept in its evidence file. */
export const EVIDENCE_LINES = 40;

export function runsFolder(mainCheckout: string): string {
	return join(mainCheckout, ".pi", "akit-flow", "runs");
}

/** Token fields in the record's names; an unknown field stays out (null), never zero. */
export function recordTokens(t: Tokens): Record<string, number | null> {
	return { input: t.input ?? null, output: t.output ?? null, cache_read: t.cacheRead ?? null, cost: t.cost ?? null };
}

export function writeAtomic(path: string, value: unknown): void {
	const tmp = `${path}.tmp-${process.pid}`;
	writeFileSync(tmp, `${JSON.stringify(value, null, 2)}\n`);
	renameSync(tmp, path);
}

export function appendEvent(folder: string, type: string, fields: Record<string, unknown>): void {
	const line = { schema: EVENT_SCHEMA, type, time: new Date().toISOString(), ...fields };
	appendFileSync(join(folder, "events.jsonl"), `${JSON.stringify(line)}\n`);
}

export interface RecordedEvent {
	type?: string;
	step?: string;
	attempt?: number;
	outcome?: Outcome;
	reason?: string;
	flow?: string;
	task?: string;
	[key: string]: unknown;
}

/** events.jsonl read tolerantly: lines that are not JSON objects are skipped. */
export function readEvents(folder: string): RecordedEvent[] {
	const path = join(folder, "events.jsonl");
	if (!existsSync(path)) return [];
	const events: RecordedEvent[] = [];
	for (const line of readFileSync(path, "utf8").split("\n")) {
		if (!line.trim()) continue;
		try {
			const value = JSON.parse(line) as unknown;
			if (value && typeof value === "object" && !Array.isArray(value)) events.push(value as RecordedEvent);
		} catch {
			// A torn last line after a crash; the events before it hold.
		}
	}
	return events;
}

/** Visits per step, counted from step-start events (as AKit's reader does). */
export function visitsFrom(events: RecordedEvent[]): Visits {
	const visits: Visits = {};
	for (const e of events) if (e.type === "step-start" && e.step) visits[e.step] = (visits[e.step] ?? 0) + 1;
	return visits;
}

function alive(pid: number): boolean {
	try {
		process.kill(pid, 0);
		return true;
	} catch (error) {
		return (error as NodeJS.ErrnoException).code === "EPERM";
	}
}

/** Takes the run's lock; refuses (returns the holder's pid) when another live process holds it. */
export function takeLock(folder: string): number | undefined {
	const path = join(folder, "lock");
	if (existsSync(path)) {
		const pid = Number.parseInt(readFileSync(path, "utf8").trim(), 10);
		if (Number.isFinite(pid) && pid !== process.pid && alive(pid)) return pid;
	}
	writeFileSync(path, `${process.pid}\n`);
	return undefined;
}

export function releaseLock(folder: string): void {
	const path = join(folder, "lock");
	if (existsSync(path) && readFileSync(path, "utf8").trim() === String(process.pid)) rmSync(path);
}

export function createRunFolder(mainCheckout: string, id: string): string {
	const folder = join(runsFolder(mainCheckout), id);
	mkdirSync(join(folder, "sessions"), { recursive: true });
	mkdirSync(join(folder, "handoffs"), { recursive: true });
	mkdirSync(join(folder, "evidence"), { recursive: true });
	return folder;
}

/** Run ids start with date and time, so the newest sorts last. */
export function latestRun(mainCheckout: string): string | undefined {
	const root = runsFolder(mainCheckout);
	if (!existsSync(root)) return undefined;
	const names = readdirSync(root).filter((n) => !n.startsWith(".")).sort();
	return names.length ? join(root, names[names.length - 1]) : undefined;
}

export function handoffName(index: number, step: string, attempt: number, session: string | undefined): string {
	return `${String(index + 1).padStart(2, "0")}-${step}-a${attempt}-${session ?? "no-session"}.json`;
}

/** `NN-<step>`: the step's number in the flow and its id. */
export function stepKey(index: number, step: string): string {
	return `${String(index + 1).padStart(2, "0")}-${step}`;
}

export interface CheckResult {
	command: string;
	exit: number | null;
	/** The last EVIDENCE_LINES lines of stdout and stderr together. */
	tail: string[];
}

/** One check command, run by the runner (never the model), split on spaces and started without a
 * shell: AKit's rule allows no shell syntax anyway. */
function runCheck(command: string, cwd: string, signal?: AbortSignal): Promise<CheckResult> {
	return new Promise((resolve) => {
		const [file, ...args] = command.split(/\s+/).filter(Boolean);
		let output = "";
		const keep = (data: Buffer) => {
			output = (output + data.toString()).slice(-64_000);
		};
		const proc = spawn(file, args, { cwd, shell: false, stdio: ["ignore", "pipe", "pipe"], signal, timeout: 30 * 60_000 });
		proc.stdout.on("data", keep);
		proc.stderr.on("data", keep);
		proc.on("error", (error) => {
			output += `${error.message}\n`;
		});
		proc.on("close", (code) => {
			const lines = output.replace(/\n$/, "").split("\n");
			resolve({ command, exit: code, tail: output ? lines.slice(-EVIDENCE_LINES) : [] });
		});
	});
}

/** Runs a step's checks in `cwd` and writes `evidence/NN-<step>-aN-checks.json`, one file per attempt (F19). */
export async function runChecks(folder: string, key: string, run: string, step: { id: string; attempt: number }, commands: string[],
	cwd: string, signal?: AbortSignal): Promise<string> {
	const checks: CheckResult[] = [];
	for (const command of commands) checks.push(await runCheck(command, cwd, signal));
	const path = join(folder, "evidence", `${key}-a${step.attempt}-checks.json`);
	writeAtomic(path, { schema: EVIDENCE_SCHEMA, run, step, time: new Date().toISOString(), checks });
	return path;
}

/** A step's checks are green only with an evidence file whose every command exited 0. */
export function checksGreen(path: string): boolean {
	try {
		const value = JSON.parse(readFileSync(path, "utf8")) as { schema?: string; checks?: CheckResult[] };
		return value.schema === EVIDENCE_SCHEMA && Array.isArray(value.checks) && value.checks.length > 0 && value.checks.every((c) => c.exit === 0);
	} catch {
		return false;
	}
}
