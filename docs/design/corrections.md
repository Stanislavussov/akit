# Corrections: from the user's repeated corrections to one rule, with proof

Status: built 2026-11-02 (steps 0–5), on the branch `corrections-design`. Proposed the same day
from a feature research ("which missing feature brings the most value"); decided by the user: the
model runs only on a click (C1), it sees only excerpts around the user's reactions (C2), and the
proof is code only (C3). Step 0 changed four things (C7–C10, below); C4 is Insights, C5 stays open
with the numbers of step 0, C6 is not built.

Where it lives: module `AKitCorrections` (excerpts, the call, the checks, Apply, Remove, the verdict,
`~/.akit/corrections/state.json`); the count by code is `CorrectionStats` / `CorrectionsReport` in
`AKitInsights` (it needs the index's scope query); `akit corrections` in `AKitCommandLine`; the card
is `AKit/InsightsCorrectionsBox.swift`; the guide is `screens.ru.md`, "Средне: что вы поправляете
снова и снова"; the `/akit` skill has a Corrections part.

## Goal

Find what the user corrects in the agent's work *again and again*, across sessions, and turn
it into one short rule in the setup; then show whether the corrections went down after the
rule. It must cost almost no model tokens: the user's limits are low, and the model is a weak
one (Luna, medium or high reasoning).

Why this and not something else (research 2026-11-02):

- The main pain with coding agents in 2026 is checking and redoing near-correct work, not
  generating it (Sonar State of Code 2026, Stack Overflow, Pragmatic Engineer surveys).
- Self-learning tools write notes (Claude Code auto memory, `self-improving-agent`,
  `claude-mem`) but never measure whether a note helped, so instruction files grow.
- AKit has the parts and nothing joins them:

| Part | Where | State |
|---|---|---|
| The user's reactions per session (interrupt, pushback, refused call, rating) | `UserReactions` (code), counts in the index (`AnalysisIndex` signals) | built, no tokens |
| Problems with an agent prompt | one-session review (`error-analysis.md`, "Problems with a prompt") | built, on a click, the whole digest goes to the model |
| Patterns over many sessions | Error Analysis (bootstrap of 30 labeled sessions, modes, judges) | built, too heavy for daily use; its step 0 is still open |
| Put a prompt into an instruction file | — | not built ("For now Copy and paste") |
| Before/after at a mark | Insights → Changes (`Spool.mark`, `ChangesReport`) | built, measures context size only |

## Decisions

| # | Question | Decided 2026-11-02 |
|---|---|---|
| C1 | When does the model run? | Only on a click (**Find Pattern…** / `--yes`). Without a click the feature costs 0 tokens: code counts the reactions and shows the card |
| C2 | What does the model see of a session? | Only excerpts: each negative reaction verbatim and the 2–3 agent steps before it, cut short. About 1–3k tokens a session instead of 20–100k |
| C3 | How is a rule proved? | Code only: the share of sessions with a negative reaction, before and after the rule's mark, in the rule's scope. 0 tokens |

## Step 0: facts on this Mac (2026-11-02)

Read on this Mac's index (50 sessions in 14 days, 49 of them Claude Code), no model call.

| Question | Found | What changed |
|---|---|---|
| Sessions a week with a negative reaction | 3–7 of 5–26 by the old signals; 11 of 50 in 14 days | — |
| What the reactions are | of 13 excerpts, 6 were refusals by Claude Code's auto mode classifier, 2 were refused question dialogs (AskUserQuestion: "I'll answer in the chat"), 1 a false pushback ("не то" inside "не только") | C8, C9: 5 of 50 sessions (10%) after the fix |
| Excerpt size | 8 sessions, 13 reactions: ≈ 3.7k tokens (≈ 0.5k a reaction with 3 steps of 240 characters) | caps: 8 sessions, 3 reactions each, 240 characters a step, 600 the user's words, 60,000 characters the whole input (≈ 15k tokens) |
| Quiet corrections (C5) | of 101 follow-up turns, about 15–20 are corrections by reading ("стоп …", "avoid … not overengineer!", "все должно быть через акит", "Русский, пожалуйста", "release" asked again and again); the old keywords found 0 of them | C10: a few clear forms added; they find 5. Most quiet corrections read like plain requests, so C5 stays open |
| Groups for the proof | Claude Code's version changed every 2–4 days; groups of one harness version and model had 1–17 sessions | C7 |
| "10 sessions" | 15–25 sessions a week here: a global rule gets 10 in about a week, a project's rule in 1–3 weeks | kept at 10 |

| # | Decision (step 0, 2026-11-02) | Why |
|---|---|---|
| C7 | The proof compares within one harness and model, not the harness version | A version group rarely reaches 10 sessions after a rule (table above). `ChangesReport` keeps the version: the system prompt it measures changes with it; corrections don't |
| C8 | A refused tool call counts only when it is the user's own refusal ("doesn't want to proceed"), not a permission rule's, a hook's or the auto mode classifier's; Esc at the prompt is the interrupt; a refused AskUserQuestion doesn't count. Signals version 5, schema v12: `user_refusals` | Half the "corrections" were the classifier's, not the user's |
| C9 | The user's words of a refusal are the text after "the user said:"; without words, and for an interrupt, the next turn is the words; an interrupt right before a pushback is one excerpt | The refusal text is boilerplate; the next turn says what was wrong |
| C10 | Pushback also: "you forgot", "over-engineered", "still not", "стоп", "не надо", "(ты/мы) забыл", "так и не", "всё ещё не", "по-русски", "на русск"; "не то" only as words | Forms seen in step 0. The same rule feeds error analysis's `pushbacks` |
| C11 | The pattern's scope is set by code (the projects of its reactions), not by the model; Apply's project file is the one its harnesses read (`CLAUDE.md` when it exists or for Claude Code sessions, else `AGENTS.md`) | A weak model gets a smaller schema; Claude Code skips `AGENTS.md` when there is a `CLAUDE.md` |
| C12 | Dismissed patterns live in `state.json` (id and title), not in Insights' `Dismissals` | `Dismissals` is about recommendations and their context space |

## The flow

```
import (as today)
  └─ code: negative reactions per session ─────────────► 0 tokens
Insights → Corrections card: "6 sessions with corrections in 14 days"
  └─ Find Pattern…  (click)
       code: pick ≤ 8 sessions, ≤ 3 reactions each, excerpts, scrub
       one model call ───────────────────────────────────► ~10–25k tokens in
       code: check the answer (ids exist, ≥ 2 sessions a pattern)
  └─ ≤ 3 pattern cards: title, "You said" (verbatim), rule, scope
       Apply…  → diff + backup → Global Instructions or project AGENTS.md
               → a mark with the pattern id
after ≥ 10 sessions in the scope
  └─ code: share of sessions with corrections, before / after ─► 0 tokens
       "fewer" / "no change" / "more"  (+ Remove Rule… when not fewer)
```

## Parts

### 1. Corrections, code only

- A negative reaction is an interrupt, a pushback (`SignalScanner.isPushback`), a refused
  tool call or a bad rating. Plain follow-up turns are not counted.
- `akit corrections [--days N] [--project P] [--json]`: sessions in the window with at least
  one negative reaction, the count per project and harness, the share of all sessions.
- The Insights card shows the same and the button **Find Pattern…**. Lab sessions stay out
  (D19).

### 2. Find Pattern… (the one model call)

- Picking, code: the sessions of the window with the most negative reactions, up to 8; per
  session up to 3 reactions. An excerpt is the reaction's text verbatim and the agent steps
  before it (tool name, a short input, the start of the result, the agent's text), each cut
  to a fixed length; the whole input has a hard cap. The cap and the numbers are checked in
  step 0 on real sessions.
- The send goes through the sending policy and the scrubbing of `definitions.md`, like every
  Tier 2 step. The model is the one in Settings (the PiModelPicker), Luna by default.
- The answer: up to 3 patterns, each with `title` (≤ 15 words), `reactionIds` (from at least
  2 sessions), `rule` (1–4 imperative lines for the agent, English, generic: when it applies,
  what to do, how to check), `scope` (global or one project). A weak model gets a short
  prompt and a strict schema, and parsing is lenient like the session review's.
- Checks in code: unknown reaction ids are dropped; a pattern with reactions from fewer than
  2 sessions is dropped; "You said" shows the reactions verbatim from the log, never the
  model's retelling.
- A pattern already applied (same reactions or an applied rule with the same title) is not
  shown again. A dismissed pattern stays dismissed (`Dismissals`).
- CLI: `akit corrections find [--days N] [--project P] [--json]` prints the plan (sessions,
  estimated input size); `--yes` sends.

### 3. Apply…

- Targets: Brain → Global Instructions (the core layer, D22) or a project's own AGENTS.md
  (diff + backup, never a commit, D12). AKit proposes the target from the scope: reactions from
  2 or more projects → global, from one → that project. The user can change it in the sheet.
- The sheet shows the diff of the target file; the rule goes under one `##` heading
  ("Rules from corrections"), one bullet a rule, so Remove Rule… finds it again.
- Apply writes a mark (`Spool.mark`) with the pattern id and the scope; the pattern card turns
  into a rule card.
- CLI: `akit corrections apply ID [--to global|PROJECT]` prints the diff; `--yes` writes.

### 4. Proof, code only

- The number: the share of sessions with at least one negative reaction, in the rule's scope,
  in a window before the mark and after it. Compared only within one harness, harness version
  and model, as `ChangesReport` does.
- No verdict before 10 sessions after the mark (the number is checked in step 0). Then
  **fewer**, **no change** or **more**, with both counts shown, and a line that a few sessions
  are noise.
- When the verdict is not "fewer", the card offers **Remove Rule…** (diff + backup), so the
  instructions don't grow with rules that don't work.
- CLI: `akit corrections rules [--json]` lists applied rules with their verdicts;
  `akit corrections remove ID` prints the diff, `--yes` removes.

## Token budget

| Step | Tokens |
|---|---|
| Counting, the card, the proof | 0 |
| Find Pattern…, one click | about 10–25k in, ≤ 2k out (8 sessions × 1–3k + the prompt) |
| Apply…, Remove Rule… | 0 |

Compare: one session review sends the whole digest, 20–100k tokens, for one session.

## Steps

| # | Step | Tokens |
|---|---|---|
| 0 | Facts, no feature code: on this Mac's index, how many sessions a week have negative reactions; how long excerpts are; whether pushback by keywords finds the user's quiet corrections (Russian too); set the caps and the "10 sessions" number | 0 |
| 1 | `akit corrections` and the Insights card, code only | 0 |
| 2 | Find Pattern…: excerpts, the call, the checks, the pattern cards; `akit corrections find` | on click |
| 3 | Apply… and the mark; `akit corrections apply` | 0 |
| 4 | The verdict, Remove Rule…; `akit corrections rules` / `remove` | 0 |
| 5 | Guide (`docs/guides/*.ru.md` + a demo screenshot), the `/akit` skill | 0 |

## Open questions

| # | Question | Proposal |
|---|---|---|
| C4 | Where the card lives: Insights (proposal) or Error Analysis | Built on Insights, after Stuck Loops |
| C5 | Does a plain follow-up turn that narrows the task count as a correction? Keywords miss quiet corrections | Step 0: about 15–20 of 101 follow-ups are corrections, keywords find 5 (C10). Proposal: Find Pattern… also sends the follow-up turns of the window's sessions (on the click, still excerpts) and the model marks which are corrections; the card's count stays code-only |
| C6 | Does the session review's problem prompt get the same Apply… button (the "not built" line in `error-analysis.md`)? | Not built yet: `CorrectionRules` takes a pattern; a prompt would need its own small type. Next step if wanted |
