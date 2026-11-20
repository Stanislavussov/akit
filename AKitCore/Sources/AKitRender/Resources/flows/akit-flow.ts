// akit-flow.ts: written by AKit (docs/design/flows.md F1, F11). The Pi extension that runs a flow:
// `/flow [name] <task>` and `/flow resume [run-id]`. Thin: routing is in flow-core.ts, every Pi
// call in pi-adapter.ts, the record in flow-record.ts; each child gets akit-flow-handoff.ts. Flows come from <project>/.pi/flows, then
// ~/.pi/agent/flows.

import { execFileSync } from "node:child_process";
import { randomBytes, randomUUID } from "node:crypto";
import { existsSync, mkdirSync, readdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { basename, dirname, isAbsolute, join } from "node:path";
import { fileURLToPath } from "node:url";
import {
	compareVersions, type Decision, DEFAULT_MAX_LOOPS, firstStep, type Flow, formatProblem, isOutcome, isSafeCommand, MAX_CHECK_COMMANDS, nextStep,
	type FlowStep, type Outcome, parseOutcome, redact, requiredPi, runId, TESTED_PI, type Visits,
} from "./flow-core.ts";
import { DEFAULT_TOOLS, type GuardRules } from "./akit-flow-guard.ts";
import { projectRules, runClaudeChild } from "./claude-adapter.ts";
import { changedFiles, changes, commit, createWorktree, diffFromBase, flowCommits, resetTo, type Worktree, worktreeExists } from "./flow-git.ts";
import {
	appendEvent, checksGreen, createRunFolder, HANDOFF_SCHEMA, handoffName, latestRun, readEvents, type RecordedEvent, recordTokens, releaseLock,
	RUN_SCHEMA, runChecks, stepKey, takeLock, visitsFrom, writeAtomic,
} from "./flow-record.ts";
import {
	type ChildResult, detectPi, type ExtensionAPI, type ExtensionContext, missingFlags, onShutdown, type PiInfo, readFlowFile,
	registerFlowCommand, registerStartTool, registerStepShortcuts, runChild, say, sessionFile, showOverlay, showRow, status, userKeys,
} from "./pi-adapter.ts";
import { newView, overlayLines, pickShortcuts, rowLine, type RunView, type StepState, viewEvent } from "./flow-view.ts";

const here = dirname(fileURLToPath(import.meta.url));
let warnedNewerPi = false;
/** This Pi process's run, as the row and the overlay show it (F18); listeners re-render an open overlay. */
let view: RunView | undefined;
let keys: string[] = [];
const listeners = new Set<() => void>();

export default function akitFlow(pi: ExtensionAPI): void {
	const controller = new AbortController();
	keys = pickShortcuts(9, userKeys());
	registerStepShortcuts(pi, keys, showStep);
	registerFlowCommand(pi, (args, ctx) => flowCommand(args, ctx, controller.signal));
	registerStartTool(pi, (params, ctx) => startTool(params, ctx, controller.signal));
	onShutdown(pi, () => controller.abort());
}

/** `/flow …`; exported for the tests. */
export async function flowCommand(args: string, ctx: ExtensionContext, signal?: AbortSignal): Promise<void> {
	const words = args.trim().split(/\s+/).filter(Boolean);
	if (words[0] === "resume") return resume(ctx, words[1], signal);
	if (words[0] === "show") return showStep(Number(words[1]), ctx);
	await start(ctx, words, signal);
}

/** `/flow show <n>` and the step shortcuts: the overlay of step n of this Pi's run. */
async function showStep(n: number, ctx: ExtensionContext): Promise<void> {
	if (!view) return say(ctx, "No flow run in this Pi yet.", "warning");
	if (!Number.isInteger(n) || n < 1 || n > view.steps.length) return say(ctx, `Usage: /flow show <1-${view.steps.length}>`, "error");
	const shown = view;
	await showOverlay(ctx, n, () => overlayLines(shown, n), (render) => {
		listeners.add(render);
		return () => listeners.delete(render);
	});
}

/** Redraws the row from the view; the deviation count comes from events.jsonl (the guard writes there too). */
function refresh(ctx: ExtensionContext, run: Run): void {
	if (!view) return;
	view.deviations = readEvents(run.folder).filter((e) => e.type === "deviation").length;
	showRow(ctx, rowLine(view, keys.filter((k) => Number(k.split("+").pop()) <= view!.steps.length)));
	for (const render of listeners) render();
}

function setStep(ctx: ExtensionContext, run: Run, id: string, state: StepState): void {
	const step = view?.steps.find((s) => s.id === id);
	if (!step) return;
	if (state === "running") {
		step.entries = [];
		step.tokens = undefined;
	}
	step.state = state;
	refresh(ctx, run);
}

/** The tool `akit_flow`: the model may start a flow when the user asks in words (F11). It always
 * asks first; without a yes it starts nothing. Exported for the tests. */
export async function startTool(params: { flow?: string; task: string }, ctx: ExtensionContext, signal?: AbortSignal): Promise<string> {
	const task = (params.task ?? "").trim();
	if (!task) return "No task given; no flow was started.";
	const name = params.flow?.trim();
	const yes = ctx.hasUI && typeof ctx.ui?.confirm === "function"
		&& await ctx.ui.confirm("Start a flow?", `The model asks to run the flow ${name ?? "(the project's default)"} for: ${task}`);
	if (!yes) return "The user did not confirm; no flow was started.";
	const words = task.split(/\s+/);
	const id = await start(ctx, name ? [name, ...words] : words, signal);
	if (!id) return "The flow did not start; the reason is shown to the user.";
	return summaries.get(id) ?? `Flow run ${id} has paused (a gate, a question or STOP); /flow resume ${id} goes on. The record is in .pi/akit-flow/runs/${id}.`;
}

function mainCheckout(cwd: string): string {
	try {
		const common = execFileSync("git", ["rev-parse", "--path-format=absolute", "--git-common-dir"], { cwd, encoding: "utf8" }).trim();
		return dirname(common);
	} catch {
		return cwd;
	}
}

function flowFolders(project: string): string[] {
	return [join(project, ".pi", "flows"), join(homedir(), ".pi", "agent", "flows")];
}

function flowNames(project: string): string[] {
	const names = new Set<string>();
	for (const folder of flowFolders(project)) {
		if (!existsSync(folder)) continue;
		for (const file of readdirSync(folder)) if (/\.ya?ml$/.test(file)) names.add(file.replace(/\.ya?ml$/, ""));
	}
	return [...names].sort();
}

function flowPath(project: string, name: string): string | undefined {
	for (const folder of flowFolders(project)) {
		for (const ext of [".yaml", ".yml"]) if (existsSync(join(folder, name + ext))) return join(folder, name + ext);
	}
	return undefined;
}

async function loadFlow(ctx: ExtensionContext, project: string, name: string): Promise<Flow | undefined> {
	const path = flowPath(project, name);
	if (!path) {
		say(ctx, `No flow "${name}" in .pi/flows or ~/.pi/agent/flows; run Apply in AKit.`, "error");
		return undefined;
	}
	let flow: Flow;
	try {
		flow = (await readFlowFile(path)) as Flow;
	} catch (error) {
		say(ctx, `Can't read ${path}: ${(error as Error).message}`, "error");
		return undefined;
	}
	const problem = formatProblem(flow);
	if (problem) {
		say(ctx, problem, "error");
		return undefined;
	}
	return flow;
}

/** The Pi checks of F11/F20: below minPi or a missing flag refuses; above testedPi warns once. */
async function checkPi(ctx: ExtensionContext, flow: Flow): Promise<{ info: PiInfo; newer: boolean } | undefined> {
	const info = await detectPi(ctx);
	const need = requiredPi(flow);
	const missing = missingFlags(info);
	if (!info.version) {
		say(ctx, "Can't read `pi --version`; the flow needs Pi " + need + " or newer.", "error");
		return undefined;
	}
	if (compareVersions(info.version, need) < 0 || missing.length > 0) {
		const parts = [`Pi ${info.version} can't run the flow ${flow.name}.`];
		if (compareVersions(info.version, need) < 0) parts.push(`It needs Pi ${need} or newer.`);
		if (missing.length > 0) parts.push(`Missing: ${missing.join(", ")}.`);
		parts.push("Update Pi.");
		say(ctx, parts.join(" "), "error");
		return undefined;
	}
	const newer = compareVersions(info.version, TESTED_PI) > 0;
	if (newer && !warnedNewerPi) {
		warnedNewerPi = true;
		say(ctx, `Pi ${info.version} is newer than ${TESTED_PI}, the newest Pi the flow runner was tested on.`, "warning");
	}
	return { info, newer };
}

interface Run {
	folder: string;
	id: string;
	flow: Flow;
	task: string;
	project: string;
	info: PiInfo;
	newer: boolean;
	started: string;
	/** The run's worktree outside the project tree, its branch and base commit (F8). */
	worktree: Worktree;
}

function writeRunJson(run: Run, fields: Record<string, unknown>): void {
	writeAtomic(join(run.folder, "run.json"), {
		schema: RUN_SCHEMA,
		id: run.id,
		flow: run.flow.name,
		task: run.task,
		project: run.project,
		worktree: run.worktree.path,
		branch: run.worktree.branch,
		base: run.worktree.base,
		pi: run.info.version,
		piFeatures: run.info.features,
		piApi: run.info.api,
		...(run.newer ? { note: `Pi ${run.info.version} is newer than testedPi ${TESTED_PI}.` } : {}),
		started: run.started,
		updated: new Date().toISOString(),
		...fields,
	});
}

async function start(ctx: ExtensionContext, words: string[], signal?: AbortSignal): Promise<string | undefined> {
	const project = mainCheckout(ctx.cwd);
	const names = flowNames(project);
	let name: string | undefined;
	if (words.length > 1 && names.includes(words[0])) name = words.shift();
	else name = names.length === 1 ? names[0] : names.includes("feature") ? "feature" : undefined;
	const task = words.join(" ");
	if (!name) {
		say(ctx, names.length ? `Say which flow: /flow <${names.join("|")}> <task>` : "No flows in .pi/flows or ~/.pi/agent/flows; run Apply in AKit.", "error");
		return;
	}
	if (!task) {
		say(ctx, "Usage: /flow [name] <task>", "error");
		return;
	}
	const flow = await loadFlow(ctx, project, name);
	if (!flow) return;
	const pi = await checkPi(ctx, flow);
	if (!pi) return;
	const id = runId(new Date(), randomBytes(2).toString("hex"));
	const worktree = createWorktree(project, id);
	if ("error" in worktree) {
		say(ctx, `Can't start the flow: ${worktree.error}`, "error");
		return;
	}
	const folder = createRunFolder(project, id);
	takeLock(folder);
	// The run keeps its own copy of the flow: a later edit doesn't change a run under way (resume asks).
	writeFileSync(join(folder, "flow.json"), `${JSON.stringify(flow, null, 2)}\n`);
	const run: Run = { folder, id, flow, task, project, info: pi.info, newer: pi.newer, started: new Date().toISOString(), worktree };
	appendEvent(folder, "run-start", { run: id, flow: flow.name, task, pi: pi.info.version, worktree: worktree.path, branch: worktree.branch, base: worktree.base });
	await loop(ctx, run, firstStep(flow), undefined, signal);
	return id;
}

/** The flow a resumed run goes on with: its own copy from the start, unless the flow file changed
 * since and the user takes the change (only when the changed flow still has every step the run
 * used). Runs from before the copy go on with the file. Undefined: the user cancelled. */
async function runFlow(ctx: ExtensionContext, folder: string, current: Flow | undefined, events: RecordedEvent[]): Promise<Flow | undefined> {
	const path = join(folder, "flow.json");
	let kept: Flow | undefined;
	try {
		kept = existsSync(path) ? (JSON.parse(readFileSync(path, "utf8")) as Flow) : undefined;
	} catch {
		kept = undefined;
	}
	if (!kept) return current;
	if (!current || JSON.stringify(current) === JSON.stringify(kept)) return kept;
	const used = new Set(events.filter((e) => (e.type === "step-start" || e.type === "step-end") && typeof e.step === "string").map((e) => String(e.step)));
	const fits = [...used].every((id) => current.steps.some((s) => s.id === id));
	if (fits && ctx.hasUI && typeof ctx.ui?.select === "function") {
		const keep = "Go on with the flow as this run started it";
		const take = "Use the changed flow from here on";
		const answer = await ctx.ui.select(`The flow ${kept.name} changed since this run started`, [keep, take]);
		if (answer === undefined) {
			say(ctx, "Resume cancelled.", "info");
			return undefined;
		}
		if (answer === take) {
			writeFileSync(path, `${JSON.stringify(current, null, 2)}\n`);
			appendEvent(folder, "flow-changed", { taken: true });
			return current;
		}
		return kept;
	}
	appendEvent(folder, "flow-changed", { taken: false });
	say(ctx, fits ? "The flow changed since this run started; the run goes on with its own copy."
		: "The flow changed since this run started and lost steps this run used; the run goes on with its own copy.", "warning");
	return kept;
}

/** The handoff file a step attempt wrote, read back for the next step's prompt. */
function readHandoff(folder: string, index: number, step: string, attempt: number): Record<string, unknown> | undefined {
	const prefix = `${stepKey(index, step)}-a${attempt}-`;
	const name = existsSync(join(folder, "handoffs")) ? readdirSync(join(folder, "handoffs")).find((n) => n.startsWith(prefix) && n.endsWith(".json")) : undefined;
	if (!name) return undefined;
	try {
		return JSON.parse(readFileSync(join(folder, "handoffs", name), "utf8")) as Record<string, unknown>;
	} catch {
		return undefined;
	}
}

/** The newest done handoff of the flow's last planner step before `stepId`: the approved plan,
 * which every later step gets next to the previous handoff, so a fix or review after checks still
 * sees what was planned. Undefined when the flow has no planner before the step or it never ended done. */
function planHandoff(folder: string, flow: Flow, stepId: string): { step: string; handoff: Record<string, unknown> } | undefined {
	const index = flow.steps.findIndex((s) => s.id === stepId);
	const plans = flow.steps.map((s, i) => ({ s, i })).filter(({ s, i }) => s.agent === "planner" && i < index);
	const plan = plans.at(-1);
	if (!plan || !existsSync(join(folder, "handoffs"))) return undefined;
	const prefix = `${stepKey(plan.i, plan.s.id)}-a`;
	const attempts = readdirSync(join(folder, "handoffs"))
		.filter((n) => n.startsWith(prefix) && n.endsWith(".json"))
		.map((n) => Number(/^\d+/.exec(n.slice(prefix.length))?.[0] ?? 0))
		.sort((a, b) => b - a);
	for (const attempt of attempts) {
		const handoff = readHandoff(folder, plan.i, plan.s.id, attempt);
		if (handoff && (handoff.from as { outcome?: unknown } | undefined)?.outcome === "done") return { step: plan.s.id, handoff };
	}
	return undefined;
}

/** What a handoff tells the next step: the model's part and the outcome, without the record's ids,
 * tokens and paths (they cost tokens and help no step). */
export function handoffForPrompt(handoff: Record<string, unknown>): Record<string, unknown> {
	const { goal, done, files, changed, open_questions, notes, from, plan } = handoff;
	const text = typeof notes === "string" && notes.length > NOTES_IN_PROMPT
		? `${notes.slice(0, NOTES_IN_PROMPT)}… (cut; the full notes are in the run record)` : notes;
	// The files git saw win over the files the model named.
	return { from, goal, done, files: Array.isArray(changed) ? changed : files, open_questions, notes: text, ...(plan ? { plan } : {}) };
}

/** The most of a handoff's notes a prompt carries; the record keeps all of them. */
export const NOTES_IN_PROMPT = 4000;

/** How a step weighs what it gets (the same words every time, so the cache keeps them). */
export const PRECEDENCE = "How to weigh what you get: the approved plan says what to build; the handoffs say what is true now, and a later handoff wins over an older one; a note from the user at a gate wins over both.";

/** One line per earlier step, oldest first: the newest attempt of each step that ended, except
 * the ones the prompt gives in full. Every step sees the whole run this way, in a few tokens. */
export function earlierSteps(run: { folder: string; flow: Flow }, skip: Set<string>): { lines: string[]; questions: string[] } {
	const latest = new Map<string, number>();
	for (const e of readEvents(run.folder)) {
		if (e.type !== "step-end" || typeof e.step !== "string") continue;
		latest.delete(e.step);
		latest.set(e.step, typeof e.attempt === "number" ? e.attempt : 1);
	}
	const lines: string[] = [];
	const questions: string[] = [];
	for (const [id, attempt] of latest) {
		const index = run.flow.steps.findIndex((s) => s.id === id);
		const h = index < 0 ? undefined : readHandoff(run.folder, index, id, attempt);
		if (!h) continue;
		for (const q of strings(h.open_questions)) if (!questions.includes(q)) questions.push(q);
		if (skip.has(id)) continue;
		const from = (h.from ?? {}) as { outcome?: string; reason?: string };
		const done = strings(h.done);
		const files = (Array.isArray(h.changed) ? h.changed : Array.isArray(h.files) ? h.files : []) as { path?: string }[];
		const line = [`- ${id} (${run.flow.steps[index].agent}, attempt ${attempt}): ${from.outcome ?? "?"}${from.reason ? `:${from.reason}` : ""}`,
			typeof h.goal === "string" && h.goal ? ` · ${h.goal}` : "",
			done.length ? ` · did: ${done.slice(0, 3).join("; ")}${done.length > 3 ? ` (+${done.length - 3})` : ""}` : "",
			files.length ? ` · files: ${files.map((f) => f.path).filter(Boolean).slice(0, 6).join(", ")}${files.length > 6 ? " …" : ""}` : ""].join("");
		lines.push(line.length > 400 ? `${line.slice(0, 400)}…` : line);
	}
	return { lines, questions };
}

function previousFrom(folder: string, flow: Flow, step: string, attempt: number): Previous | undefined {
	const handoff = readHandoff(folder, flow.steps.findIndex((s) => s.id === step), step, attempt);
	if (!handoff) return undefined;
	const from = (handoff.from ?? {}) as { outcome?: unknown; reason?: unknown };
	return { step, outcome: isOutcome(from.outcome) ? from.outcome : "failed", reason: typeof from.reason === "string" ? from.reason : "", handoff };
}

/** `/flow resume`: events.jsonl and the commit trailers are the truth; run.json is rebuilt (F9). */
async function resume(ctx: ExtensionContext, id: string | undefined, signal?: AbortSignal): Promise<void> {
	const project = mainCheckout(ctx.cwd);
	const folder = id ? join(project, ".pi", "akit-flow", "runs", id) : latestRun(project);
	if (!folder || !existsSync(folder)) {
		say(ctx, id ? `No run ${id}.` : "No run to resume.", "error");
		return;
	}
	const events = readEvents(folder);
	// A stop at a loop limit or a missing route is the user's question, not the end: resume asks it.
	const ended = [...events].reverse().find((e) => e.type === "run-end" || e.type === "resume");
	if (ended?.type === "run-end" && ended.stop !== "visit-cap" && ended.stop !== "no-route") {
		say(ctx, `Run ${folder.split("/").pop()} has finished.`, "info");
		return;
	}
	const holder = takeLock(folder);
	if (holder !== undefined) {
		say(ctx, `Run ${folder.split("/").pop()} is running in process ${holder}; resume refused.`, "error");
		return;
	}
	try {
		await resumeLocked(ctx, project, folder, events, signal);
	} finally {
		releaseLock(folder);
	}
}

async function resumeLocked(ctx: ExtensionContext, project: string, folder: string, events: RecordedEvent[], signal?: AbortSignal): Promise<void> {
	const startEvent = events.find((e) => e.type === "run-start");
	const name = startEvent?.flow;
	const worktree = typeof startEvent?.worktree === "string" && typeof startEvent.base === "string"
		? { path: startEvent.worktree, branch: String(startEvent.branch ?? ""), base: startEvent.base } : undefined;
	if (!name || !worktree) {
		say(ctx, "The run's events name no flow or worktree; it can't resume.", "error");
		return;
	}
	if (!worktreeExists(worktree.path)) {
		say(ctx, `The run's worktree ${worktree.path} is gone; it can't resume.`, "error");
		return;
	}
	const flow = await runFlow(ctx, folder, await loadFlow(ctx, project, name), events);
	const pi = flow ? await checkPi(ctx, flow) : undefined;
	if (!flow || !pi) return;
	addGrants(flow, grantedLoops(events));
	const run: Run = {
		folder, id: folder.split("/").pop() ?? "", flow, task: startEvent.task ?? "", project, info: pi.info, newer: pi.newer,
		started: typeof startEvent.time === "string" ? startEvent.time : new Date().toISOString(), worktree,
	};
	const visits = visitsFrom(events);
	const commits = flowCommits(worktree.path, run.id, worktree.base);
	const last = [...events].reverse().find((e) => e.type === "step-start" || e.type === "step-end");
	const crashed = last?.type === "step-start" || (last?.type === "step-end" && last.reason === "aborted");
	let decision: Decision;
	let previous: Previous | undefined;
	if (!last || !last.step) decision = firstStep(flow);
	else if (crashed) {
		const attempt = last.attempt ?? visits[last.step] ?? 1;
		const committed = commits.find((c) => c.trailers["Flow-Step"] === last.step && c.trailers["Flow-Attempt"] === String(attempt) && !c.trailers["Flow-Gate"]);
		previous = previousFrom(folder, flow, last.step, attempt);
		if (committed && last.type === "step-start" && previous) {
			// Killed after the step's commit, before its step-end: the step is finished, not rerun.
			appendEvent(folder, "step-end", { step: last.step, attempt, outcome: previous.outcome, reason: previous.reason, commit: committed.commit, recovered: true });
			decision = nextStep(flow, { step: last.step, visits }, previous.outcome, previous.reason);
		} else {
			// The step crashed: back to the last step commit, then the step again (attempt + 1).
			const target = commits[0]?.commit ?? worktree.base;
			const dirty = changes(worktree.path);
			if (dirty.length > 0) {
				const yes = await ctx.ui.confirm("Reset the flow's worktree?",
					`Step ${last.step} stopped before it finished. ${worktree.path} has ${dirty.length} uncommitted change(s):\n${dirty.slice(0, 20).join("\n")}\n\nReset to the last step commit ${target.slice(0, 10)} and run the step again?`);
				if (!yes) {
					say(ctx, `Resume stopped; nothing was reset. Commit or remove the changes in ${worktree.path}, then /flow resume.`, "warning");
					return;
				}
			}
			if (!resetTo(worktree.path, target)) {
				say(ctx, `Resume stopped: can't reset ${worktree.path} to ${target.slice(0, 10)}. Check the worktree with git status, then /flow resume.`, "error");
				return;
			}
			previous = commits[0] ? previousFrom(folder, flow, commits[0].trailers["Flow-Step"] ?? "", Number(commits[0].trailers["Flow-Attempt"])) : undefined;
			const step = flow.steps.find((s) => s.id === last.step);
			const count = (visits[last.step] ?? 0) + 1;
			decision = !step ? { stop: "unknown-step", step: last.step, visits }
				: count > (step.maxLoops ?? DEFAULT_MAX_LOOPS) ? { stop: "visit-cap", step: last.step, visits }
				: { next: last.step, visits: { ...visits, [last.step]: count } };
		}
	} else {
		const attempt = last.attempt ?? visits[last.step] ?? 1;
		previous = previousFrom(folder, flow, last.step, attempt);
		decision = nextStep(flow, { step: last.step, visits }, (last.outcome ?? "failed") as Outcome, last.reason ?? "");
		// Halted at a gate (no answer): the gate asks again.
		const after = events.slice(events.lastIndexOf(last) + 1);
		const sentBack = after.find((e) => e.type === "gate" && e.answer === "send-back");
		if (sentBack && previous) {
			decision = nextStep(flow, { step: last.step, visits }, "failed", "sent-back");
			previous = { ...previous, outcome: "failed", reason: "sent-back", note: typeof sentBack.note === "string" ? sentBack.note : "" };
		} else if (last.outcome === "blocked" && last.reason === "disputed" && previous && !after.some((e) => e.type === "dispute")) {
			// Halted at a dispute: the user is asked again, with the rejection the step disputed.
			const before = events.slice(0, events.lastIndexOf(last)).reverse().find((e) => e.type === "step-end" && e.step !== last.step);
			const judge = before?.step ? previousFrom(folder, flow, before.step, before.attempt ?? 1) : undefined;
			const step = flow.steps.find((s) => s.id === last.step);
			if (judge && step && disputes(step, "blocked", "disputed", judge)) {
				const settled = await atDispute(ctx, run, last.step, attempt, visits, judge, previous);
				if (!settled) return;
				({ decision, previous } = settled);
			}
		} else if (flow.steps.find((s) => s.id === last.step)?.gate && last.outcome === "done" && previous && !after.some((e) => e.type === "gate")) {
			const answered = await atGate(ctx, run, last.step, attempt, visits, decision, previous);
			if (!answered) return;
			({ decision, previous } = answered);
		}
		// A run that stopped at a loop limit or a missing route asks again instead of stopping again.
		({ decision, previous } = await atStop(ctx, run, decision,
			{ step: last.step, visits, outcome: (last.outcome ?? "failed") as Outcome, reason: last.reason ?? "" }, previous));
	}
	// Resume is the user's word to go on: a STOP left from the halt is removed.
	const stopped = existsSync(join(folder, "STOP"));
	rmSync(join(folder, "STOP"), { force: true });
	appendEvent(folder, "resume", { run: run.id, ...(stopped ? { removed: "STOP" } : {}) });
	await loop(ctx, run, decision, previous, signal);
}

/** Where a step's skill is: Pi's folders, and for a Claude Code step Claude's own after them
 * (--safe-mode turns those off in the child, so the step gets them only this way). */
export function resolveSkill(project: string, name: string, claude = false): string | undefined {
	if (isAbsolute(name)) return existsSync(name) ? name : undefined;
	const home = homedir();
	return [join(project, ".pi", "skills", name), join(home, ".pi", "agent", "skills", name), join(project, ".agents", "skills", name),
		join(home, ".agents", "skills", name),
		...(claude ? [join(project, ".claude", "skills", name), join(home, ".claude", "skills", name)] : [])].find((p) => existsSync(p));
}

/** A checker step with check commands: the runner runs them and no model is started. */
export function codeOnly(step: { agent: string; checks?: string[] }): boolean {
	return step.agent === "checker" && (step.checks ?? []).length > 0;
}

/** -e list of a child: the guard when present (Phase 3a), the handoff tool, then the step's own extensions. */
function childExtensions(project: string, own: string[]): string[] {
	const list: string[] = [];
	const guard = join(here, "akit-flow-guard.ts");
	if (existsSync(guard)) list.push(guard);
	list.push(join(here, "akit-flow-handoff.ts"));
	for (const ext of own) list.push(isAbsolute(ext) ? ext : join(project, ".pi", "extensions", ext));
	return list;
}

/** The guard's rules for one step attempt (F15), in `<run>/guard/NN-<step>-a<attempt>.json`: the
 * step's tools, else the flow's, else Pi's built-ins; `bash` defaults to "yes unless paths is set",
 * as Swift's FlowStep. Returns the file's path for AKIT_FLOW_GUARD. */
function writeGuardRules(run: Run, step: FlowStep, key: string, attempt: number): string {
	const paths = step.paths ?? [];
	const tools = step.tools?.length ? step.tools : run.flow.tools?.length ? run.flow.tools : DEFAULT_TOOLS;
	const rules: GuardRules = {
		run: run.id, step: step.id, attempt, tools, paths, bash: step.bash ?? paths.length === 0,
		root: run.worktree.path, events: join(run.folder, "events.jsonl"), records: dirname(dirname(run.folder)),
	};
	mkdirSync(join(run.folder, "guard"), { recursive: true });
	const path = join(run.folder, "guard", `${key}-a${attempt}.json`);
	writeAtomic(path, rules);
	return path;
}

/** The model's part of a handoff, as `flow_handoff` wrote it (F4). */
interface HandoffPart {
	goal: string;
	done: string[];
	files: { path: string; change: string }[];
	open_questions: string[];
	notes: string;
	/** The planner's plan as data (steps, a check command), when it gave one. */
	plan?: { steps: string[]; check: string };
	outcome: Outcome;
	reason: string;
	/** Set when the runner made the part from the answer's `outcome:` line, not `flow_handoff`. */
	fallback?: boolean;
}

/** Most of a fallback handoff's notes: the child's answer, redacted, its last 2 KB. */
export const FALLBACK_NOTES_BYTES = 2048;
export function fallbackNotes(text: string): string {
	const clean = redact(text);
	const bytes = Buffer.from(clean, "utf8");
	return bytes.length <= FALLBACK_NOTES_BYTES ? clean : bytes.subarray(bytes.length - FALLBACK_NOTES_BYTES).toString("utf8").replace(/^\uFFFD+/, "");
}

const strings = (value: unknown): string[] => (Array.isArray(value) ? value.filter((v): v is string => typeof v === "string") : []);

/** The file `flow_handoff` wrote, or undefined when there is none or it has no valid outcome. */
function readPart(path: string): HandoffPart | undefined {
	if (!existsSync(path)) return undefined;
	try {
		return partFrom(JSON.parse(readFileSync(path, "utf8")));
	} catch {
		return undefined;
	} finally {
		rmSync(path, { force: true });
	}
}

/** The model's part of a handoff from `flow_handoff`'s file or Claude Code's structured output;
 * undefined without a valid outcome. */
export function partFrom(value: unknown): HandoffPart | undefined {
	if (!value || typeof value !== "object" || Array.isArray(value)) return undefined;
	const v = value as Record<string, unknown>;
	if (!isOutcome(v.outcome)) return undefined;
	const files = Array.isArray(v.files) ? v.files.filter((f): f is { path: string; change: string } => typeof f?.path === "string")
		.map((f) => ({ path: f.path, change: typeof f.change === "string" ? f.change : "" })) : [];
	const p = v.plan as Record<string, unknown> | undefined;
	const plan = p && typeof p === "object" && Array.isArray(p.steps) ? { steps: strings(p.steps), check: typeof p.check === "string" ? p.check.trim() : "" } : undefined;
	return {
		goal: typeof v.goal === "string" ? v.goal : "", done: strings(v.done), files, open_questions: strings(v.open_questions),
		notes: typeof v.notes === "string" ? v.notes : "", ...(plan ? { plan } : {}), outcome: v.outcome, reason: typeof v.reason === "string" ? v.reason : "",
	};
}

interface Previous {
	step: string;
	outcome: Outcome;
	reason: string;
	/** The previous step's handoff file, as written. */
	handoff: Record<string, unknown>;
	/** Failed checks of the previous step: command, exit code, last lines. */
	failedChecks?: { command: string; exit: number | null; tail: string[] }[];
	/** The user's note when a gate sent the work back. */
	note?: string;
	/** What the note is, when not a Send Back at a gate (a decision at a stop, a dispute). */
	noteTitle?: string;
}

/** A step's tools: its own, else the flow's, else Pi's built-ins. The prompt names them, the
 * child gets exactly these (-t, or Claude's --tools) and the guard allows only these. */
export function stepTools(flow: Flow, step: FlowStep | undefined): string[] {
	return step?.tools?.length ? step.tools : flow.tools?.length ? flow.tools : DEFAULT_TOOLS;
}

/** On Claude Code every command that would need a permission is denied (--permission-prompts none). */
export const CLAUDE_BASH = "On Claude Code, bash runs only commands that read (git log, git diff, cat, ls); anything that writes or runs a program, tests included, is denied. The runner runs the step's checks itself.";

function prompt(run: Run, stepId: string, agent: string, previous: Previous | undefined, claude = false, attempt = 1): string {
	const step = run.flow.steps.find((s) => s.id === stepId);
	const tools = stepTools(run.flow, step);
	const lines = [
		`You are the ${agent} step "${stepId}" of the AKit flow "${run.flow.name}" (run ${run.id}).`,
		`Task: ${run.task}`,
		// A step without bash can't run git: naming the diff would only make it ask for a tool it lacks.
		...(tools.includes("bash") ? [`The run's changes: git diff ${run.worktree.base}`] : []),
		`Your tools: ${tools.join(", ")}. Work with these; a tool you don't have is not a reason to end blocked.`,
		...(claude && tools.includes("bash") ? [CLAUDE_BASH] : []),
	];
	if (step?.prompt) lines.push("", step.prompt);
	lines.push("", PRECEDENCE);
	const plan = agent === "planner" ? undefined : planHandoff(run.folder, run.flow, stepId);
	const earlier = earlierSteps(run, new Set([stepId, ...(plan ? [plan.step] : []), ...(previous ? [previous.step] : [])]));
	if (earlier.lines.length) lines.push("", "Earlier steps, oldest first (short; the newest weigh most):", ...earlier.lines);
	if (earlier.questions.length) lines.push("", "Open questions from earlier steps (answer them if your step can):", ...earlier.questions.map((q) => `- ${q}`));
	if (plan && plan.step !== previous?.step) {
		lines.push("", `The plan (handoff of the step "${plan.step}"):`, JSON.stringify(handoffForPrompt(plan.handoff), null, 2));
	}
	// A step that runs again sees its own last result, so a judge checks its earlier notes
	// instead of finding new ones each round, and a maker knows what it tried.
	const own = attempt > 1 ? readHandoff(run.folder, run.flow.steps.findIndex((s) => s.id === stepId), stepId, attempt - 1) : undefined;
	if (own && previous?.step !== stepId) {
		lines.push("", `Your own result last time (attempt ${attempt - 1}): build on it; don't start over.`, JSON.stringify(handoffForPrompt(own), null, 2));
	}
	if (previous) {
		lines.push("", `Most recent: the handoff from the step "${previous.step}" (${previous.outcome}${previous.reason ? `:${previous.reason}` : ""}); it weighs most for where things stand:`,
			JSON.stringify(handoffForPrompt(previous.handoff), null, 2));
		if (previous.note !== undefined) {
			lines.push("", previous.noteTitle ?? `The user sent the work back at the gate after the step "${previous.step}". Their note:`, previous.note || "(no note)");
		}
		// A rejection from another step may be wrong: the step may dispute it instead of complying.
		if (previous.outcome !== "done" && previous.step !== stepId && previous.note === undefined && !previous.failedChecks?.length) {
			lines.push("", `If you are sure "${previous.step}" is wrong, don't comply: end blocked with reason disputed and give your arguments in notes; the user decides.`);
		}
		for (const check of previous.failedChecks ?? []) {
			lines.push("", `The check \`${check.command}\` exited ${check.exit}. Its last lines:`, ...check.tail);
		}
	}
	lines.push("", claude
		? "When the step is finished, answer with the handoff in the JSON schema you were given: what you did and the outcome: done, failed or blocked (with a reason)."
		: "When the step is finished, call the tool flow_handoff once with what you did and the outcome: done, failed or blocked (with a reason).");
	return lines.join("\n");
}

async function loop(ctx: ExtensionContext, run: Run, first: Decision, previous: Previous | undefined, signal?: AbortSignal): Promise<void> {
	let decision = first;
	let visits: Visits = decision.visits;
	if (view?.run !== run.id) {
		view = newView(run.flow, run.id);
		for (const e of readEvents(run.folder)) {
			if (e.type === "step-end" && e.step) setStep(ctx, run, e.step, e.outcome === "done" ? "done" : "failed");
		}
	}
	try {
		while ("next" in decision) {
			const id = decision.next;
			const index = run.flow.steps.findIndex((s) => s.id === id);
			const step = run.flow.steps[index];
			visits = decision.visits;
			const attempt = visits[step.id] ?? 1;
			const key = stepKey(index, step.id);
			// AKit's Stop button writes STOP: the run halts before the next step; /flow resume goes on (F19).
			if (existsSync(join(run.folder, "STOP"))) {
				appendEvent(run.folder, "halted", { reason: "STOP", next: step.id });
				writeRunJson(run, { status: "stopped", state: { step: previous?.step ?? null, visits: previousVisits(visits, step.id) } });
				status(ctx, undefined);
				say(ctx, `Flow ${run.flow.name} halted by STOP before step ${step.id}; /flow resume continues.`, "warning");
				return;
			}
			// Edits made between steps (at a gate) are committed before the next step starts (F9).
			if (changes(run.worktree.path).length > 0) {
				const edits = commit(run.worktree.path, `Flow edits before ${step.id}`, { "Flow-Run": run.id, "Flow-Gate": previous?.step ?? "start" });
				if ("error" in edits) return finish(ctx, run, { stop: "commit-failed", step: step.id, visits: previousVisits(visits, step.id) }, `Can't commit the edits before step ${step.id}: ${edits.error}`);
				appendEvent(run.folder, "gate-edits", { before: step.id, commit: edits.commit });
			}
			// The state is in events.jsonl before the step starts (F19), so a crash resumes here.
			appendEvent(run.folder, "step-start", { step: step.id, attempt });
			setStep(ctx, run, step.id, "running");
			const shown = view?.steps.find((s) => s.id === step.id);
			writeRunJson(run, { status: "running", state: { step: step.id, visits } });
			status(ctx, `flow ${run.flow.name}: ${index + 1}/${run.flow.steps.length} ${step.id}`);
			// A checker also runs the approved plan's own check command, when it is a plain one.
			const planCheck = step.agent === "checker" && (step.checks ?? []).length > 0
				? (planHandoff(run.folder, run.flow, step.id)?.handoff.plan as { check?: unknown } | undefined)?.check : undefined;
			const checks = [...(step.checks ?? []),
				...(typeof planCheck === "string" && planCheck && isSafeCommand(planCheck) && !(step.checks ?? []).includes(planCheck) ? [planCheck] : [])];
			const unsafe = checks.find((c) => !isSafeCommand(c));
			if (unsafe !== undefined || checks.length > MAX_CHECK_COMMANDS) {
				appendEvent(run.folder, "deviation", { step: step.id, rule: "check-refused", detail: unsafe ?? `${checks.length} commands` });
				return finish(ctx, run, { stop: "check-refused", step: step.id, visits },
					`Step ${step.id} has a check the runner refuses (${unsafe ?? `more than ${MAX_CHECK_COMMANDS} commands`}); fix it in AKit and Apply.`);
			}
			const skills: string[] = [];
			for (const name of step.skills ?? []) {
				const path = resolveSkill(run.project, name, step.harness === "claude-code");
				if (!path) {
					appendEvent(run.folder, "deviation", { step: step.id, rule: "skill-missing", detail: name });
					return finish(ctx, run, { stop: "no-route", step: step.id, visits }, `The skill ${name} of step ${step.id} is not installed.`);
				}
				skills.push(path);
			}
			const sessionDir = join(run.folder, "sessions");
			const partPath = join(run.folder, "handoffs", `${key}-a${attempt}.part`);
			// A Claude Code step has no guard: Claude's tool list and permission rules hold it (F21).
			const claude = step.harness === "claude-code";
			const guardPath = codeOnly(step) || claude ? "" : writeGuardRules(run, step, key, attempt);
			let result: ChildResult | undefined;
			let part: HandoffPart | undefined;
			let deviations = 0;
			// A checker step with check commands runs no model: the runner's checks are the whole step,
			// and its handoff passes the previous step's work on with the evidence (saves a child's tokens).
			if (codeOnly(step)) {
				result = { code: 0, signal: null, aborted: false, text: "", tokens: { input: 0, output: 0, cacheRead: 0, cost: 0 }, unknownEvents: 0, badLines: 0, stderr: "" };
				const before = previous?.handoff ?? {};
				const list = (v: unknown) => (Array.isArray(v) ? v : []);
				part = {
					goal: typeof before.goal === "string" && before.goal ? before.goal : run.task, done: list(before.done) as string[],
					files: list(before.files) as HandoffPart["files"], open_questions: list(before.open_questions) as string[],
					notes: typeof before.notes === "string" ? before.notes : "", outcome: "done", reason: "",
				};
			}
			// No valid flow_handoff: the step reruns once, then the run stops (F4).
			for (let round = 1; round <= 2 && !part; round++) {
				rmSync(partPath, { force: true });
				const options = {
					cwd: run.worktree.path, sessionDir, model: step.model, thinking: step.thinking, skills,
					tools: stepTools(run.flow, step), extensions: childExtensions(run.project, step.extensions ?? []),
					prompt: prompt(run, step.id, step.agent, previous, claude, attempt), info: run.info, env: { AKIT_FLOW_HANDOFF: partPath, AKIT_FLOW_GUARD: guardPath }, signal,
					onEvent: (event: Record<string, unknown>) => {
						if (shown && viewEvent(shown, event)) refresh(ctx, run);
					},
				};
				result = claude ? await runClaudeChild({ ...options, sessionId: randomUUID(), rules: projectRules(run.worktree.path) }) : await runChild(options);
				if (result.aborted || result.spawnError) {
					appendEvent(run.folder, "step-end", { step: step.id, attempt, outcome: "failed", reason: result.aborted ? "aborted" : "spawn", tokens: recordTokens(result.tokens), exit: result.code });
				setStep(ctx, run, step.id, "failed");
					writeRunJson(run, { status: "stopped", state: { step: step.id, visits } });
					say(ctx, result.aborted ? `Flow ${run.flow.name} aborted in step ${step.id}; /flow resume continues.` : `Can't start ${claude ? "claude" : "pi"}: ${result.spawnError}`, "error");
					return;
				}
				part = claude ? partFrom(result.structured) : readPart(partPath);
				if (part) break;
				const line = parseOutcome(result.text);
				deviations++;
				if (line) {
					appendEvent(run.folder, "deviation", { step: step.id, attempt, rule: "handoff-fallback", detail: `outcome: ${line.outcome}${line.reason ? `:${line.reason}` : ""}`, session: result.session ?? null });
					part = { goal: run.task, done: [], files: [], open_questions: [], notes: fallbackNotes(result.text), fallback: true, ...line };
					break;
				}
				appendEvent(run.folder, "deviation", { step: step.id, attempt, rule: "handoff-missing", action: round === 1 ? "rerun" : "stopped", session: result.session ?? null });
			}
			if (!result || !part) {
				appendEvent(run.folder, "step-end", { step: step.id, attempt, outcome: "failed", reason: "no-handoff", tokens: recordTokens(result?.tokens ?? {}), exit: result?.code ?? null });
				setStep(ctx, run, step.id, "failed");
				return finish(ctx, run, { stop: "no-handoff", step: step.id, visits }, `Flow ${run.flow.name} stopped: step ${step.id} ended twice without flow_handoff.`);
			}
			let { outcome, reason } = part;
			// What git saw the step change, before the checks run: the truth its handoff's files are
			// checked against and that later steps get. A code-only checks step passes work on; no check.
			const changed = codeOnly(step) ? undefined : changedFiles(run.worktree.path);
			if (changed) {
				const named = new Set(part.files.map((f) => f.path));
				const seen = new Set(changed.map((f) => f.path));
				if (named.size !== seen.size || [...seen].some((p) => !named.has(p))) {
					deviations++;
					appendEvent(run.folder, "deviation", { step: step.id, attempt, rule: "files-mismatch",
						detail: `named: ${[...named].join(", ") || "none"}; git: ${[...seen].join(", ") || "none"}` });
				}
			}
			let evidence: string | undefined;
			let failedChecks: Previous["failedChecks"];
			if (checks.length > 0) {
				// The runner runs the checks; they count as green only with the evidence file (F19).
				evidence = await runChecks(run.folder, key, run.id, { id: step.id, attempt }, checks, run.worktree.path, signal);
				if (!checksGreen(evidence)) {
					try {
						failedChecks = (JSON.parse(readFileSync(evidence, "utf8")).checks as NonNullable<Previous["failedChecks"]>).filter((c) => c.exit !== 0);
					} catch {
						failedChecks = [];
					}
					deviations++;
					appendEvent(run.folder, "deviation", { step: step.id, attempt, rule: "check-failed", detail: failedChecks.map((c) => `${c.command} → ${c.exit}`).join("; ") });
					if (outcome === "done") {
						outcome = "failed";
						reason = "checks";
					}
				}
			}
			decision = nextStep(run.flow, { step: step.id, visits }, outcome, reason);
			const next = "next" in decision ? decision.next : undefined;
			const file = sessionFile(sessionDir, result.session);
			const handoff = {
				schema: HANDOFF_SCHEMA, run: run.id, flow: run.flow.name, step: { index: index + 1, id: step.id, attempt },
				session: result.session ?? null, session_file: file ? `sessions/${file}` : null, from: { outcome, reason },
				next: next ? { step: next } : null, goal: part.goal || run.task, done: part.done, files: part.files,
				...(changed ? { changed } : {}), open_questions: part.open_questions, notes: part.notes, ...(part.plan ? { plan: part.plan } : {}), ...(part.fallback ? { fallback: true } : {}), tokens: recordTokens(result.tokens), deviations,
				evidence: evidence ? `evidence/${basename(evidence)}` : null,
			};
			writeAtomic(join(run.folder, "handoffs", handoffName(index, step.id, attempt, result.session)), handoff);
			// The finished step is a commit with trailers, before its step-end: resume trusts the trailer (F9).
			const done = commit(run.worktree.path, handoff.goal, { "Flow-Run": run.id, "Flow-Step": step.id, "Flow-Attempt": String(attempt) });
			if ("error" in done) {
				appendEvent(run.folder, "deviation", { step: step.id, attempt, rule: "commit-failed", detail: done.error });
				return finish(ctx, run, { stop: "commit-failed", step: step.id, visits }, `Can't commit step ${step.id}: ${done.error}`);
			}
			appendEvent(run.folder, "step-end", {
				step: step.id, attempt, outcome, reason, tokens: recordTokens(result.tokens), exit: result.code, commit: done.commit,
				...(result.unknownEvents ? { unknownEvents: result.unknownEvents } : {}),
			});
			setStep(ctx, run, step.id, outcome === "done" ? "done" : "failed");
			const given = previous;
			previous = { step: step.id, outcome, reason, handoff, failedChecks };
			if (disputes(step, outcome, reason, given)) {
				const settled = await atDispute(ctx, run, step.id, attempt, visits, given as Previous, previous);
				if (!settled) return;
				({ decision, previous } = settled);
			} else if (step.gate && outcome === "done") {
				const answered = await atGate(ctx, run, step.id, attempt, visits, decision, previous);
				if (!answered) return;
				({ decision, previous } = answered);
			}
			({ decision, previous } = await atStop(ctx, run, decision, { step: step.id, visits, outcome, reason }, previous));
		}
		finish(ctx, run, decision);
	} finally {
		releaseLock(run.folder);
	}
}

/** The user's answer at a gate (F5): the diff of the run branch against its base (read only),
 * then Approve or Send Back with a note. */
async function askGate(ctx: ExtensionContext, run: Run, step: string, handoff?: Record<string, unknown>): Promise<{ approve: true } | { note: string } | undefined> {
	if (!ctx.hasUI || typeof ctx.ui?.select !== "function" || typeof ctx.ui?.editor !== "function") return undefined;
	// The step's open questions come first: the gate is where the user can answer them (Send Back).
	const questions = strings(handoff?.open_questions);
	const head = questions.length ? `Open questions of ${step} (answer them with Send Back):\n${questions.map((q) => `- ${q}`).join("\n")}\n\n` : "";
	await ctx.ui.editor(`Gate after ${step}: ${run.worktree.branch} against its base (read only; edits here are not kept)`,
		head + diffFromBase(run.worktree.path, run.worktree.base));
	const choice = await ctx.ui.select(`Gate after step ${step}`, ["Approve", "Send Back"]);
	if (choice === "Approve") return { approve: true };
	if (choice !== "Send Back") return undefined;
	const note = await ctx.ui.editor(`Send Back: a note for the step that gets the work back`, "");
	return { note: (note ?? "").trim() };
}

/** A gate step that ended done: Approve keeps the decision; Send Back routes `failed:sent-back`
 * by the step's routes (a deviation) and gives the note to that step. No answer halts the run. */
async function atGate(ctx: ExtensionContext, run: Run, step: string, attempt: number, visits: Visits, decision: Decision,
	previous: Previous): Promise<{ decision: Decision; previous: Previous } | undefined> {
	const answer = await askGate(ctx, run, step, previous.handoff);
	if (!answer) {
		appendEvent(run.folder, "halted", { reason: "gate", step });
		writeRunJson(run, { status: "stopped", state: { step, visits } });
		status(ctx, undefined);
		say(ctx, `Flow ${run.flow.name} waits at the gate after step ${step}; /flow resume asks again.`, "warning");
		return undefined;
	}
	if ("approve" in answer) {
		appendEvent(run.folder, "gate", { step, attempt, answer: "approve" });
		return { decision, previous };
	}
	appendEvent(run.folder, "gate", { step, attempt, answer: "send-back", note: answer.note });
	appendEvent(run.folder, "deviation", { step, attempt, rule: "sent-back", detail: answer.note });
	return {
		decision: nextStep(run.flow, { step, visits }, "failed", "sent-back"),
		previous: { ...previous, outcome: "failed", reason: "sent-back", note: answer.note },
	};
}

/** A step disputes a rejection from another step: it ended blocked:disputed right after one,
 * and the flow has no route of its own for that. */
function disputes(step: { routes?: Record<string, string> }, outcome: Outcome, reason: string, given: Previous | undefined): boolean {
	return outcome === "blocked" && reason === "disputed" && !!given && given.outcome !== "done" && !(step.routes ?? {})["blocked:disputed"];
}

/** The step once more, unless that passes its loop limit (then atStop asks). */
function again(flow: Flow, step: string, visits: Visits): Decision {
	const count = (visits[step] ?? 0) + 1;
	const max = flow.steps.find((s) => s.id === step)?.maxLoops ?? DEFAULT_MAX_LOOPS;
	return count > max ? { stop: "visit-cap", step, visits } : { next: step, visits: { ...visits, [step]: count } };
}

/** Extra rounds the user granted at a step's loop limit, from the run's events; resume adds them
 * to the flow's limits again. */
export function grantedLoops(events: RecordedEvent[]): Record<string, number> {
	const grants: Record<string, number> = {};
	for (const e of events) {
		if (e.type === "decision" && e.answer === "more" && typeof e.target === "string") grants[e.target] = (grants[e.target] ?? 0) + 1;
	}
	return grants;
}

function addGrants(flow: Flow, grants: Record<string, number>): void {
	for (const step of flow.steps) if (grants[step.id]) step.maxLoops = (step.maxLoops ?? DEFAULT_MAX_LOOPS) + grants[step.id];
}

/** A handoff as the user reads it at a stop or a dispute. */
function readable(h: Record<string, unknown>): string {
	const from = (h.from ?? {}) as { outcome?: string; reason?: string };
	return [`Outcome: ${from.outcome ?? "?"}${from.reason ? `:${from.reason}` : ""}`, typeof h.goal === "string" ? `Goal: ${h.goal}` : "",
		...strings(h.done).map((d) => `- ${d}`), "", typeof h.notes === "string" ? h.notes : ""].filter((l, i, a) => l || a[i - 1]).join("\n");
}

/** "Stop and ask", for real: at a step's loop limit or an outcome with no route, the user picks how
 * to go on instead of the run ending in a dead end. No UI, or Stop: the run stops; /flow resume
 * asks again, and rounds granted before still count. */
async function atStop(ctx: ExtensionContext, run: Run, decision: Decision, from: { step: string; visits: Visits; outcome: Outcome; reason: string },
	previous: Previous | undefined): Promise<{ decision: Decision; previous: Previous | undefined }> {
	if ("next" in decision || (decision.stop !== "visit-cap" && decision.stop !== "no-route")) return { decision, previous };
	if (!ctx.hasUI || typeof ctx.ui?.select !== "function") return { decision, previous };
	const capped = decision.stop === "visit-cap";
	const target = decision.step ?? from.step;
	const limit = run.flow.steps.find((s) => s.id === target)?.maxLoops ?? DEFAULT_MAX_LOOPS;
	const ended = `${from.outcome}${from.reason ? `:${from.reason}` : ""}`;
	const more = `One more round of ${target}`, accept = "Accept as is and go on", back = `Send ${from.step} back with a note`, stop = "Stop";
	if (previous && typeof ctx.ui.editor === "function") await ctx.ui.editor(`What ${from.step} said (read only)`, readable(previous.handoff));
	const choice = await ctx.ui.select(capped ? `${from.step} ended ${ended}, but ${target} reached its max rounds (${limit})`
		: `${from.step} ended ${ended}, and it has no route for that`, capped ? [more, accept, stop] : [accept, back, stop]);
	const log = (answer: string, extra: Record<string, unknown> = {}) =>
		appendEvent(run.folder, "decision", { step: from.step, stop: decision.stop, answer, ...extra });
	if (choice === more) {
		const step = run.flow.steps.find((s) => s.id === target);
		if (step) step.maxLoops = limit + 1;
		log("more", { target });
		return atStop(ctx, run, nextStep(run.flow, from, from.outcome, from.reason), from, previous);
	}
	if (choice === accept) {
		log("accept");
		const accepted = previous && { ...previous, note: `The user accepted the work of "${from.step}" as it is, despite its ${ended}.`, noteTitle: "The user's decision:" };
		return atStop(ctx, run, nextStep(run.flow, { step: from.step, visits: from.visits }, "done", ""), { ...from, outcome: "done", reason: "" }, accepted);
	}
	if (choice === back && typeof ctx.ui.editor === "function") {
		const note = ((await ctx.ui.editor(`A note for ${from.step}`, "")) ?? "").trim();
		log("again", { note });
		return { decision: { next: from.step, visits: { ...from.visits, [from.step]: (from.visits[from.step] ?? 0) + 1 } },
			previous: previous && { ...previous, note, noteTitle: `The user sent "${from.step}" back to itself. Their note:` } };
	}
	log("stop");
	return { decision, previous };
}

/** A step disputes the rejection it got: the user reads both sides and decides. The maker wins: the
 * run goes on as if the judge had passed the work. The judge wins: the maker reruns and must do it.
 * No UI or no answer: the run halts; /flow resume asks again. */
async function atDispute(ctx: ExtensionContext, run: Run, step: string, attempt: number, visits: Visits, judge: Previous,
	maker: Previous): Promise<{ decision: Decision; previous: Previous } | undefined> {
	appendEvent(run.folder, "deviation", { step, attempt, rule: "disputed", detail: `${step} disputes ${judge.step}` });
	const ask = ctx.hasUI && typeof ctx.ui?.select === "function" && typeof ctx.ui?.editor === "function";
	if (ask) {
		await ctx.ui.editor(`Dispute: ${step} disagrees with ${judge.step} (read only)`,
			`${judge.step} said:\n${readable(judge.handoff)}\n\n${step} answers:\n${readable(maker.handoff)}`);
	}
	const forMaker = `${step} is right: go on`, forJudge = `${judge.step} is right: ${step} does it`, withNote = "Decide with a note";
	const choice = ask ? await ctx.ui.select(`Dispute: ${step} or ${judge.step}?`, [forMaker, forJudge, withNote]) : undefined;
	if (choice === forMaker) {
		appendEvent(run.folder, "dispute", { step, judge: judge.step, attempt, answer: "maker" });
		return {
			decision: nextStep(run.flow, { step: judge.step, visits }, "done", ""),
			previous: { ...maker, outcome: "done", reason: "", note: `The user sided with "${step}" against the objection of "${judge.step}".`, noteTitle: "The user's decision on a dispute:" },
		};
	}
	if (choice === forJudge || choice === withNote) {
		const note = choice === withNote ? ((await ctx.ui.editor(`Your decision for ${step}`, "")) ?? "").trim()
			: `The user sided with "${judge.step}": do what it asks; don't dispute it again.`;
		appendEvent(run.folder, "dispute", { step, judge: judge.step, attempt, answer: choice === forJudge ? "judge" : "note", note });
		return { decision: again(run.flow, step, visits), previous: { ...judge, note, noteTitle: "The user's decision on a dispute:" } };
	}
	appendEvent(run.folder, "halted", { reason: "dispute", step });
	writeRunJson(run, { status: "stopped", state: { step, visits } });
	status(ctx, undefined);
	say(ctx, `Flow ${run.flow.name} waits for your decision: ${step} disputes ${judge.step}; /flow resume asks again.`, "warning");
	return undefined;
}

/** Visits before the step that was about to start: a halt leaves that visit uncounted. */
function previousVisits(visits: Visits, step: string): Visits {
	const count = (visits[step] ?? 1) - 1;
	const rest = { ...visits };
	if (count > 0) rest[step] = count;
	else delete rest[step];
	return rest;
}

function finish(ctx: ExtensionContext, run: Run, decision: Decision, message?: string): void {
	if ("next" in decision) return;
	if (decision.stop === "no-route" && !message) appendEvent(run.folder, "deviation", { step: decision.step, rule: "no-route" });
	appendEvent(run.folder, "run-end", { stop: decision.stop, ...(decision.step ? { step: decision.step } : {}) });
	refresh(ctx, run);
	writeRunJson(run, { status: decision.stop === "done" ? "done" : "stopped", stop: decision.stop, state: { step: decision.step ?? null, visits: decision.visits } });
	status(ctx, undefined);
	const head = message ?? (decision.stop === "done" ? `Flow ${run.flow.name} done (run ${run.id}).`
		: decision.stop === "visit-cap" ? `Flow ${run.flow.name} stopped: step ${decision.step} reached its max rounds.`
		: decision.stop === "no-route" ? `Flow ${run.flow.name} stopped: step ${decision.step} has no route for its outcome.`
		: `Flow ${run.flow.name} stopped: unknown step ${decision.step}.`);
	const text = [head, ...outcomeLines(run)].join("\n");
	summaries.set(run.id, text);
	say(ctx, text, decision.stop === "done" ? "info" : "error");
}

/** How each run ended, for the tool that started it (akit_flow answers the model with it). */
const summaries = new Map<string, string>();

/** What the run left: the last handoff's goal, what it did and its notes, and where the work is,
 * with the command that takes it, so the user and the session that started the run can go on. */
export function outcomeLines(run: { folder: string; flow: Flow; project: string; id: string; worktree: Worktree }): string[] {
	const last = [...readEvents(run.folder)].reverse().find((e) => e.type === "step-end" && typeof e.step === "string");
	const index = last ? run.flow.steps.findIndex((s) => s.id === last.step) : -1;
	const h = last && index >= 0 ? readHandoff(run.folder, index, String(last.step), typeof last.attempt === "number" ? last.attempt : 1) : undefined;
	const lines: string[] = [];
	if (h) {
		lines.push(`Last step: ${last?.step} (${last?.outcome ?? "?"}${last?.reason ? `:${last.reason}` : ""})${typeof h.goal === "string" && h.goal ? ` · ${h.goal}` : ""}`);
		const done = strings(h.done);
		if (done.length) lines.push(`Done: ${done.slice(0, 5).join("; ")}${done.length > 5 ? ` (+${done.length - 5})` : ""}`);
		if (typeof h.notes === "string" && h.notes.trim()) lines.push(`Notes: ${h.notes.trim().slice(0, 600)}${h.notes.length > 600 ? "…" : ""}`);
		const questions = strings(h.open_questions);
		if (questions.length) lines.push(`Open questions: ${questions.join("; ")}`);
	}
	const commits = flowCommits(run.worktree.path, run.id, run.worktree.base).length;
	lines.push(commits > 0
		? `The work is on branch ${run.worktree.branch} (${commits} commit${commits === 1 ? "" : "s"} since ${run.worktree.base.slice(0, 7)}; worktree ${run.worktree.path}). To take it, in ${run.project}: git merge ${run.worktree.branch}`
		: `No commits on branch ${run.worktree.branch}.`);
	lines.push(`The record: .pi/akit-flow/runs/${run.id}`);
	return lines;
}
