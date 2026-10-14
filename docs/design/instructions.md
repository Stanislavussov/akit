# Instructions: AGENTS.md and CLAUDE.md like skills

Status: agreed 2026-10-14, from a chat request ("work with AGENTS.md on the same principle
as skills"). Step 1 is built (below). Decided the same day (D11–D13, D15 in [`README.md`](README.md)):
a section is one `##` heading, AKit may edit a project's tracked files (diff + backup, no
commit), duplicates are the same text after normalizing, and step 1 comes first and alone. D14
(decided the same day): Move to Global puts a section into the core layer.

Step 1 built 2026-10-14: `AKitInstructions` (`InstructionScanner`, `InstructionText`), the
Instructions screen (On This Mac) and `akit instructions [FOLDER] [--harness …] [--global]`.
Not in step 1: files in subfolders that load later, and Codex's budget for the global file
(only project files count against the 32 KiB).

Step 2 built 2026-10-14: `InstructionView.duplicates` (`InstructionDuplicates.swift`): same text
(D13) or the same `##` heading with other text, among the loaded files of one session; AKit's
block compared by its `##` parts (`InstructionText.units`). The screen's Duplicates (N) filter,
a mark per file and "Also in …" / "Same heading, other text in …" per section; `twice` and
`differs` lines in `akit instructions`.

Step 3 built 2026-10-14: Remove This Copy… on a repeated section (`AKitProjectSetup/InstructionEdit.swift`):
the section's lines leave one file (one blank line kept between the parts around it, every other
byte unchanged, CRLF too), diff first, `SettingsFile.write` with backup, refused when the file
changed or the section moved. Not offered for AKit's block or a file in a brain project's lock
(`InstructionEdit.renderedFiles`). A git-tracked file gets a note (D12); an emptied file stays.
No CLI command yet. Review round the same day: refused when another place of the section is the
same file (a link or hard link, read twice by Pi or Codex), when the section changed since the
screen read it (re-split and compared), for a lead with a header or `#` title and for a section
with an unclosed fence. The sheet names the other harnesses that read the same file and says
when the file is global or above the project. Not handled: a rendered file checked out in a
worktree of a brain project (only the main checkout's paths are in the lock).

Step 4 built 2026-10-14: Import to Brain… (`AKitProjectSetup/InstructionImport.swift`): the section
joins the chosen layer's AGENTS.md text (`LayerEditor.update`, one brain commit, in line with the
other layer edits); the layer is core for a global or above-project file, else the first layer of
the project's record. "Also remove it from …" (off by default) takes the section out of the file
after the commit (`InstructionEdit`). Refused when the layer already has the section, the file or
the layer's text changed since the preview. The text reaches files at the layer's next render;
step 5 adds that render to the move. Review round the same day: the layer is written by
`LayerEditor.appendToAgentsSection`, which reads the layer from disk at Apply and changes only
its AGENTS.md template (own bytes and line ending kept), so a hand edit of layer.yaml after the
scan is never reverted; the file is checked before the commit when it should lose the section;
leads, open fences and a layer whose AGENTS.md entry is only under `when:` are refused; notes for
a same-heading section in the layer, `{{…}}` and `@…` words.

Step 5 built 2026-10-14 (`AKitProjectSetup/InstructionMove.swift`). Move to Global… of a
project's (or an above folder's) section: the file is checked, the section joins core
(`appendToAgentsSection`, a commit), the home folder's plan is applied for its core blocks only
(the other home changes are left for Update Home Folder), and only then the file loses it; each
step runs when the one before worked, and a failure says what is done and how to finish. Move to
Project… of a global section (decided 2026-10-14: the project's own file): each ticked project's
AGENTS.md, else CLAUDE.md, else a new AGENTS.md gets the section (backup), then the global file
loses it; nothing is written when any file changed. A project whose file AKit renders from the
brain is not a target (Import to Brain… into its layer instead). Review round the same day: Move to Global is two steps in
the sheet: Commit to Core, then the home blocks that carry the section (only added or updated
blocks, never a take-out or other pending home changes) as diffs, applied on a second click;
the file loses the section only when every installed harness that reads it there gets it from a
global file afterwards (checked on disk with the scanner). Codex and OpenCode have no core block,
so they keep the project copy. Move to Project picks the project file that every installed
harness reading the global file reads there (else a new CLAUDE.md or AGENTS.md that each of them
would read, `InstructionMove.wouldRead`); links to one shared file are written once. A partial
home Apply now keeps the previous lock record of a deferred block, so a later Update Home
Folder still offers the new core text (this also fixes Make Manual's partial Apply).

Asked the same day and built: Edit… (the file's text in an editor → Review Changes → Save;
`InstructionEdit.editing`: refused for a rendered file and when AKit's core block changes) and
Rewrite with Skill… (`InstructionRewrite` + `AppModel.rewriteInstruction`): one `ModelCall`
through the chosen harness's sign-in (Claude Code or Pi; send policy with origin `.code`, the
scrub, the monthly limit, the send log), the skill's SKILL.md as guidance, the user's request;
AKit's core block is replaced by a marker that the answer must keep and is put back; a file or
skill the scrub would change is not sent (the masked text would come back); the answer is a diff
applied only on Apply. Not verified with a live model call in development. Review round the same
day: the plan keeps the bytes the text was made from (when the editor opened, or what the model
got), so Apply never undoes a change made meanwhile; a file whose AKit block hides behind an
unclosed code fence, or that has the marker line itself, is neither sent nor edited; marker lines
are compared as written (a 4-space indent is refused); the answer's JSON is found among braces in
prose without trapping; Cancel stops the call. The send origin is the harness the screen shows
(`.code(.claudeCode)` or `.code(.pi)`; Codex and OpenCode files are not sent), so a destination
other than that reader needs the send policy's allow list. A file the scrub would mask (an e-mail
address counts) is refused with the rules that matched. Not handled: the editor's smart quotes. Step 0 (the facts below) is done: checked the same day in
the installed harnesses' code and docs.

## Problem

Skills have a screen: where each copy lives, which harness loads it, its cost in the context,
switches, Move to Project / Global, Import to Brain, Remove Everywhere, Resolve Duplicate.
Instruction files have none of that. They cost more: every line of every loaded file goes to
the model in every call, and nothing tells you which files a session in a project gets.

The hope that a harness reads only the first file it finds is wrong. Every harness joins files
from several folders (facts below). So a rule written twice costs twice, two rules that
disagree both reach the model, and a file one harness reads may be skipped by another.

## Facts (checked 2026-10-14)

Claude Code 2.1.299, Pi 1.0.4, Codex 0.147, OpenCode 1.18.15. Sources: Claude Code's memory
docs (code.claude.com/docs/en/memory, "How CLAUDE.md files load", "AGENTS.md") and its binary;
Pi's `dist/core/resource-loader.js` (lines 115–191) and `dist/core/system-prompt.js`; Codex's
AGENTS.md guide and `core/src/agents_md.rs` strings in its binary; OpenCode's rules docs
(opencode.ai/docs/rules) and its `Instruction` service in the binary.

| | Claude Code | Pi | Codex | OpenCode |
|---|---|---|---|---|
| Global file | `~/.claude/CLAUDE.md` (+ managed file, `~/.claude/rules/`) | one file in `~/.pi/agent` (first of the list below) | `~/.codex/AGENTS.override.md`, else `AGENTS.md` | first of `~/.config/opencode/AGENTS.md`, `~/.claude/CLAUDE.md` |
| Files in one folder | all of `CLAUDE.md`, `.claude/CLAUDE.md`, `CLAUDE.local.md`, `.claude/rules/**` | one: `AGENTS.override.md` > `AGENTS.md` > `AGENTS.MD` > `CLAUDE.md` > `CLAUDE.MD` | one: `AGENTS.override.md` > `AGENTS.md` > fallback names | one name for the whole tree: `AGENTS.md`, else `CLAUDE.md`, else `CONTEXT.md` |
| Folders | cwd and every folder above it (not only to the git root); subfolders when a file there is touched | cwd and every folder above it, to `/` | git root down to cwd | cwd up to the worktree root; subfolders when a file there is read |
| Joined or first wins | joined: managed → user → root … cwd | joined: global → root … cwd | joined: root … cwd, 32 KiB in all, the last file cut | joined: global → cwd … root (closest first) |
| Reads the other's name | AGENTS.md only through its built-in plugin, and only when no CLAUDE.md exists in cwd or above | `CLAUDE.md` when the folder has no `AGENTS.*` | no (unless configured) | `CLAUDE.md` when no `AGENTS.md` is found; `~/.claude/CLAUDE.md` when no global AGENTS.md |
| Imports | `@path`, 4 hops | no | no | no (`instructions` in config) |

More rules found in the review of step 1 (2026-10-14, Pi's code read again):

- Pi, in a linked worktree inside the main checkout (`repo/.claude/worktrees/x`, Claude Code's
  own layout), skips the main checkout's file when the worktree has its own file of that name
  (`findShadowedContextFile`, `resource-loader.js:136-163`).
- Pi and Codex keep a list of paths as written: a link to a file above is read a second time.
  Claude Code and OpenCode are taken to list a file once (by its real path).
- Claude Code rules with `paths:` in their front matter load only when the agent works on a
  matching file; they are listed apart ("Loads Later") and not counted in the size.
- Claude Code imports any `@word` that is an existing path (`@README`, `@package.json`).
- Not verified: whether Codex lets an empty project `AGENTS.override.md` hide `AGENTS.md`
  (AKit follows the docs: empty files are skipped).

Consequences for AKit:

- A file "above" a project (`~/AGENTS.md`, `~/Projects/CLAUDE.md`) reaches every session below
  it in Claude Code and Pi. The screen must show these.
- A file can be "shadowed": Pi skips `CLAUDE.md` in a folder with `AGENTS.md`; Claude Code
  skips AGENTS.md when any CLAUDE.md exists. The screen says, per harness, loaded or skipped.
- `CLAUDE.md` with only `@AGENTS.md` (what AKit renders) is one text for Claude Code, not two.

## Goal

Four parts, in the order of the steps:

1. **Instructions screen** (read only). Every instruction file per harness: global, above the
   project, in the project. For one project and one harness, the text that reaches the model,
   in its order, with its size (≈ tokens). Each file split into sections (by `##` heading); the
   core layer's marked block shown as AKit's.
2. **Duplicates.** A section whose text is in another file that the same harness loads in the
   same session. Marked, filtered, and Resolve Duplicate…: keep one place, the section leaves
   the others (diff, backup).
3. **Into the brain.** Import Section to Brain…: the section becomes part of a layer's AGENTS.md
   fragment (a brain commit); its own copy can leave the file in the same step.
4. **Move global ↔ project.** Move to Project…: a section of the global text goes into chosen
   projects and leaves the global one. Move to Global…: the other way. Through the brain, as
   for skills: the global side is the core layer (rendered into every harness's global file as
   the marked block), the project side is the project's layers or answers.

```
Instructions screen
  Global ─ Above project ─ Project            per file: harnesses (loaded / skipped), size, sections
      │
      ├─ a section ── Duplicate? ── Resolve Duplicate…  (keep one place; diff; backup)
      ├─ a section ── Import Section to Brain…           (layer fragment; brain commit)
      └─ a section ── Move to Project… / Move to Global… (core layer ↔ project layers)
```

## Model

- **Instruction file**: a file one harness loads as instructions (table above). One file can
  be loaded by several harnesses (`~/.claude/CLAUDE.md`: Claude Code, and OpenCode as a
  fallback).
- **Section**: the text from one `##` heading to the next; the text before the first heading is
  the file's lead section. A `#` title alone is not a section. AKit's marked block is one
  section, read only here (it changes in the brain). (D11)
- **Effective text** of (harness, project): the files that harness loads for a session in the
  project root, in its order, skipped files left out. Subfolder files that load later are
  listed apart ("loads when a file there is touched").
- **Duplicate**: two sections in the effective text of one (harness, project), or in two global
  files of one harness, with the same text after normalizing (line ends, trailing spaces, blank
  lines; heading level). Same heading with other text is shown as "differs", not ticked. (D13)

New module `AKitInstructions` (scanner, effective text, sections, duplicates; reads only), and
the writing parts in `AKitProjectSetup` next to the skill moves.

## Writing rules

- Every write: a diff first, a backup in `~/.akit/backups`, refused when the file changed since
  the preview (`SettingsFile.write`), as for SKILL.md.
- A file AKit rendered (a brain project's `AGENTS.md`, the core block) changes only through the
  brain; a section in it offers Show in Brain, never a direct edit.
- A project's own file that git tracks: AKit may write it (D12, proposal: yes, with a note that
  the change shows in `git status`); never commits in the project.
- Removing a section never deletes the file; an empty file stays empty (the user decides).

## Steps

| Step | What | Writes |
|---|---|---|
| 0 | Facts (above) | — (done 2026-10-14) |
| 1 | `AKitInstructions`: scanner, sections, effective text per harness and project; Instructions screen (Global, Above Project, Projects; per file harnesses, size, sections); `akit instructions` | nothing |
| 2 | Duplicates: groups, marks, filter | nothing |
| 3 | Resolve Duplicate…: section removal from own files | own files |
| 4 | Import Section to Brain… | brain |
| 5 | Move to Project… / Move to Global… for a section | brain, then Apply |

Step 1 alone already answers "what does my agent get in this project and what does it cost".
Insights can later count instruction size per session from the recorded system prompt (the
context map already splits it).

## Not in this design

- Editing instruction text in AKit (open the file in the editor, as for skills).
- `.claude/rules/`, managed policy files, Codex fallback names: listed when found, not moved.
- Lazy subfolder files: listed, not part of duplicates.
