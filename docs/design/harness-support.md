# Harness support: Claude Code and Pi

Status: 2026-10-09, checked against the code. One table of what AKit does for each
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
| Skills: enable / disable | no | no | not built for any harness |
| Plugins / packages | Claude plugins listed | Pi packages on the Overview card: extensions, skills, prompt templates, themes | read-only; package code never runs. Limits per settings file and per refresh; a cut list or a too-large package gets a note |
| MCP: read, add, edit, remove | yes (`claude mcp` CLI) | yes (JSON files of `pi-mcp-adapter`) | Pi servers show as inactive without the `pi-mcp-adapter` package |
| MCP secrets from Keychain | yes (`headersHelper`) | yes (`!` lookups) | each harness's own mechanism |
| MCP catalog | yes | yes | harness-neutral form |

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
