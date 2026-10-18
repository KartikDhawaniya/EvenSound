#!/bin/bash
# Builds build/EvenSound.app stamped with the version in ./VERSION and archives a zip per version
# in build/versions/. Signs ad-hoc unless EVENSOUND_SIGN_IDENTITY is set.
set -euo pipefail

cd "$(dirname "$0")/.."
APP="build/EvenSound.app"
VERSION="$(tr -d '[:space:]' < VERSION)"
BUILD_NUMBER="$(git rev-list --count HEAD 2>/dev/null || echo 0)"
COMMIT="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
if [ -n "$(git status --porcelain 2>/dev/null)" ]; then COMMIT="$COMMIT-modified"; fi

swift build -c release --product EvenSound
BIN="$(swift build -c release --show-bin-path)/EvenSound"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/EvenSound"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
plutil -replace CFBundleShortVersionString -string "$VERSION" "$APP/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$BUILD_NUMBER" "$APP/Contents/Info.plist"
plutil -replace EvenSoundCommit -string "$COMMIT" "$APP/Contents/Info.plist"
plutil -lint "$APP/Contents/Info.plist" >/dev/null

codesign --force --options runtime --timestamp=none --sign "${EVENSOUND_SIGN_IDENTITY:--}" "$APP"
codesign --verify --strict "$APP"

mkdir -p build/versions
ARCHIVE="build/versions/EvenSound-$VERSION-$COMMIT.zip"
rm -f "$ARCHIVE" build/EvenSound.zip
ditto -c -k --keepParent "$APP" "$ARCHIVE"
cp "$ARCHIVE" build/EvenSound.zip

echo "Built $APP (version $VERSION, build $BUILD_NUMBER, commit $COMMIT)"
echo "Archived $ARCHIVE"
