# Layers: per-project harness setup

Status: design, agreed 2026-09-25. Not implemented yet.

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

- **Brain repo**: your own git repo with the skill library, layers and project
  metadata. Cloned to `~/.akit/registry`. No harness reads it.
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

Project `<id>` is the git remote URL, normalized to a folder name. Projects
without a remote use their path relative to the projects root (`~/Projects`).

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

`choice` and `multi` fields add `options: [...]`.

### Templates

- Only plain substitution: `{{company}}`. No loops or conditions inside files.
- Conditions only decide whether a whole file or skill is rendered: `when:`.
  A `when` is one comparison (`field == value`, `field != value`) or a bare
  field name (true when set). A list of `when` entries means all must match.
- Built-in fields: `project_name`, `target` (harness being rendered for).
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

- Markdown (`AGENTS.md`): each layer adds a section; sections are glued in layer
  order (`requires` first, then selection order).
- JSON (later: `.mcp.json`, settings): deep merge of keys. Two layers setting the
  same key to different values is an error, shown in the form before Apply.
- Whole files and skills: two layers bringing the same path is an error, unless
  one of them sets `override: true`.

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

1. Safe write: backup + diff viewer + Apply.
2. Brain repo + layers read-only in AKit; move the global skill library from
   `~/.agents/skills` into the brain; core layer with `manual` skills.
3. Project form + render of skills and `AGENTS.md` (+ Claude shims), answers and
   lock in the brain. The take-home flow works end to end.
4. MCP in layers.
5. `/akit-setup` agent draft.
6. Updates: 3-way merge + publish back.

## Open questions

- Manual-only mode for OpenCode and Codex: equivalent of
  `disable-model-invocation` not verified yet.
- Pi has no native MCP (only via `pi-mcp-adapter`).
- Exact normalization of remote URLs into project ids.
- Subagents in layers: low priority, format stays open for them.
