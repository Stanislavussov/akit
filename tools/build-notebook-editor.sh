#!/bin/bash
# Builds the Notebook's editor (docs/design/notebook.md, NB3): Milkdown Crepe 7.22.3 with the
# features AKit uses, and AKit's Markdown fixes (tools/notebook-editor/editor.js), bundled by
# esbuild into one offline script and one style sheet in web/notebook/vendor/. The packages come
# from registry.npmjs.org at the exact versions in tools/notebook-editor/package-lock.json, each
# checked against its integrity hash by `npm ci`; install scripts don't run. The output is
# committed, so a build of AKit needs no node and no network.
#
# Usage: tools/build-notebook-editor.sh      (idempotent: it rebuilds the folder)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/tools/notebook-editor"
OUT="$ROOT/web/notebook/vendor"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cp "$SRC/package.json" "$SRC/editor.js" "$WORK/"
if [ -f "$SRC/package-lock.json" ]; then
  cp "$SRC/package-lock.json" "$WORK/"
  (cd "$WORK" && npm ci --ignore-scripts --no-audit --no-fund --registry=https://registry.npmjs.org/ >/dev/null)
else
  # First run: make the lock file, then keep it.
  (cd "$WORK" && npm install --ignore-scripts --no-audit --no-fund --registry=https://registry.npmjs.org/ >/dev/null)
  cp "$WORK/package-lock.json" "$SRC/package-lock.json"
fi

grep -q '"license": "MIT"' "$WORK/node_modules/@milkdown/crepe/package.json" || { echo "build-notebook-editor: Crepe is no longer MIT" >&2; exit 1; }

rm -rf "$OUT"
mkdir -p "$OUT"
(cd "$WORK" && ./node_modules/.bin/esbuild editor.js --bundle --format=iife --minify --target=safari17 \
  --legal-comments=external --outfile="$OUT/editor.js" --log-level=warning)
mv "$OUT/editor.js.LEGAL.txt" "$OUT/LICENSES.txt"
# The license of every bundled package, from its own folder.
(cd "$WORK" && node -e '
  const fs = require("fs"), path = require("path");
  const lock = JSON.parse(fs.readFileSync("package-lock.json", "utf8"));
  const out = [];
  for (const [where, info] of Object.entries(lock.packages)) {
    if (!where || info.dev) continue;
    const dir = where;
    const file = ["LICENSE", "LICENSE.md", "LICENSE.txt", "license", "LICENCE"].map((n) => path.join(dir, n)).find((f) => fs.existsSync(f));
    out.push("== " + where.replace(/^node_modules\//, "") + " " + info.version + " (" + (info.license || "?") + ")\n" + (file ? fs.readFileSync(file, "utf8").trim() : ""));
  }
  fs.appendFileSync(process.argv[1], "\n\n" + out.join("\n\n") + "\n");
' "$OUT/LICENSES.txt")
echo "Built $(du -h "$OUT/editor.js" | cut -f1) editor.js and $(du -h "$OUT/editor.css" | cut -f1) editor.css in web/notebook/vendor"
