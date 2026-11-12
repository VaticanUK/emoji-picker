#!/bin/bash
# Creates the certificate the GitHub release workflow signs every release with, and prints how
# to store it as repository secrets. Run it once, when setting up releases.
#
# Every release must be signed with the same certificate, or macOS treats each new version as a
# different app and people have to grant Accessibility again after updating. So keep a copy
# (for example in a password manager): GitHub secrets can't be read back. If it's lost, make a
# new one; everyone then grants Accessibility once more on their next update.
#
# Usage: Scripts/create-release-certificate.sh [output folder]
set -euo pipefail

NAME="Emoji Picker Release Signing"
OUT="${1:-$HOME/emoji-picker-release-certificate}"

if [[ -e "$OUT" ]]; then
    echo "$OUT already exists. Move it away first, or pass another folder." >&2
    exit 1
fi

umask 077
mkdir -p "$OUT"
PASS="$(openssl rand -hex 16)"
"$(dirname "$0")/make-certificate.sh" "$NAME" "$OUT/release-signing.p12" "$PASS"
printf '%s' "$PASS" > "$OUT/password.txt"
base64 -i "$OUT/release-signing.p12" > "$OUT/release-signing.p12.base64"

cat <<MSG
Created '$NAME' in $OUT (readable only by you).

Add it to the GitHub repository as two secrets, either with the GitHub CLI from this folder:

  gh secret set MACOS_CERT_P12 < "$OUT/release-signing.p12.base64"
  gh secret set MACOS_CERT_PASSWORD < "$OUT/password.txt"

or in the repository's Settings > Secrets and variables > Actions > New repository secret,
pasting the contents of release-signing.p12.base64 as MACOS_CERT_P12 and of password.txt as
MACOS_CERT_PASSWORD.

Then keep release-signing.p12 and password.txt somewhere safe, such as a password manager, and
delete $OUT.
MSG
