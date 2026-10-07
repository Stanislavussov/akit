# Session insights: trim the harness config from real usage

Status: design agreed 2026-09-26 (grilling session). Steps 0–7 and 10 of the Order
are implemented: SQLite index and import, capture (Claude plugin, Pi extension, hourly
import), project binding, `akit stats`, per-machine summaries, `akit recommend`
(apply, dismiss), before/after measurement with k calibration (`akit stats changes`,
`akit stats mark`), and the Insights screen (2026-10-07). Revised 2026-10-01 after a review
against Claude Code's own tools and open-source session analyzers: steps 8, 9 and 11–13
(described exposures, plugin token costs, fingerprints and failure signals, more outcomes,
a reconciliation check) are designed, not built. Terms shared with Lab and Error analysis are in
[`definitions.md`](definitions.md).

Checked against the code on 2026-10-03:

- Steps 1–7 are built. Until the Insights screen they were commands only.
- Step 10, first slice (2026-10-03): the Insights screen (sidebar, Improve group) shows the
  context by owner and the recommendations of a scope, with **Apply…** (the `layer.yaml`
  diff, then a commit in the brain), **Dismiss…** and **Import Now**. It reads
  `Recommender.load`, the same calls as `akit recommend --details`; the layer-users query
  moved into `AKitInsights` (`Recommender.projectsUsing`).
- Capture in setup (2026-10-06): `akit setup` installs capture (see "Capturing before the
  folder disappears"), and the Insights screen shows a line when `CaptureInstaller.status`
  finds it off or out of date.
- Install capture and Sync (2026-10-06): the line has **Install Capture…** (one plan per
  part, `CaptureInstaller.partPlans`; only the checked parts run), and the app's brain Sync
  publishes summaries through `InsightsSync`, the sequence `akit sync` runs too.
- Skills table (2026-10-07): the screen shows `akit stats --details` of the scope, with a
  7 / 30 / 90 days picker; `Recommender.load` returns it next to the recommendations. It sits
  below the recommendations, so the actions come first.
- Changes (2026-10-07): the screen shows `akit stats changes` of the scope
  (`BeforeAfter.report`, shared with the CLI) with the calibration line, and **Add Mark…**
  writes a mark through `Spool.mark`, as `akit stats mark`.
- Plan after Apply (2026-10-07): after a committed `mode: manual` patch the screen lists the
  layer's projects; **Plan…** opens Set Up Project for a project folder on this Mac, where the
  change is a diff until Apply. A home folder still says `akit apply --home` (the Home button
  is step 2 of the design map).
- Step 10 is built except these smaller items of its plan below, left until someone needs
  them: **Copy command** / **Show in Skills** on advice cards, **Sync first** in the Apply
  sheet, and the expected-vs-observed delta and "deviates" flags in Changes (they wait for
  step 9).
- Loading the screen measures every anchor and saves the k when it changed, as
  `akit stats changes` does; so opening the screen can move the ≈ numbers `akit recommend`
  and `akit stats` print next. A project's Changes show its applies and every mark (marks
  are Mac-wide).
- Steps 8–13 are not built, with two exceptions inside step 11: the hook records `HEAD`
  (2026-10-01), and the index has a `signals` table, filled by
  `AKitErrorAnalysis.SignalScanner` instead of a shared `FailureSignals`.
- The opt-in store for eval examples (`manual_call_examples`) is in the index; the export
  to skill-creator (step 12) is not built.

## Goal

Find what the harness config costs in every request and is not used, and turn it
into ordinary layer edits (`plan` → `apply`). First target: auto skills the model
never calls. Every skill description sits in the context of every request.

One session at a time (built 2026-10-07, Sessions → Overview, Claude Code and Pi 1.0+): the
first call split into every part the harness loaded (system prompt sections, tools, MCP
servers, skills, subagents, rules files, hooks; `ContextFootprint`), each marked used,
unused or always sent, as a treemap, with its share of the first call and of all context
sent, the setup's share of every call, and how the tool calls ended (`ToolOutcomes`). Part
sizes are character estimates fitted to the first call's recorded context. Over the whole
session a part counts its size once per call. Money only where the harness recorded it per
call and kind (Pi `usage.cost`): the setup is each call's prefix, priced as cache reads, then
cache writes, then fresh input of that call; the parts add up to the recorded cost. Pi records its
prompt as a `system` message with named sections (AGENTS.md and SKILL.md with their paths),
but not its tool schemas. Each part links to the file that defines it. Lab reviews get
it as `context.json`. Across many sessions, Insights stays the place that recommends.

Measured on one Claude Code session in this repo: the skill listing alone was
≈ 7.5k tokens (121 skills). ≈ 3.2k of it came from plugins, including `marketing`
and `customer-support` in a Swift project. (These figures used the default 4 characters
per token. `claude plugin details` puts those two plugins at 874 + 448 = 1,322 tokens
always-on for 4,343 listing characters, about 3.3 characters per token, so the real
figures are higher.) In another session (2026-09-27, Claude Code
2.1.283) the listing was over its budget and Claude Code had dropped the descriptions of
39 of 118 skills.

Not the goal of v1: lessons about agent behavior (re-reads, large tool outputs).
The index keeps the raw facts for it, so it can come later without a re-import.

## What already exists

- `AKitSessions` (`ClaudeSessions`, `PiSessions`): sessions → `SessionSummary`,
  `SessionTranscript`, `SessionUsage` (tokens per model, cache, peak context,
  subagents, tool counts, errors, compactions).
- Usage screen: daily usage for Claude, Pi, Codex, OpenCode; cost only when recorded.
- `PromptSnapshot`: system prompt, tools and loaded context, incl. Claude's `skill_listing`.
- `ProjectRecords.projectID`: `origin` remote normalized to `github.com/owner/repo`,
  else `local/…`.
- Lab's `SessionAnalyzer` (`lab.md`): per-session friction counts (interrupts, rejected
  tool calls, tool errors, re-reads, compactions) from one transcript.

New in this design: a durable index, project binding that survives deleted worktrees,
cross-session and cross-machine aggregation, recommendations.

## Relation to Claude Code's own tools

Since 2.1.252 Claude Code measures part of this itself (checked against the docs and
Claude Code 2.1.287 on 2026-10-01):

- `/skill-doctor` reports "what each of your skills costs and how often it gets used" and
  flags listed skills that were never invoked, plugin skills included.
- `claude plugin details <name>` prints a plugin's always-on token cost per component
  (`marketing`: ≈ 874 tokens always-on, 8 skills). MCP tool schemas are not counted
  ("resolved at runtime").
- `/plugin` files a plugin under "Not used recently" after at least 14 days and 10
  sessions without use. AKit's defaults (N = 20 sessions, D = 14 days) are stricter.
- `skillOverrides` in settings sets a skill to `on`, `name-only` (name listed, no
  description), `user-invocable-only` (hidden from Claude, still in the `/` menu) or `off`.
  It "doesn't apply to plugin skills"; those are managed per plugin.
- `~/.claude.json` keeps `skillUsage` (`usageCount`, `lastUsedAt` per skill) and
  `pluginUsage`. The format is internal and undocumented.

So for Claude Code alone AKit is not another counter. What only AKit does:

- windows per project, starting at the `apply` that added a layer;
- sums over several Macs through the brain, with work machines kept apart;
- Pi now, OpenCode and Codex later;
- the owner's edit (`layer.yaml` patch through `plan` / `apply`), not a local toggle;
- a link to Lab and Error analysis (fingerprints, failure signals, examples for evals).

Claude Code's numbers serve as inputs and as a cross-check (step 9, step 13), never as
the source of a recommendation.

## Decisions

### Storage

- Local SQLite index in `~/.akit/index/` (system `SQLite3`, no new dependency). Not in git.
- Stores facts, never message text (Tier 0 in [`definitions.md`](definitions.md#data-tiers);
  one opt-in exception, see Evals): sessions, requests with recorded tokens, every tool
  call with its output size, skill exposure and skill calls, machine label.
- Import is incremental: remembers each file and the offset it read up to.
- Every record keeps the parser version. Raw logs expire, so later parser fixes
  migrate the index itself; store facts generously from the start.
- Hooks never open SQLite: they append one line to the spool (see Capturing) and the
  import moves the lines into the database. Parallel session starts and a running import
  can't block or slow each other.
- Why a durable index: Claude Code deletes logs after `cleanupPeriodDays` (default 30).
  Before/after comparisons and observation windows need longer history.
- The SQLite index is never synced or copied between Macs, through the brain or
  otherwise; each Mac imports its own session files. Only summaries travel:
  the brain gets small per-project summaries with a machine label,
  `projects/<id>/usage/<machine>.json`: calls per skill (model / user), sessions
  with the skill listed, average first-request context. Recommendations sum them
  over all machines, so a skill used only on the work Mac is not demoted by the home Mac.

### Token accounting

- A request is one model response, keyed globally by (harness, `message.id`), so a
  response copied into several session files (resume, forks) counts once.
- The lines of one response repeat its id with growing `output_tokens`; within a file the
  last line wins, and it carries the final count (all 12,170 multi-line responses in
  recent logs, checked 2026-10-01).
- Across files the first imported copy wins today (at equal parser version; a newer
  parser's copy replaces it). Rare here (2 of 17,407 ids in the last
  364 files), but ccusage reported double counts from it. Step 9 changes the tie rule:
  keep the non-subagent copy, then the larger total.
- First-request context = input + cache read + cache write
  (`first_request_context` in [`definitions.md`](definitions.md#session-and-request), the
  same meaning as OpenTelemetry's `gen_ai.usage.input_tokens`).

### Work machines: only counts of brain skills go to the brain

The index and the session files never leave the Mac; Lab reviews send a digest to a
model only as Tier 2 in [`definitions.md`](definitions.md#data-tiers). On a machine marked **work**
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
| Claude Code | `attachment.type == "skill_listing"`, with the skill's description | `tool_use` `name: "Skill"`, `input.skill` | `<command-name>/x` |
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

Only **described exposures** count (step 8), defined in
[`definitions.md`](definitions.md#skill-exposure). Claude Code keeps the listing within a budget
(1% of the context window by default, `skillListingBudgetFraction` to change it; each
entry capped at 1,536 characters). When it is over, Claude Code "drops descriptions
starting with the skills you invoke least", and those skills appear as `- name` lines
only. A skill listed without its description can't be picked by its description, so its
"0 model calls" says nothing. The index already stores such an exposure with
`desc_hash = NULL`, but `InsightsStats.tallies` and the usage summaries still count it.
Step 8:

- a name-only exposure gets a reason at import: `override` when the session's start line
  lists the skill as `name-only` (the hook reads only the `skillOverrides` key of each
  Claude settings scope at session start, nothing else from `settings.local.json`),
  `empty` when the skill's description is empty, otherwise `budget`. Sessions recorded
  before the hook did this have no such line; for them an exposure is `budget` when the
  same skill was listed with its description in another session on this Mac the same
  day (an override would have hidden it there too), else `unknown`. A listing is **over budget** when it has at
  least one `budget` exposure, so a user's own `name-only` choice never looks like an
  overflow, and `unknown` never counts as one;
- the denominator (stats, recommend, summaries) counts only exposures with a description;
- `akit stats` gets a finding "descriptions dropped by the harness": the share of sessions
  whose listing was over budget, and the skills that lost their description most often.
  Moving unused skills to manual is then what gives the rarely used, needed skills their
  descriptions back; raising the budget costs context in every request instead;
- Claude Code drops the descriptions of the least-invoked skills first, which are the
  skills this rule looks for. So a skill whose described plus `budget` sessions on this
  Mac reach N over ≥ D days, with 0 model and 0 user calls anywhere, gets the same
  `manual` recommendation, marked "description dropped by the harness". Its name still
  costs a line and its place in the budget; a model call or a user call still protects
  it. Other Macs' summaries carry no name-only reason, so they add only their calls
  (protection) and their described sessions to this rule, never their name-only ones;
- the usage summaries in the brain keep version 1 and `skills` keeps its three numbers
  `[listed, model, user]`. Each day gets a separate field `described: {skill: n}` (the
  same day's sessions with the description listed). An older akit's decoder ignores the
  unknown key, so it keeps reading the new files; a newer akit uses `described` when
  present and treats a file without it like Pi data: its calls protect skills, its
  listings never demote one. A fourth number in `skills` would break older readers
  (they skip entries that don't have exactly three) and the work filter, which allows
  only three whole numbers; that filter and the work summary get `described` added to
  their allowed day fields. Raising the version would make each akit drop the other's
  files, and a Mac not yet updated would stop protecting the skills it uses.

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
- Recommend when the skill was listed with its description in ≥ N sessions over ≥ D days
  across all machines and the model called it 0 times. Proposed defaults: N = 20, D = 14.
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

### More outcomes than manual (step 12)

The rule above stays the only one that edits a layer. Two cases get their own outcome:

- **User calls, no model calls.** The skill meets the rule and the user called it with
  `/name` at least once. That may mean the model should have picked it and the description
  is weak. The recommendation stays `manual` (the user's calls keep working) and offers a
  second path: keep it auto (`dismiss`) and improve the description, with the user's
  requests behind those calls exported as should-trigger examples (see Evals). Claude
  Code's plugin docs give the same advice: after trimming descriptions, check triggering
  with a `tool_used: Skill` grader.
- **Rare model calls, large description.** A skill the model does call, but in only a
  small share of described sessions (proposed: under 5%), whose description is in the top
  quarter of the listing by characters. `name-only` keeps its name listed, so the model can still pick it by name, and
  drops the description. Advice only until layers can write harness settings: it is
  Claude Code's `skillOverrides` (not a skill frontmatter field), it doesn't apply to
  plugin skills, and Pi has no counterpart. Before AKit recommends it, check on the
  installed Claude Code that `name-only` set in `~/.claude/settings.json` shows in
  `/context` (GitHub issue #50631 reported `skillOverrides` in user and project settings
  being ignored, status not checked; the docs show it written to `settings.local.json`).

A skill with 0 model calls and 0 user calls gets only `manual`; `name-only` would keep
paying for a name nobody uses.

### Scope: every listed skill, action by owner

- Summary on top: ≈ context per request by owner (layers, plugins, hand-installed,
  built-in).
- Layer skill → patch to `layer.yaml` (mode `manual`), applied through `plan`/`apply`.
- Plugin → advice only, one per plugin: disable it in this project if other projects
  use it, otherwise globally; only when the model calls none of its skills (see Interface).
  Writing `enabledPlugins` waits for harness settings in layers. `skillOverrides` can't
  narrow a plugin to some of its skills, so the plugin stays the unit.
- Hand-installed skill → advice: import into the brain in manual mode.
- A layer lists it (e.g. as manual), but the installed copy is not one AKit wrote
  (`akit apply` skips such files) → advice: `akit apply --home --include-unmanaged`
  (or `--include PATH`) so the layer's mode takes effect. `akit stats` counts these as
  owner `unknown`.
- Built-in → cost only, collapsed.

### Cost metric

- Named "≈ context space", never money.
- The characters are measured, not estimated: each skill's description as it appears in
  the actual `skill_listing` attachment (`desc_chars` in the index; the `- name: ` prefix
  is not counted), i.e. what the model received. Only the step from characters to tokens
  is an estimate.
- Tokens ≈ characters / k, marked ≈. k differs for Latin and Cyrillic (defaults 4.0 and 2.5).
  Sources of k, best first:
  1. before/after pairs (below), recorded token deltas;
  2. step 9: `claude plugin details` for installed plugins: a plugin's total always-on
     tokens against the summed characters of its listing lines (name and description;
     the per-skill numbers are rounded to about 10 tokens, too coarse alone). Local, no
     network, and available on day one: about 3.3 characters per token for `marketing`
     and `customer-support` (2026-10-01), against the Latin default of 4.0. Run at import
     only for a plugin whose `name@version` is new, and cached in the index's `meta`.
     Claude Code calls these numbers estimates, so pairs win once there are two;
  3. the defaults.
- Plugin advice shows the plugin's always-on tokens from `claude plugin details` next to
  AKit's own ≈ figure (step 9). Its MCP tool schemas are not in that number.
- Savings are nonlinear when the listing is over budget: removing a description frees
  room that dropped descriptions take back. A recommendation in such a scope says
  "listing over budget: this returns descriptions to other skills" instead of a saving.
- The Messages API `count_tokens` endpoint is not used: it needs an API key, which AKit
  doesn't read, and it sends the skill text to the provider (Tier 2).

### Before/after: proof that an apply worked

- Proof uses recorded data: the first request's context (`first_request_context`) of
  sessions in the project before and after `apply`. Compare only sessions with the same
  harness version and model, close in time; otherwise "not enough data".
- `akit stats changes`: anchors are applies and marks (`akit stats mark "<note>"
  [--at DATE]` for changes made by hand). Sessions within 14 days on each side, at
  least 5 per side in one (harness, version, model) group; a home apply or a mark
  counts every session on the Mac, a project apply that project's sessions. The
  listing's character delta comes from skills listed in most sessions on one side
  and none on the other; k = characters / recorded token delta. A pair calibrates
  when ≥ 400 characters changed and 1 ≤ k ≤ 10; each script's k is the median of
  its pairs once it has two (else the default), saved in the index's `meta` by
  `akit stats changes`.
- Expected delta = character delta / k, with a k that the change itself did not feed:
  the median of the other pairs, or the `claude plugin details` k. A change whose
  observed delta is more than 20% away from it is flagged (step 9); without such a k
  there is no flag, since a pair can't check itself. A pair where either side's listings were over budget
  never calibrates: the listing there is not the sum of its descriptions.
- Rates of failure signals before and after a change follow the statistics rules in
  [`definitions.md`](definitions.md#statistics) (intervals, tens of sessions), not the
  "≥ 5 per side" rule, which fits only the nearly deterministic context size.

### Binding a session to a project

~70% of Claude session folders no longer exist (mostly short-lived worktrees), so
`git remote` at analysis time fails. The folder names in `~/.claude/projects` encode the
path with losses (`/` becomes `-`) and every worktree gets its own folder, so they can't
name the repository either. Signals, most reliable first; each binding keeps its method
and confidence:

1. SessionStart hook (while the folder exists): `cwd`, the worktree's `gitdir` and the
   common dir of the main repository (what `git rev-parse --git-common-dir` prints, read
   from the `.git` file and `commondir` without running git), `origin` remote, branch,
   session id.
2. The worktree lists of known repos, read from `<common>/worktrees/*/gitdir` as
   `git worktree list` does (deleted worktrees stay listed until pruned).
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
  reads `session_id`, `cwd`, `transcript_path`, `source`, `model` from stdin, only appends to the
  spool file, and always exits 0. It runs on every `source` (`startup`, `resume`,
  `clear`, `compact`, and `fork` since Claude Code 2.1.214), so one session can have
  several lines. From `.git` files, read as text, the line also gets the repository
  (`gitdir`, `common_dir`, `remote_id`), `branch` and `head`: the commit HEAD points to
  (loose ref, then `packed-refs`), the base of control tasks made from the session (see
  error-analysis.md; built 2026-10-01, index schema v5).
- Pi: an extension file in `~/.pi/agent/extensions/`, owned by AKit, same facts.
- Safety net: launchd runs `akit sessions import` hourly (also parses the sessions).
- The spool is one file per UTC day in `~/.akit/index/spool/`. Each line is appended with
  one `write(2)` on an `O_APPEND` descriptor and no lock; the writer checks the written
  length, lines usually stay under 4 KiB (long fields are dropped first; a longer line is
  still written in one piece), and the importer keeps
  an unfinished last line for its next pass. That keeps parallel sessions' lines whole on
  a local APFS home; homes on NFS or SMB are not supported. `akit apply` appends an
  `apply` line too.
- Installed by `akit setup` (built 2026-10-06), not only by `akit insights install`: while
  none of it is on the Mac, setup asks once (default yes, also without a terminal). A no is
  kept in `~/.akit/insights.json` (`"capture": false`) and setup asks nothing after it;
  `akit insights install --yes` clears it. Once a part is there, setup refreshes only the
  parts there, without asking, so running `install.sh` again is an upgrade; a part that
  could join (Claude Code or Pi found since) is asked for once, and a no to it is kept too
  (`"captureSkipped"`). `--skip-home` skips capture. Pi counts as found with `~/.pi/agent`
  or `pi` on the PATH. A Pi extension AKit didn't write is left alone. On a work Mac the
  plugin commit carries the brain's own git identity, unsigned (`BrainGit`), and nothing is
  written into the brain without one. A newer plugin version already in the brain is never
  overwritten. The Insights screen shows a line when capture is off or out of date
  (`CaptureNotice`), and none for what the person said no to.

### Fingerprint, repo snapshot and failure signals (step 11)

Lab and Error analysis compare sessions "under the same setup" and sample them by what
went wrong. The index is where those facts can outlive the logs. Definitions are in
[`definitions.md`](definitions.md); here is only who records what.

- **Hook (cheap facts only).** Adds `model` (from stdin; the docs say it can be missing),
  the `HEAD` commit (read from files, like the branch), and hashes of the context files:
  the chain from `cwd` to the repository root and the user's global one, and the names of
  skills set to `name-only` by `skillOverrides` (added in step 8). Nothing that runs git or reads
  large files.
- **Repo snapshot.** Only `origin` and `HEAD` (HEAD is recorded since 2026-10-01, see
  above). `dirty` and `diff_hash` need `git status` / `git diff`, which a hook can't wait
  for. Error analysis decided against a detached helper (HEAD only; sessions that started
  with uncommitted changes don't become control tasks), so they wait for another user.
- **Hook, settings components.** Also hashes, at start, the `hooks` and `enabledPlugins`
  keys of `~/.claude/settings.json` and the project's `.claude/settings.json`, and the
  project's `.mcp.json` without `env` and `headers`. These are small files; their hashes
  are taken while they still hold that session's settings. `~/.claude.json` (rewritten
  by Claude Code all the time, and holding user-scope MCP servers with secrets) and
  `settings.local.json` are not read, except the `skillOverrides` key (see Reading skill
  use).
- **Importer.** Computes the listing hash from the initial `skill_listing` after each
  start event, reads harness version and model from the lines, and stores per start
  event each component hash and `harness_fingerprint`, built from the components that
  are always there (listing, context files, harness version, model). The settings
  components are extra filters: two sessions must match on one only when both have it.
  A session imported without a hook line simply lacks them.
- **Failure signals.** Error analysis (2026-10-01) already keeps cheap per-session signals
  (interrupts, pushbacks, tool errors, repeated calls, "done" with no check, length) in the
  index's `signals` table (schema v6), computed by `AKitErrorAnalysis.SignalScanner` from
  whole transcripts and refreshed after every import; this step should replace that with
  the incremental reducer below and keep the table's columns. One parser in `AKitSessions`,
  which both Insights and Lab already import: a `FailureSignals` reducer with its own version that takes transcript lines
  one at a time, so the importer feeds it incrementally. Lab's `SessionAnalyzer` moves
  its interrupt, rejection, error, compaction and re-read rules into it and calls it;
  the importer stores its counts per session. New in this step: `repeated_calls` (needs
  a hash of each tool input) and the version. Rewinds stay out until a marker is
  verified on real logs. Claude Code's `tool_result_meta.non_execution_kind` (refusal
  kinds) is used when present; it was in none of 364 recent files (2.1.283–2.1.287), so
  refusals are still read from the result text.

### Evals (later, but examples are kept from v1)

- Not in v1: the auto → manual rule needs none (a manual skill is never model-called),
  and the before/after measurement is its proof. Evals come when `recommend` shows
  enough "improve the description" cases (step 12).
- Two kinds, two owners. Whole sessions and setups are measured by Lab (`lab.md`: replay
  tasks, its own runner). Skill-trigger evals and description tuning belong to
  skill-creator; AKit's part there is real examples in its eval format.
- skill-creator's trigger eval set: about 20 queries, 8–10 should-trigger and 8–10
  should-not-trigger, where near-misses (shared keywords, different need) are the valuable
  negatives; its `run_loop` splits 60% train / 40% test and runs each query 3 times.
- Positive example: a manual `/name` call means the model should have picked the
  skill itself. Raw logs expire, so from v1 on an opt-in setting keeps, per manual
  call, only the user's request that led to it (the `/name` arguments and the user
  message right before). Masked with `SecretFilter`, local index only, never the brain.
  This is the one exception to "no message text".
- Negative examples can't come from passive data (no judge knows whether the skill
  was needed), so the export takes a few hand-written near-misses.

### Interface

- CLI first: `akit stats` (text, `--json`) and `akit recommend`
  (`apply <id>`, `dismiss <id>`). The JSON is the contract for `/akit` and the Insights
  screen.
- Every JSON output carries `version` (the schema version). New fields keep it; a renamed
  or removed field, or a changed meaning (step 8's denominator), raises it.
- A recommendation has a stable id, evidence (sessions, period, machines,
  binding method, confidence, ≈ context) and an edit as a layer patch that goes
  through the usual `plan`.
- Compact by default (summary + top N); details on request, since the agent pays
  tokens for what it reads.
- Advice outside layers is in the same list, typed "advice", without `apply`.
- A plugin is enabled or disabled as a whole, so its skills are judged together:
  one advice per plugin and scope, with `"skill": "*"` and the skills it is about
  in `evidence.skills` (only plugin advice has that field; it was added without raising
  the version).
  `disablePluginInProject` / `disablePluginGlobally` when the model called none
  of its listed skills in scope and the plugin as a whole meets N sessions / D days
  (evidence summed over its skills; another Mac's day counts the most sessions any
  one skill was listed in); otherwise at most one `unusedPluginSkills` note with
  the never-called skills that meet the rule on their own. Ids hash
  `rule|plugin|<name>|*|scope` (disable) and `rule|plugin|<name>|*unused|scope` (note).
- Step 13, a parser check in the debug stats output (not a command of its own): this
  Mac's model + user calls per skill against `skillUsage.usageCount` in `~/.claude.json`,
  listing skills that differ by more than 10%. The file's format is internal and it counts
  since install, so only skills first seen after the index started compare; golden-file
  parser tests stay the real guard.

### Insights screen (step 10)

A sidebar section **Insights** next to Usage and Lab. It shows the same reports as the
CLI, from the same core calls, so the screen and `--json` never disagree.

- **Header.** Scope picker: this Mac (all sessions) or one project (from the project
  list; bindings as in `akit stats`). Window picker: 7 / 30 / 90 days, for stats only;
  recommendations always use the rule's own window (N sessions, D days). Last import time
  and an **Import now** button (`QuickImport.run`). Capture status from
  `CaptureInstaller.status`; **Install capture…** shows `CaptureInstaller.installPlan`
  (the files and commands) and runs `execute` only after the user confirms. Built as one plan
  per part with a checkbox each; a part said no to in `akit setup` starts unchecked.
- **Context by owner.** One bar per owner (layers, plugins, hand-installed, built-in,
  unknown) with ≈ tokens per request, and the over-budget finding when the listing
  dropped descriptions (step 8). From `InsightsStats.report`.
- **Skills.** A table: skill, owner, sessions listed with description, model calls, user
  calls, call rate, ≈ context space, window start. Sorted by ≈ context space; Pi-only
  skills in a collapsed "no data" group.
- **Recommendations.** From `Recommender.recommend`, one row each: what, why (evidence),
  ≈ saving. A layer recommendation has **Apply…**: a sheet with the `layer.yaml` diff
  (`LayerPatch.edit`, shown with the app's existing diff view) and the projects that use
  the layer; confirming commits the patch in the brain (`LayerPatch.commit`), then offers
  **Plan** for those projects and for the home folder through the usual plan/apply sheet.
  Nothing is applied without that second step, as in the CLI. **Dismiss** asks once and
  calls `Dismissals.dismiss` (for a layer skill: the `keep_auto` patch, same sheet).
  Advice (plugins, hand-installed, unmanaged) has **Dismiss** and a **Copy command** /
  **Show in Skills** link instead of Apply. Stale evidence (another Mac's summary older
  than D days) is marked with the same warning the CLI prints, and the Apply sheet offers
  **Sync first**; Apply stays possible, as in the CLI.
- **Changes.** The before/after list from `BeforeAfter.changes`: each apply or mark with
  expected and observed delta, the group, and "not enough data" or "deviates" flags.
  **Add mark…** writes a mark (`akit stats mark`). The calibration line (k per script and
  its source) sits below.
- **Sync publishes summaries.** The app's brain Sync does what `akit sync` does: quick
  import, `SummaryPublisher.publish`, then `BrainSync.sync` (`InsightsSync`, built 2026-10-06). A failed or refused publish (work machine) is a warning in
  the sync result; pull and push still run. The hourly job still never publishes.
- **Work machine.** The screen works the same on this Mac's data; the Sync result says
  that only the pseudonymous brain-skill counts were published.
- **Empty states.** No index yet → "Import sessions" button. Capture missing → install
  hint. No recommendation → the rule and its thresholds, and how many skills are still
  inside their window.

Every operation on the screen exists in the CLI already, but three pieces live in
`AKitCommandLine`, which the app doesn't link. Step 10 starts by moving them into
`AKitInsights` so the CLI and the app share them: the sync sequence (import, publish,
warn, then `BrainSync.sync`) as `InsightsSync`, the "projects using this layer" query
behind `recommend apply`, and writing a mark line as `Spool.mark`. The screen adds no
other logic.

## Not doing

Too much for one user on a few Macs, or against a decision above:

- OpenTelemetry export, a collector, Prometheus / Loki / Grafana, Langfuse, Phoenix.
  Only the OTel field names are borrowed.
- A DuckDB / parquet mirror, or full-text search (FTS5) over message text. The index
  holds no text.
- A model pass over every session like Claude Code's `/insights`. Error analysis samples.
- Semver for skills, an own tokenizer, an own trigger-eval runner, tool search for skills.
  121 descriptions are a manual / name-only problem, not a retrieval one.
- `count_tokens` (see Cost metric).
- Statistical tests for the context size: it is measured.
- OpenCode and Codex before they are really used.

## Order

Status: 1–7 and 10 built, 8, 9 and 11–13 not built (see the status
note at the top).

0. By hand, today: `"cleanupPeriodDays": 365` in `~/.claude/settings.json`.
   Optionally disable the `marketing` and `customer-support` plugins where they
   aren't needed (≈ 1.1k tokens per request by the default k; 1,322 by
   `claude plugin details`); note the date, it is the first
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
8. The hook records the `name-only` skills from `skillOverrides`; described exposures
   only in stats, recommend and summaries (`described` day field); name-only reasons
   (same-day rule for older sessions) and the over-budget rule; the "descriptions dropped by the harness"
   finding and its `manual` recommendation; stats and recommend JSON versions raised.
9. `claude plugin details` as the plugin token source and the offline k; over-budget
   pairs don't calibrate; the deviation flag; the cross-file tie rule for requests.
10. Move the sync sequence, the layer-users query and mark writing into `AKitInsights`;
    Insights screen; the app's Sync publishes summaries.
11. `FailureSignals` in `AKitSessions` (Lab switches to it); the hook's settings hashes,
    `origin` and `HEAD`; fingerprint and signal counts in the index.
12. The "user calls, no model calls" path with the skill-creator export; `name-only`
    advice after checking `skillOverrides` on the installed Claude Code.
13. The `skillUsage` parser check in the debug stats.
14. Later: OpenCode, Codex, AGENTS.md size findings, behavior lessons.

## Caveats

- Claude Code's transcript format is not documented and changes between versions.
  Parsers tolerate missing fields and record their version.
- How Claude Code ranks "the skills you invoke least" is not documented. A formula seen in
  a third-party write-up (usage count with a weekly half-life) is not relied on.
- Claims about Pi (no listing in its logs, no `name-only` counterpart) come from the Pi
  0.84.2 checks above, not from its docs.
- Two review points were taken from other projects' issues, not from their code: the
  ccusage tie rule for duplicate requests and the double-count report.
