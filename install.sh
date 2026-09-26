#!/usr/bin/env bash
# One-step AKit install on a Mac: fetches (or updates) the source, builds it, and installs
# AKit.app into ~/Applications and the `akit` command into ~/.local/bin.
#
#   bash <(gh api repos/Stanislavussov/akit/contents/install.sh --jq .content | base64 -d)
#   or, from a checkout:  ./install.sh
#
# Settings (environment variables):
#   AKIT_REPO        GitHub repo of AKit           (default Stanislavussov/akit)
#   AKIT_DIR         where the source lives         (default ~/Projects/akit)
#   AKIT_BRAIN_REPO  your brain repo, cloned into ~/.akit/registry if that is missing
#                    (e.g. Stanislavussov/brain; optional)
#   AKIT_SKIP_HOME=1 don't render the brain's core layer into ~ after installing
set -euo pipefail

AKIT_REPO="${AKIT_REPO:-Stanislavussov/akit}"
AKIT_DIR="${AKIT_DIR:-$HOME/Projects/akit}"
BRAIN_DIR="$HOME/.akit/registry"

say() { printf '\033[1m==> %s\033[0m\n' "$*"; }
fail() { printf '\033[31mError: %s\033[0m\n' "$*" >&2; exit 1; }

[[ "$(uname)" == "Darwin" ]] || fail "AKit is a macOS app."
command -v git >/dev/null || fail "git is missing. Run: xcode-select --install"
xcodebuild -version >/dev/null 2>&1 || fail "Xcode is needed to build AKit (xcodebuild failed). Install Xcode from the App Store, open it once, then run: sudo xcode-select -s /Applications/Xcode.app"
if ! command -v xcodegen >/dev/null; then
    command -v brew >/dev/null || fail "xcodegen is missing and Homebrew isn't installed (https://brew.sh). Then: brew install xcodegen"
    say "Installing xcodegen with Homebrew"
    brew install xcodegen
fi

# Clone with gh when it is there (works for private repos), else over SSH.
clone() {
    local repo="$1" dir="$2"
    if command -v gh >/dev/null && gh auth status >/dev/null 2>&1; then
        gh repo clone "$repo" "$dir"
    else
        git clone "git@github.com:$repo.git" "$dir"
    fi
}

# Run from inside a checkout: use it as is.
here="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || true)"
if [[ -n "$here" && -f "$here/project.yml" && -d "$here/AKitCore" ]]; then
    AKIT_DIR="$here"
elif [[ -d "$AKIT_DIR/.git" ]]; then
    say "Updating $AKIT_DIR"
    git -C "$AKIT_DIR" pull --ff-only
else
    say "Downloading $AKIT_REPO into $AKIT_DIR"
    mkdir -p "$(dirname "$AKIT_DIR")"
    clone "$AKIT_REPO" "$AKIT_DIR"
fi

say "Building and installing (a few minutes the first time)"
make -C "$AKIT_DIR" install

if [[ -n "${AKIT_BRAIN_REPO:-}" && ! -e "$BRAIN_DIR" ]]; then
    say "Downloading your brain $AKIT_BRAIN_REPO into $BRAIN_DIR"
    mkdir -p "$(dirname "$BRAIN_DIR")"
    clone "$AKIT_BRAIN_REPO" "$BRAIN_DIR"
fi

# The core layer into ~ (skills for every harness), unless AKIT_SKIP_HOME=1. Replaced files
# are backed up in ~/.akit/backups.
if [[ -e "$BRAIN_DIR" && "${AKIT_SKIP_HOME:-}" != 1 ]]; then
    say "Rendering the core layer into your home folder"
    "$HOME/.local/bin/akit" apply --home --include-unmanaged || echo "akit apply --home failed; run it again after fixing the problems above."
fi

case ":$PATH:" in
    *":$HOME/.local/bin:"*) ;;
    *)
        say "Adding ~/.local/bin to PATH in ~/.zprofile"
        echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$HOME/.zprofile"
        echo "Open a new terminal (or run: source ~/.zprofile) to use akit."
        ;;
esac

say "Done"
echo "  App:     ~/Applications/AKit.app"
echo "  Command: akit --help"
[[ -e "$BRAIN_DIR" ]] && echo "  Brain:   $BRAIN_DIR" || echo "  Brain:   none yet; create it in AKit (Brain → Create Brain Repo) or set AKIT_BRAIN_REPO"
