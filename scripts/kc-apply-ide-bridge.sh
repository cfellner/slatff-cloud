#!/usr/bin/env bash
# Keycloak client for the IDE bridge (docs/IDE-BRIDGE.md). Safe to re-run.
# "ide-bridge": public client (runs on a Mac, cannot keep a secret), only the Device
# Authorization Grant (RFC 8628) is on, access tokens carry audience model-gateway, flat realm
# roles and groups, like Open WebUI's, so the gateway applies the same policy.
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH="/usr/local/bin:/opt/homebrew/bin:/Applications/Docker.app/Contents/Resources/bin:$PATH"
docker compose exec -T keycloak bash -c '
  set -e
  k=/opt/keycloak/bin/kcadm.sh
  KC_CLI_PASSWORD="$KC_BOOTSTRAP_ADMIN_PASSWORD" $k config credentials --server http://localhost:8080 --realm master --user "$KC_BOOTSTRAP_ADMIN_USERNAME" >/dev/null
  id=$($k get clients -r slatff -q clientId=ide-bridge --fields id --format csv --noquotes)
  if [ -z "$id" ]; then
    $k create clients -r slatff -f - >/dev/null <<JSON
{"clientId":"ide-bridge","name":"IDE bridge (device sign-in, local; Xcode, Visual Studio, Qt Creator)","enabled":true,
 "publicClient":true,"standardFlowEnabled":false,"directAccessGrantsEnabled":false,
 "implicitFlowEnabled":false,"serviceAccountsEnabled":false,
 "attributes":{"oauth2.device.authorization.grant.enabled":"true","pkce.code.challenge.method":"S256"},
 "protocolMappers":[
  {"name":"audience model-gateway","protocol":"openid-connect","protocolMapper":"oidc-audience-mapper",
   "config":{"included.custom.audience":"model-gateway","access.token.claim":"true","id.token.claim":"false"}},
  {"name":"realm roles flat","protocol":"openid-connect","protocolMapper":"oidc-usermodel-realm-role-mapper",
   "config":{"claim.name":"roles","multivalued":"true","jsonType.label":"String","access.token.claim":"true","id.token.claim":"false"}},
  {"name":"groups","protocol":"openid-connect","protocolMapper":"oidc-group-membership-mapper",
   "config":{"claim.name":"groups","full.path":"false","access.token.claim":"true","id.token.claim":"false"}}]}
JSON
    echo "created client ide-bridge (device sign-in only)"
  else
    $k update "clients/$id" -r slatff -s "attributes.\"oauth2.device.authorization.grant.enabled\"=true"
    echo "client ide-bridge exists: device sign-in on"
  fi
'
