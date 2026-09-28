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
- Stores facts, never message text (one opt-in exception, see Evals): sessions, requests with recorded tokens, every
  tool call with its output size, skill exposure and skill calls, machine label.
- Import is incremental: remembers each file and the offset it read up to.
- Every record keeps the parser version. Raw logs expire, so later parser fixes
  migrate the index itself; store facts generously from the start.
- Hooks never open SQLite: they append one line to `~/.akit/index/spool.jsonl`
  and the import moves the lines into the database. Parallel session starts and a
  running import can't block or slow each other.
- Why a durable index: Claude Code deletes logs after `cleanupPeriodDays` (default 30).
  Before/after comparisons and observation windows need longer history.
- Brain gets small per-project summaries with a machine label,
  `projects/<id>/usage/<machine>.json`: calls per skill (model / user), sessions
  with the skill listed, average first-request context. Recommendations sum them
  over all machines, so a skill used only on the work Mac is not demoted by the home Mac.

### Work machines: nothing about work leaves the Mac

Sessions and the index never leave any machine. On a machine marked **work**
(see `layers.md`, "Work machines") the brain gets only one file,
`insights/machines/<pseudonym>.json`: for each skill **that is in the brain**,
sessions where it was listed and model / user calls, per day. No project ids,
paths, branches, plugins, third-party skill names or prompt text; the opt-in
eval examples stay off there. Work projects' per-project summaries stay local.
So a skill needed at work is not demoted at home, and the brain learns nothing it
didn't already hold except counts.

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

Manual really removes the description (checked 2026-09-26): the three
`disable-model-invocation: true` skills in `~/.claude/skills` (`akit`, `zoom-out`,
`setup-matt-pocock-skills`) are absent from a live Claude `skill_listing`, auto
skills are present. Pi too (checked 2026-09-27, Pi 0.84.2, with the
`PiPromptProbe` extension in a project with one manual and one auto skill in
`.agents/skills`): the manual skill is still in `systemPromptOptions.skills`, but
neither its name nor its description is in the final system prompt; the auto
skill's description is. So the later Pi denominator (`before_agent_start` skills)
must drop manual skills. Pi loads project skills only in trusted folders
(`~/.pi/agent/trust.json`). If a harness keeps the description, the rule saves
nothing there and must not recommend for it.

Subagents: their transcripts (`<session>/subagents/*.jsonl`) carry their own
`skill_listing` (19 of the last 20 checked). A subagent run is not a session in
the denominator; its model calls do count as calls (they protect the skill).

### Rule: auto → manual

- Only calls by the model count. A skill called only via `/name` still works in
  manual mode, so it is recommended too.
- Recommend when the skill was listed in ≥ N sessions over ≥ D days across all
  machines and the model called it 0 times. Proposed defaults: N = 20, D = 14.
- Count only sessions where the skill was actually listed.
- A new or changed skill (description changed) starts its window again.
- The window is also per project: when a layer is added to a project, its skills
  start counting there from that `apply` (date from the project's lock history in the brain).
- `keep_auto: true` on the skill in `layer.yaml` pins it; `dismiss` sets it.
- Dismissed advice outside layers (plugins, hand-installed skills) is stored in the
  brain: `insights/dismissed.json` for global advice, `projects/<id>/dismissed.json`
  for per-project advice. A dismissed advice returns only if its evidence grows
  a lot (e.g. twice the context space).
- Output is sorted by ≈ context space (description tokens × requests in the window),
  with the call rate next to it, so almost-dead skills show up too.

### Scope: every listed skill, action by owner

- Summary on top: ≈ context per request by owner (layers, plugins, hand-installed,
  built-in).
- Layer skill → patch to `layer.yaml` (mode `manual`), applied through `plan`/`apply`.
- Plugin → advice only, one per plugin: disable it in this project if other projects
  use it, otherwise globally; only when the model calls none of its skills (see Interface). Writing `enabledPlugins` waits for harness settings in layers.
- Hand-installed skill → advice: import into the brain in manual mode.
- A layer lists it (e.g. as manual), but the installed copy is not one AKit wrote
  (`akit apply` skips such files) → advice: `akit apply --home --include-unmanaged`
  (or `--include PATH`) so the layer's mode takes effect. `akit stats` counts these as
  owner `unknown`.
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
Recommendations use exact, git and path-template bindings by default; sibling bindings
behind a flag. A path template names the repository (`{repo}` in the path), so it counts
like a git confirmation (decided 2026-09-28: most old sessions ran in deleted Orca and herdr
worktrees whose branches were squash-merged and deleted, so git can't confirm them). Orca
(`~/orca/workspaces/{repo}/*`) and herdr (`~/.herdr/worktrees/{repo}/*`) are built in; other
tools go into `pathTemplates`, and `akit stats bindings` suggests templates from unbound
folders that name a known repository.

### Capturing before the folder disappears

- Claude: an `akit` plugin in a local marketplace inside the brain, hook
  `SessionStart` → `akit record-session`. Installed by Claude itself
  (`claude plugin marketplace add` + `claude plugin install`; to verify against
  the current Claude Code), so AKit writes only its own files. Later the same
  plugin is the adapter for memory injection.
- The hook prints nothing (SessionStart output lands in the agent's context),
  reads `session_id`, `cwd`, `transcript_path` from stdin, only appends to the
  spool file, and always exits 0.
- Pi: an extension file in `~/.pi/agent/extensions/`, owned by AKit, same facts.
- Safety net: launchd runs `akit sessions import` hourly (also parses the sessions).
- The spool is one file per UTC day in `~/.akit/index/spool/`; each line is appended with
  one `O_APPEND` write and no lock. That keeps parallel sessions' lines whole on a local
  APFS home; homes on NFS or SMB are not supported. `akit apply` appends an `apply` line too.

### Evals (later, but examples are kept from v1)

- Not in v1: the auto → manual rule needs none (a manual skill is never model-called),
  and the before/after measurement is its proof. Evals come when `recommend` shows
  enough "rewrite the description" cases.
- AKit has no own eval runner. Triggering evals and description tuning belong to
  skill-creator; AKit's part is real examples, exported in skill-creator's eval format.
- Positive example: a manual `/name` call means the model should have picked the
  skill itself. Raw logs expire, so from v1 on an opt-in setting keeps, per manual
  call, only the user's request that led to it (the `/name` arguments and the user
  message right before). Masked with `SecretFilter`, local index only, never the brain.
  This is the one exception to "no message text".
- Negative examples can't come from passive data (no judge knows whether the skill
  was needed), so v1 of the export takes a few hand-written ones.

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
- A plugin is enabled or disabled as a whole, so its skills are judged together:
  one advice per plugin and scope, with `"skill": "*"` and the skills it is about
  in `evidence.skills` (only plugin advice has that field; JSON stays version 1).
  `disablePluginInProject` / `disablePluginGlobally` when the model called none
  of its listed skills in scope and the plugin as a whole meets N sessions / D days
  (evidence summed over its skills; another Mac's day counts the most sessions any
  one skill was listed in); otherwise at most one `unusedPluginSkills` note with
  the never-called skills that meet the rule on their own. Ids hash
  `rule|plugin|<name>|*|scope` (disable) and `rule|plugin|<name>|*unused|scope` (note).

## Order

0. By hand, today: `"cleanupPeriodDays": 365` in `~/.claude/settings.json`.
   Optionally disable the `marketing` and `customer-support` plugins where they
   aren't needed (≈ 1.1k tokens per request); note the date, it is the first
   before/after pair for calibration.
1. SQLite index + incremental import (Claude, Pi) + debug `stats` to check the
   parser on real logs (model vs. `/name` calls, sizes, subagents). Confirm that
   manual hides the skill in Pi.
2. Claude plugin with the hook (`cwd`, `gitdir`, remote) + Pi extension + hourly launchd.
3. Project binding chain with confidence levels.
4. Full `akit stats`.
5. Per-machine summaries in the brain.
6. `akit recommend` + `dismiss`.
7. Before/after measurement + calibration.
8. Later: OpenCode, Codex, Insights screen, AGENTS.md size findings, behavior lessons,
   export of manual-call examples to skill-creator evals.
