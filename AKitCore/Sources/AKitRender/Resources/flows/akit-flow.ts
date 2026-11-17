// akit-flow.ts: written by AKit (docs/design/flows.md F1, F11). The Pi extension that runs a flow:
// `/flow [name] <task>` and `/flow resume [run-id]`. Thin: routing is in flow-core.ts, every Pi
// call in pi-adapter.ts, the record in flow-record.ts; each child gets akit-flow-handoff.ts. Flows come from <project>/.pi/flows, then
// ~/.pi/agent/flows.

import { execFileSync } from "node:child_process";
import { randomBytes } from "node:crypto";
import { existsSync, readdirSync, readFileSync, rmSync } from "node:fs";
import { homedir } from "node:os";
import { basename, dirname, isAbsolute, join } from "node:path";
import { fileURLToPath } from "node:url";
import {
	compareVersions, type Decision, DEFAULT_MAX_LOOPS, firstStep, type Flow, formatProblem, isOutcome, isSafeCommand, MAX_CHECK_COMMANDS, nextStep,
	type Outcome, parseOutcome, requiredPi, runId, TESTED_PI, type Visits,
} from "./flow-core.ts";
import { changes, commit, createWorktree, flowCommits, resetTo, type Worktree, worktreeExists } from "./flow-git.ts";
import {
	appendEvent, checksGreen, createRunFolder, HANDOFF_SCHEMA, handoffName, latestRun, readEvents, type RecordedEvent, recordTokens, releaseLock,
	RUN_SCHEMA, runChecks, stepKey, takeLock, visitsFrom, writeAtomic,
} from "./flow-record.ts";
import {
	type ChildResult, detectPi, type ExtensionAPI, type ExtensionCommandContext, missingFlags, onShutdown, type PiInfo, readFlowFile,
	registerFlowCommand, runChild, say, sessionFile, status,
} from "./pi-adapter.ts";

const here = dirname(fileURLToPath(import.meta.url));
let warnedNewerPi = false;

export default function akitFlow(pi: ExtensionAPI): void {
	const controller = new AbortController();
	registerFlowCommand(pi, (args, ctx) => flowCommand(args, ctx, controller.signal));
	onShutdown(pi, () => controller.abort());
}

/** `/flow …`; exported for the tests. */
export async function flowCommand(args: string, ctx: ExtensionCommandContext, signal?: AbortSignal): Promise<void> {
	const words = args.trim().split(/\s+/).filter(Boolean);
	if (words[0] === "resume") return resume(ctx, words[1], signal);
	return start(ctx, words, signal);
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

async function loadFlow(ctx: ExtensionCommandContext, project: string, name: string): Promise<Flow | undefined> {
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
async function checkPi(ctx: ExtensionCommandContext, flow: Flow): Promise<{ info: PiInfo; newer: boolean } | undefined> {
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

async function start(ctx: ExtensionCommandContext, words: string[], signal?: AbortSignal): Promise<void> {
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
	const run: Run = { folder, id, flow, task, project, info: pi.info, newer: pi.newer, started: new Date().toISOString(), worktree };
	appendEvent(folder, "run-start", { run: id, flow: flow.name, task, pi: pi.info.version, worktree: worktree.path, branch: worktree.branch, base: worktree.base });
	await loop(ctx, run, firstStep(flow), undefined, signal);
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

function previousFrom(folder: string, flow: Flow, step: string, attempt: number): Previous | undefined {
	const handoff = readHandoff(folder, flow.steps.findIndex((s) => s.id === step), step, attempt);
	if (!handoff) return undefined;
	const from = (handoff.from ?? {}) as { outcome?: unknown; reason?: unknown };
	return { step, outcome: isOutcome(from.outcome) ? from.outcome : "failed", reason: typeof from.reason === "string" ? from.reason : "", handoff };
}

/** `/flow resume`: events.jsonl and the commit trailers are the truth; run.json is rebuilt (F9). */
async function resume(ctx: ExtensionCommandContext, id: string | undefined, signal?: AbortSignal): Promise<void> {
	const project = mainCheckout(ctx.cwd);
	const folder = id ? join(project, ".pi", "akit-flow", "runs", id) : latestRun(project);
	if (!folder || !existsSync(folder)) {
		say(ctx, id ? `No run ${id}.` : "No run to resume.", "error");
		return;
	}
	const events = readEvents(folder);
	if (events.some((e) => e.type === "run-end")) {
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

async function resumeLocked(ctx: ExtensionCommandContext, project: string, folder: string, events: RecordedEvent[], signal?: AbortSignal): Promise<void> {
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
	const flow = await loadFlow(ctx, project, name);
	const pi = flow ? await checkPi(ctx, flow) : undefined;
	if (!flow || !pi) return;
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
			resetTo(worktree.path, target);
			previous = commits[0] ? previousFrom(folder, flow, commits[0].trailers["Flow-Step"] ?? "", Number(commits[0].trailers["Flow-Attempt"])) : undefined;
			const step = flow.steps.find((s) => s.id === last.step);
			const count = (visits[last.step] ?? 0) + 1;
			decision = !step ? { stop: "unknown-step", step: last.step, visits }
				: count > (step.maxLoops ?? DEFAULT_MAX_LOOPS) ? { stop: "visit-cap", step: last.step, visits }
				: { next: last.step, visits: { ...visits, [last.step]: count } };
		}
	} else {
		previous = previousFrom(folder, flow, last.step, last.attempt ?? visits[last.step] ?? 1);
		decision = nextStep(flow, { step: last.step, visits }, (last.outcome ?? "failed") as Outcome, last.reason ?? "");
	}
	// Resume is the user's word to go on: a STOP left from the halt is removed.
	const stopped = existsSync(join(folder, "STOP"));
	rmSync(join(folder, "STOP"), { force: true });
	appendEvent(folder, "resume", { run: run.id, ...(stopped ? { removed: "STOP" } : {}) });
	await loop(ctx, run, decision, previous, signal);
}

function resolveSkill(project: string, name: string): string | undefined {
	if (isAbsolute(name)) return existsSync(name) ? name : undefined;
	const home = homedir();
	return [join(project, ".pi", "skills", name), join(home, ".pi", "agent", "skills", name), join(project, ".agents", "skills", name),
		join(home, ".agents", "skills", name)].find((p) => existsSync(p));
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

/** The model's part of a handoff, as `flow_handoff` wrote it (F4). */
interface HandoffPart {
	goal: string;
	done: string[];
	files: { path: string; change: string }[];
	open_questions: string[];
	notes: string;
	outcome: Outcome;
	reason: string;
}

const strings = (value: unknown): string[] => (Array.isArray(value) ? value.filter((v): v is string => typeof v === "string") : []);

/** The file `flow_handoff` wrote, or undefined when there is none or it has no valid outcome. */
function readPart(path: string): HandoffPart | undefined {
	if (!existsSync(path)) return undefined;
	try {
		const v = JSON.parse(readFileSync(path, "utf8")) as Record<string, unknown>;
		if (!isOutcome(v.outcome)) return undefined;
		const files = Array.isArray(v.files) ? v.files.filter((f): f is { path: string; change: string } => typeof f?.path === "string")
			.map((f) => ({ path: f.path, change: typeof f.change === "string" ? f.change : "" })) : [];
		return {
			goal: typeof v.goal === "string" ? v.goal : "", done: strings(v.done), files, open_questions: strings(v.open_questions),
			notes: typeof v.notes === "string" ? v.notes : "", outcome: v.outcome, reason: typeof v.reason === "string" ? v.reason : "",
		};
	} catch {
		return undefined;
	} finally {
		rmSync(path, { force: true });
	}
}

interface Previous {
	step: string;
	outcome: Outcome;
	reason: string;
	/** The previous step's handoff file, as written. */
	handoff: Record<string, unknown>;
	/** Failed checks of the previous step: command, exit code, last lines. */
	failedChecks?: { command: string; exit: number | null; tail: string[] }[];
}

function prompt(run: Run, stepId: string, agent: string, previous: Previous | undefined): string {
	const lines = [
		`You are the ${agent} step "${stepId}" of the AKit flow "${run.flow.name}" (run ${run.id}).`,
		`Task: ${run.task}`,
	];
	if (previous) {
		lines.push("", `Handoff from the step "${previous.step}" (${previous.outcome}${previous.reason ? `:${previous.reason}` : ""}):`,
			JSON.stringify(previous.handoff, null, 2));
		for (const check of previous.failedChecks ?? []) {
			lines.push("", `The check \`${check.command}\` exited ${check.exit}. Its last lines:`, ...check.tail);
		}
	}
	lines.push("", "When the step is finished, call the tool flow_handoff once with what you did and the outcome: done, failed or blocked (with a reason).");
	return lines.join("\n");
}

async function loop(ctx: ExtensionCommandContext, run: Run, first: Decision, previous: Previous | undefined, signal?: AbortSignal): Promise<void> {
	let decision = first;
	let visits: Visits = decision.visits;
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
			writeRunJson(run, { status: "running", state: { step: step.id, visits } });
			status(ctx, `flow ${run.flow.name}: ${index + 1}/${run.flow.steps.length} ${step.id}`);
			const checks = step.checks ?? [];
			const unsafe = checks.find((c) => !isSafeCommand(c));
			if (unsafe !== undefined || checks.length > MAX_CHECK_COMMANDS) {
				appendEvent(run.folder, "deviation", { step: step.id, rule: "check-refused", detail: unsafe ?? `${checks.length} commands` });
				return finish(ctx, run, { stop: "check-refused", step: step.id, visits },
					`Step ${step.id} has a check the runner refuses (${unsafe ?? `more than ${MAX_CHECK_COMMANDS} commands`}); fix it in AKit and Apply.`);
			}
			const skills: string[] = [];
			for (const name of step.skills ?? []) {
				const path = resolveSkill(run.project, name);
				if (!path) {
					appendEvent(run.folder, "deviation", { step: step.id, rule: "skill-missing", detail: name });
					return finish(ctx, run, { stop: "no-route", step: step.id, visits }, `The skill ${name} of step ${step.id} is not installed.`);
				}
				skills.push(path);
			}
			const sessionDir = join(run.folder, "sessions");
			const partPath = join(run.folder, "handoffs", `${key}-a${attempt}.part`);
			let result: ChildResult | undefined;
			let part: HandoffPart | undefined;
			let deviations = 0;
			// No valid flow_handoff: the step reruns once, then the run stops (F4).
			for (let round = 1; round <= 2 && !part; round++) {
				rmSync(partPath, { force: true });
				result = await runChild({
					cwd: run.worktree.path, sessionDir, model: step.model, thinking: step.thinking, skills,
					tools: step.tools ?? [], extensions: childExtensions(run.project, step.extensions ?? []),
					prompt: prompt(run, step.id, step.agent, previous), info: run.info, env: { AKIT_FLOW_HANDOFF: partPath }, signal,
				});
				if (result.aborted || result.spawnError) {
					appendEvent(run.folder, "step-end", { step: step.id, attempt, outcome: "failed", reason: result.aborted ? "aborted" : "spawn", tokens: recordTokens(result.tokens), exit: result.code });
					writeRunJson(run, { status: "stopped", state: { step: step.id, visits } });
					say(ctx, result.aborted ? `Flow ${run.flow.name} aborted in step ${step.id}; /flow resume continues.` : `Can't start pi: ${result.spawnError}`, "error");
					return;
				}
				part = readPart(partPath);
				if (part) break;
				const line = parseOutcome(result.text);
				deviations++;
				if (line) {
					appendEvent(run.folder, "deviation", { step: step.id, attempt, rule: "handoff-fallback", detail: `outcome: ${line.outcome}${line.reason ? `:${line.reason}` : ""}`, session: result.session ?? null });
					part = { goal: run.task, done: [], files: [], open_questions: [], notes: result.text, ...line };
					break;
				}
				appendEvent(run.folder, "deviation", { step: step.id, attempt, rule: "handoff-missing", action: round === 1 ? "rerun" : "stopped", session: result.session ?? null });
			}
			if (!result || !part) {
				appendEvent(run.folder, "step-end", { step: step.id, attempt, outcome: "failed", reason: "no-handoff", tokens: recordTokens(result?.tokens ?? {}), exit: result?.code ?? null });
				return finish(ctx, run, { stop: "no-handoff", step: step.id, visits }, `Flow ${run.flow.name} stopped: step ${step.id} ended twice without flow_handoff.`);
			}
			let { outcome, reason } = part;
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
				open_questions: part.open_questions, notes: part.notes, tokens: recordTokens(result.tokens), deviations,
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
			previous = { step: step.id, outcome, reason, handoff, failedChecks };
		}
		finish(ctx, run, decision);
	} finally {
		releaseLock(run.folder);
	}
}

/** Visits before the step that was about to start: a halt leaves that visit uncounted. */
function previousVisits(visits: Visits, step: string): Visits {
	const count = (visits[step] ?? 1) - 1;
	const rest = { ...visits };
	if (count > 0) rest[step] = count;
	else delete rest[step];
	return rest;
}

function finish(ctx: ExtensionCommandContext, run: Run, decision: Decision, message?: string): void {
	if ("next" in decision) return;
	if (decision.stop === "no-route" && !message) appendEvent(run.folder, "deviation", { step: decision.step, rule: "no-route" });
	appendEvent(run.folder, "run-end", { stop: decision.stop, ...(decision.step ? { step: decision.step } : {}) });
	writeRunJson(run, { status: decision.stop === "done" ? "done" : "stopped", stop: decision.stop, state: { step: decision.step ?? null, visits: decision.visits } });
	status(ctx, undefined);
	const text = message ?? (decision.stop === "done" ? `Flow ${run.flow.name} done (run ${run.id}).`
		: decision.stop === "visit-cap" ? `Flow ${run.flow.name} stopped: step ${decision.step} reached its max loops.`
		: decision.stop === "no-route" ? `Flow ${run.flow.name} stopped: step ${decision.step} has no route for its outcome.`
		: `Flow ${run.flow.name} stopped: unknown step ${decision.step}.`);
	say(ctx, text, decision.stop === "done" ? "info" : "error");
}
