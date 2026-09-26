#!/usr/bin/env bash
# One-step AKit install on a Mac: AKit.app into ~/Applications and the `akit` command into
# ~/.local/bin, then `akit setup` asks a few questions (Enter takes the default each time).
#
#   /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Stanislavussov/akit/master/install.sh)"
#   or, from a checkout:  ./install.sh
#
# It downloads the latest release (no Xcode needed). Without a release, or run from a
# checkout, it builds from source (needs Xcode). Run it again to update.
#
# Settings (environment variables):
#   AKIT_REPO          GitHub repo of AKit (owner/repo or a git URL; default Stanislavussov/akit)
#   AKIT_DIR           where the source goes when building (default ~/Projects/akit)
#   AKIT_FROM_SOURCE=1 build from source even when there is a release
#   AKIT_RELEASE_URL   AKit.zip to install instead of the latest release (a mirror, or file://)
#   AKIT_BRAIN_REPO    your brain repo (owner/repo or a git URL) instead of being asked
#   AKIT_SKIP_HOME=1   don't put the brain's core layer into ~
#   AKIT_MACHINE=work  a work Mac: project answers and locks stay on it, never in the brain
#                      (akit machine work; set it on the first install, before anything is saved)
set -euo pipefail

AKIT_REPO="${AKIT_REPO:-Stanislavussov/akit}"
AKIT_DIR="${AKIT_DIR:-$HOME/Projects/akit}"

say() { printf '\033[1m==> %s\033[0m\n' "$*"; }
fail() { printf '\033[31mError: %s\033[0m\n' "$*" >&2; exit 1; }

[[ "$(uname)" == "Darwin" ]] || fail "AKit is a macOS app."
[[ "$(sw_vers -productVersion | cut -d. -f1)" -ge 15 ]] || fail "AKit needs macOS 15 or later (this Mac has $(sw_vers -productVersion))."
git --version >/dev/null 2>&1 || fail "git is missing (AKit keeps your brain in git). Run: xcode-select --install"

# The latest release's AKit.zip: over HTTPS for a public repo, with gh for a private one.
# Returns 1 when there is none; stops the install when one was found but couldn't be put in place.
install_release() {
    local url="${AKIT_RELEASE_URL:-https://github.com/$AKIT_REPO/releases/latest/download/AKit.zip}"
    [[ -n "${AKIT_RELEASE_URL:-}" || "$AKIT_REPO" != *:* ]] || return 1
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' EXIT
    if ! curl -fsSL -o "$tmp/AKit.zip" "$url" 2>/dev/null; then
        [[ -z "${AKIT_RELEASE_URL:-}" ]] || fail "Couldn't download $AKIT_RELEASE_URL"
        rm -f "$tmp/AKit.zip"
        command -v gh >/dev/null && gh auth status >/dev/null 2>&1 || return 1
        gh release download --repo "$AKIT_REPO" --pattern AKit.zip --dir "$tmp" >/dev/null 2>&1 || return 1
    fi
    ditto -x -k "$tmp/AKit.zip" "$tmp" && [[ -d "$tmp/AKit/AKit.app" && -f "$tmp/AKit/akit" ]] \
        || fail "The downloaded AKit.zip is damaged; run the install again."
    mkdir -p "$HOME/Applications" "$HOME/.local/bin" || fail "Couldn't create ~/Applications or ~/.local/bin."
    rm -rf "$HOME/Applications/AKit.app" && cp -R "$tmp/AKit/AKit.app" "$HOME/Applications/" \
        || fail "Couldn't put AKit.app into ~/Applications."
    install -m 755 "$tmp/AKit/akit" "$HOME/.local/bin/akit" || fail "Couldn't put akit into ~/.local/bin (owned by root? then: sudo chown -R \"$USER\" ~/.local)."
    xattr -dr com.apple.quarantine "$HOME/Applications/AKit.app" "$HOME/.local/bin/akit" 2>/dev/null || true
}

# Clone a git URL as is; owner/repo with gh when it is signed in (private repos), else over
# HTTPS (public repos), else over SSH.
clone() {
    local repo="$1" dir="$2"
    if [[ "$repo" == *:* ]]; then
        git clone "$repo" "$dir"
    elif command -v gh >/dev/null && gh auth status >/dev/null 2>&1; then
        gh repo clone "$repo" "$dir"
    else
        GIT_TERMINAL_PROMPT=0 git clone "https://github.com/$repo.git" "$dir" 2>/dev/null \
            || git clone "git@github.com:$repo.git" "$dir"
    fi
}

build_from_source() {
    xcodebuild -version >/dev/null 2>&1 || fail "There is no AKit release to download, and building needs Xcode (xcodebuild failed). Install Xcode from the App Store, open it once, then run: sudo xcode-select -s /Applications/Xcode.app"
    if ! command -v xcodegen >/dev/null; then
        command -v brew >/dev/null || fail "xcodegen is missing and Homebrew isn't installed (https://brew.sh). Then: brew install xcodegen"
        say "Installing xcodegen with Homebrew"
        brew install xcodegen
    fi
    if [[ -n "$checkout" ]]; then
        AKIT_DIR="$checkout"
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
}

# Run from inside a checkout: build that checkout.
here="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || true)"
checkout=""
if [[ -n "$here" && -f "$here/project.yml" && -d "$here/AKitCore" ]]; then checkout="$here"; fi

if [[ -z "$checkout" && "${AKIT_FROM_SOURCE:-}" != 1 ]]; then
    say "Downloading the latest AKit"
    if ! install_release; then
        echo "No release to download; building from source."
        build_from_source
    fi
else
    build_from_source
fi

path_line='export PATH="$HOME/.local/bin:$PATH"'
case ":$PATH:" in
    *":$HOME/.local/bin:"*) ;;
    *)
        if ! grep -qsF "$path_line" "$HOME/.zprofile"; then
            say "Adding ~/.local/bin to PATH in ~/.zprofile"
            echo "$path_line" >> "$HOME/.zprofile"
        fi
        echo "Open a new terminal (or run: source ~/.zprofile) to use akit."
        ;;
esac

# A work Mac is marked before setup renders anything, so its records never land in the brain.
# If that fails, stop: a Mac meant to be a work Mac must not be set up as a personal one.
if [[ -n "${AKIT_MACHINE:-}" ]]; then
    machine="$(printf '%s' "$AKIT_MACHINE" | tr '[:upper:]' '[:lower:]')"
    "$HOME/.local/bin/akit" machine "$machine" \
        || fail "akit machine $machine failed, so setup didn't run (nothing reached the brain). Fix it (akit machine work|personal), then run: akit setup"
fi

# The questions (brain, projects folder, skills in ~) with defaults; none without a terminal.
say "Setting up"
setup=("$HOME/.local/bin/akit" setup)
if [[ "${AKIT_SKIP_HOME:-}" == 1 ]]; then setup+=(--skip-home); fi
grep -q "akit setup" <<<"$("$HOME/.local/bin/akit" --help)" || fail "This akit is older than the install script; run the install again later, or with AKIT_FROM_SOURCE=1."
if [[ -t 0 ]]; then
    "${setup[@]}" || setup_failed=1
elif (exec </dev/tty) 2>/dev/null; then
    "${setup[@]}" </dev/tty || setup_failed=1
else
    "${setup[@]}" --yes || setup_failed=1
fi
[[ -z "${setup_failed:-}" ]] || echo "Setup didn't finish (see above). AKit is installed; run akit setup again after fixing it."

echo "  App:     ~/Applications/AKit.app"
echo "  Command: akit --help"
