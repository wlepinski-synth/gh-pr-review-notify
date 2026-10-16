#!/usr/bin/env bash
#
# build.sh — build PR Reviews.app and install it to ~/Applications.
# Works with plain Xcode Command Line Tools (no Xcode needed).
#
#   PR_REVIEWS_INSTALL_DIR  Where to install. Default: ~/Applications

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

EXECUTABLE="PRReviews"
APP_NAME="PR Reviews.app"
DEST="${PR_REVIEWS_INSTALL_DIR:-$HOME/Applications}"
APP="build/$APP_NAME"

info() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }

info "Building release binary"
swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"

info "Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/$EXECUTABLE" "$APP/Contents/MacOS/"
cp Resources/Info.plist "$APP/Contents/"
cp Resources/mark-github.svg "$APP/Contents/Resources/"

ICONSET="build/AppIcon.iconset"
rm -rf "$ICONSET"
mkdir -p "$ICONSET"
for size in 16 32 128 256; do
  sips -z $size $size ../gh-mark.png --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  sips -z $((size * 2)) $((size * 2)) ../gh-mark.png --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

# Notifications and login items need a signed bundle; ad-hoc is enough locally.
codesign --force --sign - "$APP"

info "Installing to $DEST"
pkill -x "$EXECUTABLE" 2>/dev/null || true
mkdir -p "$DEST"
rm -rf "$DEST/$APP_NAME"
cp -R "$APP" "$DEST/"

info "Done. Launch with: open \"$DEST/$APP_NAME\""
