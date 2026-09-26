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

shot brain --section brain --select take-home
shot setup --section brain --tab setup --project weather-app
