#!/bin/bash
# MiniSheet installer: one command to install, update, build from source, or remove.
#
#   curl -fsSL https://raw.githubusercontent.com/aibyos/minisheet/main/install.sh | bash
#   curl -fsSL https://raw.githubusercontent.com/aibyos/minisheet/main/install.sh | bash -s -- --build
#   curl -fsSL https://raw.githubusercontent.com/aibyos/minisheet/main/install.sh | bash -s -- --uninstall
#
# Options:  --build       compile from the latest source instead of downloading the release
#           --version X   install a specific release, e.g. --version 0.1.0-alpha.1
#           --no-open     don't launch MiniSheet afterwards
#           --uninstall   remove MiniSheet and its settings
set -euo pipefail

REPO="aibyos/minisheet"
BUNDLE_ID="com.aibyos.minisheet"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

MODE=download; VERSION=""; OPEN=1
while [ $# -gt 0 ]; do
  case "$1" in
    --build) MODE=build ;;
    --uninstall) MODE=uninstall ;;
    --version) VERSION="${2#v}"; shift ;;
    --no-open) OPEN=0 ;;
    -h|--help) sed -n '2,13p' "$0" 2>/dev/null || true; exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

say()  { printf '\033[1m==>\033[0m %s\n' "$*"; }
fail() { printf '\033[31mError:\033[0m %s\n' "$*" >&2; exit 1; }

[ "$(uname -s)" = Darwin ] || fail "MiniSheet is a macOS app."
MAJOR="$(sw_vers -productVersion | cut -d. -f1)"
[ "$MAJOR" -ge 12 ] || fail "MiniSheet needs macOS 12 or later (this Mac has $(sw_vers -productVersion))."

# Keep an existing copy where it is; otherwise prefer /Applications, falling back to ~/Applications.
if   [ -d "$HOME/Applications/MiniSheet.app" ]; then DIR="$HOME/Applications"
elif [ -d "/Applications/MiniSheet.app" ] || [ -w /Applications ]; then DIR="/Applications"
else DIR="$HOME/Applications"; fi
DEST="$DIR/MiniSheet.app"

quit_running() {
  if pgrep -x MiniSheet >/dev/null 2>&1; then
    say "Quitting the running MiniSheet…"
    osascript -e 'tell application id "'"$BUNDLE_ID"'" to quit' >/dev/null 2>&1 || true
    for _ in 1 2 3 4 5 6 7 8 9 10; do pgrep -x MiniSheet >/dev/null 2>&1 || break; sleep 0.5; done
    pkill -x MiniSheet 2>/dev/null || true
  fi
}

if [ "$MODE" = uninstall ]; then
  quit_running
  for d in "$HOME/Applications/MiniSheet.app" "/Applications/MiniSheet.app"; do
    [ -d "$d" ] && { rm -rf "$d" && say "Removed $d"; }
  done
  defaults delete "$BUNDLE_ID" >/dev/null 2>&1 || true
  rm -rf "$HOME/Library/WebKit/$BUNDLE_ID" "$HOME/Library/Caches/$BUNDLE_ID" "$HOME/Library/Saved Application State/$BUNDLE_ID.savedState"
  say "MiniSheet and its settings are removed."
  exit 0
fi

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

if [ "$MODE" = download ]; then
  if [ -z "$VERSION" ]; then
    # MiniSheet is in alpha/beta: releases are GitHub *pre-releases*, which /releases/latest skips — take the newest one.
    TAG="$(curl -fsSL "https://api.github.com/repos/$REPO/releases?per_page=1" | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -1)"
    [ -n "$TAG" ] || fail "Couldn't find a MiniSheet release on GitHub."
    VERSION="${TAG#v}"
  fi
  URL="https://github.com/$REPO/releases/download/v$VERSION/MiniSheet-macOS.zip"
  say "Downloading MiniSheet ${VERSION}…"
  curl -fL --progress-bar "$URL" -o "$WORK/MiniSheet.zip" || fail "Download failed: $URL"
  ditto -x -k "$WORK/MiniSheet.zip" "$WORK" || fail "Couldn't unpack the download."
  NEW="$WORK/MiniSheet.app"
else
  xcode-select -p >/dev/null 2>&1 || {
    xcode-select --install >/dev/null 2>&1 || true
    fail "Building needs Apple's Command Line Tools. An installer window should have opened — finish it, then run this command again."
  }
  REF="${VERSION:+v$VERSION}"; REF="${REF:-main}"
  say "Fetching MiniSheet source ($REF)…"
  if [ "$REF" = main ]; then SRC_URL="https://github.com/$REPO/archive/refs/heads/main.tar.gz"
  else SRC_URL="https://github.com/$REPO/archive/refs/tags/$REF.tar.gz"; fi
  curl -fsSL "$SRC_URL" | tar -xz -C "$WORK" || fail "Couldn't download the source."
  SRC="$(find "$WORK" -maxdepth 1 -type d -name 'minisheet-*' | head -1)"
  say "Building (this takes about a minute)…"
  "$SRC/macos/build.sh" --bundle || fail "The build failed (see the messages above)."
  NEW="$SRC/build/MiniSheet.app"
fi

[ -d "$NEW" ] || fail "MiniSheet.app wasn't produced."
INSTALLED="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$NEW/Contents/Info.plist" 2>/dev/null || echo '?')"

quit_running
mkdir -p "$DIR"
rm -rf "$DEST"
ditto "$NEW" "$DEST" || fail "Couldn't write to $DIR."
xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true   # nothing to quarantine when fetched by curl, but be sure
"$LSREGISTER" -f "$DEST" >/dev/null 2>&1 || true
say "Installed MiniSheet $INSTALLED → $DEST"
echo "   Updates: MiniSheet → Check for Updates… (or re-run this command)."
echo "   Make it the default for a file type: right-click a .csv/.xlsx → Get Info → Open with → MiniSheet → Change All…"
[ "$OPEN" = 1 ] && open "$DEST"
exit 0
