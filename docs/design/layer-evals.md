# Layer evals: does a layer help?

Status: design 2026-10-03, decided in a grilling session and revised after a fact-check
against the code. Not implemented.

## Goal

Answer one question with numbers: **does layer X make the agent's work better on tasks of
its kind?** The run is the same task twice, without the layer and with it, in Lab's
isolated clone. The task's oracle decides success; the layer's own checks measure the
quality it promises. AKit shows the verdict on the layer in Brain.

v1 answers only this question (an ablation). Two later questions use the same mechanics
with other setups: "is version N of the layer worse than N−1?" (regression) and "which of
two layers is better?".

## Where the idea comes from

The `ninja-testing` plugin (JavaScript Ninja testing course, local copy in
`~/Projects/javascript-ninja-testing-skills`) is a harness generator plus an eval suite
that proves it works. Its `evals/` has four levels:

| Level | What it checks | Cost |
|---|---|---|
| 1. Mechanics | hook linters on a corpus of good and bad files: precision/recall | seconds |
| 2. Generator | `init --dry-run` with fixed answers: the chosen rule ids against the expected set | minutes |
| 3. Main (`evals/run.mjs`) | does the harness make the agent's tests better: variants × models × repeats | $0.2–4 per run |
| 4. Reviewer | the `test-reviewer` subagent on a file with 9 seeded violations (`truth.json`) | ~$0.3 |

Level 3 runs each task in a clean copy with spoilers hidden, applies a **variant**
(`bare` nothing, `agents` only AGENTS.md, `full` everything the generator wrote), starts
`claude -p` with its own session id, and scores mechanically: the agent's tests green on
the correct code, red on a toggled bug (`caught_bug`), Stryker mutation score, hook-lint
findings, whether the agent touched the code under test, turns and cost.

What its results taught:

- The effect depends on the model: on the concurrency task Haiku 0/3 → 3/3, Sonnet
  0/3 → 3/3, Opus 2/2 → 2/2.
- Most of the effect comes from AGENTS.md, path rules and hooks. Step-by-step skill
  prescriptions in CLAUDE.md only raised the cost (Sonnet $0.9 → $1.6) and distracted the
  weak model. The ablation found it: that is why variants matter.
- Sometimes tests can't see the gain: on TicketWidget every variant caught the bug 3/3,
  and the whole difference was quality (test-id locators per file 11 → 0). That is why
  this design keeps quality checks next to success.
- Weak points to avoid here: conclusions from 2–3 runs, isolation through `git worktree`,
  reviewer precision counted by regex.

## What AKit already has

| Piece | Where | Status |
|---|---|---|
| isolated clone of the base commit (`git init` + `fetch`), own session id | `IsolatedClone`, `ControlCell` | done |
| leak flags of a control cell (reading the exemplar session) | `ControlRuns.leaks` | done; fewer signs than a replay's `LeakCheck` |
| control task: a prompt at a base commit with an oracle `.tests(command:)` or `.assertion(modeID:)` | `ControlTask` | done; sources: session, reproduction |
| task from a commit with hidden tests (fail-to-pass, pass-to-pass), SwiftPM only | `ReplayTask`, `SwiftTests` | done; a replay can't take a control setup |
| setup with one difference: text appended to one file | `ControlSetup`, `ControlPatch` | done; one file, not a layer |
| read-only setup as a sanity check | `ControlSetup.readOnly` | done |
| guard: fewer test markers, test files changed (file snapshots before and after the agent, not git) | `ControlCell`, `ControlOutcome` | done |
| repeats, cell keys, paired bootstrap by task, Wilson intervals | `ControlRuns`, `ControlComparison` | done |
| cost estimate before queueing; monthly limit and sending policy per cell | `RunCellsSheet`, `akit analysis control`, `ControlRuns` | done |
| fix draft of a mode with "the layer to change" | `FixDraft.layer` | done; a kind of artifact, not a brain layer |
| layer render: skills, glued Markdown, CLAUDE.md shim, `.claude/skills` link | `Render.render` | done; pure, writes nothing |
| project plan: a template file (any non-skill path) the project edited is offered, not overwritten; one AKit wrote and nobody edited is updated; with a lock, the project's same-name skill wins | `ProjectSetup.plan` | done |
| first date a layer applied in each project | `LayerHistory.starts` | done; internal to `AKitInsights` |
| Lab's own sessions left out of production numbers | `IndexedSessions.labKeys` (by session id) | done |

Layer evals are control cells whose setup brings a whole layer instead of one patch.

## Decisions (2026-10-03)

| # | Question | Decision |
|---|---|---|
| 1 | What v1 answers | "Does the layer help?": without the layer against with it. Regression and layer-vs-layer later, on the same mechanics |
| 2 | The home folder in the baseline | As it is: the user's full setup, as control cells run today. AKit warns when a skill of the layer is already installed elsewhere, and pairs only cells with the same home fingerprint |
| 3 | The project's own harness files in the clone | They stay; the layer goes on top. "The project's layers without X" later |
| 4 | Variants | Two: baseline and the whole layer, plus read-only as a sanity check. The new setup format has room for a list of the layer's parts |
| 5 | Model | One per eval, by default the one you work with. Evals of other models line up into a matrix |
| 6 | Where tasks live | Locally, `~/.akit/lab/evals/`. Publishing tasks of public repositories into the layer later |
| 7 | How tasks enter a layer's set | By hand and from a failure mode's exemplar sessions. Suggestions by the layer's paths later. New task source: a commit |
| 8 | Success | The task's oracle decides success (tests, preferred for layer sets, or a mode's assertion). Quality checks from `layer.yaml` are separate columns |
| 9 | Check kinds in v1 | `diff` and `transcript`. `command` and `order` later |
| 10 | Link between a mode and a layer | Local, in the mode's fix draft |
| 11 | Production guard | Two levels: "helps (offline)" from the task set; "confirmed in work" once the layer is applied and enough sessions exist |
| 12 | Quality-only gain | Each check gets its own verdict, if success didn't get worse; 3–5 checks per layer |
| 13 | UI | A button and the last verdict on the layer in Brain; details in Error Analysis → Evals |

## Terms

- **Layer eval**: control cells of one layer's task set under two setups, baseline and
  layer, and their comparison.
- **Layer set**: the control tasks chosen for a layer, plus field answers for rendering it.
- **Layer setup**: a control setup that puts a rendered layer into the clone.
- **Overlay**: the files a setup writes into the clone before the agent starts: path →
  content or link. A `ControlPatch` is the one-file case.
- **Check**: a rule of the layer that turns a finished cell into a match count and a
  pass/fail (`diff`, `transcript`). Not the same as a mode's check in error analysis,
  which judges a recorded session.

## Flow

```
Brain → layer "swiftui" → Evaluate…
   │  pick the layer set (tasks), model, effort, repeats; AKit estimates the cost,
   │  shows the overlap warning, renders the layer once and stores the overlay
   ▼
for each task × {baseline, layer, read-only (sanity)} × repeat:   (control cells, Lab queue)
   1. isolated clone of the task's base commit
   2. overlay: baseline = the layer's required layers (or nothing); layer = the layer too
   3. tree T0 recorded; agent (Claude Code or Pi) with the task's prompt; tree T1 recorded
   4. guard + oracle → passed / failed
   5. saved for checks: added lines T0..T1, the agent's shell commands (subagents included)
   ▼
comparison (checks computed now, from the saved artifacts): paired by task, bootstrap
   ▼
verdict on the layer: "helps (offline)" / "didn't show it helped" / "no conclusion"
   ▼
later, from linked modes in projects that use the layer: "confirmed in work" / "worse in work"
```

## Setups

### Baseline: the home folder as it is

Control cells start Claude Code with only `--model` and `--effort` (`LabAgent.flags`), so
the agent reads the user's full setup: `~/.claude/CLAUDE.md`, user skills, plugins and
hooks. Even replays' `lean` (`--setting-sources project`) still loads `~/.claude/CLAUDE.md`
and `~/.claude/skills` (`lab.md`, "Setups to compare"); a clean home needs `--bare` and an
API key.

So the baseline is the real environment, and the question becomes "does the layer add
something to what I already have?". Two things keep that honest:

- **Overlap warning** before the run. For each task AKit lists the base commit's tracked
  files (`git ls-tree -r <base>`, no clone needed) and compares the layer's skill names
  with the agent's home skills (Claude Code: `~/.claude/skills`, `~/.agents/skills`, the
  skills of enabled plugins AKit already lists; Pi: `~/.pi/agent/skills`,
  `~/.agents/skills`) and the project's tracked `.agents/skills`, `.claude/skills` and
  `.pi/skills`: "`tdd` is already installed globally: the difference will look smaller
  than it is". It compares names only.
- **Home fingerprint.** No fingerprint is computed in code today, and the session
  fingerprint of `definitions.md` hashes the skill listing and the context files, which a
  layer setup changes on purpose. Layer evals therefore compute a **home fingerprint** when
  cells are queued: hashes of the home context file (`~/.claude/CLAUDE.md`, or Pi's
  `~/.pi/agent/AGENTS.md`), the names and `SKILL.md` hashes of home skills, and the
  harness settings that change behaviour (Claude Code: the `enabledPlugins` and `hooks`
  keys of the user `settings.json`; Pi: its `settings.json`). The fingerprint is part of
  the cell key (see [Format](#format)), so after a home change "Evaluate" queues new cells
  instead of reusing old ones, and cells are paired only within one fingerprint. The
  harness version is left out of it, since Claude Code updates often; each cell records
  its version, and the result lists the versions it mixes.

`lean` is not an option of control cells today (only replays have it, `LabSetup`); adding
it to control setups is listed under [Later](#later), as is a clean home.

### Layer setup: rendering

- **Where.** `AKitLab` doesn't depend on `AKitRender`, and `AKitRender` is the swappable
  seam (`architecture.md`). The render happens in `AKitErrorAnalysis` (new dependency on
  `AKitRender`; `architecture.md`'s map is updated in that slice). `ControlCell` gets a
  neutral **overlay** (path → data or link, plus "append" or "write") that generalizes
  `ControlPatch`.
- **When.** Once, when the cells are queued, not in each cell: `ProjectBundle.resolve`
  reads the brain's working tree, and cells run long after queueing. AKit refuses when the
  brain has uncommitted changes in the layer's folder, its required layers or their
  skills, records the brain commit, and stores the overlay in
  `~/.akit/lab/evals/overlays/<hash>/` (hash of the rendered content, answers included).
  Every cell of the setup applies that stored overlay.
- **Required layers.** `resolve` brings every `requires` layer. The layer setup is "the
  required layers + X", and the **baseline is the required layers alone** (nothing when X
  requires none), so the ablation removes only X.
- **Fields.** One precedence: the layer set's stored answers, then the project's answers
  in its project store (`projects/<id>/answers.json` in the brain, or
  `~/.akit/local/projects/<id>/` on a work Mac) when the task repository is a project set
  up through AKit, then the defaults of `layer.yaml` (as `ProjectBundle.resolve` already
  does). The built-in `project_name` is the task repository's folder name, not the clone's
  random folder. A required field without a value blocks queueing.
- **Target.** The render target is the cell agent's harness: `claude` or `pi`.

### Layer setup: on top of the project

A clone holds only what git tracks. In AKit's own repository that is `CLAUDE.md`;
`.agents/` and `.claude/skills` are in `.gitignore`, so the project's skills are not in the
clone.

**Difference from Apply.** Real Apply never appends to a project's own Markdown: an existing
`CLAUDE.md` or `AGENTS.md` belongs to the project, and a layer change is only offered
(`ProjectSetup.plan`). Decision 3 puts the layer on top instead, so an eval measures the
layer's text as the agent would read it if the user accepted it into the project. A task
whose project already has its own `CLAUDE.md` or `AGENTS.md` is marked in the results
("the project would get this only by accepting the suggestion").

The overlay is built from the render's outputs with one rule for Markdown: **append the
layer's text to the file the agent already reads; create a file only when it reads none.**
The render's `CLAUDE.md` shim is dropped; the overlay decides about `CLAUDE.md` itself.

| Output of the render | In the clone |
|---|---|
| `AGENTS.md` section, agent = Claude Code | Claude reads `CLAUDE.md` and `.claude/CLAUDE.md`. If either is a link to `AGENTS.md` or has an import line (`@AGENTS.md`, `@./AGENTS.md`): append to `AGENTS.md`. If one exists without that: append the section to it (root `CLAUDE.md` first); the project's `AGENTS.md`, unread before, stays unread. If neither exists: write a new `CLAUDE.md` holding only the section |
| `AGENTS.md` section, agent = Pi | Pi reads one of `AGENTS.md` and `CLAUDE.md` per folder. If the root has only one of them: append to it. If it has neither: write `AGENTS.md`. If it has both: the task is blocked for Pi until Pi's choice between them is verified |
| other Markdown file | append when it exists, else write |
| skill folder `.agents/skills/<name>` | written. A skill folder with the same name already in the clone wins and the layer's copy is skipped with a warning. (`ProjectSetup.plan` decides this only with a lock, which a clone doesn't have, and it lives in `AKitProjectSetup`; the overlay uses this simpler rule) |
| `.claude/skills` link (Claude only) | made when the clone has nothing there. A non-empty real folder blocks the task, as it blocks Apply |
| any other file | written when absent; present → the task is blocked before queueing |

Writes never follow a symlink out of the clone: a link to a file inside the clone is
resolved and that file is appended to; a link elsewhere blocks the task. Every written or
changed path, **resolved** (the link's target, not the link), is hidden from `git status`
and `git diff` the way `ControlPatch.apply` does it (assume-unchanged for tracked files,
`.git/info/exclude` for new ones), so the agent sees a clean checkout as in the baseline. The guard needs no such help: it compares file
snapshots taken after the overlay and after the agent.

### Format

`ControlSetup` gets one more optional difference next to `patch`:

```swift
public struct LayerVariant: Codable, Sendable, Hashable {
    public enum Role: String, Codable, Sendable { case requiredOnly, layer }
    public var layer: String           // brain layer name (X)
    public var role: Role              // requiredOnly = the baseline of X's eval
    public var parts: [String]?        // nil = the whole layer; later: skill names and file targets
    public var overlayHash: String     // the stored overlay, answers included
    public var brainCommit: String     // rendered from; metadata, not in the cell key
}
```

`ControlSetup` gets `layer: LayerVariant?` and `homeFingerprint: String?`. A setup has at
most one of `patch` and `layer`. When X requires no layers, its baseline is a plain setup
(no patch, no layer), the same as other evals' baselines, and is shared with them.

- **Cell key.** `ControlRuns.cellKey` today hashes only `patchFile`, `patchText` and
  `readOnly`, so a layer setup would get the baseline's key and be skipped as done. The key
  gains the overlay hash, the role, the parts and the home fingerprint. The brain commit is
  left out: a commit that doesn't change X's rendered output keeps the same overlay hash
  and reuses finished cells.
- **Pairing.** `ControlComparison.compare` treats a setup with `role: layer` as a variant.
  It is paired only with a baseline of the **same agent**, the same home fingerprint, and
  X's required-layers overlay (`role: requiredOnly` of the same X, or the plain setup when
  X requires nothing). The fallback to "the first baseline" stays for patch fixes only, and
  only among baselines with no overlay.

## Tasks and layer sets

**New task source: a commit.** `ControlTask.Source` gets `.commit(sha)` and
`ControlTask.Oracle` gets `.hiddenTests(commit:)`. The task points at the cached replay task
(`~/.akit/lab/tasks/<sha>.json`) instead of copying it: base = parent, prompt = the commit
message plus `ReplayTask.instruction`, hidden test files copied in after the agent, judged
by fail-to-pass and pass-to-pass with `SwiftTests` as in a replay (`lab.md`, "Replay
tasks"). Like replays, commit tasks are **SwiftPM only** in v1. For these tasks:

- the guard ignores test files the hidden tests will overwrite (the prompt asks for
  passing tests, so the agent may add tests to an existing test file);
- the leak check adds the replay's signs (`LeakCheck`): the target sha, the real repository
  path, `~/.akit/lab`, session search.

**Layer set** — `~/.akit/lab/evals/sets/<layer>.json`:

```json
{
  "layer": "swiftui",
  "tasks": ["report-layer-yaml-mistakes-instead-of-a1b2", "fix-the-login-bug-c3d4"],
  "answers": { "company": "" },
  "createdAt": "2026-10-03T12:00:00Z"
}
```

Tasks are the control task files in `~/.akit/lab/evals/tasks/` (ids as today:
`<slug>-<4 hex>`); one task may be in several sets. Nothing of a set goes into the brain
(task prompts, repository paths and work code stay on the machine, `layers.md`, "Work
machines").

How tasks get in (v1):

- **By hand**: "Add to layer set…" on a commit, on a session, or on an existing control
  task.
- **From a failure mode**: when a mode's fix draft names a brain layer (see
  [Link to error analysis](#link-to-error-analysis)), "Add exemplars to layer set" makes
  control tasks from the mode's exemplar sessions (as today) and adds them to that set.
  Such tasks may carry the mode's assertion as their oracle.

A set grows to 20–30 tasks before the number of repeats grows (`error-analysis.md`,
"Controlled evals"). Read-only sanity cells: one repeat on 3 tasks of the set, without
the layer; all must fail.

## Oracle and checks

**Success** is the task's oracle: hidden tests (commit tasks), a test command, or a mode's
assertion. The existing guard applies: a cell with dropped tests, changed test files (except
those the hidden tests overwrite) or leaks counts as failed.

**Checks** measure what the layer promises to improve. They belong to the layer, in
`layer.yaml`, because they describe the layer's purpose. A pattern that names one project's
command goes through a field, so the brain holds no project details; on a work Mac checks
are layer text like any other and follow the same rules.

```yaml
fields:
  - id: ui_check
    prompt: Command that checks the screen after a UI change
    type: text
    default: make snapshot

checks:
  - id: deprecated-api
    what: Old SwiftUI API added
    diff: '\bNavigationView\b|\.foregroundColor\('
    files: '**/*.swift'
    want: none

  - id: ui-checked
    what: Screen checked after a view change
    transcript: '{{ui_check}}'
    want: some
```

| Field | Meaning |
|---|---|
| `id` | letters, digits, `-`; unique in the layer |
| `what` | one line shown in the results |
| `diff` | regex over the lines the agent **added** between T0 and T1 |
| `files` | glob that limits `diff` to some files; default all |
| `transcript` | regex over the `command` field of the agent's shell tool calls (Bash for Claude Code, bash for Pi), subagents included |
| `want` | `none`: the cell passes with 0 matches; `some`: with at least 1 |

`{{fields}}` in a pattern are filled with the same precedence as the render (the set's
answers, then the project's, then the defaults) and the value is escaped
(`NSRegularExpression.escapedPattern`), so `make snapshot OUT=…` matches literally. A check
has exactly one of `diff` and `transcript`.

**The agent's diff.** After the overlay, AKit writes the clone's whole tree as T0 through a
temporary `GIT_INDEX_FILE` (`git add -A`, then `git add -f -- <overlay paths, resolved>`,
then `git write-tree`; no ref, no commit), and the same as T1 after the agent. The forced
add is needed because the overlay's new files sit in `.git/info/exclude` (and may match
the project's `.gitignore`), which `git add -A` respects. Added lines = `git diff T0 T1`:
new untracked files count, the layer's own text doesn't (it is in T0), and the agent's own
edits to the overlay's files count. Files the agent writes in other ignored paths (build
output, for example) are left out on purpose. At the end of the cell, before the clone goes to the Trash, the run folder keeps
`added-lines.diff` and `commands.jsonl` (each shell command, with the subagent it came
from). Subagent tool calls are read from `<session>/subagents/*.jsonl`; today
`SessionTranscript` reads only their usage, so this reader is new.

**When checks run.** At comparison time, from those saved files, not when the cell runs. A
baseline cell may be shared by several layers and brain commits, and checks belong to one
layer at one commit; computing late lets a new or edited check apply to old cells. A cell
whose saved files are missing (older runs) has no check values.

**Scoring rules.**

- A `none` check is scored only on cells with a non-empty T0..T1 diff, so a cell that gave
  up early doesn't pass it by doing nothing.
- A flagged or errored cell counts as failing every check, as it counts as failed for
  success.
- An invalid regex is a layer mistake shown in Brain, like other `layer.yaml` mistakes.
  Older AKit builds report `checks:` as an unknown key: install the app and `akit`
  together, as with other format changes.

Later kinds (not v1): `command` (run a command in the clone under the watchdog: linters,
`tsc --noEmit`), `order` (one transcript event before another: a failing test before the
first code edit).

## Verdict

The unit stays the task's pass rate over its repeats; comparisons are paired by task with
the bootstrap over tasks (`ControlComparison`). The same rules apply to success and to each
check's pass/fail.

| Level | Rule |
|---|---|
| **no conclusion** | fewer than 3 repeats per task, or fewer than 15 cells on either side over the tasks both sides share (as today) |
| **helps (offline)** | at least 95% of the bootstrap mass on improvement; the production guard is not required |
| **didn't show it helped** | enough cells, the rule above not met |
| **confirmed in work** / **worse in work** | see below |

Today a control comparison says "no conclusion" without the production signal. The offline
level drops that requirement **for layer setups only**, because a layer must be judged
before anyone uses it; a mode's fix status keeps the existing rule (see
[Link to error analysis](#link-to-error-analysis)).

**Per check.** Each check gets the same verdict on its own pass/fail ("deprecated-api:
helps (offline)"), only when success didn't get worse: at most 50% of the success bootstrap
mass strictly below zero. `Paired` stores that share ("worse share") next to the share above
zero; ties at zero count for neither. The result names the number of checks compared, since
more checks mean more chances of a lucky "helps"; a layer should keep 3–5. Mean match counts
with their spread are shown next to each check.

Example of the result:

```
swiftui · opus · 24 tasks × 3
success: 71% → 75%, didn't show it helped
deprecated-api: 38% → 96% clean, helps (offline)
ui-checked: 12% → 58%, helps (offline)
3 checks compared · home overlap: none · 6 tasks with the project's own CLAUDE.md · $142
```

**Production level.** Only for a layer that modes are linked to:

- T is per project: the date the layer first applied there (`LayerHistory.starts`, made
  public for this).
- Sessions: only those of projects that have the layer, Lab's own left out
  (`IndexedSessions.labKeys`). Each project contributes its sessions in a window around its
  own T: "after" from T to now, "before" just as long before T, as `Fixes.evaluate` does
  with one T. The sides are pooled over projects.
- Each linked mode is judged by the rules of `error-analysis.md`, "Fixes" (its check before
  and after, at least 15 sessions per side).
- **Worse in work**: a linked mode with P(failure rate rose) ≥ 0.95, the bar
  `Fixes.regressions` uses. **Confirmed in work**: no linked mode has P(rose) above 0.5,
  and at least one helped. Otherwise the offline level stands, marked "no production
  signal yet".

## Link to error analysis

The link lives on the mode's side, locally:

- `FixDraft` gets `brainLayer: String?` and `layerPart: String?` (a skill name, a file
  target, or nil for the whole layer). The existing `layer` kind (CLAUDE.md rule, skill,
  hook…) stays and says what kind of change it is. With `brainLayer` set, `text` is
  optional and the fix's variant is the `LayerVariant`, not a `ControlPatch` of the text.
- A fix draft with `brainLayer` offers "Add exemplars to layer set" and "Evaluate layer".
- The layer screen lists the modes whose fix drafts name it, read from
  `~/.akit/lab/analysis/fixes/`.
- **Two statuses, shown separately.** The mode's fix status keeps the rule of
  `error-analysis.md` ("helped" needs the production guard). The layer's verdict is the
  layer eval's own, with its offline level. The same cells can feed both.

Nothing about modes goes into the brain; on another Mac the link isn't visible.

## UI

- **Brain → layer**: "Evaluate…" (sheet: layer set, model, effort, repeats, environment,
  cost estimate, overlap warning, blocked tasks) and the last verdict as a badge with its
  date, model and brain commit. A layer without a set offers "Create layer set". The badge
  is read from local storage, never from the brain.
- **Error Analysis → Evals**: layer sets next to control tasks; a set's page shows its
  tasks, cells, the comparison table (setups × success and checks) and the verdict lines.
  "Add to layer set…" on tasks, sessions and commits.
- **Error Analysis → Modes → fix draft**: brain layer and part pickers; "Add exemplars to
  layer set"; "Evaluate layer".
- **Lab**: layer cells are control runs in the same queue; their setup label reads
  "layer swiftui@a1b2c3d · Claude Code · opus · high".

Every operation also has an `akit` command next to the existing `akit analysis control …`
(`akit analysis control layer-set …`, `akit analysis control evaluate <layer>`), so an
agent skill can drive it too.

## Storage

```
~/.akit/lab/evals/
  tasks/<id>.json          # control tasks (existing), now also from commits (pointing at
                           # the replay cache ~/.akit/lab/tasks/<sha>.json)
  sets/<layer>.json        # layer sets: task ids + field answers
  overlays/<hash>/         # rendered overlays, one per setup
  verdicts/<layer>.json    # last verdicts per model, for the badge
~/.akit/lab/<run-id>/      # a cell (kind control): + added-lines.diff, commands.jsonl,
                           #   harness version in the result
brain/layers/<name>/
  layer.yaml               # + checks:
```

## Safety and privacy

- The layer is written into the isolated clone only, never into the user's repository.
- Task prompts, repository paths, overlays, cells and verdicts stay local; only `checks:`
  (patterns, project details through fields) live in the brain.
- Control runs go through the sending policy and the monthly limit, as today; the cost is
  estimated before queueing.

## Implementation plan

Each slice works in the installed AKit, has its UI, and is tested with a fake `claude`
(`lab.md`; no tokens spent). Paid runs are started by the user.

1. **Overlay and layer setup.** Neutral overlay in `ControlCell` (generalizes
   `ControlPatch`); render in `AKitErrorAnalysis` (dependency on `AKitRender`,
   `architecture.md` updated); render once at queueing from a clean brain, stored by hash;
   required layers as the baseline; fields precedence; the Markdown rule; blocked tasks;
   `LayerVariant`; home fingerprint; cell key and pairing changes; overlap warning. UI: pick
   a layer as a setup in Error Analysis → Evals.
2. **Commit tasks and layer sets.** `Source.commit` and `Oracle.hiddenTests` over the replay
   cache; guard and leak changes for them; `sets/<layer>.json`; "Add to layer set…" on
   commits, sessions, tasks; `akit analysis control layer-set`.
3. **Artifacts for checks.** T0/T1 trees, `added-lines.diff`, `commands.jsonl` with
   subagent tool calls (new subagent reader in `AKitSessions`).
4. **Checks.** `checks:` in `layer.yaml` (parse, validate, show mistakes in Brain; fields in
   patterns); computed at comparison time with the scoring rules.
5. **Verdict.** Offline level for layer setups; per-check verdicts; worse share in `Paired`;
   the result lines; `verdicts/<layer>.json`.
6. **Brain UI.** "Evaluate…" sheet and the badge; `akit analysis control evaluate`.
7. **Link to error analysis.** `brainLayer` / `layerPart` on fix drafts; "Add exemplars to
   layer set"; modes listed on the layer.
8. **Pilot** (content, no code): layer `swiftui` with 3–5 checks and a set of 20+ tasks
   from AKit's own history; the user runs it.
9. **Production level.** "Confirmed in work" / "worse in work" from linked modes;
   `LayerHistory` made public.

## Later

| Item | Needs |
|---|---|
| Variants "contract only" and "layer without one part" | `parts` in the overlay and the UI |
| Baseline "the project's layers without X" | the project's answers rendered into the clone |
| Regression: layer at commit A against commit B | render from `git archive <commit>` instead of a clean working tree |
| Layer against layer | two layer setups with different `layer` |
| `lean` for control setups | a flag on `ControlSetup` |
| Clean home (`--bare` with the user's API key) | an agent option |
| Check kinds `command` and `order` | watchdog for commands; event order in the transcript |
| Candidate tasks by the layer's `paths:` | new `layer.yaml` field |
| Commit tasks for non-Swift repositories | a test runner per stack |
| Hooks in layers | JSON deep merge of `.claude/settings.json` (`layers.md`, "Several layers, one file") |
| Seeded trap (files before the run) and seeded bug (agent's tests against a broken version after it) | overlays on control tasks |
| Differential oracle (a check on the base and on the result, compared) | for refactoring, bundler and compiler migrations |
| Skill trigger evals (prompt → was the skill invoked) | cheap single-turn runs |
| User simulator for tasks with vague requirements | a second agent with the hidden intent |
| Publishing tasks of public repositories into the layer | URL + commit instead of a path; scrub check |

## Appendix: layers for other kinds of work

A catalog from the same session, for choosing future layers and their oracles. Oracle
kinds: **known answer** (hidden tests), **differential** (before = after), **seeded** (a
trap before the run or a bug after it), **process** (the transcript), **guard** (no
weakened tests or suppressions).

| Kind of work | Typical failures | Oracle | Kind |
|---|---|---|---|
| Refactoring | behaviour changed; tests "fixed" to pass; dynamically used code deleted; public API changed | characterization tests green before and after; test files unchanged; a trap function called by name from a string still exists; exports or `.d.ts` unchanged | differential, guard, seeded |
| Business task from a spec | an acceptance criterion missed; an edge case buried in the text missed; invented requirements | one hidden test per criterion (share passed); a test for the buried case; diff only where expected; the agent's tests red on a seeded bug | known answer, seeded |
| Bundler migration (e.g. to rsbuild) | a build feature silently lost (alias, proxy, env, SVG import); "builds" but broken; type check or lint switched off | a seeded project with each feature, a check per feature; smoke test of the built app; routes, assets and env equal to the old build; tsc and lint still pass | seeded, differential, guard |
| Compiler migration (tsc → tsgo) | errors suppressed; `tsconfig` weakened; emit changed; CI still calls `tsc` | no new `@ts-ignore`/`any`; key flags unchanged; same error list and `.d.ts` as `tsc`; no `tsc` in scripts | guard, differential |
| Bug fix | symptom fixed, not the cause; no regression test; not reproduced first; error suppressed | hidden tests for every caller of a shared helper; the agent's test red on the base; a failing run before the first edit; no empty `catch` | seeded, process, guard |
| Vague requirements | guesses and codes at once; too many or empty questions; builds the wrong thing | a question about the key ambiguity before the first edit; hidden tests for the hidden intent (needs a user simulator); assumptions listed | process, known answer |
| Dependency upgrade | upgraded without reading breaking changes | a trap using a removed API; tests; no `--legacy-peer-deps` | seeded |
| Database migration | data lost; no rollback | rows that break the new constraint; up → down → up; data intact | seeded |
| Docs in sync | code changed, docs not | a view change → a guide change in the same commit | process |
| Secrets | tokens printed or read | a fake token in a file; it never appears in output or diff | seeded |

## Relation to other designs

- **Error analysis** (`error-analysis.md`): layer evals are its controlled evals with a
  layer as the setup. The offline verdict level applies to layer setups only; a mode's fix
  status keeps the production guard.
- **Lab** (`lab.md`): cells are control runs; isolation, leak flags, watchdog and the fake
  `claude` test recipe are reused.
- **Layers** (`layers.md`): `layer.yaml` gains `checks:`; rendering is reused, the overlay
  differs from Apply for project-owned Markdown (see above).
- **Architecture** (`architecture.md`): `AKitErrorAnalysis` gains a dependency on
  `AKitRender`.
- **Definitions** (`definitions.md`): statistics rules; the home fingerprint here is
  narrower than the session fingerprint there.

## Open questions

- The Markdown rule appends where Apply only offers. If evals show a layer helps, Apply may
  need an "append the layer's section" choice for project-owned files, or the gain stays
  offline only.
- A `diff` check sees T0..T1 only; a pattern the agent added and removed again isn't
  counted (a `transcript` or later `order` question).
- Pi's choice when a folder has both `AGENTS.md` and `CLAUDE.md` isn't verified; until it
  is, such tasks are blocked for Pi cells.
- The overlap warning compares skill names only; two skills with different names and the
  same content aren't caught.
