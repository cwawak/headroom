#!/bin/bash
# Builds and packages Headroom into Headroom.app, Headroom.app.zip, and Headroom.dmg for distribution without code signing.
# Useful for automated release workflows or unsigned builds.

set -euo pipefail
cd "$(dirname "$0")/.."

HDIUTIL=/usr/bin/hdiutil
ICONUTIL=/usr/bin/iconutil

APP="build/Headroom.app"
APP_ZIP="build/Headroom.app.zip"
DMG="build/Headroom.dmg"
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Resources/Info.plist 2>/dev/null || grep -A1 "CFBundleShortVersionString" Resources/Info.plist | grep string | sed -E 's/.*<string>(.*)<\/string>.*/\1/' | xargs)

echo "==> building release $VERSION"
swift build -c release

echo "==> icon"
mkdir -p build
swiftc -O -o build/make-icon scripts/make-icon.swift 2>/dev/null
./build/make-icon build/Headroom.iconset >/dev/null
$ICONUTIL -c icns build/Headroom.iconset -o Resources/AppIcon.icns

echo "==> bundle"
rm -rf "$APP" "$APP_ZIP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Headroom "$APP/Contents/MacOS/Headroom"
cp Resources/Info.plist      "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns    "$APP/Contents/Resources/AppIcon.icns"

echo "==> zip"
/usr/bin/ditto -c -k --keepParent "$APP" "$APP_ZIP"

echo "==> dmg"
rm -rf build/dmgroot "$DMG"
mkdir -p build/dmgroot
cp -R "$APP" build/dmgroot/
ln -s /Applications build/dmgroot/Applications
$HDIUTIL create -volname "Headroom" -srcfolder build/dmgroot \
               -ov -format UDZO "$DMG" >/dev/null

echo
echo "done: $DMG and $APP_ZIP"
