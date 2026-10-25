# Notebook: short notes, plans and to-dos in the knowledge base

Status: proposal, 2026-10-25 (asked by the user; plan only, no code yet). Decided with the user:
the files live in the knowledge base, the tabs are the user's own (no tab per project), and the
scope is wider than a to-do list: short notes, plans and "what I did today". Next: spike 0.

## Goal

One place in AKit for the small text of a working day, pleasant to read and quick to write:
check boxes that tick with a click, pasted images, links, headings, tables. The files stay plain
Markdown, so Obsidian and any editor read them, and they sit in the knowledge base next to the
notes about systems.

Not a task manager: no due dates, reminders, assignees or sync with Jira or Things.

## Decisions

| # | Topic | Decision |
|---|---|---|
| NB1 | Where | In the world's knowledge base, in `notebook/` beside `areas/` (not in it: these are no notes about systems, `kb search` and lint leave them out until NB9 says otherwise). Images in `notebook/assets/`. The base's git keeps the history; the commit queue commits edits in batches as for notes (U2) |
| NB2 | Tabs | The user's own: one Markdown file per tab, `notebook/<Tab name>.md`. New Tab…, Rename… (renames the file, one commit), Delete… (to the Trash, one commit), drag to reorder (order in `notebook/.tabs.json`, AKit's own file). A new base starts with one tab, `Inbox` |
| NB3 | Editor | [Milkdown Crepe](https://github.com/Milkdown/milkdown) (MIT; v7.22.3, 2026-10-10), bundled offline in the app like Excalidraw (`web/notebook/vendor`, served through `akit-web://`). Markdown-native (ProseMirror + remark): the document is the Markdown, not HTML turned back into it. It has GFM task lists (a click ticks `- [ ]` → `- [x]`), an image block with an upload hook, link tooltips, tables, code blocks, a toolbar and a `/` block menu, and a read-only mode. Checked in its source (`packages/crepe/src/feature`: list-item, image-block, link-tooltip, table, toolbar, block-edit, code-mirror) |
| NB4 | Saving | As maps (N4, N5): opening never writes; an edit posts the editor's Markdown 800 ms after the last key; AKit writes it with the hash check (`saveChecked`); a file changed outside (Obsidian) while open asks Reload / Keep Mine. Crepe may rewrite Markdown it didn't write (`*` lists become `-`, spacing): only on an edit, never on open; spike 0 measures how much |
| NB5 | Images | A pasted or dropped image goes to Crepe's `onUpload`, which hands the bytes to AKit: saved as `notebook/assets/<date>-<short hash>.<ext>` (the same image twice is one file), the Markdown gets `![](assets/…)`. `proxyDomURL` shows it through `akit-web://`. Deleting the image from the text leaves the file; Lint (later) lists unused assets |
| NB6 | Links | `https://…` opens in the default browser. `[[note]]` resolves like a note's link (K-links) and opens the note on the Knowledge screen; a broken one is grey |
| NB7 | Today | A **Today** button puts a `## 2026-10-25` heading at the top of the tab in view (once a day; the cursor goes under it). That is the "what I did today" log: one tab, newest day first, no file per day |
| NB8 | Agents | `akit notebook` reads and appends, like the rest of AKit (everything through akit): `tabs`, `show TAB`, `add TAB TEXT [--task] [--today]` (a line, or `- [ ] TEXT`, at the top or under today's heading), `done TAB TEXT` (ticks the first open task that matches). Agents may run `tabs`, `show` and `add` only when the user asked in the session; nothing else writes. The `/akit` skill lists them |
| NB9 | Search | Open: whether `kb search` and `kb context` include the notebook. Default no: a card about systems shouldn't fill with to-dos |

## Screen

Work → **Notebook** (its own section; the Knowledge screen stays as it is):

```
┌ Notebook ─────────────── [Today] [New Tab…] [Base ▾] [Guide]
│ Inbox │ Plans │ Done today │ + │
├───────────────────────────────────────────────────────────
│  ## 2026-10-25
│  ☑ fix map rows in the list
│  ☐ add folder notes          (click ticks)
│  [image]                     (pasted screenshot)
│  see [[payments/orders-api]], https://…
└───────────────────────────────────────────────────────────
```

The base is the Knowledge screen's (the Base picker when there are several worlds).

## Steps

| # | Step | Done when |
|---|---|---|
| 0 | Spike: bundle Crepe offline; WKWebView round-trip of a test file (task lists, nested lists, tables, code, images, links, frontmatter, `[[links]]`); paste and drop an image; dark mode; bundle size | a table of what Crepe keeps byte for byte and what it rewrites, and go or no-go (fallback: Tiptap with its Markdown extension, or the note panel's text editor with a check-box preview) |
| 1 | Screen, tabs (NB2), editor, saving and commits (NB4), Changed on disk | write, tick and reorder in AKit, see the commit in the base's git, edit the same file in Obsidian |
| 2 | Images (NB5), links (NB6), Today (NB7) | paste a screenshot, click a link, start today's log |
| 3 | `akit notebook` (NB8), the skill, the sample base gets a notebook, guide `notebook.ru.md` | an agent adds a task when asked; the guide's screenshots come from the demo home |

## Open

- NB9: search and the agent card.
- A tab per project after all (the user chose own tabs only for now).
- Images: a size cap, and whether a huge paste is scaled down.
