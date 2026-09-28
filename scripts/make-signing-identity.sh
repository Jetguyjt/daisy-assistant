#!/bin/bash
# Makes a local code-signing certificate, "Daisy Local Signing", in the login keychain, once.
#
# Signed ad hoc, every build of Daisy is a new app to macOS, so it asks for the microphone (and
# Contacts, Automation...) again after each install. Signed with the same certificate every time,
# the app keeps its identity and its permissions across rebuilds. The certificate is self-signed and
# only means something on this Mac. Anyone who can use it could sign an app that macOS treats as
# Daisy, so it stays in the login keychain, usable by codesign.
#
#   bash scripts/make-signing-identity.sh
set -euo pipefail
NAME="${DAISY_SIGN_IDENTITY:-Daisy Local Signing}"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-certificate -c "$NAME" "$KEYCHAIN" >/dev/null 2>&1; then
  echo "\"$NAME\" is already in the login keychain."
  exit 0
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/daisy-signing.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
cat > "$WORK/cert.conf" <<EOF
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
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$WORK/cert.conf" \
  -keyout "$WORK/key.pem" -out "$WORK/cert.pem" 2>/dev/null
# A throwaway password: the .p12 only exists for the import, inside the temp folder.
PASS="$(/usr/bin/openssl rand -hex 16)"
/usr/bin/openssl pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" -name "$NAME" \
  -out "$WORK/identity.p12" -passout "pass:$PASS"
security import "$WORK/identity.p12" -k "$KEYCHAIN" -P "$PASS" -T /usr/bin/codesign >/dev/null
echo "Added \"$NAME\" to the login keychain. The first build that uses it may ask to allow codesign to use the key: choose Always Allow."
