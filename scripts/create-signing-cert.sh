#!/bin/bash
# Creates a self-signed code-signing certificate ("Peek Local Signing") in your
# login keychain. build.sh signs with it so macOS keeps Peek's permissions
# (Calendar, Location, Bluetooth, Automation) across rebuilds.
# It can only sign code, never leaves this Mac, and costs nothing.
set -euo pipefail
NAME="${PEEK_SIGN_IDENTITY:-Peek Local Signing}"

if security find-certificate -c "$NAME" >/dev/null 2>&1; then
  echo "\"$NAME\" already exists — nothing to do."
  exit 0
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/peek-cert.XXXXXX")"
cleanup() { /bin/rm -f "$WORK/key.pem" "$WORK/cert.pem" "$WORK/peek.p12" "$WORK/cert.cnf"; /bin/rmdir "$WORK"; }
trap cleanup EXIT
umask 077

cat > "$WORK/cert.cnf" <<CNF
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
subjectKeyIdentifier = hash
CNF

/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -keyout "$WORK/key.pem" -out "$WORK/cert.pem" -config "$WORK/cert.cnf" 2>/dev/null
PASS="$(/usr/bin/openssl rand -hex 16)"
/usr/bin/openssl pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
  -name "$NAME" -out "$WORK/peek.p12" -passout "pass:$PASS" 2>/dev/null
security import "$WORK/peek.p12" -k "$HOME/Library/Keychains/login.keychain-db" \
  -P "$PASS" -T /usr/bin/codesign -T /usr/bin/security >/dev/null

echo "Created \"$NAME\" in your login keychain."
echo "Rebuild with ./build.sh — the first build may ask to let codesign use the key: choose Always Allow."
