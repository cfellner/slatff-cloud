#!/usr/bin/env bash
# Step 11: the Apple part end to end (docs/APPLE.md).
#   psso    Platform SSO: University of Oslo Keycloak extension (downloaded and verified), realm
#           settings, apple-app-site-association file, MDM profiles in dist/mdm/
#   apple   Apple Business / School Manager federation: Keycloak SSF transmitter + client
#   all     both (default)
# Keycloak restarts once (database backup first). Writes logs/mac-step11.log.
# No secret is printed; values to paste into Apple Business Manager are copied to the clipboard.
cd "$(dirname "$0")/.."
mkdir -p logs backups
exec > >(tee logs/mac-step11.log) 2>&1
export PATH="/usr/local/bin:/opt/homebrew/bin:/Applications/Docker.app/Contents/Resources/bin:$PATH"
s() { echo; echo "=== $* ==="; }
val() { grep "^$1=" .env | cut -d= -f2-; }
setenv() { if grep -q "^$1=" .env; then sed -i '' "s|^$1=.*|$1=$2|" .env; else echo "$1=$2" >> .env; fi; }
NET=slatff_default
cu() { docker run --rm --network "$NET" --entrypoint sh curlimages/curl:latest -c "$1"; }
MODE=${1:-all}
ID=$(val ID_HOST)
ISS="https://$ID/realms/slatff"

s date; date

s "1. settings in .env"
for v in PSSO_OIDC_CLIENT_SECRET APPLE_BUSINESS_CLIENT_SECRET; do
  if [ -z "$(val $v)" ]; then setenv "$v" "$(openssl rand -hex 24)"; echo "generated $v (not shown)"; else echo "$v already set"; fi
done
[ -n "$(val WEBLOGIN_BUNDLE_ID)" ] || setenv WEBLOGIN_BUNDLE_ID no.uio.WebloginSSO
if [ "$MODE" != apple ] && [ -z "$(val APPLE_TEAM_ID)" ]; then
  echo "STOP: set APPLE_TEAM_ID in .env (your Apple Developer Team ID, 10 characters)"; exit 1
fi
if [ "$MODE" != psso ] && [ -z "$(val APPLE_FEDERATION_ADMIN)" ]; then
  echo "NOTE: APPLE_FEDERATION_ADMIN is empty; set it to the Keycloak user for Apple's connection test"
fi

s "2. database backup"
F="backups/keycloak-$(date +%Y%m%d-%H%M%S).sql"
docker compose exec -T postgres pg_dump -U keycloak keycloak > "$F" && echo "saved $F ($(wc -c < "$F") bytes)" \
  || { echo "STOP: backup failed"; exit 1; }

if [ "$MODE" != apple ]; then
  s "3. Platform SSO extension (University of Oslo): download and verify"
  bash scripts/get-psso-extension.sh || { echo "STOP: download or verification failed, nothing installed"; exit 1; }
fi

s "4. Keycloak features"
FEAT=$(val KC_FEATURES)
want=""; [ "$MODE" != apple ] && want="declarative-ui"; [ "$MODE" != psso ] && want="$want ssf"
for f in $want; do case ",$FEAT," in *,$f,*) ;; *) FEAT="${FEAT:+$FEAT,}$f";; esac; done
setenv KC_FEATURES "$FEAT"
echo "KEYCLOAK_VERSION=$(val KEYCLOAK_VERSION)  KC_FEATURES=$(val KC_FEATURES)"
docker compose up -d --force-recreate keycloak
for i in $(seq 1 60); do cu 'curl -sf -m 3 http://keycloak:8080/realms/slatff/.well-known/openid-configuration' >/dev/null 2>&1 && break; sleep 3; done
cu 'curl -sf -m 3 http://keycloak:8080/realms/slatff/.well-known/openid-configuration' >/dev/null && echo "Keycloak is up" \
  || { echo "STOP: Keycloak did not come up; docker compose logs keycloak"; exit 1; }
docker compose logs keycloak 2>/dev/null | grep -E "features enabled|psso|PSSO" | tail -4

if [ "$MODE" != apple ]; then
  s "5. Platform SSO realm settings"
  bash scripts/kc-apply-psso.sh || { echo "STOP: Platform SSO setup failed"; exit 1; }

  s "6. apple-app-site-association for $ID"
  APP="$(val APPLE_TEAM_ID).$(val WEBLOGIN_BUNDLE_ID)"
  printf '{\n  "authsrv": {\n    "apps": ["%s"]\n  },\n  "webcredentials": {\n    "apps": ["%s"]\n  }\n}\n' "$APP" "$APP" \
    > caddy/well-known/apple-app-site-association
  echo "written for $APP"
  cu "curl -s -m 5 --connect-to $ID:443:caddy:443 https://$ID/.well-known/apple-app-site-association" 2>/dev/null | head -4 \
    || echo "(check https://$ID/.well-known/apple-app-site-association in a browser)"

  s "7. MDM files"
  python3 scripts/make-mdm-files.py && ls dist/mdm | grep -i -E "psso|platform|associated" || true
fi

if [ "$MODE" != psso ]; then
  s "8. Apple Business / School Manager federation"
  bash scripts/kc-apply-apple-business.sh || { echo "STOP: Keycloak setup failed"; exit 1; }
  echo
  echo "SSF configuration (from inside Docker):"
  cu "curl -s -m 5 http://keycloak:8080/realms/slatff/.well-known/ssf-configuration" | head -c 600; echo
  echo
  echo "In Apple Business Manager > Preferences/Settings > Domains > User sign-in and directory sync >"
  echo "Custom Identity Provider, enter:"
  echo "  Client ID:                 apple-business"
  echo "  Client secret:             copied to your clipboard now (paste it, then copy something else)"
  echo "  OpenID configuration URL:  $ISS/.well-known/openid-configuration"
  echo "  SSF configuration URL:     $ISS/.well-known/ssf-configuration"
  grep "^APPLE_BUSINESS_CLIENT_SECRET=" .env | cut -d= -f2- | tr -d '\n' | pbcopy
  echo
  echo "Apple's servers must reach these URLs over the internet: tunnel profile (docs/REMOTE-ACCESS.md)."
  echo "Check from a phone on mobile data: $ISS/.well-known/ssf-configuration"
fi
echo
echo "Next steps: docs/APPLE.md"
