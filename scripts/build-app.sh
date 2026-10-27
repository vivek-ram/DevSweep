#!/bin/zsh
# Builds DevSweep.app into ./build. Works with just the Xcode Command Line Tools.
#   scripts/build-app.sh              build only (this Mac's architecture)
#   scripts/build-app.sh --universal  Apple silicon + Intel in one app (for releases)
#   scripts/build-app.sh --install    also copy to /Applications (or ~/Applications) and open it
set -euo pipefail
cd "${0:A:h}/.."

UNIVERSAL=false
[[ " $* " == *" --universal "* ]] && UNIVERSAL=true

APP=build/DevSweep.app
VERSION=1.1.1
BUNDLE_ID=app.devsweep.DevSweep

echo "› Compiling (release)…"
swift build -c release --product DevSweep
swift build -c release --product devsweep-cli
swift build -c release --product DevSweepWidgets
BIN=$(swift build -c release --show-bin-path)
if $UNIVERSAL; then
  # SwiftPM builds one architecture at a time; build the other and merge them.
  OTHER=$([[ "$(uname -m)" == arm64 ]] && echo x86_64 || echo arm64)
  echo "› Compiling for $OTHER…"
  swift build -c release --product DevSweep --triple "$OTHER-apple-macosx14.0"
  swift build -c release --product devsweep-cli --triple "$OTHER-apple-macosx14.0"
  swift build -c release --product DevSweepWidgets --triple "$OTHER-apple-macosx14.0"
  OTHER_BIN=".build/$OTHER-apple-macosx/release"
  FAT=.build/universal
  mkdir -p "$FAT"
  lipo -create "$BIN/DevSweep" "$OTHER_BIN/DevSweep" -output "$FAT/DevSweep"
  lipo -create "$BIN/devsweep-cli" "$OTHER_BIN/devsweep-cli" -output "$FAT/devsweep-cli"
  lipo -create "$BIN/DevSweepWidgets" "$OTHER_BIN/DevSweepWidgets" -output "$FAT/DevSweepWidgets"
  BIN=$FAT
fi

echo "› Assembling $APP…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Helpers"
cp "$BIN/DevSweep" "$APP/Contents/MacOS/DevSweep"
cp "$BIN/devsweep-cli" "$APP/Contents/Helpers/devsweep"

# The desktop widgets, as a WidgetKit app extension.
APPEX="$APP/Contents/PlugIns/DevSweepWidgets.appex"
mkdir -p "$APPEX/Contents/MacOS"
cp "$BIN/DevSweepWidgets" "$APPEX/Contents/MacOS/DevSweepWidgets"
cat > "$APPEX/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>DevSweepWidgets</string>
  <key>CFBundleDisplayName</key><string>DevSweep</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID.Widgets</string>
  <key>CFBundleExecutable</key><string>DevSweepWidgets</string>
  <key>CFBundlePackageType</key><string>XPC!</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleSupportedPlatforms</key><array><string>MacOSX</string></array>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$(date +%Y%m%d%H%M%S)</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSExtension</key>
  <dict>
    <key>NSExtensionPointIdentifier</key><string>com.apple.widgetkit-extension</string>
  </dict>
</dict>
</plist>
PLIST

if [[ ! -f build/AppIcon.icns || scripts/make-icon.swift -nt build/AppIcon.icns ]]; then
  echo "› Drawing icon…"
  rm -rf build/AppIcon.iconset
  swift scripts/make-icon.swift build/AppIcon.iconset
  iconutil -c icns build/AppIcon.iconset -o build/AppIcon.icns
fi
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>DevSweep</string>
  <key>CFBundleDisplayName</key><string>DevSweep</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key><string>DevSweep</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$(date +%Y%m%d%H%M%S)</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>CFBundleURLTypes</key>
  <array>
    <dict>
      <key>CFBundleURLName</key><string>$BUNDLE_ID</string>
      <key>CFBundleURLSchemes</key><array><string>devsweep</string></array>
    </dict>
  </array>
  <key>NSSupportsAutomaticTermination</key><false/>
  <key>NSDesktopFolderUsageDescription</key><string>DevSweep looks for projects in the folders you choose to find rebuildable files like node_modules and virtual environments.</string>
  <key>NSDocumentsFolderUsageDescription</key><string>DevSweep looks for projects in the folders you choose to find rebuildable files like node_modules and virtual environments.</string>
  <key>NSDownloadsFolderUsageDescription</key><string>DevSweep looks for projects in the folders you choose to find rebuildable files like node_modules and virtual environments.</string>
</dict>
</plist>
PLIST

# Sign with SIGN_IDENTITY, else this Mac's Developer ID Application certificate if it has one,
# else ad hoc. The desktop widgets need a real identity: macOS only runs a sandboxed widget
# extension whose signature carries a Team ID.
IDENTITY=${SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Developer ID Application/ {print $2; exit}')}
IDENTITY=${IDENTITY:--}
SIGN=(codesign --force --sign "$IDENTITY")
if [[ "$IDENTITY" == "-" ]]; then
  echo "› Signing (ad hoc; desktop widgets need a Developer ID — set SIGN_IDENTITY)…"
else
  echo "› Signing with $IDENTITY…"
  SIGN+=(--options runtime --timestamp)
fi
"${SIGN[@]}" "$APP/Contents/Helpers/devsweep"
"${SIGN[@]}" --entitlements scripts/DevSweepWidgets.entitlements "$APPEX"
"${SIGN[@]}" "$APP"

echo "✓ Built $APP ($(du -sh "$APP" | cut -f1))"

if [[ "${1:-}" == "--install" ]]; then
  DEST=/Applications
  [[ -w $DEST ]] || DEST=~/Applications
  mkdir -p "$DEST"
  pkill -x DevSweep 2>/dev/null && sleep 1 || true
  rm -rf "$DEST/DevSweep.app"
  cp -R "$APP" "$DEST/"
  # Let macOS know about the widgets straight away.
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DEST/DevSweep.app" 2>/dev/null || true
  echo "✓ Installed to $DEST/DevSweep.app"
  open "$DEST/DevSweep.app"
fi
