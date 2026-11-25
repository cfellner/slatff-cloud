#!/usr/bin/env bash
# Step 2 on a Mac: start the core services and check DNS, certificates, Keycloak and Open WebUI.
# Writes logs/mac-step2.log. Stop everything again with: docker compose down
cd "$(dirname "$0")/.."
mkdir -p logs
exec > >(tee logs/mac-step2.log) 2>&1
export PATH="/usr/local/bin:/opt/homebrew/bin:/Applications/Docker.app/Contents/Resources/bin:$PATH"
s() { echo; echo "=== $* ==="; }
val() { grep "^$1=" .env | cut -d= -f2-; }

s date; date
if [ -z "$(val CLOUDFLARE_API_TOKEN)" ]; then echo "STOP: CLOUDFLARE_API_TOKEN is empty in .env"; exit 1; fi
echo "Cloudflare token present (not shown)"
ID=$(val ID_HOST); AI=$(val AI_HOST); MEET=$(val MEET_HOST); FILES=$(val FILES_HOST); LAN=$(ipconfig getifaddr en0)
echo "hosts: $ID $AI $MEET   this Mac: $LAN"

s "DNS as this Mac sees it (expect $LAN)"
for h in $ID $AI $MEET $FILES; do printf '%s -> ' "$h"; dscacheutil -q host -a name "$h" | awk '/ip_address/{print $2}' | head -1; echo; done
s "DNS from Cloudflare directly (1.1.1.1)"
for h in $ID $AI $MEET $FILES; do printf '%s -> %s\n' "$h" "$(dig +short "$h" @1.1.1.1 | tail -1)"; done

s "start core services"
docker compose up -d --build
docker compose ps

s "wait for Keycloak through Caddy (up to 5 minutes; certificates come first)"
ok=""
for i in $(seq 1 60); do
  if curl -fsS -m 5 "https://$ID/realms/slatff/.well-known/openid-configuration" >/dev/null 2>&1; then ok=dns; break; fi
  if curl -fsS -m 5 --resolve "$ID:443:127.0.0.1" "https://$ID/realms/slatff/.well-known/openid-configuration" >/dev/null 2>&1; then ok=local; break; fi
  sleep 5
done
case $ok in
  dns) echo "PASS: realm slatff answers at https://$ID with a trusted certificate, via normal DNS";;
  local) echo "PARTIAL: works when forced to 127.0.0.1 but not via normal DNS. Likely the router blocks private answers (DNS rebinding protection) or the A records are wrong.";;
  *) echo "FAIL: no answer from https://$ID after 5 minutes. See Caddy and Keycloak logs below.";;
esac

s "certificate issuer for each name"
for h in $ID $AI; do printf '%s: ' "$h"; echo | openssl s_client -connect 127.0.0.1:443 -servername "$h" 2>/dev/null | openssl x509 -noout -issuer -enddate 2>/dev/null | tr '\n' ' '; echo; done

s "Open WebUI health"
curl -sS -m 10 --resolve "$AI:443:127.0.0.1" "https://$AI/health"; echo
s "Open WebUI sign-in config (password form should be off)"
curl -sS -m 10 --resolve "$AI:443:127.0.0.1" "https://$AI/api/config" | python3 -c 'import sys,json; c=json.load(sys.stdin); f=c.get("features",{}); print({k:f.get(k) for k in ("enable_login_form","enable_signup","auth")}, "oauth providers:", list(c.get("oauth",{}).get("providers",{}).keys()))' 2>&1

s "realm import: were the placeholders substituted?"
PW=$(val KC_BOOTSTRAP_ADMIN_PASSWORD); U=$(val KC_BOOTSTRAP_ADMIN_USERNAME)
docker compose exec -T keycloak /opt/keycloak/bin/kcadm.sh config credentials --server http://localhost:8080 --realm master --user "${U:-admin}" --password "$PW" >/dev/null 2>&1 && echo "admin login OK"
docker compose exec -T keycloak /opt/keycloak/bin/kcadm.sh get clients -r slatff --fields clientId,redirectUris 2>&1 | grep -A3 -E '"open-webui"|"jitsi"'
docker compose exec -T keycloak /opt/keycloak/bin/kcadm.sh get clients -r slatff -q clientId=open-webui --fields secret 2>&1 | grep -q '\${' && echo "FAIL: client secret still a placeholder" || echo "client secret is not a placeholder"
docker compose exec -T keycloak /opt/keycloak/bin/kcadm.sh get roles -r slatff --fields name 2>&1 | grep name

s "Caddy log (certificates)"
docker compose logs caddy 2>&1 | grep -iE 'certificate obtained|error|solving|challenge' | tail -15
s "Keycloak log (import, errors)"
docker compose logs keycloak 2>&1 | grep -iE 'import|realm|error|started in' | tail -15
s "Open WebUI log (errors)"
docker compose logs open-webui 2>&1 | grep -iE 'error|oauth|ollama' | tail -10

s "done"; echo "Step 2 finished. Services keep running. Output saved in logs/mac-step2.log."
