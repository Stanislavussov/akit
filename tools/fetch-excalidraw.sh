#!/bin/bash
# Vendors the Excalidraw canvas for the Knowledge maps (docs/design/knowledge.md, option A1):
# the prebuilt UMD of @excalidraw/excalidraw 0.17.6 with React 18.3.1, from registry.npmjs.org.
# Each tarball is checked against the SHA-256 pinned below and against npm's dist.integrity, then
# only the production files are kept: the UMD scripts, Excalidraw's asset folder (fonts and the
# vendor chunk it loads at start), the ru-RU locale (English is built in) and the licenses.
# The output in web/excalidraw/vendor/ is committed, so a build needs no node and no network.
#
# Usage: tools/fetch-excalidraw.sh      (idempotent: it rebuilds the folder from the tarballs)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/web/excalidraw/vendor"
REGISTRY="https://registry.npmjs.org"

# name version tarball-path sha256 (computed once from the tarball; npm's sha512 is checked too)
PACKAGES=(
  "@excalidraw/excalidraw 0.17.6 @excalidraw/excalidraw/-/excalidraw-0.17.6.tgz 480dd1ea12156d84acd8af0605fcec894326c07f152f7ed2212145b9864ed4e7"
  "react 18.3.1 react/-/react-18.3.1.tgz 8d9bed01a672e7eaf387942d781ad47c6a43089a30a0306060f9fd5ac7870347"
  "react-dom 18.3.1 react-dom/-/react-dom-18.3.1.tgz 031d4427a99f2f3f6cac18bbbf308594a67e4f47d10f4896fdec446505b040e0"
)

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

fetch() { # name version path sha256 -> extracts into $WORK/<name>/package
  local name="$1" version="$2" path="$3" sha="$4"
  local tgz="$WORK/$(basename "$path")"
  curl -fsSL --proto '=https' "$REGISTRY/$path" -o "$tgz"
  local got
  got="$(shasum -a 256 "$tgz" | cut -d' ' -f1)"
  if [ "$got" != "$sha" ]; then
    echo "fetch-excalidraw: $name@$version: SHA-256 $got, expected $sha" >&2
    exit 1
  fi
  local integrity expected
  integrity="sha512-$(openssl dgst -sha512 -binary "$tgz" | base64 | tr -d '\n')"
  expected="$(curl -fsSL --proto '=https' "$REGISTRY/$name/$version" | /usr/bin/python3 -I -c 'import json,sys; print(json.load(sys.stdin)["dist"]["integrity"])')"
  if [ "$integrity" != "$expected" ]; then
    echo "fetch-excalidraw: $name@$version: integrity $integrity, npm says $expected" >&2
    exit 1
  fi
  mkdir -p "$WORK/$name"
  tar -xzf "$tgz" -C "$WORK/$name"
}

for entry in "${PACKAGES[@]}"; do
  # shellcheck disable=SC2086
  fetch $entry
done

EX="$WORK/@excalidraw/excalidraw/package"
R="$WORK/react/package"
RD="$WORK/react-dom/package"

rm -rf "$OUT"
mkdir -p "$OUT/excalidraw-assets/locales"
cp "$R/umd/react.production.min.js" "$R/LICENSE" "$OUT/" && mv "$OUT/LICENSE" "$OUT/LICENSE-react.txt"
cp "$RD/umd/react-dom.production.min.js" "$OUT/" && cp "$RD/LICENSE" "$OUT/LICENSE-react-dom.txt"
cp "$EX/dist/excalidraw.production.min.js" "$EX/dist/excalidraw.production.min.js.LICENSE.txt" "$OUT/"
# Fonts, the vendor chunk (loaded at start) and its license notes; locales only ru (en is built in).
find "$EX/dist/excalidraw-assets" -maxdepth 1 -type f -exec cp {} "$OUT/excalidraw-assets/" \;
cp "$EX"/dist/excalidraw-assets/locales/ru-RU-json-*.js "$OUT/excalidraw-assets/locales/"

# The npm tarball has no LICENSE file; package.json says MIT. The text is the repository's
# (github.com/excalidraw/excalidraw/blob/master/LICENSE).
grep -q '"license": "MIT"' "$EX/package.json" || { echo "fetch-excalidraw: Excalidraw is no longer MIT" >&2; exit 1; }
cat > "$OUT/LICENSE-excalidraw.txt" <<'EOF'
MIT License

Copyright (c) 2020 Excalidraw

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
EOF
# Tarball files carry a 1985 mtime; give them a normal one so git and Finder show them plainly.
find "$OUT" -type f -exec chmod 644 {} \; -exec touch {} \;

echo "Vendored into ${OUT#"$ROOT"/}:"
(cd "$OUT" && find . -type f | sort | sed 's|^\./|  |')
echo "Total: $(du -sk "$OUT" | cut -f1) KB ($(find "$OUT" -type f -exec stat -f %z {} + | awk '{s+=$1} END {printf "%d", s}') bytes)"
