# Stuck loops: when to raise thinking or switch the model

Status: 2026-10-28, built on branch `repeat-loops` (the user's request: "detect sessions where the
user asks the same thing a few times and the model gives almost the same output; let the user see
that it is time for higher reasoning or another model"). The user chose the scope on 2026-10-28:
analysis for both harnesses, a live warning only in Pi.

## Goal

A model that doesn't get a problem often answers the same way again when asked again: one more
small edit to the same file, the same advice in other words. The user pastes the same error a
third time. The fix is usually not a fourth ask but more thinking or another model. AKit finds
these loops in past sessions (to show which model and thinking level loop most), and in Pi it
says so in the moment.

## Definitions

| Term | Rule |
|---|---|
| Ask | A user message of the main conversation that is not an interrupt (`[Request interrupted by user`), not a slash command (`/compact`, `/model`) and not empty. A skill text the harness put in front of it (Pi's `<skill …>…</skill>`) is left out before comparing |
| Answer | The agent's last text before the next ask, and the files it edited (`Edit`, `Write`, `MultiEdit`, `NotebookEdit`, Pi's `edit`, `write`) |
| Same text | Jaccard overlap ≥ 0.5 of the two texts' words and word pairs (lower case, words of 2+ letters or digits, the first 4000 characters) |
| Repeat | An ask that is the same text as one of the 3 asks before it, or that says "still", "again", "doesn't work", "same error" (and the Russian and Czech forms), **and** whose answer is the same text as the answer before, or edits the same files again. An ask with no answer (an error, a stop) is never a repeat: that is the harness, not the model |
| Loop | 2 or more repeats in a row: the user asked 3 or more times. Counted once, however long |

`RepeatLoops` in `AKitSessions` holds the rules; tests in `RepeatLoopsTests`.

## Decisions

| # | Decision | Why |
|---|---|---|
| R1 | Code only, no model call. Texts are compared in memory; the index keeps the steps, the number of asks, the model, the thinking level and the time of the first ask. Never text | The index never holds message text (`session-insights.md`); a model judge would cost a call per session |
| R2 | Both sides must repeat: the ask and the answer | "Still broken" with a new fix each time is a hard problem, not a loop; the same answer to a new ask is a style. Only both together say "the model is stuck" |
| R3 | 3 asks make a loop, like 3 calls make a repeated call (D1 in `definitions.md`) | One repeat is normal ("still fails" once). On the user's logs (2026-10-28, 188 sessions with 3+ asks) the rule found 2 loops, both true: an error pasted again and one more small edit to the same SQL or deploy file. Thresholds 0.3–0.5 gave the same 2 |
| R4 | The live warning only in Pi, through AKit's Pi extension (`akit-record.ts`) | The user's choice. Pi gives extensions `getThinkingLevel` / `setThinkingLevel`, so the warning can raise thinking with one key. Nothing reaches the model: no message, no prompt change, so the cache is untouched |
| R5 | The model of a loop: the model when its last repeat was sent (Pi's model change, Claude Code's `/model`), else the session's last model. Thinking: Pi's thinking level, Claude Code's `/effort`; else "not recorded" | Only recorded data (`only-recorded-data`). Claude Code's effort is not in its standard log |
| R6 | The advice is an action in the session (raise thinking, switch the model, or start a new session with a summary), not a setting change | A durable fix (a default thinking level per model) needs its own `akit` command first (everything goes through akit) |

## Where it shows

| Place | What |
|---|---|
| Insights → Stuck Loops (under the Skills / MCP Servers / Tools table) | Loops in the window and scope: per model and thinking level, the count, sessions and the most asks, with the advice; then every loop, newest first, with Show (opens it in Sessions at the first ask) |
| Sessions → a session's header, "Stuck loops" | Each loop: the number of asks, the steps, the model and thinking; a click shows the first ask in the conversation |
| `akit stats loops [--project ID\|PATH \| --all] [--days N \| --from DAY [--to DAY]] [--bindings LIST] [--json]` | The same report as Insights (`LoopsReport`, JSON `version` 1) |
| `akit loop-check --harness pi` | Reads `{"transcript_path": …}` on stdin and prints `{"version":1,"loop":{…}}` when the session ends in a loop (`loop` missing otherwise). Run by the Pi extension; reads only that log |
| Pi, after a run (`agent_settled`) | When the session ends in a loop: a line under the editor, "⟳ Asked 3× with almost the same answer (model, thinking low). ⌥T raises thinking, Ctrl+P switches the model". ⌥T sets the next thinking level for this session (Pi clamps it to the model). The line goes away with the next ask |
| Error analysis | `repeat_loops` is one more signal of a session (`SessionSignals.repeatLoops`), so a session with a loop is "raised" for the batch sample |

## Storage

Schema v11 adds `signals.repeat_loops` (the count) and the table `repeat_loops(session_key,
first_step, last_step, asks, model, thinking, ts)`. They are signals, not facts: the signals scan
(`SignalScanner`, version 4) writes them with the session's other signals, after every import and
before `akit stats loops` and Insights read them, and deletes them with them.

## Not built

- A loop count in the summaries the brain publishes (other Macs): wait for real use.
- A durable fix: `akit` command for a default thinking level per model (Pi's `modelThinkingLevels`).
- A live warning in Claude Code (a `UserPromptSubmit` hook could say it): the user chose Pi only.
- "Stuck" without the same answer (the user repeats, the model tries something new each time): the
  near misses on 2026-10-28 were mostly that; a separate signal if it proves useful.
