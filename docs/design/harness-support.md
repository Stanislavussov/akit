# Harness support: Claude Code and Pi

Status: 2026-10-10, checked against the code. One table of what AKit does for each
harness, so a gap is either a decision written down somewhere or a known gap listed here.
Each row names the design that owns it; details stay there. OpenCode and Codex are read
for skills and MCP only (`AKitHarnesses`) and are not covered here.

Legend: **yes** — works the same way; **partly** — works with a stated limit; **no** — not
built. The last column says whether the gap is a decision (with its doc) or open.

## Reading and setup

| Feature | Claude Code | Pi | Note |
|---|---|---|---|
| Detection, config locations | yes | yes | Pi: the `pi` binary or `~/.pi/agent`; `PI_CODING_AGENT_DIR` honoured |
| Projects from the harness's history | yes (`~/.claude.json`) | yes (cwd in the header of session files; a custom flat session folder too) | Pi: a project's own `sessionDir` and `--session-dir` are not followed |
| Skills: list, collisions, name rules | yes, plugin and synced skills read-only | yes, package skills read-only | Pi package skills from `packages` in global and project settings |
| Skills: delete (Trash), install from skills.sh | yes | yes | skills.sh installs into the shared `.agents/skills` |
| Skills: on / off without editing the skill | yes: On, Name Only, Manual, Off (`skillOverrides`); none for plugin skills | yes: On, Off (`skills` entries); none for package skills | see "Skill switches" below |
| Plugins / packages | Claude plugins listed | Pi packages on the Overview card: extensions, skills, prompt templates, themes | read-only; package code never runs. Limits per settings file and per refresh; a cut list or a too-large package gets a note |
| MCP: read, add, edit, remove | yes (`claude mcp` CLI) | yes (JSON files of `pi-mcp-adapter`) | Pi servers show as inactive without the `pi-mcp-adapter` package |
| MCP secrets from Keychain | yes (`headersHelper`) | yes (`!` lookups) | each harness's own mechanism |
| MCP catalog | yes | yes | harness-neutral form |

## Skill switches

Built 2026-10-10, review round the same day. A switch changes one entry in the harness's own
settings file; the skill's files stay as they are. `AKitFoundation/SettingsFile.swift` holds the
safety steps every such write uses (MCP switches too):

- read strictly (no comments, no repeated keys); a file that can't be read makes the switch
  Unknown, with the reason, and is never written;
- edit the text in place (`JSONTextEdit`): other keys, their order, spacing and line endings
  (`\r\n` too) stay byte for byte; keys are compared by Unicode scalars, as harnesses do;
- parse the result and check it equals the old tree with only the intended change, else refuse;
- preview only the changed object (`skillOverrides`, Pi's `skills`), with `env`/`headers` values
  and token-shaped strings hidden, so no neighbouring key (`apiKeyHelper`, hooks, `statusLine`)
  is shown;
- on Apply: refuse when the file's bytes changed since the preview, back it up into
  `~/.akit/backups`, write a temporary file with the old mode and extended attributes, rename it
  over the file (through a link, to the real file).

Core: `AKitSkills/SkillSwitches.swift`; Skills screen, Insights → Skills (context menu),
`akit skills state`, `akit skills set`.

Facts, checked 2026-10-10:

| | Claude Code (2.1.296) | Pi (1.0.4) |
|---|---|---|
| Source | settings schema (json.schemastore.org/claude-code-settings.json), code.claude.com/docs/en/skills ("Override skill visibility from settings"), the installed binary | `dist/core/package-manager.js` (`isEnabledByOverrides`, `addAutoDiscoveredResources`), `dist/modes/interactive/components/config-selector.js` (`pi config`) |
| File AKit writes | `~/.claude/settings.json` (`CLAUDE_CONFIG_DIR` honoured) | chosen by the folder Pi finds the skill in (a link from `~/.agents/skills` into a project is personal): personal folders → `~/.pi/agent/settings.json` (`PI_CODING_AGENT_DIR` honoured); a project's own folders → `<project>/.pi/settings.json` (Pi applies only the project's entries to them). Pi reads the project file only when it starts in the project folder (`settings-manager.js` reads `join(cwd, ".pi", "settings.json")`); one entry covers the skill in both `.pi/skills` and `.agents/skills`. A `skills` value that isn't a list is refused |
| Key | `skillOverrides: {"<name>": "on" \| "name-only" \| "user-invocable-only" \| "off"}`; absent = on | `skills: ["…"]`: `!glob` turns matching skills off, `+path` back on, `-path` off (exact, wins); plain entries are extra skill paths, not filters; absent or empty = every found skill on |
| Name | the folder name Claude Code reaches the skill through (the loader passes the directory entry's name as `skillName`; the SKILL.md `name` only becomes the display name), so `~/.claude/skills/deploy-staging` with `name: deploy` is `deploy-staging`; a claude.ai skill is `anthropic-skills:<folder>` (its bare folder name matches too, unless reserved); a nested `.claude/skills` folder's skill (`apps/web:deploy`) is not listed by AKit. The entry applies to every skill with that name, in every project; a project's `.claude/settings.json` entry wins over the user's. `akit skills set` also takes the SKILL.md name and says which folder name it used | the path relative to the skill folder's parent: `skills/<folder>/SKILL.md` (what `pi config` writes); `!` globs also match the folder name and absolute paths. AKit reads the minimatch subset `*`, `?`, `**`, `[…]`, `{a,b}` (bounded work); an `!` entry with extglobs, POSIX classes or `{1..3}` makes the state "set by a pattern AKit can't read" (Unknown) and AKit won't change the list |
| States AKit offers | On, Name Only, Manual (= `user-invocable-only`: only `/name` runs it, the description isn't sent), Off; a SKILL.md with `disable-model-invocation: true` is Manual at most, so only Manual and Off | On, Off (Pi has no name-only state; `disable-model-invocation` in SKILL.md is a file edit, not a switch) |
| What AKit writes | Off/Name Only/Manual: sets the entry; On: removes it (and `skillOverrides` when it becomes empty) | takes out every `!`/`+`/`-` entry naming exactly this skill, then adds `-skills/…/SKILL.md` (off) or `+…` (on, only when a glob still turns it off); an empty list is removed |
| Not offered | plugin skills: Claude Code ignores `skillOverrides` for them (docs; code returns "on" for `source === "plugin"`, `/skills` says "managed with the plugin") | Pi package skills: they are filtered in the package's own entry |
| Not read | `settings.local.json` (Claude Code's own `/skills` menu writes there; AKit never reads it) | — |

## Layers (`layers.md`)

| Feature | Claude Code | Pi | Note |
|---|---|---|---|
| Skills in `.agents/skills` | yes (via the `.claude/skills` link) | yes (read directly) | |
| `AGENTS.md` in a project | yes (via the `CLAUDE.md` shim) | yes | |
| JSON merge, key by key | `.mcp.json`, `.claude/settings.json` | `.pi/mcp.json`, `.pi/settings.json` | projects only, not the home folder; a value starting with `!` under env/headers is refused; keys a harness runs get a preview warning |
| Core layer's instructions in the home folder | block in `~/.claude/CLAUDE.md` | block in the file Pi reads in its agent folder (`AGENTS.override.md`, `AGENTS.md` or `CLAUDE.md`) | AKit owns only the marked block; see `layers.md`, "Home folder: instructions block" |
| `pi-mcp-adapter` fields beyond env and headers | — | not checked | open: the adapter isn't installed here to verify |

## Sessions, usage and insights (`session-insights.md`)

| Feature | Claude Code | Pi | Note |
|---|---|---|---|
| Session list, transcript, context footprint | yes | yes | Pi 1.0+ for the footprint |
| System prompt | as recorded in the session | captured now by running `pi` | Pi doesn't store its prompt; the screen shows today's |
| Usage and cost | yes (`cost-state`) | yes (per response) | |
| Failure signals | yes | partly: interrupts always 0 | decision: `definitions.md`, Failure signals |
| Insights: import, before/after, Apply | yes | yes | |
| Skill denominator, "descriptions dropped" | yes | no | decision: Pi records no skill list (`session-insights.md`) |
| Recommendations | yes | Pi-only skills shown as "no data" | decision: `session-insights.md` |
| Quick ratings on Sessions | no | yes | decision: built for Pi first (`error-analysis.md`) |

## Measuring (`lab.md`, `error-analysis.md`, `layer-evals.md`)

| Feature | Claude Code | Pi | Note |
|---|---|---|---|
| Lab review of a session | yes | yes, transcript only (no AKit numbers) | decision: `lab.md` |
| Sessions → Analysis, `akit lab analyze` | yes | no | decision: `lab.md` |
| Replays | yes | no | not built: `lab.md`, "Pi replays" |
| Control cells, plain setups | yes | yes, without metrics or denied commands | `layer-evals.md` |
| Control tasks judged by hidden tests | yes | no | decision: the leak check reads Claude Code's transcripts (`layer-evals.md`, Oracle) |
| Layer evals | yes | no | decision I2: v1 for Claude Code only (`layer-evals.md`) |
| Error analysis: sampling, notes, judging | yes | yes | Pi notes get no AKit numbers |

## Keeping this current

The commit that changes what a harness gets updates its row here, like the design map
(`README.md`, I6).
