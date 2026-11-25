#!/usr/bin/env bash
# Keycloak setup for app-to-app access with ID-JAG (step 8, docs/APP-TO-APP.md). Safe to re-run.
#
# Realm "slatff" (the company IdP, issues ID-JAGs with the slatff-id-jag extension):
# - client "notes-agent" (app A): confidential, device sign-in, may request ID-JAGs for realm
#   "apps" only, scope notes.read only, users need realm role ai-user
#
# Realm "apps" (app B's authorization server, a separate trust domain; Keycloak's own
# experimental ID-JAG receiver, feature identity-assertion-jwt):
# - identity provider "slatff": trusts ID-JAGs signed by realm slatff (JWKS fetched inside Docker)
# - client "notes-api": the API, audience only
# - client scopes notes.read, notes.write (both add audience notes-api)
# - client "notes-agent": app A at app B, may use the JWT bearer grant with IdP "slatff"
# - client "other-app": a second client, to prove an ID-JAG for notes-agent is refused for it
# - users alice, bob, carol linked to their realm slatff accounts (Keycloak needs the link)
#
# Secrets come from .env (NOTES_AGENT_SECRET, APPS_AGENT_SECRET, OTHER_APP_SECRET), passed in,
# never printed.
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH="/usr/local/bin:/opt/homebrew/bin:/Applications/Docker.app/Contents/Resources/bin:$PATH"
val() { grep "^$1=" .env | cut -d= -f2-; }
for v in NOTES_AGENT_SECRET APPS_AGENT_SECRET OTHER_APP_SECRET ID_HOST AI_HOST; do
  [ -n "$(val $v)" ] || { echo "STOP: $v is empty in .env"; exit 1; }
done
docker compose exec -T -e A_SECRET="$(val NOTES_AGENT_SECRET)" -e B_SECRET="$(val APPS_AGENT_SECRET)" \
  -e O_SECRET="$(val OTHER_APP_SECRET)" -e IDH="$(val ID_HOST)" -e AIH="$(val AI_HOST)" keycloak bash -c '
  set -e
  k=/opt/keycloak/bin/kcadm.sh
  KC_CLI_PASSWORD="$KC_BOOTSTRAP_ADMIN_PASSWORD" $k config credentials --server http://localhost:8080 --realm master --user "$KC_BOOTSTRAP_ADMIN_USERNAME" >/dev/null
  # the Keycloak image has no awk/cut/tr: plain bash only
  cid() { $k get clients -r "$1" -q clientId="$2" --fields id --format csv --noquotes; }
  scope_id() { $k get client-scopes -r "$1" --fields id,name --format csv --noquotes | while IFS=, read -r i n; do if [ "$n" = "$2" ]; then echo "$i"; fi; done; return 0; }
  user_id() { $k get users -r "$1" -q username="$2" -q exact=true --fields id --format csv --noquotes; }
  APPS_ISS="https://$IDH/realms/apps"
  SLATFF_ISS="https://$IDH/realms/slatff"
  RESOURCE="https://$AIH/notes"

  # --- realm slatff: app A ------------------------------------------------------------
  if [ -z "$(cid slatff notes-agent)" ]; then
    $k create clients -r slatff -f - >/dev/null <<JSON
{"clientId":"notes-agent","name":"Demo app A: notes agent (ID-JAG)","enabled":true,
 "publicClient":false,"standardFlowEnabled":false,"directAccessGrantsEnabled":false,
 "serviceAccountsEnabled":false,"implicitFlowEnabled":false,"consentRequired":false}
JSON
    echo "slatff: created client notes-agent"
  else echo "slatff: client notes-agent exists"; fi
  id=$(cid slatff notes-agent)
  $k update "clients/$id" -r slatff -s "secret=$A_SECRET" \
    -s "attributes.\"oauth2.device.authorization.grant.enabled\"=true" \
    -s "attributes.\"id-jag.audiences\"=$APPS_ISS" \
    -s "attributes.\"id-jag.scopes\"=notes.read" \
    -s "attributes.\"id-jag.resources\"=$RESOURCE" \
    -s "attributes.\"id-jag.required-role\"=ai-user" \
    -s "attributes.\"id-jag.lifespan\"=300"
  echo "slatff: notes-agent policy: audience $APPS_ISS, scope notes.read, resource $RESOURCE, role ai-user"

  # --- realm apps: app B ------------------------------------------------------------
  if ! $k get realms/apps >/dev/null 2>&1; then
    $k create realms -s realm=apps -s enabled=true -s "displayName=Demo app B (separate trust domain)" >/dev/null
    echo "apps: created realm"
  else echo "apps: realm exists"; fi

  if ! $k get identity-provider/instances/slatff -r apps >/dev/null 2>&1; then
    $k create identity-provider/instances -r apps -f - >/dev/null <<JSON
{"alias":"slatff","displayName":"Company IdP (realm slatff)","providerId":"keycloak-oidc","enabled":true,
 "hideOnLogin":true,"trustEmail":false,
 "config":{"issuer":"$SLATFF_ISS","validateSignature":"true","useJwksUrl":"true",
  "jwksUrl":"http://keycloak:8080/realms/slatff/protocol/openid-connect/certs",
  "authorizationUrl":"$SLATFF_ISS/protocol/openid-connect/auth",
  "tokenUrl":"http://keycloak:8080/realms/slatff/protocol/openid-connect/token",
  "clientId":"apps-broker-unused","clientSecret":"unused","clientAuthMethod":"client_secret_post",
  "jwtAuthorizationGrantEnabled":"true","jwtAuthorizationGrantAssertionReuseAllowed":"false",
  "jwtAuthorizationGrantMaxAllowedAssertionExpiration":"300"}}
JSON
    echo "apps: created identity provider slatff (trusts ID-JAGs from realm slatff)"
  else echo "apps: identity provider slatff exists"; fi

  if [ -z "$(cid apps notes-api)" ]; then
    $k create clients -r apps -f - >/dev/null <<JSON
{"clientId":"notes-api","name":"Demo app B API (audience only)","enabled":true,"publicClient":false,
 "standardFlowEnabled":false,"directAccessGrantsEnabled":false,"serviceAccountsEnabled":false}
JSON
    echo "apps: created client notes-api"
  fi
  for s in notes.read notes.write; do
    if [ -z "$(scope_id apps $s)" ]; then
      $k create client-scopes -r apps -f - >/dev/null <<JSON
{"name":"$s","protocol":"openid-connect","attributes":{"include.in.token.scope":"true","display.on.consent.screen":"false"},
 "protocolMappers":[{"name":"audience notes-api","protocol":"openid-connect","protocolMapper":"oidc-audience-mapper",
   "config":{"included.client.audience":"notes-api","access.token.claim":"true","id.token.claim":"false"}}]}
JSON
      echo "apps: created client scope $s"
    fi
  done

  for c in notes-agent other-app; do
    sec=$B_SECRET; [ "$c" = other-app ] && sec=$O_SECRET
    if [ -z "$(cid apps $c)" ]; then
      $k create clients -r apps -f - >/dev/null <<JSON
{"clientId":"$c","enabled":true,"publicClient":false,"standardFlowEnabled":false,
 "directAccessGrantsEnabled":false,"serviceAccountsEnabled":false,"consentRequired":false}
JSON
      echo "apps: created client $c"
    fi
    id=$(cid apps $c)
    $k update "clients/$id" -r apps -s "secret=$sec" \
      -s "attributes.\"oauth2.jwt.authorization.grant.enabled\"=true" \
      -s "attributes.\"oauth2.jwt.authorization.grant.idp\"=slatff"
    for s in notes.read notes.write; do
      $k update "clients/$id/optional-client-scopes/$(scope_id apps $s)" -r apps >/dev/null 2>&1 || true
    done
  done
  echo "apps: clients notes-agent and other-app may use the JWT bearer grant with IdP slatff"

  for u in alice bob carol; do
    sid=$(user_id slatff $u)
    [ -n "$sid" ] || { echo "apps: no user $u in slatff, skipped"; continue; }
    if [ -z "$(user_id apps $u)" ]; then
      $k create users -r apps -s username=$u -s enabled=true -s "email=$u@example.org" -s emailVerified=true \
        -s firstName=$u -s lastName=demo >/dev/null
    fi
    aid=$(user_id apps $u)
    $k create "users/$aid/federated-identity/slatff" -r apps -s identityProvider=slatff -s "userId=$sid" -s "userName=$u" >/dev/null 2>&1 || true
    echo "apps: user $u linked to slatff"
  done
'
