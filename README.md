# AKit

Native macOS app for AI harnesses (Claude Code, Pi, Codex, OpenCode): skills, MCP
servers, sessions, usage, and per-project harness setup from your own **brain** repo
of skills and layers. Comes with the `akit` command for agents and terminals.

## Install (one step)

```sh
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Stanislavussov/akit/master/install.sh)"
```

It downloads the latest release into `~/Applications/AKit.app` and `~/.local/bin/akit`
(macOS 15+, no Xcode needed), then `akit setup` asks three things, each with a default
(Enter):

1. **Your brain.** The brain is your own git repo of skills and layers in
   `~/.akit/registry`; nothing in it ships with AKit. Give the repo you use on your other
   Macs (`you/brain`), or press Enter for a new one: it starts with a `core` layer holding
   the `/akit` skill, and with the GitHub CLI signed in, setup offers to keep it in a
   private repo so your other Macs can use it. Or push it yourself:
   `git -C ~/.akit/registry remote add origin <url> && git -C ~/.akit/registry push -u origin HEAD`.
2. **Your projects folder** (`~/Projects`), shared with the app's Settings.
3. **Skills you already have in `~`** that differ from the brain's: kept unless you say
   replace (the old files are backed up in `~/.akit/backups`).

The core layer then goes into your home folder for every harness on the Mac. Run the
install again to update; `akit setup` is safe to run again (it syncs the brain and puts
new core skills into `~`). `akit sync` (or Sync on the
Brain screen) pulls and pushes the brain afterwards.

Without a release, or run from a checkout (`./install.sh`), it builds from source
(needs Xcode; `make install` / `make install-cli` do the same by hand). `make release`
builds `dist/AKit.zip` for a GitHub release.

## akit

```sh
akit setup                                  # the install questions again
akit init                                   # create a brain
akit check                                  # brain problems
akit layers [--json]                        # layers, fields, skills, files
akit plan  [PROJECT] --layers a,b --set field=value --targets claude,pi
akit apply [PROJECT] ...                    # backup first, removals to the Trash
akit plan --home / akit apply --home        # the core layer into ~ for every harness
akit sync                                   # pull and push the brain
akit --help
```

## Develop

`make build`, `make test`, `make run`; see `CLAUDE.md` for the rules and
`docs/design/layers.md` for the brain and layers design.

## License

MIT, see [LICENSE](LICENSE).
