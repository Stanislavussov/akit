# Instructions: AGENTS.md and CLAUDE.md like skills

Status: agreed 2026-10-14, from a chat request ("work with AGENTS.md on the same principle
as skills"). Step 1 is built (below). Decided the same day (D11–D13, D15 in [`README.md`](README.md)):
a section is one `##` heading, AKit may edit a project's tracked files (diff + backup, no
commit), duplicates are the same text after normalizing, and step 1 comes first and alone. D14
(where Move to Global puts a section) is open until step 5.

Step 1 built 2026-10-14: `AKitInstructions` (`InstructionScanner`, `InstructionText`), the
Instructions screen (On This Mac) and `akit instructions [FOLDER] [--harness …] [--global]`.
Not in step 1: files in subfolders that load later, and Codex's budget for the global file
(only project files count against the 32 KiB). Step 0 (the facts below) is done: checked the same day in
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
