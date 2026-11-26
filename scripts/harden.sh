#!/usr/bin/env bash
# Security hardening after the security review of 26 Nov 2026 (docs/THREATS.md). Safe to re-run.
#  1. Master realm: brute-force protection on (10 failures).
#  2. Realm slatff: brute-force threshold 10; password policy; admin-cli password grant off
#     (otherwise anyone reaching the token endpoint can try a password without the login page,
#     passkeys or MFA).
#  3. rogue-agent (test client with a secret and token exchange) disabled; step 10 turns it
#     on for its test run and off again.
#  4. Personal admin in realm master, with an authenticator app (TOTP) required at first sign-in.
#     The bootstrap "admin" stays for the scripts until they move to a service account.
#  5. Caddy: requests through the Cloudflare tunnel may not reach realm master at all.
# Usage: bash scripts/harden.sh            (asks for the personal admin's name and password)
#        bash scripts/harden.sh --no-admin (steps 1 to 3 and 5 only)
# Writes logs/harden.log. No password is shown or written to a file.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p logs
exec > >(tee logs/harden.log) 2>&1
export PATH="/usr/local/bin:/opt/homebrew/bin:/Applications/Docker.app/Contents/Resources/bin:$PATH"
s() { echo; echo "=== $* ==="; }
kc() { docker compose exec -T keycloak /opt/keycloak/bin/kcadm.sh "$@" </dev/null; }   # never eats terminal input
kcin() { docker compose exec -T keycloak /opt/keycloak/bin/kcadm.sh "$@"; }            # body on standard input
docker compose exec -T keycloak bash -c \
  'KC_CLI_PASSWORD="$KC_BOOTSTRAP_ADMIN_PASSWORD" /opt/keycloak/bin/kcadm.sh config credentials \
     --server http://localhost:8080 --realm master --user "$KC_BOOTSTRAP_ADMIN_USERNAME"' >/dev/null
cid() { kc get clients -r "$1" -q clientId="$2" --fields id --format csv --noquotes; }

s "1. realm master: brute-force protection"
kc update realms/master -s bruteForceProtected=true -s failureFactor=10 -s permanentLockout=false
echo "on: 10 failures, temporary lockout"

s "2. realm slatff: brute force, password policy, no password grant on admin-cli"
kc update realms/slatff -s bruteForceProtected=true -s failureFactor=10 \
  -s 'passwordPolicy=length(12) and notUsername and notEmail and passwordHistory(3)'
echo "password policy: at least 12 characters, not the user name or email, not one of the last 3"
echo "(applies when a password is set or changed; existing passwords keep working)"
kc update "clients/$(cid slatff admin-cli)" -r slatff -s directAccessGrantsEnabled=false
echo "admin-cli in slatff: password grant off"

s "3. test client rogue-agent off"
id=$(cid slatff rogue-agent)
if [ -n "$id" ]; then kc update "clients/$id" -r slatff -s enabled=false; echo "rogue-agent disabled"; else echo "no rogue-agent"; fi

s "4. personal admin in realm master"
if [ "${1:-}" = "--no-admin" ]; then
  echo "skipped (--no-admin)"
else
  read -r -p "User name for your personal admin [christoph-admin]: " au </dev/tty; au=${au:-christoph-admin}
  uid=$(kc get users -r master -q username="$au" -q exact=true --fields id --format csv --noquotes)
  setpw=y
  if [ -n "$uid" ]; then
    read -r -p "$au exists. Set a new password? [y/N] " setpw </dev/tty
  else
    uid=$(kc create users -r master -s "username=$au" -s enabled=true -i)
    echo "created $au"
  fi
  if [ "$setpw" = y ] || [ "$setpw" = Y ]; then
    read -r -s -p "Password for $au (12+ characters): " pw </dev/tty; echo
    [ ${#pw} -ge 12 ] || { echo "STOP: shorter than 12 characters"; exit 1; }
    pw_json=$(printf '%s' "$pw" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')
    printf '{"type":"password","value":"%s","temporary":false}' "$pw_json" |
      kcin update "users/$uid/reset-password" -r master -n -f -
    unset pw pw_json
    echo "password set"
  fi
  kc update "users/$uid" -r master -s enabled=true -s 'requiredActions=["CONFIGURE_TOTP"]'
  kc add-roles -r master --uusername "$au" --rolename admin
  kc get "users/$uid" -r master --fields username,enabled,requiredActions
  echo "role admin; an authenticator app is required at first sign-in"
fi

s "5. Caddy: realm master only on the local network"
docker compose exec -T caddy caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile && echo "Caddy reloaded"

s "check"
kc get realms/master --fields bruteForceProtected,failureFactor
kc get realms/slatff --fields bruteForceProtected,failureFactor,passwordPolicy
kc get "clients/$(cid slatff admin-cli)" -r slatff --fields clientId,directAccessGrantsEnabled
[ -n "${id:-}" ] && kc get "clients/$id" -r slatff --fields clientId,enabled
echo
echo "Next: open https://<ID_HOST>/admin/master/console/ in a private window, sign in as your"
echo "personal admin, set up the authenticator app. Then use that account, not 'admin'."
