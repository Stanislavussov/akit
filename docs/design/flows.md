# Flows: agent orchestration for Pi

Status: 2026-11-16, proposal, not built. Written from a web search, the Pi docs (context7,
`earendil-works/pi`), the Pi 1.5.2 package and PurpleFlow (MIT). Decisions F1–F12 below are
proposals until the user accepts them.

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
| Run the order in code, not by asking the model: an explicit state object drives retries and handoffs | Medium "Best practices…", Augment guide | F1: AKit runs the steps; the model never chooses to skip one |
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

- **F1 AKit runs the flow.** The runner lives in a new module `AKitFlows`. Each step starts
  `pi --mode json -p` with the step's model, tools, skills and prompt, in the run's worktree.
  It needs only the `pi` command, so it works the same with any subagent plugin or none, on
  any 1.x version. Inside a step Pi may still use its own subagents.
- **F2 Simple diagram.** A flow is a column of steps. Each step is a card: agent, model,
  "goes back to" on failure, gate on or off. No free canvas. Parallel steps are one card
  with several agents side by side.
- **F3 A flow is a brain file.** `brain/flows/<name>.yaml` (steps, agents, models, skills,
  gates, max loops). A layer can include flows, so a project gets its flows with Apply
  (layers.md). On a work machine, flows of work projects stay in the local store, as layers do.
- **F4 Handoff.** Each step writes `handoff.md` with fixed headings: Goal, Done, Files,
  Open questions, Next step. The runner checks the headings, saves the file in the run
  folder, and passes it, not the whole output, to the next step.
- **F5 Gates and checks.** A check step runs the project's test and lint commands (the
  review setup commands, review.md). Red goes back to the step the card names. A gate stops
  the run and shows the plan or the diff with Approve / Send Back (with a note) buttons.
  Max loops per flow (default 3), then the run stops and asks.
- **F6 Model rules.** Models come from `PiModelPicker`. A warning when the reviewer's model
  equals the implementer's.
- **F7 Run tracking.** A run's screen shows the same diagram with each step's state
  (waiting, running, done, failed, sent back), time, tokens and cost from Pi's JSON
  events, the handoff of each step, and Stop. Runs are stored in
  `~/.akit/local/flows/runs/<id>/` (events, handoffs, a summary) and shown in Sessions and
  Insights next to normal sessions.
- **F8 Isolation.** Each run works in its own worktree and branch `akit-flow/<run>`, as
  review runs do (review-own-clone). Merge or MR stays the user's choice.
- **F9 Resume.** The run folder is the state: after a restart the run continues from the
  last finished step.
- **F10 Templates.** Built-in flows to copy into the brain: Quick fix; Bug (failing test
  first); Feature (PurpleFlow's order, the diagram above); Refactor (tests green before and
  after). Step prompts adapted from PurpleFlow's `core/prompts`, MIT, with the source noted.
- **F11 Terminal.** `akit flow list|show|run|status|stop` with `--json` and `--yes`; the
  commands go into the `/akit` skill (setting up) and `akit flow status` into
  `/akit-context`.
- **F12 durable later.** The model (flow, step, agent, handoff, run) keeps durable's rules:
  a step's tools are a subset of the flow's, and a step does not start nested flows. A
  durable adapter for Pi p2/p3 is a later step.

## Steps

| # | Step | Built |
|---|---|---|
| 0 | On the work Mac: `pi --version`, plugins, does `pi --mode json -p` with `--model` / `--tools` / `--skill` work | — |
| 1 | `AKitFlows`: flow file, runner for one step, JSON events → state and tokens, tests with a fake `pi` | — |
| 2 | Order, back-arrows, max loops, handoff check, resume | — |
| 3 | Flows screen: column of cards, pickers, templates | — |
| 4 | Run screen: live states, tokens, handoffs, gates, Stop | — |
| 5 | Brain and layers: `brain/flows`, Apply, work machines | — |
| 6 | Runs in Sessions and Insights; `akit flow` commands and skills; guide | — |
| 7 | durable adapter (Pi p2/p3) | later |

## Open questions

- Q1: Does a step get the project's skills, or only the ones the card names?
- Q2: Should a run start from the Notebook or a ticket (Work → Notebook, Digest)?
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
- https://github.com/earendil-works/pi (examples/extensions/subagent, packages/durable)
