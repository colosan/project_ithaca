#!/usr/bin/env bash
# Creates a stable, self-signed code-signing identity "Ithaca Local Signing" in this Mac's login keychain (once).
# build.sh uses it when present (falls back to ad-hoc). Why: ad-hoc signatures change every build, so macOS
# treats each update as a new app (privacy permissions, keychain items reset). A stable identity keeps the
# designated requirement the same across updates. Replace with Developer ID when an Apple account exists (ADR-0008).
# The private key never touches the repo: it is generated in a temp dir, imported, and the temp dir is deleted.
set -euo pipefail
# Run it yourself in Terminal: the last step asks for your login keychain password (macOS requires it to let
# codesign use the key without a dialog). Only after that succeeds does it write the marker build.sh reads, so
# unattended builds never block on a keychain dialog.
NAME="${IDENTITY_NAME:-Ithaca Local Signing}"
KC="$HOME/Library/Keychains/login.keychain-db"
MARKER="$HOME/Library/Application Support/Ithaca-Release/signing-identity"

finish() {
  echo "▸ allowing codesign to use the key (enter your login keychain password)"
  security set-key-partition-list -S apple-tool:,apple:,codesign: -s -l "$NAME" "$KC" >/dev/null
  mkdir -p "$(dirname "$MARKER")"; chmod 700 "$(dirname "$MARKER")"
  printf '%s\n' "$NAME" > "$MARKER"
  echo "✓ build.sh will sign with '$NAME' (remove $MARKER to go back to ad-hoc)"
}

if security find-certificate -c "$NAME" "$KC" >/dev/null 2>&1; then
  echo "✓ '$NAME' already in the login keychain"; finish; exit 0
fi

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
chmod 700 "$TMP"
cat > "$TMP/cert.cnf" <<EOF
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
subjectKeyIdentifier = hash
EOF
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$TMP/cert.cnf" \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" 2>/dev/null
PASS="$(openssl rand -hex 16)"
# macOS `security` reads only legacy PKCS#12 algorithms; LibreSSL (/usr/bin/openssl) defaults to them, OpenSSL 3 needs -legacy.
LEGACY=""; openssl version | grep -q '^OpenSSL 3' && LEGACY="-legacy"
openssl pkcs12 -export $LEGACY -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -name "$NAME" \
  -out "$TMP/id.p12" -passout "pass:$PASS"
# -T: let codesign use the key without a keychain prompt.
security import "$TMP/id.p12" -k "$KC" -P "$PASS" -T /usr/bin/codesign -T /usr/bin/security >/dev/null
echo "✓ created '$NAME' in the login keychain"
security find-certificate -c "$NAME" -Z "$KC" | grep SHA-1
finish
