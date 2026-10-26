# Notebook: short notes, plans and to-dos in the knowledge base

Status: built 2026-10-25, steps 0–3 (asked by the user). Decided with the user: the files live in
the knowledge base, the tabs are the user's own (no tab per project), and the scope is wider than a
to-do list: short notes, plans and "what I did today". NB9 decided: no (the default). Later: broken
`[[links]]` greyed (NB6), unused images in Lint (NB5).

Code: `KnowledgeNotebook` (AKitKnowledge: tabs, checked saves, images, the text edits of
`akit notebook`), `AKit/Notebook/` (screen, model, editor view), `web/notebook/` (page, bridge,
bundled editor), `tools/notebook-editor/editor.js` + `tools/build-notebook-editor.sh` (the bundle:
Crepe 7.22.3 and AKit's Markdown fixes, built with esbuild from a locked npm install),
`AKitCommandLine/NotebookCommand.swift`.

## Spike 0: what Crepe keeps

Round-trip of test files in WebKit (the editor's own Markdown after loading, no edit):

| Kept byte for byte | Rewritten (only on an edit) |
|---|---|
| headings, `-` lists, nested task lists, ordered `1.` lists, tables, fenced code, quotes, `---`, bold, italic, inline code, links, `[[links]]` and `[[a\|b]]`, frontmatter | `*` and `+` bullets → `-` (Crepe's default `*` is set to `-`); two trailing spaces → `\`; `1)` → `1.`; an image's alt text → `![](…)` (Crepe keeps its size ratio there) |

AKit's fixes in `editor.js`: `bullet: "-"` and `rule: "-"` for remark; `\[\[` unescaped; the
ratio alt text dropped; an empty paragraph (`<br />`) dropped; frontmatter split off before the
editor and put back on save. Bundle: 2.4 MB script, 36 KB style sheet (CodeMirror languages
included; LaTeX and AI features left out). Go.

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
| NB6 | Links | ⌘-click: `https://…` opens in the default browser; `[[note]]` resolves like a note's link (K-links) and opens the note on the Knowledge screen (a plain click places the cursor). Later: a broken one grey |
| NB7 | Today | A **Today** button puts a `## 2026-10-25` heading at the top of the tab in view (once a day; the cursor goes under it). That is the "what I did today" log: one tab, newest day first, no file per day |
| NB8 | Agents | `akit notebook` reads and appends, like the rest of AKit (everything through akit): `tabs`, `show TAB`, `add TAB TEXT [--task] [--today]` (a line, or `- [ ] TEXT`, at the top or under today's heading), `done TAB TEXT` (ticks the first open task that matches). Agents may run `tabs`, `show` and `add` only when the user asked in the session; nothing else writes. The `/akit-context` skill lists them (knowledge.md K28) |
| NB10 | Drawings | Asked by the user while building: Draw… opens the maps' Excalidraw canvas in a sheet; Done writes `notebook/drawings/<date>-<6 hex>.excalidraw` and its picture `….excalidraw.svg` (Excalidraw's `exportToSvg`) and puts `![](drawings/….excalidraw.svg)` after the cursor's block. A plain image, so Obsidian and GitHub show it. A double click on the picture opens the drawing again (hash check on the scene). Nothing is written while drawing |
| NB9 | Search | No: `kb search`, lint and `kb context` leave the notebook out; a card about systems shouldn't fill with to-dos. Agents read it with `akit notebook` |

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

- Links (2026-10-26, the user's request: open the notebook from Raycast): the app registers the
  `akit` URL scheme; `akit://<screen>` shows a sidebar screen, `akit://notebook/<tab>` a tab (any
  case; it waits until the tabs are read). The open window takes the link (`AppLink`, `RootView`).

## Steps

| # | Step | Done when |
|---|---|---|
| 0 | Spike: bundle Crepe offline; WKWebView round-trip of a test file (task lists, nested lists, tables, code, images, links, frontmatter, `[[links]]`); paste and drop an image; dark mode; bundle size | a table of what Crepe keeps byte for byte and what it rewrites, and go or no-go (fallback: Tiptap with its Markdown extension, or the note panel's text editor with a check-box preview) |
| 1 | Screen, tabs (NB2), editor, saving and commits (NB4), Changed on disk | write, tick and reorder in AKit, see the commit in the base's git, edit the same file in Obsidian |
| 2 | Images (NB5), links (NB6), Today (NB7) | paste a screenshot, click a link, start today's log |
| 3 | `akit notebook` (NB8), the skill, the sample base gets a notebook, guide `notebook.ru.md` | an agent adds a task when asked; the guide's screenshots come from the demo home |

## Open

- A tab per project after all (the user chose own tabs only for now).
- Broken `[[links]]` greyed; unused images listed by Lint.
- Images: a size cap, and whether a huge paste is scaled down.
