#!/usr/bin/env bash
# Step 8: app-to-app access with ID-JAG (docs/APP-TO-APP.md).
# Upgrades Keycloak (database backup first), builds the issuer extension, sets up realm "apps"
# and the notes API, then runs the demo: you sign in once as a user with role ai-user.
# Writes logs/mac-step8.log. No token or secret is printed.
cd "$(dirname "$0")/.."
mkdir -p logs backups
exec > >(tee logs/mac-step8.log) 2>&1
export PATH="/usr/local/bin:/opt/homebrew/bin:/Applications/Docker.app/Contents/Resources/bin:$PATH"
s() { echo; echo "=== $* ==="; }
val() { grep "^$1=" .env | cut -d= -f2-; }
setenv() { if grep -q "^$1=" .env; then sed -i '' "s|^$1=.*|$1=$2|" .env; else echo "$1=$2" >> .env; fi; }
KC_TARGET=26.8.2
NET=slatff_default
cu() { docker run --rm --network "$NET" --entrypoint sh curlimages/curl:latest -c "$1"; }

s date; date

s "1. secrets in .env"
for v in NOTES_AGENT_SECRET APPS_AGENT_SECRET OTHER_APP_SECRET; do
  if [ -z "$(val $v)" ]; then setenv "$v" "$(openssl rand -hex 24)"; echo "generated $v (not shown)"; else echo "$v already set"; fi
done

s "2. database backup before the Keycloak upgrade"
F="backups/keycloak-$(date +%Y%m%d-%H%M%S).sql"
docker compose exec -T postgres pg_dump -U keycloak keycloak > "$F" && echo "saved $F ($(wc -c < "$F") bytes)" \
  || { echo "STOP: backup failed"; exit 1; }

s "3. Keycloak $KC_TARGET with feature identity-assertion-jwt"
setenv KEYCLOAK_VERSION "$KC_TARGET"
FEAT=$(val KC_FEATURES)
case ",$FEAT," in *,identity-assertion-jwt,*) ;; *) FEAT="${FEAT:+$FEAT,}identity-assertion-jwt";; esac
setenv KC_FEATURES "$FEAT"
echo "KEYCLOAK_VERSION=$(val KEYCLOAK_VERSION)  KC_FEATURES=$(val KC_FEATURES)"

s "4. build the ID-JAG issuer extension"
bash scripts/build-id-jag-issuer.sh || { echo "STOP: build failed"; exit 1; }

s "5. restart Keycloak"
docker compose up -d keycloak
for i in $(seq 1 60); do cu 'curl -sf -m 3 http://keycloak:8080/realms/slatff/.well-known/openid-configuration' >/dev/null 2>&1 && break; sleep 3; done
cu 'curl -sf -m 3 http://keycloak:8080/realms/slatff/.well-known/openid-configuration' >/dev/null && echo "Keycloak is up" || { echo "STOP: Keycloak did not come up; docker compose logs keycloak"; exit 1; }
docker compose logs keycloak 2>/dev/null | grep -E "Keycloak .* on JVM|slatff-id-jag|identity-assertion-jwt|Preview|Experimental" | tail -6

s "6. realms: notes-agent in slatff, realm apps with the ID-JAG receiver"
bash scripts/kc-apply-app-to-app.sh || { echo "STOP: Keycloak setup failed"; exit 1; }

s "7. notes API (app B)"
chmod a+r notes-api/*.py app-to-app/*.py
docker compose up -d --build notes-api
for i in $(seq 1 20); do cu 'curl -sf -m 3 http://notes-api:8080/healthz' >/dev/null 2>&1 && break; sleep 2; done
cu 'curl -s -m 3 http://notes-api:8080/healthz'; echo

s "8. demo: sign in as alice or carol (role ai-user), in a private window"
bash scripts/app-to-app-demo.sh demo

s "9. evidence: notes API audit"
docker compose exec -T notes-api sh -c 'tail -3 /audit/notes-api.jsonl' 2>/dev/null
echo
echo "Again, or as bob (no role ai-user): bash scripts/app-to-app-demo.sh demo | demo-denied"
