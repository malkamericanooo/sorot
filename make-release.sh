#!/bin/bash
# Builds a Sorot.app that runs on any Mac with macOS 13 or later (Apple silicon and Intel)
# and zips it for a GitHub release at build/Sorot-<version>.zip.
#
# The release is signed ad-hoc on purpose: a personal development certificate would put
# its owner's name inside the download. It is not notarised, so macOS asks people to
# allow it once (see "Install" in the README).
set -euo pipefail
cd "$(dirname "$0")"

VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)
swift build -c release --arch arm64 --arch x86_64
BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/Sorot"

APP="build/release/Sorot.app"
rm -rf build/release
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/Sorot"
strip -x "$APP/Contents/MacOS/Sorot"
cp Resources/Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"

ZIP="build/Sorot-$VERSION.zip"
rm -f "$ZIP"
ditto -c -k --norsrc --noextattr --keepParent "$APP" "$ZIP"
echo "Built $ZIP"
lipo -archs "$APP/Contents/MacOS/Sorot"
shasum -a 256 "$ZIP"
