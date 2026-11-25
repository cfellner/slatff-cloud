#!/usr/bin/env bash
# Connects Nextcloud to Keycloak after: docker compose --profile files up -d
# Safe to re-run. Writes logs/setup-files.log.
# Secrets are passed as environment variables into the containers, never on a command line.
set -uo pipefail
cd "$(dirname "$0")/.."
mkdir -p logs
exec > >(tee logs/setup-files.log) 2>&1
export PATH="/usr/local/bin:/opt/homebrew/bin:/Applications/Docker.app/Contents/Resources/bin:$PATH"
val() { grep "^$1=" .env | cut -d= -f2-; }
s() { echo; echo "=== $* ==="; }
ID=$(val ID_HOST); FILES=$(val FILES_HOST)
occ() { docker compose exec -T -u www-data nextcloud php occ "$@"; }

s date; date

s "Keycloak: make sure client 'nextcloud', role 'files-user' and group 'files-users' exist"
# The realm file creates them on a fresh install. This covers a realm imported before they existed.
docker compose exec -T -e NC_SECRET="$(val NEXTCLOUD_CLIENT_SECRET)" -e FILES_HOST="$FILES" keycloak bash -c '
  k=/opt/keycloak/bin/kcadm.sh
  KC_CLI_PASSWORD="$KC_BOOTSTRAP_ADMIN_PASSWORD" $k config credentials --server http://localhost:8080 --realm master --user "$KC_BOOTSTRAP_ADMIN_USERNAME" >/dev/null || exit 1
  if [ -z "$($k get clients -r slatff -q clientId=nextcloud --fields id --format csv --noquotes)" ]; then
    $k create clients -r slatff -f - <<JSON
{"clientId":"nextcloud","name":"Files (Nextcloud)","enabled":true,"protocol":"openid-connect","publicClient":false,
 "secret":"$NC_SECRET","standardFlowEnabled":true,"directAccessGrantsEnabled":false,
 "redirectUris":["https://$FILES_HOST/apps/user_oidc/code"],"webOrigins":["https://$FILES_HOST"],
 "protocolMappers":[{"name":"groups","protocol":"openid-connect","protocolMapper":"oidc-group-membership-mapper",
  "config":{"claim.name":"groups","full.path":"false","id.token.claim":"true","access.token.claim":"true","userinfo.token.claim":"true"}}]}
JSON
    echo "created client nextcloud"
  else echo "client nextcloud exists"; fi
  $k get roles/files-user -r slatff >/dev/null 2>&1 || { $k create roles -r slatff -s name=files-user -s "description=May sign in to Files (Nextcloud)"; echo "created role files-user"; }
  if [ -z "$($k get groups -r slatff -q search=files-users -q exact=true --fields id --format csv --noquotes)" ]; then
    gid=$($k create groups -r slatff -s name=files-users -i)
    $k add-roles -r slatff --gid "$gid" --rolename files-user
    echo "created group files-users"
  else echo "group files-users exists"; fi'

s "wait for Nextcloud to finish installing (up to 5 minutes)"
for i in $(seq 1 60); do
  occ status --output=json 2>/dev/null | grep -q '"installed":true' && { echo "installed"; break; }
  sleep 5
done
occ status

s "Nextcloud settings behind Caddy"
occ config:system:set overwrite.cli.url --value="https://$FILES"
occ config:system:set default_phone_region --value=GB
occ config:system:set maintenance_window_start --type=integer --value=1
occ background:cron >/dev/null 2>&1 || true

s "install and configure the OpenID Connect app (user_oidc)"
occ app:install user_oidc 2>&1 | tail -1 || true
occ app:enable user_oidc
docker compose exec -T -u www-data -e NC_SECRET="$(val NEXTCLOUD_CLIENT_SECRET)" -e ID="$ID" nextcloud sh -c '
  php occ user_oidc:provider SLATFF.Cloud \
    --clientid=nextcloud --clientsecret="$NC_SECRET" \
    --discoveryuri="https://$ID/realms/slatff/.well-known/openid-configuration" \
    --scope="openid email profile" \
    --unique-uid=0 --mapping-uid=preferred_username \
    --mapping-display-name=name --mapping-email=email \
    --mapping-groups=groups --group-provisioning=1 \
    --group-whitelist-regex="^files-users\$" --group-restrict-login-to-whitelist=1 \
    --check-bearer=1'
# One provider and no other login backends: the login page goes straight to Keycloak.
# Break-glass: https://FILES_HOST/login?direct=1 with user ncadmin and NEXTCLOUD_ADMIN_PASSWORD.
occ config:app:set --value=0 user_oidc allow_multiple_user_backends
occ user_oidc:provider SLATFF.Cloud 2>&1 | grep -vi secret | head -30

s "check: Nextcloud can read Keycloak's discovery document through Caddy"
docker compose exec -T nextcloud curl -fsS -m 10 "https://$ID/realms/slatff/.well-known/openid-configuration" | head -c 120; echo

s "done"; echo "Files set up. Add a user to files-users (./scripts/create-demo-user.sh) and open https://$FILES"
