#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$SCRIPT_DIR"
APP_DIR="$REPO_ROOT/app"
APP_NAME="SuperSamuel"
BUILD_CONFIGURATION="${BUILD_CONFIGURATION:-release}"

SRC_APP="$APP_DIR/$APP_NAME.app"
INFO_PLIST="$APP_DIR/Info.plist"
BUILD_BIN="$APP_DIR/.build/$BUILD_CONFIGURATION/$APP_NAME"
INSTALLED_APP="$HOME/Applications/$APP_NAME.app"

mkdir -p "$HOME/Applications"

cd "$APP_DIR"
swift build -c "$BUILD_CONFIGURATION"

rm -rf "$SRC_APP"
mkdir -p "$SRC_APP/Contents/MacOS"
mkdir -p "$SRC_APP/Contents/Resources"
cp "$INFO_PLIST" "$SRC_APP/Contents/Info.plist"
cp -f "$BUILD_BIN" "$SRC_APP/Contents/MacOS/$APP_NAME"
cp "$APP_DIR/Resources/AppIcon.icns" "$SRC_APP/Contents/Resources/AppIcon.icns"

codesign --force --deep --sign - \
  --identifier com.supersamuel.app \
  -r='designated => identifier "com.supersamuel.app"' \
  "$SRC_APP"

if pgrep -x "$APP_NAME" >/dev/null 2>&1; then
  osascript -e 'tell application "SuperSamuel" to quit' >/dev/null 2>&1 || true

  for _ in {1..20}; do
    if ! pgrep -x "$APP_NAME" >/dev/null 2>&1; then
      break
    fi
    sleep 0.2
  done

  if pgrep -x "$APP_NAME" >/dev/null 2>&1; then
    pkill -x "$APP_NAME" >/dev/null 2>&1 || true
    sleep 0.5
  fi
fi

rm -rf "$INSTALLED_APP"
ditto "$SRC_APP" "$INSTALLED_APP"

open "$INSTALLED_APP"
