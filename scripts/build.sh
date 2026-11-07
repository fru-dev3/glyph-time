#!/usr/bin/env bash
# Builds "build/Glyph Time.app" from this folder (SwiftPM, no Xcode needed).
# Signs with the Apple Development identity when there is one (macOS then keeps the
# Accessibility allowance across rebuilds), else ad hoc. SIGN_IDENTITY=<identity> signs with
# that instead (scripts/release.sh passes Developer ID). --install copies it to /Applications.
set -euo pipefail

# Fru, 2026-10-31, stated three times and absolute: nothing executes on the Mac he works on.
# Builds, tests, simulators, screenshots and microphone checks go to the unattended desktop or to
# a laptop deliberately marked as a test host. The desktop has no battery and needs no flag.
# Detecting a battery rather than matching a computer name, because a name match wrongly refuses
# on a dedicated test laptop whose name happens to match the pattern.
if pmset -g batt 2>/dev/null | grep -q InternalBattery && [[ -z ${GLYPH_UI_HOST:-} ]]; then
  echo >&2 "Nothing executes on the Mac being worked on. Run this on the unattended desktop,"
  echo >&2 "or on a test laptop with GLYPH_UI_HOST=1 set."
  exit 2
fi
cd "$(dirname "$0")/.."

VERSION=0.1.20
BUILD=20

[[ -d /Applications/Xcode.app ]] && export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer} # the on-device model's macros
swift build -c release --product GlyphTime

APP="build/Glyph Time.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/GlyphTime "$APP/Contents/MacOS/GlyphTime"
[[ -f assets/AppIcon.icns ]] && cp assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp assets/MenuBar.png assets/MenuBar@2x.png "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Glyph Time</string>
  <key>CFBundleDisplayName</key><string>Glyph Time</string>
  <key>CFBundleIdentifier</key><string>dev.fru.time</string>
  <key>CFBundleExecutable</key><string>GlyphTime</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSMicrophoneUsageDescription</key><string>Glyph Time listens only while you tap the mic, to hear a project name instead of typing it. Speech is turned into text on this Mac and never kept.</string>
  <key>NSSpeechRecognitionUsageDescription</key><string>Glyph Time turns what you say into text on this Mac, to name a session without typing.</string>
  <key>NSAppleEventsUsageDescription</key><string>With Track apps and tabs on, Glyph Time reads the front tab's title and site in your browser, to show which sites your hours go to. It stays in your own folder on this Mac; private windows are never read.</string>
  <key>NSHumanReadableCopyright</key><string>© 2026 Inspired Nation, LLC. MIT License.</string>
</dict>
</plist>
PLIST

IDENTITY=${SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | grep -v REVOKED | grep -o '"Apple Development: [^"]*"' | head -1 | tr -d '"' || true)}
if [[ $IDENTITY == "Developer ID Application"* ]]; then
  # The hardened runtime sends Apple Events (a browser's front tab) only with this entitlement.
  cat > build/entitlements.plist <<ENT
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>com.apple.security.automation.apple-events</key><true/></dict></plist>
ENT
  codesign --force --options runtime --timestamp --entitlements build/entitlements.plist --sign "$IDENTITY" "$APP" >/dev/null
else
  codesign --force --sign "${IDENTITY:--}" "$APP" >/dev/null
fi
echo "Built $APP $VERSION (signed: ${IDENTITY:-ad-hoc})"

for arg in "$@"; do
  case "$arg" in
    --install)
      pkill -x GlyphTime 2>/dev/null || true
      rm -rf "/Applications/Glyph Time.app"
      cp -R "$APP" /Applications/
      echo "Installed /Applications/Glyph Time.app"
      ;;
  esac
done
