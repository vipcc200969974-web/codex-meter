#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECK_DIR="$(mktemp -d)"
trap 'rm -rf "$CHECK_DIR"' EXIT
xcrun swiftc -sdk "${CODEX_METER_SDK:-$(xcrun --sdk macosx --show-sdk-path)}" \
  -module-cache-path "$ROOT_DIR/.build/cleanup-module-cache" \
  "$ROOT_DIR/Sources/CodexMeter/CodexCleanup.swift" "$ROOT_DIR/scripts/CodexCleanupChecks.swift" \
  -o "$CHECK_DIR/cleanup-checks"
"$CHECK_DIR/cleanup-checks"
