# Layer evals: does a layer help?

Status: design 2026-10-03, decided in a grilling session and revised after a fact-check
against the code. Narrowed on 2026-10-08 by the decisions I2, D2, D3 and D4 (see
[Decisions (2026-10-08)](#decisions-2026-10-08)): v1 is for Claude Code only, without a
home fingerprint, with the verdict offline only. Slices 1, 2, 5 and 6 built 2026-10-08 (see
[Built](#built)); the pilot is next (step 4 of `README.md`).

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
| cost estimate before queueing; monthly limit and sending policy per cell | `ControlRuns.estimate` (slice 6; the app and `akit` share it), `ControlRuns` | done |
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
| 2 | The home folder in the baseline | As it is: the user's full setup, as control cells run today. AKit warns when a skill of the layer is already installed elsewhere. Pairing changed on 2026-10-08 (D2): cells pair only within one eval run; no fingerprint |
| 3 | The project's own harness files in the clone | They stay; the layer goes on top. "The project's layers without X" later |
| 4 | Variants | Two: baseline and the whole layer, plus read-only as a sanity check. Changed on 2026-10-08 (I2): no list of the layer's parts in the format yet |
| 5 | Model | One per eval, by default the one you work with. Evals of other models line up into a matrix |
| 6 | Where tasks live | Locally, `~/.akit/lab/evals/`. Publishing tasks of public repositories into the layer later |
| 7 | How tasks enter a layer's set | By hand and from a failure mode's exemplar sessions. Suggestions by the layer's paths later. New task source: a commit |
| 8 | Success | The task's oracle decides success (tests, preferred for layer sets, or a mode's assertion). Quality checks from `layer.yaml` are separate columns |
| 9 | Check kinds in v1 | `diff` and `transcript`. `command` and `order` later |
| 10 | Link between a mode and a layer | Local, in the mode's fix draft |
| 11 | Production guard | Two levels: "helps (offline)" from the task set; "confirmed in work" once the layer is applied and enough sessions exist. 2026-10-08 (I2): the production level (slice 9) waits for active modes |
| 12 | Quality-only gain | Each check gets its own verdict, if success didn't get worse; 3–5 checks per layer |
| 13 | UI | A button and the last verdict on the layer in Brain; details in Error Analysis → Evals |

## Decisions (2026-10-08)

Accepted by the user after the 2026-10-03 review (`README.md`, I2 and D2–D4) and the
step 4 work plan.

| # | Decision | Effect |
|---|---|---|
| I2 | Layer evals v1 are for **Claude Code only**. No `parts` field. Slices 7 (link to modes) and 9 (production level) wait for active modes. The pilot comes before the checks: slices 3 and 4 become step 5, built only if the pilot shows that success alone can't see the gain | Layer setups refuse a Pi agent. The Pi rules below are marked "not in v1" |
| D2 | **No fingerprint in v1.** Cells pair only within one eval run and one agent (harness, model, effort), so both sides share the harness version and the home state by construction. The eval id is part of the cell key. Each cell records its Claude Code version; the result warns when one eval mixes versions. The overlap warning stays | See [Baseline](#baseline-the-home-folder-as-it-is) and [Format](#format) |
| D3 | **Apply is not changed.** The layer's verdict stays offline only. The eval appends the layer's `AGENTS.md` section to the clone's own `CLAUDE.md` or `AGENTS.md`; results mark tasks whose project has its own `CLAUDE.md` | The open question "Apply may need an append choice" is closed |
| D4 / I3 | **Not accepted now.** Layer setups get their own "helps (offline)" level (slice 5). Patch-fix verdicts don't change: a fix pair never gets "helps (offline)" | A test proves patch pairs never get it |

Further choices of the step 4 plan, accepted on the same day:

1. **One repository per eval in v1.** `project_name` and the project's stored answers
   depend on the task's repository, so an eval refuses tasks of more than one repository
   (and, from slice 2, a layer set refuses a task of another repository).
2. **Merged JSON outputs are refused in v1.** A layer whose render has an output that is
   merged key by key (`.mcp.json`, `.claude/settings.json`, `RenderedFile.mergesJSON`) can't
   be evaluated yet: merging into the clone's file needs `JSONMerge` from
   `AKitProjectSetup`. Every other `.json` output (also inside skill folders) is an ordinary
   file.
3. **Eval folder** `~/.akit/lab/evals/layer-evals/<eval-id>/` instead of a shared
   `overlays/<hash>/` store: the manifest with the exact setups, plus the overlays.
   Continue reuses the setups verbatim, so comparison rows don't split.
4. **No reuse of baseline cells across evals.** Every new eval queues new cells; only
   Continue reuses an eval's finished cells.
5. **Continue runs only the eval's starting tasks.** Tasks added to the set later need a
   new eval, so the task population of one eval never changes.
6. **The core layer is not offered for evaluation** (it is the home folder's layer; the
   overlap warning would always fire).
7. **A project's own `.claude/skills` folder blocks the task** with a clear message, as it
   blocks Apply.
8. **Paid calibration** (one cell to measure the cost, slice 6) is fine, but only after
   the user confirms it.
9. **A watchdog guards the agent phase** of control cells (slice 2), so an agent's own
   `swift test` in an AKitCore clone can't grow without limit.

## Built

**Slice 1, overlay and layer setup (2026-10-08).**

- `ControlOverlay` (`AKitLab`): the entries (`agentsSection`, `markdown`, `skillFile`,
  `claudeSkillsLink`, `file`), their hash (canonical JSON of the sorted entries and the
  rules version; no dates, no brain commit), the stored form (`overlay.json` plus
  `files/<path>`, each file checked against its hash when read), the placement rules of
  [Layer setup: on top of the project](#layer-setup-on-top-of-the-project) and apply with
  hiding. `CloneFiles` reads either the base commit's git tree (at queueing) or the clone's
  folder (before the agent); a test proves both give the same placement. Paths are compared
  ignoring letter case. A link out of the clone, an absolute path, `..` or `.git` blocks;
  so does a root `AGENTS.md` without any `CLAUDE.md` (see [Open questions](#open-questions)).
  A skill's executable file stays executable (`executable` in its entry).
- `LayerSetups.prepare` (`AKitErrorAnalysis`): refuses a Pi agent, the core layer, tasks of
  more than one repository, a brain with uncommitted changes in the layer's closure or its
  skills, a render error (a required field without a value) and merged JSON outputs; renders
  "required layers + X" and "required layers alone" for `claude`; checks both against every
  task's base commit (blocked tasks with their reason, notes such as "appended to the
  project's own CLAUDE.md"); the overlap with Claude Code's home skills and the project's
  tracked skills. Answers: explicit, then the project's saved answers (store of this Mac),
  then the defaults; an empty explicit answer keeps the default.
- Eval folder `layer-evals/<eval-id>/` with `manifest.json` and `overlays/<hash>/`, written
  under a temporary name and moved into place before the cells are queued. Continue (`--eval
  ID`) renders again and refuses when a hash differs; otherwise it reuses the manifest's
  setups, tasks and repeats verbatim (`--eval ID` needs no task list; another list or
  `--repeats` value is refused).
- Cell key: layer setups add the layer, role, overlay hash, eval id and rules version; the
  keys of other setups stay byte-identical (golden test). Read-only sanity cells (required
  layers alone, read-only tools, the first 3 tasks, 1 repeat) are queued after the first
  repeat.
- `result.json`: `control.overlay` (always on a layer cell) and `control.harnessVersion`.
  The comparison leaves out a layer cell without `overlay` ("n cells run by an older akit,
  left out"), and warns when a pair mixes Claude Code versions.
- Pairing as in [Format](#format). In slice 1 every layer pair said "no conclusion"; slice 5
  gives layers their own level (below). A layer cell run by an older akit (no `overlay`) is
  not counted as done, so it is queued again.
- UI: Error Analysis → Evals → **Run Cells…** → Difference **A brain layer** (layer picker,
  the two setups with their overlay hashes, blocked tasks, notes, overlap). The app queues
  only through an `akit` whose `akit lab --help` names "control cells with a brain layer".
  CLI: `akit analysis control run TASK[,…] --layer NAME [--answer FIELD=VALUE]… [--eval ID]
  [--brain DIR]`.

**Slice 2, commit tasks and layer sets (2026-10-08).**

- `ControlTask.Source.commit(sha:)` and `Oracle.hiddenTests(commit:)` ("hidden tests of
  a1b2c3d"). `ControlTasks.fromCommit` checks the commit as a replay task (or takes the
  cached one), base = parent, prompt = the replay prompt, reference = the commit
  (`referenceGreen` true); a commit that already has a task gives that task back. Older
  AKit builds can't decode the new cases and leave such tasks out: install the app and
  `akit` together (the app queues them only through an `akit` whose `akit lab --help`
  names "hidden tests").
- `HiddenTests` (`AKitLab`) is the replay's hidden-test phase, moved out of `ReplayRun`
  (replays unchanged) and used by `ControlCell.run(…, oracle: CellOracle)` (`.command`,
  `.hidden`, `.none`). The cell result carries the outcome in `tests`; the oracle line
  reads "hidden tests: 1/1 fail-to-pass, 1/1 pass-to-pass". The guard leaves the hidden
  test files out of its before/after snapshots; the leak check adds the commit's hash (as
  a word of its own, in tool calls or results) and AKit's Lab folder (any path with
  `.akit/lab`; see the leak signs below), read from Claude Code's transcript files, so hidden-test tasks run Claude
  Code only for now. Every control cell and replay also flags a tool call into the Trash
  (`/.Trash`), where finished clones and a commit's validation folder go. The agent phase
  of every control cell runs under the memory watchdog.
- Layer sets `~/.akit/lab/evals/sets/<layer>.json` (`schema` 1; tasks, answers,
  `createdAt`, `updatedAt`), changed under the file's lock; a newer schema is skipped and
  never overwritten. One repository per set (v1): a task of another repository is refused
  while the set holds tasks of one. Worktrees of one repository count as one (their shared
  git folder, read from `.git` and `commondir`); an eval takes the project's answers and
  `project_name` from the main folder, so a task made in a worktree finds them. A task
  records that main folder when it is made (`mainRepo`; older tasks find it from `repo`),
  so a removed worktree doesn't split the set: its cells clone from the main folder
  (worktrees share the objects; the cell key has no repository path). A task whose
  repository is gone altogether is blocked by itself. Note: an eval queued by slice 1 with
  tasks of a worktree rendered `project_name` from the worktree's folder, so Continue of it
  may refuse ("The layer changed since the eval…"); that fails safe, start a new eval.
  Missing task ids are shown as missing and skipped. The set's answers are the eval's
  explicit answers (`--answer` still wins in the CLI). Core has no set.
- Leak signs (pre-pilot hardening, 2026-10-08), the same for replays (`LeakCheck`) and
  control cells (`ControlRuns.leaks`, plus `LeakCheck.commitSigns` for a commit task):
  - Read from the whole input of a tool call, the text it writes included (a script
    written and then run is caught): the real repository, the Trash (`/.Trash`), the
    commit's hash (also in tool results) and the exemplar's session id. The whole input
    is the input's string values, one per line with their own line breaks (not JSON
    text, where a line break becomes `\n` and the hash at a line start isn't a word of
    its own). The real repository is the task's folder and its main folder
    (`LeakCheck.repositoryPaths`: as given, standardized, symlinks resolved; never `/`),
    so a worktree task whose agent reads the main checkout is flagged; under the home
    folder (this Mac's, and the environment's when another) also as `~/…`, `$HOME/…` and
    `${HOME}/…`. A path matches only as a whole folder (`LeakCheck.mentions`): followed
    by `/`, the end, a character that can't continue a name (quote, space, `:`, `)` …),
    or a `.` before a space or the end, so `/x/akit-other` and `/x/akit.git` don't name
    `/x/akit`, while "see /x/akit." does.
  - Read only from what a call asks for (`LeakCheck.pathLikeInput`), since AKit's own
    sources mention them and editing those is no leak: AKit's Lab folder (`.akit/lab`) and
    the session history (`.claude/projects`, `.pi/agent/sessions`; a `session_search`
    tool by name). What a call asks for: a shell command; `file_path`, `notebook_path` or
    `path` of a file tool that reads or writes (not its content); `path` and `glob` of
    `Grep` (not `pattern`, a content regex); `pattern` and `path` of `Glob`, `find`, `ls`.
    Pi's `read`, `grep`, `find`, `ls` take the same argument names. Nothing of free text:
    `Task` and `Agent` (a subagent's prompt), `TodoWrite`, `ExitPlanMode`,
    `AskUserQuestion`. An unknown tool's whole input.
  - The pilot rejects commits whose diff contains `/.Trash` or the absolute repository
    path (also as `~/…`, `$HOME/…`, `${HOME}/…`): an agent redoing them writes those
    strings and is flagged. Known files that hold them today: `ControlRuns.swift`,
    `ReplayTask.swift`, `ControlRunsTests.swift`, `ReplayTests.swift`, `ScrubberTests.swift`,
    `docs/design/layer-evals.md`, `docs/guides/error-analysis.ru.md`, `install.sh`.
  - Known gaps: a search rooted at the home folder that reaches a sign without naming it
    (`grep -r <hash> ~` finds the hash, but `find ~ -name run.json` is not flagged); a
    path split across commands (`cd ~/.akit && cat lab/…`); letter case (`~/.Akit/Lab`
    on a case-insensitive disk); subagents of Pi extensions (only Claude Code's subagent
    files are read).
  - Subagents count: Claude Code writes a `Task` subagent's calls to
    `<session>/subagents/*.jsonl` next to `<session>.jsonl` (older versions: side-chain
    lines of the session file). `LeakCheck` reads them for replays and commit signs;
    `LeakCheck.subagentCalls` feeds them to `ControlRuns.leaks` for cells.
  - A task without `mainRepo` (made before it was recorded) whose worktree is gone gets
    its main folder when it is loaded (`ControlTasks.load`/`list`,
    `LabGit.mainFolder(ofGone:base:env:)`), only when both hold: the layout proves it (the
    gone folder is `<main>/.claude/worktrees/<name>`, or an ancestor's
    `.git/worktrees/*/gitdir` still names `<gone>/.git`; ancestors up to, not including,
    the environment's home folder and `/`), and `<main>` holds the task's base commit
    (`git cat-file -e`). Otherwise the task stays gone and blocked, as before. This is not
    only a leak sign: the found folder is the task's main folder everywhere, so it decides
    which set it may join (one repository per set), whether it is blocked in an eval, and
    where its cells clone from.
- UI: Evals → **From Commit…** (repository, recent commits that change Swift tests with
  "checked" marks, **Check and Save**, optional set), **Layer Sets** in the sidebar with a
  set page (tasks, missing marked, **Remove from Set**, the answers editor with **Save
  Answers**, **Run Cells…** on the set's tasks with the layer chosen, **Delete Set…**),
  **Add to Layer Set…** and "In sets" on a task, **Add to layer set** in the From
  Session… and Reproduction… sheets, and **Add to Layer Set…** on a Claude Code or Pi
  session of the Sessions screen (the From Session… sheet with that session). CLI: `akit
  analysis control task new --commit SHA [--repo DIR]`, `--layer-set LAYER` on every form
  of `task new`, `layer-sets`, `layer-set LAYER [add|remove TASK[,…] | answer FIELD=VALUE…
  | delete]`.
- Not in this slice: "From a failure mode" (slice 7, waits), a Continue that picks up tasks
  added to the set later (by design, decision 5).

**Slice 5, verdict (2026-10-08).** Success only (checks are step 5).

- `ControlComparison`: a layer pair (`role: layer`) is judged offline: at least 95% of the
  bootstrap mass on improvement, with 3+ repeats and 15+ cells a side, gives **helps
  (offline)** (`helps-offline`) without the production guard; below that, "didn't show it
  helped". A read-only cell of the same eval and agent that passed leaves the pair at "no
  conclusion" ("A read-only agent passed <task>: its oracle can't tell work from no work"),
  also when that task isn't among the compared ones (`compare(_:sanity:)`). A setup with
  both a patch and a layer is not paired.
  Patch pairs keep the fix rule and never get the offline level (D4; a test runs the same
  cells as both). `Paired.worseShare`: the share of bootstrap sums strictly below zero (ties
  count for neither), computed for every pair. Both shares come from exact sums: each
  task's change is an integer over the least common multiple of the task totals, so changes
  in thirds that cancel are ties, never a floating-point "improvement" (patch pairs too).
  The stored `reason` never names a task (task ids come from prompts).
- `LayerVerdicts` (`AKitErrorAnalysis`): `verdict(of:runs:costs:)` gives an eval's verdict
  once none of its cells is queued or running (nil before, and nil when no task has finished
  cells of both setups, so a cancelled eval never replaces a stored verdict); `save` keeps the last verdict per
  agent (harness, model, effort) in `verdicts/<layer>.json` (schema 1; a newer schema is
  skipped and never overwritten), where an older eval never replaces a newer one's verdict;
  `load`; `lines` (the result lines below). The manifest now records `ownFiles` for the count
  of tasks with the project's own `CLAUDE.md` (an older manifest shows none).
- UI: Error Analysis → Evals → the comparison shows "helps (offline)", the share on worse
  next to the share on improvement, and under a layer pair the eval's result lines ("Verdict
  of the eval (all its tasks), saved for the layer:") or "The eval's verdict waits for N
  cells still queued or running." When the shown eval has no open cell, the view saves its
  verdict off the main thread. CLI: `akit analysis control compare --eval ID [--json]` (the
  comparison, the lines, and the save); `compare TASK[,…]` prints `helps (offline)` for
  layer pairs and is otherwise unchanged.
- What slice 6 needs: `LayerVerdicts.load(layer:env:)` for the badge, `LayerVerdict.agent`,
  `decidedAt`, `brainCommit`, `verdict.title`, and `LayerEvalStore.evals(of:)` for running
  evals.

**Slice 6, Brain UI and `evaluate` (2026-10-08).**

- `ControlRuns.estimate(cells:agent:repo:env:)` (`CostEstimate`) is the one estimate the app
  and `akit` show before cells are queued (it replaced their two copies): the recorded cost
  per cell of earlier control cells of the same harness and model, else of replays of them;
  the mean times the cells, a range (the lowest and highest recorded cell times the cells)
  and the number of records; the time in the Lab queue from the median duration of finished
  control runs, else replays (`startedAt` → `updatedAt`: clone, agent and hidden-test build),
  of the tasks' repository first, else of any repository, times the cells (the queue runs
  one at a time). The time line says where the median comes from ("median of 9 control runs
  of this repository"). With no record there is no estimate. `ControlRuns.plan` is a dry run
  of `newControlRuns` (cells to queue and cells skipped), so only cells still to run are
  estimated.
- `LayerEvals.plan` (`AKitErrorAnalysis`) plans an eval of the layer's set: prepare, the cells
  to queue, the estimate, and the latest eval of the layer and agent that renders the same
  files (`Resumable`: cells done, open, left; `calibrating` while a setup has no finished
  cell). It writes nothing. `LayerEvals.queue` holds a file lock per eval
  (`layer-evals/.<id>.lock`), counts and estimates the cells again and refuses when more
  cells would run than the plan said ("The eval changed since the estimate …; check it
  again": a cell that failed or was cancelled since runs again) or when the fresh estimate's
  high end is above the amount the user confirmed (`maxCost`). Then it checks the monthly
  limit with the fresh estimate (`SendLog.checkLimit`; a send log that exists but can't be
  read now refuses when a limit is set), writes the eval folder, and queues the cells. A new
  eval whose cells can't be queued has its folder removed again. Without an estimate it
  refuses and only **calibration** is possible: exactly one cell, the first not yet done
  (repeat 1 of the baseline of the first task in a new eval); under the lock a second
  calibration cell is refused while one of the eval is queued or running. The eval keeps the
  calibration cell, and the next Evaluate continues that eval by default while not every
  setup has a finished cell (so the paid cell is reused); `--new` (CLI) or the Continue
  toggle (app) starts another.
- Every paid queue of **Run Cells…** (plain and patch setups too) counts the cells still to
  run, estimates them and asks before queueing: "Queue up to N cells for about $X (range
  $L–$H)?", or "Queue N cells with no estimate yet?" when no cost is recorded; the app counts
  and estimates again before it queues. The hint for a variant without its baseline says "it
  costs nothing" only when the baseline has no cell left to run. `control run --yes` without
  `--layer` prints the cells to run and the estimate, and needs `--max-cost USD` once a cost
  is recorded (without one, `--yes` alone with the count shown).
- The same money rule for **Run Cells…** with a brain layer and `run --layer`: no recorded
  cost, no paid layer cell (the button stays disabled and points to Brain → layer →
  Evaluate… for the calibration cell; the CLI refuses with the `evaluate --calibrate`
  command); otherwise the button waits for the estimate and asks "Queue up to N cells for
  about $X (range $L–$H)?"; both queue through `LayerEvals.queue` (the lock, the second count,
  the cleanup of a new eval's folder and lock). The
  CLI's `--yes` for paid layer cells (`evaluate` and `run --layer`) needs `--max-cost USD`
  and refuses when the estimate's high end is above it; `--calibrate --yes` needs none (one
  cell) and prints the cell's expected range when there is one. The app's confirmations add
  "k other queued runs will start too" when the Lab queue holds other runs.
- **Denied commands** (the pilot safety rule, decided by the user): `ControlSetup.denied`
  (shell command prefixes) goes into Claude Code's one `--disallowedTools` flag as
  `Bash(<command>:*)`, next to the push rule every run has (one flag with all values; a
  test reads the fake `claude`'s argv). A layer eval gives the same list to both setups and
  the read-only cells, so the comparison stays fair. In AKit's own repository (it has
  `AKitCore/Package.swift`) the default is every Makefile target that builds, installs or
  starts AKit or another app, `open` and `swift run` (`swift build` and `swift test` stay
  allowed): `make snapshot, make run, make restart, make install, make install-cli, make
  screenshots, make open, open, swift run` (a test parses the Makefile
  and fails when a new launching or installing target is missing). AKit's `CLAUDE.md` asks
  for `make snapshot` after UI changes, and these would build and start a development AKit
  against the real `~/.akit`. Other repositories get none. The default applies to **every**
  control cell (a setup with `denied` nil gets it when its cells are queued, `--no-deny`
  stores an explicit empty list; a cell an older version queued without the list gets it when
  it runs, its key unchanged) and to every replay in AKit's own repository (at run time).
  The list is in the cell key only when it is not empty, so keys change only for cells in
  AKit's own repository: their earlier finished cells (without the list) don't count as done
  and run again. A continued eval keeps its own list; continuing one that denies nothing in
  AKit's own repository warns. Entries are command prefixes: one with `(`, `)` or `*` (a
  permission rule such as `Bash(make run:*)`) is refused. The app queues such cells only
  through an `akit` whose `akit lab --help` names "denied commands". **What it doesn't
  catch:** a prefix rule sees the command as written, so `make -C . snapshot`,
  `make OUT=x snapshot`, `cd x && …` chains Claude Code splits differently, a script that
  calls make, and running a built binary directly (`build/…/AKit.app/Contents/MacOS/AKit`,
  `AKitCore/.build/…/akit`, `xcodebuild` followed by either) are not denied; Pi cells get no list (Pi has no deny flag). It guards the commands the
  project's own instructions name.
- UI: Brain → layer (not core) → **Evals** box: the last verdict per agent as a badge
  ("helps (offline)" · opus · high · the date · @a1b2c3d, the result lines in its help),
  "running: n of N cells" for an eval with open cells, **Evaluate…** (when the set has tasks),
  **Show in Error Analysis**, or **Create Layer Set** (an empty set, then Evals with it
  selected). The Brain list shows the newest verdict next to the layer's name. **Evaluate…**
  sheet: the eval (Continue toggle "Continue the eval of …: n of N cells done", set, answers
  read-only with **Edit in Set…**, setups, eval id, warnings, home overlap), the agent (model,
  effort, repeats, read-only sanity cells, "The agent may not run", Open in, Keep the clones),
  and under them the cells to run, the estimate and the time. **Queue N Cells…** asks "Queue N
  cells for about $X (range $L–$H)?" ("They run with your Claude Code account (…), go through
  the sending policy and count toward the monthly limit."); with no estimate it is disabled
  and **Queue 1 Calibration Cell…** asks "Queue 1 calibration cell?" ("1 paid cell to measure
  the cost; the eval reuses it."). Error Analysis → Evals → a layer set's page lists the
  layer's evals (newest first) with the comparison of the chosen one. Snapshot hook:
  `--section brain --select <layer> --tab evaluate`.
- CLI: `akit analysis control evaluate LAYER [--model M] [--effort E] [--repeats N]
  [--no-sanity] [--continue [ID] | --new] [--deny CMD[,CMD…] | --no-deny] [--brain DIR]
  [--env …] [--keep] [--calibrate] [--yes [--max-cost USD]] [--no-start] [--json]`, exempt
  from the model-flag refusal. Without `--yes` it prints the plan and the estimate and queues
  nothing; `--yes` without an estimate is refused; `--calibrate --yes` queues the one
  calibration cell.
- Not in this slice: the sheet offers Continue only for the latest eval of the layer and
  agent; an older one continues with `--continue ID`. The sheet doesn't edit answers (the
  set's page is the one editor).

Not checked yet: whether Claude Code reads a project's `AGENTS.md` by itself (see
[Open questions](#open-questions)); the check needs a transcript of a repository with
`AGENTS.md` and no import, which was not read in this slice.

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
   3. tree T0 recorded (step 5); agent (Claude Code; Pi not in v1) with the task's prompt; tree T1 recorded (step 5)
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
  skills of enabled plugins AKit already lists) and the project's tracked
  `.agents/skills` and `.claude/skills`: "`tdd` is already installed globally: the
  difference will look smaller than it is". It compares names only. (Pi's skill folders:
  not in v1, I2.)
- **One eval run, no fingerprint (D2).** The 2026-10-03 design had a home fingerprint in
  the cell key. It is not built. Instead every cell of a layer eval carries the **eval
  id** in its key, and cells are paired only within one eval id and one agent. Both sides
  of a pair run in the same queue, interleaved, so they share the home state and the
  harness version by construction. A new eval queues new cells (nothing is reused across
  evals; a layer with no `requires` no longer shares its baseline with other evals);
  **Continue** of an eval reuses its finished cells. Each cell records its Claude Code
  version (`control.harnessVersion`), and the result warns when one eval mixes versions
  (Claude Code may update during a long eval).

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
  `~/.akit/lab/evals/layer-evals/<eval-id>/overlays/<hash>/` (hash of the rendered
  content, answers included; see [Storage](#storage)). Every cell of the setup applies
  that stored overlay.
- **Required layers.** `resolve` brings every `requires` layer. The layer setup is "the
  required layers + X", and the **baseline is the required layers alone** (nothing when X
  requires none), so the ablation removes only X.
- **Fields.** One precedence: the explicit answers (the layer set's stored answers from
  slice 2, or `--answer` / the sheet), then the project's answers
  in its project store (`projects/<id>/answers.json` in the brain, or
  `~/.akit/local/projects/<id>/` on a work Mac) when the task repository is a project set
  up through AKit, then the defaults of `layer.yaml` (as `ProjectBundle.resolve` already
  does). The built-in `project_name` is the task repository's folder name, not the clone's
  random folder. A required field without a value blocks queueing.
- **Target.** The render target is the cell agent's harness: `claude` (`pi` not in v1, I2).

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
| `AGENTS.md` section, agent = Pi | Not in v1 (I2). Designed: Pi reads one of `AGENTS.md` and `CLAUDE.md` per folder. If the root has only one of them: append to it. If it has neither: write `AGENTS.md`. If it has both: the task is blocked for Pi until Pi's choice between them is verified |
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
    public var overlayHash: String?    // the stored overlay, answers included; nil = nothing written
    public var evalID: String          // the eval run: in the cell key; pairs only within it
    public var brainCommit: String     // rendered from; metadata, not in the cell key
}
```

`ControlSetup` gets `layer: LayerVariant?`. A setup has at most one of `patch` and
`layer`. When X requires no layers, its baseline is a `requiredOnly` setup with no overlay
(`overlayHash` nil): it runs like a plain setup, but its key carries the eval id, so it is
not shared with other evals (D2). No `parts` and no home fingerprint (I2, D2).

- **Cell key.** `ControlRuns.cellKey` today hashes only `patchFile`, `patchText` and
  `readOnly`, so a layer setup would get the baseline's key and be skipped as done. For a
  setup with a layer the key gains the layer name, the role, the overlay hash, the eval id
  and the overlay rules version; the keys of other setups stay byte-identical. The brain
  commit is left out: Continue of an eval after a brain commit that doesn't change X's
  rendered output keeps the same overlay hash and reuses finished cells.
- **Pairing.** `ControlComparison.compare` treats a setup with `role: layer` as a variant.
  It is paired only with the `requiredOnly` setup of the same X, the **same eval id** and
  the **same agent**. Layer rows never pair with plain baselines, and patch variants never
  pair with layer rows. The fallback to "the first baseline" stays for patch fixes only,
  and only among baselines with no layer.

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
| `transcript` | regex over the `command` field of the agent's shell tool calls (Bash for Claude Code; Pi's bash not in v1), subagents included |
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
before anyone uses it; a mode's fix status keeps the existing rule (D4, 2026-10-08: patch
fixes never get "helps (offline)"; see [Link to error analysis](#link-to-error-analysis)).

**v1 (slice 5, built).** Success only: per-check verdicts wait for step 5. Two more rules:

- **Read-only sanity.** If a read-only cell of the eval passed, the oracle can't tell work
  from no work, so the layer pair has no conclusion, whatever the shares.
- **Older akit.** A layer cell whose result has no `control.overlay` was run by an akit
  that ignored the layer: it is left out and counted ("n cells run by an older akit, left
  out").

The verdict waits until no cell of the eval is queued or running, then is stored as the
layer's last verdict for that agent (`verdicts/<layer>.json`; see [Storage](#storage)).
Result lines (success only):

```
swiftui · Claude Code · opus · high · 8 tasks × 3 · eval 2026-10-12 · brain a1b2c3d
success: 71% → 75%, didn't show it helped (81% of the bootstrap mass on improvement, 12% on worse; needs 95%)
read-only sanity: 0 of 3 passed · 1 flagged cell · Claude Code 2.1.290
home overlap: none · 8 tasks with the project's own CLAUDE.md or AGENTS.md (the project gets the layer's text only by accepting the suggestion) · $48.20
```

`cost` is the sum of the cost the eval's cells recorded (the send log); a cell without a
recorded cost adds nothing.

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
  is read from local storage, never from the brain. Built in slice 6 (see [Built](#built)),
  with the calibration cell when no cost is recorded yet and the denied commands.
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
  layer-evals/<eval-id>/   # one eval:
    manifest.json          #   the exact setups, tasks, blocked tasks, notes, overlap
    overlays/<hash>/       #   overlay.json + files/<path> (rendered bytes, answers filled)
  verdicts/<layer>.json    # last verdict per agent (harness, model, effort), for the
                           #   badge: numbers only, no prompts or repository paths
~/.akit/lab/<run-id>/      # a cell (kind control): controlSetup.layer in run.json;
                           #   control.overlay and control.harnessVersion in result.json;
                           #   later (step 5) added-lines.diff, commands.jsonl
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
   `architecture.md` updated); render once at queueing from a clean brain, stored in the
   eval folder; required layers as the baseline; fields precedence; the Markdown rule;
   blocked tasks; `LayerVariant` with the eval id; cell key and pairing changes; overlap
   warning; the Claude Code version per cell. UI: pick a layer as a setup in Error
   Analysis → Evals.
2. **Commit tasks and layer sets.** `Source.commit` and `Oracle.hiddenTests` over the replay
   cache; guard and leak changes for them; `sets/<layer>.json`; "Add to layer set…" on
   commits, sessions, tasks; `akit analysis control layer-set`.
3. **Artifacts for checks** (step 5, only if the pilot needs it, I2). T0/T1 trees, `added-lines.diff`, `commands.jsonl` with
   subagent tool calls (new subagent reader in `AKitSessions`; the leak check already reads
   subagent files with `LeakCheck.subagentCalls` in `AKitLab`, a starting point).
4. **Checks** (step 5, with slice 3). `checks:` in `layer.yaml` (parse, validate, show mistakes in Brain; fields in
   patterns); computed at comparison time with the scoring rules.
5. **Verdict.** Offline level for layer setups; per-check verdicts; worse share in `Paired`;
   the result lines; `verdicts/<layer>.json`.
6. **Brain UI.** "Evaluate…" sheet and the badge; `akit analysis control evaluate`.
7. **Link to error analysis** (waits, I2). `brainLayer` / `layerPart` on fix drafts; "Add exemplars to
   layer set"; modes listed on the layer.
8. **Pilot** (content, no code): layer `swiftui` and 5–8 commit tasks from AKit's own
   history, judged on success only, before slices 3–4 (I2); the user runs it.
9. **Production level** (waits, I2). "Confirmed in work" / "worse in work" from linked modes;
   `LayerHistory` made public.

## Later

| Item | Needs |
|---|---|
| Variants "contract only" and "layer without one part" | `parts` in `LayerVariant`, the overlay and the UI (left out of v1, I2) |
| Pi as the cell agent | the Pi rows of the Markdown rule; Pi's file choice verified (I2) |
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
- **Definitions** (`definitions.md`): statistics rules. The home fingerprint once designed
  here is not built (D2).

## Open questions

- Closed by D3 (2026-10-08): the Markdown rule appends where Apply only offers, and Apply
  stays as it is; the layer's verdict is offline only.
- Claude Code reading `AGENTS.md` by itself: the rule "the project's `AGENTS.md`, unread
  before, stays unread" assumes it doesn't. Not yet checked against a transcript; if it
  does, the `AGENTS.md` section goes to `AGENTS.md` instead. Until it is checked, a task
  whose base commit has a root `AGENTS.md` and neither `CLAUDE.md` nor `.claude/CLAUDE.md`
  is blocked ("The project has AGENTS.md but no CLAUDE.md; AKit can't yet tell what Claude
  Code reads there."): there a new `CLAUDE.md` would hide the question.
- A `diff` check sees T0..T1 only; a pattern the agent added and removed again isn't
  counted (a `transcript` or later `order` question).
- Pi's choice when a folder has both `AGENTS.md` and `CLAUDE.md` isn't verified (not in v1, I2).

- The overlap warning compares skill names only; two skills with different names and the
  same content aren't caught.
