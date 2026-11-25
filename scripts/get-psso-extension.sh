#!/usr/bin/env bash
# Downloads the University of Oslo Keycloak Platform SSO extension into keycloak/providers/
# and verifies it the way the project's README describes: SHA-256 checksum, then the SSH
# signature over the checksum. The signing key is cross-checked against the key GitHub
# publishes for the maintainer. The jar is GPL-2.0-or-later and is never committed here.
# Usage: ./scripts/get-psso-extension.sh [version]   e.g. 0.58b; default: latest release
set -euo pipefail
cd "$(dirname "$0")/.."
REPO=unioslo/keycloak-psso-extension
SIGNER=franciaa@uio.no
GH_USER=oculos
ver="${1:-}"
if [ -n "$ver" ]; then base="https://github.com/$REPO/releases/download/$ver"; ref="$ver"
else base="https://github.com/$REPO/releases/latest/download"; ref="main"; fi

tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
cd "$tmp"
echo "Downloading from $base"
for f in keycloak-psso.jar keycloak-psso.jar.sha256 keycloak-psso.jar.sha256.sig; do
  curl -fsSL -o "$f" "$base/$f" || { echo "Could not download $f. Check the release exists: https://github.com/$REPO/releases" >&2; exit 1; }
done
curl -fsSL -o allowed_signers "https://raw.githubusercontent.com/$REPO/$ref/allowed_signers"

echo "1/3 signing key matches the key GitHub publishes for $GH_USER"
key=$(awk '{print $3}' allowed_signers | head -1)
curl -fsSL "https://api.github.com/users/$GH_USER/ssh_signing_keys" | grep -qF "$key" \
  || { echo "FAIL: allowed_signers key not found among $GH_USER's GitHub signing keys" >&2; exit 1; }

echo "2/3 checksum"
shasum -a 256 -c keycloak-psso.jar.sha256

echo "3/3 signature over the checksum"
ssh-keygen -Y verify -f allowed_signers -I "$SIGNER" -n file -s keycloak-psso.jar.sha256.sig < keycloak-psso.jar.sha256

cd - >/dev/null
cp "$tmp/keycloak-psso.jar" keycloak/providers/keycloak-psso.jar
cp "$tmp/keycloak-psso.jar.sha256" "$tmp/keycloak-psso.jar.sha256.sig" keycloak/providers/
echo
echo "Verified and installed: keycloak/providers/keycloak-psso.jar"
echo "Next: set KC_FEATURES=declarative-ui in .env, then: docker compose up -d keycloak"
echo "Then follow docs/PLATFORM-SSO.md for the realm settings."
