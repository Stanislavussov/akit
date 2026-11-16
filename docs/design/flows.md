# Flows: agent orchestration for Pi

Status: 2026-11-16, proposal, not built. Written from a web search, the Pi docs (context7,
`earendil-works/pi`), the Pi 1.5.2 package and PurpleFlow (MIT). Decisions F1–F19 below are
proposals until the user accepts them; D24–D28 (2026-11-16) are decided, and the reviewed
plan with the spec audit (A1–A22) is `.omc/plans/flows-plan.md` (local).

## Goal

One screen where the user sets up and watches a multi-agent run for Pi: the order of the
steps, each step's agent, model, skills and tools, what passes from one step to the next
(the handoff), the gates where the user decides, and while it runs: state, work and tokens.
The diagram is as simple as PurpleFlow's; setting a step up is a few pickers, not code.

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
| The writer never accepts its own work; the reviewer runs on another model | PurpleFlow, Anthropic guidance | F6: a flow with the same model on write and review gets a warning |
| Fresh context per step, only the handoff passes on | Anthropic long-running agents guidance | each step is a new Pi process |
| Trace every step: time, tokens, cost | Interlock | F7: tokens from Pi's JSON events, per step |
| Visual editors (CC Workflow Studio, React Flow canvas) give free graphs; users get lost in them | CC Workflow Studio, AgentsRoom | F2: a fixed column of steps with back-arrows, no free canvas |

## How Pi runs a step (facts, Pi 1.x)

- Pi's own subagent example (`examples/extensions/subagent`) starts each child as
  `pi --mode json -p --no-session [--model M] [--tools a,b]`, parses JSON events for usage
  (input, output, cache, cost, turns) and chains with `{previous}`. The child writes no
  session file, so the Sessions index never sees it.
- A chain started from a prompt template is run by the model: it may skip or reorder steps.
- Versions and plugins differ between Macs (work Mac: CLI 1.x with an extension; this Mac:
  1.0.4 with `pi-subagents`). Pi p2/p3 has built-in subagents on `durable`, not installed on
  either Mac.

## Decisions (proposals)

Split of roles (the user's rule, 2026-11-16): **AKit only models the behavior; Pi runs it.**
AKit edits, checks and renders the flow files and shows recorded runs. It starts nothing.

```
 AKit (model)                         Pi (runs)
 Flows screen ──▶ brain/flows/*.yaml   /flow feature "add export"
       │ Apply                               │
       ▼                                     ▼
 .pi/flows/*.yaml, ~/.pi/agent/flows/ ──▶ akit-flow.ts (Pi extension, rendered by Apply)
 akit-flow.ts                                │ each step: pi --mode json -p --model … --tools …
                                             ▼
 Runs screen ◀──── reads ───── run record <project>/.pi/akit-flow/runs/<run-id>/
```

- **F1 Pi runs the flow, in code.** The runner is the Pi extension `akit-flow.ts`. It
  reads the flow file and starts each step as `pi --mode json -p` with the step's model,
  tools, skills and prompt, in the run's worktree, as Pi's own subagent example does. The
  order, back-arrows and loop limit are kept by the extension's code, not by the model. It
  needs only Pi's extension API, so it works with any subagent plugin or none, on any 1.x
  version. A step may not start its own subagents (D28): another agent is another step. What the code guarantees is in F15.
- **F2 Simple diagram.** A flow is a column of steps. Each step is a card: agent, model,
  skills, "goes back to" on failure, gate on or off. No free canvas. Parallel steps are one
  card with several agents side by side.
- **F3 A flow is a brain file.** `brain/flows/<name>.yaml` (steps, agents, models, skills,
  gates, max loops). A layer can include flows; Apply renders them to the project's
  `.pi/flows/` or the home `~/.pi/agent/flows/`. On a work machine, flows of work projects
  stay in the local store, as layers do. AKit checks a flow before Apply: agents, models and
  skills exist, every back-arrow points to an earlier step.
- **F4 Handoff as JSON, OMC style, in `.pi`.** Like OMC's `.omc/handoffs/<sessionId>-<stage>.json`
  plus its chain ledger, but per run so several runs can go at once:

  ```
  <project>/.pi/akit-flow/
    runs/<run-id>/                  run-id = 20261116-1432-a3f9 (date, time, 4 hex)
      run.json                      ledger: flow, task, branch, state, current step, visits per step
      handoffs/02-implement-a1-<pi-session-id>.json   step number, step id, attempt, session
      sessions/                     the steps' Pi session files (F17)
      events.jsonl                  states, times, tokens
      deviations.jsonl              F16
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
  ends without `flow_handoff` reruns once, then the run stops (a deviation). `outcome` is one
  of `done`, `failed`, `blocked`; the runner, not the model, turns it into the next step.
  The next step gets the previous handoff as its input, not the whole output.
  `.pi/akit-flow/` is local: AKit adds it to `info/exclude` (layers.md, local-only files).
  In a worktree the run lives in the main checkout's `.pi/akit-flow/`, so it outlives the
  worktree (OMC's lesson: state inside a worktree dies with it).
- **F5 Gates and checks.** A check step runs the project's test and lint commands, set in
  the flow. Red goes back to the step the card names. At a gate the extension stops and asks
  in Pi (`ctx.ui.confirm` / `ctx.ui.editor`): Approve, or Send Back with a note. Max loops
  per flow (default 3), then it stops and asks.
- **F6 Model rules.** Models come from `PiModelPicker`. A warning in AKit when the
  reviewer's model equals the implementer's.
- **F7 Run record and tracking.** The extension writes each run to
  `<project>/.pi/akit-flow/runs/<run-id>/` (F4): `events.jsonl` (step, state, time, tokens and cost from
  Pi's JSON events), the handoffs, a summary. In Pi a widget above the editor
  (`ctx.ui.setWidget`) shows the column of steps with state, model and tokens. AKit's Runs
  screen reads the same record and draws the same diagram (read-only), and adds runs to
  Sessions and Insights. Child steps keep their session files (F17).
- **F8 Isolation.** Each run works in its own worktree and branch `akit-flow/<run>`.
  Merge or MR stays the user's choice.
- **F9 Resume.** The run record is the state: `/flow resume` continues from the last
  finished step.
- **F10 Templates.** Built-in flows to copy into the brain: Quick fix; Bug (failing test
  first); Feature (PurpleFlow's order, the diagram above); Refactor (tests green before and
  after). Step prompts adapted from PurpleFlow's `core/prompts`, MIT, with the source noted.
- **F11 Start from Pi.** `/flow [name] <task>`; without a name, the project's default flow.
  A tool `akit_flow` lets the model start one when the user asks in words ("do it by the
  Feature flow"). Settings come from `.pi/flows/` first, then `~/.pi/agent/flows/`: change a
  flow in AKit, Apply, and the next `/flow` uses it. On start the extension checks
  `pi --version` and says what is missing on an old Pi.
- **F12 Terminal for modeling.** `akit flow list|show|check` with `--json` (no `run`: Pi
  runs); they go into the `/akit` skill. `/flow` is described in the extension.
- **F13 durable later.** The model (flow, step, agent, handoff, run) keeps durable's rules:
  a step's tools are a subset of the flow's, and a step does not start nested flows. A
  durable runner for Pi p2/p3 is a later step.

- **F14 Setup by clicks only.** Every setting on the Flows screen is a picker, a toggle or a
  drag: add a step from a list of agents, drag to reorder, model from `PiModelPicker`,
  skills and tools as check boxes, "goes back to" as a picker of earlier steps, gate as a
  switch, checks from the project's known commands. The YAML is never edited by hand; AKit
  writes it.
- **F15 What is guaranteed, and how.** The user's rule: Pi must follow the flow, and the
  order is always kept. A model can't be forced to think a certain way, so every rule is
  either enforced by code or checked by code after the step; none is left to the prompt.

  | Rule | How | Guarantee |
  |---|---|---|
  | Order of steps, back-arrows, loop limit | the extension's runner; the model never picks the next step | enforced |
  | Model of a step | `--model` on the child | enforced |
  | Tools of a step | `--tools` on the child, plus the guard (below) blocks any other call | enforced |
  | Skills of a step | only the named skills are given (`--skill` / no discovery), Q1 | enforced |
  | Files a step may change (e.g. Review: none; Bug step 1: tests only) | the guard blocks `edit` / `write` / `bash` writes outside the step's paths | enforced |
  | Checks (tests, lint) | run by the extension, not by the model | enforced |
  | Handoff has its headings | checked after the step; missing → the step reruns once, then the run stops | checked |
  | Step rules such as "test fails before the fix" | a check the extension runs at the step's end (run tests, compare) | checked |
  | Quality of the work | review step and gates | the user decides |

  The guard is a second small extension, `akit-flow-guard.ts`, that the runner loads into
  each child with `-e`. It reads the step's rules and answers Pi's `tool_call` event with
  `{ block: true, reason }`. The model sees the reason and can go on within the rules.
- **F16 Deviation log.** Every blocked call, failed check, rerun handoff and gate Send Back
  is a line in the run's `deviations.jsonl`: step, rule, what the model tried, what
  happened (blocked, rerun, stopped). The widget in Pi shows a count; AKit's Runs screen
  lists them per step, with the quote, next to the error modes of error-analysis.md.
- **F17 Every step can be evaluated.** Children run with `--session-dir <run>/sessions`
  instead of `--no-session`, so each step is a normal Pi session file. AKit's Sessions
  index reads them tagged with flow, run and step; Lab (review, numbers), error analysis,
  Corrections and tool costs work on a step as on any session. At least: open a step and see
  what it read, ran and changed, with its tokens.
- **F18 Buttons in Pi.** Like Claude Code's subagent row, without changing Pi's own
  functions:
  - a widget **below the editor** (Pi's widget placement) shows one row of steps:
    `1 Plan ✓  2 Code ● 12k  3 Checks ○  4 Review ○   ⚠ 1`;
  - shortcuts open a step: an overlay (`ctx.ui.custom`) with the child's live transcript
    (tool calls, output, handoff); Esc closes it; `/flow show <n>` does the same;
  - Pi's normal mode leaves the mouse to the terminal, so the "buttons" are shortcuts shown
    in the row; mouse clicks work only in Pi's fullscreen mode;
  - shortcuts are picked so they don't clash with Pi's built-in keybindings (checked in
    step 0 against `keybindings.md` of the installed version); a clash means no shortcut,
    the `/flow show` command still works.

- **F19 Taken from OMC's chain (oh-my-claudecode 5.8.0, `hooks/session-end`).** OMC runs a
  chain of headless sessions with code-side routing; Flows takes the same parts:

  | OMC | Flows |
  |---|---|
  | Route table `outcome:reason` → next stage, `outcome:*` as fallback (`decideNextStage`) | Each card's "on done / failed / blocked go to" pickers become this table in the flow file; the runner looks the next step up, the model never names it |
  | A malformed table halts silently as `no-route` | AKit's check refuses a flow with a missing or bad route before Apply; the runner stops loudly on no route (a deviation) |
  | `visits` per stage in the chain ledger, capped | `run.json` counts visits per step; the card's max loops caps it |
  | Ledger written before the next link starts | `run.json` is written before each step starts, so a crash resumes at the right step (F9) |
  | Check evidence `state/runs/evidence/<sessionId>-checks.json`; a "checks passed" flag is trusted only with it | The runner writes `<run>/evidence/<step>-checks.json` (command, exit code, last lines of output); a check counts as green only with this file, never because the model says so |
  | Human gates kept for irreversible or outside-visible acts, precedent and value calls; review sign-off only with the diff attached, not the reviewed side's summary | Gates are fixed before merge, push, MR and any outside call; the Accept gate always shows the diff, the handoff is only next to it |
  | Verify commands are a trust boundary: plain pattern, ≤ 10 commands, ≤ 120 chars | Check commands in a flow file pass the same rules in AKit's check and again in the runner |
  | Stop marker and a daily chain limit (`guardrails`) | A `STOP` file in the run folder halts the run at the next step (AKit's Stop button writes it); a per-day run limit in the flow settings |
  | Headless links run with a fixed tool profile and chosen setting sources | Each step runs with its tool list and the guard; whether the user's other Pi extensions load is a switch on the flow (default: only the guard and `akit-record`) |

## Steps

| # | Step | Built |
|---|---|---|
| 0 | On the work Mac: `pi --version`, does `pi --mode json -p` take `--model` / `--tools` / `--skill` / `--session-dir` / `-e`, `tool_call` block, widget below the editor, free shortcuts | — |
| 1 | `AKitFlows`: flow file format, check, run-record reader; tests on a fake home | — |
| 2 | Pi extension `akit-flow.ts`: one step, events → run record; tested with a fake `pi` (pty recipe) | — |
| 3 | Route table, visits, ledger first, evidence files, STOP, handoff check, gates, resume (F19) | — |
| 3a | Guard `akit-flow-guard.ts` (F15), deviation log (F16), step sessions (F17) | — |
| 3b | Row below the editor, shortcuts, step overlay (F18) | — |
| 4 | Flows screen: column of cards, pickers, templates, check | — |
| 5 | Brain and layers: `brain/flows`, Apply renders flows and the extension, work machines | — |
| 6 | Runs screen with deviations; step sessions in Sessions, Lab, error analysis; `akit flow` and the `/akit` skill; guide | — |
| 7 | durable runner (Pi p2/p3) | later |

## Open questions

- Q1: Does a step get the project's skills, or only the ones the card names?
- Q3: Step 0 facts on the work Mac.

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
