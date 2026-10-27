#!/usr/bin/env bash
# Builds "build/Glyph Time.app" from this folder (SwiftPM, no Xcode needed).
# Signs with the Apple Development identity when there is one (macOS then keeps the
# Accessibility allowance across rebuilds), else ad hoc. SIGN_IDENTITY=<identity> signs with
# that instead (scripts/release.sh passes Developer ID). --install copies it to /Applications.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=0.1.2
BUILD=3

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
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>© 2026 Inspired Nation, LLC. MIT License.</string>
</dict>
</plist>
PLIST

IDENTITY=${SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | grep -v REVOKED | grep -o '"Apple Development: [^"]*"' | head -1 | tr -d '"' || true)}
if [[ $IDENTITY == "Developer ID Application"* ]]; then
  codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP" >/dev/null
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
