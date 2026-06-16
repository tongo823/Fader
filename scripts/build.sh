#!/bin/bash
# Dev build: regenerate the Xcode project, build Debug (ad-hoc signed), launch.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
DEV="/Applications/Xcode.app/Contents/Developer"

echo "▸ Generating Xcode project…"
xcodegen generate >/dev/null

echo "▸ Building (Debug)…"
DEVELOPER_DIR="$DEV" xcodebuild -project Fader.xcodeproj -scheme Fader \
  -configuration Debug -derivedDataPath build build >/dev/null

APP="build/Build/Products/Debug/Fader.app"
[ -d "$APP" ] || { echo "error: build product missing" >&2; exit 1; }

echo "▸ Relaunching…"
pkill -f "Fader.app/Contents/MacOS/Fader" 2>/dev/null || true
sleep 1
open "$APP"
echo "✅ $APP"
