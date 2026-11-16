# Flows: agent orchestration for Pi

Status: 2026-11-16, spec revised after the ralplan review (plan in `.omc/plans/flows-plan.md`,
local); D24–D28 decided; step 1 built 2026-11-17 (`AKitFlows`, `akit flow`), the runner and screens not yet. Written from a web search, the Pi docs (context7,
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
      evidence/<step>-checks.json   F19
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
  output. The handoff holds the run id and the child's session id, and that session file
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
  the flow. Red goes by the step's route. At a gate the extension stops and asks in Pi
  (`ctx.ui.confirm` / `ctx.ui.editor`): Approve, or Send Back with a note. Max loops per step
  (default 3), then it stops and asks. Push and MR are always behind a gate. The Accept gate
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
  path rule; only records live in `.pi/akit-flow/`. After 14 days with a dead lock AKit runs
  `git worktree remove` only if the worktree is clean; a dirty one is kept and flagged in
  Runs (like R61), never deleted. Merge or MR stays the user's choice.
- **F9 Resume and commits.** The truth is `events.jsonl` plus the commit trailers; `run.json`
  is a cache, rebuilt on resume. Each finished step is a commit on the run branch with
  trailers `Flow-Run:`, `Flow-Step:`, `Flow-Attempt:`. `/flow resume` continues after the last
  step commit; a crashed step resets to it (attempt + 1). A gate edit is committed before the
  next step. Uncommitted changes at resume: warn and ask, never a silent reset. The Commit
  step either squashes (only on the local branch, never after a push) or keeps the per-step
  commits, per flow setting; its message comes from the handoff `goal`.
- **F10 Templates.** Built-in flows to copy into the brain. v1 has **Feature** only
  (PurpleFlow's order, the diagram above); Quick fix, Bug (failing test first) and Refactor
  (tests green before and after) are later. Step prompts adapted from PurpleFlow's
  `core/prompts`, MIT, with the source noted.
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
  | Check evidence `state/runs/evidence/<sessionId>-checks.json`; a "checks passed" flag is trusted only with it | The runner writes `<run>/evidence/<step>-checks.json` (command, exit code, last lines of output); a check counts as green only with this file, never because the model says so |
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
| Check the exclude | — | — | `akit doctor` |
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
| 2a | Runner core: `flow-core.ts`, `akit-flow.ts`, template in AKitRender, vendored spawn code, atomic `run.json`, `events.jsonl`, lock; `make test-flows` (`tsc --noEmit` against vendored min-version Pi types, `node --test` on the vectors, fake `pi`); Node and TypeScript versions in the `Makefile`; a missing Node fails `make test` with a clear message; `make check-pi`; `pi-adapter.ts`, format number, `minPi`/`testedPi`, feature checks with fallbacks, tolerant event reader (F20) | — |
| 2b | `flow_handoff` tool, rerun once, evidence files, handoff ↔ session link | — |
| 2c | Worktree outside the tree, per-step commits with trailers, resume from events, gate edits first, `STOP`, kill the process group | — |
| 2d | Gates, `akit_flow` with confirm, Accept shows the diff, push/MR behind a gate | — |
| 3a | Guard `akit-flow-guard.ts`: allow-list incl. MCP tools, path rules, no `bash` default, subagent block, per-step `-e` list (F15, F16) | — |
| 3b | Row, shortcuts, overlay (F18); `make test-flows-e2e` (pty on Pi 1.0.4 with the work Mac's keybindings list; before merge, not in `make test`) | — |
| 4 | Flows screen: cards, pickers, back-arrows, Check, Feature template; `brain/flows`, layers include flows, Apply with backup, diff and hand-edit refusal; work mode; guide `flows.ru.md` with demo shots | — |
| 5 | Runs screen: diagram, deviations, evidence, Stop, `akit flow runs`; step sessions behind the `flow` filter, Lab, Corrections, Tools tab; the token fixture (F17); `akit doctor` exclude check; guide update; `pi-capabilities.json` in `akit doctor`, greyed-out options, Pi version next to `testedPi`, `make check-pi` over a Pi version list (F20) | — |
| Later | durable runner (F13); parallel agents in one card (D26); per-day run limit; mouse clicks (F18); Quick fix, Bug and Refactor templates | later |

## Open questions

- Q1: Work-Mac probe output (step 0): flags, `belowEditor`, free shortcuts, names of the
  extensions a child needs (the per-step `-e` list); skills enforcement there.
- Q2: Are a child's tokens also in the parent session file? (fixture in step 5)
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
