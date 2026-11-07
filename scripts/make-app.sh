#!/bin/bash
# Builds a .app bundle from a SwiftPM executable target and signs it.
#   scripts/make-app.sh PRODUCT "App Name" Resources/Info.plist [Resources/Icon.icns]
# Signs with your free "Apple Development" certificate when one exists, so Photos and
# Full Disk Access permissions survive rebuilds; otherwise falls back to ad-hoc signing.
set -euo pipefail
cd "$(dirname "$0")/.."
PRODUCT="$1"; NAME="$2"; PLIST="$3"; ICON="${4:-}"

swift build -c release --arch arm64 --product "$PRODUCT"
BIN="$(swift build -c release --arch arm64 --show-bin-path)"

APP="build/$NAME.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN/$PRODUCT" "$APP/Contents/MacOS/$PRODUCT"
cp "$PLIST" "$APP/Contents/Info.plist"
if [ -n "$ICON" ]; then
  mkdir -p "$APP/Contents/Resources"
  cp "$ICON" "$APP/Contents/Resources/"
fi

# Keeper's orientation network (Sideways Photos): compiled now when Xcode's Core ML compiler is
# installed; otherwise bundled as is, and Keeper compiles it once on first use.
if [ "$PRODUCT" = "Keeper" ] && [ -d Resources/OrientationNet.mlpackage ]; then
  mkdir -p "$APP/Contents/Resources"
  if xcrun --find coremlcompiler >/dev/null 2>&1; then
    xcrun coremlcompiler compile Resources/OrientationNet.mlpackage "$APP/Contents/Resources" >/dev/null
  else
    cp -R Resources/OrientationNet.mlpackage "$APP/Contents/Resources/"
  fi
fi

# The dates face-age model (CC BY-NC 4.0, see Resources/FaceAge-NOTICE.txt). Dates works without it.
if [ "$PRODUCT" = "Keeper" ] && [ -d Resources/FaceAge.mlpackage ]; then
  mkdir -p "$APP/Contents/Resources"
  cp -R Resources/FaceAge.mlpackage "$APP/Contents/Resources/"
  cp Resources/FaceAge-NOTICE.txt "$APP/Contents/Resources/"
fi

IDENTITY="${WINNOW_SIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/ {print $2; exit}')}"
codesign --force --sign "${IDENTITY:--}" "$APP"
echo "Built $APP (signed: ${IDENTITY:-ad-hoc})"
