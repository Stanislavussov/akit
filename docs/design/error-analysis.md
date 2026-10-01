# Error analysis: failure modes across many sessions

Status: design 2026-10-01 (decided in a grilling session, then reviewed against the
evals literature), not started. Extends Lab (`lab.md`): the one-session review becomes the
first step of this pipeline.

## Goal

Find out what goes wrong in agent sessions *again and again*, how often, at which step of
the work, and whether a fix helped, with every claim backed by steps of real transcripts.
One session review answers "what went wrong here"; this answers "what goes wrong, how
often, where, and did the fix work".

Method (error analysis, as Hamel Husain and Shreya Shankar teach it):

1. **Bootstrap.** The user reads 20–30 sessions and writes their own notes before seeing
   the model's notes.
2. **Open coding.** Free notes per session about what went wrong, with no predefined
   categories.
3. **Axial coding.** Group the notes into concretely named failure modes ("full read of a
   34 KB file", not "context issues").
4. **Counting.** Frequency of each mode, sliced by outcome, project, harness and model.
5. **Saturation.** Stop adding sessions when no new modes appear.

A human stays in the loop: they label the bootstrap set and confirm changes to the list of
modes, but they don't label every session.

## Terms

- **Note**: one problem seen in one session (open coding). Written by the model or by the
  user (`source: model | human`).
- **Mode**: a failure mode, a definition with criteria, not just a name.
- **Outcome**: did the session reach the user's goal; see [Step 1](#step-1-notes-per-session-one-call).
- **Phase**: where in the work something happened, from a fixed list: understand → explore
  → plan → edit → verify → report.
- **Batch run**: a Lab run over a sample of sessions. Only batch notes count towards
  frequencies.
- **Ad-hoc review**: today's review of one session. Its notes go into the pool as examples
  and candidates, and count as "seen manually", never in a denominator.

## Sampling (batch)

The user picks a project and a period. AKit takes up to N sessions (default 20) from the
session index, spread over length, tool errors, harness and model; sessions with fewer
than 5 requests are skipped. Each note records `sampling` (how its session was chosen).
Ad-hoc reviews hint which similar sessions the next batch should add.

## Step 1: notes per session (one call)

One structured call per session, fields in this order:

1. **Outcome.** Did the session reach the user's goal: achieved, partly, no, unclear. It is
   judged from what the user saw (their messages and the final state they were told
   about). It is stored per session, separate from the notes (transcript versus outcome).
2. **Blind notes.** The call never sees the list of modes. Each note has:
   - free description;
   - step `#n` and a quote;
   - `phase`;
   - fault layer: agent (model), harness setup (CLAUDE.md, skills, hooks, MCP),
     environment/tools, task spec (the user's request), grader (rare in our sessions);
   - root or symptom (symptom of `#m`);
   - cost in tokens or steps.

   The session's first point of deviation is marked, together with the last phase
   completed before it (this feeds the [transition matrix](#transition-matrix)). Later
   problems are often a cascade of the first one.
3. **Paragraph.** 3–5 sentences, written from the transcript, not only from the notes.
4. **Up to 3 improvements.** Generic advice as today (`lab.md`). Each cites the ids of the
   notes it rests on. Advice that rests on a tool's behaviour ("the tool returned garbage")
   says whether that was checked by repeating the step. In call mode it never was.

A session with no problems is stored as "checked, no failures"; it counts in denominators.

Re-reviewing the same session replaces its notes; it doesn't add to them. The dedup key is
session id + notes prompt version.

## Bootstrap labeling

A spot check of the model's notes shows their precision: did the model invent a problem?
It can't show their recall, because what the model missed is visible only to someone who
read the transcript. Recall is the main risk, so it is measured.

1. **Labeling.** The user labels 20–30 sessions blind before any model note of those
   sessions is shown. The UI shows the transcript; the user writes notes with the same
   fields (`source: human`), plus the outcome and the first point of deviation.
2. **Comparison.** The model's notes for the same sessions are then compared with the
   user's. The model proposes pairs of notes; the user confirms them.
   - **Recall** is the share of the user's problems the model found.
   - **Precision** is the share of the model's notes the user agrees with.
   - The two marks of the first point of deviation, and the two outcomes, should match.
3. **Labels.** The labeled set becomes the labels for validating matching and checks
   (see [Validation](#validation)).
4. **Repeat** on 10–15 new sessions whenever the notes model or the notes prompt changes.
   Recall per notes model/prompt version is shown next to every report built from it.

## Step 2: matching (separate call)

Runs after the paragraph is shown (async for an ad-hoc review). Input: the session's notes
and the current modes (definitions, criteria, exemplars), never the transcript. Each note
gets one mode with a confidence, or **"none fits"** (an explicit option, against anchoring).

Low-confidence matches go to the human. Unmatched notes become candidates (step 3).

## Step 3: clustering unmatched notes (batch end)

One call over all unmatched notes of the batch. It returns candidate modes (name,
definition, include/exclude criteria, the notes in them).

- A candidate from an ad-hoc review becomes a mode at its second independent case, or
  when confirmed in the UI.
- **After a new mode is confirmed:**
  - The whole note pool is matched against it again (retro-matching).
  - The mode's check (see [Checks](#checks)) runs over the raw transcripts of the pool,
    Docent style, showing where and why it matched. This gives an honest frequency even
    where no note was written, and shows how many cases the notes missed.

## Modes

`modes.json`, one list per machine, local only (`~/.akit/lab/analysis/modes/`). A mode:

| Field | Meaning |
|---|---|
| `id` | stable, survives renames |
| `name` | concrete, specific |
| `definition` | 1–2 sentences |
| `include`, `exclude` | criteria; without them the next run drifts and frequencies float |
| `scope` | `general` (default) or `project:<id>`, narrowed with one UI button; used only in filters and reports, matching sees all modes |
| `origin` | `seed-prior` (our observations), `seed-literature` (MAST and similar), `emergent` |
| `faultLayer` | model, harness, environment, grader, task spec |
| `status` | see [Fixes](#fixes); seeds start as "seed, not confirmed" |

Exemplars (2–3 per mode, each with session, step and quote) live in `exemplars/`, separate
from the definitions. This way the definitions could later be exported without quotes.

- **Versions.** Every rename, merge, split or reject writes a new version of the list with
  a log entry (`history.jsonl`). Past frequencies are recounted through the merge map, so
  trends survive.
- **Rejected modes** are kept with "rejected because…", so the model doesn't propose them
  again.
- **"Unclear" bucket.** Notes the human couldn't place are kept; they are the main source
  of future modes.

### Seeds

About 8 seeds, each with a definition and include *and* exclude criteria.

- **From our observations (`seed-prior`):**
  - a long session not reset after finished steps;
  - UI not clicked through before "done";
  - a large file read whole.
- **Single-agent modes from MAST and similar (`seed-literature`):**
  - steps repeated without progress;
  - premature "done";
  - wrong self-check;
  - a tool error ignored;
  - an explicit requirement of the task broken.
- Broad modes like "drifted from the task" are left out or worded narrowly.

A seed appears in reports and frequencies only after 2 independent batch matches (ad-hoc
matches don't count) or confirmation in the UI. AKit tracks the share of notes each seed
absorbs; when that share is unusually high, it proposes narrowing or splitting the seed.

## Human in the loop

- **Bootstrap labeling** (above): the only place where recall is measured.
- **After each run** the UI shows only:
  - candidate modes;
  - proposals to merge or split modes;
  - low-confidence matches;
  - 5–10 notes picked at random for a precision spot check.
- **Confirmed modes** with familiar exemplars aren't re-checked.
- **First UI**: a table with rename / merge / reject / move-note actions.

## Batch report

- **Mode frequencies** are shown separately for sessions that reached their goal and those
  that didn't. A mode that is as frequent in successful sessions as in failed ones is a
  candidate for "not worth fixing".
- **Saturation**, coverage k/N, and the notes recall of the notes model/prompt version
  used.

### Saturation

- Per run: the share of notes that matched no mode, and new confirmed modes.
- Both are counted globally **and per project**, so a new project's own modes don't drown
  in the global numbers.
- Both near zero for several runs in a row means the list is saturated. Frequent modes can
  then move to automatic checks.
- **Rebuild.** Every N runs, or when the unmatched share exceeds 15%, all notes are
  clustered again from scratch, without seeds, and compared to the list. A seed whose
  notes fall into several clusters is flagged as an umbrella.

### Transition matrix

After Bryan Bischof's matrix. Modes answer "what breaks"; the matrix answers "on which
transition". A fix can leave a mode's frequency unchanged and still move the hot cell, for
example from edit → verify to verify → report. Only the matrix shows that.

- **Vocabulary.** The phase list is fixed: understand → explore → plan → edit → verify →
  report. The coding agent loops (edit → verify → edit), so the list stays short.
- **Rows and columns.** Rows are the last phase completed before the first point of
  deviation; columns are the phase of the first point of deviation. An extra "no failures"
  column shows the denominator.
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
  matching, clustering).
- **Per-session status.** pending / running / done / error (with the reason). Invalid
  output is an error, not a skip.
- **Done key.** session id + transcript hash + notes prompt version + model + scrub
  version. If it matches, the step is skipped; otherwise it is recomputed. The same applies
  to matching, whose key also has the version of the modes list. Changing a step's model
  recomputes only that step.
- **Pipeline.** A session's matching starts right after its notes. Clustering is one call
  at the end, over everything done; the report shows coverage k/N if some sessions failed.
- **Parallelism.** Adaptive: start with 2 (max 3), with starts a few seconds apart. On a
  rate limit, AKit backs off and drops to 1 for the rest of the run.
- **Pause** stops after the current calls; resuming continues from the same place.
- **Retry errors** reruns only the failed sessions, and an old result is deleted only
  after the retry succeeds.
- **Cost.** Before the start AKit shows an estimate of tokens and Copilot credits. A
  monthly analysis limit is a setting.

## Models and budget

Each step stores harness + model. Harnesses are Claude Code and Pi only; there is no
Copilot CLI harness. Copilot models (billed per token) go through Pi's `github-copilot`
provider (`/login` in Pi once).

| Step | Default |
|---|---|
| Notes + paragraph + advice | GPT-6.1 Sol (Pi, github-copilot) |
| Re-check of hard sessions | Claude Opus 5.5 (Claude Code), manual, by choice |
| Matching | GPT-6 Luna, once it passes [validation](#validation) |
| Clustering | GPT-6.1 Sol |

- **Different family.** By default, if the session ran on a model of the reviewer's
  family, AKit takes a model of another family when it can. This is a default, not a
  rule: a model with better TPR/TNR on our labels wins.
- **Digest size.** The transcript is compressed before sending: long tool output becomes a
  stub that refers to it. The target is an input under 272K tokens; today's
  `ReviewDigest` budget, 360K chars (about 90K tokens), becomes per-model.
- **Cache.** A stable prefix (system prompt + modes list) comes first in the request.

## Validation

This applies to matching and to every LLM judge. Raw agreement is not used, because a
judge can agree 80% of the time while missing most real failures.

- **Split.** Labeled data is split into train (10–20%), dev (40–45%) and test (40–45%).
  Exemplars and few-shot examples come only from train, so the test isn't leaked.
- **Iterate on dev** until TPR and TNR are both above 90%, measured separately. Then run
  once on the held-out test and record the result with the model and prompt version.
- **Matching** is measured per mode (recall of each mode) plus the recall of
  "none fits".
- **Volume.** About 100 binary labels per mode for a judge (50 pass, 50 fail). Until a
  mode has enough labels, its judge results are shown as "not validated".
- **Repeat** the test run when the model or the prompt changes.

## Checks

A check per confirmed mode is a pass/fail per session.

- Where possible, it is code over the session index.
- Otherwise it is an LLM judge, validated as above.
- It runs:
  - over the raw transcripts of the pool right after the mode is confirmed (see Step 3);
  - over every new session of the project from then on.

## Sending policy

This applies to every call that sends session data out: notes, ad-hoc reviews, matching
and clustering (notes contain quotes), checks, subagents, and a harness picked
automatically.

- **Allowed list.** Settings → Lab holds the destinations allowed for session data. An
  entry is harness + provider + account + plan/organization (the org through which Copilot
  is granted, not only the login). The list is empty by default on a work machine (`work`
  mode, see `layers.md`). The UI hint says to fill it in by the company policy for
  *session data*, not only for code.
- **Account check** runs at the start of each review and batch, and again every ~15
  minutes inside a long batch. If the account can't be determined, or there is no plan or
  org data, the call is refused.
  - **Claude Code:** `claude auth status --json` returns `email`, `orgId` and `orgName`, and
    no secrets.
  - **Pi** has no whoami: `pi auth check --json` gives only provider, status and reason.
    Exception to "AKit never reads harness keys":
    1. AKit runs `pi auth print-bearer-token --provider github-copilot`. The token stays in
       AKit's process memory only: no shell, never in another process's arguments, never
       written or shown.
    2. AKit asks `api.github.com/user` for the login, and Copilot's plan/org for the rest.
       HTTP errors are logged without headers or body.
    3. First check whether `/user` accepts that token. If it is a Copilot token that
       `/user` rejects, find the OAuth token or treat the account as undetermined.
    4. The exception is written into CLAUDE.md and removed once Pi has a whoami command
       (request it upstream).
  - **A failed check rejects Pi on this machine**; Claude Code keeps working.
- **Scrub before sending.** Keys, tokens, e-mails, private hosts and `.env` contents are
  removed, and long tool output is cut. The scrub version is part of the done key.
- **Send log** (`sends.jsonl`): session, harness, provider, account, tokens and scrub
  version.

## Fixes

Each mode moves through these statuses: open → draft → applied(T) → confirmed / didn't
help / rejected (with a reason).

- **Draft** (a button on a mode): the layer to change (CLAUDE.md rule, skill, hook, tool
  description, environment), the text, links to exemplar notes, and the expected
  observable change in transcripts. The user applies it; there is no auto-apply.
- **Applied at T** (an `akit stats mark`-style anchor). Three signals:
  1. **Control set** (controlled): a few reproducible tasks built from the mode's exemplar
     sessions, as Lab replay tasks (the same request, the same repo at that commit).
     They run several times before and after the fix. Production frequencies are noisy
     because the mix of tasks changes; this signal isn't.
  2. **The mode's check** over production sessions, before and after T.
  3. **Batch matching** frequency, before and after T.
- **Reading the signals.**
  - N is shown on both sides; with N < 15 there is no conclusion.
  - Changes of session model or prompt version between the periods are flagged.
  - Modes whose frequency grew after T are shown.
  - The transition matrix before/after T is shown as a difference.

## Storage

```
~/.akit/lab/analysis/
  modes/modes.json         # definitions, versioned
  modes/history.jsonl      # renames, merges, splits, rejects, status changes
  modes/exemplars/         # quotes, never exported
  notes/<session-key>.json # outcome, notes (model and human), paragraph, advice, matching, done keys
  labels/                  # bootstrap labels and train/dev/test splits, validation results
  batches/<run-id>.json    # sample, per-session status, coverage, saturation, matrix
  sends.jsonl              # send log
```

All of it is local and never goes into the brain repo. A later export of `general`
definitions (no exemplars) would need a scrub check first: an internal tool or client name
can leak through a criterion. `project:` modes from a work machine are never synced.

## Implementation plan

Each slice is merged into master with a tag, is usable in the installed AKit, and brings
its own UI.

1. **Sending policy.** Allowed list in Settings, account check (Claude, Pi with the token
   exception), scrub, send log. It guards today's review too. Add the CLAUDE.md exception.
2. **Blind notes.** Outcome, notes with phase, first point of deviation, paragraph and
   advice in the one-session review; the note pool, done keys, "no failures" records.
3. **Bootstrap labeling.** Blind labeling screen, pairing of notes, recall and precision
   per notes model/prompt version.
4. **Modes.**
   - Modes list with versions, history, exemplars and seeds; blind matching with "none
     fits"; retro-matching.
   - Matching validation on the labels.
   - Modes table: rename / merge / reject / move; candidates.
5. **Batch run.**
   - The run: sampling, adaptive parallelism, pause/resume, retry errors, clustering,
     cost estimate, monthly limit.
   - The report: frequencies by outcome, saturation, spot check, transition matrix and
     comparison.
6. **Checks.** Code checks first, then validated judges; a run over the raw pool on
   confirmation.
7. **Fixes.** Drafts, control sets from replay tasks, before/after T.

## Open questions

- **Personal machine default.** Should the allowed list start empty there too, or with
  the harnesses already signed in?
- **Credits.** How Copilot credits per token are read for the cost estimate. Pi records
  cost per request; check that it does for `github-copilot`.
- **Upstream request.** Ask Pi for a whoami command. This is outward-facing, so it happens
  only after the user agrees to it.
- **Label volume.** 100 labels per mode is a lot for one person. Which modes get a judge
  at all, versus code checks or staying "not validated"?
- **Control sets.** Replay tasks today come from commits (`lab.md`). Exemplar sessions
  without a clean commit need another way to pin the task and the repo state.

## Sources

- Hamel Husain and Shreya Shankar: AI Evals FAQ (agentic workflows, multi-turn traces,
  automating error analysis), `ai-evals-course/evals-skills` (error-discovery,
  validate-evaluator).
- Bryan Bischof's transition matrices; Lenny's Newsletter, "Building eval systems".
- Anthropic, "Demystifying evals for AI agents".
- Transluce Docent.
- AWS Strands Evals detectors.
- MAST ("Why Do Multi-Agent LLM Systems Fail?", arXiv 2503.13657).
- "Model or Harness? An Interaction-Centric Taxonomy" (arXiv 2607.28802).
- "Engineering Reliable Coding Agents" (arXiv 2608.13867).
- Wink (arXiv 2602.17037).
- Langfuse, "Error analysis".
- Arize, agent evals from traces.
- benchflow-ai/awesome-evals PATTERNS.
