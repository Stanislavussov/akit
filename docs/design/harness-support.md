# Harness support: Claude Code and Pi

Status: 2026-10-11, checked against the code. One table of what AKit does for each
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
| Skills: description length warnings | yes: `description - when_to_use` over `skillListingMaxDescChars` (read from `~/.claude/settings.json`, default 1536) is cut there | yes: a description over 1024 characters gets Pi's warning; Pi still sends it all | `SkillScanner` problems on the Skills screen and in `akit skills state`; facts in `session-insights.md`, "Skill listing budget" |
| Skills: delete (Trash), install from skills.sh | yes | yes | skills.sh installs into the shared `.agents/skills` |
| Skills: move a global skill into some projects, and back | yes | yes: the only per-project control (Pi can't hide a global skill in one project) | through the brain into each project's answers, worktrees included; Move to Global the other way (core layer and home folder first); see `layers.md`, "Move a skill to a project" |
| Skills: remove everywhere (every place a harness loads it from) | yes: own copies, brain entries; plugin skills only with their plugin (Disable Plugin…, `enabledPlugins`); claude.ai skills through the switch | yes: own copies, brain entries; package skills not (filtered in the package's own entry, not written by AKit) | `layers.md`, "Remove a skill everywhere" |
| Skills: on / off without editing the skill | yes: On, Name Only, Manual, Off (`skillOverrides`); none for plugin skills | yes: On, Off (`skills` entries); none for package skills | see "Skill switches" below |
| Skills: Manual / Auto in the skill itself (`disable-model-invocation`) | yes | yes | one edit for every harness: the SKILL.md of your own copy, or the layer's mode for a global copy from the brain; see "Model invocation" below |
| Plugins / packages | Claude plugins listed | Pi packages on the Overview card: extensions, skills, prompt templates, themes | read-only; package code never runs. Limits per settings file and per refresh; a cut list or a too-large package gets a note |
| MCP: read, add, edit, remove | yes (`claude mcp` CLI) | yes (Pi's own `mcp.json` files and those of `pi-mcp-adapter`) | Pi 0.99+ reads `~/.pi/agent/mcp.json` and `.pi/mcp.json` itself (CHANGELOG 0.99.0, "MCP support as built-in extensions"); AKit takes the version from the package the `pi` command resolves to, else `lastChangelogVersion` in Pi's settings. The adapter's shared files and a project's `.mcp.json` still need `pi-mcp-adapter` |
| MCP: off without deleting (everywhere, in a project) | yes: user servers both; local and `.mcp.json` servers in their project; none for plugin servers; all claude.ai connectors at once | yes: servers of `~/.pi/agent/mcp.json` both; a project's `.pi/mcp.json` servers in their project | see "MCP switches" below |
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

### Model invocation

Built 2026-10-12. The Skills screen's **Model invocation** row (Auto / Manual; in the list's menu
Make Manual… / Make Auto…) is not a switch: it changes the skill itself, `disable-model-invocation:
true` in its SKILL.md, so every harness that reads the key follows it (Pi has no Manual switch).
Core: `AKitProjectSetup/SkillInvocation.swift` (`unavailable`, `plan`, `apply`); a diff first,
then Apply. Two paths:

- **Your own copy** (global or a project's; not rendered by AKit): the line is added
  (`Render.manualOnly`) or taken out (`Render.modelInvocable`: bare or quoted key, any spacing,
  value true; `false` counts as Auto and stays); BOM, line endings and every other byte stay. A
  file without a `---` header can't be made Manual. Apply is `SettingsFile.write`: refused when
  the bytes changed since the preview, backup in `~/.akit/backups`, rename over the real file.
- **A global copy AKit rendered**: a hand edit would come back at the next render, so the mode
  changes in the layer whose entry wins in the home folder's render (`LayerEditor.setMode`, a
  commit in the brain; with two layers listing the skill that is the `override: true` one, the
  only one whose mode counts), then the home folder's Apply rewrites only that skill's files, as
  Move to Global does. Refused, with nothing changed: the copy was edited by hand, the home plan
  has blockers, the home folder's own answers set the mode, or the brain's SKILL.md holds the
  flag itself (a layer's `auto` can't take it out).

`Frontmatter.disablesModelInvocation` is the one reading of the flag (key bare or quoted, a
trailing ` # comment` ignored, the header ends at a `---` with nothing before it): the skill
scanner and the writer both use it. A rendered copy's Apply runs in line with the Brain screen's
layer edits. When the layer file is written but the commit fails, or the commit is made but the
home folder's Apply fails, the error says which half is done and that Update Home Folder finishes it.

Not offered: a rendered copy in a project (its mode is the layer's or the project's, on the Brain
screen), a skill whose file lies inside the brain's folder (a link into it), plugin, claude.ai,
bundled and Pi package skills; the list's menu then has no item. The sheet notes when Claude Code's own
`skillOverrides` entry is Manual or Off (Auto in the file doesn't list it there), and when the
skill has a recorded source (an update from there may write over the edit). No CLI command yet.

**All global skills at once** (built 2026-10-14): Skills toolbar → Model Invocation → Make All Global
Skills Manual… (or Auto…), to keep the skill listing out of every session's context. Core:
`AKitProjectSetup/SkillInvocationBulk.swift` (`globalCandidates`, `planAll`, `applyAll`). The
candidates are global skills not already in the target state, one per real file. Own copies use
the one-skill plan each; rendered copies get their modes set together (`LayerEditor.setModes`, one
commit for every changed layer) and one home folder Apply for all their files. A skill that can't
change (the reasons above) is listed as skipped and the rest still change; a rendered copy whose
home file can't follow is dropped and the plan made again without it. At Apply, own copies go one
by one (a file changed since the preview fails alone); the error counts what changed.

## MCP switches

Built 2026-10-10, two review rounds the same day. A server is turned off in the harness's own
setting, never by deleting its entry. Core: `AKitMCP/MCPSwitches.swift`; `AKitProjectSetup/
MCPProjectSwitch.swift` adds the project's git (worktrees, exclude lines). Every write goes
through `SettingsFile` (see "Skill switches"). MCP Servers screen, Insights → MCP Servers
(context menu), `akit mcp state`, `akit mcp set`, `akit mcp connectors`.

Facts, checked 2026-10-10 (Claude Code 2.1.296: the installed binary, code.claude.com/docs/en/mcp
and /permissions; Pi 1.0.4: `docs/mcp.md`, `CHANGELOG.md` and `dist/extensions/mcp/config.js`):

| | Claude Code | Pi |
|---|---|---|
| Off Everywhere | `"mcp__<server>"` in `permissions.deny` of `~/.claude/settings.json`: the server's tools leave the context, the server still starts. The rule uses the tool-name spelling (every character other than letters, digits, `_`, `-` as `_`). Only for user servers (`~/.claude.json` `mcpServers`) | `"enabled": false` on the entry in `~/.pi/agent/mcp.json`: Pi keeps the entry and doesn't connect it |
| Off in Project | the name in `disabledMcpServers` of the project's entry in `~/.claude.json` (what `/mcp` → Disable writes; `Ao(name)` checks it for every server, whatever its scope). The entry's key is `getProjectPathForConfig` → `findCanonicalGitRoot`, NFC-normalized (`On`): `findGitRoot` (`Vn`) walks up from the physical folder (Claude Code starts from `getcwd`: `/private/tmp`, not `/tmp`) to the first one whose `.git` is a folder or file (lstat; a `.git` link counts only when it leads to a readable text file, `Ue`); outside git, the folder itself. Then `Xn`: a `.git` file whose `gitdir:` folder sits in `<commondir>/worktrees` (`commondir` and `gitdir` must be plain files) and whose `gitdir` file points back to this checkout's `.git` (real paths) is a linked worktree, keyed by the main checkout's top; a common dir not named `.git` (a bare repository) is the key unless it holds a `.git` itself. A submodule, a worktree moved without `git worktree repair`, or a `.git` file without `gitdir:` keeps its own top. So one entry covers the project and all its worktrees, and a project AKit knows as a subfolder of a repository uses the repository's root. A root Claude Code hasn't seen gets Claude Code's own default entry plus the list (the preview shows the whole entry). For `.mcp.json` servers AKit uses the same list rather than `disabledMcpjsonServers`, so the project's approval answer stays the user's | the folder's `.pi/mcp.json` (read from the folder Pi starts in, only in a trusted project; overrides since 1.0.1): `"enabled": false` on the project's own entry, or a `{ "enabled": false }` override of a user-level server (an override may set only `enabled`, `exposure`, `toolExposure`). Pi keys it by the folder, so AKit writes it in the main checkout and every git worktree; a worktree with no such server and no user-level one to override is skipped |
| Git | — | a folder whose real path leads out of its checkout is refused (no exclude line could cover it). A `.pi/mcp.json` that is missing or untracked gets a line in AKit's MCP block of `<git common dir>/info/exclude` (`# >>> akit mcp …`, apart from the local-only block that Set Up Project rewrites), added before the file is written; one exclude file covers every worktree. On leaves the line (and the file, which may hold other entries), and the preview says so. A tracked one is changed only when asked, and the preview says "Modifies a tracked file in N worktrees" |
| Later worktrees | nothing to do: the root's entry covers them | "Off in Project" is remembered in `~/.akit/mcp-off.json`; the app's refresh, its worktree sync (also the watcher of local-only projects) and `akit worktrees sync` give new worktrees the missing entry and exclude line. One sync at a time; what it added or couldn't write shows on the MCP Servers screen. A worktree where git tracks the file (or git can't tell) is never written on its own |
| claude.ai connectors | `disableClaudeAiConnectors: true` in `~/.claude/settings.json` turns all of them off (the binary names them `claude.ai <display name>`; AKit doesn't list them one by one) | — |
| On | removes the rule and the name from the list (an empty list stays, as Claude Code's own toggle leaves it) | removes the override AKit wrote, else `enabled: false` (Pi's default is on); without a project, in every folder where it is off and in every worktree of the remembered projects |
| Ownership | AKit records each entry it adds (`owned` in `~/.akit/mcp-off.json`), also when the check after a write fails. Off on an entry that is already there is a no-op and records nothing; On removes only AKit's entries. Reading the state drops a record whose entry is gone (turned on by hand or by `/mcp`), so a later `/mcp` Disable counts as the user's. A `mcp-off.json` that can't be read makes the switches Unknown and is never replaced. An entry made outside AKit (by `/mcp` or by hand) is shown as such and removed only when asked (Also Remove Entries Made Outside AKit, `--include-unmanaged`). Deny rules for some of a server's tools (`mcp__x__tool`, `mcp__x__*`) show as "Partly Denied"; AKit never writes or removes them | the same, for `enabled: false` |
| Not offered | plugin servers: their name is `plugin:<plugin or its marketplace alias>:<server>`, so AKit doesn't switch them alone; turn the plugin off with `/plugin` | servers in the shared files of `pi-mcp-adapter` (`~/.config/mcp/mcp.json`, `~/.agents/mcp.json`) and a project's `.mcp.json` |

Writing `~/.claude.json`, which Claude Code rewrites all the time: Claude Code saves it under a
proper-lockfile lock, a directory `~/.claude.json.lock` (`lockfilePath` `${e}.lock`, `stale:1e4`,
retries 200–4000 ms; the binary's `saveConfigWithLock`). AKit takes the same directory, waits at
most 6 s for it, takes over one older than 10 s, doesn't rename after holding it 7 s (so it never
needs to refresh it), and on release removes it only while it is the same directory (inode) it made. Under the lock it reads
the file again, refuses when a value the change touches differs from the preview, makes the same
edits on the fresh text and checks them as a tree edit, saves the backup from the bytes it read,
writes and syncs the new file next to it, compares the bytes once more and renames: the compare
and the rename are the last two steps. When only other bytes changed meanwhile it tries again (3
times) with one backup, which holds the bytes actually replaced; a write that doesn't happen leaves
no backup and no empty folder. Afterwards it reads the file and reports when an edited value isn't there. Backups in
`~/.akit/backups` (folders 0700, files 0600) are pruned to the newest 20 per file after a
successful write (they may hold tokens).

Pi's own MCP (0.99+): fixed 2026-10-10, see the "MCP: read" row; servers in `~/.pi/agent/mcp.json`
and `.pi/mcp.json` are no longer marked "Needs the pi-mcp-adapter package" on such a Pi.

Pi exposure (2026-10-24, for Pi doctor): `exposure` on the server's entry in the Pi `mcp.json` that
defines it (`direct`, `deferred`, `codemode` = the default and removes the key, `hidden`; mcp.md
"Control tool exposure"), through `SettingsFile` like the switches (`MCPSwitches.exposurePlan`,
`akit mcp set NAME --harness pi --exposure …`, Switches → Exposure → Change). Not written as a
project override of a user server. `akit mcp login NAME --harness pi` starts `pi mcp login`.

## Layers (`layers.md`)

| Feature | Claude Code | Pi | Note |
|---|---|---|---|
| Skills in `.agents/skills` | yes (via the `.claude/skills` link) | yes (read directly) | |
| `AGENTS.md` in a project | yes (via the `CLAUDE.md` shim) | yes | |
| JSON merge, key by key | `.mcp.json`, `.claude/settings.json` | `.pi/mcp.json`, `.pi/settings.json` | projects only, not the home folder; a value starting with `!` under env/headers is refused; keys a harness runs get a preview warning |
| Core layer's instructions in the home folder | block in `~/.claude/CLAUDE.md` | block in the file Pi reads in its agent folder (`AGENTS.override.md`, `AGENTS.md` or `CLAUDE.md`) | AKit owns only the marked block; see `layers.md`, "Home folder: instructions block" |
| Model notes (text for one model only) | proposal: SessionStart hook | proposal: extension, `before_agent_start` | not built: `model-guidance.md` |
| `pi-mcp-adapter` fields beyond env and headers | — | not checked | open: the adapter isn't installed here to verify (Pi's own MCP since 0.99 uses the same `mcpServers` shape) |

## Sessions, usage and insights (`session-insights.md`)

| Feature | Claude Code | Pi | Note |
|---|---|---|---|
| Session list, transcript, context footprint | yes | yes | Pi 1.0+ for the footprint |
| System prompt | as recorded in the session | captured now by running `pi` | Pi doesn't store its prompt; the screen shows today's |
| Usage and cost | yes (`cost-state`) | yes (per response) | |
| Failure signals | yes | partly: interrupts always 0 | decision: `definitions.md`, Failure signals |
| Insights: import, before/after, Apply | yes | yes | |
| Skill denominator, "descriptions dropped" | yes | no | decision: Pi records no skill list (`session-insights.md`) |
| Skill listing budget, Raise Budget… | yes (`skillListingBudgetFraction`, `skillListingMaxDescChars` read-only, `SLASH_COMMAND_TOOL_CHAR_BUDGET` in the command and `akit doctor`) | — (no budget, every description is sent) | `session-insights.md`, "Skill listing budget" |
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
