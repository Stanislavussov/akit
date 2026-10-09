# Machine setup: diagnostics and onboarding

Status: designed 2026-10-09 from a day of feedback on a work Mac. `akit doctor` built
2026-10-09 (`AKitDoctor`, `Doctor.report`), with the worktree links (see `layers.md`,
"Local-only files and git worktrees"); **Help → Copy Diagnostics** in the app built
2026-10-10 (the same `Doctor.report`, with the app's settings and its project folders, and a
short note at the bottom of the window when the report is on the clipboard). Onboarding in the app is a proposal; the user reviews it
before it is built.

## Problem

On a second Mac (a work Mac) AKit is installed from the repo, but nobody there has the
context of how it was built. When something is missing or broken, the agent on that Mac
can't tell what AKit expects, so the fix waits for the home Mac and an update. And AKit
guesses tools and folders; when the guess is wrong, nothing says so.

## `akit doctor`

A read-only report for an agent (or a person) on any Mac. It prints what AKit sees and
what is wrong, never a secret (no auth files, tokens, MCP env or header values,
`settings.local.json`).

| Section | Shows |
|---|---|
| AKit | version, the source folder of the build, `~/.local/bin/akit` and `~/Applications/AKit.app` present |
| This Mac | personal or work, `machine.json` problems, where project records are kept |
| Brain | path, exists, git repo, remote, ahead/behind, problems of its layers |
| Tools | each harness found: config folder, version; `PI_CODING_AGENT_DIR` |
| Project folders | the roots setting, how many projects found |
| Projects | each set-up project: its folder on this Mac or "not on this Mac", local only or committed, exclude block present (or broken, with the fix by hand: `akit apply` can't fix it), worktrees and the links each one lacks |
| Logs | crash reports of AKit in `~/Library/Logs/DiagnosticReports`, the newest three by name and date; `~/.akit/backups` size |

A line starting with `!` is a problem, with what to do. Exit code 0 even with problems
(it is a report, not a check). The `akit` skill that a new brain gets says: when AKit
doesn't behave, run `akit doctor` first.

In the app: **Help → Copy Diagnostics** puts the same report on the clipboard, to paste
into an agent session.

## Onboarding (proposal)

A required first-run sheet in the app, **Set Up This Mac**, also reachable from Settings
(**Run Setup Again…**). It replaces guessing with answers the user confirms. Defaults are
preselected from what AKit detects; the sheet only needs a click when detection is right.

| Step | Asks | Preselected from |
|---|---|---|
| Tools | which agents are used (Claude Code, Pi, Codex, OpenCode, custom) and what makes worktrees (Pi, herdr, Orca, Claude Code, `git worktree add`) | installed harnesses; worktree folders seen in session history |
| Folders | project folders; Pi's agent folder | the current setting; parents of projects in session history |
| This Mac | personal or work; for work, local-only projects by default | `machine.json` |
| Brain | its path; clone, create, or later | the current setting |

What the answers change: Set Up Project's default targets (the tools picked, not every
installed harness); the folders scanned; for a worktree tool that can run a command after
it makes a worktree, the sheet shows the line to add (`akit worktrees sync`).

The sheet comes back when a picked tool or folder is no longer found. Saved in
`~/.akit/onboarding.json` (no secrets, never in the brain).
