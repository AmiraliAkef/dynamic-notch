#!/bin/zsh
# Creates a self-signed code-signing certificate in the login keychain.
#
# Why: ad-hoc signatures change on every build, and macOS ties privacy grants
# (Full Disk Access, System Audio Recording, Bluetooth) to the signature, so
# they'd reset after each rebuild. A stable certificate keeps them.
set -euo pipefail

NAME="Dynamic Notch Local Signing"
KEYCHAIN=~/Library/Keychains/login.keychain-db

# macOS only ties permissions to a certificate it trusts for code signing;
# otherwise grants are pinned to one build's hash and lost on rebuild.
# Asks for your password.
trust() {
  local pem=$(mktemp)
  security find-certificate -c "$NAME" -p $KEYCHAIN > "$pem"
  security add-trusted-cert -r trustRoot -p codeSign -k $KEYCHAIN "$pem"
  rm -f "$pem"
}

if security find-certificate -c "$NAME" $KEYCHAIN >/dev/null 2>&1; then
  if security find-identity -v -p codesigning | grep -q "$NAME"; then
    echo "Certificate '$NAME' already exists and is trusted."
  else
    trust
    echo "Trusted '$NAME' for code signing."
  fi
  exit 0
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/cert.conf" <<CONF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
CONF

openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -config "$TMP/cert.conf" 2>/dev/null
PASS=$(openssl rand -hex 16)
openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
  -name "$NAME" -out "$TMP/cert.p12" -passout pass:"$PASS" \
  -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1 2>/dev/null
# -T lets codesign use the key without a keychain prompt.
security import "$TMP/cert.p12" -k ~/Library/Keychains/login.keychain-db \
  -P "$PASS" -T /usr/bin/codesign >/dev/null
trust
echo "Created and trusted '$NAME' in your login keychain."
