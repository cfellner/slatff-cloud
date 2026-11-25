#!/usr/bin/env bash
# Step 3: put the model gateway between Open WebUI and the model, and prove it on the live stack.
# - Keycloak: sign-out addresses and the "model-gateway" audience (kc-apply-client-settings.sh)
# - builds and starts the gateway; points Open WebUI only at it (fresh Open WebUI, see below)
# - live tests with a real Keycloak token from a temporary test client, then disables that client
# Writes logs/mac-step3.log. No token or secret is printed.
cd "$(dirname "$0")/.."
mkdir -p logs
exec > >(tee logs/mac-step3.log) 2>&1
export PATH="/usr/local/bin:/opt/homebrew/bin:/Applications/Docker.app/Contents/Resources/bin:$PATH"
s() { echo; echo "=== $* ==="; }
val() { grep "^$1=" .env | cut -d= -f2-; }
ID=$(val ID_HOST); NET=slatff_default
C() { docker run --rm --network "$NET" curlimages/curl:latest "$@"; }

s date; date

s "1. Keycloak client settings"
bash scripts/kc-apply-client-settings.sh

s "2. second model for the knowledge demo (llama3.2:3b, about 2 GB)"
ollama pull llama3.2:3b 2>&1 | tail -1

s "3. build and start the model gateway"
docker compose up -d --build model-gateway
for i in $(seq 1 20); do C -s -m 3 http://model-gateway:8080/healthz 2>/dev/null | grep -q '"ok": true' && break; sleep 2; done
C -s -m 3 http://model-gateway:8080/healthz; echo

s "4. live tests with a real Keycloak token"
docker compose exec -T keycloak bash -c '
  k=/opt/keycloak/bin/kcadm.sh
  KC_CLI_PASSWORD="$KC_BOOTSTRAP_ADMIN_PASSWORD" $k config credentials --server http://localhost:8080 --realm master --user "$KC_BOOTSTRAP_ADMIN_USERNAME" >/dev/null
  id=$($k get clients -r slatff -q clientId=gateway-selftest --fields id --format csv --noquotes)
  if [ -z "$id" ]; then
    $k create clients -r slatff -f - >/dev/null <<JSON
{"clientId":"gateway-selftest","name":"Model gateway self-test (disabled after use)","enabled":true,
 "publicClient":false,"standardFlowEnabled":false,"directAccessGrantsEnabled":false,"serviceAccountsEnabled":true,
 "protocolMappers":[
  {"name":"realm roles flat","protocol":"openid-connect","protocolMapper":"oidc-usermodel-realm-role-mapper",
   "config":{"claim.name":"roles","multivalued":"true","jsonType.label":"String","access.token.claim":"true"}},
  {"name":"audience model-gateway","protocol":"openid-connect","protocolMapper":"oidc-audience-mapper",
   "config":{"included.custom.audience":"model-gateway","access.token.claim":"true"}}]}
JSON
    $k add-roles -r slatff --uusername service-account-gateway-selftest --rolename ai-user
    echo "created test client gateway-selftest (role ai-user)"
  else
    $k update "clients/$id" -r slatff -s enabled=true
    echo "re-enabled test client gateway-selftest"
  fi' 
SECRET=$(docker compose exec -T keycloak bash -c '
  k=/opt/keycloak/bin/kcadm.sh
  KC_CLI_PASSWORD="$KC_BOOTSTRAP_ADMIN_PASSWORD" $k config credentials --server http://localhost:8080 --realm master --user "$KC_BOOTSTRAP_ADMIN_USERNAME" >/dev/null
  id=$($k get clients -r slatff -q clientId=gateway-selftest --fields id --format csv --noquotes)
  $k get "clients/$id/client-secret" -r slatff --fields value --format csv --noquotes')
TOKEN=$(docker run --rm --network "$NET" -e S="$SECRET" --entrypoint sh curlimages/curl:latest -c \
  "curl -s -d grant_type=client_credentials -d client_id=gateway-selftest -d client_secret=\"\$S\" https://$ID/realms/slatff/protocol/openid-connect/token" \
  | python3 -c 'import sys,json; print(json.load(sys.stdin).get("access_token",""))')
unset SECRET
[ -n "$TOKEN" ] && echo "got a Keycloak access token for the test client (not shown)" || echo "FAIL: no token from Keycloak"

G=http://model-gateway:8080/v1/chat/completions
t() { want=$1; name=$2; body=$3; auth=$4
  got=$(docker run --rm --network "$NET" -e T="$auth" -e B="$body" --entrypoint sh curlimages/curl:latest -c \
    'if [ -n "$T" ]; then H="Authorization: Bearer $T"; else H="X-No-Token: 1"; fi; curl -s -m 120 -o /tmp/o -w "%{http_code}" -H "$H" -H "Content-Type: application/json" -d "$B" '"$G"'; echo; head -c 160 /tmp/o')
  code=$(echo "$got" | head -1); detail=$(echo "$got" | tail -n +2)
  if [ "$code" = "$want" ]; then echo "PASS $name ($code)"; else echo "FAIL $name: got $code, want $want"; fi
  echo "     $detail"; }
t 200 "real model answers a permitted request" '{"model":"llama3.2:1b","messages":[{"role":"user","content":"Reply with the single word OK."}]}' "$TOKEN"
t 403 "BOARD-ONLY content refused for an ai-user" '{"model":"llama3.2:1b","messages":[{"role":"system","content":"CLASSIFICATION: BOARD-ONLY test"},{"role":"user","content":"x"}]}' "$TOKEN"
t 403 "model outside the policy refused" '{"model":"not-in-policy","messages":[]}' "$TOKEN"
t 401 "request without a token refused" '{"model":"llama3.2:1b","messages":[]}' ""
unset TOKEN

docker compose exec -T keycloak bash -c '
  k=/opt/keycloak/bin/kcadm.sh
  KC_CLI_PASSWORD="$KC_BOOTSTRAP_ADMIN_PASSWORD" $k config credentials --server http://localhost:8080 --realm master --user "$KC_BOOTSTRAP_ADMIN_USERNAME" >/dev/null
  id=$($k get clients -r slatff -q clientId=gateway-selftest --fields id --format csv --noquotes)
  $k update "clients/$id" -r slatff -s enabled=false && echo "test client gateway-selftest disabled again"'

s "5. known gap: is Ollama still reachable directly from a container?"
C -s -m 5 http://host.docker.internal:11434/api/version && echo "  <- yes: any container on this Mac can still bypass the gateway (see docs/MODEL-GATEWAY.md)" || echo "not reachable"

s "6. gateway audit log (last 6 decisions)"
docker compose exec -T model-gateway sh -c 'tail -6 /audit/audit.jsonl'

s "7. Open WebUI: start fresh so it uses only the gateway"
echo "Open WebUI keeps connection settings in its own database, so the new settings only apply"
echo "to a fresh Open WebUI. This deletes Open WebUI's chats and accounts (users come back from"
echo "Keycloak at their next sign-in; sign in as carol first). Keycloak is not touched."
read -r -p "Type RESET to start Open WebUI fresh, anything else to skip: " ans
if [ "$ans" = "RESET" ]; then
  docker compose rm -sf open-webui
  docker volume rm slatff_open-webui-data
  docker compose up -d open-webui
  echo "Open WebUI recreated. Wait about a minute, then sign in as carol first."
else
  echo "skipped: Open WebUI still talks to Ollama directly"
fi

s "done"; echo "Step 3 finished. Output saved in logs/mac-step3.log."
