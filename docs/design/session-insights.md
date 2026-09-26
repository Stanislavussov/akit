# Session insights: trim the harness config from real usage

Status: design agreed 2026-09-26 (grilling session). Nothing implemented yet.

## Goal

Find what the harness config costs in every request and is not used, and turn it
into ordinary layer edits (`plan` → `apply`). First target: auto skills the model
never calls. Every skill description sits in the context of every request.

Measured on one Claude Code session in this repo: the skill listing alone was
≈ 7.5k tokens (121 skills). ≈ 3.2k of it came from plugins, including `marketing`
and `customer-support` in a Swift project.

Not the goal of v1: lessons about agent behavior (re-reads, large tool outputs).
The index keeps the raw facts for it, so it can come later without a re-import.

## What already exists

- `Sessions/ClaudeSessions.swift`, `PiSessions.swift`: sessions → `SessionSummary`,
  `SessionTranscript`, `SessionUsage` (tokens per model, cache, peak context,
  subagents, tool counts, errors, compactions).
- Usage screen: daily usage for Claude, Pi, Codex, OpenCode; cost only when recorded.
- `PromptSnapshot`: system prompt, tools and loaded context, incl. Claude's `skill_listing`.
- `ProjectSetup.projectID`: `origin` remote normalized to `github.com/owner/repo`,
  else `local/…`.

New in this design: a durable index, project binding that survives deleted worktrees,
cross-session and cross-machine aggregation, recommendations.

## Decisions

### Storage

- Local SQLite index in `~/.akit/index/` (system `SQLite3`, no new dependency). Not in git.
- Stores facts, never message text: sessions, requests with recorded tokens, every
  tool call with its output size, skill exposure and skill calls, machine label.
- Import is incremental: remembers each file and the offset it read up to.
- Why a durable index: Claude Code deletes logs after `cleanupPeriodDays` (default 30).
  Before/after comparisons and observation windows need longer history.
- Brain gets small per-project summaries with a machine label,
  `projects/<id>/usage/<machine>.json`: calls per skill (model / user), sessions
  with the skill listed, average first-request context. Recommendations sum them
  over all machines, so a skill used only on the work Mac is not demoted by the home Mac.

### Reading skill use from logs (verified on real sessions)

| | Listed (denominator) | Called by the model | Called by the user |
|---|---|---|---|
| Claude Code | `attachment.type == "skill_listing"` | `tool_use` `name: "Skill"`, `input.skill` | `<command-name>/x` |
| Pi | not recorded | `toolCall read` of an installed `…/SKILL.md` | user message starting `<skill name="x" location=…>` |

- Pi model calls count only for paths of installed skills (project `.agents/skills`,
  `~/.agents/skills`, Pi skill folders), never `~/.akit/registry` or temp folders
  (reading or writing a SKILL.md while editing it is not a call).
- v1: the denominator comes from Claude only. Pi calls can only protect a skill
  (a model call blocks the recommendation) and never demote one. The report lists
  "no data (Pi only)" skills.
- Later: the Pi extension also records the skill list (`before_agent_start`
  `systemPromptOptions.skills`, the same hook `PiPromptProbe` already uses) into
  AKit's own file, and Pi joins the denominator.

### Rule: auto → manual

- Only calls by the model count. A skill called only via `/name` still works in
  manual mode, so it is recommended too.
- Recommend when the skill was listed in ≥ N sessions over ≥ D days across all
  machines and the model called it 0 times. Proposed defaults: N = 20, D = 14.
- Count only sessions where the skill was actually listed.
- A new or changed skill (description changed) starts its window again.
- `keep_auto: true` on the skill in `layer.yaml` pins it; `dismiss` sets it.
- Output is sorted by ≈ context space (description tokens × requests in the window),
  with the call rate next to it, so almost-dead skills show up too.

### Scope: every listed skill, action by owner

- Summary on top: ≈ context per request by owner (layers, plugins, hand-installed,
  built-in).
- Layer skill → patch to `layer.yaml` (mode `manual`), applied through `plan`/`apply`.
- Plugin → advice only: disable it in this project if other projects use it,
  otherwise globally. Writing `enabledPlugins` waits for harness settings in layers.
- Hand-installed skill → advice: import into the brain in manual mode.
- Built-in → cost only, collapsed.

### Cost metric

- Named "≈ context space", never money.
- Size ≈ characters / k, marked ≈. k differs for Latin and Cyrillic, and is
  calibrated from before/after measurements (character delta vs. recorded token delta).
- Proof uses recorded data: the first request's context (input + cache read +
  cache write) of sessions in the project before and after `apply`. Compare only
  sessions with the same harness version and model, close in time; otherwise
  "not enough data".

### Binding a session to a project

~70% of Claude session folders no longer exist (mostly short-lived worktrees), so
`git remote` at analysis time fails. Signals, most reliable first; each binding
keeps its method and confidence:

1. SessionStart hook (while the folder exists): `cwd`, `gitdir` of a worktree
   (`.git` file → main repo), `origin` remote, session id.
2. `git worktree list --porcelain` in known repos (lists deleted worktrees as
   prunable until pruned).
3. `gitBranch` from Claude logs confirms a candidate repo.
4. Siblings: a resolved folder with the same parent (`<root>/<repo>/<branch>`).
5. Path templates / aliases in config, e.g. `~/orca/workspaces/{repo}/*`.
6. Otherwise "no project".

Not tied to any workspace tool (Orca, herdr, …). Tool-specific resolvers are
optional plugins behind "path → repo or nothing", starting with path templates.
Recommendations use exact and git bindings by default; sibling bindings behind a flag.

### Capturing before the folder disappears

- Claude: an `akit` plugin in a local marketplace inside the brain, hook
  `SessionStart` → `akit record-session`. Installed by Claude itself
  (`claude plugin marketplace add` + `claude plugin install`; to verify against
  the current Claude Code), so AKit writes only its own files. Later the same
  plugin is the adapter for memory injection.
- The hook prints nothing (SessionStart output lands in the agent's context),
  reads `session_id`, `cwd`, `transcript_path` from stdin, is fast and always exits 0.
- Pi: an extension file in `~/.pi/agent/extensions/`, owned by AKit, same facts.
- Safety net: launchd runs `akit sessions import` hourly (also parses the sessions).

### Interface

- CLI first: `akit stats` (text, `--json`) and `akit recommend`
  (`apply <id>`, `dismiss <id>`). The JSON is the contract for `/akit` now and
  an Insights screen later.
- A recommendation has a stable id, evidence (sessions, period, machines,
  binding method, confidence, ≈ context) and an edit as a layer patch that goes
  through the usual `plan`.
- Compact by default (summary + top N); details on request, since the agent pays
  tokens for what it reads.
- Advice outside layers is in the same list, typed "advice", without `apply`.

## Order

0. By hand, today: raise `cleanupPeriodDays` in `~/.claude/settings.json`.
1. SQLite index + incremental import (Claude, Pi) + debug `stats` to check the
   parser on real logs (model vs. `/name` calls, sizes).
2. Claude plugin with the hook (`cwd`, `gitdir`, remote) + Pi extension + hourly launchd.
3. Project binding chain with confidence levels.
4. Full `akit stats`.
5. Per-machine summaries in the brain.
6. `akit recommend` + `dismiss`.
7. Before/after measurement + calibration.
8. Later: OpenCode, Codex, Insights screen, AGENTS.md size findings, behavior lessons.
