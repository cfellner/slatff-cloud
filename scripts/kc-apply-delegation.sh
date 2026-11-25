#!/usr/bin/env bash
# Keycloak setup for delegation ("authority narrows"), docs/DELEGATION.md. Safe to re-run.
# Works on a fresh or an existing realm (the realm file is not changed, so nothing depends
# on it being re-imported). Creates or updates:
# - client "kb-tool": the demo tool, a resource only (no sign-in flows, no secret used)
# - client scope "kb-search": optional, puts audience "kb-tool" into a token that asks for it
# - client "model-gateway": confidential, may do standard token exchange (RFC 8693), has
#   "kb-search" as an optional scope and the flat realm-roles mapper. Its secret comes from
#   GATEWAY_CLIENT_SECRET in .env (passed in, never printed).
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH="/usr/local/bin:/opt/homebrew/bin:/Applications/Docker.app/Contents/Resources/bin:$PATH"
S=$(grep '^GATEWAY_CLIENT_SECRET=' .env | cut -d= -f2-)
[ -n "$S" ] || { echo "STOP: GATEWAY_CLIENT_SECRET is empty in .env"; exit 1; }
docker compose exec -T -e GW_SECRET="$S" keycloak bash -c '
  set -e
  k=/opt/keycloak/bin/kcadm.sh
  KC_CLI_PASSWORD="$KC_BOOTSTRAP_ADMIN_PASSWORD" $k config credentials --server http://localhost:8080 --realm master --user "$KC_BOOTSTRAP_ADMIN_USERNAME" >/dev/null
  cid() { $k get clients -r slatff -q clientId="$1" --fields id --format csv --noquotes; }
  # the Keycloak image has no awk/cut/tr: plain bash only
  scope_id() { $k get client-scopes -r slatff --fields id,name --format csv --noquotes | while IFS=, read -r i n; do if [ "$n" = "$1" ]; then echo "$i"; fi; done; return 0; }

  # 1. the tool as a client, so it is a known audience in the realm
  if [ -z "$(cid kb-tool)" ]; then
    $k create clients -r slatff -f - >/dev/null <<JSON
{"clientId":"kb-tool","name":"Demo tool: knowledge search (resource only)","enabled":true,
 "publicClient":false,"standardFlowEnabled":false,"directAccessGrantsEnabled":false,
 "serviceAccountsEnabled":false,"implicitFlowEnabled":false}
JSON
    echo "created client kb-tool"
  else echo "client kb-tool exists"; fi

  # 2. optional scope kb-search, which adds audience kb-tool
  sid=$(scope_id kb-search)
  if [ -z "$sid" ]; then
    $k create client-scopes -r slatff -f - >/dev/null <<JSON
{"name":"kb-search","description":"Search the demo knowledge base (delegated, tool kb-tool only)",
 "protocol":"openid-connect","attributes":{"include.in.token.scope":"true","display.on.consent.screen":"false"},
 "protocolMappers":[{"name":"audience kb-tool","protocol":"openid-connect","protocolMapper":"oidc-audience-mapper",
   "config":{"included.client.audience":"kb-tool","access.token.claim":"true","id.token.claim":"false"}}]}
JSON
    sid=$(scope_id kb-search)
    echo "created client scope kb-search"
  else echo "client scope kb-search exists"; fi

  # 3. the gateway as a confidential client that may exchange tokens
  if [ -z "$(cid model-gateway)" ]; then
    $k create clients -r slatff -f - >/dev/null <<JSON
{"clientId":"model-gateway","name":"Model gateway (token exchange for tools)","enabled":true,
 "publicClient":false,"clientAuthenticatorType":"client-secret","secret":"$GW_SECRET",
 "standardFlowEnabled":false,"directAccessGrantsEnabled":false,"serviceAccountsEnabled":false,
 "implicitFlowEnabled":false,"attributes":{"standard.token.exchange.enabled":"true"},
 "protocolMappers":[{"name":"realm roles flat","protocol":"openid-connect","protocolMapper":"oidc-usermodel-realm-role-mapper",
   "config":{"claim.name":"roles","multivalued":"true","jsonType.label":"String","access.token.claim":"true","id.token.claim":"false"}}]}
JSON
    echo "created client model-gateway"
  else
    $k update "clients/$(cid model-gateway)" -r slatff -s "secret=$GW_SECRET" -s "attributes.\"standard.token.exchange.enabled\"=true"
    echo "client model-gateway exists: secret and token exchange setting refreshed"
  fi
  gid=$(cid model-gateway)
  # keep exchanged tokens lean: no email scope on the gateway client (profile stays for the user name)
  eid=$(scope_id email)
  if [ -n "$eid" ]; then $k delete "clients/$gid/default-client-scopes/$eid" -r slatff >/dev/null 2>&1 || true; echo "client model-gateway: email scope removed"; fi
  if $k update "clients/$gid/optional-client-scopes/$sid" -r slatff; then
    echo "client model-gateway: optional scope kb-search attached"
  else echo "WARN: could not attach scope kb-search to model-gateway"; fi
  echo "token exchange: proven by the live tests in scripts/mac-step5-delegation.sh"
'
