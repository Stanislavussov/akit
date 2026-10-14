# Ask AKit: a helper inside the app

Status: 2026-10-14, built on branch `ask-akit`: the core (`AKitHelp`), the side panel, the
toolbar button and Help → Ask AKit (⌥⌘/), and Ask AKit About This in the context menus of the
screens listed under "Where it shows". Chats are not saved.

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
   1. the screen's own section in screens.ru.md and its first subsection
   2. glossary entries (guide `terms`) for the question's words, ≤ 8,000
   3. sections GuideSearch ranks best for the question, the element and their words
   4. more of the screen's sections while room is left
  earlier turns: newest first, ≤ 8 turns, ≤ 12,000 characters, each cut at 4,000
        │
        ▼
App: SendGate.open → ModelCall.run (no tools, schema {"answer": string})
        │
        ▼
AskAKit.answer (the "answer" field, or the text as it came)
AskAKit.sources (the guide sections the answer links to; unknown ids dropped)
```

The system prompt asks for: the language of the question (Ask AKit About This writes its own
question in English, so it asks for the Review language from Settings instead); short plain
sentences; what it means, why it matters, what to do; button names quoted exactly; "the
guides don't cover this" instead of an invention; citations as `[title](guide#section)`. A
link opens the Guide window at that section.

## Data sent and the origin

What leaves the Mac, in one call through the chosen harness and its own sign-in: the
question, the screen's summary (counts, names, the scope and window the screen shows), the
element's facts, the earlier turns of the chat, and the guide sections. The panel says this
under the input field, with the harness and model, every time.

The origin is `SendOrigin.code(agent.harness)`: the screen's data describes the user's own
harness setup (skill and server names, counts, project names), like the repository code that
replays send. So on a personal Mac it may go to the harness's own account; on a work Mac it
goes only to a destination on the allowed list (Settings → Sending policy), else the call fails closed
with the policy's reason shown in the chat. The scrub runs on the input as for every call.
Unlike Rewrite with Skill, a masked value is fine here: the answer is only read, never
written back, so the scrubbed text is sent. The monthly limit and the send log (Lab → Sends,
purpose "ask akit") apply as for every call.

## The agent

The same harness, model and effort fields as Lab and Rewrite with Skill (`ReviewAgentFields`),
in a popover from the panel's header, remembered on this Mac (`ask.harness`, `ask.model`,
`ask.effort`). An empty model means Lab's default for the harness.

## Limits

- One call per question, no tools: the model can't look anything up beyond what is sent.
- A screen's summary is short: counts and names AKit already has, plus what a screen view adds
  with `.askAKitScreen(…)` (Insights: scope, window, recommendations). Rows add their own values
  through Ask AKit About This.
- Chats live until New Chat or quit; they are not saved.
- The glossary guide is picked up by its id `terms`; it is used once `Guide` has a `terms`
  case (`AKit/Guide/GuideView.swift`) and `docs/guides/terms.ru.md` exists.

## Where it shows

Ask AKit About This is in the context menus of:

| Screen | Elements |
|---|---|
| Sidebar | every item (next to What Is … For?) |
| Overview | harness cards, config locations, Pi packages |
| Skills | every skill row (switches, brain link, duplicate and warning marks in the facts) |
| skills.sh | every search result |
| MCP Servers | every server row |
| Instructions | every file row |
| Sessions | every session row; the Usage tab's rows, the Analysis tab's metrics, context rent and tool outcome tiles |
| Usage | the summary tiles and every row of the table |
| Insights | owners, recommendation cards, Skill Listing, Changes, every row of the Skills, MCP Servers and Tools tables |
| Lab | every run row and the run detail's rows |
| Error Analysis | the Modes table (the screen's facts name the tab) |
| Brain | layers, projects, skills |

Screen facts beyond AppModel's counts: Insights (scope, window, recommendations), Sessions (the
open session and tab), Error Analysis (the tab and the Review queue).

Not yet: Error Analysis's Review, Bootstrap, Reports and Evals items, and the detail panes of
Skills, MCP Servers and Brain (their rows have it). Rows inside a view with selectable text
(Usage's table) may show the system's text menu instead on some clicks.

## Code

- `AKitCore/Sources/AKitHelp/AskAKit.swift`: `AskContext`, `AskTurn`, `AskAKit.prepare`,
  `answer`, `sources`.
- `AKit/AskAKit.swift`: `AskAKitModel` (the chat, the call), `AskAKitPanel`,
  `.askAKit(_:facts:)`, `AskAKitMenuItem`, `.askAKitScreen(_:facts:)`.
- `make snapshot ASK=1 SECTION=insights` shows the panel with a made-up chat (no call).
