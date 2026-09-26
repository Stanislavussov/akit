# AKit

Native macOS app for AI harnesses (Claude Code, Pi, Codex, OpenCode): skills, MCP
servers, sessions, usage, and per-project harness setup from your own **brain** repo
of skills and layers. Comes with the `akit` command for agents and terminals.

## Install (one step)

Needs Xcode (opened once) and the GitHub CLI signed in (`gh auth login`); the script
installs `xcodegen` with Homebrew if it is missing.

```sh
bash <(gh api repos/Stanislavussov/akit/contents/install.sh --jq .content | base64 -d)
```

It clones the source into `~/Projects/akit` (or updates it), builds a release, and
installs `~/Applications/AKit.app` and `~/.local/bin/akit`. Run it again to update.
To bring your brain along: `AKIT_BRAIN_REPO=<owner>/<repo>` before the command; when a
brain is there, its core layer is rendered into `~` (skills for every harness; replaced
files are backed up in `~/.akit/backups`). `AKIT_SKIP_HOME=1` skips that.

From a checkout: `./install.sh`, or `make install` (both) / `make install-cli` (only `akit`).

## akit

```sh
akit check                                  # brain problems
akit layers [--json]                        # layers, fields, skills, files
akit plan  [PROJECT] --layers a,b --set field=value --targets claude,pi
akit apply [PROJECT] ...                    # backup first, removals to the Trash
akit plan --home / akit apply --home        # the core layer into ~ for every harness
akit --help
```

## Develop

`make build`, `make test`, `make run`; see `CLAUDE.md` for the rules and
`docs/design/layers.md` for the brain and layers design.
