# Shared definitions: Session insights, Lab, Error analysis

Status: 2026-10-01. One place for the terms that `session-insights.md`, `lab.md` and
the error analysis design (`error-analysis.md`) use, so a field means the same thing in
the index, in a Lab result and in an analysis step. A design doc links here instead of
defining these again.

Checked against the code on 2026-10-03. Built: the data tiers with the sending policy,
session and request keys, `first_request_context`, exposures with `desc_hash`, `origin`
and `commit` of the repo snapshot; the shared `FailureSignals` (2026-10-08). Not built:
name-only reasons and "over budget", the harness fingerprint, `dirty` and `diff_hash`.
Each section below says so where it applies.

## Data tiers

What AKit keeps or sends, by how close it is to message text.

- **Tier 0: index facts.** `~/.akit/index/`: sessions, requests with recorded tokens, tool
  calls with sizes, skill exposures and calls, signal counts, hashes. Never message text,
  with one opt-in exception: the masked user request behind a manual `/name` call
  (`session-insights.md`, Evals). Per-machine summaries in the brain are built from
  Tier 0 only.
- **Tier 1: local derived text.** `~/.akit/lab/`: digests, notes, quotes and exemplars
  of reviews and error analysis. Local only, opt-in, never in the brain.
- **Tier 2: egress.** A transcript or a digest sent to an LLM provider (a Lab review, an
  error analysis step, a judge), only when the user starts that step.
  - Every send goes through the sending policy of `error-analysis.md` (built
    2026-10-01): the scrubbed digest goes through the harness the user picked, with that
    harness's own sign-in and provider, and only back to the harness and provider that
    recorded the session or to a destination on the allowed list (harness + provider +
    account + org), checked before every send. The list is empty by default on a work
    machine, where repository code goes only to it.

The sentence every design uses: *AKit never uploads sessions anywhere; a transcript
reaches an LLM provider only in a review or analysis step the user starts, and only to a
destination the sending policy allows (none by default on a work machine).* Claude Code's own `/insights` sends transcripts to a model too; AKit says it
plainly instead of claiming "sessions never leave the machine".

## Session and request

- **Session key**: harness + the harness's own session id.
- **Request**: one model response. Claude Code key: `message.id` (fallback `requestId`),
  global across files, since resumed sessions and forks copy lines into another file.
  The lines of one response repeat the id with growing `output_tokens`; the last line
  carries the final count (checked 2026-10-01: in 12,170 of 12,170 multi-line responses
  in recent logs the last line had the largest count). Pi key: `<entry id>@<timestamp>`.
- **`first_request_context`**: input + cache read + cache write of the session's first
  main (non-subagent) request. Same meaning as OpenTelemetry's
  `gen_ai.usage.input_tokens`, which "SHOULD include all types of input tokens, including
  cached tokens"; Anthropic's own `input_tokens` excludes the cache. On export the fields
  are `gen_ai.usage.input_tokens`, `gen_ai.usage.cache_read.input_tokens` and
  `gen_ai.usage.cache_creation.input_tokens`.

## Skill exposure

- **Exposure**: one skill in one `skill_listing` attachment (Claude Code). Pi records no
  listing yet.
- **Described exposure**: an exposure whose description is in that attachment
  (`desc_hash` is not NULL in the index). Only described exposures count toward a
  denominator: a skill listed by name only can't be picked by its description.
- **Name-only reason**: why an exposure has no description. `override`: the user's
  `skillOverrides` set the skill to `name-only` at session start. `empty`: the skill has
  no description. `unknown`: the session has no start line saying which overrides were
  set, and the skill was not listed with its description elsewhere that day. `budget`: none of these, so Claude Code dropped it to keep the listing within its
  budget (1% of the context window by default).
- **Over budget**: a listing with at least one `budget` exposure.

Status: exposures and `desc_hash` are in the index. The described-only denominator is built
(2026-10-08, step 8 of `session-insights.md` as simplified by proposal I1): stats,
recommendations and summaries count only described exposures, and `akit stats` and the
Insights screen show the share of Claude sessions with a name-only exposure. The name-only
reasons and "over budget" are not built (I1 left them out), so that share also counts skills
set to `name-only` by the user. A skill never listed with its description anywhere in the index
(likely an empty description) is left out of it.

## Harness fingerprint

What the agent ran with, as a hash, so two sessions can be compared "under the same setup".

Status: designed, not built. No fingerprint is computed in code (step 11 of
`session-insights.md`). Layer evals once designed a second, narrower one, the home
fingerprint; D2 (2026-10-08) dropped it: a layer eval pairs cells only within one eval
run and records the Claude Code version per cell instead (`layer-evals.md`, "Baseline").

- Components, each hashed on its own:
  - `listing`: the text of the initial `skill_listing` after that start event (from the
    transcript, by the importer);
  - `context_files`: the CLAUDE.md / AGENTS.md files on the chain from `cwd` to the
    repository root and the user's global one (paths + contents, by the hook);
  - `harness_version` and `model` (from the transcript lines);
  - settings components, hashed by the hook at session start: `hooks` and `plugins`
    (the `hooks` and `enabledPlugins` keys of the user and project `settings.json`) and
    `mcp` (the project's `.mcp.json`, never `env` or `headers`). `~/.claude.json` and
    `settings.local.json` are not hashed.
- `harness_fingerprint` = sha256 of the sorted `name=hash` lines of `listing`,
  `context_files`, `harness_version` and `model`, the components every session has.
- The settings components are stored next to it as filters: two sessions must match on
  one only when both have it. A session imported without a hook line lacks them, and the
  fingerprint stays comparable.
- One per session start event: SessionStart fires on `startup`, `resume`, `clear`,
  `compact` and `fork`, so the fingerprint can change inside one session. The importer keeps each
  one with its time.
- Skills are versioned by git (the brain) and this fingerprint, never by semver.

## Repo snapshot

The repository state a session started from (after Inspect AI's `EvalRevision`:
type git, origin, commit, dirty).

- `{origin, commit, dirty, diff_hash}`: normalized `origin` remote, `HEAD` commit,
  whether the work tree had changes, and the sha256 of `git diff HEAD` when it did.
  The diff itself is never stored. `origin` and `commit` are recorded from the start;
  `dirty` and `diff_hash` come with their first user (control sets), since they need
  git to run, which a session hook can't wait for. Status: `origin` and `commit` are in
  the hook line since 2026-10-01; `dirty` and `diff_hash` are not built, and error
  analysis decided to do without them (HEAD only).
- A session can be a control task (Lab replay, error analysis control sets) only when it
  is clean, or dirty with a `diff_hash` (then it is marked as not reproducible from the
  commit alone).

## Failure signals

Per-session counts from structural markers only, never from reading message text. They
are sampling strata for review and error analysis, not verdicts. Each count is stored
with the version of the parser that produced it.

Status: built 2026-10-08 (step 7 of the design map, proposal I4, decision D1). The four
signals both parsers have, `interrupts`, `rejected`, `tool_errors` and `repeated_calls`,
have one definition: `FailureSignals` in `AKitSessions`. It is fed the main conversation
in order: a user text, a tool call (tool name and input text), a tool result (tool, text,
error flag).

- Lab's `SessionAnalyzer` feeds it from the log lines of one Claude Code transcript and
  shows the counts on Sessions → Analysis and in Lab; nothing is stored in the index.
- `AKitErrorAnalysis.SignalScanner` feeds it from the transcript items (Claude Code and
  Pi) and stores the counts in the index table `signals` (schema v9 added the column
  `rejected`), with the scanner's version (3 since 2026-10-08; 2 was the first shared version the same day). A row of an older version
  is recomputed on the next scan, like a row whose file changed; one whose file is gone or
  can't be read is deleted. A batch and the bootstrap pick scan before they sample.
- The session's Usage tab ("N failed") counts `tool_errors` by the same rule, and the
  Overview tab classifies each call with the same `ToolResultOutcome` and Esc rule and, like
  the transcript, skips meta lines whole, so its "failed" and "rejected" match.
- It is not an incremental reducer: the scanner already recomputes only the files that
  changed.

Signals that only one parser has stay with it: Lab's `compactions` and `rereads`; the
scanner's `pushbacks`, `unverified_done`, `user_turns` and `steps`.

| Signal | Counted from | Known noise |
|---|---|---|
| `interrupts` | user text that starts with `[Request interrupted by user` (leading white space ignored) in the main transcript; the marker inside other text is not one; meta lines and compaction summaries are not user text | the same text is written when a subagent is aborted or fails; subagent files and side chains don't count. Pi writes no such marker: always 0 |
| `rejected` | a tool result with the error flag that `ToolOutcomes.outcome` calls `rejected`: the harness's refusal text in its first two lines (the user, a permission rule, a hook, the auto mode classifier or a Pi extension's `Blocked …`). The outcome is read from the real text, before the transcript hides the output of a call that touched a secrets file, and travels with the transcript item. Esc at the permission prompt (`PromptEscapes`): the user's own refusal ("doesn't want to proceed…") followed by user text starting `[Request interrupted by user for tool use]` before the next tool call is not rejected; the Overview tab counts it as interrupted by the same rule. A permission rule's or hook's denial in the same batch stays rejected | |
| `tool_errors` | a tool result with the error flag that is neither `rejected` nor `interrupted` (`[Request interrupted by user…` as the result, Pi's `Command aborted`). A failed result with no text counts too: the transcript shows it as `(no output)`. Such an item shifts the ids of the later steps in its session (none was found in the local logs on 2026-10-08) | |
| `compactions` | `system` line with `subtype: "compact_boundary"` (Lab only) | |
| `rereads` | a successful `Read` of a file and range already read, with no edit of that file in between; a Bash command that may write resets every file (Lab only) | |
| `repeated_calls` | 3 or more calls in a row of the same tool with the same input: no other tool call between them (results, text and user turns between them don't break the run). Each run counts once, however long it is; a run broken by another call and started again counts again. The input is compared as the transcript shows it: JSON with sorted keys, secrets masked | polling (`sleep`, status checks) repeats on purpose; masking and the redaction of secrets-file content can make two different inputs look the same. A call with no input is not in the transcript and is not counted |

D1, decided 2026-10-08: an interrupt is the start of the text, not anywhere in it; a
repeat is 3 or more in a row, not any repeat. Counting a run once makes the number read
as "times the agent got stuck", and a run of 10 doesn't outweigh 10 sessions with one.

Rewinds are not counted until a marker for them is verified on real logs.

Claude Code's transcript format is not documented and changes between versions; a
missing field means "not recorded", never zero. Lab results analyzed before 2026-10-08
have no `repeatedCalls` (the Repeated calls row is left out, as for any value not
recorded) and keep the old counts of the other three.

## Statistics

- Context size is deterministic for a given listing: a measured size needs no test.
- Rates (interrupts per session, sessions with a rejection, …) are binomial: show a Wilson
  interval and compare only groups with the same fingerprint and model. With a base rate
  near 5% a difference of a few points needs tens of sessions per side; AKit shows the
  interval, never a verdict from five sessions.
