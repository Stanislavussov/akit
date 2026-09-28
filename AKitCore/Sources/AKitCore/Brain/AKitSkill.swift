/// The `/akit` skill every new brain starts with: `skills/akit/SKILL.md`, manual in the
/// core layer, so agents can create layers and set up projects through the `akit` command.
enum AKitSkill {
    static let text = #"""
---
name: akit
description: Create or edit harness layers in the AKit brain (~/.akit/registry) and set up a project's harness from them with the akit command. Use when the user asks to make or change a layer, add skills or fields to one, or set up / re-render a project's AGENTS.md and skills.
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
akit answers [PROJECT]          # saved answers of a project
akit plan  [PROJECT] [ANSWERS]  # every change with a diff; never writes
akit apply [PROJECT] [ANSWERS] [--include PATH]
# ANSWERS: --layers a,b  --set field=value (repeat)  --unset field  --targets claude,pi
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
they are backed up). Run it after changing the core layer.

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

## Rules

- Never put secrets in fields, templates or skills.
- Never edit `projects/*/answers.json` or `lock.json` by hand; akit writes them.
- On a work Mac (`akit machine` says so) answers and locks stay in `~/.akit/local/projects`;
  never copy them, project names or work details into the brain.
- Never delete skills or layers without asking; prefer changing a layer over copying it.
"""#
}
