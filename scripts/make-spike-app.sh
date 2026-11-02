#!/bin/bash
# Builds "build/Winnow Spike.app" from the SwiftPM target and signs it.
# Signs with your free "Apple Development" certificate when one exists, so Photos and
# Full Disk Access permissions survive rebuilds; otherwise falls back to ad-hoc signing.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release --arch arm64 --product WinnowSpike
BIN="$(swift build -c release --arch arm64 --show-bin-path)"

APP="build/Winnow Spike.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN/WinnowSpike" "$APP/Contents/MacOS/WinnowSpike"
cp Resources/WinnowSpike-Info.plist "$APP/Contents/Info.plist"

IDENTITY="${WINNOW_SIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/ {print $2; exit}')}"
codesign --force --sign "${IDENTITY:--}" "$APP"
echo "Built $APP (signed: ${IDENTITY:-ad-hoc})"
