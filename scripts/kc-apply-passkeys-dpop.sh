#!/usr/bin/env bash
# Keycloak settings for phishing-resistant sign-in and key-bound tokens (docs/PASSKEYS-DPOP.md).
# Safe to re-run.
# - realm slatff: passkeys on (WebAuthn passwordless policy, discoverable credential, user verification)
# - client ide-bridge: access tokens must be DPoP-bound (RFC 9449)
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH="/usr/local/bin:/opt/homebrew/bin:/Applications/Docker.app/Contents/Resources/bin:$PATH"
docker compose exec -T keycloak bash -c '
  set -e
  k=/opt/keycloak/bin/kcadm.sh
  KC_CLI_PASSWORD="$KC_BOOTSTRAP_ADMIN_PASSWORD" $k config credentials --server http://localhost:8080 --realm master --user "$KC_BOOTSTRAP_ADMIN_USERNAME" >/dev/null
  $k update realms/slatff -s webAuthnPolicyPasswordlessPasskeysEnabled=true \
    -s webAuthnPolicyPasswordlessRpEntityName=SLATFF.Cloud \
    -s webAuthnPolicyPasswordlessRequireResidentKey=Yes \
    -s webAuthnPolicyPasswordlessUserVerificationRequirement=required
  echo "realm slatff: passkeys on (discoverable, user verification required)"
  id=$($k get clients -r slatff -q clientId=ide-bridge --fields id --format csv --noquotes)
  [ -n "$id" ] || { echo "STOP: client ide-bridge missing, run scripts/mac-step6-ide-bridge.sh first"; exit 1; }
  $k update "clients/$id" -r slatff -s "attributes.\"dpop.bound.access.tokens\"=true"
  echo "client ide-bridge: DPoP-bound tokens required"
'
