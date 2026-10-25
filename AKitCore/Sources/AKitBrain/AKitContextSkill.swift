/// The `/akit-context` skill every new brain starts with: `skills/akit-context/SKILL.md`, auto in
/// the core layer, so an agent on any task finds the knowledge base and the notebook by itself.
/// Setting AKit up is the manual `/akit` skill (AKitSkill).
enum AKitContextSkill {
    static let text = #"""
---
name: akit-context
description: Read the user's knowledge base of the systems around this repository (other services, events, repositories, who owns what) and propose additions; read the user's notebook of plans and to-dos, and add or tick a line when asked. Use at the start of a task that touches other services, events or repositories, when the user asks what a system does or who talks to whom, and when the user asks about their notebook.
---

# AKit: knowledge base and notebook

Two things on this Mac that help with a task, both read and written only through the `akit`
command (add `--json` and read the answer):

- the knowledge base: what the systems around the repository do and how they connect;
- the notebook: the user's plans, to-dos and "what I did today".

## Knowledge base

Notes and maps of the systems around a repository: which service sends what to whom, which
repo owns what. A base is a folder per world (by default `~/.akit/local/knowledge/<world>`, or
the folder `akit kb path` sets, like one in an Obsidian vault; git without a remote);
`areas/<area>/` holds the notes, one area per project, system or unrelated entity.
Read it when a task is about systems. Start with the card of the project's focus area:

```
akit kb context [FOLDER] [--max-tokens N] [--json] [--base PATH|WORLD]
                                                   # run it at the start of a task about systems:
                                                   # {base, focus, systems: [{note, title, line,
                                                   # local}], relations: [{from, kind, to}],
                                                   # truncated}; local = the system's folder on
                                                   # this Mac (another repo, a local wiki): read
                                                   # its code or documents there when the task
                                                   # needs them; FOLDER defaults to the current
                                                   # project
akit kb neighbors NOTE [--depth 1|2] [--max-tokens N] [--json] [--base PATH|WORLD]
                                                   # the arrows to and from a note (depth 2: also
                                                   # its neighbours'): {note, edges: [{from, kind,
                                                   # to, flow, map}]}
akit kb focus [FOLDER] [--json]                    # the focus area and why: override (the user's
                                                   # choice), area.yaml or repo
akit kb areas [--json] [--base PATH|WORLD]         # the areas: note and map counts, and their
                                                   # settings (title, description, projects)
akit kb notes [AREA] [--json] [--base PATH|WORLD]  # notes: id (payments/orders-api), kind, title
akit kb kinds [--json] [--base PATH|WORLD]         # the kinds of notes and each kind's fields (kb.yaml)
akit kb area AREA [--json] [--base PATH|WORLD]     # one area's settings: projects = git remotes,
                                                   # ~/ paths or globs the area is about
akit kb maps [AREA] [--json] [--base PATH|WORLD]   # the maps (.excalidraw): blocks (shapes linked to
                                                   # a note), arrows, unbound arrows, jumps to maps
akit kb relations NOTE [--json] [--base PATH|WORLD]
                                                   # arrows to and from a note on every map:
                                                   # {from, kind, to, flow, map}; kind = the label
akit kb search QUERY [--area A] [--limit 10] [--max-tokens N] [--json] [--base PATH|WORLD]
                                                   # the best ## sections with every word:
                                                   # {note, heading, score, snippet, neighbors};
                                                   # score is BM25, lower is better
akit kb show NOTE [--section H] [--max-tokens N] [--json] [--base PATH|WORLD]
                                                   # one note: title, kind, repo, path, files,
                                                   # local (its folder on this Mac), sections
akit kb index [--rebuild] [--json] [--base PATH|WORLD]
                                                   # bring the search index up to the files
akit kb lint [--json] [--base PATH|WORLD]          # check the base: {base, findings: [{rule, severity,
                                                   # file, element, link, message, fix}], counts}
akit kb inbox [--json] [--base PATH|WORLD]         # the proposals waiting for the user: {base,
                                                   # proposals: [{id, kind, target, reason, created,
                                                   # checks: [{name, status, message}], modelCheck:
                                                   # {model, checked, stale, marks} or null}]}
akit kb check ID [--json] [--base PATH|WORLD]      # ask the user's check model whether a proposal
                                                   # repeats a note, contradicts a map arrow or has
                                                   # a broken link: one model call through Pi under
                                                   # the sending policy and the monthly limit (send
                                                   # log: kb-check). It only marks: {id, model,
                                                   # marks: [{kind, note, edge, link, message}]}
```

You never edit the base: you propose, and the user accepts or rejects in AKit. Propose when
you learn a fact a note lacks, find a system the base doesn't have, or see a relation no map
shows. Name the note as AREA/NAME (`kb context`'s focus or `kb areas` picks the area); for a
system unrelated to every area, propose a new area (`--note support/helpdesk`) rather than
mixing it into one. Say in `--reason` where the fact comes from. After a proposal, `kb check
ID` may mark a duplicate or a contradiction: tell the user (and propose a better change if you
have one); the marks never accept or reject anything.

```
akit kb propose --note AREA/NAME (--file F | --stdin) [--set KEY=VALUE]… [--reason T] [--json]
                                                   # existing note: the text is ## Heading blocks
                                                   # (each replaces that section or is added); new
                                                   # note: its whole text. --set: properties
                                                   # (kind=service, owner=team-a). Writes only
                                                   # inbox/<id>.md; refused for a secret, a broken
                                                   # [[link]], a path outside areas/.
                                                   # --json: {id, path, kind, target, checks}
akit kb propose --arrow "A -kind-> B" [--map MAP] [--reason T] [--json]
                                                   # a relation between two notes (kind = what
                                                   # flows); the user draws it on the map
akit kb propose --map AREA/NAME (--file F.excalidraw | --stdin) [--reason T] [--json]
                                                   # a map you drew: the draft goes to
                                                   # inbox/<id>.excalidraw; an existing map is
                                                   # replaced only when the user accepts; a new
                                                   # area is created then. Refused: a file that
                                                   # isn't an Excalidraw scene, a secret in its text.
                                                   # --json: {id, path, kind, target, checks, draft}
```

To draw a map, use excalidraw-cli (`npx --yes @swiftlysingh/excalidraw-cli` when
`excalidraw-cli` isn't installed; it needs Node 20.19 or later). Label each block with a note's
name exactly as `kb notes AREA` lists it, so AKit links the block to that note on Accept (a
label that names no note, or more than one, stays plain); name each arrow by what flows:

```
excalidraw-cli create --inline '[orders-api] -> "events" -> [billing]' -o /tmp/x.excalidraw
akit kb propose --map payments/order-flow --file /tmp/x.excalidraw --reason "orders-api sends its events to billing"
```

The user accepts or rejects the map in AKit (Knowledge → Inbox); `kb accept` of a map only
says so (exit 2). AKit's Draw Map with Pi… does the same with Pi given no tools: Pi writes
only the DSL, and AKit runs excalidraw-cli and proposes the draft itself.

Run `kb lint` before you trust a note's `repo:`/`files:` or a map's blocks, and after you
propose a change. Errors: a broken link, a map that doesn't parse. Warnings: an ambiguous link,
a map block with no note, an unbound arrow (no relation), a `repo:` that is no known project,
a `files:` or `~/` path that doesn't exist. Hints: a kind not in `kb.yaml`, a block for a note
of an unrelated area. Tell the user or propose a fix; never edit the base to fix them.

To find text, `kb search` first, then `kb show NOTE --section H` for the one section you
need; both stay under `--max-tokens` (default 4000). Search reads `areas/` only, never the
proposals in `inbox/`, and refreshes the index itself (`kb index` is rarely needed).
`"stale": true` means another process is updating the index: the answer is from its last
state.

The focus is where to start, never a wall: follow a relation or a link into another area
when the task needs it. `"focus": null` means no area names this project (its remote or
folder): look at `kb areas`, and when you propose a note for a new system, propose a new area
rather than mixing unrelated systems.

`--base` picks a base (a world name or a folder); without it akit takes the project's choice,
the only base, or the one named like this Mac's kind. No base: `{"base": null, "reason":
"no base"}`, exit 0; then there is nothing to read. Reads also take `--base PATH` for a folder
with `areas/` and no git. Kinds and fields are data in the base's `kb.yaml`, never a fixed
list: read `akit kb kinds` before you name a kind or a field. On maps, a block stands for the
note its link names, and an arrow's label says what flows (`kb relations orders-api`).

Commands that change the base (`kb init`, `set`, `rename`, `accept`, `reject`, `rm`, `path`,
`focus --set`, `area` with flags, `kinds add`, …) are for a person only and are in the `/akit` skill: run them only when the user
asked for that action in this session; otherwise propose or ask. Never accept or reject a
proposal on your own: the user decides.

## Notebook

The user's plans, to-dos and "what I did today", one Markdown file per tab in the base's
`notebook/` folder (the Notebook screen). Not knowledge about systems: `kb search` and
`kb context` leave it out. Read it when the user asks about their plans or tasks; write only when
the user asked ("add to my notebook", "tick that off").

```
akit notebook tabs [--json]                        # the tabs in order, open tasks each
akit notebook show TAB [--open] [--json]           # a tab's Markdown; --open: open tasks only
akit notebook add TAB TEXT [--task] [--today] [--json]
                                                   # one line at the top (after a # Title); --task:
                                                   # "- [ ] TEXT"; --today: under "## YYYY-MM-DD",
                                                   # made when missing. Committed at once
akit notebook done TAB TEXT [--json]               # ticks the first open task containing TEXT
```

Drawings (`![](drawings/NAME.excalidraw.svg)` in a tab) are made and changed in the app (Draw…, a
double click); the scene is `notebook/drawings/NAME.excalidraw`. Don't edit them by hand.

## Rules

- Write to the base only with `kb propose`, and to the notebook only when the user asked.
- Never put secrets (tokens, passwords, keys) in a proposal or a notebook line.
"""#
}
