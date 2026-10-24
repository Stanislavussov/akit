# Knowledge base: maps of systems and notes an agent can search

Status: designed 2026-10-24 (grilling with the user); nothing built yet. Steps in [Steps](#steps).
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
| K11 | Git | The base is a local git repository **without a remote**. AKit commits each accepted change. On a work Mac the base never goes into the personal brain |
| K12 | References | `repo:` is the git remote URL when the repository has one, else a `~/` path; AKit finds the local copy among its projects. `files:` are paths inside the repository. Files outside git use `~/` paths. Missing → grey link and a lint finding |
| K13 | Agent access | `akit kb context / search / show / neighbors --json`; the `/akit` skill teaches them. No MCP server. A retrieval subagent on a small model is a harness matter: AKit may ship its template in a brain layer, the harness runs it |
| K14 | Agent writes | Only proposals: `akit kb propose` puts a change into `inbox/`. A light model checks it (duplicate, contradiction with a map, broken `[[link]]`) and only marks it; checks without a model (secrets, broken links) block at once. Accept / Reject is always the user's; Accept writes and commits. The agent never edits maps; it proposes an arrow in text ("Add an arrow?") |
| K15 | Checker model | A setting with a Picker (like Settings → Translation model). The user's choice for the work Mac: GPT-6 Luna, run through Pi |
| K16 | Context in a session | Only a template, once per Mac, for **Pi only** (no Claude Code): the core layer's AGENTS.md block in the file Pi reads in `~/.pi/agent`, through `akit apply --home`. 3–4 lines: there is a base, run `akit kb context` at the start of a task about systems, then `akit kb search`. Project files are never written; `akit kb context` works out the focus from the folder |
| K17 | RAG | Yes, in two steps. v1: SQLite FTS5 + the graph of the maps (a hit brings its neighbours). Embeddings later, only with a local model (no work text leaves the Mac), when keyword search misses. This lifts `review.md`'s "no embeddings" for the knowledge base only, at that step |
| K18 | AKit Review | Yes, the user wants it (2026-10-24), as step 6. Gather adds only a **card** of the systems an MR touches and their neighbours (names, one line each, relations), within the profile's `knowledge_budget` (8 000 tokens by default; the user found 1 500 too small); the roles get `akit_kb_search` / `akit_kb_show` for the rest. The profile field `knowledge:` keeps working |
| K19 | Token budget | The point of the RAG is to send little. `akit kb context`: a card, 4 000 tokens at most by default. `search`: the 10 best chunks (one chunk = one `##` section of a note), snippets first. `show`: a whole note only when the agent asks for it. Each command takes `--max-tokens`. The defaults are a first guess; tune them from real Review logs |
| K20 | RAG engine | All in one SQLite file: FTS5 with BM25 for words, `nodes` / `edges` tables for the graph, and (step 7) one vector BLOB per chunk with cosine similarity in Swift (Accelerate), no extension: macOS's system SQLite can't load `sqlite-vec` (checked 2026-10-24 on macOS 15.6.1: SQLite 3.43.2 is built with `OMIT_LOAD_EXTENSION`, the SDK header has no `sqlite3_load_extension`; `ENABLE_FTS5` is on and an FTS5 table with `bm25()` works). Embeddings from a local model (`NLContextualEmbedding` or Ollama) |

## Layout

```
~/.akit/local/knowledge/work/          (work Mac; one folder = one base, git without remote)
├── areas/
│   ├── payments/
│   │   ├── orders-api.md               note of a system
│   │   ├── billing.md
│   │   ├── flows/order-to-billing.md   note of an arrow
│   │   └── maps/overview.excalidraw    a tab of the "payments" space
│   └── logistics/ …
├── inbox/                               agent proposals waiting for Accept / Reject
└── .akit-index.sqlite                   index, rebuildable, git-ignored
```

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

## Screen

Knowledge (sidebar): spaces on the left, tabs of maps in the middle (Excalidraw), the note
panel on the right with **Open in Obsidian**; **Inbox** and **Lint** as tabs of the screen.

## Steps

| Step | What | Built |
|---|---|---|
| 1 | Base folder + git without remote; Knowledge screen: spaces, note list, note panel (read and edit), **Open in Obsidian** | — |
| 2 | Excalidraw in the app, offline: map tabs, block ↔ `[[note]]`, jump to another map, relations from arrows | — |
| 3 | SQLite index (FTS + graph); `akit kb search / show / neighbors / context --json`; the Pi template in the core layer; the `/akit` skill | — |
| 4 | Lint: block without a note, unbound arrow, broken repo/file references | — |
| 5 | `akit kb propose`, Inbox, the light-model check, Accept / Reject with a commit | — |
| 6 | AKit Review reads the base (K18) | — |
| 7 | Embeddings with a local model, if FTS misses (K17) | — |

## Open

- The exact word in K16's Pi block, and where `akit kb context` looks for the base when a
  Mac has more than one.
- How Excalidraw is bundled (a prebuilt web bundle in the app resources) and how AKit
  reads and writes the file it edits.
