# Agent reports: what the agent wrote at the end of each task, for a whole period

Status: built 2026-11-20 (asked by the user the same day: an eval that goes through every session
of a chosen period of days and hours, finds what Pi writes at the end of a task, and gives one
report, because nobody can open every session; then an optional focus for the analysis, a
result that is simple and clear, and a simpler screen; after the first release: findings with a
severity, colors and a prompt that fixes each, and the screen that jumped up after Summarize).

Code: `AgentReports` and `AgentReportStore` (`AKitLab/AgentReports.swift`),
`AKit/ErrorAnalysis/AgentReportsTab.swift` (Error Analysis → Agent Reports),
`AKitCommandLine/AgentReportsCommand.swift` (`akit reports`). No new module dependency: Lab
already reads Sessions.

## Goal

Pi's global AGENTS.md asks for three sections at the end of the final task report: `Agent
decisions:`, `Autonomy improvements:` and `Unknown unknowns:`. Over a month that is hundreds of
reports in hundreds of sessions (on the work Mac, 30 days: 282 sessions, 529 reports). Agent
Reports gathers them without a model, and Summarize turns them into one short report.

Not a failure-mode count: Modes and batches stay the way to measure how often something goes
wrong. These are the agent's own words about its work.

## Decisions

| # | Topic | Decision |
|---|---|---|
| A1 | Where | Error Analysis, a sixth tab after Evals (the Improve part of the loop); `akit reports` |
| A2 | Period | One Period picker: Today, Yesterday, Last 7/14/30 Days (default 7), This Month, or Custom with From and To (day and time); `--days N` or `--from`/`--to` with `YYYY-MM-DD` or `"YYYY-MM-DD HH:MM"`. A report counts by its message's time, not the session's |
| A3 | Sections | Editable, one per line, other spellings after `|`; default Pi's three with the Russian headings it writes (`Решения агента`, `Улучшения автономности`, `Неизвестные факторы`, …). A heading counts when it is bold, a Markdown heading, or starts a line with a colon, so a name inside a sentence or in the AGENTS.md text a tool read is not a report. A section runs to the next heading, the next bold label or a paragraph that isn't a list item |
| A4 | "none" | `none`, `- none identified`, `` `- none` ``, `нет`, `отсутствуют`, `No additional blind spots identified` and the like are left out; a report with nothing else counts as "only none" |
| A5 | Reading | Pi files are read fast: only `user` and `assistant` lines are decoded (tool results and the system prompt are most of the bytes), sessions in parallel (30 days: 37 s → 4 s). Every branch of a session counts, also one left with `/tree`: Pi wrote it. A message seen twice (a fork copies history) counts once. The task is the user's last prompt before the report (300 characters) |
| A6 | Without a model | Found: each section's items with time, project and session title; Filter; Copy as Markdown (`akit reports --markdown`); Show Session in the context menu |
| A7 | Summarize | Only the found sections, the task's start and the session's title go out, numbered R1…Rn, never a transcript; Pi model (GPT-6 Luna by default), Thinking, Language (English by default) through `ModelCall` (policy, scrub, limit, send log `agent-reports`). Above 60,000 characters the reports go in parts and one more call merges them; the plan (reports, characters, calls, cost when known) is shown before. The answer is JSON (A12); a stray `"}` after it is tolerated |
| A8 | Simple and clear | The user's choice: one or two sentences, then findings (A12); each text one plain sentence. Replaced 2026-11-20 the first version's Markdown headings (In short, each section, What to change), which read as long lists |
| A9 | Focus | Optional text ("where the agent lacked access"); it goes into the instructions, the report gets a `Focus` section after `In short`, and every heading puts what bears on it first. Kept in the saved file's front matter and shown in Saved |
| A10 | Saved | `~/.akit/lab/agent-reports/<created>.md`: front matter (from, to, created, model, sessions, reports, focus), the report and a table of the reports cited (time, project, session, file). Local only; `akit reports list`, `show` |
| A11 | Simple screen | The user's choice: the left column shows only Period, the count of reports found, Focus and one large Summarize; Sessions, Language, Thinking, Model and Sections wait under a closed More Options |
| A12 | Findings | Asked by the user after the first release: at most 8 findings, each with a severity (high: the work may be wrong or unverified unnoticed; medium: costs time or attention; low: minor), a title, one sentence of what the reports show, the section, the count and up to five report numbers, and a prompt (2–4 sentences: what to change, the rule, how to tell it works) to paste into the agent. Checked after the answer: an unknown severity is medium, report numbers that don't exist are dropped, the most severe and frequent first. Saved as Markdown (🔴 🟠 🔵) with a JSON file beside it that the screen draws as colored cards with Copy Prompt; Copy All Prompts and `akit reports show --prompts` give every prompt as one message |
| A13 | Status bar | Error Analysis' message bar pushed the whole window up (sidebar too) after Summarize, on every tab: its selectable label had a fixed vertical size. It has a line limit now |

## Open

- Compare two periods (did an AGENTS.md change make a section's points go away).
- A finding of `What to change` → a draft for Corrections or a layer edit.
