# Port to Pi

Status: 2026-11-07, built on branch `port-skill-to-pi`: the deterministic pass, the model pass
with one feedback round, the check, `akit skills port` and Skills → Port to Pi…; then the
questions before the port and the user's extra rules with presets (same day). Not built: a
smoke run of the port in `pi -p` (see Later).

The flow: **Analyze → Questions → Port → Check.**

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

## Questions

Retargeting is generic: vitest → jest is one example among any technology, command, path or
convention. Before the port AKit asks the skill's choice points, from three sources that merge
(deduplicated by family):

1. **The alternatives catalog** (data, `SkillPortCatalog`). Families of interchangeable tools
   (test framework, package manager, HTTP client, logger, linter and formatter, ORM, CI, Python
   package tool, …), each member with regex tokens that detect it and literal tokens that must
   not remain after switching away, and pairwise rules where known (`vitest-to-jest`,
   `npm-to-pnpm`, `npm-to-yarn`, `npm-to-bun`, `axios-to-fetch`). A family the skill uses becomes
   a question: keep, or switch F to T (the pair's rules, else a note and F's forbidden tokens).
   The bundled catalog is JSON kept in `SkillPortCatalogData.swift` (a string, not a resource
   bundle: the standalone `akit` binary ships without one); the user adds families, members and
   pairs in `~/.akit/port-presets/catalog.json` (same format; a member or pair of the same id
   replaces the bundled one). No Swift logic names a technology.
2. **The model** (`SkillPortModel.suggestQuestions`), on by default whenever a model is used
   (`--no-model` turns it off): it reads the skill and returns choice points for anything the
   user might want changed, each option with the rules it implies, written by the model
   (replace, regex, forbid with at least one token, note). A question whose id or family is
   asked already, whose recommended option is missing or whose rules don't parse is dropped.
3. **Claude Code → Pi detectors** (a table in `SkillPortQuestions`):

| id | Raised by | Options (recommended first) |
|---|---|---|
| `subagents` | `Agent(`, `subagent_type=` | inline role switch with `references/<role>.md`; a real `pi -p` via bash |
| `questions` | `AskUserQuestion` | a numbered text question, stop the turn; keep (Pi has a questionnaire extension: `allow: AskUserQuestion`) |
| `state` | TodoWrite, TaskCreate, `state_*`, `notepad_`, `.omc/` | `.pi/state/<skill>/`; `.pi/state/` |
| `handoffs` | `Skill("x")` | tell the user to run /skill:x; drop |
| `model-hints` | `model=opus` etc. | drop; keep as plain advice |

Every question also takes **Other…** (`--answer ID=other:TEXT`), and the user can **Add a
change…** in plain words (`--change "replace axios with fetch"`). One model call
(`SkillPortModel.rules(forChanges:)`) turns these into rules with forbid checks based on what the
files contain; a change that gets neither a replacement nor a forbidden token is reported as
unchecked. They need a model.

An option is a rules text, so answers go through the same engine as the user's rules. An
unanswered question takes its recommended option; the report lists it as "(default)". The
target (global / project) stays `--to` and the sheet's picker, not a question: it needs a path.

## Extra rules

`SkillPortRules`, one rule per line: `FROM => TO` (literal; a FROM starting with a letter matches
at a word start, so `vi.` is not found in `navi.`), `re:PATTERN => TO` (`$1` in TO), `forbid: X`,
`note: text`, `allow: <built-in lint rule>`, `answer: id=option`, `#` comments. Replacements run
after the built-in ones, on every text file, in order, again on the model's answer. Notes,
replacements and forbids go into the model's system prompt as the user's hard requirements
(over the rewrite rules, never over the meaning rule). Each replacement's FROM (unless its TO
contains it) and each forbidden token is a lint rule: its hits are `source: user` and carry the
change that produced them (`origins`: an answer "package-manager: Switch npm to pnpm", a free
change's text), so the report groups hits by change (the CLI shows `[your …]` under each
change's heading); they go into the feedback round too. The
model also gets each non-Markdown file that has a hit. A rule's TO must not re-create its FROM,
or the second pass applies it again: `state`'s folder rule uses a negative lookahead for that.

Presets: every catalog pair is a built-in preset named `<from>-to-<to>`. Saved presets live in `~/.akit/port-presets/<name>.rules`,
not in the brain: they need no brain, need no brain commit, and on a work Mac its rules (tool
names of work projects) stay off the personal brain. A saved preset carries the answers too, so
a re-port with it asks nothing. Moving presets into the brain is a later choice if they should
follow the user to every Mac.

## Writing

The usual AKit rule: a preview first. The plan shows the target folder, whether one is there,
the SKILL.md diff and the changed files. Install writes into a hidden folder next to the
target, moves the old folder to the Trash, then renames the new one into place; it refuses
when the target appeared or went away since the preview.

## Surfaces

- `akit skills port SKILL [--to global|project PATH] [--model HARNESS[:MODEL]] [--no-model] [--json] [--yes]`
  and `akit skills port --check-only PATH [--json]`. Exit 1 on a failed check. Extra rules:
  `--rule` (repeatable), `--note`, `--forbid`, `--rules FILE|PRESET`, also for `--check-only`.
  `--questions [--no-model] [--json]` prints the choice points (catalog and detectors; the
  model's too unless `--no-model`); `--answer ID=OPTION` or `ID=other:TEXT` (repeatable);
  `--change TEXT` (repeatable). `akit skills port presets [save NAME FILE]`.
- Skills → a Claude Code skill (plugin skills too) → Port to Pi… (detail button and context
  menu): the Analyze page (each question as a Picker, the recommended option marked, Other…
  with a text field; Add a change…; Find More Questions, the default first step with a model, or
  Port Without Asking; Extra Rules with a preset Picker, the rules text and Save as Preset…), target
  (Global / Project), model (No Model, or a harness and model), Port, the report (leftovers
  grouped by the change that produced them),
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
