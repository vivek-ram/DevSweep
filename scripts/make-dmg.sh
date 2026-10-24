#!/bin/zsh
# Builds DevSweep.app (Apple silicon + Intel) and packs it into a disk image with an
# Applications shortcut, ready to drag and drop.
#   scripts/make-dmg.sh      → build/DevSweep-<version>.dmg
set -euo pipefail
cd "${0:A:h}/.."

scripts/build-app.sh --universal

VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" build/DevSweep.app/Contents/Info.plist)
DMG="build/DevSweep-$VERSION.dmg"
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT

echo "› Packing $DMG…"
cp -R build/DevSweep.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname "DevSweep $VERSION" -srcfolder "$STAGE" -ov -format UDZO -quiet "$DMG"
hdiutil verify -quiet "$DMG"

echo "✓ Built $DMG ($(du -h "$DMG" | cut -f1))"
