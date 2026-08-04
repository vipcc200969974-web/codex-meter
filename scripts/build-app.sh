#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

VERSION="${CODEX_METER_VERSION:-0.1.1}"
BUILD_NUMBER="${CODEX_METER_BUILD_NUMBER:-1}"

swift build -c release

APP_DIR="$ROOT_DIR/build/Codex Meter.app"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"

cp "$ROOT_DIR/.build/release/CodexMeter" "$APP_DIR/Contents/MacOS/CodexMeter"
chmod +x "$APP_DIR/Contents/MacOS/CodexMeter"

# Keep the app icon and the editable logo source inside the bundle so the
# packaged app is self-contained and Finder can show the same identity as the
# menu-bar utility.
for resource in AppIcon.icns CodexMeterLogo.svg CodexMeterLogo.png; do
  if [ -f "$ROOT_DIR/Resources/$resource" ]; then
    cp "$ROOT_DIR/Resources/$resource" "$APP_DIR/Contents/Resources/$resource"
  fi
done

/usr/libexec/PlistBuddy -c "Clear dict" "$APP_DIR/Contents/Info.plist" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :CFBundleName string Codex Meter" "$APP_DIR/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleDisplayName string Codex Meter" "$APP_DIR/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string app.codex-meter.prototype" "$APP_DIR/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleExecutable string CodexMeter" "$APP_DIR/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundlePackageType string APPL" "$APP_DIR/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string $VERSION" "$APP_DIR/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleVersion string $BUILD_NUMBER" "$APP_DIR/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$APP_DIR/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :LSMinimumSystemVersion string 14.0" "$APP_DIR/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :LSUIElement bool true" "$APP_DIR/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :NSUserNotificationUsageDescription string Codex Meter uses notifications for low quota alerts." "$APP_DIR/Contents/Info.plist"

echo "$APP_DIR"
