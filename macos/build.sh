#!/bin/bash
# Build MiniSheet.app from source.
#
#   macos/build.sh            build for this Mac and install to ~/Applications (registers .csv/.xlsx/… types)
#   macos/build.sh --dist     build a universal (Apple Silicon + Intel) app and zip it into build/ — used by CI
#   macos/build.sh --bundle   build for this Mac into build/MiniSheet.app only (used by install.sh --build)
#
# Needs only Apple's Command Line Tools (xcode-select --install) or Xcode. Set VERSION=0.2.0-beta.1 to stamp a version.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MODE="${1:-install}"
OUT="$ROOT/build"
APP="$OUT/MiniSheet.app"
PLIST="$ROOT/macos/Info.plist"
VERSION="${VERSION:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")}"

rm -rf "$OUT"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/web"

SWIFT_FLAGS=(-O)
# Some Command Line Tools releases ship a stale duplicate module map, which breaks every Swift build with
# "redefinition of module 'SwiftBridging'". If that's the case here, hide the stale file for this build only.
INC="$(cd "$(dirname "$(xcrun --find swiftc)")/../include/swift" 2>/dev/null && pwd || true)"
if [ -n "$INC" ] && [ -f "$INC/module.modulemap" ] && [ -f "$INC/bridging.modulemap" ] && grep -q SwiftBridging "$INC/module.modulemap"; then
  OVL="$(mktemp -d)"; : > "$OVL/empty.modulemap"
  printf "{ 'version': 0, 'roots': [ { 'name': '%s', 'type': 'directory', 'contents': [ { 'name': 'module.modulemap', 'type': 'file', 'external-contents': '%s/empty.modulemap' } ] } ] }" "$INC" "$OVL" > "$OVL/overlay.yaml"
  SWIFT_FLAGS+=(-vfsoverlay "$OVL/overlay.yaml" -Xcc -ivfsoverlay -Xcc "$OVL/overlay.yaml")
fi

if [ "$MODE" = "--dist" ]; then ARCHS=(arm64 x86_64); else ARCHS=("$(uname -m)"); fi
BINS=()
for arch in "${ARCHS[@]}"; do
  echo "Compiling for ${arch}..."
  swiftc "${SWIFT_FLAGS[@]}" -target "$arch-apple-macos12.0" -o "$OUT/MiniSheet-$arch" "$ROOT/macos/main.swift" \
    -framework Cocoa -framework WebKit -framework UniformTypeIdentifiers
  BINS+=("$OUT/MiniSheet-$arch")
done
lipo -create "${BINS[@]}" -output "$APP/Contents/MacOS/MiniSheet"
rm -f "${BINS[@]}"

cp "$PLIST" "$APP/Contents/Info.plist"
# CFBundleShortVersionString carries the full version (e.g. 0.1.0-alpha.1); CFBundleVersion must be numeric.
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" -c "Set :CFBundleVersion ${VERSION%%-*}" "$APP/Contents/Info.plist"
cp "$ROOT/macos/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
cp "$ROOT/web/index.html" "$ROOT/web/xlsx.full.min.js" "$APP/Contents/Resources/web/"
codesign --force --deep --sign - "$APP"          # ad-hoc signature (no Apple Developer account needed)

if [ "$MODE" = "--dist" ]; then
  ditto -c -k --keepParent "$APP" "$OUT/MiniSheet-macOS.zip"
  echo "Built $OUT/MiniSheet-macOS.zip (version $VERSION, $(lipo -archs "$APP/Contents/MacOS/MiniSheet"))"
elif [ "$MODE" = "--bundle" ]; then
  echo "Built $APP (version $VERSION)"
else
  DEST="$HOME/Applications/MiniSheet.app"
  mkdir -p "$HOME/Applications"
  pkill -x MiniSheet 2>/dev/null || true
  rm -rf "$DEST" && ditto "$APP" "$DEST"
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DEST"
  echo "Installed $DEST (version $VERSION)"
fi
