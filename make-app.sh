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
# Ad-hoc signature: enough to run on this Mac and to be asked for camera access.
codesign --force --sign - "$APP"
echo "Built $APP"
