#!/bin/bash
# Builds Sorot and wraps it in an app bundle at build/Sorot.app.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release
APP="build/Sorot.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$(swift build -c release --show-bin-path)/Sorot" "$APP/Contents/MacOS/Sorot"
cp Resources/Info.plist "$APP/Contents/Info.plist"
# Sign with your Apple Development certificate when you have one, so macOS remembers the
# camera permission across rebuilds. Without one the signature is ad-hoc: the app still
# runs, but macOS asks for camera access again after every rebuild.
IDENTITY="${SOROT_SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development/ {print $2; exit}')}"
codesign --force --sign "${IDENTITY:--}" "$APP"
echo "Built $APP"
