# Global instructions: one AGENTS.md in the brain

Status: asked 2026-10-30 ("manage the global AGENTS.md in the brain: open, read, edit,
analyze"). Decided the same day by the user: the text lives in the brain's core layer (D22),
and the analysis has three parts: size and repeats, a model's review, and the recorded
sessions (D23). Steps below; none built yet.

## Problem

Every session of every harness starts with its global instruction file: `~/.claude/CLAUDE.md`
(Claude Code, and OpenCode as a fallback), Pi's `AGENTS.md` in `~/.pi/agent`, Codex's
`~/.codex/AGENTS.md`. On the user's Mac (2026-10-30) these files are written by hand, differ
from each other (6.5 KB for Claude, 3.7 KB for Pi), and none comes from the brain: the core
layer has no AGENTS.md text. AKit can already show them (Instructions → Global Files Only),
edit one file, move one section at a time into core (Import to Brain…, Move to Global…), and
render core's text as a marked block into Claude's and Pi's files (Update Home Folder). What is
missing:

1. One place that says "this is your global instructions text": read it, edit it, see where it
   goes and whether every harness has the latest copy.
2. A way to bring the hand-written files into the brain in one step, not section by section.
3. An answer to "is this text any good": what it costs, what repeats, what is vague or
   contradicts itself, what the agent keeps breaking.

## Model

- **Global instructions**: the core layer's AGENTS.md text (`LayerEditor.details(of:).agentsSection`
  of `core`). The brain is the source; the files are copies.
- **Home copy**: AKit's marked block (`InstructionsBlock`) in one harness's global file. In
  sync when its text is the core text as last rendered; else "Update Home Folder…".
- **Own text**: what a global file has outside AKit's block. Another tool's marked block in it
  (`<!-- NAME:START -->` … `<!-- NAME:END -->`, e.g. oh-my-claudecode) is **managed elsewhere**:
  shown, counted in the size, never taken over or edited by AKit.
- **Finding**: one problem in the global text, from any of the three analyses: section,
  severity (`critical` … `nit`, the review's `ReviewSeverity`), title, why, and an optional
  suggested change (replacement text for the section, or removal). A suggestion is applied as
  a diff of the core text and a brain commit, never straight into a file.

## Screen

Brain → a **Global Instructions** row above the layers (it is core's AGENTS.md text):

```
Global Instructions                         [Edit…] [Analyze…] [Update Home Folder…]
  Text (Markdown drawn; Source toggle)      2.1 KB ≈ 540 tokens
  Home copies
    Claude  ~/.claude/CLAUDE.md     in sync  · own text 6.5 KB (oh-my-claudecode 4.2 KB, yours 2.3 KB)
    Pi      ~/.pi/agent/AGENTS.md   update needed · own text 3.7 KB
    Codex   ~/.codex/AGENTS.md      no block (step 6)
  Own text left in the files: 2 sections            [Take Over…]
  Findings (last analysis, date)    CRITICAL 0 · HIGH 1 · MEDIUM 3 · LOW 2
```

- **Edit…**: the core text in an editor → Review Changes (diff) → Commit to Brain; then the
  home copies' diffs (as Move to Global's second step) → Apply.
- **Take Over…**: every section of own text in the global files (not managed elsewhere), with
  the harnesses that read it. Same text in two files counts once; same heading with other text
  asks which one. Ticked sections join the core text (one commit), the home blocks are written,
  and only then the sections leave the files (backup, `InstructionEdit`), each step after the
  one before worked (as `InstructionMove.finish`).
- **Analyze…**: the three analyses below, each can run alone; results are saved in the brain's
  machine-local folder (`~/.akit/local/instructions/analysis-<date>.json`, not committed: it
  may quote sessions).
- The Instructions screen keeps working as now; its AKit block row gets **Show in Brain**.

## Analysis

1. **Size and repeats** (no model). Per section: bytes, ≈ tokens, and tokens × the model
   requests recorded in the last 30 days (how much of the spend is this section; recorded
   counts only, no prices). Repeats: a section of the global text that is also in a project's
   instruction file (any known project, `InstructionDuplicates` across projects) or in an
   installed skill's SKILL.md; own text that repeats the core text.
2. **Model review**. One model call (as Rewrite with Skill…: the chosen harness's sign-in,
   send policy, scrub, monthly limit, send log). Input: the global text with section ids, the
   names of installed skills, MCP servers and `akit` commands (to check that rules point to
   things that exist). It reports contradictions, vague rules a model can't follow or check,
   rules a model does anyway (no effect, only cost), stale names, rules that belong in a skill
   or a project file, and a section order that buries the important rules. Each finding has a
   severity and a confidence (the review's scale) and may carry a suggested text.
3. **By sessions**. Recorded sessions of the last N days (default 14, all projects, Claude and
   Pi): the user's messages that correct the agent. A model call per batch matches them to
   global rules: "rule X was broken in 4 sessions", "the user asked for Y by hand 6 times and
   no rule says it". Each finding names the sessions (open in Sessions). Session text goes
   through the same send policy as Lab.

## Steps

| Step | What | Writes |
|---|---|---|
| 1 | Global Instructions in Brain: text, home copies with status, own text summary, Edit… (core text → commit → home blocks); `akit instructions global [--json]`; Show in Brain on the Instructions screen | brain, home blocks |
| 2 | Take Over…; `akit instructions take-over [--section ID]... [--yes]` | brain, home files |
| 3 | Analyze: size and repeats; `akit instructions analyze --global [--json]` | local file |
| 4 | Analyze: model review, findings with severity, Apply Suggestion… | local file, brain |
| 5 | Analyze: by sessions | local file |
| 6 | A Codex block in `~/.codex/AGENTS.md` (Codex reads no other global file) | home file |

## Not in this design

- Merging another tool's managed block (oh-my-claudecode) into the brain.
- Per-harness global text (a `when: target == pi` part of core stays hand-edited in the layer).
