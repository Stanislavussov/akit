// flow-git.ts: written by AKit (docs/design/flows.md F8, F9). The run's git: its worktree outside
// the project tree on the branch `akit-flow/<run>`, one commit per finished step with trailers,
// and reading those trailers back on resume.

import { spawnSync } from "node:child_process";
import { existsSync, mkdirSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join } from "node:path";

export const BRANCH_PREFIX = "akit-flow/";

/** The run's worktree, outside the project tree. Review's path rule: AKit Review keeps a run's
 * worktree at `~/.akit/local/review/runs/<run>/worktree` on the branch `akit-review/<run>`
 * (ReviewPaths.run in AKitCore/Sources/AKitReview/ReviewCatalog.swift, Gather.swift); a flow run's
 * is `~/.akit/local/flows/runs/<run>/worktree` on `akit-flow/<run>`. */
export function worktreeFolder(run: string): string {
	return join(homedir(), ".akit", "local", "flows", "runs", run, "worktree");
}

export function git(cwd: string, args: string[]): { ok: boolean; out: string; err: string } {
	const r = spawnSync("git", args, { cwd, encoding: "utf8", maxBuffer: 64 * 1024 * 1024 });
	return { ok: r.status === 0, out: (r.stdout ?? "").trimEnd(), err: (r.stderr ?? r.error?.message ?? "").trim() };
}

export interface Worktree {
	path: string;
	branch: string;
	/** The project commit the run branch starts from. */
	base: string;
}

/** Adds the run's worktree on a new branch at the project's HEAD. */
export function createWorktree(project: string, run: string): Worktree | { error: string } {
	const head = git(project, ["rev-parse", "--verify", "HEAD"]);
	if (!head.ok) return { error: "The project has no commit yet; a flow runs on a branch from HEAD." };
	const path = worktreeFolder(run);
	const branch = BRANCH_PREFIX + run;
	mkdirSync(dirname(path), { recursive: true });
	const added = git(project, ["worktree", "add", "-q", "-b", branch, path, head.out]);
	if (!added.ok) return { error: `git worktree add failed: ${added.err}` };
	return { path, branch, base: head.out };
}

/** `git status --porcelain` lines of the worktree: uncommitted and untracked changes. */
export function changes(worktree: string): string[] {
	const r = git(worktree, ["status", "--porcelain", "--untracked-files=all"]);
	return r.out ? r.out.split("\n") : [];
}

/** What the worktree changed since the last commit, from git (the truth a handoff's `files` is
 * checked against): added, changed or removed per path; a rename is its new path, changed. */
export function changedFiles(worktree: string): { path: string; change: string }[] {
	return changes(worktree).map((line) => {
		const code = line.slice(0, 2);
		const path = line.slice(3).split(" -> ").pop() ?? "";
		const change = code.includes("?") || code.includes("A") ? "added" : code.includes("D") ? "removed" : "changed";
		return { path: path.replace(/^"|"$/g, ""), change };
	}).filter((f) => f.path);
}

/** Commits everything in the worktree (empty commits too: the trailers mark the finished step). */
export function commit(worktree: string, message: string, trailers: Record<string, string>): { commit: string } | { error: string } {
	const added = git(worktree, ["add", "-A"]);
	if (!added.ok) return { error: added.err };
	const subject = message.split("\n")[0].trim() || "Flow step";
	const lines = Object.entries(trailers).map(([k, v]) => `${k}: ${v}`).join("\n");
	const done = git(worktree, ["commit", "-q", "--allow-empty", "-m", subject, "-m", lines]);
	if (!done.ok) return { error: done.err || "git commit failed" };
	return { commit: git(worktree, ["rev-parse", "HEAD"]).out };
}

export interface FlowCommit {
	commit: string;
	trailers: Record<string, string>;
}

/** The run's commits after `base`, newest first, with their `Flow-*` trailers. */
export function flowCommits(worktree: string, run: string, base: string): FlowCommit[] {
	const r = git(worktree, ["log", "--format=%H%x1f%B%x1e", `${base}..HEAD`]);
	if (!r.ok || !r.out) return [];
	const commits: FlowCommit[] = [];
	for (const entry of r.out.split("\x1e")) {
		const [hash, body] = entry.trim().split("\x1f");
		if (!hash || body === undefined) continue;
		const trailers: Record<string, string> = {};
		for (const m of body.matchAll(/^(Flow-[A-Za-z]+):\s*(.+)$/gm)) trailers[m[1]] = m[2].trim();
		if (trailers["Flow-Run"] === run) commits.push({ commit: hash, trailers });
	}
	return commits;
}

/** Puts the worktree back to `commit`, dropping uncommitted and untracked changes. */
export function resetTo(worktree: string, commit: string): boolean {
	return git(worktree, ["reset", "-q", "--hard", commit]).ok && git(worktree, ["clean", "-q", "-fd"]).ok;
}

/** What the run branch changed against its base, the work tree included. */
export function diffFromBase(worktree: string, base: string): string {
	const stat = git(worktree, ["diff", "--stat", base]).out;
	const diff = git(worktree, ["diff", base]).out;
	return stat || diff ? `${stat}\n\n${diff}\n` : "No changes against the base.\n";
}

export function worktreeExists(path: string): boolean {
	return existsSync(join(path, ".git"));
}
