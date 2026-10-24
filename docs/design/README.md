# Design map

Status: 2026-10-11, checked against the code; `model-guidance.md` added the same day as a
proposal; `review.md` (AKit Review) added 2026-10-15 and placed before wave 1; the order after step 9 is in "Next (2026-10-11)". This is the index of `docs/design/`: what
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
        │  model-guidance.md: a new model's guide → layer edits        │
        └──────────────────────────────────────────────────────────────┘

  definitions.md: terms shared by the three lower designs
  architecture.md: the module of each area and the allowed dependencies
```

## Documents

| Document | Question it answers | Where it shows | Built | Not built |
|---|---|---|---|---|
| [`architecture.md`](architecture.md) | Which module owns what? | `AKitCore/Package.swift` | all 25 steps; 19 modules | — |
| [`layers.md`](layers.md) | How does a project get exactly the setup it needs? | Brain screen; `akit plan` / `apply` | roadmap 1–3, update rules, work machines, home render, Update Home Folder… and Forget Project… (2026-10-07), JSON merge into `.mcp.json` and `.claude/settings.json` (and Pi's `.pi/mcp.json`, `.pi/settings.json`), so MCP servers in layers; the core layer's AGENTS.md as a marked block in `~/.claude/CLAUDE.md` and the file Pi reads in `~/.pi/agent` (2026-10-08, revised after review 2026-10-09); local-only files (an `info/exclude` block) and links in git worktrees in the core and `akit worktrees` (2026-10-09), and in the app: Project files in Set Up Project, Worktrees and Sync Worktrees on the project's page, sync on refresh and a watch on new worktrees (2026-10-10); Move to Project: Skills and Brain → Move to Project…, `akit move skill` (`SkillMove`, 2026-10-11), and back: Move to Global…, `akit move skill --to-global` (2026-10-11); Remove Everywhere: every place a harness loads a skill from, Skills and Insights → Remove Everywhere…, Disable Plugin…, `akit remove skill --everywhere` (`SkillRemoval`, 2026-10-11); Resolve Duplicate: one name in places a harness loads together, Skills → Duplicates and Resolve Duplicate… (`SkillDuplicates`, 2026-10-14) | JSON merge into the home folder, MCP secrets from Keychain, `/akit-setup` draft, `machines/<name>.yaml` |
| [`session-insights.md`](session-insights.md) | What does the setup cost in every request without being used? | Insights screen; `akit stats`, `akit recommend`, `akit insights` | steps 1–7 and 10 (the Insights screen); step 8 as simplified by I1 (2026-10-08): only described exposures count, and the "descriptions dropped" finding; of step 11 the shared failure signals (2026-10-08); unused skills, MCP servers and tools over a chosen window, with the tools each session had available in the index (`akit stats tools`, Insights → Skills / MCP Servers / Tools, 2026-10-10); one skill's calls per project (`akit stats skill`, 2026-10-11); "Only used in <project>" recommendations with Move to Project… (2026-10-11); the skill listing against Claude Code's budget, with Raise Budget… (`akit stats listing`, Insights → Skill Listing, 2026-10-11); description length warnings on the Skills screen and in `akit skills state` (2026-10-11) | steps 9, the rest of 11, 12–13; step 8's name-only reasons and over-budget rule |
| [`lab.md`](lab.md) | Was this session efficient? Is setup A better than B? | Sessions → Analysis; Lab screen; `akit lab` | v1, steps 1–4; failure signals by the shared rules, with repeated calls (2026-10-08) | index as a source, Pi replays |
| [`error-analysis.md`](error-analysis.md) | What goes wrong again and again, and did the fix help? | Error Analysis screen; `akit analysis`; Pi ratings on Sessions | slices 1–8; quick ratings after a Pi run, with change, comment and remove; shown after their run and given to Lab reviews (2026-10-07) | manual calibration of cells, merge/split proposals |
| [`layer-evals.md`](layer-evals.md) | Does layer X make the agent's work better? | Brain → layer → Evaluate… and the verdict badge; Error Analysis → Evals → Run Cells… (A brain layer), From Commit…, Layer Sets (with their evals), the comparison's verdict; `akit analysis control evaluate`, `run --layer`, `task new --commit`, `layer-set`, `compare --eval` | slice 1: overlay and layer setup, eval folder, pairing within one eval; slice 2: tasks from commits judged by their hidden tests, layer sets with answers, Add to Layer Set…; slice 5: the "helps (offline)" verdict, `verdicts/<layer>.json`; slice 6: Evaluate… with the cost estimate, the calibration cell, Continue, denied commands, the badge (2026-10-08); then calibration with one cell of each setup, the estimate per setup, and the isolation check of every layer cell (before the agent and of its skill listing) | the pilot (step 4); 3–4 (step 5, if needed); 7 and 9 wait (I2) |
| [`model-guidance.md`](model-guidance.md) | What should change in the setup for a new model, and how does one model get its own text? | (proposal) Lab → New Run… → Model Guidance; Insights finding "New model"; `model_notes:` in a layer; `akit lab guidance` | — (proposal 2026-10-11, user review open) | everything: step 0 (facts to verify), model notes with delivery by the Claude Code hook and the Pi extension, the guidance review, the eval rule |
| [`instructions.md`](instructions.md) | Which instruction files (AGENTS.md, CLAUDE.md) reach the agent in a project, and how to move or dedupe their sections like skills? | On This Mac → Instructions: Duplicates (N), Remove This Copy…, Import to Brain…, Move to Global… / Move to Project…, Edit…, Rewrite with Skill…; `akit instructions` | step 0: the loading rules of Claude Code, Pi, Codex and OpenCode, checked 2026-10-14; step 1: the Instructions screen and `akit instructions` (`AKitInstructions`, 2026-10-14); step 2: duplicate sections, Duplicates (N), twice / differs lines (2026-10-14); step 3: Remove This Copy… for a repeated section (`InstructionEdit`, 2026-10-14); step 4: Import to Brain… (`InstructionImport`, 2026-10-14); step 5: Move to Global… / Move to Project… (`InstructionMove`, 2026-10-14); Edit… and Rewrite with Skill… (2026-10-14) | a brain-rendered project as a Move to Project target; files in subfolders that load later |
| [`mcp-catalog.md`](mcp-catalog.md) | How to add an MCP server without looking up its config? | MCP Servers → Catalog… | search in two public catalogs, filling the Add Server form (2026-10-04) | marks for configured servers, arguments as values, version checks |
| [`mcp-check.md`](mcp-check.md) | Does an MCP server connect, and what to do when it doesn't? | MCP Servers → Connection: Check Connection, Check All, Sign In…, Approve…, Set Variable…; `akit mcp check`, `akit mcp approve`; Copy to Pi… / Copy to Claude Code…; `akit mcp check` | step 1: the check through `claude mcp get` / `list` and `pi mcp list --json` with the login shell's environment, missing variables, `akit mcp check` (2026-10-24); step 2: the Connection box with Check Connection, Check All, the check after Apply with Edit Again and Undo… (2026-10-24); step 3: Sign In…, Set Variable…, Approve… (the one key of `.claude/settings.local.json`), `akit mcp approve` (2026-10-24); step 4: Copy to Pi… / Copy to Claude Code…; step 5: a Pi server's tools and their exposure (2026-10-24) | single-tool switches; Insights use next to each tool; Codex and OpenCode |
| [`harness-support.md`](harness-support.md) | What does AKit do for Claude Code and for Pi? | Skills and MCP Servers (switches); `akit skills state`, `akit skills set`, `akit mcp` | the table per feature, with each gap marked as a decision or open (2026-10-09); skill switches per harness, MCP servers off everywhere or in a project, with the verified setting formats (2026-10-10); moving a global skill into projects, Pi's only per-project control (2026-10-11); Model invocation, Auto / Manual in the skill itself or its layer (2026-10-12); all global skills Manual or Auto at once (2026-10-14) | Pi: replays, layer evals, hidden-test tasks, Analysis tab (decisions); `pi-mcp-adapter` fields beyond env and headers (open) |
| [`machine-setup.md`](machine-setup.md) | What does AKit see on this Mac, and how does a new Mac get set up? | `akit doctor`; `akit doctor pi`; Help → Copy Diagnostics; Help → Report a Bug…; Set Up This Mac (proposal) | `akit doctor` (2026-10-09), Help → Copy Diagnostics (2026-10-10), Help → Report a Bug… / Suggest a Feature… (2026-10-11), the Update button for a newer build in the source folder (2026-10-17), `akit doctor pi` and Overview → Check Pi… with suggestions from recent Pi sessions, `akit instructions remove`, `akit pi packages`, `akit mcp login`, `akit mcp set --exposure` (2026-10-24) | onboarding (proposal, user review open) |
| [`ask-akit.md`](ask-akit.md) | What does this label, number or badge mean, and what do I do about it? | Toolbar → Ask AKit, Help → Ask AKit (⌥⌘/), right-click → Ask AKit About This | the core (`AKitHelp`: guide sections, prompt, answer, sources), the side panel with agent choice, Stop and New Chat, context menus (2026-10-14); the review round (2026-10-15): Stop ends the harness process, no session text (ids only, redaction backstop), checked links, first-send confirmation and What Was Sent; the AKit Terms glossary guide; the second review (2026-10-15): neutral names for emergent modes and session tasks, whole-word redaction, `systemCharacters` in the send log, a cancellable account check, consent per destination with Settings → Ask before Ask AKit sends | saved chats; About This on the batch difference grid and a few pane lists |
| [`review.md`](review.md) | How does an agent review a GitLab merge request without writing anything the user didn't approve? | (being built) Review screen, Roles and Scenarios; `akit review`, `akit review post`; guide `review.ru.md` | step 1 (2026-10-15): `AKitReview`, profiles and the three levels, Gather into a context pack, `akit review` up to `run.json`; step 2: the passes in one Pi session, `akit-review.ts`, the cap and the send log; step 3: requests, the Review screen, Send Drafts…, `akit review post`; step 4: reruns, Discuss in Pi…; step 5: Roles, Scenarios, Quality, the guide; a security review round; the MCP change (2026-10-15): no tokens or REST in AKit, Pi's MCP servers through a guarded fetch pass and send pass, `akit review check`; local review of a git workspace (2026-10-16): New Review… → Local Workspace, `akit review local`; context for a run (2026-10-22, issue #1): notes, links read through MCP into `context/links.md`, read-only context servers (`mcp: extra_servers`, New Review… → Extra servers, Review Settings… → Context server), `--note`, `--link`, `--extra-server`; the audit round (2026-10-22): no tool name in posted text (only 🤖), the fingerprint without the title, AC rows outside the role limit, `bug-hunter` in Feature; Pi steps and flags (2026-10-22): the user's subagents, prompt templates and skills as passes after the roles, extra Pi flags, `akit review pi`, New Review… → Pi steps with suggestions; checks without a model (2026-10-22): the quote in the file, no repeat of a person's open thread, inline only on changed lines, a secret scan, `max_changed_lines`; practices of Anthropic, OpenAI and Uber (2026-10-23, R20–R34): built-in rules and a TS/React rule set, every Pi MCP server in the passes under a stricter policy, findings from before the MR kept out of GitLab, Anthropic's confidence scale, a required verifier model, 5 inline (3 medium), a question before the passes (draft, red pipeline, same commit), history with blame and earlier threads, the `history` role, a Security scenario, self-review limits, a private risk map, reruns on what a push changed, outcomes of the threads, an eval set; R35 (2026-10-23): comments in Czech, `posting: language` default `cs`, Send refuses text that isn't Czech; R36: live log under the status bar, Log… and `akit review log`, model lists, required fields marked, an empty fetch that says why; R37: limits only alert, 600 credits / 6000 lines; R38: `tool_search` for deferred MCP servers; R39: the work item only from the branch (`COL-123`), a code-only review without one | step 0 (facts on the work Mac), running the eval set through Lab |
| [`translate.md`](translate.md) | How do I read a review, notes or an answer in another language? | Translate menu on Lab reviews, session notes, Review runs and Ask AKit answers; Settings → Translation model; `akit translate` | GitHub issue #2 (2026-10-22): 17 languages and Show Original, one call per output through the sending policy, a cache next to the output, the translation model setting | mode texts, reports and fix drafts |
| [`knowledge.md`](knowledge.md) | How does the agent learn the system around a repository: which service talks to which, and where the text about it lies? | (designed) Knowledge screen: spaces, Excalidraw maps, notes, Inbox, Lint; `akit kb` | — (designed 2026-10-24 by grilling, K1–K20) | everything: steps 1–7 |
| [`definitions.md`](definitions.md) | What does a shared term mean? | — | tiers, sending policy, keys, shared `FailureSignals` (2026-10-08) | fingerprint, `dirty` / `diff_hash` |

The in-app guides are in `docs/guides/` (`screens.ru.md`, `error-analysis.ru.md`). Since
2026-10-11 both are full guides: every screen and every Error Analysis tab from simple tasks
to hard ones, with examples and screenshots (`docs/guides/images`, taken from a made-up home by
`make guide-screenshots`); the guide window searches both guides and the screens at once.

## What can be used today

| To do this | Use |
|---|---|
| Give a project its setup | Brain → Set Up Project… |
| Give a project MCP servers or Claude Code settings from a layer | a layer file with `to: .mcp.json` or `to: .claude/settings.json`, then Brain → Set Up Project… (keys are merged; secrets only as `${VAR}`) |
| Add an MCP server from a public catalog | MCP Servers → Catalog… |
| Turn an MCP server off without deleting it, everywhere or in some projects (with their worktrees) | MCP Servers → the server → Switches: Off Everywhere…, Off in Project…, Turn On… (or right-click in the list, or in Insights → MCP Servers); `akit mcp state`, `akit mcp set NAME --harness claude\|pi --off everywhere\|project`, `--on` |
| Turn all claude.ai connectors off in Claude Code | MCP Servers → the claude.ai Connectors toolbar button; `akit mcp connectors off` |
| See what a Pi package brings (extensions, skills, prompt templates, themes) | Overview → Pi → Packages (files open read-only in Quick Look); its skills are on Skills under “Pi package · name” |
| Update the home folder from the core layer | Brain → core → Update Home Folder… (or `akit apply --home`) |
| Forget a project and trash the files AKit wrote there | Brain → the project → Forget Project… |
| Keep AKit's files out of a project's git and give them to its git worktrees | Brain → Set Up Project… → Project files: Local only (hidden from git); Brain → the project → Worktrees → Sync Worktrees (also on each refresh and when a worktree is added); `akit worktrees sync` |
| Report what AKit sees on this Mac, for an agent or a bug report | Help → Copy Diagnostics, or `akit doctor` |
| Find what is wrong in Pi's setup, like `claude doctor` | Overview → Pi → Check Pi…, or `akit doctor pi [--live]` |
| Install the newer AKit after a merge into master, here or pushed from another Mac | the Update to … button at the bottom of the sidebar, or AKit → Update to … (it fetches the upstream branch, pulls fast-forward only); a copy from a release zip: run `install.sh` again |
| Report a bug in AKit or suggest a feature | Help → Report a Bug…, Help → Suggest a Feature… (a new GitHub issue in the browser, with a template and the AKit and macOS versions) |
| Turn a skill on or off in Claude Code or Pi without editing it | Skills → the skill → the Claude / Pi picker (or right-click in the list, or in Insights → Skills); `akit skills set NAME --harness claude\|pi --state on\|name-only\|manual\|off`, `akit skills state` |
| See which skills cost context and are never called | Insights (Apply… makes a layer skill manual; the Skills table lists every skill; the line above it says how often Claude Code dropped descriptions) |
| See which skills, MCP servers and tools a period never used | Insights → Skills / MCP Servers / Tools with Unused Only, the window 7 / 30 / 90 Days or Custom… (1–365 days); `akit stats --unused`, `akit stats tools --unused` |
| Make a project's skill global again (into the core layer and the home folder, then out of the projects) | Skills → a project's skill → Move to Global… (or right-click; Brain → the project → Skills → Move to Global…); `akit move skill NAME --to-global [--from PROJECT[,…]]` (prints the plan; `--yes` moves it) |
| Remove a skill from every place a harness loads it from (own copies, brain layers and answers, other projects), so it reaches no context | Skills → the skill → Remove Everywhere… (or right-click; Insights → Skills right-click, or a recommendation card); `akit remove skill NAME --everywhere [--library]` (prints every place; `--yes` removes). A plugin skill: Disable Plugin… in that sheet |
| Delete an MCP server from the Insights table | Insights → MCP Servers → right-click → Delete… (the MCP Servers screen's confirmation and backup) |
| See which projects call one skill | `akit stats skill NAME [--days N]` (this Mac per project, unbound sessions, the other Macs' summaries) |
| Move a global skill into the projects that use it, so other sessions stop paying for its description | Skills → the skill → Move to Project… (or right-click; Brain → a core skill → Move to Project…; Insights → an "Only used in …" card, or right-click in Insights → Skills); `akit move skill NAME --to PROJECT[,PROJECT…]` (prints the plan; `--yes` moves it; `--keep-global` copies only) |
| See whether Claude Code's skill listing fit its budget, and raise it if the fixes can't | Insights → Skill Listing (under the Skills table's first lines; Raise Budget… only when the recommendations alone can't fit); `akit stats listing [--project P] [--days N]` |
| Check that a change reduced the context | Insights → Changes (Add Mark… for a change made by hand) |
| See where one session's tokens went | Sessions → Analysis |
| See which setup one session never used, and how its tool calls ended | Sessions → Overview (Lab review: Overview…) |
| Get a short review of one session | Sessions → Review in Terminal… |
| Ask what a label, number or badge means, or how to do something | Ask AKit in the toolbar or Help → Ask AKit (⌥⌘/); right-click an element → Ask AKit About This |
| Read a session review, notes, a merge request review or an Ask AKit answer in another language | the Translate menu above it (Show Original goes back); the model: Settings → Translation model; `akit translate --to LANG --notes SESSION\|--lab-run ID\|--review RUN\|FILE` |
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
| 4 | Layer evals, minimum: slices 1, 2, 5, 6, then a pilot on 5–8 tasks. I2, D2, D3 and D4 decided 2026-10-08. In progress: slice 1 built 2026-10-08 (Run Cells… → A brain layer, `akit analysis control run --layer`); slice 2 built 2026-10-08 (Evals → From Commit…, Layer Sets, Add to Layer Set…; `task new --commit`, `layer-set`); slice 5 built 2026-10-08 (the layer verdict "helps (offline)" in Evals, `akit analysis control compare --eval`); slice 6 built 2026-10-08 (Brain → layer → Evaluate… with the cost estimate and a calibration cell, Continue, the verdict badge, denied commands for AKit's own repository; `akit analysis control evaluate`); after it, paired calibration (one cell of each setup, the estimate per setup) and the isolation check (no skill or text of the layer in the wrong setup, checked before every layer cell's agent and against its skill listing). Next: the pilot, on the user's JS/TS project (wave 1 below) | `layer-evals.md` (see I2) | Proves the mechanics and the cost on the success number before more is built |
| 5 | Layer checks: slices 3 and 4 | `layer-evals.md` | Only if the pilot shows that success alone can't see the gain |
| 6 | JSON merge in layers: `.mcp.json` and `.claude/settings.json`. Built 2026-10-08: the two files merge key by key, per-key ownership in the lock, `${VAR}`-only secrets, masked preview; not into the home folder yet. It is the base for hooks in layers, but arrays are leaves: lists from several layers (hooks, permissions) clash until named arrays get a union merge | `layers.md`, JSON merge; Roadmap 4 | One mechanism unblocks MCP in layers and writing `enabledPlugins` from a recommendation, and is the base for hooks in layers (array merge still to do) |
| 7 | One parser for failure signals. Built 2026-10-08: `FailureSignals` in `AKitSessions` holds the rules of interrupts, rejections, tool errors and repeated calls; Lab and the index scanner both use it (I4, D1) | `definitions.md`; `session-insights.md`, step 11 (see I4) | Two parsers counted the same signals differently |
| 8 | On demand | see Parked | No user yet |
| 9 | Proposal, not agreed (2026-10-11): model guidance. Step 0 verifies the harness and provider facts without code; then model notes (steps 1–5) and the guidance review (steps 6–7), then the eval rule (step 8) | `model-guidance.md`, Steps | Asked for by the user; its place is wave 3 below, the order inside it is open (D10) |

## Next (2026-10-11)

The user chose wave 1 as the next step on 2026-10-11; on 2026-10-15 the user put AKit Review (wave 0) before it. A grilling session on 2026-10-15 checked waves 1–4 against the code: wave 1 was cut down and moved to Pi (D16–D19), wave 4's Keychain secrets got a design (D20, D21); waves 2 and 3 had no conflict with the code (wave 3's cache rule is its check V4). Waves 2–4 are proposals in this
order; each wave is one or more feature branches.

| Wave | Step | Design | Why at this place |
|---|---|---|---|
| 0 | AKit Review, steps 0–5 (agreed 2026-10-15, R18): step 0 is facts on the work Mac, no code | `review.md`, Steps | The user's daily work tool; it comes before wave 1 |
| 1 | Layer evals on the user's JS/TS project on the work Mac, with Pi (cut down 2026-10-15, D16–D19): (a) Lab cell sessions leave the index; (b) Pi as the cell agent, its `AGENTS.md` rule and its setup check; (c) commit tasks judged by the commit's test files and the user's own test command, exit code only. Then the pilot there, not on AKit. Side metrics and the **Clean** setup come later | `layer-evals.md`, Later (the bold rows), Decisions (2026-10-15) | The pilot is the open part of step 4. The user evaluates layers on a JS/TS project where Pi is the agent; AKit's hidden tests don't judge SwiftUI work, so a pilot on AKit says little |
| 2 | Onboarding: **Set Up This Mac** | `machine-setup.md`, Onboarding | From the work Mac (Pi, herdr): AKit guesses tools and folders. The user reviews the proposal first |
| 3 | Model guidance: step 0 (facts, no code), the guidance review, then model notes with the model × setup matrix of evals | `model-guidance.md`; `layer-evals.md`, Later | D5–D10 first. The review is useful alone (proposal for D10); model notes need the matrix to prove them |
| 4 | Layers: a union merge for named arrays (hooks, permissions) with an owner per element in the lock, so Apply and Forget take out only AKit's elements, then hooks in layers; JSON merge into the home folder; MCP secrets from Keychain through `akit mcp exec` (D20, D21) | `layers.md` | Each removes a hand edit; the array merge unblocks hooks in layers |
| — | Small, between waves: marks for configured servers in Catalog…; I5; merge or delete the branch `review-error-analysis` (one guide commit of 2026-10-02, never merged) | `mcp-catalog.md`; this file | No wave needs them |

## Proposed improvements

Each one removes work or removes a conflict. None adds a feature.

| # | Proposal | Instead of | Why |
|---|---|---|---|
| I1 | Accepted 2026-10-08, built the same day. Step 8 without name-only reasons: the denominator counts exposures with a description, and one finding shows the share of sessions that lost descriptions | reasons `override` / `empty` / `budget` / `unknown`, the same-day rule, a hook change | The reasons guard against `skillOverrides`, which is not set on this Mac (checked 2026-10-03) and may not work in user settings (step 12 says to check it first) |
| I2 | Accepted 2026-10-08 (`layer-evals.md`, Decisions (2026-10-08)); its "Claude Code only" part revised 2026-10-15 by D16. Layer evals v1 for Claude Code only, without the `parts` field; slices 7 (link to modes) and 9 (production level) wait for the first active modes; the pilot moves before the checks | Pi rules that are partly "blocked until verified", room for later variants, a production level with nothing to feed it | Half of the design depends on active modes, and there are none yet. The example run costs $142; the pilot shows whether the result is worth it |
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

| D5 | Model notes: may the akit plugin's SessionStart hook print? Today its rule is "prints nothing". Proposal: it prints only the matching model notes, and nothing when none matches | `model-guidance.md`, Delivery |
| D6 | Limits of model notes: 1,500 characters per note and 4,000 per model in one project, over the limit is an error. Are the numbers right, and error or warning? | `model-guidance.md`, layer.yaml |
| D7 | Where the core layer's model notes live: `~/.akit/model-notes/` (proposal) or a folder in each harness's home | `model-guidance.md`, What lands in the project |
| D8 | A model note whose layer has no "helps (offline)" verdict for that model: a warning in the plan (proposal) or a block | `model-guidance.md`, Proof |
| D9 | Which agent runs a guidance review by default: the reviewed model itself (proposal) or the model the user works with | `model-guidance.md`, The run |
| D10 | Order inside model guidance and against the other steps: the review first (useful alone, mostly removals) or model notes first; before or after the layer-eval pilot | `model-guidance.md`, Steps |
| D11 | Instructions: is a section the text under one `##` heading (proposal), or any heading level, or a paragraph? Decided 2026-10-14: one `##` heading; the text before the first heading is the lead section | `instructions.md`, Model |
| D12 | May AKit remove a section from a project's own AGENTS.md / CLAUDE.md that git tracks (proposal: yes, diff + backup, no commit), or only from untracked and global files? Decided 2026-10-14: yes, diff + backup, never a commit | `instructions.md`, Writing rules |
| D13 | Duplicate sections: same text after normalizing only (proposal), or also near-same text (a similarity threshold)? Decided 2026-10-14: same text after normalizing; same heading with other text shows as "differs" | `instructions.md`, Model |
| D14 | Move to Global… of a section: into the core layer, so every harness's global file gets it as the marked block (proposal), or into one chosen global file. Decided 2026-10-14: the core layer | `instructions.md`, Goal |
| D15 | Order: step 1 (read-only screen) first and alone (proposal), or the four parts together. Decided 2026-10-14: step 1 first and alone | `instructions.md`, Steps |
| D16 | Which agent and which project do layer evals serve first? Decided 2026-10-15: the user's JS/TS project on the work Mac, with Pi; I2's "Claude Code only" no longer holds. Eval data stays in `~/.akit/lab` and never reaches the brain | `layer-evals.md`, Decisions (2026-10-15) |
| D17 | Commit tasks outside SwiftPM: a runner per stack (vitest, jest) or no stack knowledge? Decided 2026-10-15: no stack knowledge. The commit's test files are copied in after the agent and the user's command (`npx vitest run {files}`) judges by its exit code; the task is valid when the command fails on the parent and passes on the commit; an optional second command guards against regressions. The SwiftPM oracle stays as it is | `layer-evals.md`, Decisions (2026-10-15) |
| D18 | Where the judge command lives. Decided 2026-10-15: one per repository in `~/.akit/lab`, entered once in From Commit…, editable per task; never in a layer (on a work Mac that would be a brain write) | `layer-evals.md`, Decisions (2026-10-15) |
| D19 | Sessions of Lab cells (temporary clones `akit-control-*`, `akit-replay-*`) are in the index today and count in Insights (one found on this Mac, 2026-10-15). Decided 2026-10-15: the index leaves them out; Lab and Error Analysis read them from their run folders | `session-insights.md`; `lab.md` |
| D20 | MCP secrets: the value lives in Keychain (decided 2026-10-15). AKit stores what the user types and never shows it. A server gets it through `akit mcp exec NAME -- <command>` in its `command`: akit reads Keychain and passes the value only to that process, never into a file or the shell. Items are made the way `security` reads silently (`-T /usr/bin/security`). HTTP servers: to verify (Claude Code's `headersHelper`; Pi's adapter not checked) | `layers.md`, MCP |
| D21 | `akit mcp exec` in a project whose `.mcp.json` git tracks. Decided 2026-10-15: only in local-only files and the home folder; a committed file keeps `${VAR}` and the plan warns | `layers.md`, MCP |

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
