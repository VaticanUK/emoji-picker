#!/bin/bash
# Builds build/EmojiPicker.app. Usage: Scripts/make-app.sh [debug|release]
#
# Optional environment:
#   UNIVERSAL=1             build for both Apple Silicon and Intel (used for releases)
#   APP_VERSION=1.2.0       version shown in Finder (CFBundleShortVersionString)
#   APP_BUILD=42            build number (CFBundleVersion); defaults to APP_VERSION
#   REQUIRE_SIGNING=1       fail instead of falling back to ad-hoc signing
#   EMOJI_PICKER_IDENTITY   certificate name (default "Emoji Picker Local Signing")
#   EMOJI_PICKER_KEYCHAIN   keychain holding it (see create-signing-identity.sh)
set -euo pipefail

CONFIG="${1:-debug}"
IDENTITY="${EMOJI_PICKER_IDENTITY:-Emoji Picker Local Signing}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

APP="$ROOT/build/EmojiPicker.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# UNIVERSAL=1 builds one binary for both Apple Silicon and Intel.
ARCH_ARGS=()
if [[ "${UNIVERSAL:-0}" == 1 ]]; then
    ARCH_ARGS=(--arch arm64 --arch x86_64)
fi
swift build -c "$CONFIG" ${ARCH_ARGS[@]+"${ARCH_ARGS[@]}"}
BIN_PATH="$(swift build -c "$CONFIG" ${ARCH_ARGS[@]+"${ARCH_ARGS[@]}"} --show-bin-path)"

cp "$BIN_PATH/EmojiPicker" "$APP/Contents/MacOS/EmojiPicker"
cp -R "$BIN_PATH/PickerCore_PickerCore.bundle" "$APP/Contents/Resources/"
cp "$ROOT/Scripts/Info.plist" "$APP/Contents/Info.plist"
if [[ -n "${APP_VERSION:-}" ]]; then
    plutil -replace CFBundleShortVersionString -string "$APP_VERSION" "$APP/Contents/Info.plist"
    plutil -replace CFBundleVersion -string "${APP_BUILD:-$APP_VERSION}" "$APP/Contents/Info.plist"
fi

# The identity lives in its own keychain (see create-signing-identity.sh), so signing never
# touches the login keychain or asks for its password.
KEYCHAIN="${EMOJI_PICKER_KEYCHAIN:-$HOME/Library/Keychains/emoji-picker-signing.keychain-db}"
PASS_FILE="${KEYCHAIN%.keychain-db}.pass"
signed=false
if [[ -f "$KEYCHAIN" && -f "$PASS_FILE" ]] \
   && security unlock-keychain -p "$(cat "$PASS_FILE")" "$KEYCHAIN" 2>/dev/null; then
    # The certificate is untrusted by design, so look it up without -v and sign by its hash.
    hash="$(security find-identity -p codesigning "$KEYCHAIN" 2>/dev/null \
        | awk -v name="\"$IDENTITY\"" 'index($0, name) { print $2; exit }' || true)"
    if [[ -n "$hash" ]] && codesign --force --deep --keychain "$KEYCHAIN" --sign "$hash" "$APP"; then
        signed=true
    else
        echo "WARNING: signing with '$IDENTITY' from $KEYCHAIN failed."
    fi
fi
if [[ "$signed" != true ]]; then
    if [[ "${REQUIRE_SIGNING:-0}" == 1 ]]; then
        echo "ERROR: couldn't sign with '$IDENTITY' and REQUIRE_SIGNING=1." >&2
        exit 1
    fi
    codesign --force --deep --sign - "$APP"
    echo "WARNING: ad-hoc signed; Accessibility permission will reset on every rebuild. Run Scripts/create-signing-identity.sh"
fi

echo "Built $APP"
