#!/bin/sh
# Creates "Panespace Local Signing": a self-signed code-signing identity in the login keychain, trusted for code
# signing. `make install` signs with it, so the Accessibility grant survives every rebuild (an ad-hoc signature
# changes with each build, and macOS asks again). Run once per Mac; asks for your password to trust it.
set -e
NAME="Panespace Local Signing"
if security find-identity -v -p codesigning | grep -q "$NAME"; then
  echo "$NAME already exists"; exit 0
fi
D=$(mktemp -d); trap 'rm -rf "$D"' EXIT
cat > "$D/cert.cnf" <<CNF
[req]
distinguished_name = dn
prompt = no
x509_extensions = ext
[dn]
CN = $NAME
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CNF
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$D/key.pem" -out "$D/cert.pem" -days 3650 -config "$D/cert.cnf" 2>/dev/null
openssl pkcs12 -export -inkey "$D/key.pem" -in "$D/cert.pem" -out "$D/id.p12" -passout pass:panespace -name "$NAME" -legacy 2>/dev/null \
  || openssl pkcs12 -export -inkey "$D/key.pem" -in "$D/cert.pem" -out "$D/id.p12" -passout pass:panespace -name "$NAME"
security import "$D/id.p12" -k "$HOME/Library/Keychains/login.keychain-db" -P panespace -T /usr/bin/codesign
sudo security add-trusted-cert -d -r trustRoot -p codeSign -k /Library/Keychains/System.keychain "$D/cert.pem"
security find-identity -v -p codesigning | grep "$NAME"
echo "done: next 'make install' signs with it; grant Accessibility once more and it sticks from then on"
