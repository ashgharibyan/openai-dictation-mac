#!/bin/zsh
# One-time: creates a self-signed code-signing identity named "Dictate Local Signing".
# Signing every build with the same identity keeps macOS Accessibility and Microphone grants
# valid across rebuilds (ad hoc signatures change on every build, so macOS forgets them).
#
#   ./scripts/create-signing-cert.sh                 # into your login keychain
#   KEYCHAIN=/path/to/other.keychain-db ./scripts/create-signing-cert.sh
set -euo pipefail
NAME="Dictate Local Signing"
KEYCHAIN="${KEYCHAIN:-$HOME/Library/Keychains/login.keychain-db}"

if security find-identity -v -p codesigning "$KEYCHAIN" 2>/dev/null | grep -q "$NAME"; then
  echo "\"$NAME\" already exists and is valid."; exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/cert.cnf" <<EOF
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
EOF

/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$TMP/cert.cnf" \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" 2>/dev/null
PASS="dictate-$RANDOM$RANDOM"
/usr/bin/openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -name "$NAME" \
  -out "$TMP/identity.p12" -passout "pass:$PASS" 2>/dev/null

security import "$TMP/identity.p12" -k "$KEYCHAIN" -P "$PASS" -T /usr/bin/codesign >/dev/null
echo "Imported \"$NAME\" into $KEYCHAIN."

# codesign only uses identities macOS trusts. This trusts the certificate for code signing
# only, for your user account; macOS asks for your login password to approve it.
echo "Trusting it for code signing (macOS will ask for your password)…"
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$TMP/cert.pem"

security find-identity -v -p codesigning "$KEYCHAIN" | grep "$NAME" || { echo "Identity is not valid yet."; exit 1; }
echo "Rebuild with ./scripts/build-app.sh; it picks this identity up automatically."
