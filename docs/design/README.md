# Design map

Status: 2026-10-08, checked against the code. This is the index of `docs/design/`: what
each design is for, what is built, what to build next and in which order. Each design
keeps its own details and its own status note; the order across designs and the open
decisions live only here.

The improvements and the order below are proposals from the 2026-10-03 review. They are
not agreed yet, except where a row says so; a proposal that is accepted moves into its
design doc.

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
| [`architecture.md`](architecture.md) | Which module owns what? | `AKitCore/Package.swift` | all 25 steps; 16 modules | — |
| [`layers.md`](layers.md) | How does a project get exactly the setup it needs? | Brain screen; `akit plan` / `apply` | roadmap 1–3, update rules, work machines, home render, Update Home Folder… and Forget Project… (2026-10-07), JSON merge into `.mcp.json` and `.claude/settings.json` (and Pi's `.pi/mcp.json`, `.pi/settings.json`), so MCP servers in layers; the core layer's AGENTS.md as a marked block in `~/.claude/CLAUDE.md` and the file Pi reads in `~/.pi/agent` (2026-10-08, revised after review 2026-10-09) | JSON merge into the home folder, MCP secrets from Keychain, `/akit-setup` draft, `machines/<name>.yaml` |
| [`session-insights.md`](session-insights.md) | What does the setup cost in every request without being used? | Insights screen; `akit stats`, `akit recommend`, `akit insights` | steps 1–7 and 10 (the Insights screen); step 8 as simplified by I1 (2026-10-08): only described exposures count, and the "descriptions dropped" finding; of step 11 the shared failure signals (2026-10-08) | steps 9, the rest of 11, 12–13; step 8's name-only reasons and over-budget rule |
| [`lab.md`](lab.md) | Was this session efficient? Is setup A better than B? | Sessions → Analysis; Lab screen; `akit lab` | v1, steps 1–4; failure signals by the shared rules, with repeated calls (2026-10-08) | index as a source, Pi replays |
| [`error-analysis.md`](error-analysis.md) | What goes wrong again and again, and did the fix help? | Error Analysis screen; `akit analysis`; Pi ratings on Sessions | slices 1–8; quick ratings after a Pi run, with change, comment and remove; shown after their run and given to Lab reviews (2026-10-07) | manual calibration of cells, merge/split proposals |
| [`layer-evals.md`](layer-evals.md) | Does layer X make the agent's work better? | Brain → layer → Evaluate… and the verdict badge; Error Analysis → Evals → Run Cells… (A brain layer), From Commit…, Layer Sets (with their evals), the comparison's verdict; `akit analysis control evaluate`, `run --layer`, `task new --commit`, `layer-set`, `compare --eval` | slice 1: overlay and layer setup, eval folder, pairing within one eval; slice 2: tasks from commits judged by their hidden tests, layer sets with answers, Add to Layer Set…; slice 5: the "helps (offline)" verdict, `verdicts/<layer>.json`; slice 6: Evaluate… with the cost estimate, the calibration cell, Continue, denied commands, the badge (2026-10-08); then calibration with one cell of each setup, the estimate per setup, and the isolation check of every layer cell (before the agent and of its skill listing) | the pilot (step 4); 3–4 (step 5, if needed); 7 and 9 wait (I2) |
| [`mcp-catalog.md`](mcp-catalog.md) | How to add an MCP server without looking up its config? | MCP Servers → Catalog… | search in two public catalogs, filling the Add Server form (2026-10-04) | marks for configured servers, arguments as values, version checks |
| [`definitions.md`](definitions.md) | What does a shared term mean? | — | tiers, sending policy, keys, shared `FailureSignals` (2026-10-08) | fingerprint, `dirty` / `diff_hash` |

The in-app guides are in `docs/guides/` (`screens.ru.md`, `error-analysis.ru.md`).

## What can be used today

| To do this | Use |
|---|---|
| Give a project its setup | Brain → Set Up Project… |
| Give a project MCP servers or Claude Code settings from a layer | a layer file with `to: .mcp.json` or `to: .claude/settings.json`, then Brain → Set Up Project… (keys are merged; secrets only as `${VAR}`) |
| Add an MCP server from a public catalog | MCP Servers → Catalog… |
| Update the home folder from the core layer | Brain → core → Update Home Folder… (or `akit apply --home`) |
| Forget a project and trash the files AKit wrote there | Brain → the project → Forget Project… |
| See which skills cost context and are never called | Insights (Apply… makes a layer skill manual; the Skills table lists every skill; the line above it says how often Claude Code dropped descriptions) |
| Check that a change reduced the context | Insights → Changes (Add Mark… for a change made by hand) |
| See where one session's tokens went | Sessions → Analysis |
| See which setup one session never used, and how its tool calls ended | Sessions → Overview (Lab review: Overview…) |
| Get a short review of one session | Sessions → Review in Terminal… |
| Compare setups on a past commit | Lab → New Run… (replay) |
| Find failure modes over many sessions | Error Analysis: Bootstrap, then a batch, then Reports |
| Check whether a layer helps | Brain → layer → Evaluate… (tasks come from its layer set: Error Analysis → Evals → Add to Layer Set…); `akit analysis control evaluate LAYER` |

## Order

One step is one feature branch. A step is done when it works in the installed app and its
design doc and this table say so.

| # | Step | Design | Why at this place |
|---|---|---|---|
| 0 | No code: label the bootstrap sessions, run one batch, write one fix draft | `error-analysis.md` | Error analysis is built and has no active mode yet. Its results show which of the later steps are needed |
| 1 | Insights screen. Built 2026-10-03: recommendations with Apply… and Dismiss…. `akit setup` installs capture, and the screen says when it is off and has Install Capture…; the app's Sync publishes summaries (2026-10-06); the skills table, Changes with Add Mark… and Plan… after Apply (2026-10-07). Done, apart from a few small items listed in its status note | `session-insights.md`, step 10 | The feature had no button. Almost no new logic: the pieces move from the command line module into `AKitInsights` |
| 2 | Buttons for "apply the core layer to the home folder" and "forget project". Built 2026-10-07: **Update Home Folder…** and **Forget Project…** on the Brain screen; Insights' Plan… covers the home folder too | `layers.md`, Roadmap | Same rule: every operation needs a button. Small |
| 3 | Count only exposures with a description. Built 2026-10-08 as I1: stats, recommend and the summaries' `described` day field; the "descriptions dropped by the harness" line in `akit stats` and on Insights | `session-insights.md`, step 8 (simplified, see I1) | Fixes what recommendations count; one condition in the queries |
| 4 | Layer evals, minimum: slices 1, 2, 5, 6, then a pilot on 5–8 tasks. I2, D2, D3 and D4 decided 2026-10-08. In progress: slice 1 built 2026-10-08 (Run Cells… → A brain layer, `akit analysis control run --layer`); slice 2 built 2026-10-08 (Evals → From Commit…, Layer Sets, Add to Layer Set…; `task new --commit`, `layer-set`); slice 5 built 2026-10-08 (the layer verdict "helps (offline)" in Evals, `akit analysis control compare --eval`); slice 6 built 2026-10-08 (Brain → layer → Evaluate… with the cost estimate and a calibration cell, Continue, the verdict badge, denied commands for AKit's own repository; `akit analysis control evaluate`); after it, paired calibration (one cell of each setup, the estimate per setup) and the isolation check (no skill or text of the layer in the wrong setup, checked before every layer cell's agent and against its skill listing). Next: the pilot | `layer-evals.md` (see I2) | Proves the mechanics and the cost on the success number before more is built |
| 5 | Layer checks: slices 3 and 4 | `layer-evals.md` | Only if the pilot shows that success alone can't see the gain |
| 6 | JSON merge in layers: `.mcp.json` and `.claude/settings.json`. Built 2026-10-08: the two files merge key by key, per-key ownership in the lock, `${VAR}`-only secrets, masked preview; not into the home folder yet. It is the base for hooks in layers, but arrays are leaves: lists from several layers (hooks, permissions) clash until named arrays get a union merge | `layers.md`, JSON merge; Roadmap 4 | One mechanism unblocks MCP in layers and writing `enabledPlugins` from a recommendation, and is the base for hooks in layers (array merge still to do) |
| 7 | One parser for failure signals. Built 2026-10-08: `FailureSignals` in `AKitSessions` holds the rules of interrupts, rejections, tool errors and repeated calls; Lab and the index scanner both use it (I4, D1) | `definitions.md`; `session-insights.md`, step 11 (see I4) | Two parsers counted the same signals differently |
| 8 | On demand | see Parked | No user yet |

## Proposed improvements

Each one removes work or removes a conflict. None adds a feature.

| # | Proposal | Instead of | Why |
|---|---|---|---|
| I1 | Accepted 2026-10-08, built the same day. Step 8 without name-only reasons: the denominator counts exposures with a description, and one finding shows the share of sessions that lost descriptions | reasons `override` / `empty` / `budget` / `unknown`, the same-day rule, a hook change | The reasons guard against `skillOverrides`, which is not set on this Mac (checked 2026-10-03) and may not work in user settings (step 12 says to check it first) |
| I2 | Accepted 2026-10-08 (`layer-evals.md`, Decisions (2026-10-08)). Layer evals v1 for Claude Code only, without the `parts` field; slices 7 (link to modes) and 9 (production level) wait for the first active modes; the pilot moves before the checks | Pi rules that are partly "blocked until verified", room for later variants, a production level with nothing to feed it | Half of the design depends on active modes, and there are none yet. The example run costs $142; the pilot shows whether the result is worth it |
| I3 | Not accepted 2026-10-08 (D4). One verdict ladder for patch fixes and layers: both get "helps (offline)" | a patch fix that always ends at "no conclusion" before it is applied | Today a control set can't judge a fix draft before the user applies it, which is when the answer is needed |
| I4 | One shared function for the signal rules both parsers have (interrupts, tool errors, repeated calls), with one definition of each. Accepted 2026-10-08 and built (step 7) | an incremental `FailureSignals` reducer | The scanner already recomputes only files that changed; the real problem is two definitions, not speed |
| I5 | Rename `FixDraft.layer` to "kind of fix" in the screen and the docs | three meanings of "layer" (brain layer, kind of fix, fault layer) | Layer evals put a brain layer next to it on the same sheet |
| I6 | Keep this map current: the commit that merges a step updates its row here and the status note of its design | status lines that go stale (five of seven docs had stale statements on 2026-10-03) | The map is only useful while it is true |

## Open decisions

| # | Question | Where |
|---|---|---|
| D1 | Which signal definitions win: "interrupt" by the start of the text or anywhere in it; "repeated calls" as 3 in a row or as any repeat? Decided 2026-10-08: the start of the text; 3 or more in a row, each run counted once | `definitions.md`, Failure signals |
| D2 | Is the session fingerprint needed at all? Two are designed (session, home) and none is built; before/after already compares within one harness version and model. Decided 2026-10-08 for layer evals: no fingerprint in v1; the eval id is in the cell key, cells pair only within one eval and one agent, each cell records its Claude Code version and the result warns on mixed versions. The session fingerprint stays parked | `definitions.md`; `layer-evals.md`, Baseline |
| D3 | Layer evals append the layer's text to a project's own `CLAUDE.md`; Apply only offers it. Should Apply get an "append the layer's section" choice, or does the verdict stay offline only? Decided 2026-10-08: Apply is not changed; the verdict stays offline only | `layer-evals.md`, Decisions (2026-10-08) |
| D4 | Accept I3 (one verdict ladder)? It changes a decided rule of error analysis. Decided 2026-10-08: not now; only layer setups get "helps (offline)", fix verdicts keep the production guard | `error-analysis.md`, Fixes |

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
