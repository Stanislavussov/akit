/// The `/akit` skill every new brain starts with: `skills/akit/SKILL.md`, manual in the
/// core layer, so agents can create layers and set up projects through the `akit` command.
enum AKitSkill {
    static let text = #"""
---
name: akit
description: Create or edit harness layers in the AKit brain (~/.akit/registry) and set up a project's harness from them with the akit command. Use when the user asks to make or change a layer, add skills or fields to one, or set up / re-render a project's AGENTS.md and skills, and to set up the knowledge base (akit kb init, path, focus, accept, reject). Reading the base and the notebook is the akit-context skill.
---

# AKit: layers and project setup

The brain is a git repo at `~/.akit/registry` (no harness reads it):

```
skills/<name>/SKILL.md          skill library
layers/<name>/layer.yaml        a layer: fields, skills, files
layers/<name>/templates/        files rendered into a project
projects/<id>/answers.json      saved answers per project (written by akit, don't edit)
```

The `akit` command reads the brain and writes projects. Always go through it for projects;
edit brain files directly.

```sh
akit check                      # problems in layers/skills (exit 1 if any)
akit layers [--json]            # what exists: fields, skills, files per layer
akit skills                     # skills in the brain
akit sync                       # pull other Macs' brain commits, push this one's
akit doctor                     # when AKit doesn't behave, run this first: what it sees, what's wrong
akit doctor pi [--live] [--json] # when Pi misbehaves: install, settings, env, MCP, packages, skills, context
                                # (exit 1 on a problem); --live also connects MCP servers, checks sign-in;
                                # + lines: what recent Pi sessions say is extra, each with its akit command
akit instructions remove FILE (--line N | --section HEADING) [--yes]  # drop one section (a repeated one)
akit pi packages [install [SOURCE] | remove SOURCE] [--yes]  # Pi's packages; pi does the install
akit answers [PROJECT]          # saved answers of a project
akit plan  [PROJECT] [ANSWERS]  # every change with a diff; never writes
akit apply [PROJECT] [ANSWERS] [--include PATH]
# ANSWERS: --layers a,b  --set field=value (repeat)  --unset field  --targets claude,pi
#          --local-only yes|no|auto  (keep AKit's files out of git; auto: a work Mac yes)
akit worktrees [sync] [PROJECT] # a local-only project's files linked into its git worktrees
akit move skill NAME --to PROJECT  # a global skill into the projects that use it (see below)
```

## layer.yaml

```yaml
name: take-home                 # same as the folder
description: Take-home assignment for a job application
requires: [base]                # rendered first, always selected with this one
conflicts: []
fields:                         # questions; never secrets
  - id: company                 # letters, digits, _ and -
    prompt: Company name
    type: text                  # text | bool | choice | multi
    required: true
  - id: stack
    type: choice
    options: [node, swift]
    default: node
skills:
  - name: grilling              # must exist in skills/
    mode: manual                # auto: agent sees and uses it; manual: only /name; off
  - tdd                         # bare name = auto
files:
  - template: agents.md         # in templates/
    to: AGENTS.md               # .md targets from several layers are glued in layer order
  - template: REVIEW.md
    when: stack == node         # field == v, field != v, or a bare field (set/true); list = all
```

Templates use `{{field}}`, `{{project_name}}`, `{{target}}`. Claude gets `CLAUDE.md`
(`@AGENTS.md`) and `.claude/skills -> ../.agents/skills` automatically. The same skill or
non-Markdown file from two layers needs `override: true` on the one that wins.

## Create a layer

1. `akit layers` and `akit skills` to see what exists; reuse layers through `requires`.
2. Ask what the layer is for, which skills (auto or manual), what the project's AGENTS.md
   should say, and which questions differ per project (those become fields).
3. Write `layers/<name>/layer.yaml` and `templates/…`. Keep AGENTS.md sections short.
4. `akit check` until it reports no problems.
5. Show the user the files, then commit in the brain:
   `git -C ~/.akit/registry add layers/<name> && git -C ~/.akit/registry commit -m "Add layer <name>"`.

## Edit a layer

Read `layers/<name>/layer.yaml` and its templates, change them, `akit check`, commit
("Change layer <name>: …"). Projects pick the change up on their next `akit apply`.

## Set up or update a project

1. `akit answers <project>` (may be empty) and `akit layers --json`.
2. Read the project (README, task description) and ask only what's missing for the
   chosen layers' fields.
3. `akit plan <project> --layers … --set … --targets …` and show the user the result.
   ERROR/BLOCKED lines must be fixed first (a real `.claude/skills` folder has to move to
   `.agents/skills` or the brain).
4. Only after the user says yes: `akit apply` with the same arguments. Files AKit didn't
   write, or that were edited by hand, are skipped; pass `--include PATH` only when the
   user agrees to replace that file (there is a backup either way).
   AGENTS.md, CLAUDE.md and other layer templates are only a starting point: once the
   project edits one, it is the project's own, and a newer layer version shows as
   "LAYERS CHANGED" (taken only with `--include PATH`). Put project-specific rules
   straight into the project's AGENTS.md, not into a layer.
   Skills for one project: add them to the answers (`"skills": [{"name": "tdd",
   "mode": "auto"}]`; `"mode": "off"` drops a layer's skill here), or write a skill
   that lives only in the project in `.agents/skills/<name>/SKILL.md` (AKit never
   overwrites it).
5. Tell the user to review and commit the harness files in the project.

## Remove

Always run without `--yes` first and show the user what it says; add `--yes` after a yes.
Folders go to the Trash and each removal is one commit (then `akit sync`).

- A skill from a layer: `akit remove skill NAME --from LAYER`; re-apply the projects
  using that layer (`akit apply --home` for core).
- A skill from the brain: `akit remove skill NAME` (refused while a layer lists it).
- A layer: `akit remove layer NAME` (refused while other layers require it; it is dropped
  from saved project answers; re-apply those projects to take its files out).
- A project: `akit remove project [PROJECT|--home] [--keep-files]` trashes the files AKit
  wrote there (never hand-edited ones) and forgets the project in the brain.

## Home folder (core layer)

The core layer is rendered into `~` for every harness (`~/.agents/skills`, and
`~/.claude/skills` linked to it): `akit plan --home`, then after a yes
`akit apply --home` (`--include-unmanaged` to take over old copies AKit didn't write;
they are backed up). Run it after changing the core layer. The core layer's AGENTS.md
section goes into each harness's global instructions (`~/.claude/CLAUDE.md`, and the
file Pi reads in `~/.pi/agent`) as a block between `<!-- akit:core:start -->` and
`<!-- akit:core:end -->`; the text around it is the user's and stays.

## Sync between Macs

When the brain has a git remote (e.g. a private GitHub repo), run `akit sync` after
committing a change: it pulls the other Macs' commits (a conflict is undone and reported,
never forced) and pushes this Mac's. The app's Brain screen has the same Sync button. If
sync says the core layer changed, run `akit apply --home`. Uncommitted edits are never
synced; commit them first.

## Usage stats

`akit stats [--project ID|PATH | --all] [--days N] [--json]` reads the harness session logs
(imported into `~/.akit/index`): first-request context (recorded tokens) and which listed
skills take ≈ context space (tokens × requests) and how often the model or the user calls
them (`--details` for every skill). `akit stats changes [--project X|--all] [--json]`
compares first-request context before and after each `akit apply` and each
`akit stats mark "<note>" [--at DATE]` (a change made by hand, e.g. a plugin disabled; mark
it when the user makes one). Sizes marked ≈ are estimates; never talk about money.

## Recommendations

`akit recommend [--project ID|PATH | --all] [--details] [--json]` lists auto skills listed
in ≥ 20 sessions on ≥ 14 days that the model never called anywhere. Each entry has an id:

- `patch` (layer skill): `akit recommend apply ID` shows the layer.yaml change; after a yes,
  `--yes` commits it; then `akit plan`/`apply` the projects using the layer.
- `advice` (plugin, hand-installed, …): tell the user what it says; nothing to apply. A
  plugin (`skill` is `*`, its skills in `evidence.skills`) is enabled or disabled as a whole.
- `akit recommend dismiss ID [--yes]`: a layer skill gets `keep_auto: true` in layer.yaml
  (the rule skips it from then on); advice stays hidden until its ≈ context space doubles.

Show the user the recommendations and ask before `apply` or `dismiss` with `--yes`.

## Move a global skill into its projects

A global skill (core layer, or a folder in `~/.agents/skills`) that only one or two projects
use costs its description in every other session. `akit stats skill NAME [--days N] [--json]`
shows its calls per project (this Mac, unbound sessions, other Macs). Then:

```sh
akit move skill NAME --to PROJECT[,PROJECT…] [--mode auto|manual] [--local-only yes|no|auto] [--keep-global] [--keep-own]
```

It prints the plan: the brain import (library only), each project (its files, links into git
worktrees when local only), the core layer.yaml diff and the home folder's copies to the
Trash. Show it to the user; after a yes run it again with `--yes`. It stops before touching
core or the home folder when a project fails. Blocked lines: a project with its own copy
(`--keep-own` keeps it), a home copy edited by hand (bring the edits into `skills/NAME`
first), a claude.ai, plugin or Pi package skill (use `akit skills set` instead). For 3+
projects suggest a layer instead.

## MCP servers

When an MCP server doesn't work in Claude Code or Pi, ask the harness itself:

```
akit mcp check [NAME] [--harness claude|pi] [--project PATH]
```

It runs `claude mcp get NAME` / `claude mcp list` or `pi mcp list --json` in the server's
project (a global server in `--project` or the home folder), with the login shell's
environment. One line per server: Connected, Failed (with the harness's error), Missing
Variables (named), Needs Sign-In, Pending Approval, Untrusted Project, Off, Timed Out,
Not Found; Pi also counts the tools. Exit 1 when a checked server doesn't connect (Off is
fine). It starts the servers (npx, docker), so run it when asked, not in a loop.

- Missing Variables: the user stores the value (MCP Servers → Set Variable… in the app);
  never ask for or print the token.
- Needs Sign-In: `akit mcp login NAME --harness claude|pi [--project PATH]` shows what it
  runs; after a yes, `--yes` starts the harness's own sign-in (a browser; the harness keeps
  the credentials, akit never reads them).
- Pending Approval (a project's `.mcp.json` server in Claude Code):
  `akit mcp approve NAME --project PATH` shows the one key it adds
  (`enabledMcpjsonServers` of `.claude/settings.local.json`); after a yes, `--yes` writes it
  with a backup. Never show or read the rest of that file.
- Off without deleting: `akit mcp state [NAME]`, `akit mcp set NAME --harness claude|pi
  --off everywhere | --off project --project PATH | --on` (shows the change; `--yes` writes).
- Pi's tools cost too much context: `akit mcp set NAME --harness pi --exposure deferred`
  (also `direct`, `codemode` = Pi's default, `hidden`; shows the change; `--yes` writes).
  `akit doctor pi` suggests it for a direct server Pi rarely calls.

## Merge request review

`akit review map RUN [--json | --mermaid]` prints a review run's change map: the changed files
by module with their lines and worst finding, the unchanged files that import them, the
boundaries the change provides or uses (APIs, packages, events, infra, config) and the other
repositories that use them. Use it when the user asks what a merge request affects; `--json`
for the data, `--mermaid` for a `flowchart LR` to paste. It never posts anything.

`akit review MR-URL --impact auto|off|always` (also `akit review local`) says whether the review
looks for uses of the change in other GitLab repositories through the GitLab MCP server: `auto`
(default) when the brief found a boundary, `always`, or `off`. The kept uses are on the map and
in `context/consumers.md`; a use the change breaks becomes a `contracts` finding on the changed
line. Use `--impact off` for a quick review, `always` when the user asks what else a change breaks.

`akit review overview RUN [--json | --mermaid]` prints a review run's overview: 3–5 points on what
happens, the modules that change with their files and why (from the work item chain, the
description and the notes), where the why comes from, and the flow as Mermaid with the changed
parts marked and the other repositories added. Use it when the user asks what a merge request
does or why; `--json` for the data, `--mermaid` for the flow only. It is never posted.
`akit review MR-URL --summary-language CODE` (also `akit review local`; `summary_language` in
review.yaml or a profile's `review:`) sets the overview's language (`en`, `ru`, `cs`, …); the default
is the Mac's preferred language, else English. GitLab text keeps `posting: language`.
`akit review MR-URL --verifier-thinking LEVEL` (also `akit review local`; `thinking: verifier:` in
review.yaml) sets how hard the verifier model thinks: off, minimal, low, medium,
high, xhigh or max; alone it keeps the configured verifier model. The New Review sheet has the
same menu (Verifier thinking).

`akit review points [PATH] --find TEXT [--kind branches|tags|commits] [--json]` lists the branches, remote branches, tags and
commits of a local workspace whose name, commit message, author or id start holds every word of
TEXT (refs first, the most recent first; `--kind` keeps one kind). Use it when the user names a branch or a commit only
roughly, then review with `akit review local [PATH] --base NAME --head NAME`: `--head` ends the
range at another branch or commit than HEAD (without the uncommitted changes), e.g.
`--base v1.4.0 --head v1.5.0` for what a release added. In the app: New Review… → Local
Workspace → Find… next to Base and Head.

`akit review MR-URL MR-URL… [flags]` reviews several linked merge requests (a frontend and its
API in other repositories) as one change: the roles read every diff and check that the sides still
fit, the first sets the profile, scenario and roles, each finding goes to drafts in its own merge
request, and files of the others are named `@<project>/<path>`. `MR-URL@COMMIT` reports only on
lines changed after that commit of the merge request; without it the review starts at the merge
base. Use it when the user's change spans repositories, or asks to look only at the last commits.
In the app: New Review… → Merge requests, one address per line, a commit after an address.

## Knowledge base

Notes and maps of the systems around a repository: which service sends what to whom, which
repo owns what. A base is a folder per world (by default `~/.akit/local/knowledge/<world>`, or
the folder `akit kb path` sets, like one in an Obsidian vault; git without a remote);
`areas/<area>/` holds the notes, one area per project, system or unrelated entity.
Reading the base, proposing to it and the notebook (`akit notebook`) are in the
`/akit-context` skill; this part is about setting the base up.

A review (`akit review MR-URL` or `akit review local …`) reads a base only as a card,
`context/knowledge-card.md`: the systems the change touches (a note's `files:`), the rest of
the repository's areas, their relations and neighbours, within a token budget. The project
profile sets it (`knowledge_base: WORLD|PATH`, `knowledge_budget: N`, default 8000; Review
Settings… → Knowledge base); for one run add `--knowledge-base WORLD|PATH` and
`--knowledge-budget N` (`--gather-only` stops before the model passes).

Commands marked "for a person only" in `akit kb --help` change the base: run them only when
the user asked for that action in this session; otherwise propose (`akit kb propose`) or ask.
Never accept or reject a proposal on your own: the user decides. They commit at once, one
commit per command:

```
akit kb init [--world NAME]                        # create a base
akit kb new-note AREA NAME [--kind K]              # a new note
akit kb new-map AREA NAME                          # a new, empty map areas/AREA/maps/NAME.excalidraw
akit kb set NOTE KEY=VALUE… [--unset KEY]… [--json]
                                                   # note properties (kind=flow, owner=team-a,
                                                   # files=[a.ts, b.ts]); one frontmatter line each
akit kb kinds add NAME [--fields a,b] | fields NAME a,b | remove NAME | rename OLD NEW [--json]
                                                   # rename rewrites kind: in every note, all or nothing
akit kb area AREA [--title T] [--description D] [--project P]… [--remove-project P]… [--json]
akit kb path [WORLD] [--set PATH | --move PATH | --reset] [--json]
                                                   # where the world's base lives (this Mac only):
                                                   # --set uses a folder (an Obsidian vault too),
                                                   # --move commits pending edits and moves it,
                                                   # --reset goes back to ~/.akit/local/knowledge
akit kb focus [FOLDER] --set AREA | --clear [--json]
                                                   # the area a project starts from, kept on this
                                                   # Mac (~/.akit/local/knowledge/focus.json);
                                                   # --clear goes back to area.yaml and repo:
akit kb rename NOTE|MAP NEW [--yes] [--json]      # rename a note or map and every link to it,
                                                   # all or nothing, one commit; without --yes it
                                                   # only shows the plan (refused with its diff when
                                                   # another link would change its target)
akit kb accept ID [--yes] [--json]                 # accept a proposal: shows the diff; --yes backs
                                                   # the note up, writes it and commits it with the
                                                   # proposal's removal; an arrow or a map: exit 2,
                                                   # accepted in the app
akit kb reject ID [--yes] [--json]                 # a proposal to the Trash
akit kb check-model [MODEL [THINKING]] [--harness pi|claude-code]
                                                   # the check model of kb check: harness (default
                                                   # pi; each keeps its own model) and a model from
                                                   # that harness's list only (no MODEL: shows the
                                                   # list); default the GPT-6 Luna Pi lists, low
akit kb add-folder FOLDER --area AREA [--name N] [--description T] [--yes] [--json]
                                                   # a note for another repo (kind service, repo:
                                                   # its remote) or a folder without git (kind
                                                   # folder), path: the folder, the README's first
                                                   # line; without --yes it shows the note, --yes
                                                   # writes and commits it. Only when the user asked
                                                   # for it; otherwise propose the note
akit kb rm NOTE|MAP|AREA [--yes] [--json]          # a note, map or whole area to the Trash, one
                                                   # commit; without --yes it only shows what goes
akit kb pi-template [--yes] [--json]               # the core layer's section about the base, for Pi
                                                   # only (templates/kb-pi.md, a brain commit); then
                                                   # akit apply --home; again: "already set"
akit kb seed [--world NAME] [--json]               # the sample base (world sample): made-up notes
                                                   # that show every feature, separate from yours
akit kb seed --remove [--world NAME] [--yes] [--json]
                                                   # the whole sample base to the Trash
```

## Rules

- Never put secrets in fields, templates or skills.
- Never edit `projects/*/answers.json` or `lock.json` by hand; akit writes them.
- On a work Mac (`akit machine` says so) answers and locks stay in `~/.akit/local/projects`;
  never copy them, project names or work details into the brain.
- Never delete skills or layers without asking; prefer changing a layer over copying it.
"""#
}
