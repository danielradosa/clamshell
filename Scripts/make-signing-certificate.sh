#!/bin/bash
# Creates a stable, self-signed code-signing identity in the login keychain.
#
# WHY THIS EXISTS
#
# macOS ties a Screen Recording grant to the app's designated requirement. For an
# ad-hoc signature that requirement is the binary's code hash, which changes on
# every single build — so every rebuild looks like a brand-new app to TCC, the
# old grant is stranded, and the user is asked for permission again. Granting it
# repeatedly never helps, because each grant is against a build that no longer
# exists.
#
# Signing with a certificate instead makes the requirement
#     identifier "com.danielradosa.clamshell" and certificate leaf = H"..."
# which depends on the bundle ID and this certificate, not on the binary. Grant
# once and it stays granted across every future build.
#
# The certificate is local, self-signed and used only to give this app a stable
# identity on this machine. It is not a developer ID, it grants nothing, and it
# is not trusted for anything else. Remove it any time with:
#     Scripts/make-signing-certificate.sh --remove

set -euo pipefail

NAME="Clamshell Local Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if [[ "${1:-}" == "--remove" ]]; then
    security delete-identity -c "$NAME" "$KEYCHAIN" 2>/dev/null \
        && echo "Removed '$NAME' from the login keychain." \
        || echo "No '$NAME' identity found."
    exit 0
fi

if security find-certificate -c "$NAME" "$KEYCHAIN" >/dev/null 2>&1; then
    echo "Signing identity '$NAME' already exists — nothing to do."
    exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "Creating a self-signed code-signing certificate…"
openssl req -newkey rsa:2048 -nodes \
    -keyout "$WORK/key.pem" -x509 -days 3650 -out "$WORK/cert.pem" \
    -subj "/CN=$NAME/O=Clamshell/C=US" \
    -addext "basicConstraints=critical,CA:false" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=critical,codeSigning" 2>/dev/null

# Apple's Security framework rejects OpenSSL 3's default PKCS#12 MAC, so the
# bundle has to be written with the legacy SHA-1 algorithms it understands.
openssl pkcs12 -export -out "$WORK/identity.p12" \
    -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
    -name "$NAME" -passout pass:clamshell \
    -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1 2>/dev/null

# -T lets codesign use the private key without prompting for the keychain.
security import "$WORK/identity.p12" -k "$KEYCHAIN" -P clamshell -T /usr/bin/codesign

echo
echo "Done. '$NAME' is now in your login keychain."
echo "Builds will use it automatically, and the Screen Recording grant will stick."
