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
/** Why a run ended. `no-handoff`, `check-refused` and `commit-failed` come from the runner, never from `nextStep`. */
export type Stop = "done" | "visit-cap" | "no-route" | "unknown-step" | "no-handoff" | "check-refused" | "commit-failed";

export interface FlowStep {
	id: string;
	/** Left out: Pi. "claude-code": the step runs as `claude -p`, read only (F21). */
	harness?: string;
	agent: string;
	model: string;
	thinking?: string;
	/** What the step does, in the model's words (the Feature template's come from PurpleFlow). */
	prompt?: string;
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

/** The fallback when a step ended without `flow_handoff` (a deviation): the outcome from a last
 * line `outcome: failed[:reason]` of the child's answer, or undefined without one. */
export function parseOutcome(text: string): { outcome: Outcome; reason: string } | undefined {
	for (const line of text.split("\n").reverse()) {
		const m = /^\s*outcome:\s*(done|failed|blocked)(?::\s*([\w.-]+))?\s*$/i.exec(line);
		if (m) return { outcome: m[1].toLowerCase() as Outcome, reason: m[2] ?? "" };
	}
	return undefined;
}

/** OMC's verify-command rules, as AKit's check (FlowCheck.isSafeCommand): at most 10 commands,
 * each a plain command of at most 120 characters. The runner checks them again (F19). */
export const MAX_CHECK_COMMANDS = 10;
export const MAX_CHECK_LENGTH = 120;

export function isSafeCommand(command: string): boolean {
	return command.length <= MAX_CHECK_LENGTH && /^[A-Za-z][A-Za-z0-9 _.:/=%@-]*$/.test(command);
}

/** Hides env-like secrets in text shown or logged (A21): `NAME=value` where the name says token,
 * key, secret, password or auth; `Authorization:` / `Bearer` values; long token-like strings
 * (GitHub, GitLab, Slack, AWS key ids); `user:pass@` in URLs; `--password X` / `-p X`. */
export function redact(text: string): string {
	return text
		.replace(/\b([a-z][a-z0-9+.-]*:\/\/)[^\s/:@]+:[^\s/@]+@/gi, "$1***@")
		.replace(/(^|\s)(--password|-p)(\s+|=)("[^"]*"|'[^']*'|\S+)/g, "$1$2$3***")
		.replace(/\b(?:AKIA|ASIA)[A-Z0-9]{16}\b/g, "***")
		.replace(/\bgithub_pat_[A-Za-z0-9_]{20,}\b/g, "***")
		.replace(/\b(Bearer|Basic)\s+[A-Za-z0-9._~+/=-]+/g, "$1 ***")
		.replace(/\b([A-Za-z0-9_]*(?:TOKEN|KEY|SECRET|PASSWORD|PASSWD|AUTH|CREDENTIALS?)[A-Za-z0-9_]*)\s*([=:])\s*("[^"]*"|'[^']*'|\S+)/gi, "$1$2***")
		.replace(/\b(?:sk|pk|ghp|gho|ghs|ghu|glpat|xox[abps])[-_][A-Za-z0-9_-]{12,}\b/g, "***");
}

/** A tester step's claim (F26): this test, in this file, proves this scenario. `name` is the
 * test's describe titles and title joined by ` › `, as the source writes them. */
export interface TestClaim {
	scenario: string;
	path: string;
	name: string;
}

/** A gate's verdict, written into the step's evidence like a check (F26). */
export interface GateResult {
	exit: number;
	tail: string[];
}

/** G1 (F26): the plan's scenarios against the agreed scenarios of its work item. Undefined when
 * the plan names neither (technical work: no gate). `agreed` is what `akit kb scenarios
 * --work-item <ID> --status agreed` gave, or the error reading it. */
export function planScenariosGate(plan: { work_item?: string; scenarios?: string[] }, agreed: string[] | { error: string }): GateResult | undefined {
	const workItem = (plan.work_item ?? "").trim();
	const scenarios = plan.scenarios ?? [];
	if (!workItem && scenarios.length === 0) return undefined;
	if (!Array.isArray(agreed)) return { exit: 1, tail: [`Can't read the agreed scenarios: ${agreed.error}`] };
	if (workItem && agreed.length === 0) {
		return { exit: 1, tail: [`No agreed scenario names ADO ${workItem}. The user accepts the task's scenarios in AKit (Knowledge → Inbox) before the task is planned.`] };
	}
	const missing = workItem ? agreed.filter((id) => !scenarios.includes(id)) : [];
	const extra = scenarios.filter((id) => !agreed.includes(id));
	const tail = [
		...(missing.length ? [`Agreed scenarios of ADO ${workItem} the plan leaves out: ${missing.join(", ")}. Plan them, or say why in open_questions and end blocked.`] : []),
		...(extra.length ? [`Plan scenarios that are not agreed${workItem ? ` for ADO ${workItem}` : ""}: ${extra.join(", ")}. Only agreed scenarios count; propose a new one with akit kb propose and wait for the user.`] : []),
	];
	return tail.length ? { exit: 1, tail } : { exit: 0, tail: [`The plan covers the agreed scenarios${workItem ? ` of ADO ${workItem}` : ""}: ${scenarios.join(", ")}.`] };
}

/** G2 (F26): the tester's claims. Each plan scenario has a claimed test; each claimed test is in a
 * file the step changed and the file has every part of its name. `read` gives a worktree file's text. */
export function testClaimsGate(scenarios: string[], claims: TestClaim[], changed: Set<string>, read: (path: string) => string | undefined): GateResult {
	const tail: string[] = [];
	const unclaimed = scenarios.filter((id) => !claims.some((c) => c.scenario === id));
	if (unclaimed.length) tail.push(`Scenarios of the plan with no test in your handoff's tests: ${unclaimed.join(", ")}.`);
	for (const claim of claims) {
		if (!scenarios.includes(claim.scenario)) tail.push(`${claim.scenario} is not a scenario of the plan (${scenarios.join(", ") || "none"}).`);
		if (!changed.has(claim.path)) {
			tail.push(`${claim.path} (test of ${claim.scenario}) is not among the files this step changed.`);
			continue;
		}
		const text = read(claim.path) ?? "";
		const missing = claim.name.split("›").map((p) => p.trim()).filter((p) => p && !text.includes(p));
		if (missing.length) tail.push(`${claim.path} has no ${missing.map((p) => `“${p}”`).join(", ")} (test of ${claim.scenario}); write the name as the source does.`);
	}
	return tail.length ? { exit: 1, tail } : { exit: 0, tail: [`Every plan scenario has its test: ${claims.map((c) => `${c.scenario} → ${c.path} › ${c.name}`).join("; ")}.`] };
}

/** G2 (F26): the plan's check run after the tester, before any code: it must be red. A check that
 * couldn't run (no exit code, or 127: not found) proves nothing either. */
export function redFirstGate(check: string, exit: number | null, tail: string[]): GateResult {
	if (!check) return { exit: 1, tail: ["The plan has no check command, so the new tests can't be shown red."] };
	if (exit === null || exit === 127) return { exit: 1, tail: [`${check} did not run (exit ${exit}).`, ...tail] };
	if (exit === 0) return { exit: 1, tail: [`${check} passes before the code: the new tests don't test the new behaviour yet, or it exists already. Make them fail first.`] };
	return { exit: 0, tail: [`${check} is red before the code (exit ${exit}), as it should be.`] };
}

/** G3 (F26): the tester's test files are as the tester left them. `hashes` from the tester's
 * handoff, `now` the files' hashes now (undefined: the file is gone). */
export function testsUnchangedGate(hashes: Record<string, string>, now: (path: string) => string | undefined): GateResult {
	const changed = Object.keys(hashes).filter((path) => now(path) !== hashes[path]);
	return changed.length
		? { exit: 1, tail: [`Tests the tester step wrote were changed after it: ${changed.join(", ")}. Tests change only in the tester step; restore them and fix the code instead.`] }
		: { exit: 0, tail: [`The tester's tests are unchanged: ${Object.keys(hashes).join(", ")}.`] };
}
