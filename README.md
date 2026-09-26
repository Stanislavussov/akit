# AKit

Native macOS app for AI harnesses (Claude Code, Pi, Codex, OpenCode): skills, MCP
servers, sessions, usage, and per-project harness setup from your own **brain** repo
of skills and layers. Comes with the `akit` command for agents and terminals.

## Install (one step)

Needs macOS 15+ and Xcode (opened once); the script installs `xcodegen` with Homebrew
if it is missing.

```sh
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Stanislavussov/akit/master/install.sh)"
```

It clones the source into `~/Projects/akit` (or updates it), builds a release, and
installs `~/Applications/AKit.app` and `~/.local/bin/akit`. Run it again to update.
From a checkout: `./install.sh`, or `make install` (both) / `make install-cli` (only `akit`).

## Your brain

The brain is your own git repo of skills and layers in `~/.akit/registry`; nothing in it
ships with AKit. Create one with `akit init` (or Brain → Create Brain Repo): it starts with
a `core` layer holding the `/akit` skill, so an agent can build layers and set up projects
for you. Keep it in a private repo to share it between Macs:

```sh
git -C ~/.akit/registry remote add origin git@github.com:<you>/brain.git
git -C ~/.akit/registry push -u origin main
```

On a work Mac, add `AKIT_MACHINE=work` (or run `akit machine work`, or Settings → This Mac):
answers and locks of its projects then stay in `~/.akit/local/projects` and never reach the
brain, so no work repo names or field values end up in your personal remote.

On another Mac, `AKIT_BRAIN_REPO=<you>/brain` before the install command clones it and
renders its core layer into `~` (skills for every harness; replaced files are backed up in
`~/.akit/backups`; `AKIT_SKIP_HOME=1` skips that). Afterwards `akit sync` (or Sync on the
Brain screen) pulls and pushes changes.

## akit

```sh
akit init                                   # create a brain
akit check                                  # brain problems
akit layers [--json]                        # layers, fields, skills, files
akit plan  [PROJECT] --layers a,b --set field=value --targets claude,pi
akit apply [PROJECT] ...                    # backup first, removals to the Trash
akit plan --home / akit apply --home        # the core layer into ~ for every harness
akit sync                                   # pull and push the brain
akit machine [work|personal]                # a work Mac keeps project records out of the brain
akit --help
```

## Develop

`make build`, `make test`, `make run`; see `CLAUDE.md` for the rules and
`docs/design/layers.md` for the brain and layers design.

## License

MIT, see [LICENSE](LICENSE).
