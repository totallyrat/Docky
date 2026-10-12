#!/bin/bash
# Creates a self-signed code-signing certificate, "Docky Local Signing", in your login keychain.
# build.sh signs with it automatically, so rebuilt copies of Docky keep the permissions you
# granted (Accessibility, Calendar, Bluetooth…) instead of macOS treating each build as new.
#
# Remove it any time in Keychain Access (search for "Docky Local Signing").
set -euo pipefail
NAME="Docky Local Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-certificate -c "$NAME" "$KEYCHAIN" >/dev/null 2>&1; then
    echo "\"$NAME\" already exists."
    exit 0
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/cert.cnf" <<CNF
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
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$TMP/cert.cnf" \
    -keyout "$TMP/key.pem" -out "$TMP/cert.pem" 2>/dev/null
/usr/bin/openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -name "$NAME" \
    -out "$TMP/identity.p12" -passout pass:docky
security import "$TMP/identity.p12" -k "$KEYCHAIN" -P docky -T /usr/bin/codesign >/dev/null
echo "Created \"$NAME\". Run ./build.sh again; macOS will ask for permissions one last time."
