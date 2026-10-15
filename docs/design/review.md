# AKit Review: AI review of merge requests

Status: 2026-10-15, being built on branch `akit-review`. Grilled with the user on 2026-10-15 from a
research plan (Pi with the `github-copilot` provider, GitLab, Azure DevOps). The decisions
below are agreed. The user's employer allows both parts: Copilot from a third-party harness
(Pi) and AI comments in merge requests. Step 0 (facts on the work Mac) is still open: the code
was built against the public GitLab and Azure DevOps REST and Pi 1.0.4 on a personal Mac, and
`akit review check HOST` is the first fact to collect there.

Built: step 1 (2026-10-15): module `AKitReview` with the project profile, the three levels
(`ReviewCatalog`, `ReviewResolver`, `run.json`), Gather from GitLab and Azure DevOps REST into a
scrubbed context pack, the worktree at `head_sha`, `akit review MR-URL`, `akit review config show`,
`akit review token`, `akit review check`. Two additions to the design: the profile's `checkout:`
(the local clone the worktree comes from) and the tracker's `url:` (Azure DevOps Server). The
roles and scenarios of step 5 ship built in (`ReviewBuiltIns`, source `built-in`) and are used
while the brain has no layer `review`.

## What and why

The user reviews GitLab merge requests at work. An agent can read the change first, check it
against the work item (Azure DevOps) and propose comments. The user checks every comment, and
only then do the comments reach GitLab, as drafts in the user's own pending review.

Public numbers say that most AI review comments are noise: in a study of 31,073 CodeRabbit
comments (Lin et al., arXiv:2607.03316) 36.4 % were accepted and 56.3 % rejected; RevMate
(arXiv:2411.07091) saw 7–8 % accepted. Quality falls fast as the diff grows, and many false
positives come from missing context. So the design aims at precision, not recall: a verifier
pass, a hard cap on inline comments, and explicit **context gaps** instead of guesses.

The rule that shapes everything: **the model only reads and returns structured findings.**
Everything that writes, dedupes, marks or limits is deterministic Swift code in AKit. That keeps
the agent harmless against prompt injection from MR text, makes reruns idempotent and makes
the harness replaceable (Pi now, Claude Code later).

## Decisions (2026-10-15)

| # | Question | Decision |
|---|---|---|
| R1 | Where does it live? | A new module `AKitReview` in AKit. It depends on `AKitLab` and `AKitFoundation`, not the other way. Work configuration lives only in `~/.akit/local/review/` |
| R2 | Who writes to GitLab? | Only AKit, through the REST API, with a token in the Keychain. The agent never sees a GitLab or Azure DevOps token |
| R3 | How does the agent read GitLab and Azure DevOps? | It doesn't. AKit fetches everything itself (step Gather) into a context pack of local files. The agent has no MCP servers and no network except the model provider. What it lacks it reports as a context gap |
| R4 | When does AKit write? | Only after the user approves each request on the Review screen (or `akit review post RUN --yes`). Not one request goes out unapproved, deletes and updates included |
| R5 | What does AKit write? | Draft notes. The user publishes them in GitLab with **Submit review**, together with their own comments. AKit never calls `bulk_publish` or publishes a draft |
| R6 | Who orchestrates the passes? | AKit (Swift). Brief → roles → verifier, one after another **in one Pi session**, so later passes see the earlier ones and findings stay linked. Parallel fan-out only later, for big MRs |
| R7 | Interactive work | After a run, **Discuss in Pi…** opens an interactive Pi in a terminal (herdr, Orca) as `pi --fork <verifier session>`: the whole context, the run's session unchanged |
| R8 | First scenarios | Feature, Bugfix, Dependency upgrade. The user picks the scenario; the classifier comes later |
| R9 | What is a role? | One `SKILL.md` in the brain layer `review`, with review fields in its frontmatter. Scenarios are YAML in the same layer. These skills are not installed into the harnesses' skill folders; AKit passes them to review passes only |
| R10 | How configurable? | Everything, on three levels: brain → project profile → one run. The resolved `ReviewRunSpec` is saved in the run folder |
| R11 | Knowledge base | v1 reads markdown folders the project profile lists. A full KB (agent proposals in an inbox, linter) is a separate design, after the context gaps show what is missing |
| R12 | Reruns | By fingerprint, without the role in it (rules below). Every change to an earlier draft is a request to approve. Threads resolved by a person are never raised again. AKit never touches other people's threads |
| R13 | Noise | ≤ 7 inline drafts, severity ≥ medium, confidence ≥ 0.8; questions, gaps and the AC matrix go to one summary draft; the rest stays in AKit |
| R14 | Models | One model for the brief and the roles (one prompt cache), a strong model for the verifier, which gets only the candidates and their snippets. A cap per run, 150 credits by default |
| R15 | Agent tools | `read`, `grep`, `find`, `ls` and the `akit_*` tools. No `bash`, no `write`. Paths limited to the worktree and the run folder; secret patterns blocked. Git history and test output come from Gather |
| R16 | Quality | v1: the user's verdict on each finding at approval, with a reason tag, goes to Error Analysis. Sync of outcomes from GitLab comes later |
| R17 | Brain edits from the work Mac | Allowed for the generic review roles and scenarios, after a diff with warnings for work words (hosts, project paths, e-mails from the work profiles) |
| R18 | Order | Before wave 1 of `README.md` (layer evals on JS/TS) |
| R19 | Docs | An in-app guide `review.ru.md` describes how review works; each screen step updates it in the same commit (see Guide) |

Rejected on the way: the agent writing through GitLab MCP (no protection against injection);
read-only GitLab MCP (`zereight/gitlab-mcp`) and Azure DevOps MCP for the agent (third-party
servers on the work Mac, more tokens, a context the evals can't replay); orchestration in a Pi
extension (Pi only, no tests, the budget and send log written again in TypeScript); three
model tiers (switching models in one session loses the prompt cache); the role in the
fingerprint (one problem from two roles would become two comments).

## One run

```
akit review <mr-url> [--wi N] [--scenario S]        or  Review → New Review…
   │
   ├─ 1 Gather (AKit, no model)
   │     GitLab REST: MR, diff_refs, versions, changes, discussions (resolved too, with
   │     position), labels, branch; worktree at head_sha
   │     Azure DevOps REST: the work items (from --wi, the title, the description, the
   │     branch), their parents and related items one level deep: title, description,
   │     acceptance criteria, repro steps, state, comments, revisions
   │     git log / blame of the changed files; profile commands (tests, linter) if set
   │     knowledge folders from the profile
   │     → <run>/context/  (files the agent reads)
   │
   ├─ 2 Scenario: the user's choice (default from the profile); roles from the scenario
   │     and the three config levels → <run>/run.json (ReviewRunSpec)
   │
   ├─ 3 Estimate: credits from the context size; over the cap → ask
   │
   ├─ 4 Passes, one Pi session, in order:
   │     brief      intent, touched components, what people already raised, AC, first gaps
   │     role × N   candidates (≤ max_findings each) through akit_submit_findings
   │     verifier   strong model, fork of the session with only the candidates + snippets:
   │                confirms or rejects each, links and merges duplicates, turns a finding
   │                without enough context into a question or a gap, checks human threads
   │     → <run>/findings.json, <run>/gaps.json, sessions in <run>/sessions/
   │
   ├─ 5 Plan: AKit turns findings into requests (create / update / delete draft, summary)
   │     by the noise rules and the rerun rules
   │
   ├─ 6 Review screen: the user edits, approves or rejects each request (with a reason)
   │
   └─ 7 Send Drafts… → GitLab draft notes → the user's Submit review in GitLab
```

The run folder is `~/.akit/local/review/runs/<run-id>/`. Nothing of it leaves the Mac.

## Configuration

### Levels

```
brain layer `review`        generic: roles (SKILL.md), scenarios (YAML), review.yaml defaults
        ▼ overridden by
project profile             ~/.akit/local/review/projects/<slug>.yaml: own roles, roles off or
                            added, thresholds, models, constraints, path instructions
        ▼ overridden by
one run                     New Review…: scenario, roles on/off, models, thresholds, cap
        ▼
ReviewRunSpec (JSON)        <run>/run.json: exactly what this run used, with the source of each value
```

| Setting | Brain | Project | Run |
|---|---|---|---|
| Role text, `do_not_comment`, `max_findings`, `min_severity` | ✓ | ✓ (a project copy of the role) | — |
| A new role | ✓ | ✓ (work-only roles) | — |
| Roles of a scenario | ✓ | ✓ | ✓ |
| Model and thinking per pass | ✓ | ✓ | ✓ |
| Severity, confidence, inline cap, nitpicks | ✓ | ✓ | ✓ |
| Credit cap per run | ✓ | ✓ | ✓ |
| Constraints, path instructions, knowledge folders, Gather commands | — | ✓ | — |
| GitLab host and project, Azure DevOps org and project, WI pattern | — | ✓ | — |

Roles that name work systems, hosts or team rules live only in the project profile.

### Role (brain `layers/review/skills/review-<id>/SKILL.md`)

```markdown
---
name: review-security
description: Review a change for authN/authZ, input validation, injection, secrets, SSRF, PII in logs.
akit-review:
  min_severity: medium
  max_findings: 3
  needs: [diff, full_files]
  do_not_comment:
    - style and naming
    - attacks without a path from an input to a sink
---

<the checklist the model reads>
```

First roles: `domain`, `requirements`, `tests`, `bug-hunter`, `upgrade-risk`, `security`.
`requirements` puts no inline comments: it fills the summary's matrix "acceptance criterion →
covered by code / by a test / not found / can't check without X".

### Scenario (brain `layers/review/scenarios/<id>.yaml`)

```yaml
id: bugfix
roles: { required: [bug-hunter, requirements, tests], optional: [security] }
checks:
  - "Is the cause fixed, not the symptom (from the repro steps)?"
  - "Does a regression test reproduce the bug?"
context_required: [wi, full_files]
detect:            # read by the classifier later; ignored in v1
  wi_type: [Bug]
  branch_regex: "^(fix|bug)/"
```

| Scenario | Roles (required / optional) | Checks | Context |
|---|---|---|---|
| Feature | domain, requirements / tests | invariants, business rules, AC covered by code and tests | WI with AC |
| Bugfix | bug-hunter, requirements, tests / security | cause fixed, regression test, nearby paths | repro steps, comments |
| Dependency upgrade | upgrade-risk, tests / security | breaking changes, transitive upgrades, deprecated APIs, licenses | changelog or migration guide (often a gap) |

### Project profile (`~/.akit/local/review/projects/<slug>.yaml`)

```yaml
project: orders-service
gitlab: { host: https://gitlab.corp.example, project_path: team/orders-service }
tracker: { kind: azure-devops, org: corp, project: Orders, wi_ref_regex: "(?:AB#|WI-)(\\d+)" }
default_scenario: feature
knowledge: [~/.akit/local/knowledge/orders]
gather:
  - { name: tests, run: "dotnet test --no-build", timeout_s: 600 }
constraints:
  - "Public DTOs in contracts/ change only in backward-compatible ways"
path_instructions:
  - { paths: ["src/Domain/**"], instructions: "Aggregate invariants; no dependency on Infrastructure" }
  - { paths: ["**/*.generated.cs"], ignore: true }
roles: { off: [security], add: [orders-integration] }     # orders-integration: a project role
review: { max_inline: 5 }                                  # overrides review.yaml
```

### Defaults (`layers/review/review.yaml`)

```yaml
models: { passes: <from pi --list-models>, verifier: <strong model> }
posting:
  marker: "🤖 AKit review"
  severity_threshold: medium
  confidence_threshold: 0.8
  max_inline: 7
  nitpicks: false
cost: { cap_credits_per_run: 150 }
```

### Screens for configuration

Review → **Roles** and **Scenarios**: each item with its source (brain, project), Edit…,
Duplicate to Project…, Reset to Brain. `akit review config show [--project P]` prints the
resolved configuration with the source of each value. The files can be edited by hand too.

On a work Mac, saving a brain role shows the diff first and marks work words: the GitLab
hosts, project paths, organisation names and e-mail addresses from the work profiles (R17).

## The agent in a pass

Each pass is a Lab model call through the sending policy and the send log:

```
pi -p --mode json --session-id <run-session> --session-dir <run>/sessions
   --provider github-copilot --model <model> [--thinking <level>]
   --no-skills --no-context-files --no-prompt-templates --no-mcp --no-extensions
   --skill <role skill> …  --append-system-prompt <run>/prompts/<pass>.md
   -e <akit-review.ts>  --tools read,grep,find,ls,akit_submit_findings,akit_report_context_gap
   "<pass prompt>"
```

The working folder is the worktree at `head_sha`. The prompt names the context pack files.

The extension `akit-review.ts` is thin:

| Part | What it does |
|---|---|
| `akit_submit_findings` | Validates the findings against the schema and writes `<run>/passes/<pass>.json` |
| `akit_report_context_gap` | Writes a gap: system, what is needed, why, how to get it, the effect on confidence |
| `tool_call` policy | Allows paths only inside the worktree and the run folder; blocks `**/.env*`, `**/secrets/**`, `*.pem`, `*.key`, `auth.json`, `settings.local.json` |
| `appendEntry` | Records the run id, the scenario and `head_sha` in the session |

MR descriptions, comments and work item texts are untrusted input. The agent has no tool
that writes outside the run folder and no network tool, so an injection can at most produce a
bad finding, which the user sees before anything is sent.

For Claude Code later the same pipeline runs `claude -p --resume`, the role skill as a
subagent body, and the `akit_*` tools as a small local MCP server with PreToolUse hooks for
the path policy.

## Findings

```json
{
  "id": "f3",
  "role": "security",
  "file": "src/Auth/AuthMiddleware.cs",
  "side": "new", "line": 42,
  "title": "Token from the header is logged in full",
  "evidence": "logger.LogInformation(\"Auth: {Header}\", header)",
  "why": "The log goes to Kibana; anyone with log access gets the token",
  "severity": "high", "confidence": 0.86,
  "suggestion": "_logger.LogDebug(\"Auth header present: {Present}\", header is not null);",
  "related": ["f5"],
  "verifier": { "verdict": "confirmed", "note": "…" }
}
```

A verifier verdict is `confirmed`, `rejected` (with the reason), `question` (not enough
context: goes to the summary as a question to the author) or `merged` (into another finding).

**Fingerprint** = hash of the path, the anchor snippet (±2 lines, whitespace normalized) and
the normalized title. Not the line number, so it survives shifts; not the role, so one problem
from two roles is one finding.

## Requests and posting

### Where each finding goes (R13)

| Finding | Inline draft | Summary draft | Only in AKit |
|---|---|---|---|
| Confirmed, severity ≥ threshold, confidence ≥ threshold | ✓ (up to the cap) | counted | ✓ |
| Confirmed, over the cap | — | one line each | ✓ |
| Question (not enough context) | — | "Questions to the author" | ✓ |
| Context gaps | — | "What was missing" | ✓ |
| Acceptance criteria matrix | — | ✓ | ✓ |
| Below the thresholds, nitpicks, rejected by the verifier | — | — | ✓, with the reason |

The user can move any finding into an inline draft by hand.

### Inline draft

```markdown
🤖 **AKit review** · `security` · **high** · confidence 0.86

The token from the header is logged in full in `AuthMiddleware.cs:42` and reaches Kibana.

```suggestion
_logger.LogDebug("Auth header present: {Present}", header is not null);
```
<sub>AKit is an AI reviewer; check before applying.</sub>
<!-- akit-review:v1 fp=7c1e9a… role=security sev=high run=<run-id> -->
```

A finding that quotes a secret is posted as "a secret in `X:42`", without the value. Every
draft and the summary pass the scrubber before the Review screen shows them.

### Positions

From `diff_refs` and the MR versions: an added line gets only `new_line`, a removed line only
`old_line`, an unchanged line both; `base_sha`, `start_sha`, `head_sha` from the latest
version. A file GitLab can't comment on (over the diff limits) gets no inline draft: its
finding goes to the summary. GitLab silently drops a draft on such a file when it is
published.

### Reruns (R12)

AKit reads the MR's drafts (the user's own, through the token) and discussions and finds its
own by the marker.

| Finding in the new run | In GitLab now | Request |
|---|---|---|
| new | nothing | create a draft |
| same, other text | the user's draft | update the draft |
| same | a published, open thread | none |
| same | a thread resolved by a person | none; in the summary as "already dismissed" |
| gone (anchor gone or fixed) | the user's draft | delete the draft |
| gone | a published thread | a reply "looks fixed in <sha>", only when ticked |

AKit never resolves a thread and never touches threads it didn't write. The summary is one
draft, updated on each run.

### The Review screen

One run: the scenario and roles, the cost, the passes with their status. Below it the list of
requests: kind (create, update, delete, summary), file:line, the code around the anchor, the
text (editable), role, severity, confidence, the verifier's note. Each request: approve or
reject. A rejected finding needs one reason tag (below). **Send Drafts…** sends the approved
requests and shows what GitLab answered. **Discuss in Pi…** opens the fork (R7); a new
`akit_submit_findings` from there makes a new version of the findings, and the screen shows
what changed. Below the list: the "only in AKit" findings and the gaps.

The command line: `akit review <mr-url> [--wi N] [--scenario S]`, `akit review show RUN`,
`akit review post RUN` (prints the requests; `--yes` sends the approved ones; `--approve-all`
is not offered).

## Quality (R16)

| The user's action | Label |
|---|---|
| Approves without edits | `approved` |
| Approves with an edited text | `approved_edited` (the text diff is kept) |
| Rejects | `rejected`: `false-positive`, `no-context`, `style-nit`, `wrong-anchor`, `already-handled`, `wrong-requirement`, `out-of-scope`, plus an optional comment |
| Moves an "only in AKit" finding inline | `missed-by-filter` |
| Add Missed… | `missed`, with the user's text |

Precision = approved / (approved + rejected), by role, scenario and model, on the Review
screen. Rejected and missed findings become Error Analysis notes (origin `review`); a fix is an
edit of a role, a scenario or a threshold. Later: past MRs with known findings, pinned at
`head_sha`, as control tasks for evals of role × model × scenario.

## Privacy and the work Mac

- The destination goes into the sending policy's allowed list by hand: harness Pi, provider
  `github-copilot`, the work account. Empty by default on a work machine.
- What goes to the provider: the context pack files the agent reads (diff, files, threads,
  work items, knowledge notes). The send log records the run id, provider, model, tokens and
  credits, and the paths read (from `tool_call`).
- Run folders, findings, verdicts, profiles and tokens stay in `~/.akit/local` and the
  Keychain. The brain gets only generic roles and scenarios (R17).
- Review credits are their own line in the monthly limit.

## Tokens

| Token | Where | Rights |
|---|---|---|
| GitLab | Keychain, AKit only | read the MR and its notes, create, update and delete the user's draft notes (`api`, or fine-grained with these rights on the needed projects) |
| Azure DevOps | Keychain, AKit only | Work Items (Read) |

Neither token is passed to the agent, put in an environment variable of a pass, or shown.

## Steps

Each step is one feature branch.

| # | Step | Check |
|---|---|---|
| 0 | No code, on the work Mac: GitLab version (`/api/v4/version`), fine-grained tokens allowed; Azure DevOps Services or Server; `pi --list-models` for `github-copilot`; the two tokens created | the facts written into this doc |
| 1 | `AKitReview`: project profile, the three config levels, `ReviewRunSpec`; Gather from GitLab and Azure DevOps REST into the context pack; the worktree; `akit review` up to `run.json` | Swift tests on a fake server |
| 2 | The passes: brief → roles → verifier in one Pi session, `akit-review.ts` with the tools and the path policy, the estimate and the cap, the send log | fake Pi |
| 3 | Requests and the Review screen: noise rules, positions, scrubber, verdicts, Send Drafts…; `akit review post` | tests on a fake server; `make snapshot` |
| 4 | Reruns by fingerprint; Discuss in Pi… | tests |
| 5 | Roles and Scenarios screens, the three first scenarios and their roles in the brain layer `review`; the work-word check for brain edits | `make snapshot` |

## Guide

The in-app guide `docs/guides/review.ru.md` (Russian, like the other guides) describes how
review works, from simple tasks to hard ones:

1. What AKit Review does and what it never does (no publishing, no unapproved request).
2. Setting up: the two tokens, the destination in the sending policy, a project profile.
3. One review: New Review… or `akit review`, the scenario, the estimate, the passes.
4. The Review screen: requests, editing, approve and reject with a reason, Send Drafts…,
   then Submit review in GitLab.
5. What goes inline, into the summary, or stays in AKit, and why (the noise rules).
6. Context gaps and questions to the author.
7. Discuss in Pi… and a new version of the findings.
8. Reruns after a push: what happens to drafts and threads.
9. Configuration: the three levels, Roles and Scenarios, Edit…, Duplicate to Project…,
   Reset to Brain, `akit review config show`.
10. Quality: the precision numbers and how rejected findings reach Error Analysis.

Button and tab names are quoted exactly as on screen. Each step that adds or changes a screen
(steps 3, 4, 5) updates the guide in the same commit, with screenshots from the made-up home:
a shot added to `tools/guide-screenshots.sh`, then `make guide-screenshots SHOTS="<name>"`;
never real MRs. Each caption says what the shot shows, since the guide search and Ask AKit read
it. Steps 1 and 2 add the setup and command-line sections. The AKit Terms glossary
(`terms.ru.md`) gets the new terms: context pack, finding, context gap, request, fingerprint,
verifier.

## Later

- A scenario classifier (`detect` rules, the WI type), with a choice shown when it is unsure.
- Parallel role passes for big MRs, split by file groups.
- Sync of outcomes from GitLab (resolved after a change of the anchor, an applied suggestion,
  no reaction until merge).
- More scenarios: hotfix, revert, refactoring, IaC, CI, database migration, API contract.
- A knowledge base with agent proposals in an inbox, a linter and an approval queue; a map of
  interactions for bugs; LikeC4 when the systems grow.
- Triggers: polling the MRs where the user is a reviewer, drafts only, a "reviewed this
  `head_sha`" record.
- The Claude Code adapter.
- Reading `.gitlab/duo/mr-review-instructions.yaml` as team rules, if a repository has it.

## Not goals

- Publishing comments, approving or merging. The user publishes in GitLab.
- Any write to Azure DevOps.
- Vector databases or embeddings for knowledge.
- A webhook server or a daemon.
- A diff viewer in AKit.
- Several users or a team setup.

## Open

- Whether Pi's `tool_result` event can change a tool's output (a second scrub inside Pi).
- The exact Pi provider id `github-copilot` and the model names on the work account.
- Drafts on files over GitLab's diff limits on the user's GitLab version.
