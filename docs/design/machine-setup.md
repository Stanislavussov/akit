# Machine setup: diagnostics and onboarding

Status: designed 2026-10-09 from a day of feedback on a work Mac. `akit doctor` built
2026-10-09 (`AKitDoctor`, `Doctor.report`), with the worktree links (see `layers.md`,
"Local-only files and git worktrees"); **Help → Copy Diagnostics** in the app built
2026-10-10 (the same `Doctor.report`, with the app's settings and its project folders, and a
short note at the bottom of the window when the report is on the clipboard); **Help → Report a Bug… / Suggest a Feature…** built 2026-10-11 (`IssueReport`); the **Update** button built 2026-10-17 (`SourceUpdate`). **`akit doctor pi`** and Overview → Pi → **Check Pi…** built 2026-10-24 (`PiDoctor`, see "Pi doctor"). Onboarding in the app is a proposal; the user reviews it
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

## Pi doctor

Built 2026-10-24 (`AKitDoctor/PiDoctor.swift`; the app's `PiDoctorSheet.swift`). The user asked for
a doctor only for Pi that does what Claude Code's does. `claude doctor` (2.1.310) checks the
running version, install method, several installations, ripgrep and auto-updates; its in-session
`/doctor` adds invalid settings files, bad values of known environment variables, MCP config
errors, too-large CLAUDE.md (over 40,000 characters), unreachable permission rules, plugin and
keybinding problems, each with what to do. `akit doctor pi` is the same shape with Pi's facts,
all from the docs shipped in Pi 1.0.4 (and its `dist/` where the docs are silent):

| Section | Checks | Backed by |
|---|---|---|
| Install | `pi` on PATH and its `--version`; every `pi` on PATH, a warning for more than one real installation (a `shims` folder of mise or asdf is not one); `PI_CODING_AGENT_DIR` and `PI_CODING_AGENT_SESSION_DIR` when set; the config folder | `environment-variables.md`, `configuration.md` |
| Settings | `settings.json` (global and each Pi project's `.pi/settings.json`) parses; a key not in the settings reference is a warning ("unknown key"); a value outside a documented set (thinking levels, modes, ranges like `outputPad` 0–1) is a problem; a global-only key in a project is a warning; the default model; `models.json` parses (never shown) | `settings.md` (keys and values), `dist/core/settings-manager.d.ts` (`lastChangelogVersion`, `trackingId`, `deviceId` Pi writes itself), `models.md`, `dist/core/model-config.js` (comments allowed) |
| Environment | Pi's variables with documented values (`PI_TELEMETRY`, `PI_CACHE_RETENTION`, `PI_HARDWARE_CURSOR`, `PI_HYPERLINKS`, `PI_IMAGE_PROTOCOL`, `PI_TRUE_COLOR`, `PI_TUI_ESC_TIMEOUT`); the others shown when set (URLs only as "set") | `environment-variables.md` |
| MCP servers | `mcp.json` (global and projects) parses, `mcpServers` is an object; per server the rules Pi applies: name, `command` or `url`, `type`, SSE refused, `exposure`, `enabled`, `timeout`, args/env/headers types, names that differ only in `-` and `_`, project overrides; a stdio command not found; `env` and `headers` only by key name | `mcp.md` "Configuration rules", `validateMcpServerConfig` in `dist/core/mcp-servers.js`, `OVERRIDE_KEYS` in `dist/extensions/mcp/config.js` |
| Packages and extensions | each `packages` entry installed (AKit's `PiPackages`: `<Pi dir>/npm/node_modules/<name>`, `<Pi dir>/git/<host>/<path>`, a local path); `extensions` entries exist; each item of `extensions/` is a `.ts`/`.js` file or a folder with `index.ts`, `index.js` or a `package.json` whose `pi.extensions` exist (else a warning: Pi loads nothing from it) | `packages.md`, `settings.md` "Resources", `extensions.md`, `discoverExtensionsInDir` in `dist/core/extensions/loader.js` |
| Skills | what `SkillScanner` finds for Pi in the global skills: no description (a problem: Pi skips it), the name rule, long descriptions, collisions; name ≠ folder as a warning (Pi doesn't mind, other Agent Skills tools do); the size of the listing | `skills.md` |
| Context | the global instruction file Pi loads (`InstructionScanner`), a warning over 40,000 characters (Claude Code's `/doctor` line; Pi has none); `SYSTEM.md`, `APPEND_SYSTEM.md` | `configuration.md` |
| Keybindings | `keybindings.json` parses, each value a key or a list, each key in the documented syntax | `keybindings.md` |
| Context from recent sessions | AKit's session index (imported first, like `akit stats`), Pi sessions of the last 30 days: global skills Pi sees with no call and MCP servers whose tools Pi never called, both only past `akit recommend`'s bar (20 sessions on 14 days); the ≈ tokens (characters / 4) of the global instruction file per request; `##` sections the model gets twice in the folders Pi worked in (`InstructionView.duplicates`). Each suggestion is an `akit` command that shows the change and writes only with `--yes` (`akit skills set … --harness pi --state off`, `akit mcp set … --harness pi --off everywhere`, `akit instructions remove FILE --line N`, new: a thin CLI over `InstructionEdit`, the core of Remove This Copy…); the sheet opens the screen with the same action. Never "unused" for a section: sessions don't record that | `skills.md` (Pi records no skill list: `PiFacts`), `InsightsStats.activity`, `ToolStats.report(harness:)` |
| Servers and sign-in (live) | only with `--live` or **Check Servers and Sign-In**: `pi mcp list --json` (state, tool count, errors per server; 90 s) and `pi auth check --provider <defaultProvider> --json --no-refresh` (never `--credentials`; 30 s) | `cli.md`, `list` in `dist/extensions/mcp/cli.js` |

Lines are ok, warning (`?`) or problem (`!`), each problem with what to do (`→`); the text ends
"No problems found." when there is none. `akit doctor pi` exits 1 on a problem; `--json` gives the
sections. `akit doctor` adds one line to its Tools section ("Pi setup: N problems, M warnings").
The app's sheet shows the same lines with colored icons, Copy Report and Refresh.

Not suggested: `exposure: deferred` for a large server (mcp.md allows it, but AKit has no command or
screen to change a server's exposure yet; the user's rule is that every fix goes through an `akit`
command); sections that repeat a skill's text (AKit doesn't detect that). Fixes that still name a
Pi command or a hand edit, because AKit has no operation for them: installing a package (`pi update
--extensions`), MCP and provider sign-in (`pi mcp login`, `/login`), fixing broken JSON.

Not checked: whether Pi trusts a project (`trust.json`), the session folder's contents, themes and
prompt templates, the latest Pi version (that needs the network).

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
