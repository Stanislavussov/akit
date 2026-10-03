# AKit — rules for coding agents

Native macOS SwiftUI admin app for AI harnesses (Claude Code, Pi, …).
Pi and other harnesses read this file too.

## Commits and versions

- Commit medium-sized changes: one working, checked piece (a slice of a feature, a
  fix with its tests, a review round), not every small step and not a whole feature
  at once. Don't leave finished work uncommitted.
- Before committing: `make build` and `make test` must pass. For UI changes, check
  the screen with `make snapshot OUT=<png> [SECTION=<section>]`.
- When a feature is finished and merged into master, tag the merge with an annotated
  tag `vYYYY.MM.DD` (`-2`, `-3` … for more on the same day), message = what the
  feature does:
  `git tag -a v2026.09.27 -m "Session insights: stats and recommendations"`.
- Message: imperative summary line in English (≤ 72 chars), optional body with the why.
  Example: `Add Trash-based skill deletion with confirmation`.
- Never commit build output, `.omc/`, secrets or tokens (see .gitignore).
- Don't push, rewrite history or force anything unless the user asks.

## Project conventions

- UI text, code comments and docs are English only. One exception, at the user's request:
  the in-app guides `docs/guides/<name>.ru.md` are in Russian (other languages may follow
  as `<name>.<lang>.md`), with button and tab names quoted exactly as on screen. When a
  screen of a guided area changes, update its guide in the same commit.
- Xcode project is generated: edit `project.yml`, then `make generate`. Don't commit
  `AKit.xcodeproj`.
- Logic lives in the Swift package in `AKitCore/`, one module per area (`AKitFoundation`,
  `AKitHarnesses`, `AKitSkills`, `AKitSessions`, `AKitBrain`, `AKitInsights`, `AKitRender`,
  …; see `docs/design/architecture.md` for the map and allowed dependencies). The app and
  the `akit` command import only the modules they use. Tested with Swift Testing, one test
  target per module (`make test`). Tests use a temporary fake home and never touch real
  config files.
- `docs/design/README.md` is the map of the design docs: what is built, the order of the
  next steps and the open decisions. The commit that finishes a step updates its row there
  and the status note of its design doc.
- AKit only reads harness files unless a step explicitly adds safe writing
  (backup + diff first). Deleting moves things to the Trash.
- Never display or copy secrets: auth.json files, tokens, MCP env/headers,
  `settings.local.json`.
