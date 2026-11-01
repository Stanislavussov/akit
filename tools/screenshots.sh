#!/usr/bin/env bash
# README screenshots, light and dark, from a made-up home (tools/demo-home.sh). No real data.
#
#   make screenshots      (or: tools/screenshots.sh [DEMO_DIR] [OUT_DIR])
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEMO="${1:-${TMPDIR:-/tmp}/akit-demo}"
OUT="${2:-$ROOT/docs/assets}"
APP="$ROOT/build/Build/Products/Debug/AKit.app/Contents/MacOS/AKit"
[[ -x "$APP" ]] || { echo "Build first: make build" >&2; exit 1; }

"$ROOT/tools/demo-home.sh" "$DEMO" >/dev/null
DEMO="$(cd "$DEMO" && pwd -P)"
mkdir -p "$OUT"
# Lab runs need an akit command; without one the screen shows a warning over the list.
AKIT_CMD="$(command -v akit || true)"
[[ -n "$AKIT_CMD" ]] && ln -sf "$AKIT_CMD" "$DEMO/.local/bin/akit"

shot() { # name, flags...
    local name="$1"; shift
    for look in light dark; do
        # Value-less flags (--capture, --demo) last; see DebugSnapshot.
        # Only the demo's stand-in agent commands, never the ones on this Mac.
        HOME="$DEMO" PATH="$DEMO/.local/bin:/usr/bin:/bin" "$APP" -ApplePersistenceIgnoreState YES --snapshot "$OUT/$name-$look.png" \
            --brain "$DEMO/.akit/registry" --size 1280x800 --delay 4 --appearance "$look" "$@" --demo >/dev/null
        sips -Z 1600 "$OUT/$name-$look.png" >/dev/null
        echo "$OUT/$name-$look.png"
    done
}

# Ids that tools/demo-home.sh makes.
LAB_REVIEW=20261001-120000-demo
REVIEW_RUN=20261015-091500-orders-service-42

shot brain --section brain --select take-home
shot setup --section brain --tab setup --project weather-app
shot skills --section skills
shot mcp --section mcp
shot sessions --section sessions --tab analysis
shot insights --section insights --delay 8
shot lab --section lab --select "$LAB_REVIEW"
shot review --section review --select "$REVIEW_RUN" --tab requests
shot knowledge --section knowledge --select payments/orders-api
shot notebook --section notebook
shot worklog --section worklog
