# Skill modes: a skill's mode per project, with no file in the repository

Status: 2026-11-25, agreed with the user, revised the same day after an architect and a
critic review (the mechanism was checked end to end with Pi 1.5.2's SDK and a fake model).
Open decisions are at the end.

Built 2026-11-25, steps 1–5 (branch `skill-store`): `ProjectRecords.projectID(ofFolder:projectsRoot:)`
(`AKitBrain/FolderProjectID.swift`, a parity test with `LiveFolderResolver`); the core
(`AKitSkills/SkillModes.swift`, `SkillModesWrite.swift`); `akit skills mode`, `akit skills resolve`
(fast path in `akit/main.swift`, ≈ 9 ms with a release build) and `akit skills extension`
(`AKitCommandLine/SkillModesCommand.swift`); the extension (`AKitSkills/Resources/akit-skill-modes.ts`,
embedded by `tools/gen-skill-modes-extension.sh`, installer `SkillModesExtension`, node tests in
`make test` as `make test-skill-modes`, the end-to-end `make test-skill-modes-pi` passed on Pi 1.5.2 =
`minPi`); Doctor's "Skill modes" lines (`AKitDoctor/DoctorSkillModes.swift`). Not built: steps 6–7, and
the user's copy of `/akit` (the template has the section). Settled while building:

- `session_start` has no skill list, so the extension's first ask takes Pi's `/skill:` commands
  (`pi.getCommands()`, same names and paths); the cache key is the folder, the modes file's time and
  size, and the skill list. `input` uses the same cached answer.
- A rename is offered whether or not the project has entries: with none, its mode is the personal
  file's own frontmatter (what its SKILL.md says). A rename whose `my-` name is loaded already is
  left out and reported (`kind: rename`); `my-NAME: off` keeps it out of the list and refuses its `/skill:`.
- `resolve` returns modes only for names a loaded, non-temporary skill has; a bad stdin is a
  problem in the answer (exit 0), bad arguments exit 2.
- `akit skills mode NAME MODE` for a name Pi doesn't load here writes the entry with a note (the
  design keeps such names as "not found here"); outside git a write is refused.
- After the review (2026-11-25): a failed ask isn't cached (the next run asks again); the status
  line also names input and rename problems and, when the file doesn't apply, the renames that
  still did; skill names are looked up as own keys only (`constructor`); the modes file is 0600
  and a new file's preview is its whole text; a folder's project id and a session's are one
  implementation (`GitCheckout.repositoryFolders` + `ProjectRecords.projectID(commonDir:)`: links
  followed, the config's first 256 KB).

## Question

Every personal skill is Manual on this Mac (`disable-model-invocation: true`), so none of
them reaches a prompt by itself, and `/skill:x` runs any of them anywhere. In a few projects
some should be Auto, and some of the team's own skills should be quiet. How does the user
say "in col-fe these are Auto and that one is Off" so that:

- it is simple: one file, one command, one switch on the Skills screen; no layer, brain,
  path or render step to pick;
- it is easy to change and to undo, and an agent can do it from the terminal;
- it works in every checkout of the project, wherever a tool puts it (a git worktree in
  Herdr's folder, another agent's sandbox, a second clone);
- nothing personal lands in the project's repository, and nothing breaks when the team
  commits skills of its own, with the same names or not.

## Why not copies in the project

Today a project gets its skills as copies: `akit apply` renders the project's layers into
`<project>/.agents/skills`, keeps them out of git with `info/exclude` and links them into the
other worktrees (`layers.md`). For "Auto here, Manual elsewhere" that is the wrong tool:

| Problem | Cause |
|---|---|
| Pi warns `"x" collision` on every start in col-fe | the same name in `~/.agents/skills` and in the project (8 skills on 2026-11-25) |
| A team skill with the same name blocks the render or hides the personal one | Pi ranks project skills above user skills, always (Facts) |
| A worktree made after Apply has no copies | links come from Apply or the worktree sync, not from git |
| In Claude Code an Auto copy in the project does nothing | Claude Code keeps the personal copy over the project's |
| Several steps to change one skill | layer, answers, plan, apply, lock |

## The model

Two levels, each with one home:

| Level | Where it lives | How to change it |
|---|---|---|
| Global: the skill everywhere | the skill's own SKILL.md (`disable-model-invocation`), read by every harness | the existing Model invocation (`SkillInvocation`), also through `akit skills mode NAME auto\|manual --global` |
| Project: the skill in one project | `~/.akit/local/skill-modes.json` | `akit skills mode NAME auto\|manual\|off`, Mode Here on the Skills screen |

A skill's mode in a folder: the project's entry for its name if there is one, else what its
SKILL.md says. Nothing else: no default, no global section, no seed. A file with no entries
changes nothing.

```
   ~/.akit/local/skill-modes.json          { "<project id>": { "<name>": mode } }
                │
                │  akit skills resolve   (stdin: the skills Pi loaded; stdout: modes)
                ▼
   Pi loads skills ─▶ akit-skill-modes.ts (Pi extension) ─▶ prompt of this run
   (files untouched)   before each run: Auto / Manual / Off     lists only Auto ones
                       per name; /skill: of an Off one refused
```

Three modes, the same words in the file, the command and the screen:

| Mode | Listed in the prompt | `/skill:x` | Note |
|---|---|---|---|
| `auto` | yes | runs | |
| `manual` | no | runs | |
| `off` | no | refused: "x is off in this project (akit skills mode x --reset)" | not enforcement: the model can still read the file if it finds it, and `/` autocomplete still lists it. Pi's real Off (not loaded) stays the existing skill switch |

### The file

`~/.akit/local/skill-modes.json`, one per Mac, never in the brain or a repository (work
project ids stay on the Mac):

```json
{
  "version": 1,
  "projects": {
    "gitlab.apps.corp/cprdigital/projects/col/col-fe": {
      "diagnosing-bugs": "auto",
      "fsd-architecture": "auto",
      "team-review": "off"
    }
  }
}
```

- Keys are skill names as Pi lists them (the SKILL.md `name`, else the folder name).
- A name no loaded skill has is kept and shown as "not found here".
- Read per entry: an entry with an unknown mode is skipped and reported, the rest apply. Only
  JSON that doesn't parse, or another `version`, makes the whole file unapplied (reported by
  the extension's status line and by Doctor). AKit never rewrites a file it can't read.
- AKit writes it through `SettingsFile` (strict read, minimal edit, re-parse check, backup
  into `~/.akit/backups`, refusal when the bytes changed since the preview, atomic rename);
  `~/.akit/local` is created with mode 0700. Hand edits are fine: everything re-reads it.

### The project id

One function, `ProjectRecords.projectID(ofFolder:projectsRoot:)` in AKitBrain, used by the
resolver, the commands and the screen. It reads `.git` files without running git
(`GitCheckout.containing`), the way `LiveFolderResolver` does, and a test keeps the two equal:

- the `origin` remote of the repository's config, normalized (`normalizedRemote`):
  `git@gitlab.apps.corp:cprdigital/projects/col/col-fe.git` →
  `gitlab.apps.corp/cprdigital/projects/col/col-fe`;
- without `origin`: `local/…` of the main checkout, found through the git common dir, so
  every worktree of the repository has the same id (`ProjectRecords.projectID(for:)` uses the
  worktree's own path there, so it is not used for modes);
- `/private/tmp` and `/tmp` are the same folder;
- outside git: no project; only the SKILL.md applies.

So a worktree in Herdr's folder, a fresh clone and the main checkout share one entry, with
no Apply and no links. A clone whose `origin` is a mirror or a local path gets another id;
aliases can come later (Open decisions).

### Same name as the team's skill

When the project has its own `review` and the user has a personal `review`, Pi keeps the
team's and drops the user's (Facts). `resolve` sees that: for every loaded skill that is not
the user's (scope not `user`), it looks for a personal skill of that name in Pi's user
folders (`~/.agents/skills`, `~/.pi/agent/skills`) at another path. Each one comes back as a
rename, `my-review`, with its file, folder and description. The extension then:

- adds `my-review` to the run's skill list, pointing at the personal file (Auto or Manual by
  the project entry for `my-review`, else by that file's own frontmatter);
- turns `/skill:my-review args` into the same block Pi itself makes for `/skill:` (`<skill
  name=… location=…>` with the body, `agent-session.js` `_expandSkillCommand`).

No copy on disk, nothing in the repository. The prefix is a constant `my-` for now.

Which entry sets what (decided 2026-11-25, after review): an entry `my-review` always means the
user's own `review` in that project, whether Pi offers it as the rename `my-review` (the team
has a `review`) or loads it as `review` (no team skill, or an untrusted worktree where the team's
skills are absent). So for the user's `review` loaded under its own name, `my-review` sets its
mode when the project has that entry, and the entry `review` then applies only to a `review` that
isn't the user's. Without a `my-review` entry, `review` sets whatever Pi loads as `review`. The
list (`akit skills mode`) names the entry that set a mode when it isn't the skill's name.

Only a project skill (scope `project`, not a package's) hides one of the user's: Pi ranks packages
below the user's skills. A personal skill Pi doesn't load (`-skills/review/SKILL.md` or a matching
`!glob` in the `skills` list of Pi's user settings, what `akit skills set --state off` writes) is
not offered; with a pattern AKit can't read, or settings it can't read, no rename is made.

## Pi: the extension

`~/.pi/agent/extensions/akit-skill-modes.ts`, installed like `akit-record.ts`
(`CaptureInstaller`): an AKit marker line, a preview and a backup before replacing a file
without the marker. The TypeScript has no logic of its own; every decision is in Swift and
covered by `make test`.

- **Asking AKit.** `akit skills resolve --harness pi --cwd DIR --json` with the loaded skills
  on stdin (`{"skills":[{"name","scope","origin","path"}]}`), 3 s timeout, at most once per
  cwd and file mtime (cache). akit doesn't scan anything: it reads one small file and walks
  `.git`. The command takes a fast path in `akit/main.swift` before the brain and harness work
  (like `loop-check`, ~10 ms). Answer:
  `{"version":1,"project":"…"|null,"modes":{"x":"auto"},"renames":{"my-x":{…}},"problems":[]}`.
- **`session_start`**: clears the cache and starts the first ask (not awaited).
- **`before_agent_start`**: awaits the ask (bounded by the timeout), so `pi -p` with a single
  run gets the modes too. Builds a new skill list (modes applied, `off` left out, renames
  added) and assigns it in one statement, so an error midway leaves Pi's list as it was.
  Skills of scope `temporary` (`--skill`, flows) are never touched.
- **`input`**: `/skill:<name>` of an `off` skill: a notice and `handled`; `/skill:my-x`: the
  expanded block (`transform`).
- **Failure** (no `akit`, a timeout, bad JSON, an exception): no change, and one status line
  "skill modes: not applied, <reason>", cleared on the next success. So a failure can only
  bring back what the SKILL.md says (Manual for the user's skills); it never shows a Manual
  skill or leaks anything.

## Commands

In `/akit` (the manual skill), with `--json`; a write without `--yes` is a preview:

```
akit skills mode                           skills here (cwd): name, mode, from (project/skill),
                                           source (yours/project/package), renames
akit skills mode NAME auto|manual|off      set it for the project of the cwd
          [--project PATH]                   another folder's project
akit skills mode NAME --reset              take the entry out (the SKILL.md decides again)
akit skills mode --reset-project           take out all entries of this project
akit skills mode NAME auto|manual --global the SKILL.md itself (the Model invocation path)
akit skills extension install|status|uninstall    the Pi extension (uninstall: Trash)
akit skills resolve --harness pi --cwd DIR --json for the extension; read-only, stdin
```

`--global off` is refused with a pointer to `akit skills set NAME --harness pi --state off`
(the existing switch). `akit skills state` / `set` / `port` / `builtin` stay as they are. A
write while the extension is missing says so.

## Undo

- An entry: `--reset` (or Reset on the screen). A project: `--reset-project`. Everything:
  `akit skills extension uninstall` (the file stays, nothing applies it).
- Every write keeps the previous file in `~/.akit/backups`. There is no file-wide `--undo`:
  it would also undo a later change in another project.

## Screen

The Skills screen gets **Mode Here** per skill (Auto / Manual / Off for the project chosen at
the top) with a "from" label (Project, Skill) and Reset. It writes at once (a one-line
change, backup first). For the user's own skills it sits next to Model invocation (the
global level), so the two levels are visible side by side. The guide
`docs/guides/screens.ru.md` gets the section and a screenshot from the made-up home.

## Doctor

- The extension is missing or older than this AKit: a warning with `akit skills extension
  install`.
- The file doesn't parse, or entries were skipped: an error or a note with the reason.
- Pi older than the version the end-to-end test was run on (`SkillModesExtension.minPi`):
  "skill modes may not apply in Pi <version>". No SDK probe on every run.
- Entries for names no skill in that project has: a note.

## Limits

- Pi only. Claude Code has no hook into its skill list; its project setting lives in the
  repository (`.claude/settings.json`). Later, maybe: nothing to do for Claude globally, since
  the global level is the SKILL.md, which Claude Code reads.
- pi-subagents builds a child's skills from frontmatter (`pi-subagents/src/agents/skills.js`
  645–650) and some children run with `--no-skills` or `--no-extensions`, so a child doesn't
  get the project's modes.
- A team's skills load only in a trusted project, and Pi keeps trust per folder: in a new,
  untrusted worktree the team's skills are absent, whatever the file says.
- Outside a run Pi reports the base prompt (`session.systemPrompt`), so tools that show the
  prompt between runs show the skills before the modes.
- The search for the user's own skills behind a rename follows Pi's folders and their order
  (`~/.pi/agent/skills`, then `~/.agents/skills`) and its override entries, but not the
  `.gitignore` / `.ignore` / `.fdignore` files Pi honours inside them, nor extra skill paths listed
  in Pi's settings: a skill hidden only by an ignore file can still come back as `my-NAME`.
- A mode change costs one system patch on the next run; on providers that fold system
  messages into the head (`supportsMidConvoSystemMessages` false) that is one cache miss.

## Facts (Pi 1.5.2, checked 2026-11-25)

From `@earendil-works/pi-coding-agent` 1.5.2 `dist/`, and an end-to-end script with the SDK,
pi-ai's faux provider and a fake home (scratchpad `critic/modes.mjs`):

- Precedence, `core/package-manager.js` `resourcePrecedenceRank`: project settings entry 0,
  project auto-discovered (`.pi/skills`, `.agents/skills`) 1, user settings entry 2, user
  auto-discovered (`~/.pi/agent/skills`, `~/.agents/skills`) 3, package 4. The first name
  wins; each loser gets a `collision` diagnostic shown at startup. A user's skill never beats
  a project's skill of the same name (also checked with `pitest/check.mjs`).
- `disable-model-invocation: true` → `skill.disableModelInvocation`; the skill stays in
  `systemPromptOptions.skills`, `formatSkillsForPrompt` (`core/skills.js` 279) leaves it out,
  `/skill:x` runs it.
- `before_agent_start` gets a fresh copy of the base options per run (`runner.js` 1130,
  `system-prompt.js` 22); the run's prompt is built from the edited copy (`agent-session.js`
  1552, 1589–1590), later turns of the run keep it (598–607), and it is dropped after the
  run (1532). The first system message is built from the edited options; the same edits
  again add no patch; a change adds one patch with only the `skills` section (end-to-end).
- Handlers run in extension load order; user extensions load before package ones, and also
  in untrusted projects (`docs/extensions.md` 127, 414). An exception in a handler is caught,
  but what it already changed stays (`runner.js` 1129–1170).
- `input` runs before `/skill:` expansion in `prompt` (1736→1745) and in steer/follow-up
  (1840→1843), and print and RPC mode go through them; `handled` kept `/skill:t1` from the
  model (end-to-end). `sendUserMessage` doesn't expand `/skill:` by default (2035).
- `/skill:` expansion and command registration use the loaded skills, not the run's options
  (1817, 2853); `_expandSkillCommand` builds `<skill name location>` + body.

## Steps

Each step is one commit (or a few), with `make build` and `make test`; the commit that
finishes a step updates its row in `README.md` and the status note here.

1. **Project id from a folder** in AKitBrain, with the parity test against
   `LiveFolderResolver` (main checkout, linked worktree, no origin, `/private/tmp`, no git).
2. **Core** (`AKitSkills/SkillModes.swift`, `SkillModesWrite.swift`): the file model, the
   per-entry read, `resolve(file:skills:projectID:userFolders:)` → modes, renames and
   problems; plan/apply with backup; reset of an entry and of a project.
3. **CLI**: `akit skills resolve` (fast path), `akit skills mode`; the usage text, the `/akit`
   template (`AKitBrain/AKitSkill.swift`) and the user's copy.
4. **Pi extension**: the TypeScript source in `AKitSkills/Resources` with a generated Swift
   string and a drift test (as the flow templates do), node tests with a fake `pi` and a fake
   `akit` (inside `make test`), the installer (`SkillModesExtension`) and
   `akit skills extension install|status|uninstall`; an end-to-end target
   `make test-skill-modes-pi` with the SDK and the faux model (outside `make test`, skipped
   without Pi) that sets `minPi`.
5. **Doctor** checks.
6. **Projects stop getting skill copies for Pi** (refined 2026-11-25 by the lead):
   - The home render (`ProjectSetup.plan(forHome:)`) also brings the brain skills the saved
     Pi-only projects use (`ProjectBundle.resolve(homeSkills:)`): the core layer's keep their mode,
     the others are Manual (`manualOnly`). Files AKit didn't write or that were edited by hand are
     never overwritten, as before. (The lead's first rule was every brain skill; that would bring
     back a skill Remove Everywhere or Move to Project took out of the home folder, so only the
     skills a Pi-only project needs come.)
   - A project whose targets are only Pi, in git: Apply renders no skills into it (no
     `.agents/skills/<name>`, no `.claude/skills` link, so no exclude lines or worktree links for
     them); everything else is unchanged. Copies an earlier Apply wrote go to the Trash through
     the usual removal; edited ones stay and are listed. A Pi-only folder outside git keeps its
     copies (no project id), and so does every project with another target.
   - The project's modes go into `~/.akit/local/skill-modes.json` in the same Apply (preview
     line, backup): an entry for each skill whose project mode differs from the home folder's
     (core's mode, else Manual): Auto → `auto`, Off → `off`, Manual over a home Auto → `manual`.
     An entry the user set stays (a note says so on a conflict); the lock keeps the entries AKit
     wrote, which follow the layers and leave when the layers stop asking for them (unless changed
     since). Project id: `ProjectRecords.projectID(ofFolder:)`.
   - `akit plan` / `apply` and Set Up Project show it in plain lines (notes); Forget Project also
     takes the project's entries out (preview first).
7. **Skills screen**: Mode Here, Reset, the guide and its screenshot.

## Not doing

- No setting written into a repository (`.pi/settings.json`, `.claude/settings.json`), not
  even one ignored by git.
- No edits to skill files for a project's mode, and no copies of skills for it.
- No new layer or brain concept.

## Open decisions

1. **Aliases for project ids** (a mirror remote, a renamed repository): later, only if it
   happens.
2. **Layers and skills.** After step 6, whether the brain's skills should still be rendered
   to the home folder through the core layer, or live in `~/.agents/skills` with the brain as
   their history. Decide once modes are in use.
3. **The rename prefix** `my-`: a setting, if the user wants another.
