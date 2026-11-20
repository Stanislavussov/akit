# Flows: agent orchestration for Pi

Status: 2026-11-16, spec revised after the ralplan review (plan in `.omc/plans/flows-plan.md`,
local); D24–D28 decided; step 1 built 2026-11-17 (`AKitFlows`, `akit flow`); steps 2a–2d built 2026-11-17 (runner core, handoff tool, worktree, gates); steps 3a–3b built 2026-11-17 (guard, Pi row, shortcuts, overlay, `make test-flows-e2e`); step 4 built 2026-11-17 (`brain/flows`, layers include flows, Apply, Flows screen, guide `flows.ru.md`); Runs screen not yet. Written from a web search, the Pi docs (context7,
`earendil-works/pi`), the Pi 1.5.2 package, Pi 1.0.4 `--help` and PurpleFlow (MIT). F1–F19
are the design; the spec audit A1–A22 is closed in the decisions below.

## Goal

One screen where the user sets up a multi-agent run for Pi and watches a recorded run: the
order of the steps, each step's agent, model, skills and tools, what passes from one step to
the next (the handoff), the gates where the user decides, and for a run: state, work and
tokens. The diagram is as simple as PurpleFlow's; setting a step up is a few pickers, not
code. What code guarantees, and what it does not, is in F15.

```
 Clarify ──▶ Plan ──▶ ◆ Approve ──▶ Implement ──▶ Checks ──▶ Review ──▶ ◆ Accept ──▶ Commit
                                       ▲             │ red        │ notes      │ notes
                                       └─────────────┴────────────┴────────────┘
```

## What the research says

| Finding | Source | What AKit does with it |
|---|---|---|
| Run the order in code, not by asking the model: an explicit state object drives retries and handoffs | Medium "Best practices…", Augment guide | F1: the Pi extension runs the steps in code; the model never chooses to skip one |
| Handoffs as typed data with a fixed schema, not free text | mer.vin (blog), arXiv 2606.02875 "Handoff debt" | F4: a handoff file with fixed fields |
| A check gate at every handoff | Augment guide, PurpleFlow | F5: checks and the two user gates |
| The writer never accepts its own work; the reviewer runs on another model | PurpleFlow, Anthropic guidance | F6: a flow with the same model on write and review fails AKit's check |
| Fresh context per step, only the handoff passes on | Anthropic long-running agents guidance | each step is a new Pi process |
| Trace every step: time, tokens, cost | Interlock | F7: tokens from Pi's JSON events, per step |
| Visual editors (CC Workflow Studio, React Flow canvas) give free graphs; users get lost in them | CC Workflow Studio, AgentsRoom | F2: a fixed column of steps with back-arrows, no free canvas |

## Pi facts and minimum version

Minimum Pi version for now: **1.0.4** (this Mac). Work-Mac probe output: pending
(`tools/pi-flow-probe.sh`, step 0); the minimum is raised if the work Mac needs it.

| Fact | Consequence |
|---|---|
| Pi's subagent example (`examples/extensions/subagent`, 1.5.2) starts each child with `pi --mode json -p --no-session`, parses JSON events for usage and chains with `{previous}` | Flows vendors its spawn and parse code (MIT, source noted), but not its flags |
| A chain started from a prompt template is run by the model: it may skip or reorder steps | The order is kept by the extension's code (F1) |
| 1.0.4 has `--skill <path>` (repeatable), `-ns` (no skills) | Skills are enforced: `-ns` + one `--skill` per named skill |
| `-t/--tools` and `--no-builtin-tools` exist; `--tools` keeps MCP tools unless an entry starts with `mcp__` | `--tools` does not enforce. The guard's allow-list does (F15) |
| `-e` is repeatable; `-ne` drops all extensions, an explicit `-e` still loads | A child runs `-ne -e guard [-e record] [-e per-step list]`. The per-step `-e` list is the real control of what a child can do |
| `--session-dir`, `--mode json` exist | Children keep session files (F17) |
| A `belowEditor` widget placement is seen only in the 1.5.2 example | Probe in step 0; fallback: above the editor (F18) |
| Pi p2/p3 has built-in subagents on `durable`, not installed on either Mac | A durable runner is later (F13) |
| Versions and plugins differ between Macs (work Mac: CLI 1.x with an extension; this Mac: 1.0.4 with `pi-subagents`) | The extension records `pi --version` in `run.json`; `akit flow check` warns per missing feature; on start the extension says what is missing on an old Pi (F11) |

Child command form (one home):

```
pi --mode json --session-dir <run>/sessions -ns --skill <path>… --model <M> \
   -ne -e akit-flow-guard.ts [-e akit-record.ts] [-e <per-step extensions>…]
```

No `-p`, stdin is `/dev/null`, the child has its own process group and is killed as a group
on Stop or abort. The prompt goes in through the extension, not the command line.

## Decisions

Split of roles (the user's rule, 2026-11-16): **AKit only models the behavior; Pi runs it.**
AKit edits, checks and renders the flow files and shows recorded runs. At run time it only
reads run records and writes a `STOP` file.

```
 AKit (model)                         Pi (runs)
 Flows screen ──▶ brain/flows/*.yaml   /flow feature "add export"
       │ Apply                               │
       ▼                                     ▼
 .pi/flows/*.yaml, ~/.pi/agent/flows/ ──▶ akit-flow.ts (Pi extension, rendered by Apply)
 akit-flow.ts, akit-flow-guard.ts            │ each step: the child command above
                                             ▼
 Runs screen ◀──── reads ───── run record <project>/.pi/akit-flow/runs/<run-id>/
```

- **F1 Pi runs the flow, in code.** The runner is the Pi extension `akit-flow.ts`: a thin
  file over a pure `flow-core.ts` (route lookup, visits, next state). It reads the flow file
  and starts each step as the child command above, with the step's model, skills, tools and
  prompt, in the run's worktree. The order, back-arrows and loop limit are kept by code, not
  by the model. It needs only Pi's extension API, so it works with any subagent plugin or
  none, on any Pi at or above the minimum. A step may not start its own subagents (D28):
  another agent is another step. The guard blocks subagent tools (F15).
- **F2 Simple diagram.** A flow is a column of steps. Each step is a card: agent, model,
  skills, tools, three route pickers (**on done / on failed / on blocked go to**), gate on or
  off, max loops. Routes that point to an earlier step are drawn as back-arrows. No free
  canvas. Parallel agents in one card are later (D26).
- **F3 A flow is a brain file.** `brain/flows/<name>.yaml` (steps, agents, models, skills,
  gates, routes, max loops). A layer can include flows (layers.md gets the rule); Apply
  renders them to the project's `.pi/flows/` or the home `~/.pi/agent/flows/`, with the two
  extensions. These writes are safe writes: backup and diff first; each rendered file has a
  content hash in its header, and on a hand-edited `akit-flow.ts` Apply shows the diff and
  refuses. On a work machine, flows of work projects stay in the local store, as layers do;
  nothing from a run goes to the brain repo. `akit flow check` (and the Check button) runs
  before Apply: agents, models and skills exist; every route exists; routes back point to an
  earlier step; a step's tools are a subset of the flow's and a step starts no nested flow
  (durable's rules, F13); the check commands pass F19's command rules; the reviewer's model
  differs from the implementer's (F6); the Pi features the flow needs exist.
- **F4 Handoff as JSON, OMC style, in `.pi`.** Like OMC's `.omc/handoffs/<sessionId>-<stage>.json`
  plus its chain ledger, but per run so several runs can go at once:

  ```
  <project>/.pi/akit-flow/
    runs/<run-id>/                  run-id = 20261116-1432-a3f9 (date, time, 4 hex)
      run.json                      cache of the state (below); has the Pi version
      events.jsonl                  the truth: states, times, tokens
      handoffs/02-implement-a1-<pi-session-id>.json   step number, step id, attempt, session
      evidence/NN-<step>-aN-checks.json   F19
      sessions/                     the steps' Pi session files (F17)
      deviations.jsonl              F16
      lock                          pid of the running extension
      STOP                          written by AKit's Stop button
    index.json                      the runs of this project, newest first
  ```

  A handoff file:

  ```json
  {
    "schema": "akit-flow-handoff/1",
    "run": "20261116-1432-a3f9",
    "flow": "feature",
    "step": { "index": 2, "id": "implement", "attempt": 1 },
    "session": "<pi session id>",
    "from": { "outcome": "done", "reason": "" },
    "next": { "step": "checks" },
    "goal": "Add CSV export",
    "done": ["Export button", "CSV writer with tests"],
    "files": [{ "path": "src/export.ts", "change": "added" }],
    "open_questions": [],
    "notes": "",
    "tokens": { "input": 0, "output": 0, "cache_read": 0, "cost": 0 },
    "deviations": 0
  }
  ```

  The model does not write the file. The guard gives each step a tool `flow_handoff` whose
  parameters are the model's part (`goal`, `done`, `files`, `open_questions`, `notes`,
  `outcome`, `reason`); Pi checks them against the tool's schema. The runner adds `run`,
  `step`, `session`, `next`, `tokens`, `deviations` itself and writes the file. A step that
  ends without a valid `flow_handoff` reruns once, then the run stops (a deviation).
  `outcome` is one of `done`, `failed`, `blocked`; the runner turns it into the next step by
  F19's route table. The next step gets the previous handoff as its input, not the whole
  output, and (2026-11-20) the newest done handoff of the last planner step before it, so a fix
  after red checks or the review still sees the plan; both without the record's ids, tokens and
  paths. Every prompt names the base commit (`git diff <base>` shows the run's changes). The handoff holds the run id and the child's session id, and that session file
  exists in `<run>/sessions`.

  Rules for the record:
  - **Privacy.** A run holds work code. Handoffs, deviation quotes, evidence and sessions
    never go into the brain or a template; the Runs screen has no copy or export button;
    `akit doctor` checks the exclude.
  - **Local only.** `.pi/akit-flow/` is added to the git common dir's `info/exclude`
    (layers.md, local-only files). A run lives in the main checkout's `.pi/akit-flow/`, so it
    outlives the worktree (OMC's lesson).
  - **Writes.** `run.json` is written atomically and only as a cache. `STOP` is in the
    AKit-owned run folder.
  - **Lock.** `<run>/lock` holds the pid. Resume refuses a live pid. Each run has its own
    branch. The Pi row shows only its own run.
- **F5 Gates and checks.** A check step runs the project's test and lint commands, set in
  the flow. A checker step with check commands starts no model (2026-11-20): the runner's
  checks are the whole step, and its handoff passes the previous step's work on with the
  evidence. Red goes by the step's route. At a gate the extension stops and asks in Pi
  (`ctx.ui.confirm` / `ctx.ui.editor`): Approve, or Send Back with a note. Max loops per step
  (default 3), then it stops and asks. Push and MR are always behind a gate; in v1 the runner
  never pushes or opens an MR at all: the run ends on its local branch `akit-flow/<run>`, and
  push or MR is the user's own act. The Accept gate
  shows `git diff` of the run branch; the handoff is only next to it.
- **F6 Model rules.** Models come from `PiModelPicker`. A flow whose reviewer has the same
  model as the implementer fails `akit flow check`; if it runs anyway, the run-start logs a
  deviation.
- **F7 Run record and tracking.** The extension writes each run to the folder in F4:
  `events.jsonl` (step, state, time, tokens and cost from Pi's JSON events), the handoffs,
  a summary. What Pi shows is in F18. AKit's Runs screen reads the same record and draws the
  same diagram (read-only), with deviations per step and the expected path from the routes;
  a recorded path the routes forbid is flagged. Stop writes `STOP`. Step sessions: F17.
- **F8 Isolation.** Each run works in its own git worktree and branch `akit-flow/<run>`.
  The extension creates and owns the worktree **outside the project tree**, by Review's
  path rule (`~/.akit/local/flows/runs/<run>/worktree`, as Review's `~/.akit/local/review/runs/<run>/worktree`); only records live in `.pi/akit-flow/`. After 14 days with a dead lock AKit runs
  `git worktree remove` only if the worktree is clean; a dirty one is kept and flagged in
  Runs (like R61), never deleted. Merge or MR stays the user's choice.
- **F9 Resume and commits.** The truth is `events.jsonl` plus the commit trailers; `run.json`
  is a cache, rebuilt on resume. Each finished step is a commit on the run branch with
  trailers `Flow-Run:`, `Flow-Step:`, `Flow-Attempt:`. `/flow resume` continues after the last
  step commit; a crashed step resets to it (attempt + 1). A gate edit is committed before the
  next step. Uncommitted changes at resume: warn and ask, never a silent reset. The Commit
  step either squashes (only on the local branch, never after a push) or keeps the per-step
  commits, per flow setting; its message comes from the handoff `goal`.
- **F10 Templates.** Built-in flows to copy into the brain. **Feature** follows PurpleFlow's
  order (the diagram above), prompts adapted from PurpleFlow's `core/prompts`, MIT, with the
  source noted. Since 2026-11-17 21 presets follow oh-my-claudecode's workflows, one Pi step
  per OMC role: **ralplan** (plan → architect → critique, gate; read only), **ralph** (implement
  → checks → verify, up to 5 loops → commit), **tdd** (test → implement → checks → review →
  commit), **debug** (trace → fix → checks → verify → commit), **review** (one read-only step),
  **deslop** (clean → checks → review → commit), **research** (research → report; read only),
  **deep-interview** (clarify → plan, both gated; read only), **autopilot** (deep-interview +
  ralplan + ralph), **plan**, **verify**, **security-review**, **interrogate** (three attacks in a
  row, then a verdict), **blast-radius**, **fix-ci**, **fix-merge-conflicts**, **hillclimb**
  (baseline, then change → checks → measure; a round that doesn't win is undone), **sharpen**,
  **how**, **why**, **deepinit**. A preset step may carry its own prompt instead of its agent's. Judges (reviewer, verifier, critic,
  architect) get the second model; F6 compares each judge with the makers whose work it checks:
  reviewer and verifier with implementer, tester, debugger and cleaner; critic and architect with
  planner (a reviewer may share the planner's model). No OMC `team` or `arena`: parallel steps are D26.
- **F11 Start from Pi.** `/flow [name] <task>`; without a name, the project's default flow.
  A tool `akit_flow` lets the model start one when the user asks in words ("do it by the
  Feature flow"); it first asks `ctx.ui.confirm`, and starts nothing without a yes. Settings
  come from `.pi/flows/` first, then `~/.pi/agent/flows/`: change a flow in AKit, Apply, and
  the next `/flow` uses it. On start the extension checks `pi --version` and the features it
  needs, and says what is missing.
- **F12 Terminal for modeling.** `akit flow list|show|check|schema|runs` with `--json` (no
  `run`: Pi runs). `flow.schema.json` is generated by `akit flow schema` and committed; a
  test fails on drift. They go into the `/akit` skill; `/akit-context` gets one line on
  `/flow`. The full table of operations is under Operations.
- **F13 durable later.** The model (flow, step, agent, handoff, run) keeps durable's rules:
  a step's tools are a subset of the flow's, and a step does not start nested flows;
  `akit flow check` tests both. A durable runner for Pi p2/p3 is later.
- **F14 Setup by clicks only.** Every setting on the Flows screen is a picker, a toggle or a
  drag: add a step from a list of agents, drag to reorder, model from `PiModelPicker`,
  skills and tools as check boxes, the three routes as pickers, gate as a switch, checks from
  the project's known commands. The YAML is never edited by hand; AKit writes it.
- **F15 What is guaranteed, and how (D24).** The user's rule: Pi must follow the flow. A model
  can't be forced to think a certain way, and no check is complete, so every rule is at one
  of three levels, and the doc says which.

  | Rule | How | Level |
  |---|---|---|
  | Order of steps, routes, back-arrows, loop limit | the runner; the model never picks the next step | enforced |
  | Model of a step | `--model` on the child | enforced |
  | Tools of a step | the guard's allow-list answers `tool_call` with `{ block: true, reason }`: any unlisted tool, built-in or `mcp__`, is blocked; `--tools` is only a hint, it keeps MCP tools | enforced |
  | Skills of a step | `-ns` + `--skill` per named skill; verified on Pi 1.0.4, work Mac pending the probe | enforced |
  | Files a step may change (Review: none; Bug step 1: tests only) | the guard blocks `edit` / `write` outside the step's paths; write-restricted steps have **no `bash`** by default | enforced |
  | Same, when the user allows `bash` | `git diff` after the step; sees the worktree's tracked files only, misses writes outside it, ignored files and network calls | checked (worktree, tracked files) |
  | Checks (tests, lint) | run by the extension; evidence file (F19); the check says that it ran and what it returned, not that the tests are complete | enforced |
  | Handoff is complete | the `flow_handoff` tool schema; invalid or missing → the step reruns once, then the run stops | checked |
  | Step rules such as "test fails before the fix" | a check the extension runs at the step's end (run tests, compare) | checked |
  | Subagents inside a step | the guard blocks subagent tools (D28); a per-step switch allows them | enforced when off, logged-only when on |
  | A step that allows `bash`, or loads extra `-e` extensions | what they do inside the step | logged-only |
  | Run records (`<project>/.pi/akit-flow`) are the runner's | the guard blocks `edit` / `write` there; a `bash` step can still rewrite them (known limit), so resume and Runs trust the step commits' trailers over the records | enforced for edit/write, logged-only for bash |
  | How the model works inside a step; quality of the work | review step and gates | the user decides |

  Code guarantees the order of steps, each step's model, its tool allow-list, and that every
  deviation is logged. The per-step `-e` list is the real control of what a child can do:
  work-Mac MCP or auth extensions go in it, named, never by default. Name-based blocks in the
  guard are defence in depth behind the allow-list.
- **F16 Deviation log.** Every blocked call, failed check, rerun handoff, no-route stop and
  gate Send Back is a line in the run's `deviations.jsonl`: step, rule, what the model tried,
  what happened (blocked, rerun, stopped). The Pi row shows a count (F18); AKit's Runs screen
  lists them per step, with the quote, next to the error modes of error-analysis.md.
- **F17 Every step can be evaluated (D27).** Children keep their session files in
  `<run>/sessions` (the child command, Pi facts). As D19, step sessions stay out of the
  existing Insights views. The Runs screen shows them; Sessions lists them with a `flow` tag
  behind a filter; Lab (review, numbers), error analysis, Corrections and the Tools tab open
  a step as any session. Whether a child's tokens are also in the parent session file is
  unproven; a fixture in step 5 settles it before any de-duplication rule.
- **F18 Buttons in Pi (D25).** The only home of Pi UI. Without changing Pi's own functions:
  - a widget **below the editor** shows one row of its own run's steps:
    `1 Plan ✓  2 Code ● 12k  3 Checks ○  4 Review ○   ⚠ 1`; if the step 0 probe finds no
    below-editor placement, the row goes above the editor;
  - shortcuts open a step: an overlay (`ctx.ui.custom`) with the child's live transcript;
    Esc closes it; `/flow show <n>` does the same. The overlay shows only what Pi itself
    renders for that tool event, with the redaction of the existing session viewer, and has
    no copy button (child tool output may hold secrets);
  - Pi's normal mode leaves the mouse to the terminal, so the "buttons" are shortcuts shown
    in the row; mouse clicks (Pi's fullscreen mode only) are later;
  - shortcuts are picked from the probe against `keybindings.md` of the installed version so
    they don't clash with Pi's built-in keys; a clash means no shortcut, `/flow show` still
    works.
- **F19 Routing and guardrails, taken from OMC's chain (oh-my-claudecode 5.8.0,
  `hooks/session-end`).** The only home of routing. OMC runs a chain of headless sessions
  with code-side routing; Flows takes the same parts:

  | OMC | Flows |
  |---|---|
  | Route table `outcome:reason` → next stage, `outcome:*` as fallback (`decideNextStage`) | F2's three route pickers become this table in the flow file; the runner looks the next step up, the model never names it. In Swift the same function is `FlowRouting.next`; golden vectors in `fixtures/flow-vectors/` run in Swift and in `node --test` |
  | A malformed table halts silently as `no-route` | AKit's check refuses a missing or bad route before Apply; the runner stops loudly on no route (a deviation) |
  | `visits` per stage in the chain ledger, capped | the run's state counts visits per step; the step's max loops caps it |
  | Ledger written before the next link starts | the state is in `events.jsonl` before each step starts, so a crash resumes at the right step (F9) |
  | Check evidence `state/runs/evidence/<sessionId>-checks.json`; a "checks passed" flag is trusted only with it | The runner writes `<run>/evidence/NN-<step>-aN-checks.json` (command, exit code, last lines of output); a check counts as green only with this file, never because the model says so |
  | Human gates kept for irreversible or outside-visible acts | Gates are fixed before merge, push, MR and any outside call (F5) |
  | Verify commands are a trust boundary: plain pattern, ≤ 10 commands, ≤ 120 chars | Check commands pass the same rules in AKit's check and again in the runner |
  | Stop marker | A `STOP` file in the run folder halts the run before the next step (AKit's Stop button writes it) |
  | Headless links run with a fixed tool profile and chosen setting sources | A child loads only the guard, `akit-record` and the step's named `-e` extensions (F15) |

- **F20 Compatibility between Pi and AKit.** Pi updates on its own and differs between Macs;
  AKit and its rendered files update with Apply. The parts that must agree, and how:

  | Contract | Rule |
  |---|---|
  | Flow file ↔ extension | Apply always renders the flows and both `.ts` files from the same AKit build, so they match. Each file carries `akit-flow-format: N`; an extension that meets a newer format refuses to run and says "run Apply in AKit". |
  | Extension ↔ Pi API | All Pi calls go through one file, `pi-adapter.ts` (spawn, events, UI, `tool_call`). A Pi change touches only it. The extension checks features at load (`typeof ctx.ui.setWidget`, placement option, flags in `pi --help`) instead of trusting version numbers, uses the fallback (row above the editor, `/flow show` without a shortcut), and writes the found features to `run.json`. |
  | Supported Pi versions | `minPi` (1.0.4) and `testedPi` (highest version the tests passed on) live in the rendered header. Below `minPi`: refuse. Above `testedPi`: run, with one warning line in the row and a note in `run.json`. |
  | Pi JSON events ↔ runner and AKit reader | Tolerant reader: known event types are parsed, unknown ones are counted and kept raw, never a crash. Missing token fields count as unknown, not zero. |
  | Run record ↔ AKit | `run.json`, events, handoffs carry a schema number (`akit-flow-handoff/1` …). AKit reads all older numbers; a newer one is shown read-only with "update AKit". |
  | Machine facts | `akit doctor` runs `tools/pi-flow-probe.sh` logic and stores `~/.akit/local/pi-capabilities.json` per Mac. The Flows screen greys out what this Mac's Pi can't do (and says why); `akit flow check` uses the same file. |
  | Tests | `make check-pi` runs the TS tests and the e2e test against each Pi version in a list (`npm pack` of `minPi` and the newest release, in a fake home). Passing raises `testedPi`. The vendored `.d.ts` stays at `minPi`. |
  | Pi updates | AKit's About / Update view shows the installed Pi version next to `testedPi`; when Pi is newer, it links the Pi changelog lines that mention extensions or the CLI. |
  | Plugins | Flows depends on no Pi plugin (`pi-subagents` and the like): children run with `-ne` and only the per-step `-e` list. |

## Operations

| Operation | Pi command | AKit button | `akit` command |
|---|---|---|---|
| Edit a flow | — | Flows: pickers, drag | `akit flow list`, `show <name>` (read only) |
| Check a flow | `/flow check` | Flows: Check | `akit flow check [--json]` |
| Write the flow and extensions | picked up by the next `/flow` | Flows: Apply (backup + diff) | `akit apply` |
| Print the file schema | — | — | `akit flow schema` |
| Start a run | `/flow [name] <task>`; tool `akit_flow` (confirm first) | — (Pi runs) | — |
| Resume a run | `/flow resume` | — | — |
| Open a step | shortcut, `/flow show <n>` | Runs: step card | — |
| Stop a run | — | Runs: Stop (writes `STOP`) | — |
| List and read runs | — | Runs screen | `akit flow runs [--json]` |
| Open a step in Lab, Corrections | — | Runs: Open in Lab / Corrections | existing `akit` commands |
| Check the exclude, store Pi's features | — | Flows: Pi version line, greyed-out options | `akit doctor` |
| Probe a Pi | — | — | `tools/pi-flow-probe.sh` (user runs it on the work Mac) |

`akit flow` has no `run`: Pi runs. Start and resume have no AKit button by the role split;
the gap is noted in "UI for every feature".

## Steps

Every step: `make build` and `make test` green; UI steps also `make snapshot`; the commit
updates its README row and this status note. Branch `flows`; merge, tag, install and release
at the end.

| # | Step | Built |
|---|---|---|
| 0 | Facts and spec: `tools/pi-flow-probe.sh` (version, flags, `tool_call` block, `belowEditor`, free shortcuts, extension names only; no env, tokens or config); the user runs it on the work Mac; this doc revised and D24–D28 decided | spec done; probe built and run on this Mac (Pi 1.0.4: all flags and API calls present; `tool_call` block and widget placement left to the e2e test); work Mac pending |
| 1 | `AKitFlows` (deps: AKitFoundation, AKitHarnesses; AKitRender must not import it; edges in `architecture.md`, `project.yml`): flow model, YAML codec, check, run-record reader, `FlowRouting.next`, generated `flow.schema.json` with a drift test, golden vectors; `akit flow list\|show\|check\|schema`; `/akit` skill | built 2026-11-17: `AKitFlows` on Foundation, Harnesses and Yams (no `project.yml` change: the app does not import it yet); 10 golden vectors in `fixtures/flow-vectors/`; the check takes known models, skills and Pi features as input (`akit flow check` knows Pi's skills, reads `~/.akit/local/pi-capabilities.json` when there, and warns that models are not checked until the app's `PiModelPicker` list is used); a failed/blocked route must go to the same or an earlier step; F6's pair is the agents `implementer` and `reviewer`. UI gap: `akit flow check` has no button until the Flows screen's Check (step 4) |
| 2a | Runner core: `flow-core.ts`, `akit-flow.ts`, template in AKitRender, vendored spawn code, atomic `run.json`, `events.jsonl`, lock; `make test-flows` (`tsc --noEmit` against vendored min-version Pi types, `node --test` on the vectors, fake `pi`); Node and TypeScript versions in the `Makefile`; a missing Node fails `make test` with a clear message; `make check-pi`; `pi-adapter.ts`, format number, `minPi`/`testedPi`, feature checks with fallbacks, tolerant event reader (F20) | built 2026-11-17: templates in `AKitCore/Sources/AKitRender/Resources/flows/` (`flow-core.ts`, `pi-adapter.ts`, `flow-record.ts`, `akit-flow.ts`), types `fixtures/pi-types/1.0.4/`, tests `tools/flows/`; the step outcome is read from a last `outcome:` line until `flow_handoff` (2b); `.yaml` flows are read with Pi's `yaml` package, else as JSON |
| 2b | `flow_handoff` tool, rerun once, evidence files, handoff ↔ session link | built 2026-11-17: the child loads `akit-flow-handoff.ts` (`-e`), whose `flow_handoff` (plain JSON Schema params) writes the model's part to the file in `AKIT_FLOW_HANDOFF`; the runner adds run, step, session, `session_file`, next, tokens, deviations, `evidence`; a last `outcome:` line is only a fallback (deviation `handoff-fallback`); none → rerun once (`handoff-missing`), then stop `no-handoff`. The runner runs a step's checks without a shell (rule re-checked, else stop `check-refused`) and writes `evidence/NN-<step>-aN-checks.json` (command, exit, last 40 lines); red turns `done` into `failed:checks` and goes to the next step's prompt. `fixtures/flow-runs/sample/` is written by the TS test and read by a Swift test |
| 2c | Worktree outside the tree, per-step commits with trailers, resume from events, gate edits first, `STOP`, kill the process group | built 2026-11-17 (`flow-git.ts`): the worktree is `~/.akit/local/flows/runs/<run>/worktree` on `akit-flow/<run>` from the project's HEAD (Review's rule, `ReviewPaths.run(id)/worktree`, mirrored in TS; a project without a commit refuses); children and checks run there; each finished step is a commit (empty allowed) with `Flow-Run`/`Flow-Step`/`Flow-Attempt` before its `step-end`; edits between steps are committed with `Flow-Gate: <step>` before the next one. Resume reads events + trailers and rewrites `run.json`: a step with its commit but no `step-end` is not rerun (its handoff gives the outcome); a crashed or aborted step resets to the last step commit after `ctx.ui.confirm` when the worktree has changes (no → nothing reset, resume stops), then runs with attempt + 1. `STOP` halts before the next step (event `halted`); resume removes it. Open: `.pi/akit-flow/` in `info/exclude` and the 14-day worktree cleanup are step 5 |
| 2d | Gates, `akit_flow` with confirm, Accept shows the diff, push/MR behind a gate | built 2026-11-17: a `gate: true` step that ends done shows `git diff` of the run branch against its base in a read-only `ctx.ui.editor`, then `ctx.ui.select` Approve / Send Back; Send Back asks a note (`ctx.ui.editor`), logs a `gate` event and a `sent-back` deviation and routes `failed:sent-back` by the step's routes, with the note in that step's prompt; no answer (or no UI) halts the run and `/flow resume` asks again. The tool `akit_flow` (`flow?`, `task`) asks `ctx.ui.confirm` first and starts nothing without a yes. v1 never pushes or opens an MR (F5) |
| 3a | Guard `akit-flow-guard.ts`: allow-list incl. MCP tools, path rules, no `bash` default, subagent block, per-step `-e` list (F15, F16) | built 2026-11-17: the runner writes `<run>/guard/NN-<step>-a<n>.json` (tools: the step's, else the flow's, else Pi's built-ins `read bash edit write grep find ls`; paths; `bash` default "yes unless paths is set", as Swift's `FlowStep`; worktree; events file) and names it in `AKIT_FLOW_GUARD`. The guard answers `tool_call` with `{ block: true, reason }` for an unlisted tool (built-in, extension or `mcp__`), `subagent*` / `contact_supervisor` / `akit_flow` even when listed (D28; the per-step switch is later), `bash` when not allowed, `edit` / `write` outside the worktree or the step's paths (globs; a plain path covers what is below it); `flow_handoff` always passes; unreadable rules block all but `flow_handoff`. Each block appends a `deviation` event (step, attempt, rule, tool, input summary: a path, a redacted command or only the input's keys; action `blocked`) to `events.jsonl` (F16 lives there, not in a separate `deviations.jsonl`). `-t` now carries `flow_handoff` too. Children load `-ne -e guard -e handoff -e <step's list>` only |
| 3b | Row, shortcuts, overlay (F18); `make test-flows-e2e` (pty on Pi 1.0.4 with the work Mac's keybindings list; before merge, not in `make test`) | built 2026-11-17 (`flow-view.ts` pure, Pi calls in `pi-adapter.ts`): the row `1 plan ✓ m 4k  2 code ● m 1k   ⚠ 1   alt+1…2 view` via `setWidget(…, { placement: "belowEditor" })` (Pi 1.0.4 has the placement; no fallback needed there) shows only this Pi process's run (state, the model's last name part, input + output tokens, deviation count from `events.jsonl`). Shortcuts `alt+1`…`alt+9` open step N: none of them is in Pi 1.0.4's default keys (read from the installed `core/keybindings.js` and pi-tui's `keybindings.js`) and a key the user bound in `keybindings.json` is left out (no shortcut; `/flow show <n>` still works). The overlay (`ctx.ui.custom`, overlay) lists the latest attempt's tool calls (name, short redacted args, ✓/✗) and assistant text from the child's JSON events, never tool output; Esc closes; no copy; widths via pi-tui's `truncateToWidth`. `make test-flows-e2e` (`tools/flows/e2e/flow-e2e.py`): real Pi 1.0.4 in a pty, fake OpenAI-compatible server, temp HOME: a 2-step `/flow` run, `flow_handoff` from both children, the guard blocking `bash` on real Pi, the row below the editor, `alt+1` opens and Esc closes the overlay, Enter and ctrl+d still work, no shortcut conflict. Open: the work Mac's keybindings list (step 0 probe); the overlay shows only steps run in this Pi (a resumed run's earlier steps say "No events in this Pi yet") |
| 4 | Flows screen: cards, pickers, back-arrows, Check, Feature template; `brain/flows`, layers include flows, Apply with backup, diff and hand-edit refusal; work mode; guide `flows.ru.md` with demo shots | 4a built 2026-11-17: `layer.yaml` gets `flows:` (layers.md); Apply renders `.pi/flows/<name>.yaml` and the folder `.pi/extensions/akit-flow/` (`index.ts` re-exports `akit-flow.ts`; Pi 1.0.4 loads only a folder's `index.ts`, so guard and handoff load only in children by `-e`; home: under `~/.pi/agent/`). The templates are embedded in the code (`.embedInCode`, a test keeps them equal to `Resources/flows/`). The content hash is the existing render lock's sha256 (no header line: a JSON flow file has no comments); a file whose hash differs is `keepEdited` with its diff and a warning, never overwritten (test). Flow files are JSON: Pi 1.0.4's extension loader (`dist/core/extensions/loader.js`, `getAliases`) aliases only Pi's own packages and typebox, so `import("yaml")` from an extension can't be relied on; JSON is YAML, so the runner reads it either way. `/.pi/akit-flow` goes into the exclude file in its own block in every git project with flows; work-Mac records stay in the local store (test). `FlowStep.prompt` added (schema regenerated); `FlowTemplates.feature` with prompts from PurpleFlow `core/prompts` (MIT). 4b built 2026-11-17: Setup → Flows (`AKit/FlowsView.swift`; the app imports `AKitFlows`): Project picker, New from Template → Feature, Brain and Rendered for Pi lists, a column of cards (Agent picker, Model by `PiModelPicker`, Skills / Tools / Checks as check boxes, On done / On failed / On blocked pickers, Gate switch, Max loops stepper, drag onto a card or Move Up / Down, Add Step), back-arrows in the left gutter (orange failed, purple blocked), red asterisks, Check (FlowCheck with Pi's models, skills and `pi-capabilities.json`; the implementer/reviewer model line), Save (`BrainFlows.save`, committed), Layers (`BrainFlows.setIncluded`), Apply… (Set Up Project for the project or the home folder); checks are offered from the project's build files (`FlowProjectCommands`); snapshot `--tab feature` / `check`. 4c: guide `docs/guides/flows.ru.md`, shots `flows-empty`, `flows-feature`, `flows-check`; `/akit` skill template. Open: the flow's prompt per step is not editable on the screen (template text only); Rendered for Pi is read only |
| 5 | Runs screen: diagram, deviations, evidence, Stop, `akit flow runs`; step sessions behind the `flow` filter, Lab, Corrections, Tools tab; the token fixture (F17); `akit doctor` exclude check; guide update; `pi-capabilities.json` in `akit doctor`, greyed-out options, Pi version next to `testedPi`, `make check-pi` over a Pi version list (F20) | 5a built 2026-11-17: the Flows screen is simpler: each card is one line (number, step, agent, the model's last name part, skill count, gate, three route chips ✓ ✗ ⏸), the back-arrows stay; a click opens one card at a time; Skills is "N chosen" + Choose… (a searchable popover, chosen first); the step prompt is editable (Prompt, folded); options this Mac's Pi can't do (`pi-capabilities.json`) are greyed out with the reason; snapshot `--tab feature --query <step> [--add]`; guide shot `flows-card`. 5b built 2026-11-17: Activity → Runs (`AKit/RunsView.swift`, `FlowRunSummary` in `FlowRunSteps.swift`): runs of every known project, newest first; the same one-line cards (`FlowColumn`, back-arrows) with each step's state, attempts, time, tokens, cost; a click opens a card: per attempt the deviations with their quote (`rule: tool input` / `rule: detail`), the handoff, the check evidence (command, exit, last lines), and a red "Off the routes" when the next attempt is not what `FlowRouting.next` gives for the outcome and visits; Stop… (confirm) writes `STOP`; no copy or export. The reader knows `halted`, `gate-edits`, `resume` (status halted until a resume or step-start). `akit flow runs [--project] [--json]`. Step sessions: `SessionScanner.flowSessions` tags them `flow` (`SessionSummary.origin`); they are not in `model.sessions` and not in the Insights index (`SessionImporter.discover` reads only Pi's session folder; test), and Sessions lists them behind the Flow Steps toggle. A step's Open in Lab… (New Lab Run → Review a Session), Corrections (`CorrectedSession.of`, counted by code from the file) and Show in Sessions (Tools tab there); tests on the sample run. A7 / Q2 answered: `fixtures/flow-runs/a7` (kept by `AKIT_FLOW_E2E_KEEP=… make test-flows-e2e`, real Pi 1.0.4) shows the parent session file holds only its own tokens (777 + 7), not the children's (1200 + 30 each): no de-duplication needed. Demo home: the sample run in notes-mac; guide shots `runs`, `runs-step`. 5c built 2026-11-17 (F20): `akit doctor` runs the probe's CLI part (`FlowPiProbe`: `pi --version`, `pi --help`; no env, tokens or config) and writes `~/.akit/local/pi-capabilities.json` (the extension API features `tool-call-block` and `ui-confirm` are taken from a version ≥ `minPi`, which `make test-flows-e2e` proves on 1.0.4; the shell probe still checks them on a work Mac); it checks `/.pi/akit-flow` in the exclude of each project with flows and names kept run worktrees. The Flows screen greys out Gate (no `ui-confirm`) and warns on skills (no `skill`) with the reason, and shows "This Mac's Pi X · tested on Pi Y" (`Flow.testedPi`, kept equal to `TESTED_PI` of `flow-core.ts` by a test). Run worktrees under `~/.akit/local/flows/runs/<run>/worktree` unused for 14 days (the run's `events.jsonl` and the worktree folder) are removed by `git worktree remove` when the lock is dead and `git status --porcelain` is empty (the Runs screen runs it); a dirty one is kept and flagged ("Worktree kept", and `akit doctor`); test. Skills: `/akit` has `akit flow runs`, the Runs screen and doctor's part; `/akit-context` one line on `/flow`. Open: the user's copies in `~/.akit/registry/skills/` are not updated; About / Update does not show the Pi version yet (the Flows screen does); the Pi changelog link is not built |
| Later | durable runner (F13); parallel agents in one card (D26); per-day run limit; mouse clicks (F18) | later |

## Open questions

- Q1: Work-Mac probe output (step 0): flags, `belowEditor`, free shortcuts, names of the
  extensions a child needs (the per-step `-e` list); skills enforcement there.
- Answered (Q2, 2026-11-17): a child's tokens are not in the parent session file (`fixtures/flow-runs/a7`, test `childTokensAreNotInTheParentSessionFile`).
- Q3: Does the Commit step squash by default, or keep the per-step commits?
- Answered: does a step get the project's skills? No, only the card's (`-ns` + `--skill`).

## Sources

- https://mer.vin/2026/04/managing-handoffs-in-multi-agent-coding-sessions-fresh-context-without-losing-continuity/
- https://arxiv.org/pdf/2606.02875
- https://www.augmentcode.com/guides/multi-agent-orchestration-architecture-guide
- https://tryinterlock.com/knowledge/what_are_the_multi-agent_orchestration_best_practices_for_2026.php
- https://www.digitalapplied.com/blog/multi-agent-orchestration-5-patterns-that-work
- https://dev.to/_46ea277e677b888e0cd13/cc-workflow-studio-visual-workflow-editor-for-claude-code-ai-agents-41bo
- https://agentsroom.dev/features/teams
- https://github.com/PurpleSchool/purpleflow
- oh-my-claudecode 5.8.0: `dist/hooks/session-end/` (spawn-next, routing, check-evidence, guardrails)
- https://github.com/earendil-works/pi (examples/extensions/subagent, packages/durable)
