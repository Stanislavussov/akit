# Lab: measuring how well agent sessions work

Status: design proposal 2026-09-28; implementation started 2026-09-30 (see
[Implementation plan](#implementation-plan-v1)). Replaces the Session Insights
decision "AKit has no own eval runner" (see [Relation to other designs](#relation-to-other-designs)).

## Goal

Answer "was this session efficient, and does setup A work better than setup B?" with
numbers that come from recorded data, not from the agent's own story. Start runs from
AKit with a button; watch them in the terminal tool you already use (Orca, herdr);
read the result in AKit.

Name: `akit check` already validates the brain, so this feature is **Lab**:
`akit lab …`, `~/.akit/lab/`, a Lab screen.

v1 scope: Claude Code sessions and replays (a review may run in Pi); Orca, herdr and
background launchers; one run at a time.

## What we learned first (2026-09-28, 21 AKit sessions)

- Cache hit ratio is 93–98% in every session. It is a health check, not a quality signal.
- About 95% of all tokens are cache reads. Total tokens ≈ calls × context size, so the
  useful cost numbers are **fresh tokens** (input + cache creation + output) and **API calls**.
- **Context rent** (each chunk's size × the number of later calls that re-read it) shows
  where the cost goes: ~22% baseline context (median 41k per call: system prompt, tools,
  CLAUDE.md, skill list), ~31% reading code (Bash `cat`/`grep`/`sed -n` 19%, Read 11%),
  ~21% the agent's own output (heredoc file writes stay in context), ~15% harness and
  plugin injections. The split inside one gap between calls is by characters, so it is
  approximate. Only attachments the model sees count: `hook_success` and
  `prompt_snapshot` records are log-only.
- Friction numbers (calls, re-reads of unchanged files, interrupts, rejected tool calls,
  commits that never reached master) clearly flagged the one bad session.
- Write amplification from Edit/Write inputs can't be measured: in auto mode most files
  are written through Bash.
- Linking commits to a session by hashes in its output is noisy (`git log --oneline -3`
  after a commit). Keep a hash only if its subject is in the commit command and its time
  is inside the session. Lab avoids the problem by giving each run its own session id.
- Survival of committed lines needs time (≈30 days) to mean anything.
- Absolute numbers of one session say little. Comparisons of the same task under
  different setups do. That is what replay tasks are for.

## Flow

```
AKit UI ──(1) run spec──▶ ~/.akit/lab/<run-id>/run.json   (queued)
   │
   └─(2) launcher: "run this command in folder X, tab title Y", returns a handle
          ├─ Orca        orca terminal create --worktree path:<X> --title <Y> --command <cmd> --json
          ├─ herdr       herdr pane split … → herdr pane run <pane-id> <cmd>
          └─ background  plain child process of AKit, no window
                         │
                         ▼
   ~/.local/bin/akit lab run <run-id>   (visible in the tab; the terminal only hosts it)
     1. prepare the work folder (replay: isolated clone at the base commit)
     2. start the harness with a session id chosen by AKit
     3. run checks (hidden tests under a memory watchdog)
     4. compute metrics from the transcript and git
     5. write result.json, state.json = finished
                         │
AKit UI ◀──(3) watches ~/.akit/lab/ and shows state and result
```

- One command for every environment: `akit lab run <run-id>`, called by absolute path
  (`~/.local/bin/akit`), since a terminal tab's PATH is not AKit's. The same command works
  from the CLI, an agent and the UI button (CLI first, the UI is a button on top).
- A launcher knows one thing: run a command in a folder with a title, and return a handle
  to bring that tab forward later. Launchers call their CLI with `--json` and store the
  handle (Orca terminal handle; herdr workspace and pane id) in `run.json`.
- AKit picks the session id (`claude --session-id <uuid> --name "Lab: …"`), so the
  run's transcript is known exactly.
- Terminal.app / iTerm are left out of v1: driving them needs the macOS Automation
  permission prompt. Other tools can get an adapter later.

## Kinds of runs

| Kind | Agent | Where it runs | Result |
|---|---|---|---|
| **Session analysis** | no | inside AKit, instant | cost, friction and context rent of one recorded session |
| **Session review** | a model call or an agent | terminal | one paragraph plus 0 to 3 improvements |
| **Replay task** | yes | terminal, N repeats × setups | hidden tests passed or not, and what it cost |

Session analysis is plain computation over the transcript and git; it needs no
terminal, no run folder and should be the first thing built.

## Where a run opens

Picked from the target folder, same path templates as session binding in
`session-insights.md`; the run sheet can override it.

- `~/orca/workspaces/{repo}/*` → Orca, that worktree.
- `~/.herdr/worktrees/{repo}/*` → herdr, that worktree.
- Repository root → the root (Orca: `path:<root>`).
- A session review opens where the reviewed session ran, if that folder still exists;
  otherwise at the repository root.
- A replay task runs in its own clone (see below), opened as a new tab in the tool of
  the repository's usual environment.

Commands checked against Orca 1.4.200, herdr 0.7.5 and Claude Code 2.1.283.

## Run lifecycle

`run.json` is written once by AKit. `state.json` is rewritten by `akit lab run` at every
phase change:

```json
{ "status": "queued | running | finished | cancelled | error",
  "phase": "prepare | agent | tests | metrics", "pid": 51234, "pidStart": 1790783456.12,
  "startedAt": "2026-09-28T18:02:11Z", "updatedAt": "2026-09-28T18:14:40Z" }
```

- AKit shows `running` only while the worker is alive: a process of this user with that
  pid and that start time (`pidStart`), so a reused pid is never taken for it. A dead
  worker without `finished` becomes `error` ("the run stopped: tab closed or crash").
- Cancel in AKit sends SIGTERM to the pid; `akit lab run` stops the harness, kills its
  test helpers and writes `cancelled`. Closing the tab (SIGHUP), Ctrl-C and SIGQUIT do the
  same: the agent and tests run in their own process groups and never see those signals.
- Starting a run, a worker taking its run and cancelling happen under
  `~/.akit/lab/queue.lock`, so a cancel can't cross a start.
- v1 runs one run at a time from a queue: parallel runs mean cold `swift build`s and
  test helpers of up to 2 GB each. Repeats and setups are queued runs. A finishing worker
  starts the next one; while AKit is open it also moves the queue on when a worker died.
  After a start fails, the queue waits for Start in AKit (or `akit lab start`).

## Run folder

```
~/.akit/lab/<run-id>/
  run.json        by AKit when queued: kind, target, setup, environment, the akit to run,
                  session id, repeat index, commit
  launch.json     by the launcher when started: environment and handle (Orca terminal;
                  herdr workspace, tab and pane; background pid)
  state.json      by `akit lab run`, see lifecycle
  result.json     by `akit lab run` at the end (schema below); the only writer
  review.json     { "findings": [ { "title", "evidence", "detail" } ] }: 0 to 3 improvements
                  (AKit shows at most 3); written by AKit from the model's answer, or by
                  the agent
  settings.json   (in ~/.akit/lab itself) Lab defaults: { "reportLanguage": "en|ru|cs" }
  summary.md      by the review skill only: one paragraph
  agent.jsonl     raw stream-json of a headless run; the tab shows a readable version
  check.log       hidden-test output, watchdog kills
  console.log     output of a background run (Orca and herdr show it in the tab)
  transcript.md   review: the reviewed session, masked (the app's Markdown export)
  analysis.json   review: AKit's metrics of the reviewed session
```

`result.json`:

```json
{
  "schema": 1,
  "metrics": { "calls": 146, "freshTokens": 700000, "cacheReadTokens": 24900000,
               "outputTokens": 120000, "peakContext": 299000, "baselineContext": 41000,
               "contextRent": { "baseline": 1380000, "readCode": 1950000, "ownOutput": 1320000,
                                "injections": 940000, "other": 690000 },
               "toolCalls": 180, "toolErrors": 5, "rereads": 0, "interrupts": 0, "rejected": 0,
               "compactions": 0, "commits": [ { "sha": "1a2b3c4", "subject": "…", "onMainBranch": true } ],
               "wallSeconds": 1820, "activeSeconds": 1400, "subagentCalls": 0,
               "subagentFreshTokens": 0, "models": ["claude-opus-5-5"] },
  "tests": { "status": "passed | failed | not-run",
             "failToPass": { "passed": 7, "total": 7 },
             "passToPass": { "passed": 3, "total": 3 }, "timeouts": 0 },
  "review": "ok | missing | invalid",
  "leaks": []
}
```

Context rent parts are tokens × calls (they add up to all context sent); the app and
`akit lab show` turn them into shares. Absent parts are left out (a review has no `tests`).

Who writes what:

- **Numbers come from `akit lab run`**, never from the agent: tokens, calls, context
  rent, tests, commits. An agent can't be trusted to report its own metrics.
- **A review is one model call by default**: AKit sends its numbers and a digest of the
  masked transcript (numbered items, long texts cut, thinking left out; tool results and
  then the middle of the session go first when it is still over ~90K tokens), the model
  answers with JSON, and AKit writes `review.json` and `summary.md` itself. The call goes
  through the harness with its own sign-in and model settings, never with keys AKit reads:
  Claude Code `-p --tools "" --safe-mode --system-prompt … --json-schema …` with the digest
  on stdin; Pi `-p --no-tools --no-skills --no-context-files --no-prompt-templates
  --system-prompt … @review-input.md`. No tools means an injected transcript can't make it
  touch any file.
- **As an agent (`--mode agent`) the reviewer writes only `review.json` and `summary.md`**, in the run folder
  where it runs (`AKIT_LAB_DIR`). The reviewed transcript may hold text written to steer an
  agent, so it gets only `Read`, `Write`, `Glob` and `Grep` (`--tools`, no MCP servers;
  in Pi `--tools read,write,grep,find,ls`, an allowlist that covers extension tools too).
  Claude Code also gets `--restricted`, which confines its file tools to the run folder and
  skips your settings files. Known gap: Pi's file tools reach any path, so a Pi agent review
  of an injected transcript could write a file elsewhere; one model call has no such gap.
  `akit lab run` validates `review.json` and records the review status separately from
  the test status; a missing or broken review never hides the numbers.
- The digest described here is planned to be replaced by the evidence-preserving digest
  of `error-analysis.md` (user turns verbatim, tool-output stubs that keep exit codes and
  error lines).
- Summaries and findings pass through `SecretFilter` before AKit shows them.

## Replay tasks

A task is made from a commit:

- **Prompt**: the commit message (subject and body) plus a fixed line: "Implement this
  in the repository. Build and tests must pass. Commit when done."
- **Base**: the commit's parent.
- **Hidden tests**: the commit's test files, copied into the work folder after the agent
  finishes.
- **Validation before use**: run the hidden tests on the base and on the commit itself.
  Tests that fail on the base and pass on the commit are *fail-to-pass*; tests that pass
  on both are *pass-to-pass*. A task needs at least one fail-to-pass test. Tests must use
  API that exists at the base, so good tasks are review rounds and fixes of existing
  code, not brand-new API.

Pilot (2026-09-28): `1c9cf65` "Report layer.yaml mistakes instead of dropping them
silently". On the commit 10/10 hidden tests pass. On the base 3 pass, 6 fail and 1 hangs
forever: 7 fail-to-pass, 3 pass-to-pass.

### Isolation: the answer must not be reachable

A git worktree shares refs and objects with its repository, so `git log master` or
`git show <sha>` would show the solution. Replay therefore runs in a fresh repository
that holds only the base commit's history: `git init work`, `git fetch --no-tags <repo>
<base-sha>`, `git checkout --detach FETCH_HEAD`. Checked on the pilot: no refs, no
remote, the answer commit is not among the objects. The original session transcripts are the
other leak (Claude's own history search, OMC `session_search` in the full setup):
after the run, Lab flags a replay whose tool calls or tool results mention the target
sha or a path under `~/.claude/projects`, or that called a `session_search` tool, and
leaves it out of comparisons. The subject line is not a sign: it is in the prompt, and the
agent's own commit usually reuses it.

The clone lives in a temporary folder with a random name, not in the run folder (its
`run.json` names the commit), and replay agents get no `AKIT_LAB_DIR`. After the checkout
`.git/FETCH_HEAD`, which names the source repository, is removed. When the run ends the
clone goes to the Trash (build folder included: the Trash grows), or into the run folder
as `work` when "keep" is ticked; no branch is left in the real repository. Beyond the
hash and the session history, the leak flag also catches tool calls that name the real
repository or `~/.akit/lab`.

### Test runner

Rules learned in the pilot:

- One test per process with a 30 s limit; on timeout kill the whole process group and
  any leftover `swiftpm-testing-helper` of that folder (it outlives `swift test`).
- `--filter 'Suite/name\('`; a run with 0 tests is "not run", not "pass".
- A watchdog kills test helpers above 2 GB (see the memory note about the 35 GB test).
  Builds are not held to it (compilers may need more); only test helpers are watched then.

### Setups to compare (Claude Code)

| Setup | Flags |
|---|---|
| full | your normal setup |
| lean | `--setting-sources project`: no user plugins or hooks (OMC, LSP, akit) |
| model / effort | `--model …`, `--effort …` |

Measured 2026-09-28 with a one-line prompt: first-call context 31k (full) vs 21.8k
(lean). Asked in both setups whether its instructions mention oh-my-claudecode and
whether `swiftui-expert-skill` is available, the model said yes to both in lean too, so
`~/.claude/CLAUDE.md` and `~/.claude/skills` still load. A fully clean setup would need
`--bare`, which only works with an API key (no OAuth); a separate `CLAUDE_CONFIG_DIR`
loses the login. Every setup pins model and effort explicitly, since `lean` doesn't read
the user settings that set them.

Every replay run gets the same safety flags:

```
claude -p --verbose --output-format stream-json --session-id <uuid> --name "Lab: …"
       --permission-mode auto --permission-prompts none
       --disallowedTools "Bash(git push:*)"
```

`--permission-prompts none` denies anything that would ask (there is nobody to answer in
headless mode); those denials count as `rejected`. Replay runs are headless so typing
into the run is impossible and setups stay comparable; the tab shows the stream in a
readable form. LLM runs vary, so a comparison needs at least 3 repeats per setup; the
Lab screen shows the spread, not only the mean.

## UI

- **Sessions → "Analyze"**: session analysis, shown in place.
- **Sessions → "Review in terminal…"** and **Lab → "New run…"**: kind, target (session,
  commit, task set), setup, repeats, environment (prefilled from the path). A review picks
  its agent: harness (Claude Code or Pi, when installed), model (Claude aliases; for Pi the
  models `pi --list-models` offers) and effort (Pi: thinking level). Replays stay Claude
  Code only: their numbers come from Claude Code transcripts.
- **Lab screen**: the queue and past runs with status, environment, target, time and key
  numbers. A run shows its summary, metrics, test results, Cancel while running and
  "Show in Orca/herdr" (`orca terminal switch --terminal <handle>` /
  `herdr pane` focus by the stored id). Runs of the same task line up as a setup
  comparison.

## Safety

- Replay runs in an isolated clone, never in the real repository; `git push` is denied;
  anything that would ask for permission is denied. `make install` and anything touching
  `~/Applications` stays with the user.
- Clones and run folders go to the Trash, like every other delete in AKit.
- Test runs always go through the watchdog.
- Lab reads transcripts; it never shows secrets (auth files, tokens, MCP env/headers,
  `settings.local.json`), same rules as everywhere else.

## Relation to other designs

- **Session Insights** (`session-insights.md`, branch `session-insights`): this replaces
  "AKit has no own eval runner". Skill-trigger evals still belong to skill-creator; Lab
  measures whole sessions and setups. Update that doc when both are on master. Lab reuses
  its path templates for picking the environment and, once merged, its SQLite index for
  session analysis.
- **Error analysis** (`error-analysis.md`): failure modes across many sessions, checks
  per mode and controlled evals of fixes; the one-session review becomes its first step.
  Its control sets may reuse replay tasks (an open question there).
- **Module split** (`architecture.md`, on hold): Lab is its own module (`AKitLab`);
  launchers live inside it.

## Implementation plan (v1)

Decided 2026-09-30 when building starts. Each step is one or more commits on branch `lab`
and ends with `make build`, `make test` and a snapshot of the screens it touches. Status
is kept here.

1. **Session analysis** — status: done 2026-09-30.
   - New module `AKitLab` (Foundation, Model, Sessions). `SessionAnalyzer.analyze(file)`
     reads one Claude Code transcript in order: API calls (one per `message.id`, main
     chain only; subagent calls and fresh tokens are counted apart), fresh and cache-read
     tokens, peak and baseline (first-call) context, context rent, tool errors, re-reads
     (a `Read` of the same file and range with no `Edit`/`Write` of it in between),
     interrupts (`[Request interrupted by user…`), rejected tool calls (the user's "doesn't
     want to proceed" and permission denials), commits (the `[branch sha] subject` line in
     the output of a `git commit` Bash call), wall and active time.
   - Context rent: the growth of the context between two calls is split by characters
     over what arrived in between (the agent's own output, code reads: `Read`, `Grep`,
     `Glob` and read-only Bash such as `cat`/`sed -n`/`grep`/`head`, harness injections,
     everything else) and multiplied by the number of later calls until the next
     compaction. The first call's context (and the first after a compaction) is the baseline.
   - Commits that reached the main branch: `git merge-base --is-ancestor` against
     `master`/`main` in the session's folder, when that folder is still a repository.
   - `akit lab analyze SESSION [--json]` (a transcript path or a session id).
   - App: an **Analysis** tab on the Sessions screen (Claude Code sessions), computed when
     it is opened.
2. **Runs** — status: done 2026-09-30 (checked with real Orca and background runs, and a real cancel).
   - `~/.akit/lab/<run-id>/`: `run.json` (written once when the run is queued),
     `launch.json` (environment and handle, written when it is started; a queued run has
     none yet), `state.json`, `result.json`, `console.log` (background runs).
   - `akit lab run <id>`: the worker, same phases as above; SIGTERM → `cancelled`. When it
     ends it starts the next queued run with the same launcher, so the queue moves on
     without the app. `akit lab start` starts the next queued run; `akit lab list`, `show`,
     `cancel`, `remove` (to the Trash).
   - Launchers: Orca (`orca terminal create --worktree path:<worktree> --title … --command
     … --json`; the folder must be an Orca worktree, else the repository root is used),
     herdr (`herdr tab create --workspace <the workspace whose worktree is the folder>
     --cwd … --label … --no-focus`, then `herdr pane run <root pane> <cmd>`; no such
     workspace → `herdr workspace create --cwd …`), background (a detached child of
     AKit, output in `console.log`). "Show" = `orca terminal switch` /
     `herdr workspace focus` + `herdr tab focus`.
   - The command in the tab is the absolute path of the `akit` that queued the run: the
     app uses `~/.local/bin/akit`, a development build its own worktree's
     `AKitCore/.build/debug/akit` when that exists.
   - App: a **Lab** sidebar section with the queue and past runs, run details, Cancel,
     Show in Orca/herdr, Remove, and **New Run…**.
3. **Replay tasks** — status: done 2026-09-30. The pilot `1c9cf65` validates as recorded above
   (7 fail-to-pass, 3 pass-to-pass, the hanging test killed at 30 s); the whole chain (task check,
   clone, agent, hidden tests, queue moving on, comparison) was run with a stand-in `claude`.
   - `akit lab task SHA [--repo DIR]` builds and validates a task and caches it in
     `~/.akit/lab/tasks/<sha>.json` (prompt, base, test files, fail-to-pass and
     pass-to-pass test names). Test names are read from the commit's test files: Swift
     Testing `@Test func name(` in a type `Suite` (filter `Suite/name\(`) and XCTest
     `func testName(` in an `XCTestCase` class. The package is the nearest folder with a
     `Package.swift` (SwiftPM only in v1). A queued replay validates its task in the
     prepare phase when no cached one exists.
   - Test runner: `swift build --build-tests` once (15 min limit), then `swift test
     --skip-build --filter …` per test, 30 s each, in its own process group; a watchdog
     checks the memory footprint of every process in the group and every
     `swiftpm-testing-helper`/`xctest` working in the folder every second and kills
     them above 2 GB.
   - Isolated clone as above, agent run with the safety flags, hidden tests copied in,
     metrics, leak flag, clone to the Trash unless kept.
   - `akit lab new replay SHA [--repo DIR] [--setups full,lean] [--model M] [--effort E]
     [--repeats N] [--env orca|herdr|background] [--keep]` queues repeats × setups,
     interleaved (one of each setup, then the second of each…). `akit lab compare SHA`.
   - App: New Run offers the commit, setups, model, effort, repeats; the Lab screen shows
     runs of one task side by side per setup (passed, fresh tokens, calls, wall time: median
     and range).
4. **Session review** — status: done 2026-09-30, built with step 2 as the first kind of run.
   - The review instructions ship inside `akit` (no skill to install). The run folder gets
     `transcript.md` (the masked Markdown export) and `analysis.json`; the agent runs
     headless in the run folder, reads them and writes `review.json` and `summary.md`.
   - `akit lab new review SESSION [--harness claude-code|pi] [--model M] [--effort E] [--env …]`;
     app: **Review in Terminal…** on a session.
   - Later (2026-09-30): the review is one paragraph and 0 to 3 improvements (the first
     version wrote up to 10 findings and a long summary; too much to read). The agent can
     be Pi (`pi -p --mode json`); AKit doesn't measure Pi sessions yet, so a Pi review has
     no numbers of its own. When the harness ends with an error (a refused model call),
     `result.json` keeps it as `agentError` and the Lab screen shows it.
   - Later (2026-09-30): one model call became the default (`--mode call|agent`); the
     agent stays for sessions too long for a digest.
   - Later (2026-09-30): an improvement is generic advice (a rule, skill, hook, setting or
     way of working that helps any session meeting the same barrier; its title names nothing
     of the reviewed project), `evidence` with the session's facts (items #n, numbers) that
     prove the barrier, and `detail` with what the advice improves. The review language
     (English, Russian, Czech) is a Lab setting in AKit's Settings, kept in
     `~/.akit/lab/settings.json`; `--language` overrides it and the run keeps it in run.json.

## Open questions

- Which few numbers belong on a run's card, and which only in details.
- herdr: focusing a pane that runs a headless `claude -p` (no agent detected) needs a
  check against the real tool before step 2.
- Whether task sets live in the brain repo (shared between Macs) or only in `~/.akit/lab`.
- Pi and other harnesses after v1: session id and headless flags differ.
