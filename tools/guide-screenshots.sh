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
shot skills              $MAIN --section skills
shot skills-switch       $MAIN --section skills --query tdd --add
shot skills-invocation   $MAIN --section skills --tab invocation --select grilling
shot skills-invocation-all $MAIN --section skills --tab invocation-all --delay 3
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
shot settings            900x760 --settings
shot settings-lab        900x760 --tab lab --settings
shot settings-scrub      900x760 --tab scrub --settings
shot settings-add        900x760 --tab lab --settings --add
# The guide window itself: a search over every guide, and a section with a screenshot.
shot guide-search        820x900 --guide screens:start --query "usage"
shot guide-section       820x900 --guide screens:skills

exit $FAILED
