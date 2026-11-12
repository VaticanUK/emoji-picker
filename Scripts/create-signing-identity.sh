#!/bin/bash
# Creates a self-signed code-signing identity so rebuilt apps keep a stable signature, and
# therefore keep their Accessibility permission.
#
# The release workflow reuses this script to import the release certificate in CI: set
# EMOJI_PICKER_P12 and EMOJI_PICKER_P12_PASSWORD to import that certificate instead of making
# one, and EMOJI_PICKER_IDENTITY to its name.
#
# The identity lives in its own keychain, not your login keychain, so building never asks for
# your login keychain password. That keychain's password is random, generated per Mac, and kept
# in a file only your account can read (mode 0600). The keychain locks itself after 5 minutes.
#
# The certificate doesn't need to be trusted: when macOS remembers the Accessibility permission
# it records the certificate's hash, not its trust. So no admin password is needed either.
set -euo pipefail

NAME="${EMOJI_PICKER_IDENTITY:-Emoji Picker Local Signing}"
KEYCHAIN="${EMOJI_PICKER_KEYCHAIN:-$HOME/Library/Keychains/emoji-picker-signing.keychain-db}"
PASS_FILE="${KEYCHAIN%.keychain-db}.pass"

if [[ -f "$KEYCHAIN" && -f "$PASS_FILE" ]] \
   && security unlock-keychain -p "$(cat "$PASS_FILE")" "$KEYCHAIN" 2>/dev/null \
   && [[ "$(security find-identity -p codesigning "$KEYCHAIN" 2>/dev/null || true)" == *"\"$NAME\""* ]]; then
    echo "Signing identity '$NAME' already exists in $KEYCHAIN."
    exit 0
fi

# Anything partial (for example from an older version of this script) holds only a throwaway
# local key, so start again.
if [[ -f "$KEYCHAIN" ]]; then
    security delete-keychain "$KEYCHAIN" 2>/dev/null || rm -f "$KEYCHAIN"
fi
rm -f "$PASS_FILE"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
KEYCHAIN_PASS="$(openssl rand -hex 32)"
if [[ -n "${EMOJI_PICKER_P12:-}" ]]; then
    P12="$EMOJI_PICKER_P12"
    P12_PASS="${EMOJI_PICKER_P12_PASSWORD:?EMOJI_PICKER_P12_PASSWORD must be set with EMOJI_PICKER_P12}"
else
    P12="$TMP/identity.p12"
    P12_PASS="$(openssl rand -hex 16)"
    "$(dirname "$0")/make-certificate.sh" "$NAME" "$P12" "$P12_PASS"
fi

(umask 077; printf '%s' "$KEYCHAIN_PASS" > "$PASS_FILE")
security create-keychain -p "$KEYCHAIN_PASS" "$KEYCHAIN"
security set-keychain-settings -lut 300 "$KEYCHAIN"   # lock after 5 minutes and on sleep
security unlock-keychain -p "$KEYCHAIN_PASS" "$KEYCHAIN"
security import "$P12" -k "$KEYCHAIN" -P "$P12_PASS" -T /usr/bin/codesign
# Only Apple-signed tools (codesign) may use the key without a prompt.
security set-key-partition-list -S apple-tool:,apple: -s -k "$KEYCHAIN_PASS" "$KEYCHAIN" >/dev/null

echo "Created signing identity '$NAME' in $KEYCHAIN."
