#!/usr/bin/env bash
# Screenshots for the in-app guides (docs/guides/images), from a made-up home
# (tools/demo-home.sh). No real data. The guides name them as ![caption](images/<name>.png).
#
#   make guide-screenshots      (or: tools/guide-screenshots.sh [name…] to redo only some)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# A short path: the screens show it.
DEMO="${AKIT_DEMO:-/tmp/akit-demo-home}"
OUT="$ROOT/docs/guides/images"
APP="$ROOT/build/Build/Products/Debug/AKit.app/Contents/MacOS/AKit"
[[ -x "$APP" ]] || { echo "Build first: make build" >&2; exit 1; }
ONLY=" $* "

# Unknown names first: a typo must not pass as "nothing to do".
KNOWN="$(sed -n 's/^shot \([a-z-]*\) .*/\1/p' "$0")"
for name in "$@"; do
    grep -qx "$name" <<<"$KNOWN" || { echo "No shot named $name. Known: $(echo $KNOWN)" >&2; exit 1; }
done
FAILED=0

"$ROOT/tools/demo-home.sh" "$DEMO" >/dev/null
DEMO="$(cd "$DEMO" && pwd -P)"
mkdir -p "$OUT"

# name, window size, flags… Value-less flags (--add, --capture) last; see DebugSnapshot.
shot() {
    local name="$1" size="$2"; shift 2
    [[ "$ONLY" == "  " || "$ONLY" == *" $name "* ]] || return 0
    # Only the demo's stand-in agent commands, never the ones on this Mac.
    if HOME="$DEMO" PATH="$DEMO/.local/bin:/usr/bin:/bin" perl -e 'alarm 90; exec @ARGV' "$APP" -ApplePersistenceIgnoreState YES \
        --snapshot "$OUT/$name.png" --brain "$DEMO/.akit/registry" --size "$size" --delay 4 --appearance light "$@" --demo >/dev/null 2>&1; then
        # One pixel per point (the capture has two): sharp enough to read, a quarter of the
        # bytes. A sheet is captured alone and is smaller than the window, so halve, don't fit.
        # On a display without Retina the capture already has one.
        if [[ "$(sips -g dpiWidth "$OUT/$name.png" | awk '/dpiWidth/ {print int($2)}')" == 144 ]]; then
            sips --resampleWidth "$(( $(sips -g pixelWidth "$OUT/$name.png" | awk '/pixelWidth/ {print $2}') / 2 ))" "$OUT/$name.png" >/dev/null
        fi
        echo "$name.png"
    else
        echo "FAILED $name" >&2
        FAILED=1
    fi
}
MAIN=1180x760
# Ids that tools/demo-home.sh makes.
MODE=no-build-after-swift-edit                              # active, a validated judge, a fix applied
DRAFT_SESSION=claude:7c0f5e2a-3333-4d6b-8e1f-000000000003   # Bootstrap: a draft with one note
BATCH_A=20260929-100000-ba01                                # before the fix
BATCH_B=20261001-080000-ba02                                # after it
TASK=show-pinned-notes-at-the-top-a1b2
CELL=20261001-071100-c011                                   # a variant cell that changed a test file
REVIEW=20261001-120000-demo

shot overview            $MAIN --section overview
# Only for this shot: Pi settings and MCP servers with a few mistakes, a stand-in MCP server
# command, and a stand-in pi that answers pi mcp list and pi auth check. Removed afterwards.
if [[ "$ONLY" == "  " || "$ONLY" == *" overview-pi-doctor "* ]]; then
    PI_BIN="$DEMO/.local/bin/pi"
    cp "$PI_BIN" "$PI_BIN.keep"
    cat > "$PI_BIN" <<'EOF'
#!/bin/sh
case "$1" in
  mcp) echo '{"servers": [{"name": "notes", "scope": "global", "enabled": true, "state": "connected", "tools": ["search", "read", "create", "tag"]}, {"name": "github", "scope": "global", "enabled": true, "state": "needs-auth", "tools": []}], "errors": []}' ;;
  auth) echo '{"status": "ready", "provider": "anthropic", "authType": "oauth"}' ;;
  *) echo "1.0.4" ;;
esac
EOF
    printf '#!/bin/sh\n' > "$DEMO/.local/bin/notes-mcp" && chmod +x "$DEMO/.local/bin/notes-mcp"
    printf '{\n  "defaultProvider": "anthropic",\n  "defaultModel": "claude-sonnet-4-5",\n  "defaultThinkingLevel": "hihg",\n  "showTokens": true\n}\n' > "$DEMO/.pi/agent/settings.json"
    printf '{"mcpServers": {\n  "notes": {"command": "notes-mcp"},\n  "github": {"url": "https://api.githubcopilot.com/mcp/", "headers": {"Authorization": "Bearer ${GITHUB_TOKEN}"}},\n  "browser": {"command": "playwright-mcp"}\n}}\n' > "$DEMO/.pi/agent/mcp.json"
fi
shot overview-pi-doctor  $MAIN --section overview --tab pi-doctor --delay 6 --capture
if [[ -e "${PI_BIN:-}.keep" ]]; then
    mv "$PI_BIN.keep" "$PI_BIN"
    rm -f "$DEMO/.local/bin/notes-mcp" "$DEMO/.pi/agent/settings.json" "$DEMO/.pi/agent/mcp.json"
fi
shot skills              $MAIN --section skills
shot skills-switch       $MAIN --section skills --query tdd --add
shot skills-invocation   $MAIN --section skills --tab invocation --select grilling
# Only for this shot: a global CLAUDE.md with AKit's core block, and an AGENTS.md above the
# projects that Claude Code skips (notes-mac has a CLAUDE.md). Removed again afterwards.
GLOBAL_MD="$DEMO/.claude/CLAUDE.md" ABOVE_MD="$DEMO/Projects/AGENTS.md"
[[ -e "$GLOBAL_MD" ]] && cp "$GLOBAL_MD" "$GLOBAL_MD.keep"
printf -- '# My rules\n\nAnswer in short sentences.\n\n## Commits\nImperative summary line, 72 characters at most.\n\n<!-- akit:core:start -->\n## Core\nRun the tests before you say a change is done.\n<!-- akit:core:end -->\n' > "$GLOBAL_MD"
printf -- '# Projects\n\nEvery project here uses git.\n' > "$ABOVE_MD"
shot instructions        $MAIN --section instructions --project notes-mac --select CLAUDE.md
# A private file in notes-mac that repeats the global Commits rule, and has its own Style.
LOCAL_MD="$DEMO/Projects/notes-mac/CLAUDE.local.md"
printf -- '## Commits\nImperative summary line, 72 characters at most.\n\n## Style\nSwiftUI views stay under 200 lines.\n' > "$LOCAL_MD"
shot instructions-duplicates $MAIN --section instructions --project notes-mac --tab duplicates --select CLAUDE.local.md
shot instructions-remove $MAIN --section instructions --project notes-mac --tab remove-copy --select CLAUDE.local.md
shot instructions-import $MAIN --section instructions --project notes-mac --tab import --select CLAUDE.local.md
shot instructions-edit $MAIN --section instructions --project notes-mac --tab edit --select CLAUDE.local.md
shot instructions-rewrite $MAIN --section instructions --project notes-mac --tab rewrite --select CLAUDE.local.md
shot instructions-move-global $MAIN --section instructions --project notes-mac --tab move-up --select CLAUDE.local.md
shot instructions-move-project $MAIN --section instructions --project notes-mac --tab move-down --select CLAUDE.md --query weather-app
rm -f "$LOCAL_MD"
rm -f "$ABOVE_MD"; if [[ -e "$GLOBAL_MD.keep" ]]; then mv "$GLOBAL_MD.keep" "$GLOBAL_MD"; else rm -f "$GLOBAL_MD"; fi
shot skills-invocation-all $MAIN --section skills --tab invocation-all --delay 3
# Only for these two: an older copy of commit-message in weather-app, so Claude Code and the
# others load two copies of it there. Removed again, so the other shots stay as they are.
DUP="$DEMO/Projects/weather-app/.agents/skills/commit-message"
mkdir -p "$DUP" && printf -- '---\nname: commit-message\ndescription: Write a commit message from the staged diff.\n---\n\nSummary line of 50 characters at most.\n' > "$DUP/SKILL.md"
shot skills-duplicates   $MAIN --section skills --tab duplicates --select commit-message
shot skills-resolve      $MAIN --section skills --tab resolve --select commit-message --delay 5
rm -rf "$DUP"
shot skills-move         $MAIN --section skills --tab move --select grilling
shot skills-move-check   $MAIN --section skills --tab move-check --select grilling
shot skills-move-preview $MAIN --section skills --tab move-preview --select grilling
shot skills-remove       $MAIN --section skills --tab remove --select grilling
shot skills-global       $MAIN --section skills --tab global --select note-templates
shot skillssh            $MAIN --section skillsSh --query tdd
shot skillssh-own        $MAIN --section skillsSh --query tdd --own-copy
shot mcp                 $MAIN --section mcp
shot mcp-add             $MAIN --section mcp --add
shot mcp-catalog         $MAIN --section mcp --tab catalog --query github --select github --add
# Fill the Form of a result: --select takes the server's registry name, not its title.
shot mcp-add-filled      $MAIN --section mcp --tab catalog --query github --select io.github.DiceHoldingsInc/dice-mcp --delay 8 --add --capture
shot mcp-add-preview     $MAIN --section mcp --tab preview --query '{"mcpServers":{"linear":{"type":"http","url":"https://mcp.linear.app/mcp"}}}' --add
shot mcp-switch          $MAIN --section mcp --tab switch
shot mcp-copy            $MAIN --section mcp --tab copy
shot mcp-tools           $MAIN --section mcp --select docs
shot sessions            $MAIN --section sessions
shot sessions-usage      $MAIN --section sessions --tab usage
shot sessions-analysis   $MAIN --section sessions --tab analysis
# Wider and taller: the Overview tab needs the room for the tiles and the whole context map.
shot sessions-overview   1720x900 --section sessions --tab overview
shot sessions-tools      1720x900 --section sessions --tab overview --query tools
shot sessions-prompt     $MAIN --section sessions --tab prompt
shot sessions-review     $MAIN --section sessions --add
shot usage               $MAIN --section usage --query month
shot brain               $MAIN --section brain
shot brain-layer         $MAIN --section brain --select take-home
shot brain-core          $MAIN --section brain --select core
shot brain-project       $MAIN --section brain --select project:github.com/acme/notes-mac
shot brain-setup         $MAIN --section brain --tab setup --project weather-app
shot brain-setup-preview $MAIN --section brain --tab setup --project weather-app --capture
shot brain-setup-local   $MAIN --section brain --tab setup --project weather-app --local-only
shot brain-evaluate      $MAIN --section brain --select backend-node --tab evaluate
shot insights            $MAIN --section insights --delay 8
shot insights-apply      $MAIN --section insights --delay 8 --add
shot insights-table      $MAIN --section insights --delay 8 --tab skills
shot insights-servers    $MAIN --section insights --delay 8 --tab servers --query open
shot insights-tools      $MAIN --section insights --delay 8 --tab tools
shot insights-unused     $MAIN --section insights --delay 8 --tab tools --query unused
shot insights-capture    $MAIN --section insights --delay 8 --capture
shot lab                 $MAIN --section lab --select $BATCH_B
shot lab-new             $MAIN --section lab --add
shot lab-new-batch       $MAIN --section lab --tab analysis --add
shot lab-review          $MAIN --section lab --select $REVIEW
shot lab-notes           $MAIN --section lab --select $REVIEW --tab notes
shot lab-recheck         $MAIN --section lab --select $REVIEW --tab recheck
shot lab-batch           $MAIN --section lab --select $BATCH_A
shot lab-control         $MAIN --section lab --select $CELL
shot lab-sends           $MAIN --section lab --tab sends
shot analysis-modes      $MAIN --section analysis --tab modes
shot analysis-mode       $MAIN --section analysis --tab modes --select large-file-read-whole
shot analysis-mode-judge $MAIN --section analysis --tab modes --select $MODE --query judge
shot analysis-mode-fix   $MAIN --section analysis --tab modes --select $MODE --query fix
shot analysis-fix-draft  $MAIN --section analysis --tab modes --select $MODE --query fix --add
shot analysis-review     $MAIN --section analysis --tab review
shot analysis-cluster    $MAIN --section analysis --tab review --add
shot analysis-bootstrap  $MAIN --section analysis --tab bootstrap
shot analysis-labeling   $MAIN --section analysis --tab bootstrap --select $DRAFT_SESSION --query 7
shot analysis-reports    $MAIN --section analysis --tab reports
# Wider: two matrices side by side.
shot analysis-report-matrix 1480x800 --section analysis --tab reports --select $BATCH_B --query $BATCH_A --add
shot analysis-report-diff   $MAIN --section analysis --tab reports --select $BATCH_B --query $BATCH_A --add --capture
shot analysis-evals      $MAIN --section analysis --tab evals
shot analysis-run-cells  $MAIN --section analysis --tab evals --select $TASK --add
shot analysis-run-cells-layer $MAIN --section analysis --tab evals --select $TASK --query layer --project backend-node --add
shot analysis-new-task   $MAIN --section analysis --tab evals --query fromSession
# Ask AKit's panel with a made-up chat (no model call); Insights imports first.
shot ask-akit            1380x800 --section insights --delay 8 --ask
shot settings            900x760 --settings
shot settings-lab        900x760 --tab lab --settings
shot settings-scrub      900x760 --tab scrub --settings
shot settings-add        900x760 --tab lab --settings --add
# The guide window itself: a search over every guide, and a section with a screenshot.
shot guide-search        820x900 --guide screens:start --query "usage"
shot guide-section       820x900 --guide screens:skills
# Review (guide review.ru.md): the made-up review of shop/orders-service!42 from tools/demo-home.sh.
REVIEWMR="https://gitlab.example.com/shop/orders-service/-/merge_requests/42"
shot review-run          1280x860 --section review --select 20261015-091500-orders-service-42 --tab requests
shot review-overview     1280x900 --section review --select 20261015-091500-orders-service-42
shot review-kb-propose   1280x860 --section review --select 20261015-091500-orders-service-42 --tab kb-propose
shot review-ask          1280x860 --section review --select 20261015-091500-orders-service-42 --tab ask
shot review-map          1440x900 --section review --select 20261015-091500-orders-service-42 --tab map --query consumer:shop/web-mfe:src/api/orders.ts
# Open Larger on the Flow: a sheet of 90% of the screen, at Fit.
shot review-flow-large   1440x900 --section review --select 20261015-091500-orders-service-42 --tab flow
shot review-new          $MAIN --section review --query "$REVIEWMR" --add
shot review-new-linked   $MAIN --section review --query "$REVIEWMR"$'\n'"https://gitlab.example.com/shop/web-mfe/-/merge_requests/17 3f9c2ab" --add
shot review-settings     $MAIN --section review --tab settings --add
shot review-roles        $MAIN --section review --tab roles --select security
shot review-scenarios    $MAIN --section review --tab scenarios --select bugfix
shot review-project-role $MAIN --section review --tab roles --project orders-service --select tests
shot review-quality      $MAIN --section review --tab quality
shot review-log          $MAIN --section review --tab log --select 20261015-091500-orders-service-42
# New Review… in Local Workspace mode: a query starting with "/" is the workspace path.
shot review-local        $MAIN --section review --query "$DEMO/work/orders-service" --add
# Base → Find…: the branches, the tag and the commits of the made-up clone.
shot review-local-find   $MAIN --section review --query "$DEMO/work/orders-service" --tab find-base --add
# Knowledge (guide knowledge.ru.md): the made-up base from tools/demo-home.sh.
shot knowledge           $MAIN --section knowledge --select payments/orders-api
shot knowledge-note      $MAIN --section knowledge --select payments/orders-api --tab edit
# Add Folder… with the demo's handbook folder (no git: kind folder, README's line as the description).
shot knowledge-add-folder 900x700 --section knowledge --select payments/orders-api --tab add-folder --query "~/Documents/payments-handbook"
# The notebook (notebook.ru.md): the sample base's Inbox tab, Today on a fixed day, New Tab…, the Plans tab and its drawing.
shot notebook            $MAIN --section notebook
shot notebook-today      $MAIN --section notebook --tab notebook-today --query 2026-10-26
shot notebook-new-tab    $MAIN --section notebook --tab notebook-new --query Ideas
shot notebook-plans      $MAIN --section notebook --select Plans
shot notebook-drawing    $MAIN --section notebook --tab notebook-draw-open --query 2026-10-24-retry
shot knowledge-obsidian-setup 900x600 --section knowledge --select payments/orders-api --tab obsidian-setup
shot knowledge-properties $MAIN --section knowledge --select payments/orders-api --tab properties
shot knowledge-kinds     $MAIN --section knowledge --select payments/orders-api --tab kinds
# A map (read only) from the demo base's seed: payments/maps/overview.
shot knowledge-map       $MAIN --section knowledge --tab map --select payments/maps/overview
# The same map in Edit: Excalidraw's tools and the pressed Edit button.
shot knowledge-map-edit  $MAIN --section knowledge --tab map-edit --select payments/maps/overview
# A block's note beside its map (as a click on the block orders-api), with its Relations.
shot knowledge-relations $MAIN --section knowledge --tab map --select block:blk-orders
# Rename… of the note billing to invoicing: the planned changes.
shot knowledge-rename    $MAIN --section knowledge --tab rename --select payments/billing --query invoicing
# The toolbar search for "order": its hits (note, section, snippet) instead of the note list.
shot knowledge-search    $MAIN --section knowledge --query order
# Preview Agent Context… for the project orders-api, with the note orders-api in view (its neighbors too).
shot knowledge-context   $MAIN --section knowledge --tab context --project orders-api --select payments/orders-api
# Pi Template…: the core layer's Pi-only section about the base, with the layer.yaml and template diff.
shot knowledge-pi-template $MAIN --section knowledge --tab pi-template
# The Lint tab: the findings the seed's space lint-examples has on purpose (akit kb lint).
shot knowledge-lint      $MAIN --section knowledge --tab lint
# The Inbox tab: the seed's three proposals; the note proposal for billing selected, with its diff and the seeded mark.
shot knowledge-inbox     $MAIN --section knowledge --tab inbox --select 2026-10-24-payments-billing
# A map an agent drew with excalidraw-cli (5.4): the draft on its read-only canvas and the links Accept sets.
shot knowledge-inbox-map $MAIN --section knowledge --tab inbox --select 2026-10-24-payments-maps-order-flow
# Draw Map with Pi…: the form with a made-up prompt (nothing runs).
shot knowledge-draw-map  $MAIN --section knowledge --tab draw-map
# Add Sample Base…: the sample base (akit kb seed) next to the demo base, only for this shot.
if [[ "$ONLY" == "  " || "$ONLY" == *" knowledge-sample "* ]]; then
    HOME="$DEMO" GIT_CONFIG_GLOBAL=/dev/null "$ROOT/AKitCore/.build/debug/akit" kb seed >/dev/null
fi
shot knowledge-sample    $MAIN --section knowledge --tab sample --select payments/order-events
rm -rf "$DEMO/.akit/local/knowledge/sample"
# Settings → Knowledge: the base folder of each world (work has the demo base, personal none yet).
shot knowledge-settings  900x760 --tab knowledge --settings
# Settings → Knowledge check model: the Pi model and thinking of akit kb check (the default, Luna).
shot knowledge-check-settings 900x760 --tab knowledge-check --settings

exit $FAILED
