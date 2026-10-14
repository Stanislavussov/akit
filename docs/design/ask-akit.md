# Ask AKit: a helper inside the app

Status: 2026-10-15, built on branch `ask-akit`: the core (`AKitHelp`), the side panel, the
toolbar button and Help → Ask AKit (⌥⌘/), and Ask AKit About This in the context menus of the
screens listed under "Where it shows"; the glossary guide `terms.ru.md` (AKit Terms). After the
code review of 2026-10-15: Stop ends the harness's process, no session text is sent, links are
checked, the first send is confirmed and every question shows What Was Sent. Chats are not saved.

## What and why

AKit shows many labels, metrics, badges and insights. A user who doesn't know what one means
has to find it in a long guide. Ask AKit answers in place: "what does this mean, why does it
matter, what can I do". The answer comes from AKit's own in-app guides and from what the
screen shows, never from a guess.

Two ways in:

| Entry | What it does |
|---|---|
| Toolbar button **Ask AKit**, Help → **Ask AKit** (⌥⌘/) | Opens or closes the side panel. It knows the current screen. |
| Right-click → **Ask AKit About This** | Opens the panel and asks about that element, with its visible values attached. |

## How one question works

```
question + screen (id, title, summary) + element (title, facts) + earlier turns
        │
        ▼
AKitHelp.AskAKit.prepare          (pure, AKitHelp)
  guide sections ≤ 40,000 characters, whole sections:
   1. the screen's own section in screens.ru.md (cut at a line to fit when it is
      longer than the budget) and its first subsection
   2. glossary entries (guide `terms`) for the question's words, ≤ 8,000
   3. sections GuideSearch ranks best for the question, the element and their words
   4. more of the screen's sections while room is left
  earlier turns: newest first, ≤ 8 turns, ≤ 12,000 characters, each cut at 4,000
  the question: cut at 4,000 (the panel says so under the field)
        │
        ▼
App: AskContext.redacting (session titles, mode names and definitions → ‹session text›)
     first send of a launch: the confirmation (unless Don't ask again)
     in a Cancellation.Scope of its own: SendGate.open → ModelCall.run
       (no tools, schema {"answer": string}); Stop and New Chat cancel the scope,
       which ends the harness's process
        │
        ▼
AskAKit.answer (the "answer" field, or the text as it came; off the main actor, ≤ 65 parses)
AskAKit.sources (the guide sections the answer links to; unknown ids dropped)
AskAKit.linkTarget (a click: a known guide section → Guide window, https → browser,
  anything else → nothing)
```

The system prompt asks for: the language of the question (Ask AKit About This writes its own
question in English, so it asks for the Review language from Settings instead); short plain
sentences; what it means, why it matters, what to do; button names quoted exactly; "the
guides don't cover this" instead of an invention; citations as `[title](guide#section)`. A
link opens the Guide window at that section; only such links and `https` pages open.

## Data sent and the origin

What leaves the Mac, in one call through the chosen harness and its own sign-in: the
question, the screen's summary (counts, names, the scope and window the screen shows), the
element's facts, the earlier turns of the chat, and the guide sections. The panel says this
under the input field, with the harness and model, every time. The first send of a launch asks
first (Send to …?, with the kinds of data; Don't ask again stores `ask.dontConfirm`), and
What Was Sent under each question shows the destination, the input as the scrub left it and
the guide sections of the system prompt.

**No session text.** Screen data is setup data only: harness, project, tab, ids, counts,
statuses and numbers. Never a session's title (its first prompt), notes, quotes, evidence, or an
error analysis mode's name or definition (they come from notes): sessions, modes, control tasks
and Lab runs are named by id. Two layers keep it so: the facts the views build (Sessions,
Error Analysis, Lab), and `AskContext.redacting`, run on every send with every session title
AppModel has and every mode's name and definition, which replaces any of them a fact still
quotes (tested in `AskAKitTests`). The user's own typed question and the chat are sent as
written. The MCP pane sends names only, never a value (no arguments, the URL's host, the names
of environment variables and headers).

The origin is `SendOrigin.code(agent.harness)`: the screen's data describes the user's own
harness setup (skill and server names, counts, project names), like the repository code that
replays send. So on a personal Mac it may go to the harness's own account; on a work Mac it
goes only to a destination on the allowed list (Settings → Sending policy), else the call fails closed
with the policy's reason shown in the chat. The scrub runs on the input as for every call.
Unlike Rewrite with Skill, a masked value is fine here: the answer is only read, never
written back, so the scrubbed text is sent. The monthly limit and the send log (Lab → Sends,
purpose "ask akit") apply as for every call; since 2026-10-15 `ModelCall` counts the system
prompt with the input in both (every caller's system prompt is sent and paid for), which
matters here, where the guide sections are in the system prompt.

## The agent

The same harness, model and effort fields as Lab and Rewrite with Skill (`ReviewAgentFields`),
in a popover from the panel's header, remembered on this Mac (`ask.harness`, `ask.model`,
`ask.effort`). An empty model means Lab's default for the harness. A chosen harness that isn't
installed falls back to one that is, with that harness's own default model and effort. The
agent is worked out when the panel opens and when its fields change, not on every redraw.

## Limits

- One call per question, no tools: the model can't look anything up beyond what is sent.
- A screen's summary is short: counts and names AKit already has, plus what a screen view adds
  with `.askAKitScreen(…)` (Insights: scope, window, recommendations). Rows add their own values
  through Ask AKit About This.
- Chats live until New Chat or quit; they are not saved. One chat per app: the main scene is a
  single `Window` (the screen in view, `AppModel.section`, was already shared by every window).
- One call at a time: About This is off while a call runs or the confirmation waits, and sets
  the focus only when its question is really sent; New Chat during a call cancels it and the
  next send waits until its process is gone.
- The glossary guide `terms` (`docs/guides/terms.ru.md`, Help → AKit Terms Guide) is a `Guide`
  case; its matching entries go first, within 8,000 characters.
- Facts for About This are built when the item is chosen (`@autoclosure`), not on every redraw;
  a screen's own facts (`.askAKitScreen`) are a few short lines built with its view.

## Where it shows

Ask AKit About This is in the context menus of:

| Screen | Elements |
|---|---|
| Sidebar | every item (next to What Is … For?) |
| Overview | harness cards, config locations, Pi packages |
| Skills | every skill row; the detail pane's field names, harness badges, Read-only badge, warnings |
| skills.sh | every search result |
| MCP Servers | every server row; the detail pane's field names, transport badge, Used by rows, warnings (names only, never a value: no arguments, the URL's host only, only the names of environment variables and headers) |
| Instructions | every file row |
| Sessions | every session row; the Usage tab's rows, the Analysis tab's metrics, context rent and tool outcome tiles |
| Usage | the summary tiles and every row of the table |
| Insights | owners, recommendation cards, Skill Listing, Changes, every row of the Skills, MCP Servers and Tools tables |
| Lab | every run row and the run detail's rows; the batch section (summary, steps, every session and its status badge); the control task and its oracle result |
| Error Analysis | Modes table; Review cards (candidates, routes, tough calls, spot checks, umbrellas); Bootstrap (reserved sessions, agreement rows, similar cases, finds); Reports (tiles, frequency rows, transition matrix cells); Evals (layer sets, tasks, task fields, comparison setups, verdicts); the mode page (header, code check, judge, fix, routed notes) |
| Brain | layers, projects, skills; the detail panes' field grids and skill mode badges |

Screen facts beyond AppModel's counts: Insights (scope, window, recommendations), Sessions (the
open session and tab), Error Analysis (the tab and the Review queue).

Not yet: the difference grid of two batches (its cells don't know their row and column), the
skill switch and invocation rows of the Skills pane, and the layer pane's field and skill lists.

### Selectable text

A view with `.textSelection(.enabled)` shows the system's text menu (Look Up, Copy, …) on a
right-click over its glyphs, and an ancestor's `.contextMenu` is not offered there; SwiftUI has no
API to add an item to that menu. So the field names and row labels (the Usage table's day, the
Sessions Usage rows, run detail rows, metric rows, the Skills, MCP and Brain panes' field names)
are `.textSelection(.disabled)`: a right-click on them, or on empty space in the row, gets
Ask AKit About This, while the values stay selectable for copying. Checked with
`make snapshot … RCLICK="x,y;…"` (`--right-click`), which right-clicks there and prints each
menu's items: in the demo home the Usage table's day column gave the text menu before the change
and Ask AKit About This after it; a number still gives the text menu.

## Code

- `AKitCore/Sources/AKitHelp/AskAKit.swift`: `AskContext`, `AskTurn`, `AskAKit.prepare`,
  `answer`, `sources`.
- `AKit/AskAKit.swift`: `AskAKitModel` (the chat, the call), `AskAKitPanel`,
  `.askAKit(_:facts:)`, `AskAKitMenuItem`, `.askAKitScreen(_:facts:)`.
- `make snapshot ASK=1 SECTION=insights` shows the panel with a made-up chat (no call).
