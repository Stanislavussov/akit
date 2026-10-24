# MCP check: does the server connect, and what to do when it doesn't

Status: designed 2026-10-24 (grilling with the user); steps 1–4 built 2026-10-24 (`AKitMCP/MCPCheck.swift`,
`AKitFoundation/LoginShell.swift`, `akit mcp check`, `MCPWriter.undoPlan`, `AKit/MCPCheckViews.swift`, `AKitMCP/MCPApprove.swift`). Steps in [Steps](#steps).

## Goal

AKit adds, edits and switches MCP servers, but it can't say whether a server works. The
user finds out in the next agent session, often as a missing tool. This design adds a
check from AKit, a fix button for each failure that has one fix, a copy of a server from
one harness to the other, and the list of a server's tools.

```
Add / Edit → Apply ──► check this server ──► Connected ✓
                 ▲                      ├──► Needs Sign-In    → Sign In…
                 │                      ├──► Pending Approval → Approve…
                 │                      ├──► Missing Variables → Set Variable…
                 └── Edit Again / Undo ◄┴──► Failed / Timed Out (error text)
```

## Decisions

- **The harness checks, not AKit.** AKit doesn't speak MCP. It asks the harness that
  will run the server, so the result is what a session will get. Only Claude Code and Pi.

  | | Claude Code | Pi |
  |---|---|---|
  | One server | `claude mcp get NAME` | — |
  | All servers | `claude mcp list` | `pi mcp list --json` |
  | Output | text: Connected, Failed, Needs authentication, Pending approval | JSON per server: `state`, `tools`, `error` (with the tail of stderr), `exposure`, `enabled`; `note` for an untrusted project |
  | Sign in | `claude mcp login NAME` | `pi mcp login NAME` |

  Pi (checked in 1.0.4 and 1.4.0, the newest on npm on 2026-10-24) has no CLI check of one
  server: `pi mcp list` refuses a name (`dist/extensions/mcp/cli.js`), and
  `pi -p "/mcp reconnect NAME"` starts a session, which connects every server too
  (`docs/mcp.md`). So AKit runs `pi mcp list --json`, shows the server asked for first and
  keeps the other results, which cost nothing more.
- **When.** By a button: Check Connection on a server, Check All in the toolbar. And by
  itself after Apply in Add / Edit, for that server. Never when the screen opens: a check
  starts real processes (`npx`, `uvx`, docker) and may open OAuth.
- **Where.** The check runs in a folder, because that decides what the harness sees. A
  project server: in its project. A global server: in the project of the screen's filter
  (`Project · X`) when one is chosen, else in the home folder. So a server off in that
  project, or replaced by a project server with the same name, shows as such. A Pi project
  that isn't trusted gets "Pi doesn't trust this project yet: start Pi there once", not
  Failed.
- **Environment.** AKit.app started from the Dock has no variables of the user's shell.
  The check runs the harness through the user's login shell (`$SHELL -l -i -c …`), the same
  environment as a terminal. Before that AKit compares the server's `variables`
  (`MCPServer.variables`) with that environment and names the missing ones (Missing
  Variables). Only the JSON or the status lines are read from the output, so text that a
  `.zshrc` prints doesn't matter. Secrets in the `keychainLookup` mode work either way.
- **Only the status is read.** `claude mcp get` also prints the server's `Environment:` with
  its values, and `pi mcp list` its command line, so AKit reads only `Status:` / `Issue:`
  (Claude) or `state`, `error`, `tools` and `exposure` (Pi), and masks the error text.
  Both exit 0 or 1 regardless of the server, so the exit status is not used.
- **Timeout** 90 s per check. On timeout: "Timed out after 90 s; the first run of npx may
  download the package", and Check Again.
- **States.** Connected, Failed (with the error), Needs Sign-In, Pending Approval (Claude,
  `.mcp.json`), Untrusted Project (Pi), Off, Missing Variables, Timed Out. The last result
  is kept with its time ("Connected · 5 min ago") until the next check.
- **Fix buttons** next to the result:
  - Sign In… runs `claude mcp login NAME` / `pi mcp login NAME` (it opens the browser),
    waits, then checks again.
  - Approve… adds the name to `enabledMcpjsonServers` of the project's
    `.claude/settings.local.json`. Checked 2026-10-24 in Claude Code 2.1.310: its approval
    goes to `localSettings` (older answers in `~/.claude.json` are moved there by Claude), and
    counts only in a trusted folder (`hasTrustDialogAccepted`) where git doesn't track the
    file; `claude mcp get` then stops saying Pending approval. The file may hold secrets, so
    the preview shows only this key (`SettingsFile.change`), backup first; the user chose
    this over a terminal hint (an exception noted in `CLAUDE.md`). The preview notes an
    untrusted folder and a tracked file. Also `akit mcp approve NAME --project P [--yes]`.
  - Set Variable… stores the value in Keychain, like Set in Keychain… today.
- **After a failed check from Apply** the sheet stays open: the result, its fix button,
  Edit Again and Undo (the file back from the backup, or the new server removed). Nothing
  is undone by itself: Needs Sign-In or a slow first `npx` is no config error.
- **Copy to Pi… / Copy to Claude Code…** fills the Add Server form from the server
  (`MCPServerEditor` mode `.copy`, the draft of `MCPDraft.editing`: values stay hidden and in
  memory). The places offered are only those the other harness alone reads, the same level
  first. The user reads the diff and presses Apply; the check follows. A Keychain item keeps
  its name and reaches the other harness through its own mechanism (Claude's `headersHelper`
  or the stdio wrapper, Pi's `!security` lookups); a secret written in the source file goes
  into the Keychain, never into the new file; `${VAR}` stays as it is. Offered when a harness
  of the two doesn't read the server yet and has a place to write; not for plugin servers.
- **Tools are only shown.** The tools of a Pi server from its last check, with their
  exposure and whether Insights saw them used. No switches for single tools now (Pi
  `toolExposure`, Claude `mcp__server__tool` deny rules stay read-only).
- **CLI.** `akit mcp check [NAME] [--harness claude|pi] [--project P]`, the same states and
  error text, exit 1 when a checked server isn't Connected.

## Steps

| # | Step | Status |
|---|---|---|
| 1 | The check core (both harnesses, folder, login shell, missing variables, timeout, saved results in `~/.akit/mcp-checks.json`) and `akit mcp check` | built 2026-10-24 |
| 2 | UI: Check Connection, Check All, the check after Apply, the result with Edit Again and Undo | built 2026-10-24 |
| 3 | Sign In…, Set Variable…, Approve… and `akit mcp approve` (`AKitMCP/MCPApprove.swift`) | built 2026-10-24 |
| 4 | Copy to Pi… / Copy to Claude Code… | built 2026-10-24 |
| 5 | The tools of a Pi server | — |

## Later

- Switches for single tools (Pi `toolExposure`, Claude deny rules).
- Codex and OpenCode.
