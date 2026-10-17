#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

APP_NAME="EdgeBar"
BUILD_DIR="$ROOT/build"
APP_DIR="$BUILD_DIR/${APP_NAME}.app"
CONTENTS="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS/MacOS"
RESOURCES_DIR="$CONTENTS/Resources"

echo "==> Building release binary…"
swift build -c release --product "$APP_NAME"

BIN_PATH="$(swift build -c release --show-bin-path)/${APP_NAME}"
if [[ ! -x "$BIN_PATH" ]]; then
  echo "error: binary not found at $BIN_PATH" >&2
  exit 1
fi

echo "==> Assembling ${APP_NAME}.app…"
rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"
cp "$BIN_PATH" "$MACOS_DIR/$APP_NAME"
cp "$ROOT/Info.plist" "$CONTENTS/Info.plist"

echo "==> Ad-hoc codesigning…"
codesign --force --deep --sign - "$APP_DIR"

echo "==> Done: $APP_DIR"
echo "    Launch with: open \"$APP_DIR\""
