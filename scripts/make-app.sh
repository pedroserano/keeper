#!/bin/bash
# Builds a .app bundle from a SwiftPM executable target and signs it.
#   scripts/make-app.sh PRODUCT "App Name" Resources/Info.plist
# Signs with your free "Apple Development" certificate when one exists, so Photos and
# Full Disk Access permissions survive rebuilds; otherwise falls back to ad-hoc signing.
set -euo pipefail
cd "$(dirname "$0")/.."
PRODUCT="$1"; NAME="$2"; PLIST="$3"

swift build -c release --arch arm64 --product "$PRODUCT"
BIN="$(swift build -c release --arch arm64 --show-bin-path)"

APP="build/$NAME.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN/$PRODUCT" "$APP/Contents/MacOS/$PRODUCT"
cp "$PLIST" "$APP/Contents/Info.plist"

IDENTITY="${WINNOW_SIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/ {print $2; exit}')}"
codesign --force --sign "${IDENTITY:--}" "$APP"
echo "Built $APP (signed: ${IDENTITY:-ad-hoc})"
