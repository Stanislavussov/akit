# Machine setup: diagnostics and onboarding

Status: designed 2026-10-09 from a day of feedback on a work Mac. `akit doctor` built
2026-10-09 (`AKitDoctor`, `Doctor.report`), with the worktree links (see `layers.md`,
"Local-only files and git worktrees"); **Help → Copy Diagnostics** in the app built
2026-10-10 (the same `Doctor.report`, with the app's settings and its project folders, and a
short note at the bottom of the window when the report is on the clipboard); **Help → Report a Bug… / Suggest a Feature…** built 2026-10-11 (`IssueReport`); the **Update** button built 2026-10-17 (`SourceUpdate`). Onboarding in the app is a proposal; the user reviews it
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

**Help → Report a Bug…** and **Help → Suggest a Feature…** (2026-10-11, `AKitDoctor/IssueReport.swift`)
open GitHub's new-issue page for AKit in the browser, with a label and a template in the link:
the sections to fill in, the AKit version and the macOS version. AKit sends nothing and needs
no token; the user posts the issue. GitHub applies the label (`bug`, `enhancement`) only for
people who may label issues in the repository; other issues arrive without one. The diagnostics report is not put into the link: it names
the user's projects and the issue is public, so the bug template only asks for it.

## Updating AKit from its source folder

Built 2026-10-17 (`AKitDoctor/SourceUpdate.swift`, the app's `AppUpdate.swift`). A copy of
AKit knows the folder, branch and commit it was built from (`BuildInfo.plist`). When that
branch in that folder has commits after the build's commit (a feature merged into `master`
in `~/Projects/akit`), the sidebar shows **Update to <version>** above the build badge, and
**AKit → Update to …** does the same. It runs `make install` there for the copy in
`~/Applications` (`make build` for a Debug copy in a worktree's `build/`), starts the new app
and quits; a failed build leaves the running app open with the reason.

- Revised 2026-10-23 (the user: a release pushed from one Mac never showed on the other): the
  check runs `git fetch --tags <remote> <branch>` of the branch's upstream first (no password
  prompt, `GIT_TERMINAL_PROMPT=0`, SSH in batch mode added to the user's own SSH command; offline
  it just finds nothing), and an upstream ahead of the folder is an update too. The fetch writes
  objects, the remote-tracking ref and tags into the repository (no auto gc, no FETCH_HEAD); the
  working files don't change. Update then runs `git pull --ff-only` before `make install`; a
  folder with commits of its own on top isn't pulled (its own commits are the update, and the
  tooltip says how many upstream commits to merge by hand), and a failed pull shows git's reason.
- A copy installed from a release zip (`install.sh` without a checkout) has no source folder
  and no Update button: it updates by running `install.sh` again, which takes the latest GitHub
  Release. A new version needs `make release` and `gh release create <tag> dist/AKit.zip`, not
  only a pushed tag.
- Checked at launch, every 5 minutes, when AKit comes to the front (at most every 20 s) and
  with **AKit → Check for Updates**.
- Another branch checked out in the folder: no button, a build would be of that branch.
- Uncommitted changes to tracked files: the update asks first (**Update Anyway**), since
  another agent session may be working in the main checkout.
- Not covered: copies installed from a release zip (`install.sh` without a source folder);
  `install.sh` run again updates them.

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
