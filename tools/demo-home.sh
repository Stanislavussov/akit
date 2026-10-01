#!/usr/bin/env bash
# Builds a made-up home folder for README screenshots: a brain with a few layers and skills,
# two projects and some MCP servers. Nothing in it comes from a real machine.
#
#   tools/demo-home.sh /tmp/akit-demo      (then: make screenshots)
set -euo pipefail

DEMO="${1:?usage: tools/demo-home.sh DIR}"
AKIT="$(cd "$(dirname "$0")/.." && pwd)/AKitCore/.build/debug/akit"
[[ -x "$AKIT" ]] || (cd "$(dirname "$0")/../AKitCore" && swift build --product akit >/dev/null)
rm -rf "$DEMO" && mkdir -p "$DEMO"
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
skills: [tdd, code-review]
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

git -C "$BRAIN" add -A && git -C "$BRAIN" commit -qm "Add demo layers and skills"

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

# Stand-ins for the agents' commands, so the demo shows ~/.local/bin paths and made-up versions.
mkdir -p "$DEMO/.local/bin"
for pair in "claude:2.1.0 (Claude Code)" "pi:0.40.0" "codex:codex-cli 0.150.0" "opencode:1.18.0"; do
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
file "$DEMO/.codex/config.toml" <<'EOF'
[mcp_servers.context7]
command = "npx"
args = ["-y", "@upstash/context7-mcp"]
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
    "scope": "general", "origin": "emergent", "version": 2, "status": "active", "createdAt": "$(ago 26H)", "confirmedAt": "$(ago 25H)", "batchMatches": [] }
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

echo "Demo home: $DEMO"
