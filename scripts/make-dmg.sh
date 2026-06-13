#!/bin/bash
# Package VoiceStick.app into a signed and optionally notarized DMG.
#
# Usage:
#   scripts/make-dmg.sh
#   scripts/make-dmg.sh build/VoiceStick-<version>.app
#   scripts/make-dmg.sh build/VoiceStick-<version>.app build/VoiceStick-<version>.dmg

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$SCRIPT_DIR/.."
BUILD_DIR="$ROOT_DIR/build"
VERSION="$(tr -d '[:space:]' < "$ROOT_DIR/VERSION")"
APP_PATH="${1:-$BUILD_DIR/VoiceStick-${VERSION}.app}"
OUTPUT="${2:-$BUILD_DIR/VoiceStick-${VERSION}.dmg}"
ENTITLEMENTS="$ROOT_DIR/desktop/macos/VoiceStick.entitlements"
STAGING_DIR="$BUILD_DIR/.dmg-staging"
VOLUME_NAME="VoiceStick"

if [ ! -d "$APP_PATH" ]; then
    echo "Error: Application bundle not found: $APP_PATH"
    exit 1
fi

if [ ! -f "$ENTITLEMENTS" ]; then
    echo "Error: entitlements file not found: $ENTITLEMENTS"
    exit 1
fi

CODESIGN_IDENTITY="-"
if security find-identity -v -p codesigning 2>/dev/null | grep -q "Developer ID Application"; then
    CODESIGN_IDENTITY="$(security find-identity -v -p codesigning | grep "Developer ID Application" | head -1 | awk -F'"' '{print $2}')"
fi

sign_code() {
    local path="$1"
    local entitlements="${2:-}"
    codesign --remove-signature "$path" 2>/dev/null || true
    local args=(--force --options runtime)
    if [ -n "$entitlements" ]; then
        args+=(--entitlements "$entitlements")
    fi
    if [ "$CODESIGN_IDENTITY" != "-" ]; then
        codesign "${args[@]}" --sign "$CODESIGN_IDENTITY" "$path"
    else
        codesign "${args[@]}" --sign - "$path"
    fi
}

sign_embedded_code() {
    local app_dir="$1"
    local frameworks_dir="$app_dir/Contents/Frameworks"
    if [ ! -d "$frameworks_dir" ]; then
        return
    fi

    while IFS= read -r -d '' code_path; do
        echo "Signing embedded code: ${code_path#$app_dir/Contents/}"
        sign_code "$code_path"
    done < <(find "$frameworks_dir" -depth \( -name "*.app" -o -name "*.xpc" -o -name "*.framework" -o -name "*.bundle" -o -name "*.dylib" \) -print0)
}

echo "Signing app before DMG packaging..."
xattr -cr "$APP_PATH" 2>/dev/null || true
if [ "$CODESIGN_IDENTITY" != "-" ]; then
    echo "Using: $CODESIGN_IDENTITY"
else
    echo "Using ad-hoc signature."
fi
sign_embedded_code "$APP_PATH"
sign_code "$APP_PATH" "$ENTITLEMENTS"

echo "Verifying app signature..."
codesign --verify --deep --strict --verbose=2 "$APP_PATH"

echo "Checking app entitlements..."
if [ "$CODESIGN_IDENTITY" != "-" ]; then
    if ! codesign -d --entitlements :- "$APP_PATH" 2>/dev/null | plutil -extract com.apple.security.cs.disable-library-validation raw - 2>/dev/null | grep -Eq '^(1|true)$'; then
        echo "Error: app signature is missing com.apple.security.cs.disable-library-validation."
        exit 1
    fi
else
    echo "Skipping entitlement check for ad-hoc signature."
fi

rm -rf "$STAGING_DIR" "$OUTPUT"
mkdir -p "$STAGING_DIR"
ditto --norsrc --noextattr "$APP_PATH" "$STAGING_DIR/VoiceStick.app"
ln -s /Applications "$STAGING_DIR/Applications"

echo "Creating DMG..."
hdiutil create \
    -volname "$VOLUME_NAME" \
    -srcfolder "$STAGING_DIR" \
    -ov \
    -format UDZO \
    "$OUTPUT"
rm -rf "$STAGING_DIR"

if xcrun notarytool history --keychain-profile "AC_PASSWORD" >/dev/null 2>&1; then
    echo "Submitting DMG for notarization..."
    xcrun notarytool submit "$OUTPUT" --keychain-profile "AC_PASSWORD" --wait
    xcrun stapler staple "$OUTPUT"
else
    echo "Skipping notarization: keychain profile AC_PASSWORD was not found."
fi

echo "DMG complete: $OUTPUT"