# Design map

Status: 2026-10-03, checked against the code. This is the index of `docs/design/`: what
each design is for, what is built, what to build next and in which order. Each design
keeps its own details and its own status note; the order across designs and the open
decisions live only here.

The improvements and the order below are proposals from the 2026-10-03 review. They are
not agreed yet; a proposal that is accepted moves into its design doc.

## The loop

AKit's designs form one loop: set the agents up, watch how they work, find what to
change, change the setup. The sidebar groups follow it (Setup, Activity, Improve).

```
        ┌──────────────────────────  Setup  ───────────────────────────┐
        │  layers.md: brain repo, layers, Apply                        │
        │  renders skills and AGENTS.md into a project or the home     │
        └───────────────┬──────────────────────────────▲───────────────┘
                        │ harness files                │ layer edits
                        ▼                              │ (plan / apply)
              agent sessions (Claude Code, Pi)         │
                        │ logs + capture hook          │
        ┌───────────────▼──────────  Activity  ────────┴───────────────┐
        │  session-insights.md: index of facts (no message text),      │
        │  stats, recommendations, before/after                        │
        └───────────────┬──────────────────────────────▲───────────────┘
                        │ sessions, signals            │ fixes, verdicts
        ┌───────────────▼──────────  Improve  ─────────┴───────────────┐
        │  lab.md: one session's numbers, review, replay tasks, runs   │
        │  error-analysis.md: notes → modes → checks → fixes           │
        │  layer-evals.md: does a layer help? (control cells + layer)  │
        └──────────────────────────────────────────────────────────────┘

  definitions.md: terms shared by the three lower designs
  architecture.md: the module of each area and the allowed dependencies
```

## Documents

| Document | Question it answers | Where it shows | Built | Not built |
|---|---|---|---|---|
| [`architecture.md`](architecture.md) | Which module owns what? | `AKitCore/Package.swift` | all 25 steps; 15 modules | — |
| [`layers.md`](layers.md) | How does a project get exactly the setup it needs? | Brain screen; `akit plan` / `apply` | roadmap 1–3, update rules, work machines, home render | MCP in layers, JSON merge, `/akit-setup` draft, `machines/<name>.yaml` |
| [`session-insights.md`](session-insights.md) | What does the setup cost in every request without being used? | commands only: `akit stats`, `akit recommend`, `akit insights` | steps 1–7 | steps 8–13; the Insights screen |
| [`lab.md`](lab.md) | Was this session efficient? Is setup A better than B? | Sessions → Analysis; Lab screen; `akit lab` | v1, steps 1–4 | index as a source, Pi replays |
| [`error-analysis.md`](error-analysis.md) | What goes wrong again and again, and did the fix help? | Error Analysis screen; `akit analysis` | slices 1–8 | manual calibration of cells, merge/split proposals |
| [`layer-evals.md`](layer-evals.md) | Does layer X make the agent's work better? | — | nothing (design only) | slices 1–9 |
| [`definitions.md`](definitions.md) | What does a shared term mean? | — | tiers, sending policy, keys | fingerprint, shared `FailureSignals`, `dirty` / `diff_hash` |

The in-app guides are in `docs/guides/` (`screens.ru.md`, `error-analysis.ru.md`).

## What can be used today

| To do this | Use |
|---|---|
| Give a project its setup | Brain → Set Up Project… |
| Update the home folder from the core layer | `akit apply --home` (no button yet) |
| See which skills cost context and are never called | `akit stats`, `akit recommend` (no screen yet) |
| Check that a change reduced the context | `akit stats changes`, `akit stats mark "<note>"` |
| See where one session's tokens went | Sessions → Analysis |
| Get a short review of one session | Sessions → Review in Terminal… |
| Compare setups on a past commit | Lab → New Run… (replay) |
| Find failure modes over many sessions | Error Analysis: Bootstrap, then a batch, then Reports |

## Order

One step is one feature branch. A step is done when it works in the installed app and its
design doc and this table say so.

| # | Step | Design | Why at this place |
|---|---|---|---|
| 0 | No code: label the bootstrap sessions, run one batch, write one fix draft | `error-analysis.md` | Error analysis is built and has no active mode yet. Its results show which of the later steps are needed |
| 1 | Insights screen; the app's Sync publishes summaries | `session-insights.md`, step 10 | The whole feature has no button. Almost no new logic: three pieces move from the command line module into `AKitInsights` |
| 2 | Buttons for "apply the core layer to the home folder" and "forget project" | `layers.md`, Roadmap | Same rule: every operation needs a button. Small |
| 3 | Count only exposures with a description | `session-insights.md`, step 8 (simplified, see I1) | Fixes what recommendations count; one condition in the queries |
| 4 | Layer evals, minimum: slices 1, 2, 5, 6, then a pilot on 5–8 tasks | `layer-evals.md` (see I2) | Proves the mechanics and the cost on the success number before more is built |
| 5 | Layer checks: slices 3 and 4 | `layer-evals.md` | Only if the pilot shows that success alone can't see the gain |
| 6 | JSON merge in layers: `.mcp.json` and `.claude/settings.json` | `layers.md`, Roadmap 4 | One mechanism unblocks three plans: MCP in layers, hooks in layers, and writing `enabledPlugins` from a recommendation |
| 7 | One parser for failure signals | `definitions.md`; `session-insights.md`, step 11 (see I4) | Two parsers count the same signals differently today |
| 8 | On demand | see Parked | No user yet |

## Proposed improvements

Each one removes work or removes a conflict. None adds a feature.

| # | Proposal | Instead of | Why |
|---|---|---|---|
| I1 | Step 8 without name-only reasons: the denominator counts exposures with a description, and one finding shows the share of sessions that lost descriptions | reasons `override` / `empty` / `budget` / `unknown`, the same-day rule, a hook change | The reasons guard against `skillOverrides`, which is not set on this Mac (checked 2026-10-03) and may not work in user settings (step 12 says to check it first) |
| I2 | Layer evals v1 for Claude Code only, without the `parts` field; slices 7 (link to modes) and 9 (production level) wait for the first active modes; the pilot moves before the checks | Pi rules that are partly "blocked until verified", room for later variants, a production level with nothing to feed it | Half of the design depends on active modes, and there are none yet. The example run costs $142; the pilot shows whether the result is worth it |
| I3 | One verdict ladder for patch fixes and layers: both get "helps (offline)" | a patch fix that always ends at "no conclusion" before it is applied | Today a control set can't judge a fix draft before the user applies it, which is when the answer is needed |
| I4 | One shared function for the signal rules both parsers have (interrupts, tool errors, repeated calls), with one definition of each | an incremental `FailureSignals` reducer | The scanner already recomputes only files that changed; the real problem is two definitions, not speed |
| I5 | Rename `FixDraft.layer` to "kind of fix" in the screen and the docs | three meanings of "layer" (brain layer, kind of fix, fault layer) | Layer evals put a brain layer next to it on the same sheet |
| I6 | Keep this map current: the commit that merges a step updates its row here and the status note of its design | status lines that go stale (five of seven docs had stale statements on 2026-10-03) | The map is only useful while it is true |

## Open decisions

| # | Question | Where |
|---|---|---|
| D1 | Which signal definitions win: "interrupt" by the start of the text or anywhere in it; "repeated calls" as 3 in a row or as any repeat? | `definitions.md`, Failure signals |
| D2 | Is the session fingerprint needed at all? Two are designed (session, home) and none is built; before/after already compares within one harness version and model | `definitions.md`; `layer-evals.md`, Baseline |
| D3 | Layer evals append the layer's text to a project's own `CLAUDE.md`; Apply only offers it. Should Apply get an "append the layer's section" choice, or does the verdict stay offline only? | `layer-evals.md`, Open questions |
| D4 | Accept I3 (one verdict ladder)? It changes a decided rule of error analysis | `error-analysis.md`, Fixes |

## Parked

Designed, with no user today. Each can come back when something needs it.

- `session-insights.md`: step 9 (`claude plugin details` as a token source), step 12
  (`name-only` advice, export to skill-creator), step 13 (check against `skillUsage`),
  OpenCode and Codex.
- `definitions.md`: the harness fingerprint and its settings components, `dirty` and
  `diff_hash`.
- `layers.md`: `machines/<name>.yaml` (no code reads it; the machine role is in
  `~/.akit/machine.json`), the `/akit-setup` draft (the `/akit` skill already lets an agent
  set up a project), subagents in layers.
- `layer-evals.md`: everything under its "Later", slices 7 and 9.
- `error-analysis.md`: manual calibration of control cells, merge and split proposals.
- `architecture.md`: the rulesync renderer behind the `AKitRender` seam.
