#!/bin/bash
# Builds a Release copy of CompyCoach and packages it as a drag-to-install disk image.
#
#   scripts/package.sh        (run from anywhere)
#
# Output: build/CompyCoach.dmg. The name never changes, so the GitHub link
# releases/latest/download/CompyCoach.dmg always serves the newest release.
#
# The app is ad-hoc signed, not notarized: on first launch people go to
# System Settings → Privacy & Security → Open Anyway (see README).

set -euo pipefail
cd "$(dirname "$0")/.."

BUILD=build/package
ARCHIVE=$BUILD/CompyCoach.xcarchive
EXPORT=$BUILD/export
STAGE=$BUILD/dmg
DMG=build/CompyCoach.dmg

rm -rf "$BUILD" "$DMG"
mkdir -p "$BUILD"

echo "Archiving Release build…"
xcodebuild -scheme CompyCoach -configuration Release \
    -archivePath "$ARCHIVE" -derivedDataPath "$BUILD/derived" archive -quiet

echo "Exporting app…"
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath "$EXPORT" \
    -exportOptionsPlist ExportOptions.plist -quiet

APP=$EXPORT/CompyCoach.app
codesign --verify --deep --strict "$APP"

echo "Making disk image…"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname CompyCoach -srcfolder "$STAGE" -ov -format UDZO "$DMG" -quiet

PLIST=$APP/Contents/Info.plist
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$PLIST")
MIN_OS=$(/usr/libexec/PlistBuddy -c "Print LSMinimumSystemVersion" "$PLIST")
ARCHS=$(lipo -archs "$APP/Contents/MacOS/CompyCoach")
echo
echo "Packaged CompyCoach $VERSION → $DMG ($(du -h "$DMG" | cut -f1 | xargs))"
echo "  Runs on macOS $MIN_OS or later · $ARCHS"
