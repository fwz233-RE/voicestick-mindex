#!/bin/bash
# Build the macOS menu bar voice-to-text app bundle.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$SCRIPT_DIR/.."
PACKAGE_DIR="$ROOT_DIR/desktop/macos"
BUILD_DIR="$ROOT_DIR/build"
VERSION="$(tr -d '[:space:]' < "$ROOT_DIR/VERSION")"
CONFIG="${1:---release}"

case "$CONFIG" in
    --release) SWIFT_CONFIG=release ;;
    --debug) SWIFT_CONFIG=debug ;;
    *) echo "Usage: $0 [--release|--debug]"; exit 1 ;;
esac

if [ -z "$VERSION" ]; then
    echo "Error: VERSION is empty"
    exit 1
fi

mkdir -p "$BUILD_DIR"
PLIST="$PACKAGE_DIR/Sources/VoiceToTextApp/Info.plist"
APP_DIR="$BUILD_DIR/VoiceToText-${VERSION}.app"

for ARCH in arm64 x86_64; do
    SCRATCH="$PACKAGE_DIR/.build-$ARCH"
    rm -rf "$SCRATCH"
    echo "Building VoiceToTextApp for $ARCH..."
    swift build \
        --package-path "$PACKAGE_DIR" \
        -c "$SWIFT_CONFIG" \
        --arch "$ARCH" \
        --scratch-path "$SCRATCH"
done

ARM_BINARY="$PACKAGE_DIR/.build-arm64/arm64-apple-macosx/$SWIFT_CONFIG/VoiceToTextApp"
X86_BINARY="$PACKAGE_DIR/.build-x86_64/x86_64-apple-macosx/$SWIFT_CONFIG/VoiceToTextApp"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
lipo -create "$ARM_BINARY" "$X86_BINARY" -output "$APP_DIR/Contents/MacOS/VoiceToTextApp"
cp "$PLIST" "$APP_DIR/Contents/Info.plist"

codesign --force --deep --sign - "$APP_DIR"
codesign --verify --deep --strict "$APP_DIR"
echo "App complete: $APP_DIR"
