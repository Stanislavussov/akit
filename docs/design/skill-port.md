# Port to Pi

Status: 2026-11-07, built on branch `port-skill-to-pi`: the deterministic pass, the model pass
with one feedback round, the check, `akit skills port` and Skills → Port to Pi…. Not built: a
smoke run of the port in `pi -p` (see Later).

## Question

Pi reads the same SKILL.md format as Claude Code (Agent Skills), but many Claude Code skills,
OMC's above all, call things Pi doesn't have: subagents (`Agent(subagent_type=…)`), the
question tool, task lists, MCP state tools, hooks and other plugins' commands. How does a
Claude Code skill become a Pi skill that keeps its meaning, and how do we know it did?

## Three passes

```
Claude skill folder ──► 1 deterministic (AKitSkills/SkillPort) ──► 2 model (AKitLab/SkillPortModel)
                                                                      │  lint leftovers? one more call
                                                                      ▼
                         preview + diff ◄── 3 check (AKitSkills/SkillPortCheck): pass | warnings | fail
                              │ confirm (--yes / Install…)
                              ▼
               ~/.pi/agent/skills/<name>  or  <project>/.pi/skills/<name>   (old folder → Trash)
```

1. **Deterministic** (no model, unit-tested). The folder is read into memory (hidden files
   left out; at most 400 files and 8 MB). SKILL.md's frontmatter keeps `name`, `description`,
   `license`, `compatibility`, `metadata`, `disable-model-invocation`; every other field
   (`allowed-tools`, `model`, `agent`, `context`, `hooks`, `argument-hint`, `user-invocable`…)
   is dropped. Every text file: `/<plugin>:x` → `/skill:x`, `~/.claude/skills` →
   `~/.pi/agent/skills`, `.claude/skills` → `.pi/skills`, `.omc/` → `.pi/state/`. Markdown only:
   `Read(`/`Write(`/`Edit(`/`Bash(` → lower case, "the Read tool" → "the `read` tool", Glob and
   Grep → `find` / `grep` via `bash`. OMC roles the skill names (`subagent_type=…`,
   `oh-my-claudecode:<role>`, or architect, critic, planner, analyst, executor, verifier as
   words) get their prompt copied into `references/<role>.md`: `agents/<role>.md` of the plugin
   the skill is in (up to three folders up, never above the home folder), else the newest under
   `~/.claude/plugins` (at most 7 levels deep).
2. **Model.** One call through `ModelCall.run` (sending policy, scrub, monthly limit, send log
   purpose `port-skill`), origin `.code(harness)`: the skill is the user's setup. The system
   prompt holds the rewrite rules (subagent → "switch role: read references/<role>.md", optional
   `pi -p` via bash; question tool → one question as text with numbered options, then stop;
   task lists → `.pi/state/<skill>.md`; MCP state and notepad → plain files; `Skill("x")` and
   handoffs → "next step: the user runs /skill:x"; hooks, magic keywords and `model=` removed)
   and the hard rule: never change the meaning of a step, a threshold or a number. The answer
   (JSON schema) is the whole SKILL.md, each changed file (new ones only under `references/`)
   and a list of changes; the deterministic pass runs again on it. When the lint still finds
   leftovers, they go back once as feedback: two calls at most. Model: the translation model
   unless one is picked.
3. **Check.**
   - Lint, each hit with file, line, text and rule: `Agent(`, `subagent_type`,
     `AskUserQuestion`, `TodoWrite`, `TaskCreate`, `mcp__`, `Skill(`, `state_write|state_read`,
     `notepad_`, `model=`, `/oh-my-claudecode:`, `~/.claude`, `.omc/`, `[MAGIC KEYWORD`.
   - Structure: a header with `name` and `description`; the name is the folder's and follows
     Pi's rules (`PiNameRule`); the description at most 1024 characters; every
     `references/…`, `scripts/…`, `assets/…` path SKILL.md names is in the port.
   - Meaning: numbers (`0.2`, `12`, `80%`) and headings of each original text (SKILL.md
     without its header) that the port lacks.
   - Verdict: a structure problem fails; leftovers and losses are warnings; else pass. A
     failed port is never written.

## Writing

The usual AKit rule: a preview first. The plan shows the target folder, whether one is there,
the SKILL.md diff and the changed files. Install writes into a hidden folder next to the
target, moves the old folder to the Trash, then renames the new one into place; it refuses
when the target appeared or went away since the preview.

## Surfaces

- `akit skills port SKILL [--to global|project PATH] [--model HARNESS[:MODEL]] [--no-model] [--json] [--yes]`
  and `akit skills port --check-only PATH [--json]`. Exit 1 on a failed check.
- Skills → a Claude Code skill (plugin skills too) → Port to Pi… (detail button and context
  menu): target (Global / Project), model (No Model, or a harness and model), Run, the report,
  the SKILL.md diff against the original or the folder there now, Install… with a
  confirmation. Snapshot: `--tab port --select <folder name>` (`port-report` runs it without a
  model).

## Module placement

`SkillPort` and `SkillPortCheck` live in `AKitSkills`: no model. `SkillPortModel` lives in
`AKitLab`, where `ModelCall` is; for it `AKitLab → AKitSkills` was added (architecture.md).

## Later

- A smoke run: start the ported skill in `pi -p` on a toy task and check that it loads, reads
  its references and asks its first question. Not built: it costs a model run per port and
  needs a toy task per skill.
- Each run calls the model again; a cache keyed by the source files and the model would let
  `--yes` reuse the preview's answer.
