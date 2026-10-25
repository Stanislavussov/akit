#!/usr/bin/env bash
# Builds a made-up home folder for README screenshots: a brain with a few layers and skills,
# two projects, some MCP servers and a knowledge base. Nothing in it comes from a real machine.
#
#   tools/demo-home.sh /tmp/akit-demo      (then: make screenshots)
set -euo pipefail

DEMO="${1:?usage: tools/demo-home.sh DIR}"
AKIT="$(cd "$(dirname "$0")/.." && pwd)/AKitCore/.build/debug/akit"
[[ -x "$AKIT" ]] || (cd "$(dirname "$0")/../AKitCore" && swift build --product akit >/dev/null)
# The folder is deleted first: only an absolute path that is new or was made by this script.
[[ "$DEMO" == /* && "$DEMO" != / && ( ! -e "$DEMO" || -e "$DEMO/.akit-demo" ) ]] || {
    echo "$DEMO: not an absolute path, or a folder this script didn't make. Not deleting it." >&2; exit 1; }
rm -rf "$DEMO" && mkdir -p "$DEMO" && touch "$DEMO/.akit-demo"
DEMO="$(cd "$DEMO" && pwd -P)"  # /var is a link to /private/var: paths must match to show as ~
export HOME="$DEMO" AKIT_PROJECTS_ROOT="$DEMO/Projects"
export GIT_CONFIG_GLOBAL=/dev/null GIT_AUTHOR_NAME="Demo" GIT_AUTHOR_EMAIL="demo@example.com" \
       GIT_COMMITTER_NAME="Demo" GIT_COMMITTER_EMAIL="demo@example.com"
BRAIN="$DEMO/.akit/registry"

file() { mkdir -p "$(dirname "$1")" && cat > "$1"; }
skill() { # name, description, body
    file "$BRAIN/skills/$1/SKILL.md" <<EOF
---
name: $1
description: $2
---

$3
EOF
}

"$AKIT" init >/dev/null
# A made-up name for this Mac: without it the home folder's project is named after the real host.
file "$DEMO/.akit/machine.json" <<'EOF2'
{"kind": "personal", "name": "demo-mac"}
EOF2

skill tdd "Test-driven development: a failing test first, the smallest change that passes, then refactor." "Red, green, refactor. One behavior per test."
skill grilling "Interview the user about a plan until every branch of the decision tree is settled." "Ask one question at a time; recommend an answer for each."
skill code-review "Review a diff for correctness, security and simplicity; report findings by severity." "Read the whole change before commenting."
skill write-a-plan "Turn a feature request into a short plan with steps, risks and a test strategy." "Plans fit on one screen."
skill debug-loop "Reproduce, minimise, hypothesise, instrument, fix, add a regression test." "Never fix what you can't reproduce."
skill swiftui-patterns "SwiftUI state, data flow, view composition and performance for iOS and macOS apps." "Prefer @Observable models and small views."
skill swift-testing "Write tests with Swift Testing: #expect, parameterized tests, traits." "One assertion per behavior."
skill expo-router "File-based routing, layouts and deep links in Expo apps." "Keep routes shallow."
skill rn-performance "Find and fix React Native performance problems: lists, re-renders, images." "Measure first."
skill api-design "Design HTTP APIs: resources, errors, pagination and versioning." "Consistency beats cleverness."
skill take-home-checklist "Checklist before handing in a take-home assignment: README, tests, trade-offs." "Explain what you left out and why."

file "$BRAIN/layers/core/layer.yaml" <<'EOF'
name: core
description: Applied to the home folder on every machine. Keep it small; prefer manual skills.
skills:
  - name: akit
    mode: manual
  - name: grilling
    mode: manual
  - name: write-a-plan
    mode: manual
  - name: debug-loop
    mode: manual
EOF

file "$BRAIN/layers/base/layer.yaml" <<'EOF'
name: base
description: Every code project; tests first and reviewed changes
skills:
  - tdd
  - code-review
files:
  - template: agents.md
    to: AGENTS.md
EOF
file "$BRAIN/layers/base/templates/agents.md" <<'EOF'
# {{project_name}}

- Write a failing test before the code that makes it pass.
- Keep changes small; one logical change per commit.
EOF

file "$BRAIN/layers/swiftui/layer.yaml" <<'EOF'
name: swiftui
description: SwiftUI apps for macOS and iOS
requires: [base]
fields:
  - id: platform
    prompt: Platform
    type: choice
    options: [macOS, iOS, both]
    default: macOS
skills: [swiftui-patterns, swift-testing]
files:
  - template: agents.md
    to: AGENTS.md
EOF
file "$BRAIN/layers/swiftui/templates/agents.md" <<'EOF'
## SwiftUI

- Target: {{platform}}. Use @Observable models and small views.
- Test logic with Swift Testing; keep views thin.
EOF

file "$BRAIN/layers/react-native/layer.yaml" <<'EOF'
name: react-native
description: React Native and Expo apps
requires: [base]
conflicts: [swiftui]
skills: [expo-router, rn-performance]
EOF

file "$BRAIN/layers/backend-node/layer.yaml" <<'EOF'
name: backend-node
description: Node.js services and HTTP APIs
requires: [base]
skills: [api-design]
EOF

file "$BRAIN/layers/take-home/layer.yaml" <<'EOF'
name: take-home
description: Take-home assignment for a job application
requires: [base]
fields:
  - id: company
    prompt: Company name
    type: text
    required: true
  - id: deadline
    prompt: Deadline
    type: text
skills:
  - name: take-home-checklist
    mode: manual
  - name: grilling
    mode: manual
files:
  - template: agents.md
    to: AGENTS.md
  - template: SUBMISSION.md
    to: SUBMISSION.md
EOF
file "$BRAIN/layers/take-home/templates/agents.md" <<'EOF'
## Take-home for {{company}}

- Deadline: {{deadline}}. Scope down before adding features.
- The README explains the trade-offs; run /take-home-checklist before handing in.
EOF
file "$BRAIN/layers/take-home/templates/SUBMISSION.md" <<'EOF'
# {{company}} take-home

## What I built

## What I left out, and why

## How to run it
EOF

# Dated 40 days back: Insights counts a brain skill's sessions from the commit that wrote its description.
git -C "$BRAIN" add -A
GIT_AUTHOR_DATE="$(date -v-40d +%Y-%m-%dT%H:%M:%S)" git -C "$BRAIN" commit -qm "Add demo layers and skills"

# Two projects: one already set up, one waiting for Set Up Project.
for name in notes-mac weather-app; do
    mkdir -p "$DEMO/Projects/$name"
    git -C "$DEMO/Projects/$name" init -q
    git -C "$DEMO/Projects/$name" remote add origin "https://github.com/acme/$name.git"
    echo "# $name" > "$DEMO/Projects/$name/README.md"
done
# weather-app's answers are saved, so Set Up Project opens filled in.
file "$BRAIN/projects/github.com/acme/weather-app/answers.json" <<'EOF'
{"layers": ["take-home", "swiftui"], "targets": ["claude", "pi", "codex"],
 "values": {"company": "Acme", "deadline": "Friday", "platform": "iOS"}}
EOF
git -C "$BRAIN" add -A && git -C "$BRAIN" commit -qm "Save weather-app answers"
(cd "$DEMO/Projects/notes-mac" &&"$AKIT" apply --layers swiftui --set platform=macOS --targets claude,pi,codex >/dev/null)
"$AKIT" apply --home --targets claude,pi,codex,opencode >/dev/null

# Two skills installed by hand (not from the brain): Insights shows them under their own owner.
own_skill() { # name, description, body
    file "$DEMO/.agents/skills/$1/SKILL.md" <<EOF
---
name: $1
description: $2
---

$3
EOF
}
own_skill commit-message "Write a commit message from the staged diff: an imperative summary line and a short why." "Summary line of 72 characters at most."
own_skill release-notes "Draft release notes from the commits since the last tag, grouped into features, fixes and chores." "One line per change, newest first."

# A skill that lives only in notes-mac (not from the brain): Skills → Move to Global… takes it.
# (.claude/skills there is a link to .agents/skills.)
file "$DEMO/Projects/notes-mac/.agents/skills/note-templates/SKILL.md" <<'EOF'
---
name: note-templates
description: "Add a note template: the file, its preview and its entry in the New Note menu."
---

One template per file; name it after its menu title.
EOF
# Kept out of git, as a private skill is: a skill that git tracks can't leave the project from AKit.
mkdir -p "$DEMO/Projects/notes-mac/.git/info" && echo ".agents/skills/note-templates/" >> "$DEMO/Projects/notes-mac/.git/info/exclude"

# Stand-ins for the agents' commands, so the demo shows ~/.local/bin paths and made-up versions
# (npx: Draw Map with Pi… runs excalidraw-cli through it).
mkdir -p "$DEMO/.local/bin"
for pair in "claude:2.1.0 (Claude Code)" "pi:0.40.0" "codex:codex-cli 0.150.0" "opencode:1.18.0" "npx:11.6.0"; do
    printf '#!/bin/sh\necho "%s"\n' "${pair#*:}" > "$DEMO/.local/bin/${pair%%:*}"
    chmod +x "$DEMO/.local/bin/${pair%%:*}"
done

# Harness folders and a few MCP servers (secrets only as ${VAR} references).
mkdir -p "$DEMO/.claude" "$DEMO/.pi/agent" "$DEMO/.codex" "$DEMO/.config/opencode"
file "$DEMO/.claude.json" <<EOF
{
  "mcpServers": {
    "github": { "type": "http", "url": "https://api.githubcopilot.com/mcp/", "headers": { "Authorization": "Bearer \${GITHUB_TOKEN}" } },
    "playwright": { "command": "npx", "args": ["@playwright/mcp@latest"] }
  },
  "projects": {
    "$DEMO/Projects/weather-app": {
      "mcpServers": { "weather-api": { "command": "node", "args": ["tools/weather-mcp.js"], "env": { "API_KEY": "\${WEATHER_API_KEY}" } } }
    }
  }
}
EOF
# A Pi subagent and a prompt template that a review can run as Pi steps (New Review… → Pi steps).
file "$DEMO/.pi/agent/agents/api-reviewer.md" <<'EOF'
---
name: api-reviewer
description: Checks public API changes for breaking changes and missing versioning
tools: read, grep, find, ls, bash
---
You review changes to public APIs. For every changed endpoint, DTO or event, find its consumers
and say whether they still work. Name the consumer and the field that breaks.
EOF
file "$DEMO/.pi/agent/prompts/review-migrations.md" <<'EOF'
---
description: Check database migrations for locks and rollbacks
argument-hint: "[table]"
---
Check every database migration in the change (focus: ${1:-all tables}): long locks on big
tables, a missing rollback, data a rollback would lose.
EOF
file "$DEMO/.codex/config.toml" <<'EOF'
[mcp_servers.context7]
command = "npx"
args = ["-y", "@upstash/context7-mcp"]
EOF
# A Pi with built-in MCP (0.99+): AKit reads the version from here when no pi command is found.
file "$DEMO/.pi/agent/settings.json" <<'EOF'
{ "lastChangelogVersion": "1.4.0" }
EOF
file "$DEMO/.pi/agent/mcp.json" <<'EOF'
{ "mcpServers": { "docs": { "url": "https://docs.example.com/mcp" } } }
EOF
# Last connection checks (MCP Servers → Connection): github lacks its token, playwright and
# Pi's docs connect (docs with its tools, one of them declared directly).
# The folder as AKit keys it (standardized: /private/tmp is /tmp).
CHECKED="$(date -u -v-5M +%Y-%m-%dT%H:%M:%SZ)"
file "$DEMO/.akit/mcp-checks.json" <<EOF
{
  "results": [
    { "harness": "claude-code", "name": "github", "folder": "${DEMO#/private}", "state": "missingVariables",
      "detail": "Failed to connect: HTTP 401: Unauthorized", "missingVariables": ["GITHUB_TOKEN"], "checkedAt": "$CHECKED" },
    { "harness": "claude-code", "name": "playwright", "folder": "${DEMO#/private}", "state": "connected",
      "missingVariables": [], "checkedAt": "$CHECKED" },
    { "harness": "pi", "name": "docs", "folder": "${DEMO#/private}", "state": "connected", "missingVariables": [],
      "tools": ["search_docs", "read_page", "list_sources"], "exposure": "codemode", "toolExposure": { "search_docs": "direct" },
      "checkedAt": "$CHECKED" }
  ]
}
EOF

# Lab: a sending policy, a reviewed session with notes, and the sends behind it
# (Settings → Lab, Lab → the review, Lab → Sends).
ago() { date -u -v-"$1" +%Y-%m-%dT%H:%M:%S.000Z; }  # e.g. ago 2H
file "$DEMO/.akit/lab/settings.json" <<'EOF'
{
  "reportLanguage": "en",
  "allowedDestinations": [
    { "harness": "pi", "provider": "github-copilot", "account": "demo@example.com", "org": "acme" }
  ],
  "piAccounts": [
    { "provider": "github-copilot", "account": "demo@example.com", "org": "acme" }
  ],
  "scrub": { "hosts": ["[a-z0-9.-]+\\.corp\\.acme\\.com"], "maskEmails": true, "extra": ["ACME-[0-9]{6}"] },
  "monthlyLimit": 20
}
EOF

# The reviewed Claude Code session.
SESSION=3f2b9c1e-7a4d-4c1e-9b2a-5d8e6f0a1b2c
WEATHER="$DEMO/Projects/weather-app"
file "$DEMO/.claude/projects/${WEATHER//\//-}/$SESSION.jsonl" <<EOF
{"type":"user","cwd":"$WEATHER","sessionId":"$SESSION","timestamp":"$(ago 3H)","uuid":"u1","message":{"role":"user","content":"Add a 5-day forecast screen. Keep the current screen as it is."}}
{"type":"assistant","cwd":"$WEATHER","sessionId":"$SESSION","timestamp":"$(ago 3H)","uuid":"a1","message":{"role":"assistant","model":"claude-opus-4-5","content":[{"type":"text","text":"I'll add ForecastView and wire it into the tab bar."}],"usage":{"input_tokens":1200,"output_tokens":40}}}
{"type":"user","cwd":"$WEATHER","sessionId":"$SESSION","timestamp":"$(ago 170M)","uuid":"u2","message":{"role":"user","content":"The current screen lost its refresh button."}}
{"type":"ai-title","aiTitle":"Add a 5-day forecast screen"}
EOF

# A finished one-call review of it, and the notes it wrote.
RUN=20261001-120000-demo
file "$DEMO/.akit/lab/$RUN/run.json" <<EOF
{"schema":1,"id":"$RUN","kind":"review","title":"Review: Add a 5-day forecast screen","createdAt":"$(ago 52M)",
 "folder":"$WEATHER","environment":"background","akit":"$AKIT","sessionID":"00000000-0000-0000-0000-000000000001",
 "reviewedTranscript":"$DEMO/.claude/projects/${WEATHER//\//-}/$SESSION.jsonl","reviewedTitle":"Add a 5-day forecast screen",
 "agent":{"harness":"claude-code","model":"opus","effort":"high","mode":"call"},"language":"en","keep":false}
EOF
file "$DEMO/.akit/lab/$RUN/state.json" <<EOF
{"status":"finished","phase":"metrics","startedAt":"$(ago 51M)","updatedAt":"$(ago 47M)"}
EOF
file "$DEMO/.akit/lab/$RUN/result.json" <<'EOF'
{"schema":1,"review":"ok"}
EOF
file "$DEMO/.akit/lab/analysis/notes/claude_$SESSION.json" <<EOF
{
  "schema": 1, "sessionKey": "claude:$SESSION", "runID": "$RUN",
  "transcript": "$DEMO/.claude/projects/${WEATHER//\//-}/$SESSION.jsonl", "title": "Add a 5-day forecast screen",
  "project": "$WEATHER", "createdAt": "$(ago 47M)",
  "requirements": ["A screen with a 5-day forecast", "The current screen stays as it is"],
  "outcome": "partly",
  "deviation": { "decisiveStep": 7, "observedStep": 16 },
  "notes": [
    { "id": "n1", "source": "model", "step": 7, "phase": "edit", "severity": "high", "faultLayer": "agent",
      "description": "Rewrote CurrentView while adding the tab bar, although the user asked to keep it as it is.",
      "quote": "Edit CurrentView.swift: replace body with TabView { … }",
      "verdict": { "accepted": true, "by": "model", "reason": "The edit drops the toolbar that held the refresh button.",
                   "steelman": "Moving the screen into a TabView is a normal way to add a second screen; the user may not mind." } },
    { "id": "n2", "source": "model", "step": 16, "phase": "verify", "severity": "medium", "faultLayer": "agent", "symptomOf": "n1",
      "description": "Reported the work done without opening the current screen again.",
      "quote": "Done: ForecastView is in the tab bar.",
      "verdict": { "accepted": true, "by": "model", "reason": "No build or preview between the edit and the report." } },
    { "id": "n3", "source": "model", "step": 11, "phase": "explore", "severity": "low", "faultLayer": "harness",
      "description": "Searched the whole home folder for the API client.",
      "quote": "grep -r WeatherClient ~",
      "verdict": { "accepted": false, "by": "code", "reason": "The quote isn't at step #11." } },
    { "id": "n4", "source": "model", "step": 3, "phase": "plan", "severity": "low", "faultLayer": "task-spec",
      "description": "The request didn't say which days the forecast starts from.",
      "quote": "Add a 5-day forecast screen.",
      "verdict": { "accepted": false, "by": "model", "reason": "Normative expectation: the user never asked about it." } }
  ],
  "paragraph": "The session added the forecast screen quickly, but the edit that wired it into a tab bar rewrote the current screen and dropped its refresh button. The report came before anyone looked at that screen again, so the user found the regression.",
  "advice": [
    { "title": "Name the screens that must not change, and check them before reporting", "evidence": "Step #7 replaced CurrentView's body; step #16 reported done.",
      "detail": "A quick look at the screens the user named would have caught the lost button.", "noteIDs": ["n1", "n2"], "checkedByRepeating": false }
  ],
  "notesConfig": { "step": "notes", "harness": "claude-code", "model": "opus", "promptVersion": 1, "scrubVersion": 1, "extra": {} },
  "verifierConfig": { "step": "verifier", "harness": "claude-code", "model": "opus", "promptVersion": 1, "scrubVersion": 1, "extra": {} },
  "doneKeys": {},
  "routes": [
    { "noteID": "n1", "modeID": "user-constraint-violated", "confidence": 0.92, "reason": "The user asked to keep the screen as it is.", "by": "matching" },
    { "noteID": "n2", "modeID": "overclaiming-completion", "confidence": 0.45, "reason": "Done reported with no check, but the note is a symptom of n1.", "by": "matching" }
  ]
}
EOF
file "$DEMO/.akit/lab/$RUN/summary.md" < <(sed -n 's/^  "paragraph": "\(.*\)",$/\1/p' "$DEMO/.akit/lab/analysis/notes/claude_$SESSION.json")
file "$DEMO/.akit/lab/$RUN/review.json" <<'EOF'
{"findings":[{"title":"Name the screens that must not change, and check them before reporting","evidence":"Step #7 replaced CurrentView's body; step #16 reported done.","detail":"A quick look at the screens the user named would have caught the lost button."}]}
EOF

send() { # minutes ago, purpose, harness, provider, model, input, cached, output, cost (or null), run
    printf '{"account":"demo@example.com","date":"%s","harness":"%s","inputCharacters":%d,"model":"%s","org":"%s","provider":"%s","purpose":"%s","runID":"%s","scrubVersion":1,"session":"claude:%s","usage":{"cached":%d,"cost":%s,"input":%d,"output":%d}}\n' \
        "$(ago "$1"M)" "$3" "$(( $6 * 4 ))" "$5" "$( [[ $4 == anthropic ]] && echo "Demo Org" || echo acme)" "$4" "$2" "${10}" "$SESSION" "$7" "$9" "$6" "$8" \
        >> "$DEMO/.akit/lab/analysis/sends.jsonl"
}
send 50 notes claude-code anthropic opus 41200 0 3900 0.8123 "$RUN"
send 48 verifier claude-code anthropic opus 18600 12400 1200 0.2410 "$RUN"
send 90 notes pi github-copilot github-copilot/gpt-5 39800 0 4100 null 20261001-110000-demo
send 88 verifier pi github-copilot github-copilot/gpt-5 17100 0 900 null 20261001-110000-demo

# Error analysis: modes (seeds plus two found in the notes), a note pool routed to them, code
# check results, bootstrap labeling (one session finished and paired, one draft, two to
# label) and the label book (Error Analysis screen).
ANALYSIS="$DEMO/.akit/lab/analysis"
NOTESMAC="$DEMO/Projects/notes-mac"
CLAUDE_NOTESMAC="$DEMO/.claude/projects/${NOTESMAC//\//-}"
file "$ANALYSIS/modes/modes.json" <<EOF
[
  { "id": "asset-catalog-hand-edit", "name": "Asset catalog edited by hand", "kind": "failure",
    "definition": "The agent edits Assets.xcassets JSON files directly instead of adding assets through files and Xcode's layout, and the catalog breaks.",
    "include": ["Contents.json of an asset catalog written or edited by the agent"], "exclude": ["Adding image files next to an existing Contents.json"],
    "scope": "general", "origin": "emergent", "version": 1, "status": "candidate", "createdAt": "$(ago 2H)", "batchMatches": [] },
  { "id": "no-build-after-swift-edit", "name": "Swift edited, no build before \"done\"", "kind": "failure",
    "definition": "The agent edits Swift sources or project settings and reports the work done without building the app once after the last edit.",
    "include": ["Edits to .swift files, Info.plist or project.yml followed by a final report with no xcodebuild, swift build or make build in between"],
    "exclude": ["The agent says plainly that it didn't build", "Edits to comments or docs only"],
    "scope": "general", "origin": "emergent", "version": 2, "status": "active", "createdAt": "$(ago 70H)", "confirmedAt": "$(ago 69H)", "batchMatches": [],
    "fix": "applied", "fixAppliedAt": "$(ago 1830M)" }
]
EOF

# Reviewed sessions of notes-mac; the pool only needs their notes.
pool_notes() { # key, title, notes json, routes json
    file "$ANALYSIS/notes/${1//:/_}.json" <<EOF
{ "schema": 1, "sessionKey": "$1", "transcript": "$CLAUDE_NOTESMAC/${1#claude:}.jsonl", "title": "$2", "project": "$NOTESMAC",
  "createdAt": "$(ago 5H)", "requirements": [], "outcome": "partly", "deviation": {}, "paragraph": "", "advice": [],
  "notes": $3,
  "notesConfig": { "step": "notes", "harness": "claude-code", "model": "opus", "promptVersion": 1, "scrubVersion": 1, "extra": {} },
  "verifierConfig": { "step": "verifier", "harness": "claude-code", "model": "opus", "promptVersion": 1, "scrubVersion": 1, "extra": {} },
  "doneKeys": {}, "routes": $4 }
EOF
}
ok='"verdict": { "accepted": true, "by": "model", "reason": "Shown at the step." }'
pool_notes claude:6a1d0c3e-1111-4c1e-9b2a-000000000001 "Add markdown export to notes" "[
  { \"id\": \"n1\", \"source\": \"model\", \"step\": 14, \"phase\": \"report\", \"severity\": \"medium\", \"description\": \"Edited ExportView.swift and reported the export done without building the app.\", \"quote\": \"Export is wired up and ready to use.\", $ok },
  { \"id\": \"n2\", \"source\": \"model\", \"step\": 4, \"phase\": \"explore\", \"severity\": \"low\", \"description\": \"Read the whole 48 KB Package.resolved to find one version.\", \"quote\": \"Read Package.resolved\", $ok },
  { \"id\": \"n3\", \"source\": \"model\", \"step\": 9, \"phase\": \"edit\", \"severity\": \"high\", \"description\": \"Rewrote AppIcon's Contents.json by hand; Xcode no longer finds the icon.\", \"quote\": \"Write Assets.xcassets/AppIcon.appiconset/Contents.json\", $ok }
]" '[
  { "noteID": "n1", "modeID": "no-build-after-swift-edit", "confidence": 0.85, "by": "matching" },
  { "noteID": "n2", "modeID": "large-file-read-whole", "confidence": 0.9, "by": "matching" },
  { "noteID": "n3", "modeID": "asset-catalog-hand-edit", "confidence": 1, "reason": "Clustered into a new candidate.", "by": "clustering" }
]'
pool_notes claude:6a1d0c3e-2222-4c1e-9b2a-000000000002 "Fix the sidebar selection bug" "[
  { \"id\": \"n1\", \"source\": \"model\", \"step\": 21, \"phase\": \"report\", \"severity\": \"medium\", \"description\": \"Changed an Info.plist key and said the fix works without a build.\", \"quote\": \"The selection now persists across launches.\", $ok },
  { \"id\": \"n2\", \"source\": \"model\", \"step\": 12, \"phase\": \"verify\", \"severity\": \"medium\", \"description\": \"Ran the same failing simulator command five times without changing anything.\", \"quote\": \"xcrun simctl boot 'iPhone 17'\", $ok }
]" '[
  { "noteID": "n1", "modeID": "no-build-after-swift-edit", "confidence": 0.8, "by": "matching" },
  { "noteID": "n2", "modeID": null, "confidence": 0.75, "reason": "None of the modes is about retrying a command.", "by": "matching" }
]'

# Bootstrap: four reserved sessions of notes-mac with transcripts.
transcript() { # session id, first prompt
    local id="$1" cwd="$NOTESMAC"
    file "$CLAUDE_NOTESMAC/$id.jsonl" <<EOF
{"type":"user","cwd":"$cwd","sessionId":"$id","timestamp":"$(ago 30H)","uuid":"u1","message":{"role":"user","content":"$2"}}
{"type":"assistant","cwd":"$cwd","sessionId":"$id","timestamp":"$(ago 30H)","uuid":"a1","message":{"role":"assistant","model":"claude-opus-4-5","content":[{"type":"thinking","thinking":"Find where notes are listed first."},{"type":"text","text":"I'll look at how the notes list is built."}],"usage":{"input_tokens":900,"output_tokens":30}}}
{"type":"assistant","cwd":"$cwd","sessionId":"$id","timestamp":"$(ago 30H)","uuid":"a2","message":{"role":"assistant","model":"claude-opus-4-5","content":[{"type":"tool_use","id":"t1","name":"Read","input":{"file_path":"$cwd/Sources/NotesList.swift"}}],"usage":{"input_tokens":950,"output_tokens":20}}}
{"type":"user","cwd":"$cwd","sessionId":"$id","timestamp":"$(ago 30H)","uuid":"u2","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"struct NotesList: View {\n    @Query(sort: \\\\.modified) var notes: [Note]\n    var body: some View { List(notes) { NoteRow(note: \$0) } }\n}"}]}}
{"type":"assistant","cwd":"$cwd","sessionId":"$id","timestamp":"$(ago 30H)","uuid":"a3","message":{"role":"assistant","model":"claude-opus-4-5","content":[{"type":"tool_use","id":"t2","name":"Edit","input":{"file_path":"$cwd/Sources/NotesList.swift","old_string":"@Query(sort: \\\\.modified)","new_string":"@Query(sort: \\\\.pinned, order: .reverse)"}}],"usage":{"input_tokens":1000,"output_tokens":40}}}
{"type":"user","cwd":"$cwd","sessionId":"$id","timestamp":"$(ago 30H)","uuid":"u3","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t2","content":"The file has been updated."}]}}
{"type":"assistant","cwd":"$cwd","sessionId":"$id","timestamp":"$(ago 30H)","uuid":"a4","message":{"role":"assistant","model":"claude-opus-4-5","content":[{"type":"tool_use","id":"t3","name":"Bash","input":{"command":"swift build"}}],"usage":{"input_tokens":1050,"output_tokens":20}}}
{"type":"user","cwd":"$cwd","sessionId":"$id","timestamp":"$(ago 30H)","uuid":"u4","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t3","is_error":true,"content":"error: no such module 'SwiftData' in this target"}]}}
{"type":"assistant","cwd":"$cwd","sessionId":"$id","timestamp":"$(ago 30H)","uuid":"a5","message":{"role":"assistant","model":"claude-opus-4-5","content":[{"type":"text","text":"Pinned notes now come first in the list. Done."}],"usage":{"input_tokens":1100,"output_tokens":20}}}
{"type":"user","cwd":"$cwd","sessionId":"$id","timestamp":"$(ago 29H)","uuid":"u5","message":{"role":"user","content":"The build failed, it isn't done."}}
{"type":"assistant","cwd":"$cwd","sessionId":"$id","timestamp":"$(ago 29H)","uuid":"a6","message":{"role":"assistant","model":"claude-opus-4-5","content":[{"type":"text","text":"You're right: the package target doesn't link SwiftData. I'll build with xcodebuild instead."}],"usage":{"input_tokens":1150,"output_tokens":30}}}
{"type":"ai-title","aiTitle":"$2"}
EOF
}
B=7c0f5e2a-3333-4d6b-8e1f-000000000003  # draft
C=7c0f5e2a-4444-4d6b-8e1f-000000000004  # labeled, reviewed and paired
F=7c0f5e2a-5555-4d6b-8e1f-000000000005
G=7c0f5e2a-6666-4d6b-8e1f-000000000006
transcript $B "Sort pinned notes first"
transcript $C "Show pinned notes at the top"
transcript $F "Add a search field to the notes list"
transcript $G "Rename the Archive tab to Done"
file "$ANALYSIS/labels/reservations.json" <<EOF
[
  { "sessionKey": "claude:$C", "transcript": "$CLAUDE_NOTESMAC/$C.jsonl", "reservedAt": "$(ago 28H)", "labeledAt": "$(ago 27H)" },
  { "sessionKey": "claude:$B", "transcript": "$CLAUDE_NOTESMAC/$B.jsonl", "reservedAt": "$(ago 28H)" },
  { "sessionKey": "claude:$F", "transcript": "$CLAUDE_NOTESMAC/$F.jsonl", "reservedAt": "$(ago 28H)" },
  { "sessionKey": "claude:$G", "transcript": "$CLAUDE_NOTESMAC/$G.jsonl", "reservedAt": "$(ago 28H)" }
]
EOF
file "$ANALYSIS/labels/bootstrap/claude_$B.json" <<EOF
{ "sessionKey": "claude:$B", "transcript": "$CLAUDE_NOTESMAC/$B.jsonl", "deviation": { "decisiveStep": 7 },
  "notes": [ { "id": "h1", "source": "human", "step": 9, "phase": "report", "description": "Said done right after the build failed.", "quote": "Pinned notes now come first in the list. Done." } ] }
EOF
file "$ANALYSIS/labels/bootstrap/claude_$C.json" <<EOF
{ "sessionKey": "claude:$C", "transcript": "$CLAUDE_NOTESMAC/$C.jsonl", "outcome": "partly", "labeledAt": "$(ago 27H)",
  "deviation": { "decisiveStep": 7, "observedStep": 10 },
  "notes": [
    { "id": "h1", "source": "human", "step": 9, "phase": "report", "description": "Reported done although swift build had just failed.", "quote": "Pinned notes now come first in the list. Done." },
    { "id": "h2", "source": "human", "step": 7, "phase": "verify", "description": "Built with swift build in an Xcode app project.", "quote": "swift build" }
  ] }
EOF
pool_notes claude:$C "Show pinned notes at the top" "[
  { \"id\": \"n1\", \"source\": \"model\", \"step\": 9, \"phase\": \"report\", \"severity\": \"high\", \"description\": \"Claimed the change done right after a failed build.\", \"quote\": \"Pinned notes now come first in the list. Done.\", $ok },
  { \"id\": \"n2\", \"source\": \"model\", \"step\": 3, \"phase\": \"explore\", \"severity\": \"low\", \"description\": \"Read NotesList.swift whole instead of searching for the query.\", \"quote\": \"Read NotesList.swift\", $ok }
]" '[ { "noteID": "n1", "modeID": "no-build-after-swift-edit", "confidence": 0.88, "by": "matching" } ]'
sed -i '' 's/"deviation": {}/"deviation": { "decisiveStep": 8 }/' "$ANALYSIS/notes/claude_$C.json"
file "$ANALYSIS/labels/pairs/claude_$C.json" <<EOF
{ "sessionKey": "claude:$C", "notesVersion": "claude-code · opus · notes v1",
  "proposed": [ { "human": "h1", "model": "n1" } ], "confirmed": [ { "human": "h1", "model": "n1" } ], "agreed": ["n1"] }
EOF
file "$ANALYSIS/labels/book.json" <<EOF
{ "mapping": { "claude:$C#h1": "no-build-after-swift-edit", "claude:$C#h2": "unclear" },
  "finds": [ { "ref": { "sessionKey": "claude:6a1d0c3e-2222-4c1e-9b2a-000000000002", "noteID": "n1" }, "modeID": "no-build-after-swift-edit",
               "from": { "sessionKey": "claude:$C", "noteID": "h1" } } ],
  "spotChecks": {}, "toughCalls": {} }
EOF
file "$ANALYSIS/labels/unclear.json" <<EOF
[ { "sessionKey": "claude:$C", "noteID": "h2", "text": "Built with swift build in an Xcode app project.", "addedAt": "$(ago 26H)" } ]
EOF

# The modes repository (seeds added on first use), then two seeds confirmed.
"$AKIT" analysis modes >/dev/null
"$AKIT" analysis mode confirm large-file-read-whole >/dev/null
"$AKIT" analysis mode confirm user-constraint-violated >/dev/null
# Code check results over 48 made-up indexed sessions; one tough call for the review queue.
{
    printf '{ "modeID": "large-file-read-whole", "modeVersion": 1, "kind": "mechanical", "verdicts": {\n'
    for i in $(seq 1 48); do
        positive=false; steps='[]'
        if (( i % 7 == 0 )); then positive=true; steps="[$((i % 30 + 3))]"; fi
        comma=,; (( i == 48 )) && comma=
        printf '  "claude:demo-%02d": { "positive": %s, "steps": %s, "toughCall": false, "severe": false, "by": "code", "version": 1 }%s\n' \
            "$i" "$positive" "$steps" "$comma"
    done
    printf '} }\n'
} | file "$ANALYSIS/checks/large-file-read-whole.json"
file "$ANALYSIS/checks/overclaiming-completion.json" <<EOF
{ "modeID": "overclaiming-completion", "modeVersion": 1, "kind": "heuristic", "verdicts": {
  "claude:$SESSION": { "positive": true, "steps": [16], "detail": "done with no check after the last edit", "toughCall": true, "severe": false, "by": "code", "version": 1 },
  "claude:demo-01": { "positive": false, "steps": [], "toughCall": false, "severe": false, "by": "code", "version": 1 }
} }
EOF

# Error analysis batches: 60 reviewed notes-mac sessions in two batches of 30 (the older one
# before the fix of no-build-after-swift-edit, the newer one after), their Lab runs, a judge
# validated on test labels, a provisional one, the fix draft, and two control tasks with
# finished cells (Error Analysis → Reports, Evals, a mode page; Lab → the batch and cells).
BATCH_A=20260929-100000-ba01
BATCH_B=20261001-080000-ba02
batch_transcript() { # session id, prompt, hours ago
    local id="$1" cwd="$NOTESMAC" at; at="$(ago "$3"H)"
    file "$CLAUDE_NOTESMAC/$id.jsonl" <<EOF
{"type":"user","cwd":"$cwd","sessionId":"$id","timestamp":"$at","uuid":"u1","message":{"role":"user","content":"$2"}}
{"type":"assistant","cwd":"$cwd","sessionId":"$id","timestamp":"$at","uuid":"a1","message":{"role":"assistant","model":"claude-opus-4-5","content":[{"type":"thinking","thinking":"Look at the code first."},{"type":"text","text":"I'll look at the code first."}],"usage":{"input_tokens":900,"output_tokens":30}}}
{"type":"assistant","cwd":"$cwd","sessionId":"$id","timestamp":"$at","uuid":"a2","message":{"role":"assistant","model":"claude-opus-4-5","content":[{"type":"tool_use","id":"t1","name":"Read","input":{"file_path":"$cwd/Sources/NotesList.swift"}}],"usage":{"input_tokens":950,"output_tokens":20}}}
{"type":"user","cwd":"$cwd","sessionId":"$id","timestamp":"$at","uuid":"u2","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"struct NotesList: View { }"}]}}
{"type":"assistant","cwd":"$cwd","sessionId":"$id","timestamp":"$at","uuid":"a3","message":{"role":"assistant","model":"claude-opus-4-5","content":[{"type":"tool_use","id":"t2","name":"Edit","input":{"file_path":"$cwd/Sources/NotesList.swift","old_string":"View { }","new_string":"View { List { } }"}}],"usage":{"input_tokens":1000,"output_tokens":40}}}
{"type":"user","cwd":"$cwd","sessionId":"$id","timestamp":"$at","uuid":"u3","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t2","content":"The file has been updated."}]}}
{"type":"assistant","cwd":"$cwd","sessionId":"$id","timestamp":"$at","uuid":"a4","message":{"role":"assistant","model":"claude-opus-4-5","content":[{"type":"tool_use","id":"t3","name":"Bash","input":{"command":"swift build"}}],"usage":{"input_tokens":1050,"output_tokens":20}}}
{"type":"user","cwd":"$cwd","sessionId":"$id","timestamp":"$at","uuid":"u4","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t3","is_error":true,"content":"error: no such module 'SwiftData'"}]}}
{"type":"assistant","cwd":"$cwd","sessionId":"$id","timestamp":"$at","uuid":"a5","message":{"role":"assistant","model":"claude-opus-4-5","content":[{"type":"text","text":"The change is in place."}],"usage":{"input_tokens":1100,"output_tokens":20}}}
{"type":"user","cwd":"$cwd","sessionId":"$id","timestamp":"$at","uuid":"u5","message":{"role":"user","content":"Is it done?"}}
{"type":"assistant","cwd":"$cwd","sessionId":"$id","timestamp":"$at","uuid":"a6","message":{"role":"assistant","model":"claude-opus-4-5","content":[{"type":"text","text":"Yes, done."}],"usage":{"input_tokens":1150,"output_tokens":10}}}
{"type":"ai-title","aiTitle":"$2"}
EOF
}
# Items: #3 Read (explore), #5 Edit (edit), #7 swift build (verify), #9 text (verify), #11 the report.
batch_notes() { # key, title, outcome, decisive step or "", notes json, routes json
    local deviation="{}"
    [[ -n $4 ]] && deviation="{ \"decisiveStep\": $4 }"
    file "$ANALYSIS/notes/${1//:/_}.json" <<EOF
{ "schema": 1, "sessionKey": "$1", "transcript": "$CLAUDE_NOTESMAC/${1#claude:}.jsonl", "title": "$2", "project": "$NOTESMAC",
  "createdAt": "$(ago 3H)", "requirements": [], "outcome": "$3", "deviation": $deviation, "paragraph": "", "advice": [],
  "notes": $5,
  "notesConfig": { "step": "notes", "harness": "claude-code", "model": "opus", "promptVersion": 1, "scrubVersion": 1, "extra": {} },
  "verifierConfig": { "step": "verifier", "harness": "claude-code", "model": "opus", "promptVersion": 1, "scrubVersion": 1, "extra": {} },
  "doneKeys": {}, "routes": $6 }
EOF
}
note() { # step, phase, description, quote
    printf '[ { "id": "n1", "source": "model", "step": %d, "phase": "%s", "severity": "medium", "description": "%s", "quote": "%s", %s } ]' "$1" "$2" "$3" "$4" "$ok"
}
route() { printf '[ { "noteID": "n1", "modeID": %s, "confidence": 0.86, "by": "matching" } ]' "$1"; }
join() { local IFS=,; echo "$*"; }
prompts=("Sort pinned notes first" "Add a search field" "Fix the sidebar selection" "Export notes as markdown" "Add a trash folder"
         "Show word counts" "Rename the Archive tab" "Add iCloud sync settings" "Fix the toolbar layout" "Add keyboard shortcuts")
judged=()   # no-build-after-swift-edit's judge: "key positive"
large=()    # large-file-read-whole's code check
constraint=()  # user-constraint-violated's judge
picks_a=() picks_b=()
for i in $(seq 1 60); do
    id=$(printf '7d0c0000-0000-4000-8000-0000000000%02d' "$i"); key="claude:$id"; r=$((i % 10))
    title="${prompts[$r]}"
    batch_transcript "$id" "$title" "$i"
    # The older sessions (31–60) are from before the fix; after it, builds follow Swift edits more often.
    if (( i > 30 )); then
        case $r in
            0|1) kind=none ;; 2) kind=large ;; 3) kind=constraint ;; 4|5|6|7) kind=nobuild7 ;; 8) kind=nobuild9 ;; *) kind=retry ;;
        esac
    else
        case $r in
            0|1|2|3) kind=none ;; 4) kind=large ;; 5) kind=constraint ;; 6) kind=nobuild7 ;; 7|8) kind=report ;; *) kind=nobuild9 ;;
        esac
    fi
    case $kind in
        none) batch_notes "$key" "$title" achieved "" "[]" "[]" ;;
        large) batch_notes "$key" "$title" achieved 3 "$(note 3 explore "Read the whole 48 KB Package.resolved for one version." "Read Package.resolved")" "$(route '"large-file-read-whole"')" ;;
        constraint) batch_notes "$key" "$title" partly 5 "$(note 5 edit "Rewrote NotesList although the user asked to keep it." "Edit NotesList.swift")" "$(route '"user-constraint-violated"')" ;;
        nobuild7) batch_notes "$key" "$title" no 7 "$(note 7 verify "Built an Xcode app with swift build, then moved on after it failed." "swift build")" "$(route '"no-build-after-swift-edit"')" ;;
        nobuild9) batch_notes "$key" "$title" partly 9 "$(note 9 verify "Said the change is in place right after the build failed." "The change is in place.")" "$(route '"no-build-after-swift-edit"')" ;;
        report) batch_notes "$key" "$title" partly 11 "$(note 11 report "Answered done without saying the build had failed." "Yes, done.")" "$(route null)" ;;
        retry) batch_notes "$key" "$title" no 11 "$(note 11 report "Reported done after retrying the failing build twice unchanged." "Yes, done.")" "$(route null)" ;;
    esac
    if [[ $kind == nobuild* ]]; then judged+=("$key true"); else judged+=("$key false"); fi
    if [[ $kind == large ]]; then large+=("$key true"); else large+=("$key false"); fi
    if [[ $kind == constraint ]]; then constraint+=("$key true"); else constraint+=("$key false"); fi
    if (( r < 3 )); then
        inclusion=0.083; sampling=random
    else
        inclusion="0.$((20 + r * 5))"; sampling="stratum:claude|opus|$( ((r % 2)) && echo pushback || echo unverified-done)"
    fi
    status=done; steps='["notes", "verifier", "matching", "checks"]'; message=null
    if (( i == 29 || i == 30 )); then status=error; steps='["notes"]'; message="\"The verifier's answer isn't the JSON asked for.\""; fi
    pick=$(printf '{ "pick": { "sessionKey": "%s", "file": "%s", "inclusion": %s, "sampling": "%s", "stratum": "claude|opus|%s", "projectID": "acme/notes-mac" }, "status": "%s", "message": %s, "steps": %s }' \
        "$key" "$CLAUDE_NOTESMAC/$id.jsonl" "$inclusion" "$sampling" "$r" "$status" "$message" "$steps")
    if (( i > 30 )); then picks_a+=("$pick"); else picks_b+=("$pick"); fi
done
batch_file() { # id, created, picks, clustered, candidates
    file "$ANALYSIS/batches/$1.json" <<EOF
{ "schema": 1, "runID": "$1", "createdAt": "$2", "filter": {}, "size": 30, "seed": 1759312800000, "fixed": false,
  "notesAgent": { "harness": "claude-code", "model": "opus", "effort": "high", "mode": "call" },
  "matchingAgent": { "harness": "claude-code", "model": "sonnet", "effort": "high", "mode": "call" },
  "language": "en", "sessions": [ $3 ], "spotCheck": [], "candidates": $5, "clustered": $4, "paused": false }
EOF
}
batch_file "$BATCH_A" "$(ago 40H)" "$(join "${picks_a[@]}")" true '["asset-catalog-hand-edit"]'
batch_file "$BATCH_B" "$(ago 4H)" "$(join "${picks_b[@]}")" false '[]'
analysis_run() { # id, created, ended, done, failed
    file "$DEMO/.akit/lab/$1/run.json" <<EOF
{"schema":1,"id":"$1","kind":"analysis","title":"Error analysis: all projects · 30 sessions","createdAt":"$2","folder":"$DEMO",
 "environment":"background","akit":"$AKIT","sessionID":"00000000-0000-0000-0000-0000000000a1","batch":"$1","keep":false}
EOF
    file "$DEMO/.akit/lab/$1/state.json" <<EOF
{"status":"finished","phase":"metrics","startedAt":"$2","updatedAt":"$3"}
EOF
    file "$DEMO/.akit/lab/$1/result.json" <<EOF
{"schema":1,"batch":{"done":$4,"failed":$5,"total":30,"paused":false}}
EOF
}
analysis_run "$BATCH_A" "$(ago 40H)" "$(ago 38H)" 30 0
analysis_run "$BATCH_B" "$(ago 4H)" "$(ago 3H)" 28 2

# Everyday Claude Code sessions of notes-mac with what Insights, Usage and the session Overview
# read: a skill listing, responses with ids and cache tokens, skill calls, and the cost a run
# saves when it exits (Insights: owners, recommendations, the skills table; Usage: Cost).
CC_VERSION=2.1.300
day_at() { date -u -v-"$1"d -v"$2"H -v"$3"M -v0S +%Y-%m-%dT%H:%M:%S.000Z; }  # days ago, hour, minute (UTC)
json_text() { sed 's/\\/\\\\/g; s/"/\\"/g' "$1" | awk '{ printf "%s\\n", $0 }'; }  # a file as the inside of a JSON string
rep() { local k; for ((k = 0; k < $1; k++)); do printf '%s' "$2"; done; }  # count, text
# The skills Claude Code lists in notes-mac: the auto skills of its layers and the two own ones.
LISTED=(tdd code-review swiftui-patterns swift-testing commit-message release-notes)
LISTING=""
for name in "${LISTED[@]}"; do
    skill_file="$BRAIN/skills/$name/SKILL.md"; [[ -f $skill_file ]] || skill_file="$DEMO/.agents/skills/$name/SKILL.md"
    LISTING+="- $name: $(sed -n 's/^description: //p' "$skill_file")\n"
done
LISTING="${LISTING%\\n}"
# Lines of one session; SID, CWD and AT (the time of the next lines) are set by the caller.
entry() { # type, uuid, the rest of the line's fields
    printf '{"type":"%s","cwd":"%s","sessionId":"%s","version":"%s","timestamp":"%s","uuid":"%s-%s",%s}\n' "$1" "$CWD" "$SID" "$CC_VERSION" "$AT" "$2" "${SID: -4}" "$3"
}
prompt() { entry user "$1" "\"message\":{\"role\":\"user\",\"content\":\"$2\"}"; }  # uuid, text
skill_listing() {
    entry attachment L "\"attachment\":{\"type\":\"skill_listing\",\"isInitial\":true,\"names\":[\"$(join "${LISTED[@]}" | sed 's/,/","/g')\"],\"content\":\"$LISTING\",\"skillCount\":${#LISTED[@]}}"
}
# A response: n, context tokens it was sent with (mostly read from the cache), output tokens, content blocks.
answer() {
    entry assistant "a$1" "\"message\":{\"id\":\"msg_${SID: -4}_$1\",\"role\":\"assistant\",\"model\":\"claude-opus-4-5\",\"content\":[$4],\"usage\":{\"input_tokens\":180,\"cache_read_input_tokens\":$(($2 - 1080)),\"cache_creation_input_tokens\":900,\"output_tokens\":$3}}"
}
say() { printf '{"type":"text","text":"%s"}' "$1"; }
call() { printf '{"type":"tool_use","id":"toolu_%s_%s","name":"%s","input":{%s}}' "${SID: -4}" "$1" "$2" "$3"; }  # n, tool, the fields of its input
result() { # n, text, "error" for a failed call
    entry user "r$1" "\"message\":{\"role\":\"user\",\"content\":[{\"type\":\"tool_result\",\"tool_use_id\":\"toolu_${SID: -4}_$1\",$( [[ ${3:-} == error ]] && echo '"is_error":true,')\"content\":\"$2\"}]}"
}
slash() { entry user "$1" "\"message\":{\"role\":\"user\",\"content\":\"<command-message>$2</command-message>\\n<command-name>/$2</command-name>\"}"; }  # uuid, skill
# What the process saved when it exited: start (epoch seconds), minutes, dollars.
cost_state() {
    printf '{"type":"cost-state","sessionId":"%s","totalCostUSD":%s,"startTime":%d,"totalDuration":%d,"modelUsage":{"claude-opus-4-5":{"costUSD":%s}}}\n' "$SID" "$3" "$(($1 * 1000))" "$(($2 * 60000))" "$3"
}
ai_title() { printf '{"type":"ai-title","aiTitle":"%s"}\n' "$1"; }

# 24 sessions, one a day from 3 to 26 days ago. The model calls tdd often, swiftui-patterns,
# swift-testing and commit-message sometimes, and never code-review (base lists it as auto: a
# layer patch) or release-notes (installed by hand: an advice); you run both with /name.
CWD="$NOTESMAC"
everyday=("Add note pinning" "Fix the empty state of the list" "Add a word count to the editor" "Move settings into a sheet"
          "Add an export menu" "Fix the window restore bug" "Add tags to notes" "Speed up the search" "Add a trash folder"
          "Fix the date format" "Add drag and drop for attachments" "Clean up the toolbar")
for i in $(seq 1 24); do
    SID=$(printf '8e1a0000-0000-4000-8000-0000000000%02d' "$i"); d=$((i + 2)); title="${everyday[$((i % 12))]}"
    context=$((14200 + i % 7 * 600)); n=0
    step() { n=$((n + 1)); context=$((context + 1100)); AT="$(day_at "$d" 10 "$n")"; }
    {
        AT="$(day_at "$d" 10 0)"
        prompt u1 "$title"
        skill_listing
        step; answer $n $context 60 "$(say "I'll look at the code first.")"
        if (( i % 2 == 0 )); then
            step; answer $n $context 40 "$(call $n Skill '"skill":"tdd"')"; result $n "Launching skill: tdd"
        fi
        if (( i % 3 == 0 )); then
            step; answer $n $context 40 "$(call $n Skill '"skill":"swiftui-patterns"')"; result $n "Launching skill: swiftui-patterns"
        fi
        if (( i % 6 == 1 )); then
            step; answer $n $context 40 "$(call $n Skill '"skill":"swift-testing"')"; result $n "Launching skill: swift-testing"
        fi
        step; answer $n $context 50 "$(call $n Read "\"file_path\":\"$CWD/Sources/NotesList.swift\"")"; result $n "struct NotesList: View { }"
        step; answer $n $context 320 "$(call $n Edit "\"file_path\":\"$CWD/Sources/NotesList.swift\",\"old_string\":\"View { }\",\"new_string\":\"View { List { } }\"")"; result $n "The file has been updated."
        step; answer $n $context 40 "$(call $n Bash '"command":"make test"')"; result $n "Test run with 14 tests passed."
        if (( i % 8 == 5 )); then
            step; answer $n $context 40 "$(call $n Skill '"skill":"commit-message"')"; result $n "Launching skill: commit-message"
        fi
        step; answer $n $context 90 "$(say "Done: the change is in and the tests pass.")"
        if (( i % 6 == 3 )); then step; slash u2 code-review; step; answer $n $context 400 "$(say "The diff looks right; no findings.")"; fi
        if (( i % 12 == 10 )); then step; slash u3 release-notes; step; answer $n $context 300 "$(say "Release notes drafted.")"; fi
        cost_state "$(date -u -v-"$d"d -v10H -v0M -v0S +%s)" 25 "0.$((38 + i % 5 * 11))"
        ai_title "$title"
    } | file "$CLAUDE_NOTESMAC/$SID.jsonl"
    # Last changed on its own day, so the sessions list keeps today's on top.
    touch -t "$(date -v-"$d"d +%Y%m%d%H%M)" "$CLAUDE_NOTESMAC/$SID.jsonl"
done

# Today's session, written last so it is the first in the sessions list. It also records what
# Claude Code sent before the first message (prompt_snapshot: system prompt and tools; rules
# file, skills, subagents, MCP instructions), so its Overview tab draws the context map with
# used, unused and always-loaded parts, and its System Prompt tab has text. The repeated lines
# only give the parts the sizes they have in a real session.
SID=8e1a0000-0000-4000-8000-000000000099
habits='- Read a file before you change it, and change only what the task needs.\n- Run the tests of the project after a change and say plainly when they fail.\n- Prefer the dedicated tool over a shell command when both can do the job.\n- Never print or copy secrets: tokens, keys and passwords stay where they are.\n- Ask before anything that is hard to undo: deleting files, rewriting history, pushing.\n- Keep answers short; lead with the result and name the files you changed.\n'
usage_notes='\n\nUsage notes:\n- Paths are absolute; a relative path is refused.\n- The call fails with a clear message when the target is missing, so check before you guess.\n- Output over the size limit is cut; ask for a narrower range in that case.\n- Several independent calls can go in one response and run side by side.'
tool() { # name, description, properties of its input, how many times the usage notes repeat
    printf '{"name":"%s","description":"%s%s","input_schema":{"type":"object","properties":{%s},"additionalProperties":false}}' "$1" "$2" "$(rep "$4" "$usage_notes")" "$3"
}
text_field() { printf '"%s":{"type":"string","description":"%s"}' "$1" "$2"; }
TOOLS=$(join \
    "$(tool Read "Reads a file from the disk, with line numbers." "$(text_field file_path "The file to read")" 3)" \
    "$(tool Edit "Replaces one exact piece of text in a file." "$(text_field file_path "The file to change"),$(text_field old_string "The text to replace"),$(text_field new_string "The new text")" 3)" \
    "$(tool Write "Writes a file, replacing what was there." "$(text_field file_path "The file to write"),$(text_field content "Its whole content")" 2)" \
    "$(tool Bash "Runs a shell command and returns its output." "$(text_field command "The command to run"),$(text_field description "What it does, in a few words")" 5)" \
    "$(tool Grep "Searches file contents with a regular expression." "$(text_field pattern "The expression"),$(text_field path "Where to search")" 3)" \
    "$(tool Skill "Runs one of the listed skills by name." "$(text_field skill "The name of the skill"),$(text_field args "Arguments for it")" 1)" \
    "$(tool Glob "Finds files by a name pattern." "$(text_field pattern "The pattern, like **/*.swift")" 2)" \
    "$(tool Agent "Starts a subagent for a task with many steps." "$(text_field subagent_type "Which subagent"),$(text_field prompt "The task")" 5)" \
    "$(tool WebFetch "Fetches a web page and answers a question about it." "$(text_field url "The page"),$(text_field prompt "The question")" 3)" \
    "$(tool WebSearch "Searches the web." "$(text_field query "The search text")" 2)" \
    "$(tool TodoWrite "Keeps a list of the steps of the task." "$(text_field todos "The steps and their state")" 4)" \
    "$(tool NotebookEdit "Replaces one cell of a notebook." "$(text_field notebook_path "The notebook"),$(text_field new_source "The new cell")" 2)" \
    "$(tool mcp__github__get_issue "Reads one issue of a repository." "$(text_field repo "owner/name"),$(text_field number "The number of the issue")" 2)" \
    "$(tool mcp__github__list_issues "Lists the issues of a repository." "$(text_field repo "owner/name"),$(text_field state "open or closed")" 2)" \
    "$(tool mcp__github__create_pull_request "Opens a pull request." "$(text_field repo "owner/name"),$(text_field title "Its title"),$(text_field head "The branch")" 2)" \
    "$(tool mcp__github__search_code "Searches code across repositories." "$(text_field query "The search text")" 2)" \
    "$(tool mcp__playwright__browser_navigate "Opens a page in the browser." "$(text_field url "The page")" 2)" \
    "$(tool mcp__playwright__browser_click "Clicks an element of the page." "$(text_field element "What to click")" 2)" \
    "$(tool mcp__playwright__browser_type "Types text into a field." "$(text_field element "The field"),$(text_field text "The text")" 2)" \
    "$(tool mcp__playwright__browser_snapshot "Returns the page as an accessibility tree." "" 2)" \
    "$(tool mcp__playwright__browser_take_screenshot "Takes a picture of the page." "$(text_field filename "Where to save it")" 2)")
SYSTEM_PROMPT=$(join \
    "\"You are Claude Code, a coding agent that works in the terminal of the user.\\n\\nYou help with software work: reading code, changing it, running commands and explaining what you did. You work in the folder the user started you in and use the tools below to look at files and to act. When a request is unclear, ask one short question instead of guessing.\"" \
    "\"# Doing tasks\\n\\n$(rep 5 "$habits")\"" \
    "\"# Using your tools\\n\\n$(rep 6 "$habits")\"" \
    "\"# Tone and style\\n\\n$(rep 4 "$habits")\"" \
    "\"# Environment\\n\\nWorking directory: $CWD\\nIs a git repository: true\\nPlatform: darwin\"")
{
    AT="$(ago 26M)"
    prompt u1 "Add a tags filter to the notes list. Keep the search field as it is."
    entry attachment I "\"attachment\":{\"type\":\"instructions\",\"files\":[{\"path\":\"$CWD/AGENTS.md\",\"type\":\"Project\",\"content\":\"$(json_text "$CWD/AGENTS.md")\"}]}"
    skill_listing
    entry attachment G "\"attachment\":{\"type\":\"agent_listing_delta\",\"addedTypes\":[\"general-purpose\",\"Explore\",\"Plan\"],\"addedLines\":[\"- general-purpose: Researches a question or carries out a task with many steps, with every tool.\",\"- Explore: Searches a codebase and reports where things are; it reads and never edits.\",\"- Plan: Designs the steps of a change and names the files and the risks before any code is written.\"]}"
    entry attachment M "\"attachment\":{\"type\":\"mcp_instructions_delta\",\"addedNames\":[\"github\",\"playwright\"],\"addedBlocks\":[\"## github\\nIssues, pull requests and code search of GitHub repositories. Name the repository as owner/name.\",\"## playwright\\nDrives a browser. Take a snapshot of the page before you click or type.\"]}"
    entry attachment P "\"attachment\":{\"type\":\"prompt_snapshot\",\"systemPrompt\":[$SYSTEM_PROMPT],\"tools\":[$TOOLS]}"
    AT="$(ago 25M)"; answer 1 9600 80 "$(say "I'll write a failing test for the filter first."),$(call 1 Skill '"skill":"tdd"')"; result 1 "Launching skill: tdd"
    answer 2 10300 50 "$(call 2 mcp__github__get_issue '"repo":"acme/notes-mac","number":"42"')"; result 2 "#42 Filter notes by tag: a row of tags above the list; picking one keeps only its notes."
    AT="$(ago 24M)"; answer 3 11100 50 "$(call 3 Read "\"file_path\":\"$CWD/Sources/NotesList.swift\"")"; result 3 "struct NotesList: View {\\n    @Query(sort: \\\\.modified) var notes: [Note]\\n    @State private var search = \\\"\\\"\\n}"
    answer 4 11800 40 "$(call 4 Grep '"pattern":"tags","path":"Sources"')"; result 4 "Sources/Note.swift:7:    var tags: [String] = []"
    AT="$(ago 22M)"; answer 5 12500 420 "$(call 5 Write "\"file_path\":\"$CWD/Tests/TagFilterTests.swift\",\"content\":\"@Test func keepsOnlyNotesWithTheTag() { }\"")"; result 5 "File created."
    answer 6 13500 40 "$(call 6 Bash '"command":"make test"')"; result 6 "Exit code 1\\nTests/TagFilterTests.swift:9: error: cannot find 'TagFilter' in scope" error
    AT="$(ago 19M)"; answer 7 14300 610 "$(call 7 Edit "\"file_path\":\"$CWD/Sources/NotesList.swift\",\"old_string\":\"@State private var search\",\"new_string\":\"@State private var tag: String?\\n    @State private var search\"")"; result 7 "The file has been updated."
    answer 8 15400 40 "$(call 8 Bash '"command":"make test"')"; result 8 "Test run with 15 tests passed."
    AT="$(ago 17M)"; answer 9 16100 40 "$(call 9 Bash '"command":"make build"')"; result 9 "Build succeeded."
    answer 10 16700 120 "$(say "The notes list has a tags filter above it now, and the search field is unchanged. The new test and the build pass.")"
    cost_state "$(date -u -v-26M +%s)" 12 0.74
    ai_title "Add a tags filter to the notes list"
} | file "$CLAUDE_NOTESMAC/$SID.jsonl"

# The session index (the fix's before/after reads it), then the checks over the sessions.
"$AKIT" sessions import --quiet >/dev/null 2>&1 || true
verdicts() { # checker, "key positive"...
    local by="$1" first=1 entry parts; shift
    for entry in "$@"; do
        read -r -a parts <<< "$entry"
        (( first )) || printf ',\n'
        first=0
        printf '  "%s": { "positive": %s, "steps": %s, "toughCall": false, "severe": false, "by": "%s", "version": 1 }' \
            "${parts[0]}" "${parts[1]}" "$( [[ ${parts[1]} == true ]] && echo '[7]' || echo '[]')" "$by"
    done
}
{
    printf '{ "modeID": "large-file-read-whole", "modeVersion": 1, "kind": "mechanical", "verdicts": {\n'
    verdicts code "${large[@]}"
    for i in $(seq 1 48); do
        positive=false; (( i % 7 == 0 )) && positive=true
        printf ',\n  "claude:demo-%02d": { "positive": %s, "steps": [], "toughCall": false, "severe": false, "by": "code", "version": 1 }' "$i" "$positive"
    done
    printf '\n} }\n'
} | file "$ANALYSIS/checks/large-file-read-whole.json"
{
    printf '{ "modeID": "no-build-after-swift-edit@judge", "modeVersion": 2, "judge": "claude-code|opus|1", "verdicts": {\n'
    verdicts judge "${judged[@]}"
    printf '\n} }\n'
} | file "$ANALYSIS/checks/no-build-after-swift-edit_judge.json"
{
    printf '{ "modeID": "user-constraint-violated@judge", "modeVersion": 1, "judge": "claude-code|sonnet|1", "verdicts": {\n'
    verdicts judge "${constraint[@]}"
    printf '\n} }\n'
} | file "$ANALYSIS/checks/user-constraint-violated_judge.json"
file "$ANALYSIS/labels/judges.json" <<'EOF'
{ "no-build-after-swift-edit": { "harness": "claude-code", "model": "opus", "effort": "high", "mode": "call" },
  "user-constraint-violated": { "harness": "claude-code", "model": "sonnet", "effort": "high", "mode": "call" } }
EOF
bools() { # count, how many true
    local out=() k
    for k in $(seq 1 "$1"); do if (( k <= $2 )); then out+=(true); else out+=(false); fi; done
    echo "[$(join "${out[@]}")]"
}
file "$ANALYSIS/labels/validation.json" <<EOF
{ "no-build-after-swift-edit": [
    { "modeID": "no-build-after-swift-edit", "modeVersion": 2, "checker": "judge|claude-code|opus|1", "set": "dev",
      "labels": { "onPositives": $(bools 10 9), "onNegatives": $(bools 12 1) }, "tprLow": 0.596, "tnrLow": 0.646, "toughLeftOut": 1, "unchecked": 0, "at": "$(ago 50H)" },
    { "modeID": "no-build-after-swift-edit", "modeVersion": 2, "checker": "judge|claude-code|opus|1", "set": "test",
      "labels": { "onPositives": $(bools 34 33), "onNegatives": $(bools 36 1) }, "tprLow": 0.851, "tnrLow": 0.858, "toughLeftOut": 2, "unchecked": 1, "at": "$(ago 48H)" } ],
  "user-constraint-violated": [
    { "modeID": "user-constraint-violated", "modeVersion": 1, "checker": "judge|claude-code|sonnet|1", "set": "test",
      "labels": { "onPositives": $(bools 22 19), "onNegatives": $(bools 24 3) }, "tprLow": 0.666, "tnrLow": 0.690, "toughLeftOut": 0, "unchecked": 0, "at": "$(ago 47H)" } ] }
EOF
split_keys() { local out=() k; for k in $(seq "$1" "$2"); do out+=("\"claude:label-$k\""); done; echo "[$(join "${out[@]}")]"; }
file "$ANALYSIS/labels/splits.json" <<EOF
{ "no-build-after-swift-edit": { "train": $(split_keys 1 9), "dev": $(split_keys 10 33), "test": $(split_keys 34 105) } }
EOF
file "$ANALYSIS/fixes/no-build-after-swift-edit.json" <<EOF
{ "modeID": "no-build-after-swift-edit", "layer": "claude-md",
  "text": "After editing Swift files or project settings, build the app (make build) before you say the work is done. If the build fails, say so.",
  "exemplars": [ { "sessionKey": "claude:6a1d0c3e-1111-4c1e-9b2a-000000000001", "noteID": "n1" }, { "sessionKey": "claude:$C", "noteID": "n1" } ],
  "expectedChange": "A make build or xcodebuild call between the last Swift edit and the final report.",
  "helpedCriterion": "The judge finds the mode in fewer sessions after T: P(after < before) of at least 0.95, 15+ sessions a side.",
  "createdAt": "$(ago 31H)" }
EOF

# Controlled evals: two tasks in notes-mac and finished cells of a baseline and a variant.
git -C "$NOTESMAC" add -A
git -C "$NOTESMAC" commit -qm "Start notes-mac" || true
BASE=$(git -C "$NOTESMAC" rev-parse HEAD)
TASK1=show-pinned-notes-at-the-top-a1b2
TASK2=rename-the-archive-tab-to-done-c3d4
file "$DEMO/.akit/lab/evals/tasks/$TASK1.json" <<EOF
{ "schema": 1, "id": "$TASK1", "title": "Show pinned notes at the top", "repo": "$NOTESMAC", "base": "$BASE",
  "prompt": "Show pinned notes at the top", "source": { "session": { "key": "claude:$C" } }, "modeID": "no-build-after-swift-edit",
  "oracle": { "tests": { "command": "make test" } }, "reference": "$BASE", "referenceGreen": true, "createdAt": "$(ago 26H)" }
EOF
file "$DEMO/.akit/lab/evals/tasks/$TASK2.json" <<EOF
{ "schema": 1, "id": "$TASK2", "title": "Rename the Archive tab to Done", "repo": "$NOTESMAC", "base": "$BASE",
  "prompt": "Rename the Archive tab to Done and read the settings file to find where tabs are named.", "source": { "reproduction": {} },
  "modeID": "large-file-read-whole", "oracle": { "assertion": { "modeID": "large-file-read-whole" } }, "createdAt": "$(ago 25H)" }
EOF
# A layer set, so Brain → backend-node → Evaluate… and Evals → Run Cells… on a layer have tasks.
"$AKIT" analysis control layer-set backend-node add "$TASK1,$TASK2" >/dev/null
PATCH='{ "file": "CLAUDE.md", "text": "After editing Swift files or project settings, build the app (make build) before you say the work is done. If the build fails, say so." }'
AGENT='{ "harness": "claude-code", "model": "sonnet", "effort": "high", "mode": "call" }'
cell() { # n, task, title, setup, repeat, passed, oracle, changed test files json
    local id setup
    id=$(printf '20261001-07%02d00-c%03d' "$1" "$1")
    setup="{ \"name\": \"$4\", \"agent\": $AGENT, \"readOnly\": false }"
    [[ $4 == variant ]] && setup="{ \"name\": \"variant\", \"agent\": $AGENT, \"patch\": $PATCH, \"readOnly\": false }"
    file "$DEMO/.akit/lab/$id/run.json" <<EOF
{"schema":1,"id":"$id","kind":"control","title":"Control $3 · $4 · $5/3","createdAt":"$(ago $((300 - $1 * 5))M)","folder":"$NOTESMAC",
 "environment":"background","akit":"$AKIT","sessionID":"00000000-0000-0000-0000-00000000c$(printf '%03d' "$1")","agent":$AGENT,
 "repo":"$NOTESMAC","repeatIndex":$5,"repeats":3,"keep":false,"controlTask":"$2","controlSetup":$setup}
EOF
    file "$DEMO/.akit/lab/$id/state.json" <<EOF
{"status":"finished","phase":"metrics","startedAt":"$(ago $((299 - $1 * 5))M)","updatedAt":"$(ago $((296 - $1 * 5))M)"}
EOF
    file "$DEMO/.akit/lab/$id/result.json" <<EOF
{"schema":1,"control":{"key":"demo-cell-$1","passed":$6,"oracle":"$7","testsDropped":false,"changedTestFiles":$8,"leaks":[],"checkSteps":[]}}
EOF
}
n=0
for rep in 1 2 3; do
    for setup in baseline variant; do
        n=$((n + 1)); passed=false; changed='[]'
        if [[ $setup == variant || $rep == 2 ]]; then passed=true; fi
        if [[ $setup == variant && $rep == 3 ]]; then changed='["Tests/NotesListTests.swift"]'; fi
        oracle='tests failed (exit 1)'; [[ $passed == true ]] && oracle='tests passed (exit 0)'
        cell $n "$TASK1" "Show pinned notes at the top" $setup $rep $passed "$oracle" "$changed"
        n=$((n + 1)); passed=true
        if [[ $setup == baseline && $rep == 2 ]]; then passed=false; fi
        oracle='large-file-read-whole: not present'; [[ $passed == false ]] && oracle='large-file-read-whole: present (Package.resolved, 48 KB, no range)'
        cell $n "$TASK2" "Rename the Archive tab to Done" $setup $rep $passed "$oracle" '[]'
    done
done

# Review: a project profile and one finished review of a made-up merge request
# (Review screen: requests, only in AKit, gaps). Dates without fractions: review's JSON reads ISO 8601.
rago() { date -u -v-"$1" +%Y-%m-%dT%H:%M:%SZ; }
REVIEWRUN="$DEMO/.akit/local/review/runs/20261015-091500-orders-service-42"
HEADSHA=4f2c9e1b7a6d3c5e8f0a1b2c3d4e5f60718293a4
file "$DEMO/.akit/local/review/projects/orders-service.yaml" <<'EOF'
project: orders-service
gitlab: { host: https://gitlab.example.com, project_path: shop/orders-service }
checkout: ~/Projects/orders-service
tracker: { kind: azure-devops, org: example-org, project: Orders }
mcp:
  servers: [gitlab, azure-devops]
default_scenario: bugfix
knowledge: [~/notes/orders]
gather:
  - { name: tests, run: "dotnet test --no-build", timeout_s: 600 }
constraints:
  - "Public DTOs in Contracts/ change only in backward-compatible ways"
path_instructions:
  - { paths: ["**/*.generated.cs"], ignore: true }
review: { max_inline: 5 }
EOF
file "$REVIEWRUN/worktree/.git" <<<"gitdir: $DEMO/Projects/orders-service/.git/worktrees/42"
file "$REVIEWRUN/worktree/src/Auth/AuthMiddleware.cs" <<'EOF'
namespace Orders.Auth;

public sealed class AuthMiddleware(RequestDelegate next, ILogger<AuthMiddleware> logger)
{
    public async Task InvokeAsync(HttpContext context)
    {
        var header = context.Request.Headers.Authorization.ToString();
        logger.LogInformation("Auth: {Header}", header);
        if (string.IsNullOrEmpty(header))
        {
            context.Response.StatusCode = 401;
            return;
        }
        var token = header["Bearer ".Length..];
        context.Items["token"] = token;
        await next(context);
    }
}
EOF
file "$REVIEWRUN/run.json" <<EOF
{"version":1,"id":"20261015-091500-orders-service-42","created":"$(rago 3H)",
 "mergeRequest":{"host":"https://gitlab.example.com","projectPath":"shop/orders-service","iid":42},"project":"orders-service",
 "scenario":{"value":"bugfix","source":"project"},
 "checks":["Is the cause fixed, not the symptom (from the repro steps)?","Does a regression test reproduce the bug?"],
 "contextRequired":["wi","full_files"],
 "roles":[
  {"id":"bug-hunter","source":"built-in","reason":"required by bugfix","minSeverity":"medium","maxFindings":3,"needs":["diff"],"doNotComment":[],"sha256":"0"},
  {"id":"requirements","source":"built-in","reason":"required by bugfix","minSeverity":"medium","maxFindings":3,"needs":["wi"],"doNotComment":[],"sha256":"0"},
  {"id":"tests","source":"built-in","reason":"required by bugfix","minSeverity":"medium","maxFindings":3,"needs":["tests"],"doNotComment":[],"sha256":"0"},
  {"id":"security","source":"brain","reason":"optional, turned on","minSeverity":"medium","maxFindings":3,"needs":["diff"],"doNotComment":[],"sha256":"0"}],
 "passes":{"value":{"model":"github-copilot/gpt-5.4-mini","thinking":""},"source":"brain"},
 "verifier":{"value":{"model":"github-copilot/claude-opus-5-5","thinking":"high"},"source":"brain"},
 "posting":{"marker":{"value":"🤖","source":"built-in"},"severityThreshold":{"value":"medium","source":"built-in"},
  "confidenceThreshold":{"value":0.8,"source":"built-in"},"maxInline":{"value":5,"source":"project"}},
 "capCredits":{"value":150,"source":"built-in"},
 "constraints":["Public DTOs in Contracts/ change only in backward-compatible ways"],
 "pathInstructions":[{"paths":["**/*.generated.cs"],"ignore":true}],"knowledge":["~/notes/orders"],
 "gather":[{"name":"tests","run":"dotnet test --no-build","timeoutSeconds":600}],"workItems":[4512],"headSHA":"$HEADSHA"}
EOF
file "$REVIEWRUN/status.json" <<EOF
{"stage":"planned","updated":"$(rago 170M)"}
EOF
file "$REVIEWRUN/passes.json" <<EOF
{"mainSession":"0b6f1c2a-1111-4a4a-9c9c-000000000042","verifierSession":"0b6f1c2a-2222-4a4a-9c9c-000000000042","estimate":64,
 "brief":"Intent: stop the token from reaching the log after bug #4512.\nTouched components: AuthMiddleware.\nAlready raised: bob asked why the header is logged (resolved).\nAcceptance criteria: no secret reaches a log; requests without a header get 401.\nFirst gaps: no test output for the middleware.",
 "passes":[
  {"name":"fetch","model":"github-copilot/gpt-5.4-mini","started":"$(rago 180M)","ended":"$(rago 179M)","usage":{"input":4800,"cached":0,"output":1400},"credits":6.2,"paths":[]},
  {"name":"brief","model":"github-copilot/gpt-5.4-mini","started":"$(rago 178M)","ended":"$(rago 177M)","usage":{"input":14200,"cached":0,"output":420},"credits":14.6,"paths":["../context/README.md","../context/diff.patch","../context/work-items/4512.md"]},
  {"name":"role-bug-hunter","role":"bug-hunter","model":"github-copilot/gpt-5.4-mini","started":"$(rago 177M)","ended":"$(rago 176M)","usage":{"input":3100,"cached":14500,"output":610},"credits":5.2,"paths":["src/Auth/AuthMiddleware.cs"]},
  {"name":"role-requirements","role":"requirements","model":"github-copilot/gpt-5.4-mini","started":"$(rago 176M)","ended":"$(rago 175M)","usage":{"input":1800,"cached":18400,"output":380},"credits":4.0,"paths":[]},
  {"name":"role-tests","role":"tests","model":"github-copilot/gpt-5.4-mini","started":"$(rago 175M)","ended":"$(rago 174M)","usage":{"input":2600,"cached":20100,"output":350},"credits":4.96,"paths":["tests/Auth/AuthMiddlewareTests.cs"]},
  {"name":"role-security","role":"security","model":"github-copilot/gpt-5.4-mini","started":"$(rago 174M)","ended":"$(rago 173M)","usage":{"input":1500,"cached":22800,"output":520},"credits":4.3,"paths":[]},
  {"name":"verifier","model":"github-copilot/claude-opus-5-5","started":"$(rago 173M)","ended":"$(rago 171M)","usage":{"input":21900,"cached":0,"output":900},"credits":22.8,"paths":["src/Auth/AuthMiddleware.cs"]}]}
EOF
file "$REVIEWRUN/findings.json" <<EOF
{"version":1,"created":"$(rago 170M)","source":"passes","findings":[
 {"id":"f1","kind":"finding","role":"security","file":"src/Auth/AuthMiddleware.cs","side":"new","line":8,"title":"Hlavička Authorization se celá zapisuje do logu",
  "evidence":"logger.LogInformation(\"Auth: {Header}\", header);","why":"Log jde do sdíleného úložiště logů; kdo ho čte, získá platný bearer token.",
  "severity":"high","confidence":0.88,"suggestion":"logger.LogDebug(\"Auth header present: {Present}\", header.Length > 0);","related":["bug-hunter:Header reaches the log"],
  "verifier":{"verdict":"confirmed","note":"Řádek 8 zapisuje celou hlavičku; kroky k reprodukci chyby ukazují stejný řádek.","confidence":0.93},"fingerprint":"7c1e9a04b2d6f318"},
 {"id":"f2","kind":"finding","role":"bug-hunter","file":"src/Auth/AuthMiddleware.cs","side":"new","line":14,"title":"Hlavička bez prefixu Bearer shodí požadavek",
  "evidence":"var token = header[\"Bearer \".Length..];","why":"Přihlášení Basic nebo krátká hlavička vyhodí ArgumentOutOfRangeException: 500 místo 401.",
  "severity":"medium","confidence":0.84,"related":[],"verifier":{"verdict":"confirmed","note":"Každá hlavička kratší než 7 znaků vyhodí výjimku."},"fingerprint":"a91f2c7d0e3b5a66"},
 {"id":"f3","kind":"finding","role":"tests","file":"src/Auth/AuthMiddleware.cs","side":"new","line":8,"title":"Žádný test nekontroluje, co se zapisuje do logu",
  "evidence":"logger.LogInformation","why":"Regresní test s falešným loggerem by token z logu udržel venku.","severity":"medium","confidence":0.72,"related":[],
  "verifier":{"verdict":"confirmed","note":"Oprávněné, ale příčinu opraví f1."},"fingerprint":"5d0c13e8a2f47b90"},
 {"id":"f4","kind":"ac","role":"requirements","side":"new","title":"Žádný tajný údaj se nedostane do logu","evidence":"","why":"kód: AuthMiddleware.cs:8 stále zapisuje hlavičku (f1)",
  "severity":"high","confidence":0.9,"related":[],"verifier":{"verdict":"confirmed","note":""},"fingerprint":"0e44c1d2b3a59f71"},
 {"id":"f5","kind":"finding","role":"requirements","file":"src/Auth/AuthMiddleware.cs","side":"new","line":11,"title":"Má chybějící hlavička vrátit 401, nebo projít k anonymním endpointům?",
  "evidence":"context.Response.StatusCode = 401;","why":"Work item neříká, zda /health zůstane otevřený.","severity":"medium","confidence":0.6,"related":[],
  "verifier":{"verdict":"question","note":"Zeptejte se, zda /health a /metrics musí zůstat anonymní."},"fingerprint":"c3b7e2a1d9f04e88"},
 {"id":"f6","kind":"finding","role":"bug-hunter","file":"src/Auth/AuthMiddleware.cs","side":"new","line":15,"title":"Token uložený v HttpContext.Items",
  "evidence":"context.Items[\"token\"] = token;","why":"Diagnostika může Items zapisovat do logu.","severity":"medium","confidence":0.65,"related":[],
  "verifier":{"verdict":"rejected","note":"Žádná cesta v kódu Items nezapisuje; spekulace bez místa úniku."},"fingerprint":"9e8d7c6b5a4f3e21"}]}
EOF
file "$REVIEWRUN/gaps.json" <<'EOF'
[{"id":"g1","system":"tests","needed":"Output of tests","why":"dotnet test failed to build in the worktree.","howToGet":"Check the command in the profile.","effect":"","reportedBy":"gather"},
 {"id":"g2","system":"azure-devops","needed":"Které endpointy zůstanou anonymní","why":"Work item #4512 je neuvádí.","howToGet":"Zeptejte se autora.","effect":"f5 je otázka, ne nález.","reportedBy":"role-requirements"}]
EOF
# What the passes asked Pi's MCP servers (Log…): made-up calls, no answers worth reading.
file "$REVIEWRUN/mcp/calls/fetch-1760520000000-0001.json" <<'EOF'
{"pass":"fetch","tool":"mcp__gitlab__get_merge_request","server":"gitlab","input":"{\"project_id\":\"shop/orders-service\",\"merge_request_iid\":42}","text":["{\"iid\":42}"],"isError":false}
EOF
file "$REVIEWRUN/mcp/calls/fetch-1760520001000-0002.json" <<'EOF'
{"pass":"fetch","tool":"mcp__gitlab__get_merge_request_diffs","server":"gitlab","input":"{\"project_id\":\"shop/orders-service\",\"merge_request_iid\":42}","text":["[]"],"isError":false}
EOF
file "$REVIEWRUN/mcp/calls/fetch-1760520002000-0003.json" <<'EOF'
{"pass":"fetch","tool":"mcp__ado__wit_get_work_item","server":"ado","input":"{\"id\":4512}","text":["{\"id\":4512}"],"isError":false}
EOF
file "$REVIEWRUN/mcp/calls/role-security-1760520100000-0001.json" <<'EOF'
{"pass":"role-security","tool":"mcp__context7__query-docs","server":"context7","input":"{\"libraryId\":\"/dotnet/aspnetcore\",\"query\":\"ILogger structured logging sensitive data\"}","text":["Docs about logging."],"isError":false}
EOF
file "$REVIEWRUN/mcp/blocked.jsonl" <<'EOF'
{"tool":"mcp__gitlab__create_note","pass":"role-bug-hunter","reason":"a review pass only reads"}
EOF
file "$REVIEWRUN/gitlab/snapshot.json" <<EOF
{"mergeRequest":{"iid":42,"title":"Stop logging the Authorization header (AB#4512)","description":"Fixes AB#4512.","state":"opened","author":"alice",
  "sourceBranch":"fix/4512-auth-log","targetBranch":"main","labels":["backend","security"],"webURL":"https://gitlab.example.com/shop/orders-service/-/merge_requests/42",
  "diffRefs":{"baseSHA":"1a2b3c4d","startSHA":"1a2b3c4d","headSHA":"$HEADSHA"}},
 "versions":[{"id":3,"headSHA":"$HEADSHA","baseSHA":"1a2b3c4d","startSHA":"1a2b3c4d"}],
 "diffs":[{"oldPath":"src/Auth/AuthMiddleware.cs","newPath":"src/Auth/AuthMiddleware.cs","diff":"@@ -5,10 +5,13 @@\n     public async Task InvokeAsync(HttpContext context)\n     {\n         var header = context.Request.Headers.Authorization.ToString();\n+        logger.LogInformation(\"Auth: {Header}\", header);\n         if (string.IsNullOrEmpty(header))\n         {\n             context.Response.StatusCode = 401;\n             return;\n         }\n+        var token = header[\"Bearer \".Length..];\n+        context.Items[\"token\"] = token;\n         await next(context);\n     }\n }\n","newFile":false,"renamedFile":false,"deletedFile":false,"tooLarge":false}],
 "discussions":[],"drafts":[],"user":"demo","gathered":"$(rago 179M)"}
EOF
SUMMARY='🤖 · souhrn · scénář **bugfix** · role `bug-hunter`, `requirements`, `tests`, `security`\n\n2 komentáře k řádkům diffu.\n\n### Otázky pro autora\n\n- `src/Auth/AuthMiddleware.cs:11`: Má chybějící hlavička vrátit 401, nebo projít k anonymním endpointům? — Zeptejte se, zda /health a /metrics musí zůstat anonymní.\n\n### Akceptační kritéria\n\n| Kritérium | Stav |\n|---|---|\n| Žádný tajný údaj se nedostane do logu | kód: AuthMiddleware.cs:8 stále zapisuje hlavičku (f1) |\n\n### Co chybělo\n\n- Které endpointy zůstanou anonymní: Work item #4512 je neuvádí.\n\n<sub>Zkontrolovaný commit 4f2c9e1b7a.</sub>'
POS='"baseSHA":"1a2b3c4d","startSHA":"1a2b3c4d","headSHA":"'"$HEADSHA"'","oldPath":"src/Auth/AuthMiddleware.cs","newPath":"src/Auth/AuthMiddleware.cs"'
file "$REVIEWRUN/requests.json" <<EOF
{"created":"$(rago 170M)","findingsVersion":1,"requests":[
 {"id":"r1","kind":"create","findingID":"f1","fingerprint":"7c1e9a04b2d6f318","role":"security","severity":"high","confidence":0.93,
  "file":"src/Auth/AuthMiddleware.cs","line":8,"position":{$POS,"newLine":8},
  "proposed":"🤖 · \`security\` · **vysoká** · jistota 0,93\n\n**Hlavička Authorization se celá zapisuje do logu**\n\nLog jde do sdíleného úložiště logů; kdo ho čte, získá platný bearer token.\n\n\`\`\`suggestion\nlogger.LogDebug(\"Auth header present: {Present}\", header.Length > 0);\n\`\`\`",
  "decision":"approved","movedByUser":false},
 {"id":"r2","kind":"create","findingID":"f2","fingerprint":"a91f2c7d0e3b5a66","role":"bug-hunter","severity":"medium","confidence":0.84,
  "file":"src/Auth/AuthMiddleware.cs","line":14,"position":{$POS,"newLine":14},
  "proposed":"🤖 · \`bug-hunter\` · **střední** · jistota 0,84\n\n**Hlavička bez prefixu Bearer shodí požadavek**\n\nPřihlášení Basic nebo krátká hlavička vyhodí ArgumentOutOfRangeException: 500 místo 401.",
  "decision":"pending","movedByUser":false},
 {"id":"r3","kind":"summary","proposed":"$SUMMARY","decision":"pending","movedByUser":false}],
 "placements":[{"findingID":"f1","place":"inline","reason":"Confirmed and over the thresholds."},
  {"findingID":"f2","place":"inline","reason":"Confirmed and over the thresholds."},
  {"findingID":"f3","place":"onlyInAKit","reason":"Confidence 0.72 is below 0.80."},
  {"findingID":"f4","place":"matrix","reason":"A row of the acceptance-criteria matrix."},
  {"findingID":"f5","place":"question","reason":"Not enough context: a question to the author."},
  {"findingID":"f6","place":"onlyInAKit","reason":"Rejected by the verifier: Žádná cesta v kódu Items nezapisuje; spekulace bez místa úniku."}]}
EOF

# Review → New Review… → Local Workspace: a made-up clone of orders-service (its origin is the
# profile's GitLab project) on a feature branch with 2 commits since main and 2 uncommitted files.
LOCAL="$DEMO/work/orders-service"
mkdir -p "$LOCAL"
git -C "$LOCAL" init -q -b main
git -C "$LOCAL" remote add origin "https://gitlab.example.com/shop/orders-service.git"
file "$LOCAL/README.md" <<<"# orders-service"
file "$LOCAL/src/Orders/OrdersController.cs" <<'EOF'
namespace Orders;

public sealed class OrdersController(IOrderStore store)
{
    public IReadOnlyList<Order> List() => store.All();
}
EOF
git -C "$LOCAL" add -A && git -C "$LOCAL" commit -qm "Start orders-service"
git -C "$LOCAL" switch -q -c feature/4630-export-csv
file "$LOCAL/src/Orders/OrderCsv.cs" <<'EOF'
namespace Orders;

public static class OrderCsv
{
    public static string Write(IEnumerable<Order> orders) =>
        "id,total\n" + string.Join("\n", orders.Select(o => $"{o.Id},{o.Total}"));
}
EOF
git -C "$LOCAL" add -A && GIT_AUTHOR_NAME="Alice" git -C "$LOCAL" commit -qm "Add a CSV export of orders (AB#4630)"
file "$LOCAL/tests/OrderCsvTests.cs" <<'EOF'
namespace Orders.Tests;

public class OrderCsvTests
{
    [Fact] public void WritesAHeader() => Assert.StartsWith("id,total", OrderCsv.Write([]));
}
EOF
git -C "$LOCAL" add -A && GIT_AUTHOR_NAME="Alice" git -C "$LOCAL" commit -qm "Test the CSV header"
# Not committed yet: a changed controller and a new file.
cat >> "$LOCAL/src/Orders/OrdersController.cs" <<<"// GET /orders.csv: OrderCsv.Write(store.All())"
file "$LOCAL/docs/export.md" <<<"Orders export as CSV: id and total."

# Knowledge base (Knowledge screen, guide knowledge.ru.md): the work world built from the sample
# base's content (KnowledgeSeed.swift, one source of made-up notes): two spaces with their
# settings, a note of every kind, committed. Maps come with step 2.3.
"$AKIT" kb seed --world work >/dev/null

# The repo that orders-api's note points at (repo: and files:), found under ~/Projects.
ORDERS="$DEMO/Projects/orders-api"
mkdir -p "$ORDERS" && git -C "$ORDERS" init -q
git -C "$ORDERS" remote add origin "git@example.com:shop/orders-api.git"
file "$ORDERS/src/events/order-created.ts" <<'EOF'
export type OrderCreated = { orderId: string; total: number };
EOF
git -C "$ORDERS" add -A && git -C "$ORDERS" commit -qm "Add the order created event"
echo "export const retries = 3;" >> "$ORDERS/src/events/order-created.ts"
git -C "$ORDERS" add -A && git -C "$ORDERS" commit -qm "Retry a failed publish three times"

# The other repos the notes name (repo:): billing and orders-db of payments, lint-examples of the
# space's missing-file example (an empty copy), so akit kb lint finds only the findings the space
# lint-examples has on purpose. No harness files: no screen lists them as projects.
for name in billing orders-db lint-examples; do
    mkdir -p "$DEMO/Projects/$name" && git -C "$DEMO/Projects/$name" init -q
    git -C "$DEMO/Projects/$name" remote add origin "git@example.com:shop/$name.git"
done

echo "Demo home: $DEMO"
