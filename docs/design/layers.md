# Layers: per-project harness setup

Status: design agreed 2026-09-25. Roadmap steps 1–3 are implemented (see
[Roadmap](#roadmap) for the status of each step, checked against the code on 2026-10-03).
JSON merge built 2026-10-08 (see [JSON merge](#json-merge-built-2026-10-08)): layers can
bring MCP servers in `.mcp.json` and settings in `.claude/settings.json`.

Also built, though not roadmap steps: work machines, the "project owns its files" update
rules, `keep_auto`, `override`, the home folder render (`akit apply --home`, and in the app
**Update Home Folder…**), brain sync,
import of skills into the brain, the layer editor, and removing layers, skills and
projects. Not built: JSON merge into the home folder, MCP secrets from Keychain, the
`/akit-setup` draft, `machines/<name>.yaml`, `checks:`.

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
    lock.json                  # brain commit each file was rendered from; keys AKit
                               # merged into the project's JSON files (`json`)
    usage/<machine id>.json    # this project's skill use per day, one file per Mac
    dismissed.json             # recommendations dismissed for this project
  machines/<name>.yaml         # which harnesses and core layer per machine (not built: the
                               # folder is created, no code reads it)
  plugins/                     # local Claude marketplace with the akit plugin (session hook)
  insights/
    machines/<file>.json       # skill use per day per Mac (<id>, or <pseudonym> on a work Mac)
    dismissed.json             # global recommendations dismissed
```

On a work Mac the `projects/` files (answers, lock, usage, dismissed) live in the
local store, `~/.akit/local/projects/<id>/`, and never reach the brain.

Project `<id>` is the `origin` remote as `host/owner/repo` (lowercase, no
credentials, no `.git`), e.g. `projects/github.com/me/app/`. Projects without a
remote use `local/<path relative to the projects root>`; a folder outside the
root gets `local/<name>-<short hash of its path>`.

### Work machines (implemented 2026-09-26)

A machine can be marked **work** (per-machine setting, not in the brain). A work
machine must not push anything about work projects to the brain's remote:
project ids, paths, answers and locks name the employer's repos.

- The role is `~/.akit/machine.json` (`akit machine work|personal`, Settings → This Mac,
  `AKIT_MACHINE=work` in install.sh). `ProjectStore` picks the folder from it.
- On a work machine `projects/<id>/` lives in `~/.akit/local/projects/<id>/` (same
  format), outside the brain's git. Plan, apply, removals work the same; nothing is committed.
- The `home` entry uses a name chosen by the user (default `work`), not the host name.
  Switching copies this Mac's home record from the brain so `apply --home` still knows
  its files, and lists the records the brain already has; removing work ones from the
  brain (and its remote's history) is left to the user.
- Skills and layers still come from the brain; the only things a work machine
  commits to it are skill and layer edits the user makes on purpose, and its usage
  summary `insights/machines/<pseudonym>.json` (counts of brain skills per day, under a
  random pseudonym). `WorkFilter` checks that commit's paths, message and bytes and refuses
  without a brain `user.email` and `user.name` of its own; per-project summaries stay in the
  local store. `akit sync` rebases a work machine's commits with that identity too (never the
  environment's or a global signing key), and refuses to rebase without it.
- Fails closed: a `machine.json` that can't be read counts as work (with a warning);
  install.sh stops if `AKIT_MACHINE` can't be applied; Apply refuses a preview made
  before the role changed. The app asks before going from work back to personal.
- On a work Mac the brain's older records are read (never written) when the local
  store has none, so projects rendered before the switch keep their lock and answers.
- Skill and layer commits still happen on a work Mac; switching warns when the brain
  has no git identity of its own (the global one may be the work email).
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

Designed, not built: `checks:`, patterns that measure what the layer promises to improve,
used by layer evals (`layer-evals.md`, "Oracle and checks").

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
- A `.mcp.json` or `.claude/settings.json` template is parsed first and `{{field}}` is
  filled only inside its string values (see [JSON merge](#json-merge-built-2026-10-08)).
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

`keep_auto: true` on a skill entry pins it to `auto`: `akit recommend` never proposes
making it manual (`akit recommend dismiss` on a layer skill sets it). Older AKit
ignores the key.

## What lands in the project

Only harness files. They are always committed. Nothing from AKit itself.

```
project/
  AGENTS.md                    # glued from layer fragments
  .agents/skills/<name>/       # read by Pi, OpenCode, Codex
  CLAUDE.md                    # "@AGENTS.md", only if Claude is a target
  .claude/skills -> ../.agents/skills   # symlink, only if Claude is a target
  .mcp.json, .claude/settings.json      # only the layers' keys, merged into the project's file
```

Targets (harnesses) are a project field, multi-select, default from the machine
profile. Differences per harness go through `when: target == "claude"`.

## Several layers, one file

- Markdown (any `.md` target, e.g. `AGENTS.md`): each layer adds a section;
  sections are glued in layer order (`requires` first, then selection order).
- JSON (`.mcp.json` and `.claude/settings.json` only; built 2026-10-08):
  deep merge of keys. Two layers setting the same leaf to different values is an error,
  shown in the form before Apply, unless one sets `override: true`. The result is merged
  into the project's file key by key, see [JSON merge](#json-merge-built-2026-10-08).
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
files blocks Apply until its skills move to the brain or `.agents/skills`, and so does a
JSON file the layers merge into that is not valid JSON.

## Updates: layers are a skeleton, the project owns its files (decided 2026-09-28)

A layer is a shared starting point, not the owner of a project. Per project:

- AGENTS.md, CLAUDE.md and other template files are written when missing. While
  the project hasn't touched one, a new render updates it like before. Once the
  project edits it, it is the project's own: AKit never writes over it or removes
  it. When the layers' version changes, the preview offers it (unticked, "the
  project's own · layers changed"); `lock.json` keeps a hash of the version last
  offered (`templates`), so the same offer doesn't come back. It can still be
  taken later (ticked in the preview, or `akit apply --include PATH`).
- Skills from layers stay AKit's (updated, removed with the layer).
- `answers.json` has `skills`: brain skills for this project only, or a different
  mode for a layer's skill (`off` drops it here).
- The project's own skills: folders in `.agents/skills` that AKit didn't write.
  They win over a brain skill with the same name, are never overwritten, and get
  the `.claude/skills` link when Claude is a target. The project page lists them
  (New Skill…, Edit, Move to Trash).
- The home folder follows the core layer completely (no ownership rules there).
- JSON files (`.mcp.json`, `.claude/settings.json`): ownership is per key, not per file
  (2026-10-08). The file is the project's; AKit owns only the leaves it wrote. See
  [JSON merge](#json-merge-built-2026-10-08).

This replaces the earlier plan of a 3-way merge and "detach".

## JSON merge (built 2026-10-08)

Decided 2026-10-08, built the same day. One mechanism for three plans: MCP servers in
layers, hooks and permissions in layers, and writing `enabledPlugins` from a
recommendation later.

1. **Which files.** Two files are merged, not glued or owned whole: `.mcp.json` and
   `.claude/settings.json` in a project (exact paths, any letter case; an allow-list,
   `ProjectBundle.mergedJSONFiles`, revised 2026-10-08 after review). Any other `.json`
   target (`tsconfig.json`, `opencode.json`, …) stays a whole file like any template, with
   text substitution, so JSONC files keep working. Targets are grouped ignoring letter case
   and a leading `./`; one file spelled two ways is a render error. Objects merge deeply;
   arrays, strings, numbers, booleans and null are leaves: an array is never merged item by
   item, so `hooks` or `permissions.allow` lists from two layers clash today (a union merge
   of named arrays is a later step). Two layers setting one leaf to different values, or one
   a value where the other has an object, is a render error, shown in the form before
   Apply. `override: true` on the file entry lets that layer win (the later one when both
   set it), like for other files.
2. **Templates.** The template is parsed as JSON first; `{{field}}` is filled only inside
   string values, never in keys and never as text, so a value with `"` or `\` can't break
   the file. A template that is not valid JSON, or not an object, is a render error naming
   the layer and the template.
3. **Secrets.** A layer never carries secret values: every value at or under an `env` or
   `headers` key (any letter case) must be a whole-string `${NAME}` reference, else a render
   error. So `"Bearer ${TOKEN}"` is refused for now. The preview never shows a secret: in a
   JSON change's texts every value under `env` and `headers` that is not a `${NAME}`
   reference reads `••••`, in the old and the new text, also inside lists of objects. The
   masked text is only for showing; Apply writes the real values. Every `.json` file the
   preview shows (also whole files and files an older AKit wrote) is shown re-printed and
   masked, for showing also under `environment` (OpenCode's MCP servers; the layer rule
   stays `env` and `headers`); one that can't be read as JSON (or JSONC) reads "(JSON file; contents not
   shown)". `settings.local.json` and `auth.json` are never read or shown: a layer that
   targets one is a render error, and one an earlier render wrote is left alone with a
   warning. Backup folders are created readable only by the user (0700), since they now hold
   copies of these files.
4. **Ownership per key.** The project's existing file stays the project's. AKit adds the
   leaves the layers bring:
   - a leaf already there with the same value: nothing (it stays the project's unless AKit
     wrote this very value earlier, so a value the project set itself is never claimed, even
     when the layers later bring the same value);
   - a leaf there with a different value that AKit did not write earlier: left alone, and
     the preview warns "the project sets `mcpServers.x.command` itself";
   - a leaf AKit wrote and the project deleted: the project's choice. Not added again; the
     preview warns "the project removed X; AKit leaves it out". The lock remembers it in
     `declined` (so the record stays even when all of AKit's leaves were deleted) until the
     layers stop bringing it;
   - a merged file the project deleted entirely: like a deleted skeleton file. Not created
     again; the preview offers the layers' keys unticked ("the project's own"), taken only
     when ticked or with `akit apply --include PATH`;
   - `lock.json` keeps, per merged file, the key paths AKit wrote (RFC 6901 pointers) with a
     hash of each value, the objects AKit created to hold them, and the leaves the project
     declined, in a new optional key `json` (`{path: {keys, created, layers, containers,
     declined}}`; an early record without `containers` of a file AKit created counts every
     object as AKit's). Lock paths are read in one spelling (`./AGENTS.md` is `AGENTS.md`),
     and a merge record is found under any letter case of its path. Older akit ignores the key, and
     merged files are never in `files` (a lock that has both reads as merged), so an older
     akit never treats such a file as one it wrote whole. An older akit that saves the lock
     again drops `json`; AKit's keys then look like the project's, which is the safe side;
   - on a later render a leaf AKit wrote that the layers no longer bring is removed while
     it still holds AKit's value; a leaf the project changed is its own from then on (kept,
     dropped from the lock). A leaf AKit wrote and the project left alone is updated to the
     layers' new value. Objects that become empty go only if AKit created them; one the
     project had (say `"mcpServers": {}`) stays;
   - when nothing of AKit's is left in a file AKit created and only `{}` remains, the file
     goes to the Trash like other files AKit wrote. **Forget Project…** takes AKit's keys out
     of the files the project keeps, and says so when it can't (a file that is not valid
     JSON keeps them);
   - an older AKit wrote `.json` targets whole (`files` in the lock). On the first merge such
     a file is taken over: untouched since, every key and object is AKit's (and AKit created
     it); edited, only the keys that still hold the layers' value. Its `files` entry then goes.
5. **Writing.** Only when the merged result differs from the file (compared as JSON, so a
   file whose keys already match is not reformatted). AKit writes pretty-printed JSON with
   sorted keys, a 2-space indent and a trailing newline; when that changes the file's
   formatting, the preview says so. Backup, diff and Apply are the same as for other files,
   and an edit after the preview stops Apply. A file that exists and is not valid JSON (or
   not an object, or a link, or with a key given twice in one object) blocks Apply with a
   message and is never overwritten. AKit reads JSON with its own strict parser
   (`JSONValue`): numbers keep their text, so a rewrite never rounds the project's values.
6. **Home folder.** Not in v1: a merged file of the core layer is a render warning ("JSON
   files are not rendered into the home folder yet") and is skipped. Projects only. A JSON
   file an older AKit wrote into the home folder is never removed for that: it keeps its
   lock entry.
7. **UI.** Set Up Project's preview lists merged files like other changes ("keys merged;
   the project's own keys stay"), with the masked diff and the per-key warnings at the top;
   merged changes start ticked, since they never replace a value of the project's. `akit
   plan` prints the same. Brain → a layer's page already lists its files; no new screen.
   **Forget Project…** names its button after what goes: "Forget and Remove AKit's Files and
   Keys" (on a work Mac "Remove AKit's Files and Keys") when keys come out of a JSON file.

Where it lives: `JSONValue` (AKitFoundation: parse, print, key paths, masking),
`ProjectBundle.resolve` (parse, fill, secret check), `Render.mergeJSON` (layers into one
object, clashes), `JSONMerge` in AKitProjectSetup (into the project's file, the lock record).

## Agent draft

Status: not built. What exists instead: every new brain starts with the manual `/akit`
skill in the core layer, so an agent can already create layers and set up a project
through the `akit` command, without a draft file.

`/akit-setup` is a `manual` skill in the core layer. It reads
`~/.akit/registry/layers/*/layer.yaml`, asks about missing fields and writes
`.akit/draft.json` in the project (hidden via `.git/info/exclude`). The draft has
the answers format plus a short reason per chosen layer. AKit sees the file,
opens the prefilled form, and after Apply moves the answers to the brain repo
and deletes the draft. The form works without the agent.

## MCP (step after v1)

Status: possible since 2026-10-08 through JSON merge: a layer with an `.mcp.json`
template brings project MCP servers (`"mcpServers": {…}`), and `.claude/settings.json`
can enable them (`enabledMcpjsonServers`). Secrets are written only as `${VAR}` references
(enforced). Not built: the real values from Keychain (today they come from the
environment the harness starts in), and MCP files of other harnesses (Codex TOML,
OpenCode `opencode.json` has its own layout).

Layers may bring MCP servers, merged into `.mcp.json`. Secrets are written only
as `${VAR}` references; the real values come from Keychain.

## Roadmap

1. Safe write: backup + diff viewer + Apply. (Done, for MCP and for the render.)
2. Brain repo + layers read-only in AKit (done: Brain screen, checks, Create Brain Repo); move the global skill library from
   `~/.agents/skills` into the brain (done: Import Skills…); core layer with `manual`
   skills (done; it is rendered into the home folder with `akit apply --home` or
   **Update Home Folder…**).
3. Project form + render of skills and `AGENTS.md` (+ Claude shims), answers and
   lock in the brain. The take-home flow works end to end. (Done.)
4. MCP in layers. (Possible since 2026-10-08 through JSON merge: `.mcp.json` templates,
   `${VAR}` references only. Keychain values not built, see "MCP".)
5. `/akit-setup` agent draft. (Not built; the `/akit` skill covers the agent-driven
   setup, see "Agent draft".)
6. Updates. (Done 2026-09-28 as "the project owns its files", see "Updates". The 3-way
   merge and "publish back" of this step's first version were dropped.)

Buttons for the two operations that were command-only (2026-10-07): **Update Home Folder…**
(on the core layer, on the home folder's page, after a Sync or a removal from core that
changed core, and as Plan… in Insights) opens Set Up Project for the home folder with the
core layer only, `akit apply --home` in the app. **Forget Project…** (a project's page and
its context menu) is `akit remove project`: both use `ProjectForget`, and the dialog offers
"Forget and Trash Files" or "Forget, Keep Files" (`--keep-files`).

Step 6 of the design map, JSON merge (2026-10-08): `.mcp.json` and `.claude/settings.json`
merge key by key into the project's file, see [JSON merge](#json-merge-built-2026-10-08).

## Open questions

- Manual-only mode for OpenCode and Codex: equivalent of
  `disable-model-invocation` not verified yet.
- Pi has no native MCP (only via `pi-mcp-adapter`).
- Subagents in layers: low priority, format stays open for them.
- Rendering the core layer into the home folder: done (`akit apply --home`, and
  **Update Home Folder…** in the app).
