#!/bin/bash
# Package a VoiceToText.app bundle into a drag-to-install DMG.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$SCRIPT_DIR/.."
BUILD_DIR="$ROOT_DIR/build"
VERSION="$(tr -d '[:space:]' < "$ROOT_DIR/VERSION")"
APP_PATH="${1:-$BUILD_DIR/VoiceToText-${VERSION}.app}"
OUTPUT="${2:-$BUILD_DIR/VoiceToText-${VERSION}.dmg}"
STAGING="$BUILD_DIR/.dmg-staging"

if [ ! -d "$APP_PATH" ]; then
    echo "Error: app bundle not found: $APP_PATH"
    echo "Run scripts/build-macos.sh --release first."
    exit 1
fi

rm -rf "$STAGING" "$OUTPUT"
mkdir -p "$STAGING"
ditto --norsrc --noextattr "$APP_PATH" "$STAGING/语音转文字.app"
ln -s /Applications "$STAGING/Applications"

hdiutil create \
    -volname "语音转文字" \
    -srcfolder "$STAGING" \
    -ov \
    -format UDZO \
    "$OUTPUT"
rm -rf "$STAGING"
echo "DMG complete: $OUTPUT"
