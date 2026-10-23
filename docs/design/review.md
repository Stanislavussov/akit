# AKit Review: AI review of merge requests

Status: 2026-10-15, built on branch `akit-review`; MCP change (R2, R3 revised, below) on branch
`review-mcp`. Grilled with the user on 2026-10-15 from a
research plan (Pi with the `github-copilot` provider, GitLab, Azure DevOps). The decisions
below are agreed. The user's employer allows both parts: Copilot from a third-party harness
(Pi) and AI comments in merge requests. Step 0 (facts on the work Mac) is still open: the code
was built against the public GitLab and Azure DevOps REST and Pi 1.0.4 on a personal Mac, and
`akit review check HOST` is the first fact to collect there. Context for a run (notes, links,
read-only context servers; GitHub issue #1) built 2026-10-22 on branch `review-context`, below.

Revised 2026-10-22 (branch `review-cleanup`, after an audit of the review): posted text names
no tool, only 🤖 (marker default `🤖`, no "AKit is an AI reviewer" line, the "looks fixed"
reply without AKit's name); the hidden line is `<!-- ai-review:v1 … -->` and the old
`akit-review:v1` is still read. The fingerprint drops the title (Findings, below). AC rows
don't count against a role's `max_findings`, so the matrix has a row per criterion. The
Feature scenario gets `bug-hunter` as a required role. Mermaid diagrams of a run under One run.

Added 2026-10-23 (branch `review-branch-wi`): R39, the work item comes only from the source branch
(`COL-317494`); without one the review checks the code alone.

Added 2026-10-23 (branch `review-deferred`): R37, limits only alert and are 4× higher; R38, passes
reach MCP servers with deferred tools through `tool_search`.

Added 2026-10-23 (branch `review-log`): R36, the run's log for analysis and while it runs, model
choices from Pi's list, required fields marked, an empty fetch that says why (section "Decisions
(2026-10-23)").

Added 2026-10-23 (branch `review-czech`): R35, Czech comments only (section "Decisions
(2026-10-23)").

Added 2026-10-23 (branch `review-practices`): decisions R20–R34 from a research note on agentic code
review (section "Decisions (2026-10-23)"), built in four parts with a reviewer round each.

Added 2026-10-22 (branch `review-audit-2`): checks without a model (the quote in the file, a
person's open thread, inline only on changed lines, a secret scan, the size of the change; section
"Checks without a model"); four optional roles, `performance`, `concurrency`, `data-migrations`
and `observability`, with `architecture` optional in Feature (a role per pass costs credits; turn
it on when the change has a design question); the `nitpicks` switch is gone (`severity_threshold`
already keeps `nit` out; set it to `nit` to post them); the verifier runs in a session of its
own with the brief, not as a fork of the passes' session, so the roles' reasoning doesn't sway
it; and Pi steps and Pi flags (section "Pi steps", below).
A run can add the user's pi-subagents agents (`/run reviewer …`), prompt templates and skills
as passes after the roles, and extra Pi flags for the passes; `akit review pi` and New Review…
suggest what the user's Pi has. Checked on a real Pi 1.0.4: an extension command such as
`/run` doesn't finish in `pi -p` (Pi exits before the subagent; the extension's context goes
stale), and the `subagent` tool can run scripts, change agent settings and start agents with
bash and edit outside AKit's checks. So AKit runs a step itself: the agent's prompt and model,
the review's reading tools.

Built: step 1 (2026-10-15): module `AKitReview` with the project profile, the three levels
(`ReviewCatalog`, `ReviewResolver`, `run.json`), Gather from GitLab and Azure DevOps REST into a
scrubbed context pack, the worktree at `head_sha`, `akit review MR-URL`, `akit review config show`,
`akit review token`, `akit review check`. Two additions to the design: the profile's `checkout:`
(the local clone the worktree comes from) and the tracker's `url:` (Azure DevOps Server). The
roles and scenarios of step 5 ship built in (`ReviewBuiltIns`, source `built-in`) and are used
while the brain has no layer `review`.

Built: step 2 (2026-10-15): `ReviewPasses` runs brief → roles → verifier in one Pi session
(`--session-id`, the verifier as `--fork` of it with its own model; since 2026-10-22 the verifier
has a session of its own), `akit-review.ts`
(`ReviewExtension`) with the two tools and the `tool_call` policy, the estimate and the cap, the
send log (purpose `review-<pass>`, the paths read), `akit review passes RUN`. Checked with a fake
Pi in tests and with real Pi 1.0.4 against a fake model server. Decisions made while building:

- **Credits** (R14): AKit's own unit, 1 credit = 1,000 tokens as Pi recorded them (input, cache
  writes, output); a cached read counts one tenth. Recorded numbers only. Step 0 checks how it
  lines up with the Copilot plan.
- **Sending policy**: a new origin `mergeRequest`. Revised 2026-10-16 at the user's request
  ("I only run Pi; Pi already has access to the model"): AKit runs Pi on the merge request as
  the user would, so any Pi destination may get it, on a work Mac too, without an allowed-list
  entry. Other harnesses may not. Masking before sending, the cap and the send log stay.
- **Role text**: every pass gets all of the run's role skills (`--skill`) and the same appended
  system prompt, so the session keeps one prompt cache; each role pass's prompt carries its
  checklist.
- **Verifier**: a session of its own since 2026-10-22 (before: a fork of the passes' session),
  so it doesn't inherit the roles' reasoning; prompted with the brief, the candidates and their
  snippets (`prompts/candidates.md`); one tool, `akit_submit_findings`, takes
  `findings` or `verdicts`.
- **Secret files**: Gather deletes them from AKit's own worktree, because `grep` and `find` read
  folders and the policy sees only the folder.
- **Anchors**: when a finding's evidence isn't within ±3 lines of its line but is on exactly one
  line of the file, AKit moves the anchor there.
- Pi reads stdin when it isn't a terminal: a pass's stdin is `/dev/null`.

Built: step 3 (2026-10-15): `ReviewPlanner` (the noise rules, positions from the diff hunks, the
scrubber, the summary draft, the rerun table), `ReviewWorkflow` (decisions with reasons, Move
Inline, Add Missed…, Send Drafts with a fresh read of the drafts and threads first),
`ReviewQuality` (labels and precision read from each run's `requests.json`), the Review screen
(sidebar group Work: the runs, the requests with the code around each anchor, Edit, Approve,
Reject with a reason, Only in AKit with Move Inline, the gaps, Send Drafts…, New Review…, Review
Settings… with the tokens and the profiles), `akit review show|approve|reject|inline|missed|post|quality`.
Decisions made while building:

- The hidden meta line also carries `th=`, a hash of the text AKit proposed: a rerun that would
  propose the same text leaves a draft the user edited alone.
- A suggestion block whose code the scrubber would change is left out of the draft.
- Labels are not a separate log: they are read from the runs' decisions. Error Analysis notes
  (origin `review`) are not written yet: notes there belong to agent sessions, and review's
  labels fit them only through the verifier's session; open.
- Gather and the passes run inside the app (one review at a time, Stop ends the pass); a run
  survives a quit as a folder, and Run Passes (or `akit review passes RUN`) runs it again.

Built: step 4 (2026-10-15): reruns by fingerprint end to end (a new run of the same merge
request sees the drafts the last one sent: same text → nothing, gone → delete), Discuss in Pi…
(`ReviewDiscuss`: `<run>/discuss.command` with `pi --fork` of the verifier's session, opened in
Orca, herdr or Terminal by `Launcher.openInteractive`; Make New Version turns what Pi submitted
into `findings.json` version N+1, keeps `findings-v<N>.json` and plans the requests again),
`akit review discuss|apply`. In a discussion, `verdicts` change findings by id and `findings`
add new ones (counted as confirmed: the developer was there); the discussion's tokens go into
`passes.json` and the send log when its version is made.

Built: step 5 (2026-10-15): Review → Roles, Scenarios (with the defaults) and Quality; Save… with a
diff, Duplicate to Project…, Reset to Brain, Add to Brain (the built-ins into `layers/review`,
committed), the work-word warning for brain saves on a work Mac; `layers/review` is reserved
(the brain doesn't read it as a project layer). The guide `review.ru.md`, the Work group in the
screens guide, the Review terms in the glossary.

MCP change (2026-10-15, the user's decision after trying the first build): AKit keeps no GitLab or
Azure DevOps token and has no REST client. Pi connects to GitLab, Azure DevOps and the other
trackers with the MCP servers the user configured in Pi; AKit is the configuration that fits each
kind of merge request (roles, scenario checks, rules, models and thinking, which servers and tools)
and the guard around every call. In the user's words: AKit passes Pi what to call, with which
roles, tools and skills, what to check, in which context, with which guardrails and limits.
Built the same day:

- **Fetch pass** (Gather, R3): Pi (`-ne -e builtin:mcp -e builtin:codemode`, the user's
  `mcp.json`) reads the MR, versions, diffs, threads, the user's drafts, the signed-in user and
  the work items in codemode scripts. The extension saves every MCP answer in `<run>/mcp/calls/`
  (AKit masks secrets in it after the pass); AKit sorts them by shape (`ReviewMCPData`: GitLab's and Azure DevOps's
  JSON) and trusts the servers' answers, never the model's account. `akit_submit_context` takes
  what a server answers in prose. With a `checkout:` AKit makes the worktree and the diff with
  git (`base..head`), so no model carries the diff. Its own session; its credits count toward
  the cap; it goes through the sending policy like every pass.
- **MCP rules** (`ReviewMCPPolicy`, the same in `akit-review.ts`): a profile's `mcp:` names the
  servers (none = all), extra read patterns, the write patterns (default `*draft_note*`) and
  `in_passes` (the rules were tightened by the security review below).
  `--tools mcp__<server>__*` keeps other servers' tools out too. Every call, direct or from a
  codemode script, passes the extension's `tool_call` (verified with Pi 1.0.4).
- **Passes** read through MCP too when `in_passes` (default): codemode with reading tools only.
- **Send pass** (Send Drafts…, R4–R5): AKit writes the approved requests to
  `<run>/send/approved.json`; Pi creates, updates and deletes draft notes with the GitLab
  server's draft tools, reading the requests from `akit_approved_requests` in a script. The
  extension lets a write through only when it carries an unsent approved request word for word:
  the same action (create, update, delete by the tool's verb), the body, the draft id, the
  thread, the file and the line; each request once. It logs GitLab's answer per request in
  `<run>/send/log.jsonl`; AKit marks requests sent from that log, not from the model. Drafts to
  change and threads to reply in are checked against what the run's fetch pass read (a fresh
  read is a new run: Refresh from GitLab is gone). The send pass is never stopped by the cap.
- Pass environments keep the user's variables, so Pi's MCP servers find the `${VAR}` their
  `mcp.json` names; the model has no shell or environment tool.
- `akit review check [--project P]` and Review Settings… → **Check Servers** run
  `pi mcp list --json` and sort each tool (read, write drafts, blocked); never a server's
  command line, environment or headers. `akit review token` and the token blocks are gone.
- Checked end to end with real Pi 1.0.4, a fake model and a fake GitLab MCP server: fetch →
  passes → approve → send; in the send pass an altered text, another line, another draft, a
  second send, a published note and bulk publish were blocked, and only the three approved
  calls reached the server.

Local review (2026-10-16, the user's request: review a git workspace of herdr or Orca by its
path, showing the commit range or saying that only the diff is there):

- `ReviewLocal`: `inspect(path, base?)` reads the workspace's top folder, branch, HEAD, the base
  (`origin/HEAD`, `origin/main`, `origin/master`, `main`, `master`, never the branch itself; or
  `--base REF`, checked as a ref name), the commits `merge-base..HEAD` and the
  `git status --porcelain` lines. It says in one sentence what is there: N commits since the base
  (with the range), only the uncommitted changes, or nothing to review.
- Modes: `all` (default when both exist), `commits`, `uncommitted`. Uncommitted changes
  (untracked too, `.gitignore` honoured) become a snapshot commit on top of HEAD, made with a
  temporary index (`GIT_INDEX_FILE` + `add -A` + `write-tree` + `commit-tree`): the workspace's
  index, files and branches never change; the object stays dangling in the repository.
- The run: `ReviewRunSpec.local` (`ReviewLocalTarget`: path, branch, base ref, mode, base, head,
  commits, uncommitted files), `MergeRequestRef.local(repo)` (label `repo (local)`, run id
  `…-local`). Gather skips the fetch pass, makes the worktree from the workspace (Pi reads that
  copy, never the workspace) and the diff with git; `merge-request.md` holds the branch, the range
  and the commits. Files that usually hold secrets are left out of the diff in every review, with
  a gap. Work item numbers in the branch or commits are a gap ("A local review doesn't read the
  tracker"). The project profile is the one whose GitLab project is the `origin` remote or whose
  `checkout:` is this repository.
- No GitLab: no Send Drafts… (the button is hidden, `send` refuses, `post` says so); verdicts
  still count for quality. Deleting a run removes its worktree from the workspace it came from.
- `akit review local [PATH] [--base REF] [--what all|commits|uncommitted] [--show]` (PATH: the
  current folder, so `akit review local .` in an Orca or herdr terminal); New Review… →
  **Local Workspace** with Choose…, Base, What to review, the commits and the uncommitted files.

Context and extra servers (2026-10-22, GitHub issue #1 "Code review improvement - context for
review"; the user chose the three parts below):

- **Notes** (New Review… → **Context for this review**, `--note TEXT`, `--note-file PATH`): the
  user's own text for one run: what the change is for, what to focus on, decisions made. Kept in
  `run.json` (`notes`, secrets masked, at most 20,000 characters), written scrubbed to
  `context/notes.md`, and quoted in the system prompt of every pass (so the verifier and
  Discuss in Pi… have it too). It is trusted as instructions for focus only: the prompt says it
  doesn't change the rules, and the model still only returns findings. The brief starts from it
  and adds a "Focus" line.
- **Links** (New Review… → **Links**, one per line; `--link URL`, repeatable): https only, with a
  host, no user name or password, no secret-like query parameter (`sig`, `token`, `access_token`,
  `key`, `apikey`, `password`, `secret`, `code`, `signature`), at most 20 (`ReviewContext.links`).
  The fetch pass is told to
  read each link with a reading tool of the server that serves it, one link at a time, naming it
  first with `akit_reading_link` (a fetch-pass tool; it accepts only the run's links). The
  extension tags every MCP answer saved after it with that link (`ReviewMCPCall.link`) and its
  server (`ReviewMCPCall.server`, the longest-name split), and logs every call it blocks in
  `mcp/blocked.jsonl`. **`akit_reading_link` only labels the calls that follow it: it doesn't
  gate which pages or tools the model reads.** What may be read is decided by the MCP policy
  alone (the run's servers, the read allowlist). AKit files an answer under a link when the
  tag or the call's arguments name it, and writes `context/links.md`: the servers' answers per
  link (masked, 40k characters per link, 150k in all) or "Not read: <why>"; each unread link is a
  gap ("No MCP call of the fetch pass read it", "AKit blocked <tool>: <reason>", "<tool> failed")
  and is listed in `run.json` (`linksUnread`). The merge request's data (`ReviewMCPData`) comes
  only from the run's own servers (`ReviewMCPAccess.answeredByBase`), tagged or not: a GitLab
  thread read after a link was named still counts, and an answer of the merge request's shape
  stays out of the link's text; a context server's answer is never the merge request's data.
  Base-server calls stay tagged on purpose: Azure DevOps wiki pages and work items are read by
  the tracker's own (base) server. A local review runs a
  fetch pass only when it has links, with a links-only prompt (no GitLab reading, no
  `akit_submit_context`); if that pass fails, the links become one gap and the review goes on.
  Checked in tests with a fake Azure DevOps wiki answer (`wiki_get_page_content` reads by its
  second word), a Figma answer named by its arguments, a blocked Confluence write and a link no
  server read.
- **Context servers** (`ReviewMCPAccess.extraServers`): the profile's `mcp: extra_servers:` plus
  the run's choice (New Review… → **Extra servers**, the servers of `pi mcp list` that aren't the
  run's own, ticked per run; `--extra-server NAME`). They are added on top of `servers:` (or the
  default GitLab and tracker names), never replace them. A context server is there in the fetch
  pass, the brief, role and verifier passes and Discuss in Pi…, and only reads: its tools pass the
  same read allowlist (reading verb, `readOnlyHint`, `read:` patterns, the forbidden words), and a
  writing verb is blocked even when it matches `write:` (`ReviewMCPPolicy.kind` and
  `akit-review.ts` v6, the same rule). The send pass never gets one: its `--tools` has only the
  base patterns and its `AKIT_REVIEW_MCP` has no `extraServers`. A server the defaults or
  `servers:` already allow keeps its role (writes in Send Drafts included); `config show` and
  `check` warn about such an `extra_servers` entry. `--tools` gets `mcp__<server>__*` for each
  context server (`toolPatterns`) in the other passes. `run.json` records
  `mcpServers`: each server (or default name pattern) with its source (`built-in`, `project`,
  `run`) and whether it is read only. Browser, file-system and fetch-type servers (names with the
  words `browser`, `chrome`, `file`, `fs`, `http`, … or the parts `fetch`, `web`, `crawl`,
  `browser`, `puppeteer`, `playwright`, `firecrawl`, `tavily`, `exa`, `jina`, `brightdata`,
  `filesystem` anywhere) are never ticked by default;
  ticking one shows a warning (`ReviewMCPAccess.warning`), `config show` marks it with "!".
  Review Settings… → **Check Servers** with a profile in **Rules of** shows a **Context server**
  checkbox for each other server; **Save Extra Servers…** changes only the `extra_servers` line of
  the profile's `mcp:` (block, one-line flow, or a new block; a trailing comment and CRLF line
  ends stay; the parsed profile must stay the same except `extra_servers`), shows the diff, then writes
  (`ReviewConfigEditor.extraServers`, kind `profile`). Not done: a context server per link
  (the model picks the server by the link's site); a fetch pass for a local review with context
  servers but no links (the passes read through them anyway when `in_passes`).

Security review of the MCP change (2026-10-15), fixed the same day:

- Servers: without `servers:` a run uses only Pi servers named like `gitlab`, `azure`,
  `devops` or `ado` (and `--tools` keeps only theirs), never a browser, file or fetch server.
- Reading is an allowlist: a reading verb as the first word or the second after a namespace
  (`get_merge_request`, `wit_get_work_item`), a server's read-only hint, `mr_discussions`, or
  the profile's `read:`; `publish`, `submit`, `approve`, `vote`, `resolve`, `rebase` anywhere in
  a name block it in every pass.
- Writes are checked by field, not by value: only known arguments (project, merge request
  number, body, draft, thread, position with its known fields); the project and number must be
  the run's (`mr` in each approved request), every other argument (`resolve_discussion`, a
  second text field) blocks the call; the verb comes from the tool's own name.
- `akit_submit_context` is the model's account: it may give the merge request and diffs for the
  context, never the user, the threads or the drafts that decide what AKit may change.
- Commit ids from MCP answers must be hex; the target branch must be a plain branch name and is
  fetched as `refs/heads/<name>` without a destination.
- A server is the longest allowed name before `__`, so `gitlab__x` is not `gitlab`.
- Checked again with real Pi: `resolve_discussion`, a reply into another thread, a second text
  field, another MR or project, an extra position field, a decoy delete argument and another
  server were blocked, each with its reason; the exact calls went through.

Review round (2026-10-15, code review of the branch), fixed:

- The path policy refuses paths that start with `~`, `@` or `file:` (Pi expands them itself),
  `find` patterns that leave the folder, and more secret files (`.npmrc`, `.netrc`,
  `.git-credentials`, `id_*`, `*.p12`, …). A pass reads only the worktree and `context/`,
  `roles/`, `prompts/` of the run: never `gitlab/` or `tracker/` (raw, unscrubbed).
- AKit's own reads of worktree files (snippets, anchors, the screen) don't follow a symlink
  out of the worktree and are masked.
- What a run keeps from MCP servers is masked on disk (`ReviewMask`, 2026-10-16): the saved
  answers (`mcp/calls/`) and the send log after each pass and when AKit opens a run (Discuss
  in Pi… saves answers too), the pass streams (`passes/*.jsonl`) line by line as Pi writes
  them. Only string values change (`SecretFilter.masked`, the Scrubber's token shapes and
  passwords, plus whole private-key blocks), JSON stays JSON and a text keeps its lines, so
  diffs keep their line numbers; files without a secret stay byte for byte. Pi's own session
  files in `sessions/` stay as Pi wrote them.
- Tokens: one Keychain account per exact `https://host[:port]` (Azure DevOps: per collection
  address), https only, no redirects. They are now written and read in-process
  (`ReviewKeychain`), not through `/usr/bin/security`, so another program gets a Keychain
  prompt instead of the token. Gather commands (they run the merge request's code) and passes
  get a minimal environment without GitLab or Azure DevOps variables.
- A thread is AKit's only when the token's user started it with AKit's line; "looks fixed" is
  proposed once per thread and only when no finding of the run has the fingerprint.
- Model text can't open or close an HTML comment, the meta line is read from the end, and a
  discussion's finding takes a role of the run only.
- Send Drafts sends only the requests the sheet showed, with the text it showed; after a send
  the snapshot learns GitLab's drafts, and sent requests stay on the list after a replan.
- Diff positions after hunks that only add or only remove lines.

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
| R2 | Who writes to GitLab? | (revised 2026-10-15) Pi, through the user's GitLab MCP server, in a send pass that only carries out approved requests: the extension blocks every write that isn't an approved request word for word. AKit keeps no token. (Was: only AKit, through REST, with a Keychain token) |
| R3 | How does the agent read GitLab and Azure DevOps? | (revised 2026-10-15) Through the MCP servers configured in Pi, reading tools only: the fetch pass reads the MR and work items, and AKit builds the context pack from the servers' saved answers; the passes may read more (`in_passes`). (Was: it doesn't; AKit fetched everything by REST) |
| R4 | When does AKit write? | Only after the user approves each request on the Review screen (or `akit review post RUN --yes`). Not one request goes out unapproved, deletes and updates included |
| R5 | What does AKit write? | Draft notes. The user publishes them in GitLab with **Submit review**, together with their own comments. AKit never calls `bulk_publish` or publishes a draft |
| R6 | Who orchestrates the passes? | AKit (Swift). Brief → roles → verifier, one after another **in one Pi session**, so later passes see the earlier ones and findings stay linked. Parallel fan-out only later, for big MRs. Revised 2026-10-22: the verifier has a session of its own with the brief and every role's limits in its prompt, so the roles' reasoning doesn't sway it |
| R7 | Interactive work | After a run, **Discuss in Pi…** opens an interactive Pi in a terminal (herdr, Orca) as `pi --fork <verifier session>`: the brief, the candidates and the verifier's checks (since 2026-10-22 not the roles' reasoning), the run's sessions unchanged |
| R8 | First scenarios | Feature, Bugfix, Dependency upgrade. The user picks the scenario; the classifier comes later |
| R9 | What is a role? | One `SKILL.md` in the brain layer `review`, with review fields in its frontmatter. Scenarios are YAML in the same layer. These skills are not installed into the harnesses' skill folders; AKit passes them to review passes only |
| R10 | How configurable? | Everything, on three levels: brain → project profile → one run. The resolved `ReviewRunSpec` is saved in the run folder |
| R11 | Knowledge base | v1 reads markdown folders the project profile lists. A full KB (agent proposals in an inbox, linter) is a separate design, after the context gaps show what is missing |
| R12 | Reruns | By fingerprint, without the role in it (rules below). Every change to an earlier draft is a request to approve. Threads resolved by a person are never raised again. AKit never touches other people's threads |
| R13 | Noise | ≤ 7 inline drafts, severity ≥ medium, confidence ≥ 0.8; questions, gaps and the AC matrix go to one summary draft; the rest stays in AKit |
| R14 | Models | One model for the brief and the roles (one prompt cache), a strong model for the verifier, which gets only the candidates and their snippets. A cap per run, 150 credits by default (600 since R37, and it only alerts) |
| R15 | Agent tools | `read`, `grep`, `find`, `ls` and the `akit_*` tools. No `bash`, no `write`. Paths limited to the worktree and the run folder; secret patterns blocked. Git history and test output come from Gather |
| R16 | Quality | v1: the user's verdict on each finding at approval, with a reason tag, goes to Error Analysis. Sync of outcomes from GitLab comes later |
| R17 | Brain edits from the work Mac | Allowed for the generic review roles and scenarios, after a diff with warnings for work words (hosts, project paths, e-mails from the work profiles) |
| R18 | Order | Before wave 1 of `README.md` (layer evals on JS/TS) |
| R19 | Docs | An in-app guide `review.ru.md` describes how review works; each screen step updates it in the same commit (see Guide) |

Rejected on the way: the agent writing through GitLab MCP *unguarded* (no protection against
injection; now it writes only approved requests word for word, checked by the extension); AKit's
own REST clients and tokens (first build; the user wants Pi's MCP servers as the one way to the
work systems); orchestration in a Pi
extension (Pi only, no tests, the budget and send log written again in TypeScript); three
model tiers (switching models in one session loses the prompt cache); the role in the
fingerprint (one problem from two roles would become two comments).

## Decisions (2026-10-23): practices from Anthropic, OpenAI and Uber

Grilled with the user on 2026-10-23 from a research note on agentic code review in 2025–2026
(Anthropic's `code-review` plugin and Code Review, OpenAI's Codex review, Uber uReview, the
CodeRabbit field study). Built on branch `review-practices` in four parts: (a) R20–R26, R29;
(b) R27, R30, R33, R34; (c) R28, R31; (d) R32.

| # | Question | Decision |
|---|---|---|
| R20 | Where do review rules come from? | Built into AKit and generic for any project. A review doesn't read the repository's `AGENTS.md`, `CLAUDE.md` or `REVIEW.md` (Pi keeps `--no-context-files`); the project profile adds its own. Anthropic's false-positive list joins the built-in "never comment on" rules: issues from before the MR, rules silenced with `eslint-disable` / `@ts-ignore` / `swiftlint:disable`, and intended changes of behaviour |
| R21 | Language rules | One built-in rule set, TS/JS with React, on when the diff has `.ts`, `.tsx`, `.js`, `.jsx`, `.mjs` or `.cjs` files. Each rule has a level and a safe path. No other languages |
| R22 | MCP servers in the passes | The roles get every MCP server of the user's Pi, reading tools only (the extension's write guard is unchanged). The built-in rules say which server is for what: documentation servers (context7) when the behaviour of a framework, a library or a tool is in doubt, GitLab for merge requests and their history, Azure DevOps for work items. `access.in_passes` can still narrow the list. A server reached only this way (an *open* server; `mcp: all_servers`, default true, a toggle in Review Settings…) is stricter than the run's own: a tool runs only when its server marks it read-only, when it is a known exact read (context7's `resolve-library-id`, `query-docs`), or when its name starts with a reading verb and no word anywhere in it acts (`execute`, `run`, `query`, `create`, `send`, …); its arguments are at most 300 characters each and have no line break, so code of the change can't leave through a search box; secret stores, databases and cloud consoles count as risky (named only). Found by the review of part (a): the reading-verb rule alone let `execute_query` and `get_or_create_*` through |
| R23 | Issues from before the MR | A finding gets `preExisting: true` when the problem is already there at the base commit. It never goes to GitLab, not even to the summary; the Review screen lists it under "Before this MR". Move Inline still works |
| R24 | Confidence | Anthropic's rubric, on the 0–1 scale, in the role and verifier prompts: it says whether the problem is real, also for an issue from before the MR (that one gets `preExisting`, not a low score): 0 a false positive, 0.25 couldn't verify, 0.5 real but minor, 0.75 verified and will happen in practice, 1 certain. `confirmed` needs ≥ 0.75; the posting threshold stays 0.8 |
| R25 | The verifier's model | `models.verifier` is required: without it New Review… keeps Start Review off and `akit review` stops with a hint (`--verifier-model`) before a run folder exists. No automatic choice. Runs made before (spec version 1) keep their old verifier |
| R26 | How many drafts | `max_inline: 5` and a new `max_inline_medium: 3`; critical and high first. The rest stay one line each in the summary |
| R27 | Before the passes | Gather reads the draft status, the latest pipeline and earlier AKit runs on the same head SHA. If any of these holds, one question before money is spent, like the size question. Triviality isn't judged |
| R28 | Reruns | With an earlier run of the MR, the roles look only at the lines changed between the last reviewed head and the new one, and earlier findings are checked for "fixed". The 4th run asks whether to talk about the approach instead. **Full review** reads the whole MR again. After the review of part (c): a carried finding keeps every fingerprint it ever had (drafts and threads of any earlier run match); a role that finds an earlier problem again takes its fingerprints over; earlier findings not carried (questions, merged, rejected) keep their threads from "Looks fixed" while their lines didn't change (`rerun-kept.json`); a deleted or renamed file is a whole-file change; only a rejection noted "fixed" counts as fixed; Move Inline carries over; Discuss findings are not filtered; the kept fingerprints pass from run to run; a run whose newest earlier run is on the same head is a full review (the user asked for this commit again); without the earlier findings the run reviews the whole MR, with a gap |
| R29 | Rules off the changed lines | Unchanged: findings off the changed lines go to the summary; issues from before the MR follow R23 |
| R30 | History | Gather writes `history.md`: `git log` and `git blame` of the changed lines (local, no network) and people's threads in the last merged MRs that touched the same files (GitLab MCP). A new optional role `history`: an old bug coming back, or what people already asked for in these files. After the review of part (b): a past merge request's threads count only when the fetch pass read it as merged in this project; an answer about `!N` of another project, or a past merge request's diff, never becomes this merge request's data; draft and pipeline come only from calls about this merge request, and the pipeline concern only for the head commit; blame runs once per file with `--no-textconv` and a 90 s budget, and notes are quoted |
| R31 | Outcomes | Each rerun and a **Sync Outcomes** button read the threads with AKit's hidden line: anchor changed → `fixed`; resolved without a change → `dismissed`; the author's reply is shown as text; merged with no reaction → `ignored`. The Review screen shows the share accepted by role and model. After review: a run's own findings say "still there" only for its own head (a sync after a push sees the fix), AKit's "Looks fixed" reply counts as fixed, outcomes keep the time of their data (an older re-plan never overwrites a newer sync), a sync without threads changes nothing, and the sync pass reads GitLab only with a small limit of its own |
| R32 | Eval set | **Add to Eval Set** on a run or a finding records the MR, its head SHA and the expected findings (or "clean"). Running the set through Lab is a later step. Built: `~/.akit/local/review/eval-set.json` (`ReviewEvalSet`), one case per merge request and head; the run menu Add to Eval Set (approved findings, or clean), Expect in Eval Set on a held-back finding, the list with Remove on the Quality page, `akit review eval [list|add|remove]` |
| R33 | Modes | Chosen by the kind of run, no new choice: a colleague's MR uses the posting rules above; the user's own MR or a local review also posts `low` and has a higher limit. A built-in scenario `security` next to Feature and Bugfix |
| R34 | AI-written merge requests | The brief writes a personal risk map for the user, never posted: risk areas, whether the MR shows proof that it was tested, signs of slop. Slop in the code (a duplicated helper, a test of a mock, a swallowed error) is an ordinary finding of `tests` or `bug-hunter` |
| R35 | The comments' language | Asked by the user later on 2026-10-23: only Czech goes to GitLab. `posting: language` (default `cs`) tells the passes, the verifier and Discuss to write titles, reasons, notes and gaps in it; AKit's own words in a draft (the header, the summary, "Looks fixed") are Czech; Gather's own gaps stay out of the summary (they are English and about this Mac). Send checks each draft's text with Apple's language recognizer (code, links, markup and AKit's header line left out; Slovak counts only with letters only Czech has) and refuses one that isn't Czech; the Review screen warns on its card. Translate only shows a translation: Send always takes the original |
| R36 | Seeing what a run does | Asked by the user on 2026-10-23. While a run goes, **Details** under the status bar shows a live log: each pass's start and end (credits, time, tokens) and, indented, what the pass does now from Pi's events (files read, MCP tools by name, the model's answers with tokens, findings submitted, failures); never MCP arguments or answers. In a terminal the CLI prints the same lines to stderr at once; piped, only the steps. After it, **Log…** (`ReviewRunLog`, `akit review log RUN [--json]`) shows each pass's model, thinking, time, tokens, credits, files, MCP calls and blocked calls, its Pi session file, and what each role's findings became; **Copy for Analysis** gives it as Markdown without secrets, MCP arguments (work data) or answers. Model fields of New Review… are lists of `pi --list-models` with **Other…** to type one; Add Missed… picks a file of the change or Other…; required fields have a red asterisk. A fetch pass that read no merge request says which tools Pi called, what AKit blocked, which servers answered that the run doesn't use, and which server names the run looks for |
| R37 | Limits | Asked by the user on 2026-10-23: "avoid limit for code review just alert me when overlap, and increase limits 4x". `cap_credits_per_run` 600 and `max_changed_lines` 6000 by default; over them the review never stops: an estimate over the cap, a change over the line limit, and the credits passing the cap (once) each make a yellow alert in the Review screen and a progress line ("Over a limit: …"). `--over-cap` is gone. Still asked: Review it now? (draft, red pipeline, same commit, 4th round); still enforced: the monthly dollar limit of Settings → Lab and Sync Outcomes' own small limit. A brain `review.yaml` that holds the old numbers keeps them |
| R38 | Servers with deferred tools | Found on the work Mac on 2026-10-23: GitLab's own MCP server (`/api/v4/mcp`, 50 tools) runs in Pi with `deferred` exposure, so its tools are in no tool list until `tool_search` loads them, and the fetch pass made no MCP call. Every MCP pass and Discuss now load `builtin:tool-search` and allow `tool_search` (the extension checks each loaded tool as before); the fetch prompt says how to find tools that are in no list. That server has no draft-note tools: Send can't write drafts through it yet |
| R39 | The work item from the branch only | Found on the work Mac on 2026-10-23: the team names the work item in the branch (`feature/COL-317494-…`); the description names other, older items, and the review read those and reported their missing acceptance criteria as its only output. Gather and the fetch pass now take the number only from the source branch (`wi_ref_regex` default `(?i)(?:COL-|AB#|WI-)(\\d+)`) and drop items the fetch pass read anyway, unless a named item's parent or related item. With no number the run is code-only: no gap about it, no `requirements` role, and the prompts ask for contracts and regressions; the passes' gaps about a work item are dropped. Review Again… (next to Log… and in a run's menu) opens New Review… with the run's change, scenario, notes, links and models, and Full review on |

Not taken: CI layers (Danger, reviewdog, SAST, a `.gitlab-ci.yml` template) are the team's
repository set-up, and a team set-up is not a goal; the team agreement on 🤖 comments is the
user's. Automatic choice of a verifier model of another family (R25: the user wants it explicit).

## One run

```
akit review <mr-url> [--wi N] [--scenario S]        or  Review → New Review…
   │
   ├─ 1 Gather: the fetch pass (Pi + its MCP servers, reading tools only)
   │     GitLab: MR, diff_refs, versions, diffs, discussions (resolved too, with
   │     position), the user's drafts, the signed-in user
   │     Tracker: the work items (from --wi, the title, the description, the branch),
   │     parents and related items one level deep, comments
   │     → <run>/mcp/calls/ (every answer, secrets masked); AKit sorts them by shape
   │     AKit: worktree at head_sha and the diff by git (with a checkout)
   │     git log / blame of the changed files; profile commands (tests, linter) if set
   │     knowledge folders from the profile
   │     → <run>/context/  (files the agent reads)
   │
   ├─ 2 Scenario: the user's choice (default from the profile); roles from the scenario
   │     and the three config levels → <run>/run.json (ReviewRunSpec)
   │
   ├─ 3 Estimate: credits from the context size; over the cap → ask
   │
   ├─ 4 Passes, in order (brief, roles and Pi steps in one Pi session):
   │     brief      intent, touched components, what people already raised, AC, first gaps
   │     role × N   candidates (≤ max_findings each) through akit_submit_findings
   │     verifier   strong model, a fresh session with the brief, the candidates + snippets:
   │                confirms or rejects each, links and merges duplicates, turns a finding
   │                without enough context into a question or a gap, checks human threads
   │     → <run>/findings.json, <run>/gaps.json, sessions in <run>/sessions/
   │
   ├─ 5 Plan: AKit turns findings into requests (create / update / delete draft, summary)
   │     by the noise rules and the rerun rules
   │
   ├─ 6 Review screen: the user edits, approves or rejects each request (with a reason)
   │
   └─ 7 Send Drafts… → the send pass: Pi writes the approved requests word for word
         with the GitLab MCP server's draft tools → the user's Submit review in GitLab
```

The run folder is `~/.akit/local/review/runs/<run-id>/`. Nothing of it leaves the Mac.

The same run as a diagram, with where each finding ends up:

```mermaid
flowchart TD
    A["akit review MR-URL<br/>or New Review…"] --> F["fetch pass<br/>Pi + MCP, read-only tools"]
    F --> C["context pack<br/>diff, threads, work items, notes, links"]
    C --> S{"scenario<br/>feature · bugfix · dependency-upgrade"}
    S --> E{"estimate<br/>over the credit cap?"}
    E -- "yes" --> Q["ask the user"]
    E -- "no" --> B
    Q --> B
    subgraph P ["one Pi session"]
        B["brief"] --> R1["role 1"] --> R2["role 2"] --> RN["role N"]
        RN --> ST["Pi steps<br/>subagent · template · skill"]
    end
    ST --> K["candidates<br/>role limit (AC rows exempt), min severity,<br/>anchor by evidence, fingerprint, fold duplicates"]
    K --> V["verifier<br/>own session, strong model,<br/>brief + candidates"]
    V --> PL["plan: noise rules + rerun rules"]
    PL --> UI["Review screen<br/>edit · approve · reject"]
    UI --> SD["send pass<br/>approved drafts only, word for word"]
    SD --> GL["GitLab drafts<br/>the user submits the review"]
```

```mermaid
flowchart LR
    X["finding"] --> AC{"AC row?"}
    AC -- "yes" --> M["summary: matrix"]
    AC -- "no" --> RJ{"verifier: rejected or merged?"}
    RJ -- "yes" --> O["only in AKit"]
    RJ -- "no" --> RS{"thread resolved<br/>by a person?"}
    RS -- "yes" --> D["summary: already dismissed"]
    RS -- "no" --> QU{"question?"}
    QU -- "yes" --> QS["summary: questions"]
    QU -- "no" --> TH{"confirmed, ≥ severity,<br/>≥ confidence?"}
    TH -- "no" --> O
    TH -- "yes" --> EV{"quote in the file,<br/>no person's open thread<br/>on these lines?"}
    EV -- "no" --> O
    EV -- "yes" --> IG{"path not ignored?"}
    IG -- "no" --> O
    IG -- "yes" --> POS{"GitLab can hold a comment there,<br/>on a line the change touches?"}
    POS -- "no" --> MF["summary: more findings"]
    POS -- "yes" --> CAP{"within max_inline<br/>(strongest first)?"}
    CAP -- "yes" --> IN["inline draft 🤖"]
    CAP -- "no" --> MF
```

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
| Severity, confidence, inline cap | ✓ | ✓ | ✓ |
| Credit cap per run | ✓ | ✓ | ✓ |
| Constraints, path instructions, knowledge folders, Gather commands | — | ✓ | — |
| GitLab host and project, Azure DevOps org and project, WI pattern | — | ✓ | — |
| Pi MCP servers, read and write tool patterns, MCP in passes (`mcp:`) | — | ✓ | — |
| Context servers, read only (`mcp: extra_servers`, Extra servers) | — | ✓ | ✓ (added) |
| Notes and links (Context for this review, Links) | — | — | ✓ |

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

First roles: `domain`, `requirements`, `tests`, `bug-hunter`, `upgrade-risk`, `security`; added
2026-10-18 at the user's request ("critical, on architecture and contracts first, not on syntax or
how the MR is written"): `contracts` (each changed contract and its consumers, found with grep)
and `architecture` (boundaries, dependency direction, duplicated concepts, fit; doubts go as
questions). The system text of every pass sets the focus order (contracts → architecture →
behaviour), a never-comment list (formatting, syntax, naming taste, comment wording, the MR's
title, description and commits, advice without a consequence, praise) and "every finding
states its consequence"; the brief lists the contracts touched; the verifier rejects the
never-comment list (prompts v3).
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
| Feature | contracts, domain, bug-hunter, requirements / architecture, tests, security, performance, concurrency, data-migrations, observability | consumers of changed contracts, boundaries, invariants, business rules, edge cases and errors, AC covered by code and tests | WI with AC |
| Bugfix | bug-hunter, contracts, requirements, tests / architecture, security, concurrency, performance, observability | cause fixed, contract kept, regression test, nearby paths | repro steps, comments |
| Dependency upgrade | upgrade-risk, tests / contracts, security, performance | breaking changes, transitive upgrades, deprecated APIs, licenses | changelog or migration guide (often a gap) |

### Project profile (`~/.akit/local/review/projects/<slug>.yaml`)

```yaml
project: orders-service
gitlab: { host: https://gitlab.corp.example, project_path: team/orders-service }
tracker: { kind: azure-devops, org: corp, project: Orders, wi_ref_regex: "(?i)(?:COL-|AB#|WI-)(\\d+)" }
default_scenario: feature
knowledge: [~/.akit/local/knowledge/orders]
gather:
  - { name: tests, run: "dotnet test --no-build", timeout_s: 600 }
constraints:
  - "Public DTOs in contracts/ change only in backward-compatible ways"
path_instructions:
  - { paths: ["src/Domain/**"], instructions: "Aggregate invariants; no dependency on Infrastructure" }
  - { paths: ["**/*.generated.cs"], ignore: true }
mcp: { servers: [gitlab, azure-devops], write: ["*draft_note*"], in_passes: true }
roles: { off: [security], add: [orders-integration] }     # orders-integration: a project role
review: { max_inline: 5 }                                  # overrides review.yaml
```

### Defaults (`layers/review/review.yaml`)

```yaml
models: { passes: <from pi --list-models>, verifier: <required: a strong model> }
posting:
  marker: "🤖"
  severity_threshold: medium
  confidence_threshold: 0.8
  max_inline: 5
  max_inline_medium: 3
  language: cs        # Send lets only Czech go to GitLab (R35)
cost: { cap_credits_per_run: 600, max_changed_lines: 6000 }   # R37: over them the review alerts and goes on
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
   --no-skills --no-context-files --no-prompt-templates --no-extensions --offline
   -e builtin:mcp -e builtin:codemode            (or --no-mcp when in_passes is false)
   --skill <role skill> …  --append-system-prompt <run>/prompts/<pass>.md
   -e <akit-review.ts>
   --tools read,grep,find,ls,akit_submit_findings,akit_report_context_gap,codemode[,mcp__<server>__*]
   "<pass prompt>"
```

The fetch pass and the send pass use the same line without the skills and the system prompt,
with `--tools akit_submit_context,akit_report_context_gap,codemode…` or
`--tools akit_approved_requests,codemode…`, and `AKIT_REVIEW_MODE=fetch|send`.

```
```

The working folder is the worktree at `head_sha`. The prompt names the context pack files.

The extension `akit-review.ts` is thin:

| Part | What it does |
|---|---|
| `akit_submit_findings` | Validates the findings against the schema and writes `<run>/passes/<pass>.json` |
| `akit_report_context_gap` | Writes a gap: system, what is needed, why, how to get it, the effect on confidence |
| `tool_call` policy | Allows paths only inside the worktree and the run folder; blocks `**/.env*`, `**/secrets/**`, `*.pem`, `*.key`, `auth.json`, `settings.local.json`. MCP calls: the run's servers, reading tools; writes only in the send pass and only an approved request word for word; never publish, approve, merge, resolve |
| `tool_result` | Saves every MCP answer in `<run>/mcp/calls/`; in the send pass logs each write's answer in `<run>/send/log.jsonl` |
| `akit_submit_context`, `akit_approved_requests` | Fetch pass: what a server said in prose. Send pass: the approved requests as JSON |
| `appendEntry` | Records the run id, the scenario and `head_sha` in the session |

MR descriptions, comments and work item texts are untrusted input. The agent has no tool that
writes outside the run folder, its MCP tools only read, and the send pass can only carry out
approved requests word for word, so an injection can at most produce a bad finding, which the
user sees before anything is sent.

For Claude Code later the same pipeline runs `claude -p --resume`, the role skill as a
subagent body, and the `akit_*` tools as a small local MCP server with PreToolUse hooks for
the path policy.

## Checks without a model

Added 2026-10-22 (branch `review-audit-2`). The code decides these, not a pass:

| Check | Where | Result |
|---|---|---|
| The quote is in the file | `ReviewCandidates.anchor` sets `evidenceFound`: any quoted line, without a diff marker or a line number, split at `...`, spaces collapsed, after the same masking and defusing as the file's lines (nil without a worktree, a quote or for a removed line, and for findings added in Discuss in Pi…); the verifier's input says when it isn't | Plan: only in AKit, "The quoted code isn't in … at the reviewed commit" |
| A person's open thread on the same lines (±2, not AKit's, on the reviewed commit: an older version's line numbers point elsewhere) | `ReviewPlanner.personThread` | Plan: only in AKit, "… already has an open thread on these lines". Resolved threads stay with the prompt and the verifier |
| Inline only on lines the change touches | `DiffPositions.isInDiff` (added, removed, or a context line GitLab shows) | Plan: a line in the summary |
| Secrets in added lines | Gather writes `<run>/scan.json` (`ReviewScan`): the file, the line and the masked line cut to ±80 characters around the mask, never the value; ignored files and diffs over GitLab's limits (when git made them) are scanned too, at most 20; a file that usually holds secrets (`.env`, credentials) is one secret by path, unread; a match of only the password rules is weaker (`high`) and skipped in test, fixture and example paths | After the verifier: a finding of role `secret-scan`, `critical` (`high` for a password), confirmed by AKit. A role's finding on the same lines is merged into it, so the secret keeps its own text. The person's-thread and ignored-path rules don't hold it back |
| The size of the change | `scan.json` `changedLines` (added + removed lines of files not ignored; a local rename counts as removed and added); `cost: max_changed_lines`, default 6000 (1500 before R37; over it the review alerts and goes on), per run in New Review… → This run only or `--max-changed-lines` | Before the passes, before the credit question: **A big change** (Run Anyway / Stop); the command line goes on with `--over-cap` |

The first three don't apply to a finding the user moved inline. Existing runs without
`scan.json` skip the last two.

## Pi steps

The user's own Pi set-up can add passes after the roles (the user's request, 2026-10-22: run
their subagents, slash commands and extra Pi parameters from AKit, with suggestions).

```yaml
pi:                                    # review.yaml, a profile, or one run (New Review… → Pi steps)
  flags: ["--exclude-tools", "find"]
  steps:
    - "/run reviewer check the retries"          # a pi-subagents agent, with a task
    - "/review-migrations orders"                 # a prompt template, with arguments
    - { run: "/skill:security-audit", max_findings: 3, min_severity: high }
    - "Check every new SQL query for an index"   # plain text
```

| Step | What AKit reads | The pass gets |
|---|---|---|
| `/run AGENT [TASK]` | The agent's `.md`: `~/.pi/agent/agents/**`, then the agents of installed packages (pi-subagents' builtins, `pi-subagents.agents` / `pi.subagents.agents` of a manifest) | Its prompt and the task; its model in pi-subagents' order (a custom agent's frontmatter, then `subagents.agentOverrides`; for a builtin the override first; then `subagents.defaultModel`, else the passes' model; a `:high` suffix is the thinking level), checked by the sending policy like every pass |
| `/TEMPLATE [ARGS]` | `~/.pi/agent/prompts/*.md` and the packages' prompts | The template expanded by AKit with Pi's own rules (`$1`, `$@`, `$ARGUMENTS`, `${1:-default}`, `${@:N}`, `${@:N:L}`; Pi's argument split) |
| `/skill:NAME [REQUEST]` | `~/.pi/agent/skills`, `~/.agents/skills`, the packages' skills | The skill's text and the request |
| text | | The text |

- Each step is one pass `step-<id>` in the main session after the roles (id `pi-<name>`, or
  `pi-step-<n>`), with the role prompt's rules: findings through `akit_submit_findings`, at most
  `max_findings` (default 5) at `min_severity` (default medium). Its findings are candidates like
  a role's, so the verifier checks them.
- Only the review's reading tools: an agent's `bash`, `edit`, `write` and other tools are left
  out, and the prompt says so. AKit never loads the package's code into a pass.
- Never from the reviewed repository: `.pi/agents`, `.pi/prompts` and the project's settings are
  not read, because a merge request could bring them.
- Extension commands (`/subagents-doctor`, `/council` with tools) don't run: in `pi -p` Pi ends
  before an async command finishes, and their code would run outside the checks. A step naming
  one stops the run with the list of what can run.
- The instructions (secrets masked) are in `run.json` (`steps`) and `<run>/steps/<id>.md`.
- Levels add up: brain, then profile, then run; a repeated command runs once.
- Flags go to the brief, the roles, the steps and the verifier, not to the fetch and send
  passes. Only an allowlist: `--name`/`-n`, `--exclude-tools`/`-xt` (not AKit's own tools, no
  patterns), `--no-approve`/`-na`, `--verbose`; every other item, a value that starts with `-`
  or `@`, a flag without its value, or a value that looks like a secret stops the run. Found in
  the review round: Pi takes the next argument as a flag's value even when it starts with `-`
  (a trailing `--name` would swallow AKit's `-e akit-review.ts` and with it every check), a
  loose `@file` puts any file into the prompt, and `--provider` / `--models` send the merge
  request to a provider the sending policy didn't check. The provider goes in the model
  (`provider/model`). Suggestions come from `pi --no-extensions --offline --help`, limited to
  the allowlist.
- `akit review pi` lists the agents, templates, skills and flags; `--step` and
  `--pi-flags="…"` add them to one run; `config show` prints the steps with their models and
  the tools left out.

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

**Fingerprint** = hash of the path and the anchor snippet (±2 lines, whitespace normalized).
Not the line number, so it survives shifts; not the role, so one problem from two roles is one
finding; not the title (revised 2026-10-22), because a model words it differently on each run,
which made a rerun delete and recreate drafts and reply "looks fixed" to a thread that wasn't.
Two problems on the same lines become one finding with the other in `related`; its
fingerprints stay in `foldedFingerprints`, so its drafts and threads still count as found. A finding
without lines of the file (an AC row, no checkout) keeps the normalized title in it. The
first rule's fingerprint (with the title) is kept as `previousFingerprint`, so drafts and
threads from before still match.

## Requests and posting

### Where each finding goes (R13)

| Finding | Inline draft | Summary draft | Only in AKit |
|---|---|---|---|
| Confirmed, severity ≥ threshold, confidence ≥ threshold | ✓ (up to the cap) | counted | ✓ |
| Confirmed, over the cap | — | one line each | ✓ |
| Question (not enough context) | — | "Questions to the author" | ✓ |
| Context gaps | — | "What was missing" | ✓ |
| Acceptance criteria matrix | — | ✓ | ✓ |
| Below the thresholds, rejected by the verifier | — | — | ✓, with the reason |

The user can move any finding into an inline draft by hand.

### Inline draft

```markdown
🤖 · `security` · **high** · confidence 0.86

The token from the header is logged in full in `AuthMiddleware.cs:42` and reaches Kibana.

```suggestion
_logger.LogDebug("Auth header present: {Present}", header is not null);
```
<!-- ai-review:v1 kind=finding fp=7c1e9a… role=security sev=high run=<run-id> th=… -->
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

- No allowed-list entry: Pi sends to the model it is set up with (revised 2026-10-16). Which
  model and provider Pi may use is the user's Pi setup, as in daily work.
- What goes to the provider: the context pack files the agent reads (diff, files, threads,
  work items, knowledge notes). The send log records the run id, provider, model, tokens and
  credits, and the paths read (from `tool_call`).
- What Pi's MCP servers answer reaches the model of the pass that asked (the fetch pass's
  scripts return only short notes; the context pack is scrubbed as before; MCP answers read in
  the passes are not).
- Run folders, findings, verdicts and profiles stay in `~/.akit/local`; AKit keeps no tokens. The brain gets only generic roles and scenarios (R17).
- Review credits are their own line in the monthly limit.

## Tokens

AKit keeps none (since 2026-10-15). The tokens belong to the MCP servers in Pi's settings, with
the rights those servers need: GitLab to read MRs and notes and to create, update and delete the
user's draft notes; Azure DevOps to read work items.

## Steps

Each step is one feature branch.

| # | Step | Check |
|---|---|---|
| 0 | No code, on the work Mac: `akit review check` (Pi's GitLab and tracker MCP servers, their tool names and which read or write); Azure DevOps Services or Server; `pi --list-models` for `github-copilot`; one real fetch pass on a small MR | the facts written into this doc |
| 1 | `AKitReview`: project profile, the three config levels, `ReviewRunSpec`; Gather from GitLab and Azure DevOps REST into the context pack; the worktree; `akit review` up to `run.json` | Swift tests on a fake server |
| 2 | The passes: brief → roles → verifier in one Pi session, `akit-review.ts` with the tools and the path policy, the estimate and the cap, the send log | fake Pi |
| 3 | Requests and the Review screen: noise rules, positions, scrubber, verdicts, Send Drafts…; `akit review post` | tests on a fake server; `make snapshot` |
| 4 | Reruns by fingerprint; Discuss in Pi… | tests |
| 5 | Roles and Scenarios screens, the three first scenarios and their roles in the brain layer `review`; the work-word check for brain edits | `make snapshot` |

## Guide

The in-app guide `docs/guides/review.ru.md` (Russian, like the other guides) describes how
review works, from simple tasks to hard ones:

1. What AKit Review does and what it never does (no publishing, no unapproved request).
2. Setting up: Pi's MCP servers, a project profile.
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

- Whether Pi's `tool_result` event can change a tool's output (a second scrub inside Pi). Pi's
  docs (1.0.4) say `tool_result` handlers compose and may replace `content`; not used yet.
- The exact Pi provider id `github-copilot` and the model names on the work account.
- Drafts on files over GitLab's diff limits on the user's GitLab version.
- Whether the work Mac's GitLab and Azure DevOps MCP servers answer in GitLab's and Azure
  DevOps's JSON (AKit sorts answers by shape); if not, the fetch pass falls back to
  `akit_submit_context`, which is the model's account.
