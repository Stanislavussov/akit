#!/bin/sh
# Checks what Flows needs from the installed Pi. Read-only: it changes no Pi file.
# It prints no tokens, env values or config contents: only versions, yes/no, and names.
# Usage: tools/pi-flow-probe.sh   (paste the output back into the Flows design)
set -u

if ! command -v pi >/dev/null 2>&1; then
  echo "pi: not found on PATH"
  exit 1
fi

echo "== Pi"
echo "version: $(pi --version 2>/dev/null | head -1)"

echo "== CLI flags"
HELP=$(pi --help 2>&1)
for flag in "--mode" "--session-dir" "--skill" "--no-skills" "--tools" "--no-builtin-tools" \
            "--no-extensions" "--extension" "--model" "--thinking" "--no-session"; do
  if printf '%s\n' "$HELP" | grep -q -- "$flag"; then echo "$flag: yes"; else echo "$flag: no"; fi
done

echo "== Extension API"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/probe.ts" <<'EOF'
import { writeFileSync } from "node:fs";
export default function (pi: any) {
  const out: Record<string, boolean | string> = {};
  out.registerCommand = typeof pi.registerCommand === "function";
  out.registerTool = typeof pi.registerTool === "function";
  out.registerShortcut = typeof pi.registerShortcut === "function";
  out.on = typeof pi.on === "function";
  pi.on("session_start", (_e: any, ctx: any) => {
    const ui = ctx?.ui ?? {};
    for (const k of ["confirm", "editor", "custom", "setWidget", "setStatus", "notify"]) {
      out["ui." + k] = typeof ui[k] === "function";
    }
    writeFileSync(process.env.AKIT_PROBE_OUT as string, JSON.stringify(out));
  });
}
EOF
# rpc mode waits for commands on stdin, so no prompt reaches a model.
mkfifo "$TMP/in"
AKIT_PROBE_OUT="$TMP/out.json" pi -ne -ns -e "$TMP/probe.ts" --mode rpc --no-session \
  <"$TMP/in" >/dev/null 2>&1 &
PID=$!
exec 3>"$TMP/in"   # keep stdin open, so Pi waits instead of exiting
i=0
while [ ! -s "$TMP/out.json" ] && [ $i -lt 50 ]; do sleep 0.2; i=$((i + 1)); done
exec 3>&-
kill "$PID" 2>/dev/null
wait "$PID" 2>/dev/null
if [ -s "$TMP/out.json" ]; then
  tr ',' '\n' < "$TMP/out.json" | tr -d '{}"' | sed 's/:true/: yes/; s/:false/: no/'
  echo
else
  echo "probe extension did not start (no session_start within 10 s)"
fi

echo "not probed here: tool_call block and widget placement (tested in the Flows e2e test)"

echo "== Extensions and packages (names only)"
AGENT="${PI_CODING_AGENT_DIR:-$HOME/.pi/agent}"
if [ -d "$AGENT/extensions" ]; then
  ls "$AGENT/extensions" | sed 's/^/extension: /'
fi
if [ -f "$AGENT/settings.json" ]; then
  grep -o '"npm:[^"]*"\|"git:[^"]*"' "$AGENT/settings.json" | tr -d '"' | sed 's/^/package: /'
fi
if [ -d "$AGENT/agents" ]; then
  ls "$AGENT/agents" | sed 's/^/agent file: /'
fi
