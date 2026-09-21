#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

VERSION="${CODEX_METER_VERSION:-0.1.2}"
BUILD_NUMBER="${CODEX_METER_BUILD_NUMBER:-1}"
OUTPUT_DIR="${CODEX_METER_OUTPUT_DIR:-$ROOT_DIR/dist}"
APP_DIR="$ROOT_DIR/build/Codex Meter.app"
ZIP_PATH="$OUTPUT_DIR/Codex-Meter-macOS-$VERSION.zip"
DMG_PATH="$OUTPUT_DIR/Codex-Meter-macOS-$VERSION.dmg"

"$ROOT_DIR/scripts/build-app.sh"

# The app is intentionally ad-hoc signed so anyone can install the downloaded
# artifact locally. A Developer ID certificate can be supplied later for a
# notarized release without changing the packaging layout.
codesign --force --deep --sign - "$APP_DIR"
codesign --verify --deep --strict --verbose=2 "$APP_DIR"

mkdir -p "$OUTPUT_DIR"
rm -f "$ZIP_PATH" "$DMG_PATH"

ditto -c -k --sequesterRsrc --keepParent "$APP_DIR" "$ZIP_PATH"

STAGING_DIR="$(mktemp -d "${TMPDIR:-/tmp}/codex-meter-dmg.XXXXXX")"
trap 'rm -rf "$STAGING_DIR"' EXIT
ditto "$APP_DIR" "$STAGING_DIR/Codex Meter.app"
ln -s /Applications "$STAGING_DIR/Applications"
hdiutil create \
  -volname "Codex Meter" \
  -srcfolder "$STAGING_DIR" \
  -ov \
  -format UDZO \
  "$DMG_PATH" >/dev/null

echo "version=$VERSION"
echo "build=$BUILD_NUMBER"
echo "zip=$ZIP_PATH"
echo "dmg=$DMG_PATH"
