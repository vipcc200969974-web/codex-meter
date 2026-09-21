#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_PATH="$ROOT_DIR/build/Codex Meter.app"

if [ ! -d "$APP_PATH" ]; then
  "$ROOT_DIR/scripts/build-app.sh" >/dev/null
fi

pkill -x CodexMeter 2>/dev/null || true
open -n "$APP_PATH"
