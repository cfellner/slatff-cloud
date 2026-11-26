#!/usr/bin/env bash
# Keycloak setup for agents acting for a user (step 10, docs/AGENTS.md). Safe to re-run.
# Needs Keycloak 26.8 with features token-exchange-delegation and parameterized-scopes.
#
# Realm "slatff":
# - fine-grained admin permissions v2 on (needed for the "delegate" permission)
# - client "agent-console": public, browser sign-in with PKCE, loopback redirect, consent
#   required, optional scope delegation:client (the user asks for delegation:client:<agent>)
# - client "research-agent": the agent. Service account, standard token exchange on,
#   authenticates with its own key (private_key_jwt, public key from AGENT_JWKS, no secret),
#   full scope off with only realm role ai-user mapped (an agent never carries more than
#   ai-user, even for an admin), audience model-gateway, tokens live 120 s
# - client "rogue-agent": an agent with a secret and no permission (for the refusal check)
# - permission "research-agent may act for users": Users, scope delegate, policy = the agent
#
# Usage: AGENT_JWKS='{"keys":[...]}' bash scripts/kc-apply-agents.sh          set up
#        bash scripts/kc-apply-agents.sh permission-off | permission-on       kill switch A
#        bash scripts/kc-apply-agents.sh session-off <username>               kill switch B
#        bash scripts/kc-apply-agents.sh rogue-off                            test client off again
# Secrets come from .env (ROGUE_AGENT_SECRET), passed in, never printed.
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH="/usr/local/bin:/opt/homebrew/bin:/Applications/Docker.app/Contents/Resources/bin:$PATH"
ACTION=${1:-apply}; TARGET_USER=${2:-}
val() { grep "^$1=" .env | cut -d= -f2-; }
if [ "$ACTION" = apply ]; then
  [ -n "${AGENT_JWKS:-}" ] || { echo "STOP: AGENT_JWKS is empty (python3 agents/agent.py jwks)"; exit 1; }
  [ -n "$(val ROGUE_AGENT_SECRET)" ] || { echo "STOP: ROGUE_AGENT_SECRET is empty in .env"; exit 1; }
fi
kc() {   # kcadm in the Keycloak container; stdin passes through
  docker compose exec -T keycloak bash -c 'KC_CLI_PASSWORD="$KC_BOOTSTRAP_ADMIN_PASSWORD" /opt/keycloak/bin/kcadm.sh config credentials --server http://localhost:8080 --realm master --user "$KC_BOOTSTRAP_ADMIN_USERNAME" >/dev/null 2>&1 && /opt/keycloak/bin/kcadm.sh "$@"' _ "$@"
}
if [ "$ACTION" = apply ] && ! kc get client-scopes -r slatff --fields name --format csv --noquotes | grep -qx "delegation:client"; then
  # Keycloak adds the delegation scopes only to new realms (or at upgrade with the feature on).
  # Copy Keycloak's own definition from a temporary realm, then delete that realm.
  T=slatff-scope-template
  kc create realms -s realm=$T -s enabled=false >/dev/null 2>&1 || true
  kc get client-scopes -r $T | python3 -c '
import json, sys
for s in json.load(sys.stdin):
    if s["name"] in ("delegation:client", "delegation:user"):
        s.pop("id", None)
        for m in s.get("protocolMappers", []):
            m.pop("id", None)
        print(json.dumps(s))' | while read -r scope; do
    echo "$scope" | kc create client-scopes -r slatff -f - >/dev/null && echo "realm slatff: added client scope $(echo "$scope" | python3 -c 'import json,sys; print(json.load(sys.stdin)["name"])')"
  done
  kc delete realms/$T >/dev/null 2>&1 || true
fi
docker compose exec -T -e ACTION="$ACTION" -e TARGET_USER="$TARGET_USER" -e JWKS="${AGENT_JWKS:-}" \
  -e R_SECRET="$(val ROGUE_AGENT_SECRET)" keycloak bash -c '
  set -e
  k=/opt/keycloak/bin/kcadm.sh
  KC_CLI_PASSWORD="$KC_BOOTSTRAP_ADMIN_PASSWORD" $k config credentials --server http://localhost:8080 --realm master --user "$KC_BOOTSTRAP_ADMIN_USERNAME" >/dev/null
  # the Keycloak image has no awk/cut/tr/jq: plain bash only
  cid() { $k get clients -r slatff -q clientId="$1" --fields id --format csv --noquotes; }
  scope_id() { $k get client-scopes -r slatff --fields id,name --format csv --noquotes | while IFS=, read -r i n; do if [ "$n" = "$1" ]; then echo "$i"; fi; done; return 0; }
  PERM="research-agent may act for users"
  POL="agent research-agent"
  perm_id() { $k get "clients/$(cid admin-permissions)/authz/resource-server/permission" -r slatff -q name="$PERM" --fields id,name --format csv --noquotes 2>/dev/null | while IFS=, read -r i n; do if [ "$n" = "$PERM" ]; then echo "$i"; fi; done; return 0; }
  permission_on() {
    apc=$(cid admin-permissions)
    [ -n "$apc" ] || { echo "STOP: no admin-permissions client (adminPermissionsEnabled?)"; exit 1; }
    base="clients/$apc/authz/resource-server"
    pol=$($k get "$base/policy" -r slatff -q name="$POL" --fields id,name --format csv --noquotes 2>/dev/null | while IFS=, read -r i n; do if [ "$n" = "$POL" ]; then echo "$i"; fi; done)
    if [ -z "$pol" ]; then
      $k create "$base/policy/client" -r slatff -f - >/dev/null <<JSON
{"name":"$POL","description":"The research-agent client (step 10)","logic":"POSITIVE","clients":["$(cid research-agent)"]}
JSON
    fi
    if [ -z "$(perm_id)" ]; then
      $k create "$base/permission/scope" -r slatff -f - >/dev/null <<JSON
{"name":"$PERM","description":"Users may let research-agent act for them (consent at sign-in). Delete to stop the agent.","resourceType":"Users","scopes":["delegate"],"policies":["$POL"],"decisionStrategy":"UNANIMOUS"}
JSON
    fi
    echo "permission on: $PERM"
  }

  case "$ACTION" in
  permission-off)
    p=$(perm_id)
    if [ -n "$p" ]; then $k delete "clients/$(cid admin-permissions)/authz/resource-server/permission/$p" -r slatff; fi
    echo "permission off: $PERM"; exit 0 ;;
  permission-on)
    permission_on; exit 0 ;;
  rogue-off)
    id=$(cid rogue-agent); if [ -n "$id" ]; then $k update "clients/$id" -r slatff -s enabled=false; fi
    echo "rogue-agent disabled"; exit 0 ;;
  session-off)
    uid=$($k get users -r slatff -q username="$TARGET_USER" -q exact=true --fields id --format csv --noquotes)
    [ -n "$uid" ] || { echo "no user $TARGET_USER"; exit 1; }
    $k create "users/$uid/logout" -r slatff -f - >/dev/null <<< "{}"
    echo "sessions ended for $TARGET_USER"; exit 0 ;;
  esac

  $k update realms/slatff -s adminPermissionsEnabled=true
  echo "realm slatff: fine-grained admin permissions v2 on"

  # --- the user side: agent-console ------------------------------------------------------
  if [ -z "$(cid agent-console)" ]; then
    $k create clients -r slatff -f - >/dev/null <<JSON
{"clientId":"agent-console","name":"Agent console (step 10): you approve an agent","enabled":true,
 "publicClient":true,"standardFlowEnabled":true,"directAccessGrantsEnabled":false,"implicitFlowEnabled":false,
 "serviceAccountsEnabled":false,"consentRequired":true,"redirectUris":["http://127.0.0.1:8766/callback"],
 "attributes":{"pkce.code.challenge.method":"S256"}}
JSON
    echo "created client agent-console"
  else echo "client agent-console exists"; fi
  ds=$(scope_id delegation:client)
  [ -n "$ds" ] || { echo "STOP: client scope delegation:client missing: features token-exchange-delegation,parameterized-scopes on?"; exit 1; }
  $k update "clients/$(cid agent-console)/optional-client-scopes/$ds" -r slatff >/dev/null 2>&1 || true
  echo "agent-console: consent required, optional scope delegation:client"

  # --- the agent: research-agent ---------------------------------------------------------
  if [ -z "$(cid research-agent)" ]; then
    $k create clients -r slatff -f - >/dev/null <<JSON
{"clientId":"research-agent","name":"Research agent (demo, step 10)","enabled":true,"publicClient":false,
 "clientAuthenticatorType":"client-jwt","serviceAccountsEnabled":true,"standardFlowEnabled":false,
 "directAccessGrantsEnabled":false,"implicitFlowEnabled":false,"fullScopeAllowed":false,
 "protocolMappers":[{"name":"audience model-gateway","protocol":"openid-connect","protocolMapper":"oidc-audience-mapper",
   "config":{"included.custom.audience":"model-gateway","access.token.claim":"true","id.token.claim":"false"}}]}
JSON
    echo "created client research-agent"
  fi
  rid=$(cid research-agent)
  # kcadm parses a JSON-looking value as JSON; quote it so the attribute stays a string
  J="\"${JWKS//\"/\\\"}\""
  $k update "clients/$rid" -r slatff -s clientAuthenticatorType=client-jwt -s fullScopeAllowed=false \
    -s "attributes.\"use.jwks.string\"=true" -s "attributes.\"jwks.string\"=$J" \
    -s "attributes.\"use.jwks.url\"=false" \
    -s "attributes.\"token.endpoint.auth.signing.alg\"=RS256" \
    -s "attributes.\"standard.token.exchange.enabled\"=true" \
    -s "attributes.\"access.token.lifespan\"=120"
  role=$($k get roles/ai-user -r slatff --fields id,name --format csv --noquotes)
  $k create "clients/$rid/scope-mappings/realm" -r slatff -f - >/dev/null 2>&1 <<JSON || true
[{"id":"${role%%,*}","name":"ai-user"}]
JSON
  echo "research-agent: private_key_jwt with the key from this Mac, token exchange on, roles limited to ai-user, audience model-gateway, 120 s"

  # --- an agent nobody approved ----------------------------------------------------------
  if [ -z "$(cid rogue-agent)" ]; then
    $k create clients -r slatff -f - >/dev/null <<JSON
{"clientId":"rogue-agent","name":"Rogue agent (refusal check, step 10)","enabled":true,"publicClient":false,
 "serviceAccountsEnabled":true,"standardFlowEnabled":false,"directAccessGrantsEnabled":false,
 "attributes":{"standard.token.exchange.enabled":"true"}}
JSON
    echo "created client rogue-agent"
  fi
  $k update "clients/$(cid rogue-agent)" -r slatff -s "secret=$R_SECRET" -s enabled=true
  echo "rogue-agent enabled for the test run (scripts/harden.sh or the end of step 10 turns it off)"

  permission_on
'
