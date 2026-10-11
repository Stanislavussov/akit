# Layers: per-project harness setup

Status: design agreed 2026-09-25. Roadmap steps 1–3 are implemented (see
[Roadmap](#roadmap) for the status of each step, checked against the code on 2026-10-03).
Local-only files and git worktrees built 2026-10-09 in the core and the `akit` command, and
2026-10-10 in the app (see
[Local-only files and git worktrees](#local-only-files-and-git-worktrees-built-2026-10-09)).
Move to Project and its reverse, Move to Global, built 2026-10-11 (see [Move a skill to a project](#move-a-skill-to-a-project-built-2026-10-11)).
Remove Everywhere built 2026-10-11 (see [Remove a skill everywhere](#remove-a-skill-everywhere-built-2026-10-11)).
JSON merge built 2026-10-08 (see [JSON merge](#json-merge-built-2026-10-08)): layers can
bring MCP servers in `.mcp.json` and settings in `.claude/settings.json`, and for Pi in
`.pi/mcp.json` and `.pi/settings.json`. The home render writes the core layer's AGENTS.md
text as a marked block into the harnesses' global instructions (2026-10-08, see
[Home folder: instructions block](#home-folder-instructions-block-built-2026-10-08)).

Also built, though not roadmap steps: work machines, the "project owns its files" update
rules, `keep_auto`, `override`, the home folder render (`akit apply --home`, and in the app
**Update Home Folder…**), brain sync,
import of skills into the brain, the layer editor, and removing layers, skills and
projects. Not built: JSON merge into the home folder, MCP secrets from Keychain, the
`/akit-setup` draft, `machines/<name>.yaml`, `checks:`, `model_notes:` (a proposal,
`model-guidance.md`).

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
  commits to it are skill and layer edits the user makes on purpose, one narrow Move to
  Project exception (below), and its usage
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
  has no git identity of its own (the global one may be the work email). Since 2026-10-11 they are
  made like the work Mac's other brain commits (`BrainGit.commitStyle`: the brain's own identity,
  the environment's dropped, no hooks, never signed) by `BrainRemove`, `LayerEditor`, `LayerWriter`
  and `BrainImport`; without the brain's own identity they refuse before writing anything.
- Masking is not enough: it hides tokens, not repo names, paths or field text.
- One exception (2026-10-11, Move to Project): a work Mac may add a skill name to a personal
  project's answers in the brain, when that project is not on this Mac and only the brain has
  its record. The commit holds only `projects/<id>/answers.json` of a record already committed,
  with one skill entry added and nothing else (`WorkFilter`'s `answers` kind checks the staged
  bytes), made with the brain's own identity, without hooks or signing. Work projects' data
  (records in `~/.akit/local/projects`) still never reaches the brain. Remove Everywhere (and Move
  to Global) use the same kind the other way: `mode: nil` allows only that one skill entry taken
  out of such a record, and refuses when it isn't there.

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

Proposed, not built: `model_notes:`, short texts that reach the agent only for a matching
model, delivered by AKit's hook and Pi extension (`model-guidance.md`, "Model notes").

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
- A template for a merged JSON file (`.mcp.json`, `.claude/settings.json`, `.pi/mcp.json`,
  `.pi/settings.json`) is parsed first and `{{field}}` is filled only inside its string values (see [JSON merge](#json-merge-built-2026-10-08)).
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

Only harness files. Nothing from AKit itself. They are committed, unless the project is
[local only](#local-only-files-and-git-worktrees-built-2026-10-09).

```
project/
  AGENTS.md                    # glued from layer fragments
  .agents/skills/<name>/       # read by Pi, OpenCode, Codex
  CLAUDE.md                    # "@AGENTS.md", only if Claude is a target
  .claude/skills -> ../.agents/skills   # symlink, only if Claude is a target
  .mcp.json, .claude/settings.json      # only the layers' keys, merged into the project's file
  .pi/mcp.json, .pi/settings.json       # the same for Pi (MCP through pi-mcp-adapter)
```

Targets (harnesses) are a project field, multi-select, default from the machine
profile. Differences per harness go through `when: target == "claude"`.

In the home folder, AGENTS.md is not written as `~/AGENTS.md` (Claude Code never reads it, Pi
only below the home folder): its text goes as a marked block into `~/.claude/CLAUDE.md` and the
file Pi reads in `~/.pi/agent`, see
[Home folder: instructions block](#home-folder-instructions-block-built-2026-10-08).

## Local-only files and git worktrees (built 2026-10-09)

Built 2026-10-09 in the core and the command line: `ProjectAnswers.localOnly`,
`LocalOnly` (the exclude block, written by Apply, taken out by Forget), `ProjectWorktrees`
(`status` and `sync`, run by Apply and Forget), the worktree blocker, `GitCheckout.preferred`
for the Brain screen, `akit plan|apply --local-only yes|no|auto`, and
`akit worktrees [sync] [PROJECT]` (a folder in a worktree stands for its main checkout).
Built 2026-10-10 in the app: **Project files** in Set Up Project (**Commit to git** / **Local
only (hidden from git)**, its notes in the preview, and Apply when only that choice or the
block changes), the **Worktrees** box on the project's page (each worktree: linked, lacks N,
stale, conflicts; **Sync Worktrees**; the last sync's result), the sync of every set-up
local-only project on each refresh, and an FSEvents watch on `<git common dir>/worktrees`
(`WorktreeWatcher`) that syncs only that project about a second after a worktree comes or
goes. The watch counts only a record coming or going (`worktrees/<name>`, its `gitdir` and
`locked`), not the index, HEAD and logs git writes there on every command; a worktree git
is still creating (`locked initializing`) is skipped until the lock goes. Apply and Forget
hold the same per-project gate as the sync, so an automatic sync waits for them, and a link
another sync just made counts as linked. Snapshots (`make snapshot`) skip the automatic
sync, so they change no files.

Feedback from a work Mac (2026-10-09): a work repo has its own skills in git, and the
user's own skills and settings must not land there. Left untracked, AKit's files are
missing from every new git worktree (git checks out only tracked files), so an agent
started in a worktree by Pi, herdr or `git worktree add` has none of them.

**Local only.** `answers.json` gets `localOnly` (true or false). Without it the machine
role decides: a work Mac is local only, a personal Mac commits. Set Up Project shows the
choice. In a local-only project:

- Apply writes one marked block into `<git common dir>/info/exclude` with a line per unit
  AKit wrote that git doesn't track: `/.agents/skills/<name>` for each skill folder (no
  trailing slash, so the line also matches a link in a worktree), `/.claude/skills` for the
  link, and the files AKit created (`/AGENTS.md`, `/CLAUDE.md`, a merged JSON file AKit
  created). The project's own skills and its tracked files get no line.
- The exclude file is shared by all worktrees of the repo and is never committed. It only
  hides files from git: agents still read them. Pi 1.0.4 reads only `.gitignore`,
  `.ignore` and `.fdignore` inside its skills folders, never `info/exclude` (checked in
  `dist/core/skills.js`), so AKit never writes an ignore file into `.agents/skills`.
- A tracked file AKit merges keys into (a tracked `.mcp.json`) can't be hidden: the
  preview warns that AKit's keys show in `git diff`.
- Switching to commit takes the block out; the files then show in `git status`.
  Forget Project takes the block out too, after the project's record is gone (if the record
  can't go, the block still matches it).
- Apply writes the block before the files, with the old units and the planned ones, and
  after the files shrinks it to what was written and is untracked. So a file AKit writes
  never shows in `git status`, even when git fails after Apply.
- AKit edits the exclude file as bytes, split on line ends: every other line stays byte for
  byte (a line that is not UTF-8, a CRLF line). A linked `info/exclude` is written through
  to the file it points to. A file AKit can't read, or a broken block (a marker missing or
  doubled), is left alone: the preview, Apply and `akit doctor` say so and name the fix by
  hand (delete the block's lines, then apply again).
- The block may be edited by hand, so a line is a unit only when it names a path inside the
  checkout: not empty, not absolute, no empty, `.` or `..` component, no line break. A path
  of the lock that is not such a path gets no line; the preview names it.
- Not a git repo: nothing more to do.

**Worktrees.** For a local-only project AKit reads `git worktree list --porcelain` in the
main checkout. In each other worktree, each unit above becomes a symbolic link to the same
path in the main checkout:

```
main checkout                         worktree (Pi, herdr, git worktree add)
.agents/skills/
├─ team-skill/   tracked      ─git─►  team-skill/          (from the branch)
└─ my-skill/     AKit, excluded ◄──── my-skill -> <main>/.agents/skills/my-skill
```

- A unit missing in the worktree gets the link; parent folders are made as real folders.
- A link that already points there is left. Anything else at that path (the branch has
  its own file or skill) is left alone and reported.
- Apply and Forget remove, in every worktree, the link of each unit they take out of the
  block, when it points to the same path in the main checkout and its parent folders are
  real folders. Nothing else is removed: AKit can't tell a link it made from one the user
  made, so a plain sync (a refresh, **Sync Worktrees**, `akit worktrees sync`) only creates
  links, and in a repository without AKit's block it does nothing. A link left behind (a
  worktree that was gone during Apply, a line deleted from the block by hand) stays until
  removed by hand. Never a file or folder.
- A unit whose parent folder in the worktree is a link or a file (`.agents/skills` linked
  elsewhere) is left alone and reported: AKit never creates or removes through a link.
- Edits to a skill reach every worktree at once (it is the same folder); only a new or a
  removed unit needs a sync.
- These writes have no diff preview: they only create links where nothing is and remove
  AKit's own links. This is the one exception to "backup and diff first".

When: after every Apply; on every refresh of the app; within about a second of a new
worktree while the app runs (it watches `<git common dir>/worktrees` of each local-only
project); on **Sync Worktrees** on the project's page (which also lists the worktrees and
what each one lacks); and with `akit worktrees sync [PROJECT]`, which a tool's
"after worktree created" hook can run while the app is closed. A Pi session started in a
worktree before its links exist doesn't see the skills until it is restarted.

Not supported: a `.git` that is a symbolic link (AKit treats the folder as not a git
repository), and finding the main checkout from a linked worktree whose common git folder
is not `<main>/.git` (`git init --separate-git-dir`, a submodule): run `akit worktrees sync`
in the main checkout instead.

Set Up Project in a linked worktree is blocked: it names the main checkout, which is the
one to set up. The Brain screen maps a project id to its main checkout, never to one of
its worktrees.

## Move a skill to a project (built 2026-10-11)

A global skill that only one or two projects need costs its description in every other
session. **Move to Project…** (Skills screen, Brain → a core skill, Insights → Skills and the
"Only used in <project>" recommendation; `akit move skill`) moves it into those projects. Core:
`SkillMove` (AKitProjectSetup). The recommendation's rule is in `session-insights.md` (status,
"Only used in one project").

The skill reaches a project through the brain, never as a plain folder: only files of the
project's lock become lines of the local-only exclude block and links in its git worktrees
(`LocalOnly`, `ProjectWorktrees`). A folder copied into `.agents/skills` by hand is the
project's own skill: committed with the project or missing from every worktree. Pi has no way
to hide a global skill in one project (Pi 1.0.4 `package-manager.js` applies only a project's
own entries to its own folders), so for Pi this is the only per-project control.

The order keeps the skill present at every step:

```
 skill not in the brain → copy it into skills/<name>, no layer   commit "Import skill X"
    ▼
 each project: answers.skills + X (source "this project") → plan → Apply
    the skill's files (and .claude/skills when new) only; other pending changes wait
    local only: the exclude block grows, the worktrees get the link (now and later)
    ▼ a failure stops here: core and the home folder are untouched
 layers/core/layer.yaml without X                                 commit "Remove skill X from layer core"
    ▼
 home folder: plan with core without X → Apply removes AKit's copy (Trash)
    a copy AKit didn't write (a folder, or a link: only the link) → Trash
    other copies the harnesses see (~/.pi/agent/skills/X, a separate ~/.claude/skills/X) → Trash
```

- **Projects.** Each project's answers get `{name: X, mode}`; a project without answers gets
  its first Set Up with no layers and the installed harnesses as targets. Its Apply writes
  only X's files and the `.claude/skills` link when it is new, AKit's own, or replaces an empty
  folder; every other change of its plan (a layer that changed since) is deferred to Set Up
  Project: the lock keeps their old entries and their last offer (a pending "layers changed"
  suggestion is offered again), and, while one of them is a real change, the previous brain
  commit and Pi folder (`ProjectSetup.apply(deferring:)`). When Claude is a target and
  `.claude/skills` would not lead to `.agents/skills` (a link elsewhere, a folder with files),
  that project is blocked: Claude Code wouldn't see X. The app holds the worktree sync of every
  project the move writes; the command line has no cross-process gate (the app's is in memory),
  so a sync the app runs at the same time may make a link a moment early or late; it only
  creates links where nothing is, and the next sync fixes the rest.
- **Not on this Mac.** A project with a record (answers in the brain or the local store) gets
  only its answers, committed ("Add skill X to <id>'s answers"); Set Up Project on its Mac
  renders X. One without a record blocks the move. On a work Mac, a record only the brain has
  (a personal project) gets the skill entry in the brain's answers, as the one work-Mac
  exception (see "Work machines"); a record in `~/.akit/local/projects` (a work project set up
  on another Mac, which this Mac's store never reaches) blocks the move: move it on the Mac
  that has it, or keep the skill global. The plan says which store gets the answers.
- **Project files.** A project's saved choice (Commit / Local only) stays and is shown; a
  project set up by the move is local only unless the user picks Commit.
- **Mode.** The caller picks it: `auto` when the skill's calls show model calls, else its
  current mode (its core entry, else the global copy's header).
- **The core layer.** The preview shows the `layer.yaml` diff (`BrainRemove.layerWithoutSkill`);
  it is written and committed only after every project's Apply. Other layers that list X are
  named; their projects keep it.
- **The home folder.** Its plan renders core without X; Apply takes only X's files (the rest
  of a pending Update Home Folder waits). A copy edited by hand since AKit wrote it (`keepEdited`)
  stops the move: Show Edits, bring the edits into the brain first. When core has no skills
  left, a home render keeps AKit's `~/.claude/skills` link while `~/.agents/skills` still holds a
  skill folder (the user's own), so Claude Code keeps seeing them.
- **Other copies.** Only copies with the same folder name in other skill folders go to the Trash,
  and only when their files are the brain's (or those the brain is about to get); one that
  differs blocks the move, with Show Edits for every differing file. A folder of another name
  whose header says X is a different skill: a warning, never trashed. What goes to the Trash is
  hashed in the preview and checked again before anything is written, and so are the home
  folder's files the move removes; a folder of more than 10,000 entries, or with a part AKit
  can't read, can't be checked and blocks the move. What the brain import leaves out of a copy
  that goes to the Trash (files that may hold secrets, a broken link) is named in a warning;
  git history (`.git`) or a link out of the skill blocks it: move or remove it by hand. A source that is a link
  (into a development folder) is imported from that folder alone, and only the link goes.
- **Blocked.** A project with its own X (a folder AKit didn't write, in git or not) until the
  user compares and keeps the project's (then nothing is written there and X only leaves
  core; an own copy not in git gets a warning that its worktrees won't have X, and Apply checks
  that the copy is still there); a global copy that differs from the brain's `skills/X`; a project whose plan can't
  apply; claude.ai, plugin and Pi package skills (AKit can't move them: the skill switches
  turn them off per harness).
- **Warnings.** Other brain skills, layer templates (strong for the core layer: every session
  gets that text) and the AGENTS.md or CLAUDE.md of known projects not moved to that name X; a
  project not on this Mac (skipped); 3 or more projects ("a layer may suit it better").
- **Other Macs.** Brain Sync there offers Update Home Folder, which takes X out of their home
  folder; each project there needs its own Apply. A work Mac keeps answers and locks in
  `~/.akit/local/projects`.
- **Keep global** (`--keep-global`): only the brain import and the projects; core and the home
  folder keep X.
- **Failures** say where X is: a failed import commit may leave `skills/X` uncommitted in the
  brain; a home Apply that fails after the core commit leaves `~/.agents/skills/X`, which
  Update Home Folder takes out.
- The calls that preselect projects are read from the index opened read-only (`IndexSchema.openReadOnly`):
  the sheet and `akit move` never import or migrate it; `akit stats skill` imports first, like every `akit stats`.
- Not built: "make it the project's own" (copy the folder into the project to commit it), which
  would reach worktrees only once committed and has no lock entry or preview of its own.

**Move to Global** (built 2026-10-11) is the reverse: **Move to Global…** on a project's skill
(Skills screen: context menu and detail; Brain → the project → Skills), `akit move skill NAME
--to-global [--from PROJECT[,…]] [--mode auto|manual] [--yes]`. Core: `SkillMove.planToGlobal`,
`applyToGlobal`. The order keeps the skill present at every point:

```
 a project's own copy only (not in the brain): copy into skills/<name>   commit "Import skill X"
 layers/core/layer.yaml + X (diff in the preview)                        commit "Add X to layer core"
 home folder Apply: only X's files (and ~/.claude/skills when new)
 each project (default: every record whose answers list X):
   on this Mac: answers − X → Apply of only X's files (its copy to the Trash through the lock;
     a local-only project's worktree links go with the existing sync)
   not on this Mac: answers only (a work Mac: a personal project's brain record through
     WorkFilter's answers kind with mode nil, only that entry taken out)
   its own copy: to the Trash, last
```

- The mode: `--mode`, else the first project's answers entry, else auto.
- A project's own copy is checked like Move's source: git tracks it → blocked ("remove it there
  with a commit"); its own git history, a link out of the skill, an unreadable part or more than
  10,000 entries → blocked; a copy that differs from the brain's `skills/X` → blocked with Show
  Edits. A rendered copy edited by hand blocks too.
- The home folder: a copy in `~/.agents/skills/X` AKit didn't write blocks (compare, then remove
  it or import it); another global X (say `~/.pi/agent/skills/X`) is a warning, since harnesses
  reading both folders see two. When Claude is a home target and `~/.claude/skills` doesn't lead to
  `~/.agents/skills` (a folder of its own, a link elsewhere), Claude Code wouldn't see the home copy:
  that blocks the move when it would take a copy Claude Code loads now out of a project, else it is
  a warning.
- Own copies go last, after every project's answers, each hashed again right before the Trash.
- Projects not chosen that list it keep their copy; the plan names them.
- It stops at the first failure and says where the skill is: in its projects only (import or core
  failed), in core but not the home folder (Update Home Folder puts it there), or in core, the home
  folder and the projects not yet done.

## Remove a skill everywhere (built 2026-10-11)

A skill that is never needed costs its description wherever any harness loads it, and it can
be in many places at once: `~/.agents/skills` (Pi, Codex, OpenCode, and Claude Code through the
`~/.claude/skills` link), a real `~/.claude/skills` folder, `~/.pi/agent/skills`, OpenCode's
config folders, each project's `.agents/skills`, `.claude/skills`, `.pi/skills` (and
OpenCode's), a brain layer or a project's answers that render it, a Claude Code plugin, a
claude.ai skill, a Pi package. Deleting one copy leaves the others, and deleting a rendered copy
brings it back on the next Apply. **Remove Everywhere…** (Skills screen: context menu and the
detail's toolbar; Insights → Skills context menu and the auto → manual cards; `akit remove skill
NAME --everywhere`) finds every place and takes the skill out of each. Core: `SkillRemoval`
(AKitProjectSetup), `PluginSwitch` (AKitSkills).

- **Finding.** The places are `SkillScanner`'s: every root of every installed harness, the
  global ones and those of every project AKit knows (checked 2026-10-11: Claude Code's global,
  synced, plugin and project folders; Pi's `~/.pi/agent/skills`, `~/.agents/skills`, a project's
  `.pi/skills` and `.agents/skills` up to its git root, package skills; Codex's and OpenCode's
  folders). A copy matches by its folder name (what Claude Code keys on); a folder of another name
  whose header says the name is listed as "maybe the same skill" and is never ticked by default.
  The scanner merges copies with one real path into one skill, so the plan splits it again by
  `Skill.places`: each link of its own (a skills.sh layout, `~/.claude/skills/x → ~/.agents/skills/x`)
  is a place where only the link goes; the real folder is a place of its own when it sits directly in a
  folder some installed harness loads skills from (also when no harness's first place reached it
  there), else it stays and the plan says so (a development folder the links led to). Those folders
  (`SkillScanner.rootFolders`, custom harnesses included) leave out the home folder and anything
  above it: a harness whose skill folder is `~` never makes `~/Documents/notes` removable; such a
  copy is listed as "Not directly in a skill folder AKit removes from". A folder reached
  through a folder of skills that is a link (`~/.claude/skills → ~/.agents/skills`) is one place,
  listed under its real folder with "also reached as". Then the brain: every layer that
  lists it, every record whose answers list it (a work Mac adds the personal projects only the
  brain has), and `skills/<name>`.
- **Actions.** Own copy (global, or a project's, not in git) → the Trash; a skills.sh lock entry
  is forgotten only when the real folder goes, never for a link, by the path resolved before the
  move. A copy or a link that git tracks stays, also a global one (a home folder may be a dotfiles
  repository). A tracked link whose folder goes stays as a link to a removed folder: the plan says
  so in a note (it loads nothing, so it is not in "still loads in"). Known limit: dotfiles kept as a
  bare repository (`git --git-dir=~/.dotfiles --work-tree=~`) leave no `.git` to find, so AKit can't
  tell such a copy is tracked; it goes to the Trash like any own copy (recoverable from there). A copy AKit rendered → it leaves with the Apply of its
  brain entry. A layer → its `layer.yaml` without the entry (diff, one commit each). A project's
  answers → without the entry; on this Mac the project's Apply saves them (a local-only project's
  worktree links go with the existing sync); a project on another Mac gets only its answers
  (the brain's, or a work Mac's local record; a personal project's brain answers from a work Mac
  through `WorkFilter`'s answers kind, whose `mode: nil` allows only that one entry taken out).
  The brain library's `skills/<name>` stays unless ticked ("Also delete it from the brain
  library", `--library`), and only when nothing in the brain lists it any more; its git history
  stays. On a work Mac it also stays while the brain's answers of a project this Mac keeps its own
  record of still list it: a work Mac never rewrites the brain's copy of such a record (only
  `WorkFilter` writes project data to the brain), so that is done from a personal Mac. The plan
  says that projects set up on a work Mac keep their records on that Mac and can't be seen here.
- **Kept, with the alternative.** A project's own copy that git tracks: "remove it there with a
  commit", and Pi's per-project switch (**Pi: Off…**). A plugin skill: Claude Code's
  `skillOverrides` doesn't reach it, so it leaves only with its plugin: **Disable Plugin…** sets
  `enabledPlugins["<plugin>@<marketplace>"]` to false through `SettingsFile` (backup, refused when
  the entry changed); the confirmation names the exact keys, every skill and MCP server that goes
  with the plugin, and the known projects whose own `.claude/settings.json` turns it on again (it
  stays on there). Never part of Remove. A plugin skill's row (Skills, Insights → Skills) opens
  Disable Plugin… instead of Remove Everywhere…: its bare folder name may be an unrelated skill's. A claude.ai
  skill: the Claude switch Off (`skillOverrides`), a place left unticked by default. A Pi package's
  skill: Pi filters it in the package's own settings entry, which AKit doesn't write. A skill
  bundled with a harness: nothing.
- **Records.** Each record on this Mac whose rendered copy or answers change gets one plan with
  every ticked brain edit at once (the layers as edited, its answers without the entry); Apply
  takes only the skill's files, and the rest of a pending render waits (`deferring`), as Move
  does.
- **Order.** Layers (commit) → each record's Apply → other Macs' answers → own copies to the
  Trash → claude.ai switches → the library. Each item is hashed again right before its own move to
  the Trash (commits and Applies ran meanwhile); an item already gone (a worktree link the sync
  removed, a copy another tool took) is a note, and a place whose items were all gone gets no
  "to the Trash" line.
  Before the first write too: what goes to the Trash is hashed again (a folder of more than 10,000 entries or with an unreadable part, git history or a
  link out of the skill blocks that place at plan time), each record's files and each layer file
  must be as previewed. A rendered copy edited by hand blocks, with Show Edits. It stops at the
  first failure and says what was done.
- **The plan ends** with "After this, NAME loads in: nowhere." or the places left and why. Other
  Macs: Brain → Sync there, then Update Home Folder and each project's Apply.
- MCP servers: Insights → MCP Servers' context menu has the MCP Servers screen's **Delete…**
  (its confirmation and backup); a plugin's or claude.ai server can't be deleted there.

## Several layers, one file

- Markdown (any `.md` target, e.g. `AGENTS.md`): each layer adds a section;
  sections are glued in layer order (`requires` first, then selection order).
- JSON (`.mcp.json`, `.claude/settings.json`, `.pi/mcp.json` and `.pi/settings.json` only;
  built 2026-10-08):
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
- The home folder follows the core layer completely (no ownership rules there), except
  for the instructions block: one edited by hand is kept and the layers' text only offered
  (see [Home folder: instructions block](#home-folder-instructions-block-built-2026-10-08)).
- JSON files (`.mcp.json`, `.claude/settings.json`, `.pi/mcp.json`, `.pi/settings.json`):
  ownership is per key, not per file
  (2026-10-08). The file is the project's; AKit owns only the leaves it wrote. See
  [JSON merge](#json-merge-built-2026-10-08).

This replaces the earlier plan of a 3-way merge and "detach".

## JSON merge (built 2026-10-08)

Decided 2026-10-08, built the same day. One mechanism for three plans: MCP servers in
layers, hooks and permissions in layers, and writing `enabledPlugins` from a
recommendation later.

1. **Which files.** Four files are merged, not glued or owned whole: `.mcp.json` and
   `.claude/settings.json` in a project, and Pi's `.pi/mcp.json` (read by the pi-mcp-adapter
   package, which reads `.mcp.json` too) and `.pi/settings.json` (exact paths, any letter
   case; an allow-list, `ProjectBundle.mergedJSONFiles`, revised 2026-10-08 after review; Pi's
   two added 2026-10-08). Any other `.json`
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
   error. So `"Bearer ${TOKEN}"` is refused for now. In `.mcp.json` and `.pi/mcp.json` a value
   there starting with `!` gets its own error: pi-mcp-adapter runs such a value as a shell
   command, and a layer never brings a command to run. Open (2026-10-09): pi-mcp-adapter's
   source was not available locally, so whether it also runs or expands other fields
   (`bearerToken`, `auth`, …) is not checked; only `env` and `headers` are guarded and masked.
   Keys a harness runs are allowed but named in the preview ("layer X sets `shellCommandPrefix`
   in .pi/settings.json, which Pi runs"): Pi's `shellPath`, `shellCommandPrefix`, `npmCommand`,
   `packages`, `extensions`, `externalEditor`; Claude Code's `hooks`, `apiKeyHelper`,
   `statusLine`, `awsAuthRefresh`, `awsCredentialExport`, `otelHeadersHelper`; and an MCP
   server's `headersHelper` in `.mcp.json`. The preview never shows a secret: in a
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

## Home folder: instructions block (built 2026-10-08)

Decided 2026-10-08 ("block with markers"), built the same day, revised 2026-10-09 after review.
The home render used to write the core layer's AGENTS.md text to `~/AGENTS.md`, which Claude
Code never reads and Pi reads only as a parent of the folder it starts in. Now it goes into the
global instructions file of each target harness of the home record (`answers.targets`):

- `claude` → `~/.claude/CLAUDE.md`;
- `pi` → the file Pi reads in its config folder. Pi reads one file per folder, the first that
  exists of `AGENTS.override.md`, `AGENTS.md`, `AGENTS.MD`, `CLAUDE.md`, `CLAUDE.MD`
  (`loadContextFileFromDir` in Pi's resource-loader; checked in the installed 0.8x package), so
  the block goes into that one, and AKit creates `AGENTS.md` only when none is there. The
  preview names the files next to it that Pi doesn't read ("…; CLAUDE.md next to it is not read
  by Pi"). The folder is PI_CODING_AGENT_DIR (`~` and `file://` expanded, as Pi does), else
  `~/.pi/agent`. `akit` on the command line takes its environment as it is. The app, started
  from the Finder, doesn't see the shell's variables: it uses the folder the last home render
  used (`piAgentDir` in the lock) while that folder exists, and the preview says so ("Pi's
  folder: … (remembered from an earlier render…)"). A relative PI_CODING_AGENT_DIR is resolved
  by Pi from the folder it starts in, so AKit leaves Pi's file alone with a warning. A folder
  outside the home folder shows its absolute path.

The text sits between two markers, and AKit owns only what is between them:

```
<!-- akit:core:start -->
…the core layer's AGENTS.md text…
<!-- akit:core:end -->
```

- **One text per target.** The text is rendered once per harness, so a section with
  `when: target == pi` reaches only Pi's file; an error in any target's render stops Apply. A
  layer text that holds a marker is a render error.
- **Markers** count only as whole lines (at most 3 spaces or tabs before, any after, `\r`
  ignored; 4 make an indented code line), never inside a fenced code block, so a quoted marker
  in the user's text is just text. A fence that never closes doesn't count as one (else the
  block AKit appended after it would be invisible and appended again); the file is read in one
  pass, however many fences stay open.
- **Bytes around the block** are AKit's to keep. AKit works on bytes: CRLF files get a block
  with CRLF lines, a BOM stays. Text in UTF-16 or UTF-32 (a BOM of those, or NUL bytes) is
  skipped with a warning. Taking the block out removes the separator AKit put before it
  (`separator` in the lock, in the file's line ending of today) only while it is still there
  as AKit put it, and never joins the
  user's line before the block with their text after it. So on a file the user left alone,
  append + take out gives back the same bytes (no final newline, trailing blank lines, CRLF,
  BOM); with the user's edits around the block, their text stays, with at most a line ending
  added between two lines that would otherwise join. Permissions and extended attributes of
  the file are kept (the atomic write makes a new file, so AKit copies them over). Other tools
  keep their own blocks in the same file (oh-my-claudecode writes `<!-- OMC:START -->` … into
  `~/.claude/CLAUDE.md`).
- **No block yet**: appended at the end, after one blank line. **File missing**: created with
  only the block. **Update**: only the block is replaced.
- **Empty render** (the core layer has no AGENTS.md text, the target is no longer chosen,
  Forget): the block and its markers go; the file stays, even when empty. Only a block AKit
  wrote (it has a record) is taken out; one without a record is only offered. One exception: a
  Pi file AKit created (`created` in the lock) that is empty without the block (or holds only
  spaces and line endings) goes to the Trash, since Pi reads the first instructions file in its
  folder even when it is empty and would no longer see a `CLAUDE.md` next to it. Its folder
  stays, even when empty (it may be a link, or a PI_CODING_AGENT_DIR meant to be empty).
- **Broken markers** (a start without an end, two starts, an end before the start): a blocker
  in the preview; nothing is written. When AKit only wanted to take its block out, the file is
  left alone with a warning and keeps its record.
- **A file AKit can't safely write** (a link, a file with more than one hard link, which an
  atomic write would cut, a folder, an unreadable file): skipped with a warning, the rest of the
  home folder still updates. A linked parent folder (`~/.claude` in a dotfiles repo) is fine.
- **Edited by hand**: `lock.json` keeps, per file, a hash of the text AKit wrote in the block
  and of the layers' text last offered (optional key `blocks`, `{path: {sha256, offered,
  layers, separator, target, created}}`, plus `piAgentDir`). A block edited since is the user's, like an
  edited template in a project: kept, and the layers' new text is offered unticked ("edited by
  hand · layers changed"), once per new version ("edited by hand" after that); taken when ticked
  or with `akit apply --include PATH`. A block (or the whole file) removed by hand is not added
  again, only offered ("removed by hand"). An edited block outlives an empty render ("no longer
  rendered, but edited by hand: kept").
- **Pi reads another file now** (an `AGENTS.override.md` appeared, PI_CODING_AGENT_DIR
  changed): the block goes into the new file, and the old one is only offered for taking out
  (unticked, with a warning); an old block edited by hand is kept ("edited by hand · Pi no
  longer reads this file").
- **Older AKit**: it ignores `blocks` and `piAgentDir`, and drops them when it saves the lock.
  A block found without a record counts as edited, unless it holds the layers' text exactly
  (then it is AKit's again, with a record); Forget can't tell, so it leaves such a block and
  says so.
- **Lock keys** are used only for instruction files: `.claude/CLAUDE.md`, or a Pi record whose
  file is one Pi reads (`AGENTS.md`, `CLAUDE.md`, …) in any folder, so a block in a folder Pi
  used before can still be offered for taking out. Any other key is dropped from the lock with
  a warning; its file is never touched.
- **Preview and Apply**: the preview shows a diff of the whole file; Apply backs the file up
  first (a file outside the home folder under its full path) and refuses if it changed since
  the preview, checked again right before the block is written.
- **`~/AGENTS.md` of an older render** goes through the usual "an earlier render wrote it"
  removal: to the Trash, unless edited since (then kept, and with Pi as a target the preview
  warns that Pi reads it on top of its own file in every folder under the home folder).
- **`akit setup`** names each block change and asks ("Add AKit's block … to ~/.claude/CLAUDE.md?
  [Y/n]"), and the same for moving an older `~/AGENTS.md` to the Trash; without a terminal it
  leaves them and says so.
- **Forget** takes AKit's blocks out ("Forget and Remove AKit's Files and Blocks") and lists the
  ones that stay (edited, without a record, or a file AKit doesn't write).
- A core template that targets one of these files is a blocker (the file can't be both).

Where it lives: `Render` marks the home folder's AGENTS.md output `instructionsBlock`;
`InstructionsBlock.planHome` (called by `ProjectSetup.plan` with `piAgentDirSetting`) renders
the text per target, picks the files and plans each one; `InstructionsBlock` finds, writes and
takes out the block. `akit apply --home`, `akit setup`, **Update Home Folder…** and **Forget
Project…** on the home folder all use it.

Not built: the global files of other harnesses (Codex `~/.codex/AGENTS.md`, OpenCode
`~/.config/opencode/AGENTS.md`).

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
can enable them (`enabledMcpjsonServers`). For Pi, `.pi/mcp.json` has the same shape (read by
pi-mcp-adapter, which also reads `.mcp.json`). Secrets are written only as `${VAR}` references
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
   An import can also copy a skill into the library without listing it in any layer
   (`BrainImport.apply(listInLayer: false)`, 2026-10-11; commit "Import skill X"), for a skill
   that a project's answers list instead (Move to Project). Every import commit names where
   each new skill was installed from ("Source of X: owner/repo", from the skills.sh or AKit
   lock, reduced to `owner/repo` or a host and path: no credentials, query or line breaks, and
   never a local path or `file://` source), so the
   brain's copy keeps its origin; the brain has no other record of it.
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
Pi's `.pi/mcp.json` and `.pi/settings.json` joined the same day.

## Open questions

- Manual-only mode for OpenCode and Codex: equivalent of
  `disable-model-invocation` not verified yet.
- Pi has no native MCP (only via `pi-mcp-adapter`).
- Subagents in layers: low priority, format stays open for them.
- Rendering the core layer into the home folder: done (`akit apply --home`, and
  **Update Home Folder…** in the app); its AGENTS.md text as a block in Claude Code's and
  Pi's global instructions since 2026-10-08.
