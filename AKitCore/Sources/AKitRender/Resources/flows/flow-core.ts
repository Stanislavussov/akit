// flow-core.ts: written by AKit (docs/design/flows.md F1, F19). Pure: no Pi, no files.
// Route lookup, visits and the next state. Same answers as Swift's FlowRouting.next; both run
// the golden vectors in fixtures/flow-vectors.

/** The `akit-flow-format` this runner reads. A newer flow file means "run Apply in AKit" (F20). */
export const FLOW_FORMAT = 1;
/** The lowest Pi the runner supports, and the highest one the tests passed on (F20). */
export const MIN_PI = "1.0.4";
export const TESTED_PI = "1.0.4";
/** The reserved route target that ends the run. */
export const END = "end";
export const DEFAULT_MAX_LOOPS = 3;

export type Outcome = "done" | "failed" | "blocked";
export type Stop = "done" | "visit-cap" | "no-route" | "unknown-step";

export interface FlowStep {
	id: string;
	agent: string;
	model: string;
	thinking?: string;
	skills?: string[];
	tools?: string[];
	paths?: string[];
	bash?: boolean;
	extensions?: string[];
	gate?: boolean;
	checks?: string[];
	maxLoops?: number;
	routes?: Record<string, string>;
}

export interface Flow {
	"akit-flow-format": number;
	name: string;
	minPi?: string;
	tools?: string[];
	steps: FlowStep[];
}

export type Visits = Record<string, number>;

export interface RunState {
	/** The step that just ended. */
	step: string;
	/** How often each step has started. */
	visits: Visits;
}

export type Decision =
	| { next: string; visits: Visits }
	| { stop: Stop; step?: string; visits: Visits };

export function isOutcome(value: unknown): value is Outcome {
	return value === "done" || value === "failed" || value === "blocked";
}

/** `outcome:reason`, then `outcome:*`; a `done` without a route goes to the next step (the end after
 * the last); `failed` and `blocked` need a route; a target over its `maxLoops` stops. */
export function nextStep(flow: Flow, state: RunState, outcome: Outcome, reason = ""): Decision {
	const index = flow.steps.findIndex((s) => s.id === state.step);
	if (index < 0) return { stop: "unknown-step", step: state.step, visits: state.visits };
	const routes = flow.steps[index].routes ?? {};
	let target: string;
	const exact = reason ? routes[`${outcome}:${reason}`] : undefined;
	if (exact !== undefined) target = exact;
	else if (routes[`${outcome}:*`] !== undefined) target = routes[`${outcome}:*`];
	else if (outcome === "done") target = index + 1 < flow.steps.length ? flow.steps[index + 1].id : END;
	else return { stop: "no-route", step: state.step, visits: state.visits };
	if (target === END) return { stop: "done", visits: state.visits };
	const next = flow.steps.find((s) => s.id === target);
	if (!next) return { stop: "unknown-step", step: target, visits: state.visits };
	const count = (state.visits[target] ?? 0) + 1;
	if (count > (next.maxLoops ?? DEFAULT_MAX_LOOPS)) return { stop: "visit-cap", step: target, visits: state.visits };
	return { next: target, visits: { ...state.visits, [target]: count } };
}

/** The first step of a run, with its first visit. */
export function firstStep(flow: Flow): Decision {
	const first = flow.steps[0];
	if (!first) return { stop: "done", visits: {} };
	return { next: first.id, visits: { [first.id]: 1 } };
}

/** Compares dotted versions ("1.0.4" < "1.10.0"); a pre-release tail is ignored. */
export function compareVersions(a: string, b: string): number {
	const parts = (v: string) => v.replace(/^v/, "").split(/[-+ ]/)[0].split(".").map((n) => Number.parseInt(n, 10) || 0);
	const x = parts(a);
	const y = parts(b);
	for (let i = 0; i < Math.max(x.length, y.length); i++) {
		const d = (x[i] ?? 0) - (y[i] ?? 0);
		if (d !== 0) return d < 0 ? -1 : 1;
	}
	return 0;
}

/** Why a flow file can't run with this runner, or undefined. */
export function formatProblem(flow: Flow): string | undefined {
	const format = flow["akit-flow-format"];
	if (typeof format !== "number") return `The flow ${flow.name ?? "?"} has no akit-flow-format; run Apply in AKit.`;
	if (format > FLOW_FORMAT)
		return `The flow ${flow.name} has akit-flow-format ${format}, newer than this runner (${FLOW_FORMAT}); run Apply in AKit.`;
	if (!Array.isArray(flow.steps) || flow.steps.length === 0) return `The flow ${flow.name} has no steps.`;
	return undefined;
}

/** The lowest Pi a flow needs: the flow's own minPi or the runner's, whichever is higher. */
export function requiredPi(flow: Flow): string {
	return flow.minPi && compareVersions(flow.minPi, MIN_PI) > 0 ? flow.minPi : MIN_PI;
}

/** A run id `YYYYMMDD-HHMM-xxxx` (local time, 4 hex). */
export function runId(now: Date, hex: string): string {
	const p = (n: number) => String(n).padStart(2, "0");
	return `${now.getFullYear()}${p(now.getMonth() + 1)}${p(now.getDate())}-${p(now.getHours())}${p(now.getMinutes())}-${hex.slice(0, 4)}`;
}

/** Reads the step's outcome from the child's last answer: a line `outcome: failed[:reason]`.
 * Without such a line, exit 0 is `done` and anything else `failed`. Phase 2b replaces this with the
 * `flow_handoff` tool. */
export function parseOutcome(text: string, exitCode: number | null): { outcome: Outcome; reason: string } {
	const lines = text.split("\n").reverse();
	for (const line of lines) {
		const m = /^\s*outcome:\s*(done|failed|blocked)(?::\s*([\w.-]+))?\s*$/i.exec(line);
		if (m) return { outcome: m[1].toLowerCase() as Outcome, reason: m[2] ?? "" };
	}
	return exitCode === 0 ? { outcome: "done", reason: "" } : { outcome: "failed", reason: "exit" };
}
