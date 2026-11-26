#!/usr/bin/env bash
# Keycloak as the identity provider for Apple Business Manager / Apple School Manager
# (federated authentication with a custom IdP), with Keycloak's Shared Signals Framework
# transmitter telling Apple about sessions, credentials and accounts (docs/APPLE.md). Safe to re-run.
# Needs Keycloak with feature "ssf" (experimental) and the id host reachable from the internet.
#
# Realm "slatff":
# - realm attribute ssf.transmitterEnabled=true (creates client scopes ssf.read, ssf.manage)
# - realm role apple-federation-admin: only users with it may create Apple's SSF stream
# - client "apple-business": confidential, browser sign-in, redirect URI Apple publishes
#   (https://gsa-ws.apple.com/grandslam/GsService2/acs), optional scopes ssf.read, ssf.manage,
#   offline_access; SSF receiver with the legacy SSE_CAEP profile Apple still uses, events for
#   all users, stream created by the admin's token (no service account)
#
# Settings from .env:
#   APPLE_BUSINESS_CLIENT_SECRET   created by scripts/mac-step11-apple.sh, never printed
#   APPLE_FEDERATION_ADMIN         Keycloak user who signs in during Apple's connection test
#   APPLE_SSF_PUSH_URLS            Apple's push endpoint(s), "##"-separated; empty until known
#                                  (Keycloak logs the URL Apple asks for when it is refused)
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH="/usr/local/bin:/opt/homebrew/bin:/Applications/Docker.app/Contents/Resources/bin:$PATH"
val() { grep "^$1=" .env | cut -d= -f2- || true; }
[ -n "$(val APPLE_BUSINESS_CLIENT_SECRET)" ] || { echo "STOP: APPLE_BUSINESS_CLIENT_SECRET is empty in .env"; exit 1; }
docker compose exec -T -e SECRET="$(val APPLE_BUSINESS_CLIENT_SECRET)" -e ADMIN_USER="$(val APPLE_FEDERATION_ADMIN)" \
  -e PUSH_URLS="$(val APPLE_SSF_PUSH_URLS)" keycloak bash -c '
  set -e
  k=/opt/keycloak/bin/kcadm.sh
  KC_CLI_PASSWORD="$KC_BOOTSTRAP_ADMIN_PASSWORD" $k config credentials --server http://localhost:8080 --realm master --user "$KC_BOOTSTRAP_ADMIN_USERNAME" >/dev/null
  # the Keycloak image has no awk/cut/tr/jq: plain bash only
  cid() { $k get clients -r slatff -q clientId="$1" --fields id --format csv --noquotes; }
  scope_id() { $k get client-scopes -r slatff --fields id,name --format csv --noquotes | while IFS=, read -r i n; do if [ "$n" = "$1" ]; then echo "$i"; fi; done; return 0; }

  $k update realms/slatff -s "attributes.\"ssf.transmitterEnabled\"=true"
  echo "realm slatff: SSF transmitter on"
  for s in ssf.read ssf.manage offline_access; do
    [ -n "$(scope_id $s)" ] || { echo "STOP: client scope $s missing (feature ssf on? Keycloak restarted?)"; exit 1; }
  done

  $k create roles -r slatff -s name=apple-federation-admin \
    -s "description=May connect Apple Business or School Manager (creates the SSF stream)" >/dev/null 2>&1 || true

  if [ -z "$(cid apple-business)" ]; then
    $k create clients -r slatff -f - >/dev/null <<JSON
{"clientId":"apple-business","name":"Apple Business / School Manager (federated authentication)","enabled":true,
 "publicClient":false,"standardFlowEnabled":true,"directAccessGrantsEnabled":false,"implicitFlowEnabled":false,
 "serviceAccountsEnabled":false,"consentRequired":false,
 "redirectUris":["https://gsa-ws.apple.com/grandslam/GsService2/acs"],"webOrigins":[]}
JSON
    echo "created client apple-business"
  else echo "client apple-business exists"; fi
  id=$(cid apple-business)
  $k update "clients/$id" -r slatff -s "secret=$SECRET" \
    -s "attributes.\"ssf.enabled\"=true" \
    -s "attributes.\"ssf.profile\"=SSE_CAEP" \
    -s "attributes.\"ssf.defaultSubjects\"=ALL" \
    -s "attributes.\"ssf.requireServiceAccount\"=false" \
    -s "attributes.\"ssf.requiredRole\"=apple-federation-admin"
  if [ -n "$PUSH_URLS" ]; then
    $k update "clients/$id" -r slatff -s "attributes.\"ssf.validPushUrls\"=$PUSH_URLS"
    echo "apple-business: push URLs allowed: $PUSH_URLS"
  else
    echo "apple-business: no push URL allowed yet (APPLE_SSF_PUSH_URLS empty)"
  fi
  for s in ssf.read ssf.manage offline_access; do
    $k update "clients/$id/optional-client-scopes/$(scope_id $s)" -r slatff >/dev/null 2>&1 || true
  done
  echo "apple-business: SSF receiver, profile SSE_CAEP, all users, optional scopes ssf.read ssf.manage offline_access"

  if [ -n "$ADMIN_USER" ]; then
    $k add-roles -r slatff --uusername "$ADMIN_USER" --rolename apple-federation-admin
    echo "user $ADMIN_USER: role apple-federation-admin"
  else
    echo "no APPLE_FEDERATION_ADMIN set: give one user the role apple-federation-admin before the connection test"
  fi
'
