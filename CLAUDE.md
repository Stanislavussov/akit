# AKit — rules for coding agents

Native macOS SwiftUI admin app for AI harnesses (Claude Code, Pi, …).
Pi and other harnesses read this file too.

## Commit every iteration

- Every finished iteration ends with a git commit. An iteration is one small step
  that builds, passes tests and was checked (a feature, a fix, a review round).
- Before committing: `make build` and `make test` must pass. For UI changes, check
  the screen with `make snapshot OUT=<png> [SECTION=<section>]`.
- One commit = one logical change. Don't pile several iterations into one commit,
  and don't leave finished work uncommitted.
- Message: imperative summary line in English (≤ 72 chars), optional body with the why.
  Example: `Add Trash-based skill deletion with confirmation`.
- Never commit build output, `.omc/`, secrets or tokens (see .gitignore).
- Don't push, rewrite history or force anything unless the user asks.

## Project conventions

- UI text, code comments and docs are English only.
- Xcode project is generated: edit `project.yml`, then `make generate`. Don't commit
  `AKit.xcodeproj`.
- Logic lives in the `AKitCore` Swift package and is tested with Swift Testing
  (`make test`). Tests use a temporary fake home and never touch real config files.
- AKit only reads harness files unless a step explicitly adds safe writing
  (backup + diff first). Deleting moves things to the Trash.
- Never display or copy secrets: auth.json files, tokens, MCP env/headers,
  `settings.local.json`.
