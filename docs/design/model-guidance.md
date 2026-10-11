# Model guidance: setup that depends on the model

Status: proposal 2026-10-11, from a chat idea. Nothing is built. Not agreed: the user's
review is open, and the questions are D5–D10 in [`README.md`](README.md). Facts about
Claude Code, Pi and the providers' guides that this design relies on are marked "to verify"
and are checked in step 0, before any code.

## Problem

Providers publish prompting advice per model and a migration guide per release. A new model
arrives every few months. Today the setup in the brain doesn't follow it:

- nobody compares the new guide with the layers, so old instructions stay ("be more
  thorough", repeated rules) that the new model no longer needs;
- one harness runs several models (a large and a small one of the same provider), and a
  layer can't say "this text is only for that model". `AGENTS.md` is a committed file; the
  model is picked when the session starts.

## Goal

1. **Model notes.** A layer can bring a short text that reaches the agent only when the
   session runs a matching model. One store in the brain, one delivery per harness.
2. **Guidance review.** When a new model appears, one button starts an agent that reads
   the provider's guide, compares it with the layers and proposes changes as a diff. The
   user accepts the diff; nothing is changed before that.
3. **Proof.** A model note stays only when an eval on the user's own tasks shows that it
   helps for that model.

```
  new model in the index            Lab → New Run… → Model Guidance
  (Insights finding)  ──────────►   agent reads the guide + the layers
                                            │ proposal: diff + quotes
                                            ▼
                                    Accept… (brain commit)
                                            │ layer edits: mostly removals,
                                            │ sometimes a model note
                                            ▼
                         Brain → Set Up Project… (plan / apply)
                                            │ .agents/model-notes/
                                            ▼
        session start: hook (Claude Code) or extension (Pi) adds the matching note
                                            │
                                            ▼
              Brain → layer → Evaluate… for that model: keeps or drops the note
```

## What the guides give, and what they don't

- Most advice is to remove text, not to add it: shorter instructions, fewer "be careful"
  rules. So the usual result of a review is a smaller shared `AGENTS.md`, and a model note
  is the exception.
- The guides are written for people who write the whole prompt. The vendor already tuned
  the system prompt of Claude Code and Codex. AKit controls only the user's layer:
  `AGENTS.md` / `CLAUDE.md`, skills, hooks, settings. The review takes only advice that
  applies to that layer and says what it skipped.
- The guides say to test changes on your own tasks. That is the proof step below.

## Terms

- **Model note**: a Markdown file of a layer with a model selector. It is added to the
  agent's context only for a matching model. Not a fragment of `AGENTS.md` (`layers.md`
  uses "fragment" for those).
- **Model id**: the id the harness reports for the session (Claude Code: `model` in the
  hook input and the transcript; Pi: provider and model of the current agent).
- **Guide source**: where a provider's prompting guide and migration guide for a model are.
- **Guidance review**: the Lab run that compares a guide with the layers.

## Model notes

### layer.yaml

```yaml
model_notes:
  - template: model-notes/small-model.md   # under the layer's templates/
    models: ["claude-haiku-*"]             # globs on the model id; any match
    harness: [claude]                      # optional; default: every target
    when: strict_mode == true              # optional, same rules as files:
```

- `models:` is a list of globs (`*` only), matched case-insensitive against the whole
  model id. A family is a glob (`claude-sonnet-*`); there is no separate `family:` key.
  For Pi a glob without `/` matches the model id, one with `/` matches `provider/id`.
- A note without `models:` is an error: text for every model belongs in `AGENTS.md`.
- `{{field}}` substitution as in other Markdown templates. No secrets.
- Limits, checked in the plan before Apply: one note ≤ 1,500 characters; all notes that
  can match one model in one project ≤ 4,000 characters. Over the limit is an error, not
  a warning (D6). The reason: per-model text is the easiest way to grow a long,
  conflicting context, which is what the guides warn about.
- Older AKit ignores the key (as with `keep_auto`).

### What lands in the project

```
project/
  .agents/model-notes/
    index.json                 # schema, and per note: file, models, harness, sha256
    <layer>--<name>.md         # the rendered text
```

- Written, owned in the lock, updated and trashed like other rendered files; local-only
  projects and worktree links cover the folder like `.agents/skills`.
- No harness reads this folder by itself. Only AKit's hook and extension do.
- The core layer's notes go to `~/.akit/model-notes/` on **Update Home Folder…** (D7),
  not into a harness's home folder.
- Lookup at session start: the project folder (from `cwd` up to the repository root, the
  first `.agents/model-notes/index.json`), then the home folder. Project notes come first.
  Order inside one place: layer order, as for `AGENTS.md` sections.

### Delivery

| | Claude Code | Pi |
|---|---|---|
| Where | the akit plugin's `SessionStart` hook | AKit's extension (`akit-record.ts`), `before_agent_start` |
| How it knows the model | `model` in the hook's stdin (can be missing: then no note) | the current model of the agent (to verify: the field) |
| How the text enters | hook output as additional context | appended to the system prompt |
| When | `startup`, `resume`, `clear`, `compact`, `fork` | every agent start |
| Model changed inside a session | the note of the first model stays until the next start event | the next agent start gets the new model's note |
| Subagents with another model | no note in v1 | to verify |
| Codex, OpenCode | later, with their place in Layers | |

Rules for both:

- **No matching note, no output.** A session without a matching note gets exactly the
  bytes it gets today. The hook's rule "prints nothing" (`session-insights.md`, Capture)
  changes to "prints only the matching model notes" (D5).
- **Stable bytes.** The text for one model is the same on every start of a session while
  the files don't change, so the prompt cache holds. A test proves it for Claude Code (two
  runs of the hook command, same output); for Pi the proof is real Pi in a pty against a
  fake provider server: request bodies identical between turns, and identical to today's
  when no note matches.
- **One block.** The notes are joined under one heading that names their source
  (`Notes for this model (from AKit layers)`), so a transcript reader can tell where the
  text came from.
- **Fail open.** A missing or broken index, an unreadable file or a note over the limit
  adds nothing and never fails the session. `akit doctor` reports it.
- The Claude Code side is a second command of the same hook entry,
  `akit model-notes --harness claude`, which only reads files and prints. `akit
  record-session` keeps printing nothing.

### What is recorded

- The `session_start` spool line gets `model` (already designed in `session-insights.md`,
  step 11, not built) and `model_notes`: name and sha256 of each note that was added.
  Hashes and names only, Tier 0.
- The index keeps them per start event. Sessions → Overview shows "Model notes: …" for the
  session.
- The harness fingerprint is parked (D2). When it is built, `model_notes` is one of its
  components, so before/after never mixes sessions with and without a note.
- Layer evals need no fingerprint for this: cells pair within one eval and one agent
  (harness, model, effort).

## Guidance review

### Guide sources

A file in the brain, `guides/sources.yaml`, so a new provider or model needs no app change:

```yaml
sources:
  - provider: anthropic
    models: ["claude-*"]
    harness: [claude, pi]
    guide: <url of the provider's prompting guide; may contain {model}>
    migration: <url of the migration guide>
  - provider: openai
    models: ["gpt-*"]
    harness: [pi]
    guide: <url>
    migration: <url>
```

- AKit writes a starter file when the brain has none. Its URLs are filled in step 0 from
  the providers' sites, not from memory.
- Only `https` URLs. The review may fetch only the hosts listed here.
- A provider's own migration skill (if one exists: to verify) can be named as `skill:`;
  the review then tells the agent to use it. Not needed for v1.
- The file holds public URLs only, so a work Mac may read and sync it like layers.

### The trigger

- **Insights finding**: "New model: `<id>`, first seen `<date>`. No guidance review yet."
  with **Review Model Guidance…**. Source: the models of indexed sessions. A model counts
  as new when no review in `~/.akit/lab` names it and it has at least 3 sessions (one
  accidental session isn't worth a review). Dismiss… hides it for that model.
- **By hand**: Lab → New Run… → Model Guidance (pick harness, model, layers); the same
  button on a layer in Brain. Command: `akit lab guidance --harness H --model M
  [--layer L…] [--project P]`.

### The run

A Lab run of a new kind, `guidance`, in the terminal like a session review.

1. AKit prepares the run folder: a copy of the chosen layers (`layer.yaml`, templates, the
   skills they list) under `layers/`, the guide sources for the model, and the task text.
   Default layers: core plus the layers of the project the run was started from.
2. The agent (the harness and model the user picked; default: the reviewed model itself, D9)
   reads the guide and the migration guide, then edits the **copy** and writes
   `proposal.json`:

   ```json
   { "schema": 1, "model": "…", "harness": "claude",
     "sources": [{ "url": "…", "fetchedAt": "…", "sha256": "…" }],
     "changes": [
       { "id": "c1", "kind": "remove | shorten | move-to-note | new-note | setting",
         "layer": "base", "file": "templates/AGENTS.md.d/base.md",
         "quote": "the guide's sentence, verbatim", "url": "…",
         "why": "one sentence", "confidence": "guide | inference" } ],
     "skipped": ["advice that applies to the system prompt, not to the user's layer"] }
   ```

3. AKit checks the result before showing it: every change has a quote that is really in
   the fetched page (text match; a change without one is shown as "no source"); the
   copy's diff has no change that `proposal.json` doesn't list; limits of model notes hold.
4. The run's page shows the changes one by one: the quote with its link, the reason, the
   diff of that file. Each can be switched off. Kind `setting` (a default effort or
   thinking level) is shown as text only in v1: AKit doesn't write it.
5. **Accept…** writes the selected changes into the brain's layers with the usual safe
   write (backup, diff), as one brain commit "Model guidance for `<model>`: …". Projects
   get them through the normal plan / apply (the page offers Plan… as Insights does).
6. Nothing else changes. The agent never writes into the brain or a project.

Rules of the task text:

- prefer removing and shortening; propose a model note only where the guide names a
  behaviour of this model that differs from the others the user runs in that harness;
- touch only the user's layer; list skipped advice;
- quote, don't paraphrase; mark your own conclusions as `inference`.

### Safety

- **Sending.** The layers' text goes to the provider of the harness that runs the review.
  That is Tier 2 and goes through the sending policy (`definitions.md`): the user starts
  it, the sheet names the destination, a work machine's list decides. The copy holds
  layer files only: no project answers, no session text, no settings with values.
- **Fetched pages are data.** A guide page can contain instructions aimed at the agent.
  The agent works in the run folder only, with the denied commands of control cells; its
  only output that AKit uses is the copy's diff and `proposal.json`, and the user reads
  every change before Accept.
- **Sources are kept.** The fetched pages are saved in the run folder with their hash, so
  a later review can say "the guide changed since the last review".

## Proof

AKit has its own runner for this (layer evals; `error-analysis.md` decided against
promptfoo), so no new tool.

- A layer with a model note is evaluated as any layer: Brain → layer → **Evaluate…** with
  the note's model as the agent's model. Baseline: no layer. Layer setup: the layer with
  its notes, delivered by the same hook.
- The isolation check of layer cells gets one more rule: the baseline cell's transcript
  has no model-notes block, the layer cell's has it when the model matches.
- The verdict is already per agent (harness, model, effort) in `verdicts/<layer>.json`.
  A narrower question, "the layer with the note against the layer without it", is the
  "layer against layer" row of `layer-evals.md`, Later.
- The plan shows a warning on a model note whose layer has no "helps (offline)" verdict
  for a matching model: "not evaluated for this model" (D8: warning or block).
- The "model × setup matrix" of `layer-evals.md`, Later, is the view that shows where a
  note is needed: same layer, several models, one table.
- Gap: layer evals are for Claude Code only (I2). A Pi note can be delivered and recorded,
  but not evaluated, until Pi is a cell agent.

## Harness support

| | Claude Code | Pi | Codex, OpenCode |
|---|---|---|---|
| Notes rendered into the project | yes | yes | files only |
| Delivery | SessionStart hook | extension | not designed |
| Model change inside a session | on the next start event | on the next agent start | |
| Recorded in the index | yes | yes | |
| Guidance review | yes | yes | |
| Eval of a note | yes | no (I2) | |

## To verify first (step 0, no code)

| # | Fact | Why it matters |
|---|---|---|
| V1 | Claude Code: `model` in `SessionStart` stdin on every `source`; the exact output form for additional context; its size limit | delivery |
| V2 | Claude Code: what a hook can learn about a `/model` change, and whether `SubagentStart` gets the subagent's model and can add context | the two known gaps |
| V3 | Pi: `before_agent_start` may return a changed system prompt; where the current provider and model are; whether a handler order problem exists with other extensions | delivery |
| V4 | Pi: the system prompt with a note is byte-stable between turns (pty proof) | cache |
| V5 | The providers' guide and migration URLs, and whether they are stable per model | guide sources |
| V6 | A control cell's clone gets the hook's output (the plugin is in the home folder) | proof |
| V7 | The model ids each harness reports for the models the user runs | the globs |

A fact that fails changes the design before step 1, not after.

## Steps

One step is one branch, as in the design map. Each ends with its button.

| # | Step | Gives |
|---|---|---|
| 0 | Verify V1–V7; fill the starter `guides/sources.yaml` | a design without "to verify" |
| 1 | `model` in the spool line and the index (hook and Pi extension) | the "new model" signal; part of `session-insights.md` step 11 |
| 2 | `model_notes:` in `layer.yaml`: parse, limits, render to `.agents/model-notes/`, lock, home render; the layer editor in Brain lists and edits notes; the plan shows them | notes exist as files |
| 3 | Claude Code delivery: `akit model-notes`, the hook's second command, `akit doctor` line, the no-output and same-bytes tests | notes reach Claude Code |
| 4 | Pi delivery: the extension handler; the pty proof | notes reach Pi |
| 5 | Record active notes: spool, index, Sessions → Overview | "which note did this session have?" |
| 6 | Guide sources in the brain; Lab run `guidance`; the proposal page with Accept… and Plan…; `akit lab guidance` | the one-button review |
| 7 | Insights finding "New model" with Review Model Guidance… and Dismiss… | the trigger |
| 8 | Layer evals: the isolation rule for notes; the plan's "not evaluated for this model" warning | proof |

Steps 1–5 (notes) and 6–7 (review) don't depend on each other after step 1. The review is
useful without notes, because most of its proposals are removals; D10 asks which comes
first. The in-app guide `screens.ru.md` gets the new buttons in the commits that add them.

## Later

- A note for subagents; a check on each prompt for a changed model in Claude Code.
- Codex and OpenCode delivery.
- `setting` changes written by AKit (a default effort per harness) through JSON merge.
- "The guide changed" finding: fetch the sources on a schedule and compare hashes.
- Pi notes in layer evals (with Pi as a cell agent).

## Risks

- **Growth.** Notes pile up per model until the context is long and contradicts itself.
  Guards: the hard limits, the "not evaluated" warning, and the review's rule to prefer
  removals.
- **Trusting the guide.** A guide describes the vendor's tasks, not the user's. Guard: the
  proof step; a review's commit says "from the guide, not evaluated" until a verdict exists.
- **Hidden context.** Text that no committed file shows is hard to notice. Guards: the
  block's heading, the recorded note names, Sessions → Overview.
- **The hook starts to print.** A bug there reaches every session's context. Guards: fail
  open, no output without a match, the same-bytes tests.
