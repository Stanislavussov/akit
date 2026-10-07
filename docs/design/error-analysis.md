# Error analysis: failure modes across many sessions

Status: design 2026-10-01 (decided in a grilling session, reviewed against the evals
literature, then revised against 2025–2026 practice); open questions decided the same day
(see [Decisions](#decisions)). Built 2026-10-01/02, all eight slices, and merged to
master (tag `v2026.10.02`); what differs from the design and what is not built is listed
under [Implementation plan](#implementation-plan). Extends Lab (`lab.md`): the one-session
review becomes the first step of this pipeline.

## Goal

Find out what goes wrong in agent sessions *again and again*, how often, at which step of
the work, and whether a fix helped, with every claim backed by steps of real transcripts.
One session review answers "what went wrong here"; this answers "what goes wrong, how
often, where, and did the fix work".

The user's judgement defines the modes and labels; models apply it to many sessions.
Frequencies come from binary checks per mode, corrected for the checker's known errors and
shown with intervals. They don't come from a chain of model steps whose errors multiply.

Method (error analysis, as Hamel Husain and Shreya Shankar teach it):

1. **Bootstrap.** The user reads at least 30 sessions and writes their own notes before
   seeing the model's notes.
2. **Open coding.** Free notes per session about what went wrong, with no predefined
   categories.
3. **Axial coding.** Group the notes into concretely named failure modes ("full read of a
   34 KB file", not "context issues").
4. **Counting.** A mode's frequency in a report comes only from that mode's check (a
   mechanical code check, or a validated check) run over all sessions of the batch.
   Matching notes to modes maintains the taxonomy (candidates, merge/split, exemplars) and
   never feeds a denominator. A mode without such a check is shown as "seen in k notes",
   without a percentage.
5. **Saturation.** Stop adding sessions when no new modes appear.

A human stays in the loop: they label the bootstrap set, confirm changes to the list of
modes and review tough calls, but they don't label every session.

## Terms

- **Note**: one problem seen in one session (open coding). Written by the model or by the
  user (`source: model | human`).
- **Mode**: a pattern with a definition and criteria, not just a name. Most modes are
  failures; a mode also has a `kind` (failure, success, efficiency); see [Modes](#modes).
- **Check**: a pass/fail verdict per session for one mode: code, or an LLM judge.
- **Positive** means the mode is present in the session: the failure for a failure or
  efficiency mode, the strategy for a success mode. **TPR** (true positive rate) is the
  share of positive sessions the check catches. **TNR** (true negative rate) is the share
  of negative sessions the check correctly passes.
- **Outcome**: did the session reach the user's goal; see [Step 1](#step-1-notes-per-session).
- **Phase**: where in the work something happened, from a fixed list: understand → explore
  → plan → edit → verify → report.
- **Session key**: the session index's key (harness + the harness's own session id).
- **Batch run**: a Lab run over a sample of sessions. Batch reports count only batch
  sessions.
- **Indexed sessions**: every session in the session index. Code checks also run over
  them, for a mode's own page and for the before/after signal of [Fixes](#fixes).
- **Ad-hoc review**: today's review of one session. Its notes go into the pool as examples
  and candidates, and count as "seen manually", never in a denominator.

## Sampling (batch)

The user picks a project, a period and optionally the harness that ran the sessions
(Claude Code or Pi). AKit takes up to N sessions (default 20) from the session index;
sessions with fewer than 5 requests are skipped.

- **Cheap signals.** The session index stores signals computed by code, no model call:
  - user interruptions;
  - pushback turns ("no", "not that", "I asked for", a revert);
  - number of tool errors;
  - repeated identical tool calls;
  - "done" with no test run or check after it;
  - session length.
- **Strata.** The sample is stratified by these signals, plus harness and model. Each
  session records its inclusion probability and `sampling` (how it was chosen).
- **Random share.** 20–30% of every batch is drawn purely at random, so quiet failures
  that raise no signal are still seen.
- **Weights.** Reported frequencies are weighted by inverse inclusion probability
  (Horvitz–Thompson); the unweighted numbers are shown next to them.
- Sessions marked `reserved_for_bootstrap` are never sampled (see
  [Bootstrap](#bootstrap-labeling)).
- Ad-hoc reviews hint which similar sessions the next batch should add.

## Digest

What the model reads instead of the raw transcript. It is built from the scrubbed
transcript (see [Sending policy](#sending-policy)), and evidence is never cut away:

- **User turns** are always included verbatim.
- **Requirements.** The Step 1 call first writes the task's requirements from the verbatim
  user turns, before any note, so notes are judged against the spec without a separate
  call. A noticeable share of failures is visible only against the spec.
- **Long tool output** keeps its head and tail. The stub always keeps the exit code, the
  lines with error/fail/warn, and the number of failed tests.
- **Budget per turn** scales with the session's length instead of fixed limits per kind.
  The target is an input under 272K tokens; the budget is per model: 360K chars (about
  90K tokens) by default, 1M chars for 1M-token windows. `EvidenceDigest` (AKitLab)
  replaced the earlier digest of `lab.md`.
- **Over budget.** User turns and the stubs of failed tool results are never cut. When
  they alone pass the model's budget, the session isn't sent: the notes call and the judge
  refuse it with a clear error, and nothing goes out. In a batch such a session is "too
  long for a digest": counted apart from failures, never retried, and named in the
  coverage. A judge that refuses one doesn't fail the session's notes.
- **No `get_step(n)` tool** (decided): the call stays tool-less, as in `lab.md`, so an
  injected transcript can't make it do anything. The [verifier](#verifier-second-pass)
  checks every quote in code against the full scrubbed transcript.

## Step 1: notes per session

One structured call per session, fields in this order:

1. **Requirements** (see [Digest](#digest)).
2. **Outcome.** Did the session reach the user's goal: achieved, partly, no, unclear. It is
   judged from what the user saw (their messages and the final state they were told
   about). It is stored per session, separate from the notes (transcript versus outcome).
3. **Blind notes.** The call never sees the list of modes. Each note has:
   - free description;
   - step `#n` and a quote;
   - severity;
   - fault layer: agent (model), harness setup (CLAUDE.md, skills, hooks, MCP),
     environment/tools, task spec (the user's request), grader (rare in our sessions).
     An environment blocker is a fault layer, not a mode;
   - root or symptom (symptom of `#m`);
   - cost in tokens or steps.

   The note's phase is not written by the model: code derives it from step `#n` (see
   [Transition matrix](#transition-matrix)). The model labels only understand and plan.

   **Deviation steps.** The session's first point of deviation is two fields, both
   approximate:
   - `decisive_step`: the error that decided the outcome;
   - `observed_step`: the first moment the problem became visible in the transcript or to
     the user.

   Later problems are often a cascade of the decisive one. The UI shows both as
   "about here", never as an exact step. Localisation is hard: on Who&When the best method
   finds the decisive step in 14.2% of cases, on TRAIL the best model gets both place and
   type of error in 11%. In "Failure as a Process" the median decisive error is at step 7,
   the first visible signal at step 16, and 28% of failures never surface clearly.
4. **Paragraph.** 3–5 sentences, written from the transcript, not only from the notes.
5. **Up to 3 improvements.** Generic advice as today (`lab.md`). Each cites the ids of the
   notes it rests on; advice whose notes are all rejected by the verifier is dropped.

A session with no problems is stored as "checked, no failures"; it counts in denominators.

Re-reviewing the same session replaces its notes; it doesn't add to them. The user's route
verdicts carry over to the new notes with the same step and the same quote (normalized).
Whether a step can be skipped is decided by the [done key](#done-key).

### Verifier (second pass)

A separate pass right after the notes. Only notes it accepts enter the pool and go on to
matching:

1. **Code** checks that the quote is in the scrubbed transcript verbatim at step `#n`
   (the model saw scrubbed text, so quotes are matched against it).
2. **A model call** checks whether the quote supports the claim.
3. **High-severity notes**: the verifier first writes the steelman argument "there is no
   problem here", then gives its verdict.
4. **The conclusion** (verifier prompt 3): the same call ends with one or two plain
   sentences for a busy reader (was the session good, the problem that cost most, the one
   change worth making), from the notes it accepted only. It gets the outcome, the
   paragraph, the advice and the notes code rejected, so the conclusion can't rest on a
   rejected note the way the paragraph (written before the verifier) can. No note reaching
   the verifier means no conclusion; the review page then leads with the outcome alone.
   The review page shows it first, in a card with the outcome, the accepted notes by
   severity and the session's numbers, then the advice, then the accepted notes grouped by
   mode ("No type yet" when none fits); the paragraph, requirements, deviation steps and
   rejected notes sit under Details.

A note that fails is kept with `rejected_by_verifier` and the reason, and stays out of the
pool. In Tang et al. only 53.9% of the extracted episodes survived such a second pass. The
typical false positives are:
- "normative expectations": the model flags deviations from its own idea of good work
  although the user didn't object;
- conclusions drawn from context that isn't in the log.

## Bootstrap labeling

A spot check of the model's notes shows their precision: did the model invent a problem?
It can't show their recall, because what the model missed is visible only to someone who
read the transcript. Recall is the main risk, so it is measured.

1. **Choosing sessions.** At least 30 sessions. The agent picks them: representatives of
   clusters of the session index plus random ones. Picked sessions are marked
   `reserved_for_bootstrap` at once. They are excluded from ad-hoc reviews until the user
   has labeled them, otherwise the labeling would no longer be blind, and from batches for
   good: a session can't be both the yardstick of the notes model and part of a sample.
2. **Labeling.** The UI shows the scrubbed transcript; the user writes notes (`source: human`) with
   only: description, step, quote, the session's outcome, and the first point of deviation
   (`decisive_step`, and `observed_step` if it differs). Fault layer and root/symptom are
   not asked of the human. Human note ids (`h1`, `h2`, …) are stable: a saved note keeps
   its id when the label is reopened and edited, a new note gets a number never used in
   that label, and deleting a note drops its mapping and its pairs.
3. **Comparison.** The model's notes for the same sessions are then compared with the
   user's. The model proposes pairs of notes; the user confirms them. Model note ids
   (`n1`, …) are numbered afresh by every review, so a pairing records the notes done key
   it was made on. A new review of the session moves the pairing and the user's spot
   checks to the same notes (same step and quote, as for the user's route verdicts) and
   drops what was about notes that are gone; metrics ignore a pairing made on other notes.
   - **Recall** is the share of the user's problems the model found and the verifier
     kept: confirmed pairs whose model note was accepted, the same notes that precision,
     the pool and the reports use. Recall before the verifier (pairs with any model note)
     is shown next to it: the difference is what the verifier's rejections cost.
   - **Precision** is the share of the model's accepted notes the user agrees with.
   - **Deviation steps**: phase agreement and step agreement within ±3 steps are measured
     separately. The [transition matrix](#transition-matrix) uses phases only, and only
     when phase agreement is high enough.
   - **Outcomes** should match.
4. **First modes.** The human and model notes of the bootstrap are clustered into the
   first modes, the same call as [Step 3](#step-3-clustering-unmatched-notes); seeds
   join them as candidates. The user confirms or edits them.
5. **Mapping.** The user maps their own bootstrap notes to the confirmed modes by hand.
   Bootstrap labels are notes, not mode labels: they become labels for checks (and for
   route acceptance) only through this mapping. A session is positive for a mode when one
   of the user's notes maps to it, and negative only when every note of the session is
   mapped (elsewhere, or to "unclear"); with a note not mapped yet it gives no negatives.
6. **Similar cases.** After the first 30 sessions, the model searches the pool for cases
   similar to each human note. Each accepted or rejected find is a cheap label for checks;
   within a session, one accepted find makes it positive. Notes whose session may not go
   to the destination are left out of the search, and it says how many.
7. **Stop** after about 20 sessions in a row with no new mode and no change to an existing
   one. A clustering candidate is not a change of the list until it is confirmed (by the
   user or by its second independent case).
8. **Repeat** on 10–15 new sessions whenever the notes model or the notes prompt changes.
   Recall per notes model/prompt version is shown next to every report built from it.

## Step 2: matching (separate call)

Runs after the verifier, on accepted notes only (async for an ad-hoc review). Input: the
session's notes and the current modes (definitions, criteria, exemplars), never the
transcript. Exemplars are quotes from other sessions: one whose session may not go to the
destination is left out, and the others' origins go with the call (the judge does the
same). Each note gets one mode with a confidence, or **"none fits"** (an explicit option,
against anchoring).

Matching is a **router**: note → mode or candidate. It maintains the taxonomy (candidates,
merge/split proposals, exemplars) and never feeds a denominator; frequencies come from
[checks](#checks). Its one metric is the **share of routes the human accepted**.

Low-confidence routes go to the human. Unmatched notes become candidates (step 3).

## Step 3: clustering unmatched notes

One call over all unmatched notes, at the end of a batch (and over the bootstrap notes, to
get the first modes). It returns candidate modes (name, definition, include/exclude
criteria, the notes in them). This call, retro-matching and the similar-case search leave
out the notes whose session may not go to the destination and say "N of M notes left out";
they fail only when no note is left.

- A candidate from an ad-hoc review becomes a mode at its second independent case, or
  when confirmed in the UI.
- **After a new mode is confirmed:**
  - its code check, if it has one, runs over all indexed sessions at once (local, free);
  - two model-backed actions are offered as buttons, each with a cost estimate first:
    **retro-matching** routes the whole note pool against the new mode; a **pool judge
    run** runs the mode's judge over the raw transcripts of the pool and shows where and
    why it matched. The judge run shows how many cases the notes missed.

## Modes

`modes.json`, one list per machine, local only (`~/.akit/lab/analysis/modes/`). A mode:

| Field | Meaning |
|---|---|
| `id` | stable, survives renames |
| `name` | concrete, specific |
| `kind` | `failure`, `success` or `efficiency` |
| `definition` | 1–2 sentences |
| `include`, `exclude` | criteria; without them the next run drifts and checks float |
| `scope` | `general` (default) or `project:<id>`, narrowed with one UI button; used only in reports: a project's mode counts over the batch's sessions of that project and is left out of a report without them; matching, checks and judges see all modes |
| `origin` | `seed-prior` (our observations), `seed-literature` (published studies), `emergent` |
| `faultLayer` | model, harness, environment, grader, task spec |
| `version` | bumped by any merge, split or definition edit; invalidates the mode's test metrics |
| `merged_into` | set when the mode was merged into another |
| `status` | see [Fixes](#fixes); seeds start as "seed, inactive" |

`success` modes are strategies that worked (gathering context first, recovering from a
tool error). They are candidates for CLAUDE.md rules that keep them. Fix statuses apply to
failure and efficiency modes.

Exemplars (2–3 per mode, each with session, step and quote) live in `exemplars/`, separate
from the definitions. This way the definitions could later be exported without quotes. A
session in a test set is never an exemplar: exemplars go into every matching call, and the
test would leak through them.

- **Versions.** `~/.akit/lab/analysis/` is a local git repository (no remote) that tracks
  `modes/` only (see [Storage](#storage)). Every rename, merge, split or reject is a
  commit. A merge sets `merged_into`; past results are recounted through it, so trends
  survive.
- **Rejected modes** are kept with "rejected because…", so the model doesn't propose them
  again.
- **"Unclear" bucket.** Notes the human couldn't place are kept; they are the main source
  of future modes.

### Seeds

Each seed has a definition and include *and* exclude criteria. Seeds 1–7 are
`seed-literature`; 8–9 are `seed-prior`.

1. **Overclaiming completion.**
   - *Include:* "done" or success reported while (a) nothing confirmed it, for example
     UI not clicked through before "done", or a wrong self-check; (b) tool output showed
     an error that the report leaves out, for example a tool error ignored and success
     reported after it; (c) work invented or inflated. Premature "done" is a criterion
     here, not a mode.
   - *Exclude:* the agent says plainly what it didn't check; an error the agent fixed
     before reporting.
2. **Explicit user constraint violated.**
   - *Include:* the user stated a constraint (don't touch X, use Y, no push) and the agent
     broke it.
   - *Exclude:* the user lifted the constraint later; a constraint the agent couldn't
     have seen (not in the transcript).
3. **Intent misread on an underspecified request.**
   - *Include:* the request allowed several readings, the agent picked one without asking,
     and the user corrected it.
   - *Exclude:* the request was clear and the agent ignored it (that is seed 2 or
     overreach); the user changed their mind.
4. **Scope overreach.**
   - *Include:* changes outside the request without the user's consent (refactors, extra
     features, other files).
   - *Exclude:* changes the request needs to work; changes the agent asked about first.
5. **Weakening tests or oversight.**
   - *Include:* tests deleted, skipped or loosened; checks, scoring or CI edited so that
     they pass.
   - *Exclude:* the user asked for it; a test fixed because it was wrong, said so in the
     report.
6. **False premise / wrong diagnosis.**
   - *Include:* the agent acted on an unchecked assumption about the project or the
     environment that turned out wrong.
   - *Exclude:* the assumption was checked and the environment changed later; a wrong
     guess discarded before any action.
7. **Steps repeated without progress.**
   - *Include:* the same or nearly the same action three or more times with no new
     information between them.
   - *Exclude:* polling for something that is expected to change (a build, CI); retries
     with a changed input.
8. **A long session not reset after finished steps** (`kind: efficiency`).
   - *Include:* finished, committed steps followed by new work in the same context, with
     context above roughly half the window.
   - *Exclude:* steps that need the earlier context.
9. **A large file read whole** (`kind: efficiency`).
   - *Include:* a file over 20 KB read in full (Read without a range, `cat` of the whole
     file).
   - *Exclude:* the file is then rewritten whole (a Write of the same path).

**Activation.** Seeds are inactive: they take part in matching, but they don't appear in
reports and get no check. A seed becomes an active mode after 2 independent batch matches
(ad-hoc matches don't count) or confirmation in the UI. AKit tracks the share of notes each
seed absorbs; when that share is unusually high, it proposes narrowing or splitting it.

**Reference frequencies** (orientation only, not targets): in Tang et al. a constraint was
violated in 38.33% of failure episodes, intent was misread in 26.95%, and the agent's own
report was inaccurate in 22.58%. METR saw reward hacking in about 0.7% of runs.

## Human in the loop

- **Bootstrap labeling** (above): the only place where recall is measured.
- **After each run** the UI shows only:
  - candidate modes;
  - proposals to merge or split modes;
  - low-confidence routes;
  - checks flagged `tough_call`;
  - 5–10 notes picked at random for a precision spot check; the answers give the
    batch report's spot-check precision.
- **Confirmed modes** with familiar exemplars aren't re-checked.
- **First UI**: a table with rename / merge / reject / move-note actions.

### Quick ratings after a run (Pi)

Built 2026-10-07 for Pi; Claude Code waits (the user asked for Pi only for now).

- **Input in the harness, everything else in AKit.** The rating lives seconds; switching to
  the app for it would mean rating only big failures. The Pi extension (`akit-record.ts`,
  written by `akit insights install` / `akit setup`) shows `rate last run:  👍 ⌥G   👎 ⌥X
  💬 ⌥R` under the editor after `agent_settled`; the next prompt hides it. ⌥R asks for one
  line of comment, then good or bad. Ctrl keys were the first wish, but Pi reserves ⌃G
  (external editor) and uses ⌃B and ⌃R; the Option keys need "Option as Meta" in the
  terminal.
- **"Saved" is true.** The extension waits for `akit rate --harness pi --rating good|bad`
  (stdin: session id, cwd, log path, `anchor` = the run's last entry id, `text`) and says
  `✅ Saved` only on exit 0; otherwise `⚠️ Not saved: <reason>`. An akit from before ratings
  exits 2 on the unknown command `rate`: the extension says to update akit. Ratings need Pi
  0.80.4 or newer (`agent_settled`); the extension imports no Pi package, so on an older Pi
  session capture still loads. `pi --no-session` shows no rating line.
- **Change, comment, remove.** Until the next prompt the rated run stays the target: the
  line under the editor reads `rated 👍 «…»:  change 👍 ⌥G   👎 ⌥X   💬 ⌥R   remove ⌥U`.
  ⌥G / ⌥X change the rating and keep the comment (the same rating again only says
  "Already rated"); ⌥R edits the comment in Pi's editor dialog, prefilled, then asks the
  rating with the current one first; ⌥U removes it (`akit rate --rating none`) and the run
  can be rated again. Nothing is rewritten: every press appends a spool line and a custom
  entry (`changed: true` after the first), and a run's latest line by its anchor is its
  rating (`Ratings.current`; index schema v8 lets `none` in). After the next prompt a
  rating stays as it is.
- **Not one token in the next request.** No messages, tools or prompt changes: a custom
  entry (`appendEntry`, shown in the transcript by an entry renderer) and a widget only.
  Checked 2026-10-07 against a local fake model: three requests with ratings between them
  had the same system prompt and tools, each request started with the previous one
  unchanged, and no rating text reached any of them.
- **Storage.** A `rating` spool line → the index's `ratings` table (local only; usage
  summaries never carry it). The Sessions screen shows 👍/👎 counts in the list and the
  ratings with their comments in the session header, from the index and from spool lines
  the hourly import hasn't read yet.
- **Where a rating belongs.** The Pi reader turns the extension's custom entries into
  `SessionTranscript.ratings`: per anchor the last entry wins (other entries such as a
  model switch may sit between them), `none` drops it, and each is placed after the item
  that ends its anchor entry, not where the entry is in the log; a run off the active
  branch has no place. Ratings are kept apart from `items`, so item ids (which notes and
  quotes refer to) don't move. The conversation shows each rating right after its run;
  each header line (from the spool, by the same anchor) names the run's prompt and scrolls
  to it. A rating saved while the next run is going is written to the log when that run
  ends; one saved for a session that has since been left is only in the spool; `/tree`
  ends the chance to change it. Copy as Markdown / JSON and the agent-with-file-tools Lab
  review's `transcript.md` carry them, so that agent knows which run the person liked or
  not. A one-call review is a notes call and stays blind like the notes.
- **What the ratings are for.** Labels with `source: human-quick`: a cheap outcome per run,
  the first candidates for modes and a queue of sessions to look at first. Not for recall
  (the person picks which runs to rate) and not in the denominator of frequencies. A rating
  is about one run, not the session's outcome. Notes, checks and judges stay blind to them:
  they read `items`, and ratings are not items. Not built yet: feeding them into bootstrap
  labeling and the batch.

## Checks

A check per active mode is a pass/fail per session. It is the only source of a mode's
frequency: a mode's frequency in a report comes only from that mode's check (a mechanical
code check, or a validated check) run over all sessions of the batch. Matching never
feeds a denominator.

- **Mechanical code check.** When the mode's definition is itself mechanical (seed 9: a
  file over 20 KB read without a range), the code check *is* the definition. It is exact
  by construction: TPR = TNR = 1 against the definition, so no correction applies. A
  spot check on labels still guards against parser bugs.
- **Heuristic code check.** A code check that only approximates a non-mechanical mode (for
  example "done with no test after it" for overclaiming) is validated like a judge. Until
  it is, the mode stays "seen in k notes".
- **Judge.** Otherwise an LLM judge, validated as below. A judge runs over the sessions of
  a batch as part of it, and over the raw pool only by button.
- **Where they run.** Code checks run locally and automatically on every indexed session;
  they send nothing. Judges send data and fall under the [sending policy](#sending-policy).
- **Flags.** Besides pass/fail, every verdict carries `tough_call` (borderline) and
  `severe`. A tough call without human review is left out of TPR/TNR.
- **Which modes get a judge.** Only a mode that is in the top 3 by "seen in k notes" or by
  cost *and* has a fix in `draft` or `applied`. Cost is what the notes seen in the mode
  record, summed: the top 3 by tokens and the top 3 by steps both count. Other modes get a
  code check, or stay "observed" ("seen in k notes").
- **Errors.** A judge error inside a batch fails the session (retried by "Retry errors");
  a pool run or a validation run goes on and leaves the session unchecked.
- **Scrub version.** Each verdict records the scrub version of the transcript it read.
  A newer scrubber doesn't drop a judge's verdicts: they keep counting (reports,
  validation, Fixes) until each session is judged again, the next time a batch, a pool
  run or a validation reaches it, and the cost shown before a run counts them. A verdict
  made before the version was recorded counts as current: it is still evidence about the
  same session, and judging every session again after an upgrade would spend money
  nobody asked to spend. Another mode version, judge model or prompt starts over.

## Validation

This applies to every LLM judge and every heuristic code check (matching is a router and is
measured only by route acceptance). Raw agreement is not used, because a judge can agree
80% of the time while missing most real failures.

- **Labels.** Sources in this order: bootstrap notes mapped to modes; accepted and rejected
  finds of the similar-case search; `tough_call` cases sent to the human. The review queue
  asks the tough calls of the verdicts that count (the judge's when one is enabled); code
  checks never set the flag, so in practice they come from judges. Similar-case finds
  lean towards easy cases and may inflate TPR/TNR; the test set should keep a share of
  randomly sampled sessions.
- **Split.** Labels are split into train (10%), dev (30%) and test (60%). Exemplars and
  few-shot examples come only from train.
- **Iterate on dev**, then run once on the held-out test and record TPR and TNR with the
  mode version, model and prompt version.
- **Valid** means the lower bound of the Wilson 95% interval is at least 80% for TPR *and*
  for TNR. A point estimate is not enough: 18/20 is about [70%, 97%]. Passing needs about
  29/30 or 46/50 in test.
- **Status by volume**, counted in test labels per class: "provisional" at 20 or more,
  "validated" at 30 or more and meeting the bound. A provisional check shows its mode as
  "seen in k notes" with its provisional rate beside it, never as a frequency. In total that is about 50 labels per
  class, about 100 per mode, and 300 for three judged modes (accepted as proposed).
  A judge for a subjective mode may never reach the bound; it then stays "seen in k
  notes".
- **Invalidation.** Any merge, split or definition edit bumps the mode's version and
  invalidates its test metrics (criteria drift). A model or prompt change does the same.

### Correction and intervals

With a check, the report shows for each mode:

- the observed share `p_obs`, Horvitz–Thompson weighted;
- for a validated check, the share corrected by Rogan–Gladen applied to the weighted
  `p_obs`: θ = (p_obs + TNR − 1) / (TPR + TNR − 1), clipped to [0, 1];
- a 95% interval by bootstrap that resamples the batch within its strata and, for a
  validated check, the test labels behind TPR and TNR. Strata with fewer than 2 picks are
  pooled into one resampling group: a single pick resampled alone never varies, which made
  the interval too narrow;
- "below detection threshold" instead of a number when p_obs ≤ 1 − TNR.

A mechanical code check has no correction; its interval covers the sampling only.

## Batch report

- **Mode frequencies** come from checks only (see [Checks](#checks)):
  - observed, corrected and the interval;
  - Horvitz–Thompson weighted, with the unweighted numbers next to them;
  - separately for sessions that reached their goal and those that didn't. A mode that is
    as frequent in successful sessions as in failed ones is a candidate for "not worth
    fixing".
- **Modes without such a check**: "seen in k notes", no percentage.
- **Checked of N** for every mode: the batch's done sessions with a verdict of its check,
  of those it counts over. An exact or validated mode with no verdict yet shows "—" and
  says why (code checks run after imports and at the end of the batch).
- **Scope.** A project's mode counts over the batch's sessions of its project only.
- **Also shown**: saturation, coverage k/N (running, paused and failed sessions apart),
  notes recall of the notes model/prompt version after the verifier, verifier rejection
  rate and the spot-check precision, each with k/n, and route acceptance of matching,
  which is pool-wide, not per batch.

### Saturation

- Per run: the share of notes that matched no mode, and new confirmed modes.
- Both are counted globally **and per project**, so a new project's own modes don't drown
  in the global numbers.
- Both near zero for several runs in a row means the list is saturated.
- **Rebuild.** Every N runs, or when the unmatched share exceeds 15%, all notes are
  clustered again from scratch, without seeds, and compared to the list. A seed whose
  notes fall into several clusters is flagged as an umbrella.

### Transition matrix

After Bryan Bischof's matrix. Modes answer "what breaks"; the matrix answers "on which
transition". A fix can leave a mode's frequency unchanged and still move the hot cell, for
example from edit → verify to verify → report.

- **Phases by code.** explore, edit, verify and report come from the tool type:
  - Read/Grep/Glob → explore;
  - Edit/Write → edit;
  - Bash that runs tests, a build or a linter, and browser tools → verify;
  - the final message → report.

  Other Bash goes by its command (read-only → explore, writing → edit), else it takes the
  phase of the previous step; before the first tool, code says understand. The model may
  label a note's step understand or plan; nothing else.
- **Rows and columns.** The column is the phase of the decisive step; the row is the phase
  of the step just before its action, not "the last completed phase": the agent loops, and
  "completed" is blurry there. For a tool result the action starts at its call, so the
  row is the step before the call; otherwise every failing test result sat on the
  verify → verify diagonal. Parallel calls (call A, call B, result A) are matched to their
  results in order, by tool name where the result has one. An extra "no failures" column shows the denominator.
- **Gate.** The matrix and the funnel are shown only while the bootstrap's phase agreement
  for the current notes version is at least 70%; otherwise AKit says why they are hidden.
- **Small N.** While a project has fewer than 50 sessions in batches, AKit shows a funnel
  (deviations per phase) instead of the 6×7 matrix.
- **Cells.** A cell shows a session count and a % of the batch's N. Colour follows the
  share, and the number is always shown. Normalisation toggles between the whole batch
  ("where is it hot") and the row ("where does the agent slip after this phase").
- **Drill-down.** Clicking a cell lists its sessions and notes (step + quote).
- **Comparing two runs** (applied T, session model, harness, project):
  - side by side on **one shared colour scale**;
  - or one difference matrix with a diverging palette: red worse, green better, grey
    within noise.
  - N is shown for both sides, and cells with fewer than 3–5 sessions are dimmed.

## Batch run

- **Lab run.** One "Error analysis" run in Lab, with progress k/N for each step (notes,
  verifier, matching, checks, clustering).
- **Per-session status.** pending / running / done / error (with the reason) /
  too-long. Invalid output is an error, not a skip; so is a judge's error. A session too
  long for a digest is too-long: retrying can't make it fit, so "Retry errors" leaves it.
- **Pipeline.** A session's verifier starts right after its notes, and its matching right
  after the verifier. Clustering is one call at the end, over everything done; the report
  shows coverage k/N if some sessions failed.
- **Parallelism.** Fixed at 2, with exponential backoff on 429 (rate limit).
- **Pause** stops after the current calls; resuming continues from the same place.
- **Retry errors** reruns only the failed sessions, and an old result is deleted only
  after the retry succeeds. A worker writes only the sessions it changed, so a retry
  queued while an old run still works isn't written back to errors.

### Done key

One content-addressed rule for every step, in batches, ad-hoc reviews and control runs
alike:

`key(step) = hash(input) + hash(config of this step and of every step whose output it reads)`

- **Input** is the transcript for session steps (the task for a control cell); for the
  notes it also holds AKit's numbers, exactly as the notes call sends them. The notes step
  computes them itself, from a Claude Code transcript alone and scrubbed like it (no git:
  whether a commit later reached the main branch isn't in the log and changes with the
  repository), so an ad-hoc review and a batch send the same input and share notes. The
  session's title isn't sent.
- **Config** holds the model, prompt version and scrub version of each of those steps;
  for a code check, the check's code version. Judges and code checks read only the
  transcript, so a notes-model change never re-runs them.
  The modes-list version enters only the matching key, and a mode's version only that
  mode's check key, so renaming a mode never re-runs the blind notes.
- **Skip or recompute.** A step whose key exists is skipped; otherwise it is recomputed.
  Changing one step's model changes its key and the keys of the steps that read its
  output, and nothing else. A new scrub version changes every key: the next review of each
  session (a batch, an ad-hoc review) re-runs its notes and verifier once, and judges
  judge it again (see [Checks](#checks): their old verdicts count until then).

## Models and budget

Each step stores harness + model. Harnesses are Claude Code and Pi only; there is no
Copilot CLI harness. Copilot models (billed per token) go through Pi's `github-copilot`
provider (`/login` in Pi once).

| Step | Default |
|---|---|
| Notes, verifier, clustering, paragraph + advice | GPT-6.1 Sol (Pi, github-copilot) |
| Re-check of hard sessions | Claude Opus 5.5 (Claude Code), manual, by choice |
| Matching | GPT-6 Luna, kept while its route acceptance holds |
| Judges | per mode, the model that passed [validation](#validation) |

- **One default model** for notes, verifier and clustering. Another model replaces it only
  when validation shows it is better.
- **Different family.** By default, if the session ran on a model of the reviewer's
  family, AKit takes a model of another family when it can, but only among destinations
  the [sending policy](#sending-policy) allows. The first one allowed for the origin of
  every session the filter matches wins. When none is (a project with Claude Code and Pi
  sessions, each allowed only to its own harness), the one allowed for the most sessions
  reviews the batch, and the sessions it may not get are left out of the population before
  sampling. AKit says how many before queuing, and the batch records it. The batch isn't
  queued only when no reviewer may get any of them. The policy always wins.
- **A reviewer you pick** keeps every session. Before queuing, AKit says how many of the
  sampled sessions the policy will refuse it (they fail, so the report covers fewer), and
  queues only after a yes: a confirmation in the app, `--yes` for `akit lab new analysis`.
  The harness filter (`--session-harness`) narrows a mixed project instead.
- **Cache.** A stable prefix (system prompt + modes list) comes first in the request.
- **Cost (recorded only).** Before any model work AKit shows an estimate, "≈" from the
  recorded cost of past calls of the same harness and model in the send log. A monthly
  limit is a setting, shared by everything that calls a model here:
  - ad-hoc reviews and batches;
  - bootstrap pairing and the similar-case search;
  - judges run over the pool and retro-matching;
  - control sets.

## Sending policy

**Scope.** It applies to every model call that sends session data or repository code out:
- notes and the verifier, including ad-hoc reviews;
- bootstrap pairing, the similar-case search, matching and clustering (notes contain
  quotes);
- LLM judges;
- control runs ([Controlled evals](#controlled-evals));
- subagents, and a harness picked automatically.

Code checks run locally and send nothing, so the policy doesn't apply to them.

- **Allowed list.** Settings → Lab holds the destinations allowed for session data. An
  entry is harness + provider + account + plan/organization (the org through which Copilot
  is granted, not only the login).
  - **Same origin, on every machine** (since 2026-10-07): a transcript may go back to the
    harness and provider that produced it, which already has it; everything else is added
    explicitly. The default notes model (Copilot through Pi) on a Claude Code session is
    cross-origin, so it has to be added.
  - **Work machine** (`work` mode, see `layers.md`): the list is empty by default and is
    the company's; refusals say so. Repository code (replays, control runs) goes only to
    the list there: it was given to the harness, not to every provider the harness reaches.
  - **UI hint**: fill the list in by the company policy for *session data*, not only for
    code.
- **Account check** at the start of each review, batch and control run, and again after
  an authorization error. If the Claude Code account can't be determined, or there is no
  plan or org data, the call is refused.
- **Unreadable settings.** When Lab's `settings.json` exists but can't be read (or a field
  such as the monthly limit doesn't decode), every send is refused with that reason: the
  defaults would silently drop the allowed list, the scrub patterns and the limit.
  - **Claude Code:** `claude auth status --json` returns `email`, `orgId` and `orgName`,
    and no secrets.
  - **Pi** has no whoami (`pi auth check --json` gives only provider, status and reason).
    Pi must report the provider ready. The account and plan/org the user entered for the
    provider (Settings → Pi accounts) name the destination; with none it is "account not
    entered", which only the same origin allows and which matches no list entry. No
    harness secret is read.
- **Scrub before sending.**
  - **Detector**: gitleaks rules ported to Swift (`Scrubber`, next to `SecretFilter`), with
    no live verification of found keys (trufflehog-style verification sends the secret to
    its provider).
  - **Own patterns**: regexes for internal hosts and e-mails, and `.env` contents.
  - **Allowlist**: hex strings (SHAs, hashes, UUIDs) are allowlisted for the entropy
    detector.
  - **Weak passwords**: a value after a password's name (`db_password: Summer2024`,
    `--password hunter22`, `PGPASSWORD=…`, `password: 123456`, `password=letmein`,
    `IDENTIFIED BY '…'`, `PASSWORD '…'` in SQL, `mysql -pSecret`) is masked without the
    entropy gate, from 4 characters, unless it reads as code (a variable like `input2`, a
    placeholder like `<PASSWORD>`, a path, a type or a number other than a PIN) or as prose
    about a flag (`the --password flag`). A word with no digit counts only right after
    `=` with no space; `-p…` only after `mysql`, `mysqldump` or `mysqladmin`, since short
    flags elsewhere mean other things.
  - **One rule list**: `SecretFilter` (what the screen masks) runs the Scrubber's own token
    and password rules, so the two never drift apart.
  - **Versioning**: the scrub version (now 4) is part of the [done key](#done-key).
- **Send log** (`sends.jsonl`): session, harness, provider, account, tokens (input,
  cached, output), the recorded cost and scrub version.

## Fixes

Each failure or efficiency mode moves through these statuses: open → draft → applied(T) →
confirmed / didn't help / rejected (with a reason). **T** is the moment the user marks the
fix applied, an anchor like `akit stats mark`.

- **Draft** (a button on a mode): the layer to change (CLAUDE.md rule, skill, hook, tool
  description, environment), the text, links to exemplar notes, and the expected
  observable change in transcripts. It is written down before any run, together with the
  "helped" criterion. The user applies it.
- **Signals**, from strongest to weakest. Randomized interleaving was rejected: AKit never
  changes the context of real sessions on its own.
  1. **Control set**: controlled tasks, see [Controlled evals](#controlled-evals).
  2. **The mode's check** over indexed sessions before and after T: the production
     signal, and the guard against regressions that offline tasks miss (as the Anthropic
     postmortem and Replit's write-up show).
- **"Helped"**, fixed before the run, from one rule:
  - **Production** (independent sessions): P(fail_after < fail_before) ≥ 0.95 under
    Beta(1,1) posteriors. Wilson intervals per group and Fisher's exact p are shown
    alongside.
  - **Control set** (paired by task): the bootstrap over tasks of the per-task change in
    pass rate puts at least 95% of its mass on improvement.
  - **And not worse in production**: the mode's production check gives at most 50%
    posterior probability that its failure rate rose after T. A control set's "helped"
    needs it too: without production data (no applied fix with check results, or fewer
    than 15 sessions on a side of T) the control verdict is "no conclusion". Layer evals
    (`layer-evals.md`) give a layer its own verdict with an offline level that doesn't need
    this guard; the mode's fix status keeps the rule.
  - With N < 15 on a side there is no conclusion.
- **Why not plain intervals.** CLT intervals understate the uncertainty at N ≈ 15–50 per
  group, and clustering by task changes the standard errors.
- **Minimum detectable effect** is shown in the report. As a guide: with about 30
  sessions per group only large effects show (around 50% → 15%); 20% → 5% needs about 80
  sessions per group.
- **Reading the signals.**
  - Changes of session model or prompt version between the periods are flagged.
  - Modes whose check shows a higher failure rate after T are listed.
  - The transition matrix before/after T is shown as a difference.

## Controlled evals

Error analysis answers "what breaks and how often" on real sessions. Controlled evals
answer "did the fix help" on fixed tasks, where the mix of tasks can't move the number.
They are Lab replay tasks (`lab.md`) extended in two ways: a task can be made from a
session instead of a commit, and the agent can be Claude Code or Pi.

A layer from the brain as the setup, instead of one patch, is designed in
`layer-evals.md`; it adds an offline verdict level that doesn't need the production guard.

**Mapping.**

| Error analysis | Control set |
|---|---|
| a confirmed frequent mode | a reason to add tasks to the set |
| the mode's exemplar sessions | control tasks: the user's first turn verbatim, base = HEAD at the session's start |
| the mode's check | the task's assertion: AKit runs the mode's code check (or judge) on the cell's transcript |
| the fix draft | a second setup with exactly one difference |
| the draft's expected observable change | a written hypothesis with the "helped" criterion, before the run |
| outcome | the oracle: tests passed, or the assertion |

**Oracle.** Each task names its oracle:
- the project's test command at that commit, when the session's goal is covered by
  tests (green on a reference solution, for example the commit that later fixed it);
- or only the mode's assertion, a behavioural oracle.

A single-turn task can't reproduce modes that need the user's pushback (seeds 2 and 3);
those stay with production signals.

**Shared event parser.** Event parsing lives in AKit (`AKitSessions`, next to the session
readers, which already read Claude Code and Pi logs). For Pi it reads the session log and
the `--mode json` stream into the same items, so a check over the session index and an
assertion over a control cell read events the same way.

**Mechanics** (Lab replay):
1. **Isolation.** A cell's folder is a fresh repository holding only the base commit's
   history (`git init`, `git fetch <sha>`), not a git worktree: a worktree shares refs and
   objects with the user's repository, so the later fix would be reachable (`lab.md`,
   "Isolation"). A cell whose tool calls read the original session history (the
   exemplar's own transcript) is flagged.
2. **Traces are kept.** A cell is a Lab run with its own transcript: it can be reviewed,
   but it never enters production frequencies (Lab's own sessions are left out by session
   id, `IndexedSessions.labKeys`). Red
   cells of the fixed setup are offered for review, since new modes after a fix are side
   effects.
3. **The oracle is guarded from day one.** The result records that the number of tests
   didn't drop, and that test and scoring files are unchanged (by diff). This is a direct
   check of the seed "Weakening tests or oversight". A flagged cell counts as failed and is
   not queued again, so a setup can't re-roll its bad outcomes away.
4. **Statistics, not "+4 cells".** 21/30 against 25/30 gives p ≈ 0.36 by Fisher's exact
   test: compatible with noise. Two baseline runs in a row don't estimate the noise.
   - Unit: the pass rate per task over k ≥ 3 repeats.
   - Comparison: paired by task (bootstrap over tasks), with the production guard of
     [Fixes](#fixes).
   - Shown: Wilson intervals, pass@1 (the chance one run passes) next to pass^k (the
     chance all k runs pass).
   - The set grows to 20–30 tasks before the number of repeats grows.
5. **Cell key** = the [done key](#done-key) of a cell: the task + the setup (harness,
   model, effort, the one difference) + base commit + repeat number. Cells already run
   aren't rerun.
6. **Money.** Copilot bills per token in AI credits since June 2026, so runs cost money,
   not just quota. AKit estimates the cost before a run; the monthly limit is shared with
   the analysis.
7. **Sending policy.** Tasks and traces contain the code of a work repository. Control
   runs go through the same policy with the code as origin: on a personal Mac the agent's
   own harness counts as the origin, on a work Mac only the allowed list (harness +
   provider + account + plan/org) does; see [Sending policy](#sending-policy).
8. **Sanity checks:**
   - a deliberately broken setup (read-only tools) must fail;
   - the tests are green on the reference commit;
   - a manual calibration of 5 red and 2 green cells.

**Reproducibility: HEAD only.** A control task needs the repository state at the
session's start. The capture hook records HEAD from `.git` files as text. Uncommitted
changes would need a process, which the hook's contract rules out, so a session that
started with uncommitted changes can't become a control task. Instead, the user can write
a minimal reproduction: the simplest request that triggers the mode.

## Storage

```
~/.akit/lab/analysis/        # a local git repo, no remote; tracks modes/ only
  modes/modes.json           # definitions, version, merged_into
  modes/exemplars/           # quotes from scrubbed transcripts, never exported
  notes/<session-key>.json   # outcome, notes (model and human, verifier verdicts),
                             # paragraph, advice, routes, done keys
  checks/<mode-id>.json      # code check verdicts per session
  checks/<mode-id>@judge.json # judge verdicts per session with tough_call and severe
  labels/                    # bootstrap notes, reservations, pairs, the label book
                             # (mappings, finds, spot checks, tough calls), unclear,
                             # judges, train/dev/test splits, validation results
  batches/<run-id>.json      # sample with inclusion probabilities, per-session status,
                             # candidates, spot-check picks
  fixes/<mode-id>.json       # fix drafts (the status lives in modes.json)
  work/                      # input files of model calls made from the app
  sends.jsonl                # send log
~/.akit/lab/evals/           # control tasks and sets; cells are Lab runs
```

All of it is local and never goes into the brain repo. Everything outside `modes/` is
ignored by the local git repo, so notes and quotes never enter its history. A later export
of `general` definitions (no exemplars) would need a scrub check first: an internal tool
or client name can leak through a criterion. `project:` modes from a work machine are
never synced.

## Implementation plan

Each slice is usable in the installed AKit and brings its own UI. Built on branch
`error-analysis` (2026-10-01, all slices; merged as one feature). Code: module
`AKitErrorAnalysis` (plus the sending policy in `AKitLab`, the scrubber in
`AKitFoundation`, HEAD and signals in `AKitInsights`); commands `akit analysis …`,
`akit lab new analysis`, `akit lab policy|sends`; screens Settings → Lab, Lab (Sends,
review notes, batch and control runs) and Error Analysis (Modes, Review, Bootstrap,
Reports, Evals).

What differs from the text above, found while building or on real sessions:

- **Verifier context.** The verifier sees the cited step and the three steps before and
  after it: on a real session it rejected claims that sum up a step with its neighbours
  when it saw the step alone. Quotes under 8 characters are rejected in code, and so is a
  quote with elisions ("…") none of whose parts reaches 8 characters ("error … ok"). One
  long part anchors the quote in its step and the short ones must still follow it there;
  requiring every part to be long rejected valid quotes the prompt allows.
- **Low-confidence routes** count in "seen in k notes" only after the user accepts them.
- **Lab's own sessions** (replays, control cells, agent reviews) are left out of samples,
  bootstrap picks and check rates, so evals never enter production frequencies.
- **Signals** live in the session index (schema v6, table `signals`), computed by
  `akit analysis signals` and after every `akit sessions import` once error analysis is in
  use, together with the code checks of active modes.
- **Code checks.** Seed 9 has a mechanical check (output over 20 KB of a Read without a
  range or a plain `cat`); seeds 1, 5, 7 and 8 have heuristic checks.
- **Control tasks** keep a `referenceGreen` flag from `akit analysis control task check`;
  a success mode's assertion passes when the mode shows (from the mode's kind).
- Model calls of the analysis run with `--no-session-persistence` (Claude Code) or
  `--no-session` (Pi), so they never appear as sessions.
- **Clustering never confirms a mode.** Its candidates wait for the user; a candidate is
  promoted when a later session (matching, retro-matching or the user) routes a note to it.
  A seed is activated by two batches whose own matching routed two different sessions to it.
- **Scrubber v4.** After a secret's name, long hex values and UUIDs are masked unless the
  name says hash (sha, digest, commit, checksum, cache…); `--token VALUE` flags are masked;
  weak passwords after a password's name are masked (see [Sending policy](#sending-policy)).
- **Same origin for Claude Code.** A Claude Code transcript doesn't record its account, so
  same-origin compares the harness only: any signed-in Claude Code account counts (a
  commented decision in `SendPolicy`).
- **Concurrent writers.** Every file of the analysis folder is changed under a lock, as a
  read-modify-write of what is on disk, so the app, `akit` and two batch workers never save
  over each other.
- **Fixes.** A draft of a fix already applied needs an explicit start-over (it would move T
  and its criterion); the before/after view also flags a harness-version change.
- **Matrix.** Sessions with failures but no decisive step are counted as unlocated, outside
  the cells.

Status per slice: all done 2026-10-01/02, with the review fixes above.

Not built (yet):

- **Manual calibration** of 5 red and 2 green control cells ([Controlled
  evals](#controlled-evals), sanity checks); red cells of a fixed setup aren't offered for
  review on their own either (a cell is a Lab run the user can open).
- **Merge and split proposals** for modes in general: only seeds that absorb more than 30%
  of the routed notes are flagged as umbrellas, and the rebuild marks groups that span
  several modes. Merges and splits are the user's own.
- **Control "helped"** needs production data, which exists only after the fix is applied
  and only for tasks of a single mode, so a draft tried on control tasks before it is
  applied ends at "no conclusion".
- **Tough calls from code checks**: no code check sets the flag; only judges do.

1. **Sending policy and cost.**
   - Allowed list with the account check: Settings → Lab.
   - Scrub, send log, cost estimate and monthly limit: a send log view in Lab.
   - It guards today's review too.
2. **Blind notes and the verifier.**
   - Outcome, notes, deviation steps, paragraph and advice in the one-session review,
     with "Re-check with another model" for hard sessions;
     the verifier pass; the evidence-preserving digest.
   - The code phase classifier; the note pool, the done key, "no failures" records.
   - HEAD at session start.
   - UI: the review shows verified and rejected notes, deviation steps "about here", phases.
3. **Bootstrap labeling.**
   - Reserved sessions picked by the agent; the blind labeling screen; pairing of notes.
   - Recall, precision, phase agreement and step agreement per notes model/prompt version.
4. **Modes.**
   - The clustering call; first modes from the bootstrap notes; seeds, activated by
     confirmation only until batches exist (slice 6).
   - The modes list in the local git repo with exemplars.
   - Routing with "none fits" and route acceptance; candidates; the human queue (low-
     confidence routes, spot checks).
   - The user's mapping of bootstrap notes to modes; the similar-case search and the
     bootstrap stop rule; retro-matching by button.
   - UI: modes table (rename / merge / reject / move), candidates, mapping.
5. **Code checks.**
   - Cheap signals in the session index.
   - Mechanical code checks over indexed sessions, run on confirmation and on every new
     session; their sampling intervals.
   - UI: each mode's page with its rate over indexed sessions.
6. **Batch run and report.**
   - The run: stratified sampling with weights, fixed parallelism, pause, retry errors,
     clustering of unmatched notes at the end; seed activation by batch matches.
   - The report: frequencies by outcome, "seen in k notes", saturation and rebuild,
     funnel or matrix behind the phase-agreement gate, comparison.
7. **Fixes and controlled evals.**
   - Drafts and statuses; before/after T with the "helped" rule.
   - Control sets as Lab replay tasks with the shared event parser.
8. **Judges and validation.**
   - LLM judges and heuristic code checks for 2–3 modes picked by the rule in
     [Checks](#checks), validated as in [Validation](#validation).
   - Rogan–Gladen correction; pool judge runs by button; `tough_call` review.

## Decisions

Decided by the user on 2026-10-01; they replace the open questions of the design.

- **Personal machine default: same-origin.** A transcript may go only to the provider and
  account that produced it; everything else is added explicitly. (Since 2026-10-07 on a
  work machine too; see the Pi account decision.)
- **Pi account: entered by the user** (option b). Pi is allowed by provider + model + the
  account and plan/org the user entered in Settings → Lab; no harness secret is touched and
  CLAUDE.md needs no exception. With same-origin, a Pi session is reviewed only through the
  Pi provider that produced it. AKit can't see a switched account behind Pi; on a work
  machine that means trusting the entry.
  Changed by the user on 2026-10-07: a harness that is already signed in is used as it
  is, on a work Mac too, with nothing typed in. Pi can't tell its account and the entry
  was never checked, so same-origin for Pi compares the provider, as it compares the
  harness for Claude Code; the data goes back where it already went, so nobody new gets
  it. A Pi destination with no account entered is "account not entered" and matches no
  list entry, not even an old one with blank fields. The allowed list (the company's on a
  work Mac) is for cross-origin sends; allowing a Pi destination (Settings or `akit lab
  policy allow pi …`) also enters it as the provider's Pi account. The review sheets say
  what the policy will refuse before a run is queued. Known gap, as before: an account
  switched inside the harness since the session isn't seen.
- **Randomized interleaving: no.** The user applies fixes; AKit never changes the context
  of real sessions, stays read-only and the capture hook keeps printing nothing. The fix
  signals are control sets and before/after T.
- **Controlled evals: Lab replay tasks**, extended to control tasks made from sessions and
  to Pi. One runner and one UI; no promptfoo or Node dependency.
- **Snapshot: HEAD only.** The capture hook records HEAD from `.git` files. Sessions that
  started with uncommitted changes can't become control tasks; minimal reproductions cover
  them.
- **Credits: recorded only.** The send log keeps the cost each harness recorded for a call
  (Claude Code's `total_cost_usd`, Pi's `usage.cost`); the estimate before a run is "≈"
  from recorded calls of the same harness and model. No rate table.
- **`get_step(n)`: no tool.** The calls stay tool-less; the digest keeps user turns and the
  evidence stubs, and the verifier checks quotes in code against the full scrubbed
  transcript.
- **Label volume:** as proposed (about 100 labels per judged mode, at most three judged
  modes); the thresholds are constants in one place.
- **Scrub: gitleaks rules ported to Swift** next to `SecretFilter`, plus own patterns and the
  hex allowlist. No new dependency.
- **Control sets:** HEAD snapshots from now on, minimal reproductions for older sessions.
- **Claude Code `/insights`:** a one-time manual comparison, not part of AKit.

## Caveats

- Many 2026 sources are preprints. Their numbers are used as orientation, not as constants.
- The power figures (30 and 80 sessions per group), the Wilson intervals (18/20, 29/30,
  46/50) and the Fisher p for 21/30 against 25/30 are our own calculations, not quotes.

## Sources

- Hamel Husain and Shreya Shankar, AI Evals FAQ: https://hamel.dev/blog/posts/evals-faq/;
  `ai-evals-course/evals-skills` (error-discovery, validate-evaluator).
- ai-evals-course/error-discovery-skill: https://github.com/ai-evals-course/error-discovery-skill
- ai-evals-course/judgy: https://github.com/ai-evals-course/judgy
- Transluce, Measuring coding agent misalignment in the wild:
  https://transluce.org/docent/blog/coding-agent-behaviors; Docent: https://transluce.org/docent
- Inspect Scout (scanner validation): https://meridianlabs-ai.github.io/inspect_scout/
- Tang et al., How Coding Agents Fail Their Users: https://arxiv.org/abs/2605.29442
- Failure as a Process: https://arxiv.org/abs/2607.09510
- Who&When: https://arxiv.org/abs/2505.00212; TRAIL: https://arxiv.org/abs/2505.08638
- METR, Recent Frontier Models Are Reward Hacking (metr.org).
- Bowyer, Aitchison, Ivanova, small-sample eval uncertainty: https://arxiv.org/abs/2503.01747
- Miller, Adding Error Bars to Evals: https://arxiv.org/abs/2411.00640
- Lee et al., How to Correctly Report LLM-as-a-Judge Evaluations:
  https://arxiv.org/abs/2511.21140
- Shankar et al., Who Validates the Validators? (EvalGen): https://arxiv.org/abs/2404.12272
- Anthropic, "Demystifying evals for AI agents":
  https://anthropic.com/engineering/demystifying-evals-for-ai-agents; Anthropic, April 23
  postmortem.
- Replit, Closing the loop: https://replit.com/blog/evaluating-and-improving-agent-at-scale
- Bryan Bischof, Failure is a Funnel (Data Council 2025); Lenny's Newsletter, "Building
  eval systems".
- promptfoo docs: https://promptfoo.dev
- MAST, Why Do Multi-Agent LLM Systems Fail?: https://arxiv.org/abs/2503.13657
- Model or Harness? An Interaction-Centric Taxonomy: https://arxiv.org/abs/2607.28802
- Engineering Reliable Coding Agents: https://arxiv.org/abs/2608.13867
- Wink: https://arxiv.org/abs/2602.17037
- AWS, Failure detection and RCA with Strands Evals:
  https://aws.amazon.com/blogs/machine-learning/ai-agent-failure-detection-and-root-cause-analysis-with-strands-evals/
- Langfuse, Error analysis:
  https://langfuse.com/blog/2025-08-29-error-analysis-to-evaluate-llm-applications
- Arize, Agent evals from traces: https://arize.com/resources/agent-evals-from-traces/
- benchflow-ai/awesome-evals PATTERNS.
