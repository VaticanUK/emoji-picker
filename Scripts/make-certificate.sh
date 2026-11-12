#!/bin/bash
# Writes a self-signed code-signing certificate and its private key as a PKCS12 file.
# Usage: Scripts/make-certificate.sh <common name> <output.p12> <p12 password>
set -euo pipefail

NAME="$1"
OUT="$2"
PASS="$3"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/openssl.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CNF

openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -config "$TMP/openssl.cnf" 2>/dev/null
# -legacy keeps the PKCS12 readable by macOS `security` on OpenSSL 3; LibreSSL rejects the flag.
(umask 077
 openssl pkcs12 -export -legacy -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
     -out "$OUT" -passout "pass:$PASS" 2>/dev/null \
   || openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
     -out "$OUT" -passout "pass:$PASS")
