# Work log: what I did, one line at a time

Status: built 2026-10-28 (asked by the user: many tasks and window switches, a short log of what
they do, stamped by day and time without choosing either, with presets, and a link to the screen).

Code: `KnowledgeWorkLog` (AKitKnowledge: files, parsing, durations, checked writes),
`AKit/WorkLog/` (screen and model), `AKitCommandLine/WorkLogCommand.swift`, `AppLink` (links),
`WatchFilter` (`worklog/` changes).

## Goal

Writing an entry costs one keystroke more than the words: open (⌘L, a link, Raycast), type,
Return. The day and the time come from the clock. The files stay plain Markdown, easy to read
and to process (`akit worklog show --json`).

Not a timer and not a time sheet for billing.

## Decisions

| # | Topic | Decision |
|---|---|---|
| W1 | Where | In the world's knowledge base, in `worklog/` beside `notebook/`: its git keeps the history, Obsidian reads it, the commit queue commits app edits in batches (U2); `akit worklog add` commits at once. Search, lint and `kb context` leave it out (as NB9) |
| W2 | Files | One file per local day, `worklog/YYYY-MM-DD.md`; one entry per line, `- HH:MM #kind text`, in time order. Other lines (a note typed in Obsidian) are kept. The app and `add` stamp the moment of Return; only Edit… and `--at` set a time |
| W3 | Kinds | Presets agent, task, bug, research, reply, meeting, review, break (⌘1…⌘8 on screen); any other `#tag` works too. A leading `#tag` in the text is the kind. The kind resets after each entry |
| W4 | Time | An entry lasts until the next entry of its day; the last one of today until now; the last one of a past day has no length. `break` is not counted as work. Each day shows `work` and minutes per kind |
| W5 | Edits | Edit… (time, kind, text; the day stays), Again Now, Copy, Delete… (git keeps the line). An edit finds its line by number and refuses when the line changed |
| W6 | Links | `akit://worklog` (cursor in the field), `?kind=bug`, `akit://worklog/add?text=…&kind=…` (adds at once, for a Raycast quicklink); View → New Work Log Entry (⌘L) |
| W8 | Auto-Fill | Asked by the user the same day: the Work Log's second tab (not a sidebar item) rebuilds a past day. The user's prompts of that day in the chosen harness's saved sessions (Claude Code, Pi or both) are put in 15- or 30-minute slots; each slot gets its project, the git branch its checkout was on then (the folder's reflog, `GitBranchHistory`) and a ticket (`COL-123`, from the branch, else the prompt). Shown before anything is sent. Propose Entries sends the starts of the prompts (≤ 240 characters each, ≤ 24,000 in all) to a Pi model, by default the GPT-6 Luna Pi lists (GitHub Copilot on the work Mac), chosen from Pi's list (Copilot's when it has them), through `ModelCall` (sending policy, scrub, monthly limit, send log `worklog-fill`). The entries are written in the chosen language, Czech by default (the user's choice; Language, `--language`). The ticked proposals go into that day with their times. `akit worklog fill` does the same |
| W9 | Summary and thinking | Asked by the user the same day: each Auto-Fill entry gets a summary of 2–3 sentences (the goal, what was tried, found or decided, the result), in the entries' language, kept on the lines under it as a quote (`  > …`, paragraphs as `  >`) so Obsidian shows it under the entry. The Log and the proposals show it as an accordion (a chevron under the line; open in the proposals, closed in the log); Edit… changes it. The prompts sent grow to ≤ 400 characters each, so a summary has something to go on. Auto-Fill has a Thinking setting (Pi's levels, default low), `--thinking` |
| W10 | Many days | Asked by the user: the Log shows today and the latest 14 days with entries; Show N More Days adds 14 (with how many are left); Go to Day… (a calendar in the toolbar) loads the pages up to a day and scrolls to it. A reload reads only day files whose change date or size moved, past days are parsed once per change, and only today follows the clock (every minute). Checked with 400 days. Auto-Fill works on one day at a time, so it has no pages: its input is capped (W8) |
| W11 | Calendar blocks | Asked by the user 2026-11-06: meetings were missing from the log, so reports to work were hard. A block has a start and an end, `- 09:00-09:30 #meeting Standup`, in the same day file. It holds its own minutes (an earlier block wins an overlap); a plain entry gets the minutes no block holds, up to the next plain entry (the last one of a past day: up to the next block after it, else unknown). The Calendar tab: week (Mon–Fri, Weekend toggle) or day, drag or click for New Block, drag to move, lower edge to resize, click to edit. Auto-Fill leaves out prompts inside blocks and tells the model about them |
| W12 | Norm | A work day's hours, 7.5 by default, in `worklog/settings.yaml` (`hours: 8`), Monday to Friday; a day's own `norm: 4 h` line (0 a day off). Work day field on Calendar and Report; Set Norm… on a day's header; `akit worklog hours` |
| W13 | Report | Week or month: per day norm, work, missing, break, kinds; per ticket (first `ABC-123` in the text) and kind. Copy (tabs) and Export CSV…; `akit worklog report --csv/--json`. Sending somewhere is later |
| W14 | Import from Calendar | EventKit, read only, after the macOS permission: the timed events of the days on screen, declined ones left out, ticked unless already in the log, added as blocks of the chosen kind (Meeting) |
| W7 | Agents | `akit worklog add`, `show`, `kinds`; an agent adds only when the user asked (`/akit-context`) |

## Screen

```
┌ Work Log ─────────────────────────────── [Base ▾] [📁] [Guide]
│ (Agent) (Task) (Bug) (Research) (Reply) (Meeting) (Review) (Break)
│ [ What are you doing now? Return adds it with the time ] [Add]
├──────────────────────────────────────────────────────────────
│ Today · Wednesday 28. 10.   work 2 h 10 min    Bug 1 h · Agent 50 min
│ 09:20  Bug     order-created arrives twice              1 h 20 min
│ 10:40  Agent   Review of COL-123 with Pi           now · 50 min
└──────────────────────────────────────────────────────────────
```

![Auto-Fill: Day, Sessions, Slot, Model; the slots with project and branch](../guides/images/worklog-fill.png)

## Open

- Auto-Fill: the ticket's title and state through Pi's GitLab MCP server (as AKit Review reads
  work items), checked on the work Mac.

- A menu bar item or a global hotkey for an entry without bringing AKit forward.
- Custom presets in the base.
- Report: send it somewhere (a time-tracking system) instead of Copy/CSV.
