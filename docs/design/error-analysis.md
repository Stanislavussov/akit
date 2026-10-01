# Error analysis: failure modes across many sessions

Status: design 2026-10-01 (decided in a grilling session), not started. Extends Lab
(`lab.md`): the one-session review becomes the first step of this pipeline.

## Goal

Find out what goes wrong in agent sessions *again and again*, how often, and whether a
fix helped, with every claim backed by steps of real transcripts. One session review
answers "what went wrong here"; this answers "what goes wrong, how often, and did the
fix work".

Method (error analysis, as practitioners do it for LLM apps):

1. **Open coding.** Free notes per session about what went wrong, with no predefined
   categories.
2. **Axial coding.** Group the notes into concretely named failure modes ("full read of a
   34 KB file", not "context issues").
3. **Counting.** Frequency of each mode, sliced by project, harness and model.
4. **Saturation.** Stop adding sessions when no new modes appear.

A human stays in the loop: they confirm changes to the list of modes, not every note.

## Terms

- **Note**: one problem seen in one session (open coding output).
- **Mode**: a failure mode, a definition with criteria, not just a name.
- **Batch run**: a Lab run over a sample of sessions. Only batch notes count towards
  frequencies.
- **Ad-hoc review**: today's review of one session. Its notes go into the pool as
  examples and candidates, and count as "seen manually", never in a denominator.

## Sampling (batch)

The user picks a project and a period. AKit takes up to N sessions (default 20) from the
session index, spread over length, tool errors, harness and model; sessions with fewer
than 5 requests are skipped. Each note records `sampling` (how its session was chosen).
Ad-hoc reviews hint which similar sessions the next batch should add.

## Step 1: notes per session (one call)

One structured call per session, fields in this order:

1. **Blind notes.** The call never sees the list of modes. Each note has:
   - free description;
   - step `#n` and a quote;
   - fault layer: agent (model), harness setup (CLAUDE.md, skills, hooks, MCP),
     environment/tools, task spec (the user's request), grader (rare in our sessions);
   - root or symptom (symptom of `#m`);
   - cost in tokens or steps.
   - The session's first point of deviation is marked.
2. **Paragraph.** 3–5 sentences, written from the transcript, not only from the notes.
3. **Up to 3 improvements.** Generic advice as today (`lab.md`). Each cites the ids of the
   notes it rests on. Advice that rests on a tool's behaviour ("the tool returned garbage")
   says whether that was checked by repeating the step. In call mode it never was.

A session with no problems is stored as "checked, no failures"; it counts in denominators.

Re-reviewing the same session replaces its notes; it doesn't add to them. The dedup key is
session id + notes prompt version.

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
- After a new mode is confirmed, the whole note pool is matched against it again
  (retro-matching).

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

- **Versions.** Every rename, merge, split or reject writes a new version of the list
  with a log entry (`history.jsonl`). Past frequencies are recounted through the merge map,
  so trends survive.
- **Rejected modes** are kept with "rejected because…", so the model doesn't propose
  them again.
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

After each run the UI shows only:

- candidate modes;
- proposals to merge or split modes;
- low-confidence matches;
- 5–10 notes picked at random for a spot check. If notes miss something important
  systematically, no clustering fixes it.

Confirmed modes with familiar exemplars aren't re-checked. The first UI is a table with
rename / merge / reject / move-note actions.

## Saturation

- Per run: the share of notes that matched no mode, and new confirmed modes.
- Both are counted globally **and per project**, so a new project's own modes don't
  drown in the global numbers.
- Both near zero for several runs in a row means the list is saturated. Frequent modes
  can then move to automatic checks.
- **Rebuild.** Every N runs, or when the unmatched share exceeds 15%, all notes are
  clustered again from scratch, without seeds, and compared to the list. A seed whose
  notes fall into several clusters is flagged as an umbrella.

## Batch run

- **Lab run.** One "Error analysis" run in Lab, with progress k/N for each step (notes,
  matching, clustering).
- **Per-session status.** pending / running / done / error (with the reason). Invalid
  output is an error, not a skip.
- **Done key.** session id + transcript hash + notes prompt version + model + scrub
  version. If it matches, the step is skipped; otherwise it is recomputed. The same
  applies to matching, whose key also has the version of the modes list. Changing a
  step's model recomputes only that step.
- **Pipeline.** A session's matching starts right after its notes. Clustering is one
  call at the end, over everything done; the report shows coverage k/N if some sessions
  failed.
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
| Matching | GPT-6 Luna, after its agreement is checked on 20–30 labeled notes |
| Clustering | GPT-6.1 Sol |

- **Different family.** If the session ran on a model of the reviewer's family, AKit
  takes a model of another family when it can.
- **Digest size.** The transcript is compressed before sending: long tool output becomes
  a stub that refers to it. The target is an input under 272K tokens; today's
  `ReviewDigest` budget, 360K chars (about 90K tokens), becomes per-model.
- **Cache.** A stable prefix (system prompt + modes list) comes first in the request.

## Sending policy

This applies to every call that sends session data out: notes, ad-hoc reviews,
matching and clustering (notes contain quotes), subagents, and a harness picked
automatically.

- **Allowed list.** Settings → Lab holds the destinations allowed for session data. An
  entry is harness + provider + account + plan/organization (the org through which
  Copilot is granted, not only the login). The list is empty by default on a work
  machine (`work` mode, see `layers.md`). The UI hint says to fill it in by the company
  policy for *session data*, not only for code.
- **Account check** runs at the start of each review and batch, and again every ~15
  minutes inside a long batch. If the account can't be determined, or there is no plan
  or org data, the call is refused.
  - **Claude Code:** `claude auth status --json` returns `email`, `orgId` and `orgName`,
    and no secrets.
  - **Pi** has no whoami: `pi auth check --json` gives only provider, status and reason.
    Exception to "AKit never reads harness keys":
    1. AKit runs `pi auth print-bearer-token --provider github-copilot`. The token stays
       in AKit's process memory only: no shell, never in another process's arguments,
       never written or shown.
    2. AKit asks `api.github.com/user` for the login, and Copilot's plan/org for the
       rest. HTTP errors are logged without headers or body.
    3. First check whether `/user` accepts that token. If it is a Copilot token that
       `/user` rejects, find the OAuth token or treat the account as undetermined.
    4. The exception is written into CLAUDE.md and removed once Pi has a whoami
       command (request it upstream).
  - **A failed check rejects Pi on this machine**; Claude Code keeps working.
- **Scrub before sending.** Keys, tokens, e-mails, private hosts and `.env` contents
  are removed, and long tool output is cut. The scrub version is part of the done key.
- **Send log** (`sends.jsonl`): session, harness, provider, account, tokens and scrub
  version.

## Fixes

Each mode moves through these statuses: open → draft → applied(T) → confirmed / didn't
help / rejected (with a reason).

- **Draft** (a button on a mode): the layer to change (CLAUDE.md rule, skill, hook, tool
  description, environment), the text, links to exemplar notes, and the expected
  observable change in transcripts. The user applies it; there is no auto-apply.
- **Check per mode.**
  - Where possible, a pass/fail check in code over the session index.
  - Otherwise an LLM judge, validated on the exemplars.
  - The check runs over every new session of the project.
- **Applied at T** (an `akit stats mark`-style anchor).
  - **Signals.** Frequency before/after T: from the check (primary) and from batch
    matching (secondary).
  - **Sample size.** N is shown on both sides; with N < 15 there is no conclusion.
  - **Confounders.** Changes of session model or prompt version between the periods
    are flagged.
  - **Side effects.** Modes whose frequency grew after T are shown.

## Storage

```
~/.akit/lab/analysis/
  modes/modes.json         # definitions, versioned
  modes/history.jsonl      # renames, merges, splits, rejects, status changes
  modes/exemplars/         # quotes, never exported
  notes/<session-key>.json # notes, paragraph, advice, matching, done keys
  batches/<run-id>.json    # sample, per-session status, coverage, saturation numbers
  sends.jsonl              # send log
```

All of it is local and never goes into the brain repo. A later export of `general`
definitions (no exemplars) would need a scrub check first: an internal tool or client
name can leak through a criterion. `project:` modes from a work machine are never
synced.

## Implementation plan

Each slice is merged into master with a tag and is usable in the installed AKit.

1. **Sending policy.** Allowed list in Settings, account check (Claude, Pi with the
   token exception), scrub, send log. It guards today's review too. Add the CLAUDE.md
   exception.
2. **Blind notes.** Notes in the one-session review (notes → paragraph → advice), the
   note pool, done keys, "no failures" records.
3. **Modes.** Modes list with versions, history, exemplars and seeds; blind matching
   with "none fits"; retro-matching.
4. **Batch run.** Sampling, adaptive parallelism, pause/resume, retry errors, clustering,
   cost estimate, monthly limit.
5. **UI.** Modes table (rename / merge / reject / move), candidates, spot check,
   saturation numbers, rebuild.
6. **Fixes.** Drafts, per-mode checks (code first, judge second), before/after T.

## Open questions

- **Personal machine default.** Should the allowed list start empty there too, or with
  the harnesses already signed in?
- **Credits.** How Copilot credits per token are read for the cost estimate. Pi
  records cost per request; check that it does for `github-copilot`.
- **Upstream request.** Ask Pi for a whoami command. This is outward-facing, so it
  happens only after the user agrees to it.
- **Matching agreement.** What the 20–30 labeled notes are, and who labels them (the
  spot checks of slices 2–3 are the natural source).

## Sources

- Transluce Docent; Anthropic, "Demystifying evals for AI agents"; AWS Strands Evals
  detectors; MAST ("Why Do Multi-Agent LLM Systems Fail?", arXiv 2503.13657);
  Hamel Husain and Shreya Shankar, evals FAQ and `ai-evals-course/evals-skills`
  (error-discovery); Langfuse, "Error analysis"; "Model or Harness? An Interaction-Centric
  Taxonomy" (arXiv 2607.28802); Wink (arXiv 2602.17037); Arize, agent evals from traces.
