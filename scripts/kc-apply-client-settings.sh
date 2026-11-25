#!/usr/bin/env bash
# Applies client settings to a realm that was already imported (the realm file is only
# imported on the very first start). Safe to re-run.
# Currently:
# - allowed sign-out return addresses ("Valid post logout redirect URIs") for open-webui and
#   jitsi. Without them, signing out ends on Keycloak's "Invalid redirect uri".
# - audience "model-gateway" in open-webui's access tokens, so the model gateway accepts them.
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH="/usr/local/bin:/opt/homebrew/bin:/Applications/Docker.app/Contents/Resources/bin:$PATH"
docker compose exec -T keycloak bash -c '
  set -e
  k=/opt/keycloak/bin/kcadm.sh
  KC_CLI_PASSWORD="$KC_BOOTSTRAP_ADMIN_PASSWORD" $k config credentials --server http://localhost:8080 --realm master --user "$KC_BOOTSTRAP_ADMIN_USERNAME" >/dev/null
  set_logout() {
    id=$($k get clients -r slatff -q clientId="$1" --fields id --format csv --noquotes)
    [ -n "$id" ] || { echo "client $1 not found"; return; }
    $k update "clients/$id" -r slatff -s "attributes.\"post.logout.redirect.uris\"=https://$2/*"
    echo "client $1: sign-out may return to https://$2/*"
  }
  set_logout open-webui "$AI_HOST"
  set_logout jitsi "$MEET_HOST"
  id=$($k get clients -r slatff -q clientId=open-webui --fields id --format csv --noquotes)
  if $k get "clients/$id/protocol-mappers/models" -r slatff --fields protocolMapper --format csv --noquotes | grep -q oidc-audience-mapper; then
    echo "client open-webui: audience model-gateway already present"
  else
    $k create "clients/$id/protocol-mappers/models" -r slatff -f - <<JSON
{"name":"audience model-gateway","protocol":"openid-connect","protocolMapper":"oidc-audience-mapper",
 "config":{"included.custom.audience":"model-gateway","access.token.claim":"true","id.token.claim":"false"}}
JSON
    echo "client open-webui: added audience model-gateway to access tokens"
  fi
'
