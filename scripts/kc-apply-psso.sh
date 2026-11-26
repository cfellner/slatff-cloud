#!/usr/bin/env bash
# Keycloak side of Platform SSO for Mac with the University of Oslo extension
# (keycloak-psso-extension, docs/PLATFORM-SSO.md). Safe to re-run. Follows the extension's wiki:
# - client scope urn:apple:platformsso (no mappers)
# - client "psso": public, redirect weblogin-sso://idp-login-redirect, default scope
#   urn:apple:platformsso, optional offline_access, longer access token (the Mac's SSO session)
# - required action psso-required-action (users see their Mac registrations in the account console)
# - authenticator psso-authenticator in a copy of the realm's browser flow, directly under Cookie
# - realm tab "Platform Single Sign-on" (component): registration token not required
# - macOS 27 web-based (OpenID) method: confidential client "psso-oidc", pushed authorization
#   requests required, the urn:apple:platformsso:auth:* scopes as optional scopes
# Needs: scripts/get-psso-extension.sh (jar in keycloak/providers/), feature declarative-ui.
# Secret from .env: PSSO_OIDC_CLIENT_SECRET (never printed).
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH="/usr/local/bin:/opt/homebrew/bin:/Applications/Docker.app/Contents/Resources/bin:$PATH"
val() { grep "^$1=" .env | cut -d= -f2- || true; }
[ -n "$(val PSSO_OIDC_CLIENT_SECRET)" ] || { echo "STOP: PSSO_OIDC_CLIENT_SECRET is empty in .env"; exit 1; }
docker compose exec -T -e OIDC_SECRET="$(val PSSO_OIDC_CLIENT_SECRET)" \
  -e LIFESPAN="$(val PSSO_ACCESS_TOKEN_LIFESPAN)" keycloak bash -c '
  set -e
  k=/opt/keycloak/bin/kcadm.sh
  KC_CLI_PASSWORD="$KC_BOOTSTRAP_ADMIN_PASSWORD" $k config credentials --server http://localhost:8080 --realm master --user "$KC_BOOTSTRAP_ADMIN_USERNAME" >/dev/null
  cid() { $k get clients -r slatff -q clientId="$1" --fields id --format csv --noquotes; }
  scope_id() { $k get client-scopes -r slatff --fields id,name --format csv --noquotes | while IFS=, read -r i n; do if [ "$n" = "$1" ]; then echo "$i"; fi; done; return 0; }
  new_scope() {
    if [ -z "$(scope_id "$1")" ]; then
      $k create client-scopes -r slatff -f - >/dev/null <<JSON
{"name":"$1","protocol":"openid-connect","attributes":{"include.in.token.scope":"true","display.on.consent.screen":"false"}}
JSON
      echo "created client scope $1"
    fi
  }

  # is the extension loaded?
  $k get authentication/authenticator-providers -r slatff --fields id --format csv --noquotes | grep -qx psso-authenticator \
    || { echo "STOP: authenticator psso-authenticator not found: run scripts/get-psso-extension.sh and restart Keycloak"; exit 1; }

  # 1. scope and public client psso
  new_scope urn:apple:platformsso
  if [ -z "$(cid psso)" ]; then
    $k create clients -r slatff -f - >/dev/null <<JSON
{"clientId":"psso","name":"Platform SSO for Mac (Weblogin SSO extension)","enabled":true,"publicClient":true,
 "standardFlowEnabled":true,"directAccessGrantsEnabled":false,"implicitFlowEnabled":false,
 "redirectUris":["weblogin-sso://idp-login-redirect"],"webOrigins":[]}
JSON
    echo "created client psso"
  else echo "client psso exists"; fi
  id=$(cid psso)
  $k update "clients/$id/default-client-scopes/$(scope_id urn:apple:platformsso)" -r slatff >/dev/null 2>&1 || true
  $k update "clients/$id/optional-client-scopes/$(scope_id offline_access)" -r slatff >/dev/null 2>&1 || true
  $k update "clients/$id" -r slatff -s "attributes.\"access.token.lifespan\"=${LIFESPAN:-28800}"
  echo "psso: scope urn:apple:platformsso, optional offline_access, access token ${LIFESPAN:-28800} s"

  # 2. required action
  if $k get authentication/unregistered-required-actions -r slatff --fields providerId --format csv --noquotes | grep -qx psso-required-action; then
    $k create authentication/register-required-action -r slatff -s providerId=psso-required-action -s "name=Platform SSO" >/dev/null
  fi
  $k update authentication/required-actions/psso-required-action -r slatff -s enabled=true -s defaultAction=false
  echo "required action psso-required-action enabled"

  # 3. browser flow copy with the PSSO authenticator under Cookie
  base=$($k get realms/slatff --fields browserFlow --format csv --noquotes)
  flow=browser-psso
  if [ "$base" != "$flow" ]; then
    if ! $k get authentication/flows -r slatff --fields alias --format csv --noquotes | grep -qx "$flow"; then
      $k create "authentication/flows/$base/copy" -r slatff -s "newName=$flow" >/dev/null
      echo "copied flow $base to $flow"
    fi
  fi
  ex() { $k get "authentication/flows/$flow/executions" -r slatff --fields id,providerId,level,index,priority --format csv --noquotes; }
  if ! ex | grep -q ",psso-authenticator,"; then
    $k create "authentication/flows/$flow/executions/execution" -r slatff -s provider=psso-authenticator >/dev/null
    echo "added psso-authenticator to $flow"
  fi
  eid=$(ex | while IFS=, read -r i p l n r; do if [ "$p" = psso-authenticator ]; then echo "$i"; fi; done)
  prio=$(ex | while IFS=, read -r i p l n r; do if [ "$i" = "$eid" ]; then echo "$r"; fi; done)
  # the update endpoint also sets priority, so send the current one back unchanged
  $k update "authentication/flows/$flow/executions" -r slatff -f - >/dev/null <<JSON
{"id":"$eid","requirement":"ALTERNATIVE","priority":${prio:-0}}
JSON
  for n in 1 2 3 4 5 6 7 8; do
    idx=$(ex | while IFS=, read -r i p l n r; do if [ "$i" = "$eid" ]; then echo "$n"; fi; done)
    [ "$idx" -le 1 ] && break
    $k create "authentication/executions/$eid/raise-priority" -r slatff -f - >/dev/null <<< "{}"
  done
  ex | while IFS=, read -r i p l n r; do if [ "$l" = 0 ]; then echo "  $flow step $n: ${p:-(sub-flow)}"; fi; done
  $k update realms/slatff -s "browserFlow=$flow"
  echo "realm slatff: browser flow $flow"

  # 4. realm tab "Platform Single Sign-on" (stored as a component)
  rid=$($k get realms/slatff --fields id --format csv --noquotes)
  comp=$($k get components -r slatff -q type=org.keycloak.services.ui.extend.UiTabProvider --fields id,providerId --format csv --noquotes \
    | while IFS=, read -r i p; do if [ "$p" = "Platform Single Sign-on" ]; then echo "$i"; fi; done)

  # 5. macOS 27 web-based (OpenID) method
  for s in auth-prompt login elevation unlock temporary-session setup-assistant password-change fallback refresh create-user; do
    new_scope "urn:apple:platformsso:auth:$s"
  done
  if [ -z "$(cid psso-oidc)" ]; then
    $k create clients -r slatff -f - >/dev/null <<JSON
{"clientId":"psso-oidc","name":"Platform SSO, macOS 27 web-based sign-in","enabled":true,"publicClient":false,
 "standardFlowEnabled":true,"directAccessGrantsEnabled":false,"implicitFlowEnabled":false,
 "redirectUris":["weblogin-sso://idp-login-redirect"],"webOrigins":[]}
JSON
    echo "created client psso-oidc"
  fi
  oid=$(cid psso-oidc)
  $k update "clients/$oid" -r slatff -s "secret=$OIDC_SECRET" -s "attributes.\"require.pushed.authorization.requests\"=true"
  for s in urn:apple:platformsso urn:apple:platformsso:auth:auth-prompt urn:apple:platformsso:auth:login urn:apple:platformsso:auth:elevation \
           urn:apple:platformsso:auth:unlock urn:apple:platformsso:auth:temporary-session urn:apple:platformsso:auth:setup-assistant \
           urn:apple:platformsso:auth:password-change urn:apple:platformsso:auth:fallback urn:apple:platformsso:auth:refresh \
           urn:apple:platformsso:auth:create-user; do
    $k update "clients/$oid/optional-client-scopes/$(scope_id "$s")" -r slatff >/dev/null 2>&1 || true
  done
  echo "psso-oidc: confidential, PAR required, urn:apple:platformsso:auth:* optional"

  cfg="{\"name\":\"Platform Single Sign-on\",\"providerId\":\"Platform Single Sign-on\",\"providerType\":\"org.keycloak.services.ui.extend.UiTabProvider\",\"parentId\":\"$rid\",\"config\":{\"requireRegistrationToken\":[\"false\"],\"checkRegistrationWithURL\":[\"NEVER\"],\"clientIDOIDCFlow\":[\"psso-oidc\"],\"clientSecretOIDCFlow\":[\"$OIDC_SECRET\"]}}"
  if [ -z "$comp" ]; then
    printf "%s" "$cfg" | $k create components -r slatff -f - >/dev/null
    echo "realm tab Platform Single Sign-on: created (registration token not required, OIDC client psso-oidc)"
  else
    printf "%s" "$cfg" | $k update "components/$comp" -r slatff -f - >/dev/null
    echo "realm tab Platform Single Sign-on: updated"
  fi
'
