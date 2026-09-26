# Layers: per-project harness setup

Status: design agreed 2026-09-25. Steps 2 (brain) and 3 (project form + render) are implemented.

## Goal

Get a task (for example a take-home assignment), and in a few minutes render a
harness for exactly that project: only the skills and rules it needs, nothing
extra loaded into the agent's context.

Flow:

1. Optional: run `/akit-setup` in the project. The agent reads the task, asks
   what is missing and writes a draft of answers.
2. AKit shows the project form, prefilled from the draft (or empty).
3. You pick layers, fill fields, review the diff and press Apply.
4. AKit renders harness files into the project. You commit them.

## Terms

- **Brain repo**: your own private git repo with the skill library, layers and
  project metadata. Lives in `~/.akit/registry` (changeable in Settings). No
  harness reads it. It is private because `projects/` holds project URLs and
  answers; a public skills marketplace, if any, is a separate repo.
- **Layer**: a composable piece of setup (`base`, `backend-node`, `docker`,
  `take-home`, …). Brings skills, questions (fields) and file templates.
- **Answers**: chosen layers and field values for one project.
- **Render**: turning layers + answers into harness files in the project.
- **Core layer**: the layer applied to the home folder instead of a project.
  It is the only "global" setup.

AKit has no built-in layers. Every layer is a folder in the brain repo, so a
new layer never needs an app change.

## Brain repo layout

```
brain/
  skills/<name>/SKILL.md       # skill library (may contain {{fields}})
  layers/<name>/
    layer.yaml                 # manifest, see below
    templates/                 # files rendered into the project
  projects/<id>/
    answers.json               # layers + field values
    lock.json                  # brain commit each file was rendered from
  machines/<name>.yaml         # which harnesses and core layer per machine
```

Project `<id>` is the `origin` remote as `host/owner/repo` (lowercase, no
credentials, no `.git`), e.g. `projects/github.com/me/app/`. Projects without a
remote use `local/<path relative to the projects root>`; a folder outside the
root gets `local/<name>-<short hash of its path>`.

### Work machines (decided 2026-09-26, not implemented)

A machine can be marked **work** (per-machine setting, not in the brain). A work
machine must not push anything about work projects to the brain's remote:
project ids, paths, answers and locks name the employer's repos.

- On a work machine `projects/<id>/` lives in `~/.akit/local/projects/<id>/` (same
  format), outside the brain's git. Plan, apply and updates work the same.
- The `home` entry uses a pseudonym chosen by the user (e.g. `work`), never the hostname.
- Skills and layers still come from the brain; the only things a work machine
  commits to it are skill and layer edits the user makes on purpose.
- Masking is not enough: it hides tokens, not repo names, paths or field text.

## layer.yaml

```yaml
name: take-home
description: Take-home assignment for a job application
requires: [base]          # rendered after these; must be selected too
conflicts: []             # cannot be selected together with these

fields:
  - id: company
    prompt: Company name
    type: text            # text | choice | bool | multi
    required: true
  - id: deadline
    prompt: Deadline
    type: text
  - id: reviewer_readme
    prompt: Write a README for the reviewer?
    type: bool
    default: true

skills:
  - name: grilling        # from brain/skills/
    mode: manual          # auto | manual | off
  - name: tdd
    mode: auto

files:
  - template: AGENTS.md.d/take-home.md
    to: AGENTS.md         # fragment, glued with other layers
  - template: REVIEW.md
    to: REVIEW.md
    when: reviewer_readme == true
```

`choice` and `multi` fields add `options: [...]`. A skill may be a bare name
(`skills: [tdd]`, mode `auto`); `to` defaults to the template path. Field ids use
letters, digits, `_` and `-`. An empty `layer.yaml` is a valid empty layer.
AKit reads it with Yams; mistakes are shown per layer, never silently dropped.

### Templates

- Only plain substitution: `{{company}}`. No loops or conditions inside files.
- Conditions only decide whether a whole file or skill is rendered: `when:`.
  A `when` is one comparison (`field == value`, `field != value`) or a bare
  field name (true when set). A list of `when` entries means all must match.
- Built-in fields: `project_name`, `target` (the chosen harnesses: `claude`, `pi`,
  `opencode`, `codex`; `target == claude` holds when claude is among them).
- An unanswered field is empty (`false` for bool, no items for multi).
- Skills fill `{{field}}` only in Markdown files; unknown names are left as is
  (a warning for templates).
- Fields never hold secrets. Secrets come from Keychain (see MCP below).

### Skill modes

- `auto`: description in the agent's context, the agent may invoke it.
- `manual`: hidden from context, runs only on explicit `/name`. Rendered as
  `disable-model-invocation: true` in the copy's frontmatter.
- `off`: not rendered.

The mode belongs to the layer, not the skill, so the same skill can be
`manual` in the core layer and `auto` in a project.

## What lands in the project

Only harness files. They are always committed. Nothing from AKit itself.

```
project/
  AGENTS.md                    # glued from layer fragments
  .agents/skills/<name>/       # read by Pi, OpenCode, Codex
  CLAUDE.md                    # "@AGENTS.md", only if Claude is a target
  .claude/skills -> ../.agents/skills   # symlink, only if Claude is a target
```

Targets (harnesses) are a project field, multi-select, default from the machine
profile. Differences per harness go through `when: target == "claude"`.

## Several layers, one file

- Markdown (any `.md` target, e.g. `AGENTS.md`): each layer adds a section;
  sections are glued in layer order (`requires` first, then selection order).
- JSON (later: `.mcp.json`, settings): deep merge of keys. Two layers setting the
  same key to different values is an error, shown in the form before Apply.
- Whole files and skills: two layers bringing the same path is an error, unless
  one of them sets `override: true` (that one wins; `mode: off` + override drops
  a skill). Output paths must be unique and never inside `.git`.

## Apply (implemented)

Brain → Set Up Project… shows the form (the core layer is not offered; it is for
the home folder), then every change with a diff. Files AKit didn't write, and
files edited by hand since the last render, start unticked. Apply backs up what
it replaces in `~/.akit/backups/`, moves files only an earlier render wrote to the
Trash (not when edited since), refuses if the project changed after the preview,
and commits `projects/<id>/` in the brain. A real `.claude/skills` folder with
files blocks Apply until its skills move to the brain or `.agents/skills`.

## Updates

`lock.json` stores the brain commit each file was rendered from. On update:

- base = old template commit + answers, rendered again;
- ours = the file in the project (maybe edited by hand);
- theirs = new template + answers.

AKit runs `git merge-file` and shows the result in the diff viewer. A useful
hand edit can be published back to the template. A single file can be detached
so it is never updated again.

## Agent draft

`/akit-setup` is a `manual` skill in the core layer. It reads
`~/.akit/registry/layers/*/layer.yaml`, asks about missing fields and writes
`.akit/draft.json` in the project (hidden via `.git/info/exclude`). The draft has
the answers format plus a short reason per chosen layer. AKit sees the file,
opens the prefilled form, and after Apply moves the answers to the brain repo
and deletes the draft. The form works without the agent.

## MCP (step after v1)

Layers may bring MCP servers, merged into `.mcp.json`. Secrets are written only
as `${VAR}` references; the real values come from Keychain.

## Roadmap

1. Safe write: backup + diff viewer + Apply. (Done for MCP; to be shared with render.)
2. Brain repo + layers read-only in AKit (done: Brain screen, checks, Create Brain Repo); move the global skill library from
   `~/.agents/skills` into the brain; core layer with `manual` skills.
3. Project form + render of skills and `AGENTS.md` (+ Claude shims), answers and
   lock in the brain. The take-home flow works end to end. (Done.)
4. MCP in layers.
5. `/akit-setup` agent draft.
6. Updates: 3-way merge + publish back.

## Open questions

- Manual-only mode for OpenCode and Codex: equivalent of
  `disable-model-invocation` not verified yet.
- Pi has no native MCP (only via `pi-mcp-adapter`).
- Subagents in layers: low priority, format stays open for them.
- Rendering the core layer into the home folder (then the old `~/.agents/skills`
  copies can go).
