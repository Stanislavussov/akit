# Knowledge base: maps of systems and notes an agent can search

Status: designed 2026-10-24 (grilling with the user); step 1 built 2026-10-24 (base, notes, links,
`akit kb`, the Knowledge screen, the commit queue, guide `knowledge.ru.md`; 1.3, K24: kinds in
`kb.yaml`, Properties and `akit kb set`, Kinds…, `area.yaml` and Area Settings…; 1.4, K25: the base
folder per world in `bases.json`, `akit kb path`, Settings → Knowledge; 1.5, K26: the sample base
`akit kb seed`, Add/Remove Sample Base…, `akit kb rm`); spike 2.0 (Excalidraw
bundle, results below) done 2026-10-24; 2.1 (reading `.excalidraw`, the map graph, `akit kb maps`,
`relations`, `new-map`, two seeded maps) built 2026-10-24; 2.2a (the read-only map view: Maps
in the list, view mode, a click on a block opens its note, map snapshots) built 2026-10-24; 2.2b (Edit,
saves of Excalidraw's own bytes, Changed on disk, maps in the commit queue, New Map…, Delete…) built 2026-10-24;
2.3 (map tabs, a dragged note becomes a linked block, Relations in the note panel, Rename… and
`akit kb rename`) built 2026-10-24: step 2 is done. 3.2a (the search index `.akit-index.sqlite` with FTS5,
`akit kb search`, `show`, `index`, the miss log; seed v3) built 2026-10-24. 3.2b (focus: `focus.json`, then
`area.yaml` `projects:`, then notes' `repo:`; `akit kb neighbors`, `context`, `focus`) built 2026-10-24. 3.3 (the
search field, the index line with Reindex, watching the base folder, a note Changed on disk, Focus… and Preview
Agent Context…) built 2026-10-24. 3.4 (the Pi template: `templates/kb-pi.md` in the core layer for Pi only,
`akit kb pi-template`, Knowledge → Pi Template…) built 2026-10-25: step 3 is done. 4.1 (lint: `KnowledgeLint`, `akit kb lint`, the Lint tab, Checks and grey links
in the note panel; seed v4 with the area `lint-examples`) built 2026-10-24: step 4 is done. 5.1 (proposals: `akit kb
propose`, `inbox`, `accept`, `reject`; `KnowledgeInbox`; seed v5 with two proposals) built 2026-10-25; 5.2 (the check model: `KnowledgeCheck`, `akit kb check`, `kb check-model`, Settings →
Knowledge check model, the origin `knowledgeBase`; seed v6 with a stored mark) built 2026-10-25; 5.3 (the Inbox
tab: Accept…, Reject…, Check Again, "Add an arrow?" on the map; `KnowledgeChecker` in AKitLab) built 2026-10-25; 5.4
(agent-drawn maps, K21: `akit kb propose --map`, the draft's preview and Accept… with Save Map in the Inbox, Draw Map
with Pi…, `KnowledgeMapDrawer` in AKitLab; seed v7 with a map proposal) built 2026-10-25: step 5 is done, see
[Proposals](#proposals). 6.1 (K18: the knowledge card of AKit Review, `context/knowledge-card.md`; profile
`knowledge_base:` / `knowledge_budget:`, Review Settings… → Knowledge base, `akit review --knowledge-base`,
`--knowledge-budget`) built 2026-10-25; 6.2 (the review passes' `akit_kb_search` / `akit_kb_show`, extension v13 after the merge with master's v12) built
2026-10-25: step 6 is done. K27 (folders and other repositories: `path:`, kind `folder`, `local` in `kb show` / `kb context`, Add Folder… and `akit kb add-folder`; seed v8) built 2026-10-25. Step 7 waits for about two weeks of use on the work Mac (7.0: go or no-go from the miss log). Steps in [Steps](#steps).
First use: the work Mac, with Pi.

## Goal

The agent knows the code of one repository, not the system around it: which service sends
which event to whom, which repository owns what, where the spec lies. The user wants to
describe the system once, by hand, and let the agent read it.

- The user draws maps of systems by hand (Excalidraw, inside AKit, offline).
- The text lives in Markdown notes; a block on a map links to its note.
- The agent searches the notes and walks the links of the maps through `akit kb …`.
- The agent may propose changes; the user approves each one.

## Decisions

| # | Question | Decision |
|---|---|---|
| K1 | Main reader | The agent. The maps are for the user, to describe and check the system. Both read the same files |
| K2 | Source of truth | A folder of files. SQLite is only an index: it can be deleted and rebuilt. No Postgres |
| K3 | Map editor | Excalidraw (MIT), bundled into the app, works without network. Maps are `.excalidraw` files in the base folder |
| K4 | How many bases | One base per "world" (work, personal). A subproject is an **area** (a folder) inside the base, not a base of its own, so a data pipeline across repositories stays one graph |
| K5 | Project focus | A project sets a **focus** (its area first), never a wall. The agent can follow a link into another area. Default focus: the area of the systems whose `repo:` matches the folder; the user can change it in AKit (stored in `~/.akit/local`, not in the repository) |
| K6 | Map ↔ note | A block's Excalidraw `link` is `[[note]]`; clicking it opens the note in a side panel (read, edit, copy, paste). Dragging a note onto the canvas makes a linked block. An arrow's label is the kind of relation; an arrow may link `[[flow-note]]` for long text |
| K7 | Several maps | Each map is its own space (a tab). One system may be on several maps (the same `[[note]]`); the graph joins the arrows of all maps. A block may link another map (`[[maps/payments]]`) to jump to it. Unrelated apps get their own maps with no shared blocks |
| K8 | Source of relations | Arrows bound to two blocks. Notes hold text and references; a note shows its relations, read from the maps, read-only |
| K9 | Space = area | A space of maps and an area of notes are one thing: `areas/<name>/` holds both |
| K10 | Obsidian | The base folder is a plain Obsidian vault (`[[links]]`, frontmatter). **Open in Obsidian** opens a note through `obsidian://open`. No plugin. Maps are edited in AKit only. AKit watches the folder and reindexes changed files |
| K11 | Git | The base is a local git repository **without a remote**. AKit commits each accepted change. On a work Mac the base never goes into the personal brain. Where the folder may be: K25 (it replaced the first rule "on a work Mac only under `~/.akit/local/`") |
| K12 | References | `repo:` is the git remote URL when the repository has one, else a `~/` path; AKit finds the local copy among its projects. `files:` are paths inside the repository. Files outside git use `~/` paths. Missing → grey link and a lint finding |
| K13 | Agent access | `akit kb context / search / show / neighbors --json`; the `/akit` skill teaches them. No MCP server. A retrieval subagent on a small model is a harness matter: AKit may ship its template in a brain layer, the harness runs it |
| K14 | Agent writes | Only proposals: `akit kb propose` puts a change into `inbox/`. A light model checks it (duplicate, contradiction with a map, broken `[[link]]`) and only marks it; checks without a model (secrets, broken links) block at once. Accept / Reject is always the user's; Accept writes and commits. The agent never edits maps; it proposes an arrow in text ("Add an arrow?") |
| K15 | Checker model | A setting with a Picker (like Settings → Translation model). The user's choice for the work Mac: GPT-6 Luna, run through Pi |
| K16 | Context in a session | Only a template, once per Mac, for **Pi only** (no Claude Code): the core layer's AGENTS.md block in the file Pi reads in `~/.pi/agent`, through `akit apply --home`. 3–4 lines: there is a base, run `akit kb context` at the start of a task about systems, then `akit kb search`. Project files are never written; `akit kb context` works out the focus from the folder |
| K17 | RAG | Yes, in two steps. v1: SQLite FTS5 + the graph of the maps (a hit brings its neighbours). Embeddings later, only with a local model (no work text leaves the Mac), when keyword search misses. This lifts `review.md`'s "no embeddings" for the knowledge base only, at that step |
| K18 | AKit Review | Yes, the user wants it (2026-10-24), as step 6. Gather adds only a **card** of the systems an MR touches and their neighbours (names, one line each, relations), within the profile's `knowledge_budget` (8 000 tokens by default; the user found 1 500 too small); the roles get `akit_kb_search` / `akit_kb_show` for the rest. The profile field `knowledge:` keeps working |
| K19 | Token budget | The point of the RAG is to send little. `akit kb context`: a card, 4 000 tokens at most by default. `search`: the 10 best chunks (one chunk = one `##` section of a note), snippets first. `show`: a whole note only when the agent asks for it. Each command takes `--max-tokens`. The defaults are a first guess; tune them from real Review logs |
| K20 | RAG engine | All in one SQLite file: FTS5 with BM25 for words, `nodes` / `edges` tables for the graph, and (step 7) one vector BLOB per chunk with cosine similarity in Swift (Accelerate), no extension: macOS's system SQLite can't load `sqlite-vec` (checked 2026-10-24 on macOS 15.6.1: SQLite 3.43.2 is built with `OMIT_LOAD_EXTENSION`, the SDK header has no `sqlite3_load_extension`; `ENABLE_FTS5` is on and an FTS5 table with `bm25()` works). Embeddings from a local model (`NLContextualEmbedding` or Ollama) |
| K21 | Maps drawn by an agent | Added 2026-10-24 at the user's request. Pi draws a map from a prompt with [`@swiftlysingh/excalidraw-cli`](https://github.com/swiftlysingh/excalidraw-cli) (MIT; runs in the agent's harness, AKit ships no Node) and sends it with `akit kb propose --map AREA/NAME --file F`. The draft waits in Inbox; on Accept, AKit links each block whose label names one note to `[[note]]` and saves Excalidraw's own bytes. In AKit: **Draw Map with Pi…** (a prompt → Pi with no tools writes the DSL → AKit runs excalidraw-cli and proposes the draft; 2026-10-25 review: no shell for Pi). Spike answer 6 lists the format gaps |
| K22 | AKit and Pi | Added 2026-10-24 at the user's request: everything works from AKit (a button) and from Pi (an `akit kb` command with `--json` / `--yes`). The `/akit` skill lists the person-only commands too, with the rule: run them only when the user asked for that action in the session; never accept or reject a proposal on your own |
| K23 | Separate folders | Added 2026-10-24 at the user's request: one area `areas/<name>/` per project, system or unrelated entity, with its own notes and maps; unrelated worlds get separate bases. Every create or proposal names its area; an agent proposes a new area instead of mixing unrelated systems, and the area is created on Accept |
| K24 | Kinds and settings | Added 2026-10-24 at the user's request: kinds and their fields are data in `<base>/kb.yaml` (defaults `service`, `flow`, `team`, `database`, `queue`, `external`; the user adds, renames, removes). A note's kind and fields change in the note panel's **Properties** or with `akit kb set NOTE KEY=VALUE`, one frontmatter line at a time. `areas/<name>/area.yaml` maps an area to projects (remotes, `~/` paths, globs), so focus and Review find the area for new clones and folders without setup |
| K25 | Base folder | Added 2026-10-24 at the user's request: the base folder is a setting per world (`~/.akit/local/knowledge/bases.json`, this Mac only), e.g. a folder in the user's Obsidian vault. Any local folder is allowed except inside the brain, a synced folder (iCloud Drive, CloudStorage, Dropbox, Google Drive) or a repo with a remote; this replaces the work-Mac rule "only under `~/.akit/local/`" (K11). **Open in Obsidian** opens the vault that holds the base |
| K26 | Sample base | Added 2026-10-24 at the user's request: `akit kb seed` / **Add Sample Base…** make a separate base `sample` with made-up content that shows every feature (each later step adds its feature to it); `kb seed --remove` / **Remove Sample Base…** move it to the Trash. `akit kb rm NOTE\|MAP\|AREA` removes from the terminal (to the Trash, one commit) |
| K27 | Folders and other repositories | Added 2026-10-25 at the user's request: the base is the one way in to the other repositories and local folders around a project (the backend of a frontend, a local wiki). A note's `path:` names its folder on this Mac (`~/…` or absolute); `kind: folder` (new default kind, fields `path`, `owner`) is a folder without git, and `service` gained `path`. `KnowledgeLocal` finds a note's folder: `path:`, else a `~/` `repo:`, else the clone of `repo:`'s remote among the projects lint knows; `akit kb show` gives it as `local` ("on this Mac"), `akit kb context` as `local` per system (`[~/…]`). **Add Folder…** and `akit kb add-folder FOLDER --area A [--name] [--description] [--yes]` (person only) write the note: kind service with the origin remote (user and password cut out) for a git repository, else kind folder; `path:`; the description given, else the README's first line (none with a secret); one commit, with the kind added to a `kb.yaml` that lacks it. Lint: `missing-home-path` for a `path:` that is no folder; `files:` are checked in the `path:` folder. Seed v8: orders-api has `path:`, lint-examples' home-path is a folder note |

## Layout

```
~/.akit/local/knowledge/work/          (the default folder of the world work; one folder = one base, git without remote)
├── areas/
│   ├── payments/
│   │   ├── orders-api.md               note of a system
│   │   ├── billing.md
│   │   ├── flows/order-to-billing.md   note of an arrow
│   │   └── maps/overview.excalidraw    a tab of the "payments" space
│   └── logistics/ …
├── inbox/                               agent proposals waiting for Accept / Reject (untracked;
│   └── .gitkeep                         only this file is committed, so inbox/ is tracked, P3)
└── .akit-index.sqlite                   index, rebuildable, git-ignored
```

The folder is the default; `~/.akit/local/knowledge/bases.json` may set another one per world
(K25), like `~/Notes/Vault/kb` inside an Obsidian vault or the vault itself. The vault's own notes
outside `areas/` stay untracked, and `.obsidian/` is git-ignored. A vault with Obsidian Sync on
(`.obsidian/sync.json`, or the core plugin `sync` enabled in `core-plugins.json` or
`core-plugins-migration.json`) uploads the base with it: on a work Mac the folder is refused, on
another Mac it is allowed with a warning that `kb path`, `kb init` and Settings → Knowledge show
(review 2026-10-25).

When the app opens a base it sweeps it once: `git status --porcelain -z -- areas/ kb.yaml` (with
`GIT_OPTIONAL_LOCKS=0`) names what differs from the last commit, and those paths join the commit
queue (`KnowledgeCommitQueue.sweep`), so an edit whose enqueue was lost (the lock was held at quit,
a crash) still gets its commit; `inbox/` never. Git in a base runs only where the base has its own
`.git` (only `init` runs without one), with `GIT_CEILING_DIRECTORIES` at the base's parent, so a
base that lost its `.git` never commits into a repo above it.

A note of a system:

```markdown
---
kind: service
repo: git@gitlab.example.com:shop/orders-api.git
files: [src/events/order-created.ts]
---
# Orders API
Free text…
```

## Proposals

Built in 5.1 (K14, K23, K24, P3). An agent changes the base only by a proposal: `akit kb propose`
writes one file `inbox/<yyyy-MM-dd>-<slug>.md` (UTC day; `-2`, `-3` … when taken) and nothing
else. It is never committed, queued or indexed; `git status` shows it as `?? inbox/<id>.md`.

The file (`KnowledgeProposal.text`, read back by `parse`):

```markdown
---
id: "2026-10-25-payments-billing"
kind: note                        # note | arrow | map (5.4)
target: "payments/billing"        # note: the note id; arrow: the map id, or none; map: the map id
reason: "Retries were missing"    # --reason, optional
created: "2026-10-25T09:12:00Z"
author: "pi"                      # --author, else "claude" under Claude Code, else none
set:                              # --set KEY=VALUE, note only (K24)
  "owner": "team-a"
arrow:                            # arrow only: note ids, the label, the map
  from: "payments/orders-api"
  kind: "events"
  to: "payments/billing"
  map: "payments/maps/overview"
---
## Retries
Three tries with backoff.
```

| Kind | Body | Accept (person only) |
|---|---|---|
| note, target exists | `## Heading` blocks only (no frontmatter, no `# title`, no loose text before the first block) | each block replaces the section with that heading (the blank line after the heading kept) or is appended; then each `set` key through `KnowledgeNote.setting` |
| note, new target `AREA/NAME` | the whole note; `# NAME` is added when it has no title and no frontmatter | the file is created; a new area's folder too (K23, no `area.yaml`); then `set` |
| arrow | empty | writes nothing: "Add the arrow A -kind-> B on map M in the app (Knowledge → Inbox)", exit 2, the proposal stays |
| map (5.4), target `AREA/maps/NAME` | the draft's blocks and arrows as text (`Blocks: …`, `Arrows: …`); the draft itself beside it, `inbox/<id>.excalidraw` | in the app only (below); `kb accept` writes nothing: "Open Knowledge → Inbox to accept a map.", exit 2 |

Checks without a model block `propose` at once, and are run again by `kb inbox` and before
Accept (the base may have changed): `secret` (body, reason, `set`, arrow: `SecretFilter.masked`
changes the text, or `PRIVATE KEY`), `target` (no `..`, no absolute or `~` path, no hidden part,
not `inbox/`, not a `maps/` folder, a new note names its area, the file stays inside `areas/`),
`links` (every `[[link]]` / `akit:` link of the body resolves, the proposed note itself counts;
ambiguous is a warning), `arrow` (both ends are notes, the map exists). The model's marks (5.2)
come on top and never block.

The Inbox tab (5.3) lists `proposals()` with these checks and the stored marks, and shows the
selected one's `planAccept` diff. **Accept…** of a note asks with the diff, then runs `accept`
(the window's pending saves are queued first). **Reject…** runs `reject`. **Check Again** runs
`KnowledgeChecker.run` (AKitLab), the same call as `kb check`; a refused gate shows its "Not sent: …"
reason. **Accept…** of an arrow opens its map in Edit (the named map, else the one map of its ends'
areas, else a question which: `arrowMaps`) with "Add an arrow?" (`planArrow`: each end's first block,
or a new block with the shortest link that resolves to the note from the map and the note's title).
**Add** draws it in the canvas (bridge.js `akitAddArrow`: new blocks right of the drawing, an arrow
bound to both blocks with its label), force-posts the change through the normal checked save (the
map's commit waits in the queue, U2), then `closeArrow` removes the proposal and its marks, only once
the map on disk has the arrow; nothing is committed for the untracked proposal. The badge
**Inbox (N)** and the list follow every `inbox/` change the watcher sees.

The check model (5.2, K15): `akit kb check ID [--model provider/model] [--json]` (agents may run
it) sends one call through `ModelCall` with the origin `SendOrigin.knowledgeBase` (any Pi
destination is allowed, like `mergeRequest`; anything else needs the allowed list) and the purpose
`kb-check`, so the sending policy, the scrub, the monthly limit and the send log apply. The model
is `LabSettings.knowledgeCheckAgent` (Settings → Knowledge check model, a `PiModelPicker`, or
`akit kb check-model MODEL [THINKING] [--harness]`). Models come only from the harness's own list
(`LabRuns.models`: `pi --list-models`, Claude Code's aliases), never typed in (2026-10-25, user's
rule): unset, the model is picked at call time from that list (Pi: the first of
`KnowledgeCheckModel.lunaModels` it lists, `opencode-go/gpt-6-luna` at home or
`github-copilot/gpt-6-luna` on the work Mac, else its first; Claude Code: haiku), at thinking `low`;
a model the harness no longer lists is refused with the list. The harness is a choice too: Pi
(default) or Claude Code, only the installed ones, each remembering its last model
(`LabSettings.knowledgeCheckModels`; a non-Pi harness needs the Sending policy's list, as the origin
allows only Pi). Draw Map always runs Pi, so it takes Pi's check model. `KnowledgeCheck` (core, no call, C1) builds the input: the proposal, then
candidates of at most 1500 tokens: the best 5 sections of searches for the proposal's words
(its target's name, headings and text; each cut to 800 characters) and the arrows touching its
notes (1 hop), cut from the end. The answer `{"marks": [{kind, note, edge, link, message}]}` with
kind `duplicate`, `contradiction` or `broken-link`: fields beyond the schema and marks of other
kinds are dropped, messages are masked and cut to 300 characters; anything else in the answer
(an "accept") is ignored. The marks are kept in `inbox/.<id>.check.json` (hidden: not a proposal,
not counted; untracked; `WatchFilter` treats it as `inbox/`) with the proposal file's SHA-256, so
`kb inbox` shows them (`modelCheck`, `stale` after the proposal changed). Accept and Reject remove
the file.

Map proposals (5.4, K21, `KnowledgeMapProposal.swift`): an agent draws a map with
[`@swiftlysingh/excalidraw-cli`](https://github.com/swiftlysingh/excalidraw-cli) in its own harness
(AKit ships no Node) and sends it with `akit kb propose --map AREA/NAME (--file F.excalidraw |
--stdin) [--reason T]`. `propose` copies the draft to `inbox/<id>.excalidraw` (written before the
proposal file, so a map proposal never lacks it; at most 2 MB) and writes the proposal (id from the
map id, `2026-10-25-payments-maps-flow`); `--json` adds `draft`. Refused: a file `ExcalidrawFile`
can't read or without elements, a secret in any element's text or link, a name other than
`AREA/NAME` or `AREA/maps/NAME` (no `..`, no absolute path, nothing hidden, not `inbox/`). An existing
map is "replaced" (the `target` check says so); a new area is created on Accept (K23). The checks
are `secret`, `target` and `map` (the draft is there and parses). The draft is never counted apart
(`WatchFilter.inboxCount`) and goes to the Trash with its proposal on Reject.

`planMap` reads the draft as `MapGraph.labels(in:)` does (bound text first, else the free text whose
centre lies inside the smallest shape: excalidraw-cli's labels are free text) and matches each
shape's label to one note (`KnowledgeInbox.match`): the link rules (P1, the label read as `[[label]]`
from the map's path, so the map's own area wins), else a note's title, ignoring case. One note: the
shape gets the shortest `[[…]]` that resolves to it from the map; ambiguous or none: it stays plain
and is listed. The plan's diff lists blocks and arrows by label (`+ block billing`, `- arrow …`,
kept ones indented) against the map it replaces. The Inbox shows the draft on a read-only canvas
(the key `inbox/<id>.excalidraw`, never saved as a map), the links and the plain labels. **Accept…**
puts that canvas in Edit and sets the links through the bridge (`akitSetLinks({elementId: link})`,
on the shape that holds the label); **Save Map** takes `akitSerialize` (Excalidraw's own bytes, so
`source` becomes `akit-web://app`) and `acceptMap` saves it: the queue is flushed (U2), the map must
still be as planned (absent, or hashing to the planned bytes, as `saveChecked` checks), the proposal
and the draft unchanged; a replaced map is backed up like a note; then the map is written (a new
area's folder too), the proposal, draft and marks removed, and one commit holds only the map
(`Add map M (accept proposal ID)` or `Replace map M …`); a failed commit puts everything back.
**Cancel** reloads the draft without links. The new map opens in the Notes tab.

**Draw Map with Pi…** (the Knowledge toolbar; R-AP): an area (or New Area…), a map name, what the
map shows and a Pi model (`PiModelPicker`; empty = Settings → Knowledge check model). Run makes one
`ModelCall` (`KnowledgeMapDrawer`, AKitLab): `pi -p --mode json --no-session --offline --no-tools
--no-skills --no-context-files --no-prompt-templates`, so Pi has no shell and runs nothing. The
input is the person's words, the area and map names and the area's note names (all scrubbed); the
system prompt asks for excalidraw-cli's DSL (`[orders-api] -> "events" -> [billing]`, note names as
block labels) and a one-line reason as `{"dsl", "reason"}` (a fenced block is read too). The gate
checks the origin `.knowledgeBase` (it carries the note names), and the monthly limit and the send
log apply (purpose `kb-draw`): the log records exactly what was sent. AKit then draws the DSL itself
without a shell, through `ChildProcess` (Stop cancels it): `excalidraw-cli create --inline <DSL> -o
<tmp>/NAME.excalidraw` when `excalidraw-cli` is on the PATH, else `npx --yes
@swiftlysingh/excalidraw-cli create …` (AKit ships no Node; without either the sheet says so and
Run stays off). A DSL that is empty, longer than 20 000 characters or starts with `-` (it is one
argument) is refused. The draft goes to `propose(.map …)` in-process (author `pi`, the reason from
Pi); no `akit` subprocess. The sheet shows each step; on success the Inbox opens on the new
proposal. Pi without AKit, in the terminal, still draws as before: the `/akit` skill's recipe runs
excalidraw-cli and `akit kb propose --map` in Pi's own shell.

Accept (`kb accept ID [--yes]`, `planAccept` + `accept`): without `--yes` it prints the diff and
exits 0. With it: the commit queue is flushed (U2), the note is backed up to
`~/.akit/local/backups/knowledge/<world>/<yyyy-MM-dd'T'HHmmss.SSS>/areas/…` (0600), written,
the proposal file is deleted, and one commit holds the note (`Edit NOTE (accept proposal ID)` or
`Add note NOTE (…)`; plus `inbox/.gitkeep` for a base made before 5.1). A note changed since the
plan is refused; a failed commit puts the note and the proposal back. Reject (`kb reject ID
[--yes]`) moves the file to the Trash; there is nothing to commit.

## Screen

Knowledge (sidebar): spaces on the left, tabs of maps in the middle (Excalidraw), the note
panel on the right with **Open in Obsidian**; **Inbox** and **Lint** as tabs of the screen.

## Steps

| Step | What | Built |
|---|---|---|
| 1 | Base folder + git without remote; Knowledge screen: spaces, note list, note panel (read and edit), **Open in Obsidian** | 2026-10-24: `AKitKnowledge` (base, notes, links, `KnowledgeGit`, `KnowledgeCommitQueue`), `akit kb areas/notes/init/new-note`, the Knowledge screen with New Area…, New Note…, Delete…, Edit, Copy, Paste; batch commits on tab close, after 5 min, at quit and rebuild |
| 2 | Excalidraw in the app, offline: map tabs, block ↔ `[[note]]`, jump to another map, relations from arrows | 2026-10-24: the bundle and `MapCanvasView` (2.0), `ExcalidrawFile`, `MapGraph`, `akit kb maps/relations/new-map` (2.1), the map view (2.2a), Edit with checked saves and Changed on disk (2.2b), map tabs, drag a note onto a map, Relations, `KnowledgeRename` and `akit kb rename` (2.3) |
| 3 | SQLite index (FTS + graph); `akit kb search / show / neighbors / context --json`; the Pi template in the core layer; the `/akit` skill | 2026-10-24/25, done (3.2a, 3.2b, 3.3, 3.4): (3.2a) `KnowledgeIndex` (`<base>/.akit-index.sqlite`: files, notes, nodes, edges, chunks + FTS5; schema version with "Update akit"; incremental refresh under `.akit-index.lock`, `stale` when busy), `Budget` (tokens ≈ bytes / 4), `.akit-misses.log`, `akit kb search / show / index`; (3.2b) focus of a folder (`focus.json` override, then the first area whose `area.yaml` `projects:` names its remote, `~/` path or glob, then the area of a note whose `repo:` is its remote or `~/` path; remotes through `ProjectRecords.normalizedRemote`), `akit kb neighbors NOTE [--depth 1; (3.4, K16) the Pi template: `templates/kb-pi.md` in the core layer, listed as `{template: kb-pi.md, to: AGENTS.md, when: target == pi}` through `LayerEditor.addingFile` (read-back verify, one brain commit), so `akit apply --home` writes it only into Pi's AGENTS.md, never `~/.claude/CLAUDE.md`; `akit kb pi-template [--yes] [--json]` (person only; commits the base's pending edits first; a second run says "already set") and Knowledge → Pi Template… with its own preview, then Update Home Folder… |2]`, `akit kb context [FOLDER]` (the focus area's notes with title and one line, the arrows touching them, their neighbours in other areas; ≤ 4000 tokens, `truncated`), `akit kb focus [FOLDER] [--set AREA \| --clear]` (person only); (3.3) the search field in Knowledge (hits by section, a click opens the note at that section), the index line (notes, sections, stale) with Reindex, `KnowledgeWatcher` + `WatchFilter` (outside edits reindexed within about a second and joined to the batch commit; inbox/ only counted; an open note or map changed outside asks Reload / Keep Mine), Focus… and Preview Agent Context… (exactly `akit kb context`, with its tokens) |
| 4 | Lint: block without a note, unbound arrow, broken repo/file references | 2026-10-24 (4.1): `KnowledgeLint` with errors (broken link, map that doesn't parse), warnings (ambiguous link, block without a note, unbound arrow, `repo:` not a known project, `files:` path missing in the local copy, `~/` path missing) and hints (kind not in `kb.yaml`, K24; a block of an unrelated area, R-SEP: no map of one area jumps to one of the other). Known projects: `origin` remotes of the repos in the projects root (and one folder below), the project stores' ids, the areas' `area.yaml` remotes, all through `normalizedRemote`. `akit kb lint [--json]` (`{base, findings, counts}`), the Lint tab (Open, Create Note…, Check Again), Checks and grey links in the note panel; the seed's area `lint-examples` has one finding per rule |
| 5 | `akit kb propose`, Inbox, the light-model check, Accept / Reject with a commit | 2026-10-25 (5.1): `KnowledgeInbox` (`KnowledgeProposal` file format, checks without a model, `planAccept`/`accept` with a backup and one commit, `reject` to the Trash), `inbox/.gitkeep` in new bases, `akit kb propose / inbox / accept / reject`, seed v5 with a note and an arrow proposal; see [Proposals](#proposals). 5.2: the check model (`KnowledgeCheck`, `kb check`, `kb check-model`, Settings → Knowledge check model, `SendOrigin.knowledgeBase`, purpose `kb-check`, marks in `inbox/.<id>.check.json`, seed v6). 5.3: the Inbox tab (the list with checks and marks, the diff, Accept…, Reject…, Check Again through `KnowledgeChecker`, an arrow drawn on its map with "Add an arrow?" and closed by `closeArrow`, the badge Inbox (N)). 5.4: agent-drawn maps (`kb propose --map`, the draft beside its proposal, `planMap` / `acceptMap`, the draft's preview, Accept… with links set on the canvas and Save Map, Draw Map with Pi… through `KnowledgeMapDrawer`, purpose `kb-draw`, seed v7): step 5 is done |
| 6 | AKit Review reads the base (K18) | 2026-10-25 (6.1): `AKitReview → AKitKnowledge`; Gather refreshes the base's index, maps the change to systems (the repository's remote through `normalizedRemote` → areas by `area.yaml` `projects:` and notes' `repo:`; notes whose `files:` names a changed path, as a file or a folder, come first), and writes `context/knowledge-card.md` (`ReviewKnowledgeCard`): an untrusted-text header, systems with one line each, relations `A -kind-> B`, neighbours one arrow away; scrubbed with the pack, within `knowledge_budget` (default 8000 tokens; cut from the end, marked, a context gap). A `knowledge:` folder that is a base gives only its card (no notes, no `inbox/`). Profile `knowledge_base:` (a world or a path, `KnowledgeBase.choose`) and `knowledge_budget:`; Review Settings… → Knowledge base (Picker of this Mac's bases, None) and Knowledge budget, Save Knowledge… with a diff; `akit review … --knowledge-base WORLD\|PATH --knowledge-budget N`. 6.2: the review extension v13 (v8 on the branch) registers `akit_kb_search` (query, area, limit ≤ 10) and `akit_kb_show` (note, section) in the review passes only when AKit sets `AKIT_REVIEW_AKIT` (an absolute, executable akit: this process, else the one on the search paths) and `AKIT_REVIEW_KB_BASE` (the base Gather used, `knowledgeBasePath` in `run.json`); each call is `execFile` of `akit kb search\|show … --json --scrub --max-tokens 4000 --base B` (no shell, 20 s, 64 KB), saved in `mcp/calls/` with the server `akit-kb` (the run log). `--scrub` masks the answer with the pack's scrubber and the Lab patterns. Without the two variables the tools Pi declares are exactly v12's (a test hashes them). Step 6 done |
| 7 | Embeddings with a local model, if FTS misses (K17) | — |

## Open

- Where `akit kb context` looks for the base when a Mac has more than one. (K16's words were
  chosen in 3.4, 2026-10-25: "## Knowledge base" and two lines, in `KnowledgePiTemplate.text`;
  the user can change them in the brain, `layers/core/templates/kb-pi.md`, though a later
  `akit kb pi-template` writes AKit's text back.)
- How AKit reads and writes the file it edits (steps 2.1 and 2.2b). The bundle is settled: see
  [Spike 2.0 results](#spike-20-results).

## Spike 2.0 results

Run 2026-10-24 in the app's own web view (`MapCanvasView`, debug snapshot
`--section knowledge --tab map --query <file.excalidraw>` on a made-up home); the page posted
its findings through the `kb` message handler to stdout. A1 works, so the A1′ try (0.18 ESM
through an import map) was skipped.

**Bundle.** `tools/fetch-excalidraw.sh` takes `@excalidraw/excalidraw@0.17.6`, `react@18.3.1`
and `react-dom@18.3.1` from registry.npmjs.org, checks each tarball against a pinned SHA-256
and against npm's `dist.integrity`, and keeps the production UMD files, Excalidraw's
`excalidraw-assets/` (5 fonts, the vendor chunk it loads at start, the ru-RU locale; English is
built in) and the licenses: 16 files, 4.4 MB (4,559,653 bytes), in `web/excalidraw/vendor/`.
The vendor chunk (2.9 MB) is not optional: the bundle imports it at load. The npm tarball of
Excalidraw has no LICENSE file; the script writes the repository's MIT text. The app bundles
`web/excalidraw` as `AKit.app/Contents/Resources/excalidraw/`, served as `akit-web://app/…`.
`EXCALIDRAW_ASSET_PATH` is `akit-web://app/vendor/` (Excalidraw appends `excalidraw-assets/…`).

| # | Question | Answer | Evidence |
|---|---|---|---|
| 1 | Does `[[note]]` survive 0.17.6's link editor? | **Yes**, so no fallback is needed (`akit:note/…` also survives) | The editor and the open path run `normalizeLink`: trim, `"` → `&quot;`, then `sanitizeUrl`, which only rewrites `javascript:`, `data:` and `vbscript:` schemes. Typed into the editor (⌘K, Enter): `[[billing#Invoices\|Billing]]`, `[[payments/billing]]`, `akit:note/payments/billing` were stored unchanged; `link` fields set in the file survive `restore` and `serializeAsJSON` |
| 2 | Can `onLinkOpen` call `preventDefault` and post to Swift? | **Yes** | Each open posted `{type: "linkOpen", link, elementId, elementType}` (e.g. `[[order-to-billing]]` from the arrow `arr-events`); `window.open` was called 0 times, the page stayed at `akit-web://app/index.html`, 0 navigations were cancelled |
| 3 | Do fonts load offline? | **Yes** | The scheme handler served only `akit-web://app/…` files (page, scripts, the vendor chunk, `Assistant-*.woff2`, `Virgil.woff2` once text is drawn); `document.fonts` shows them `loaded`. WebKit lists no `performance` resource entries for a custom scheme, so the served list comes from the handler. `fetch("https://example.com/")` fails twice over: CSP `connect-src` and, with the CSP relaxed to `*`, the content rule list. Refused: `%2e%2e` paths, `..%2f`, a missing file, another host (4 of 4). Once, right after a fresh build, Assistant 500/700 reported `error` at the first check and `loaded` later; a font answer delayed 2–3 s reproduces the `error` |
| 4 | How does a user open a link? | **Edit mode: the link icon** at the element's top-right corner (cursor turns to a hand), or the link in the popup of a **selected** element. A click on the block only selects it. **View mode** (`viewModeEnabled`): a click anywhere on the block or arrow opens it | Synthetic pointer events: icon → 1 `linkOpen`; block centre → 0 (selected); popup anchor click → 1; view mode block centre → 1, arrow middle → 1. In the code: `isPointHittingLink` is false for a selected element, true on the whole element in view mode, else only on the icon |
| 5 | Which CSP do the workers need? | **None**: no worker starts. The smallest policy that works: `default-src akit-web:; img-src akit-web: data:; style-src akit-web: 'unsafe-inline'` | The main bundle has no `new Worker`; the vendor chunk's three (pica, image compression via `data:`/`blob:`) serve image import, which is off. Without `img-src data:`: "img-src blocked data" (cursors, icons). Without `style-src 'unsafe-inline'`: 220 violations and no fonts (Excalidraw injects `<style>`). Scripts need no `'unsafe-inline'`: the page has no inline script. The policy is sent as a response header by the scheme handler |
| 6 | Do drafts from `@swiftlysingh/excalidraw-cli` 1.5.0 (MIT) work in 0.17.6? | **They load, with gaps** | A DSL draft (`[Orders API] -> "events" -> [Billing]`) and a JSON one (`{nodes, edges}`): both `restore` and draw. Arrows are bound at both ends (`startBinding`/`endBinding.elementId`), the edge label is bound text (`containerId` = the arrow). Node labels are **free text**, not bound to their box (`containerId` null; the box's `boundElements` lists only the arrow). Ids from JSON input survive (`blk-orders`); DSL ids are random. The file says `version: 2`, `source: "https://github.com/swiftlysingh/excalidraw-cli"`. It is written for a newer Excalidraw: `fontFamily: 5` (Excalifont, unknown to 0.17.6, drawn in a fallback font), bindings with `mode`/`fixedPoint` and no `gap`, `index`, `elbowed`, `autoResize` (the last three dropped by 0.17.6's `restore`). A `link` in JSON input is dropped. So 2.1 must name a block by its own `link` or by overlapping text, and a draft gets its links after import |

Fixtures for 2.1 (made in the running canvas with `convertToExcalidrawElements` and saved with
`serializeAsJSON(…, "local")`, so `source` is `akit-web://app`) are in
`AKitCore/Tests/AKitKnowledgeTests/Fixtures/`: `base/areas/payments/maps/overview.excalidraw`
(blocks `blk-orders` `[[orders-api]]` and `blk-billing` `[[billing]]` with bound labels; arrow
`arr-events` bound at both ends, label "events", link `[[order-to-billing]]`; the unbound arrow
`arr-loose`; `blk-detail` linking `[[maps/billing-detail]]`), `…/maps/billing-detail.excalidraw`
(the same notes as `[[payments/orders-api]]` and `[[billing]]`, arrow `arr-invoices` labelled
"invoice requests", a block without a link, a link back to `[[maps/overview]]`), the three notes
from the demo base, and `cli-draft.excalidraw` (the raw JSON draft). The fixture base has no
`.git`, which can't be committed inside this repo. Decided in 2.1: the read commands accept
`--base PATH` for a folder with `areas/` and no git (`KnowledgeBase.isReadable`); every write
still needs a base with git (`isBase`) and is refused there.

How 2.2a shows a map: a click in the list's Maps opens it in place of the note panel, in view mode
(`viewModeEnabled`, from `window.akitOptions`, which AKit sets with a user script before the page's
scripts). Excalidraw opens a link on a click anywhere on the element only when its canvas is at least
730 px wide; narrower, it counts as a phone and opens links only from the small link icon. So in view
mode the bridge finds the clicked element itself (the topmost element with a link whose box holds the
point, shapes before arrows; a drag of more than 4 px is a pan) and posts `linkOpen`; Excalidraw's
own `onLinkOpen` is only prevented. A note link opens that note beside the map, a map link that map,
an `http(s)` link the default browser. A synthetic AppKit click does not reach a web view, so
snapshots (`--click` on the canvas) send pointer events into the page (`akitClick`).

How 2.2b saves a map: in Edit the bridge posts one `serializeAsJSON(…, "local")` string 800 ms after
the last change, only when its hash differs from the last one posted, with the map id it was loaded
under (a change still waiting when another map loads goes out under its own id). A load hashes its
own serialization (again 100 ms later, once Excalidraw has applied the app state) without posting,
so opening never dirties a map (N4). Swift writes those bytes with
`KnowledgeWrite.saveChecked`: only while the file still hashes to what AKit read or last wrote,
else "Changed on disk: Reload / Keep Mine" (Keep Mine backs up the disk copy with `Backup.save`).
Saved maps join the commit queue ("Edit maps: …"). Close Map, a base switch, the quit flush and the
Update flush first take the change still waiting (`akitTakeUnsaved`, the N5 routine). Found on the
way: `NSApp.terminate` called from a main-actor task hangs, because `.terminateLater` waits in a
nested event loop for the flush, which needs the main actor; Update now terminates from the run
loop (`perform(_:with:afterDelay:)`).

How 2.3 renames (`KnowledgeRename.swift`, R3): every `[[…]]` and `akit:note|map/…` token in the notes
and every JSON `"link"` string value in the maps that resolves to the old id gets a new value with its
alias, `#heading`, extension and form kept and its path as long as before when that still resolves
(else the full id). Every link in the base is resolved before and after on the planned contents; only
the planned ones may change target, and each changed map must parse to the expected (element id,
target) pairs. A refusal throws with the planned diff; `apply` flushes the queue, checks no file
changed since the plan, writes (putting back what it wrote on failure), moves the file and commits
once ("Rename note A to B, N links in M files"). NEW is a name in the same folder, or for a note
area/name (not into a `maps/` folder). In the app the open map force-posts first ("Save the open map
first" when that fails), the rename is planned again on the saved files, and open tabs follow.
A dragged note becomes a rectangle with its title as the bound label and the shortest link that
resolves to it from the map (`akitAddLinkedBlock`); the web view gives up its own drop types so
SwiftUI's drop destination gets the drag. Relations come from `MapGraph.relations(of:)`.

How 2.1 reads a map (`ExcalidrawFile`, `MapGraph`): a block is a live shape whose `link`
resolves to a note (P1, from the map's path); its label is its bound text or, in a CLI draft,
the free text whose centre lies inside it. An arrow bound at both ends to blocks is an edge
(kind = its bound label, flow = the note its own link names); any other arrow, also one bound
to a shape without a note, is listed as unbound. A shape linking a map is a jump. A file that
isn't a JSON scene is listed with its error, never thrown. The maps of the sample base come
from `KnowledgeSeed` (not from `tools/demo-home.sh`, as 2.3 first planned).
