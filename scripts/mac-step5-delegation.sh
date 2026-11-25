#!/usr/bin/env bash
# Step 5: delegation, "authority narrows" (docs/DELEGATION.md).
# The gateway calls a tool on the user's behalf with a token Keycloak exchanged for that one
# tool, never with the user's own token. Proves it on the live stack and shows the evidence.
# Writes logs/mac-step5.log. No token or secret is printed.
cd "$(dirname "$0")/.."
mkdir -p logs
exec > >(tee logs/mac-step5.log) 2>&1
export PATH="/usr/local/bin:/opt/homebrew/bin:/Applications/Docker.app/Contents/Resources/bin:$PATH"
s() { echo; echo "=== $* ==="; }
val() { grep "^$1=" .env | cut -d= -f2-; }
ID=$(val ID_HOST); NET=slatff_default
TOK=https://$ID/realms/slatff/protocol/openid-connect/token
kc() { docker compose exec -T keycloak bash -c '
  k=/opt/keycloak/bin/kcadm.sh
  KC_CLI_PASSWORD="$KC_BOOTSTRAP_ADMIN_PASSWORD" $k config credentials --server http://localhost:8080 --realm master --user "$KC_BOOTSTRAP_ADMIN_USERNAME" >/dev/null
  '"$1"; }
cu() { docker run --rm --network "$NET" -e T="${T:-}" -e S="${S:-}" -e B="${B:-}" --entrypoint sh curlimages/curl:latest -c "$1"; }

s date; date

s "0. file permissions (containers run as a non-root user and must be able to read these)"
chmod a+r model-gateway/*.py model-gateway/policy.json kb-tool/*.py 2>/dev/null
chmod -R a+rX demo 2>/dev/null
echo "made gateway, tool, policy and demo documents readable"

s "1. gateway client secret in .env"
if [ -z "$(val GATEWAY_CLIENT_SECRET)" ]; then
  grep -q '^GATEWAY_CLIENT_SECRET=' .env && sed -i '' '/^GATEWAY_CLIENT_SECRET=/d' .env
  echo "GATEWAY_CLIENT_SECRET=$(openssl rand -hex 24)" >> .env
  echo "generated GATEWAY_CLIENT_SECRET (not shown)"
else echo "GATEWAY_CLIENT_SECRET already set"; fi

s "2. Keycloak: clients kb-tool and model-gateway, scope kb-search"
bash scripts/kc-apply-delegation.sh || { echo "STOP: Keycloak setup failed"; exit 1; }

s "3. build and start the gateway (new version) and the demo tool"
docker compose up -d --build model-gateway kb-tool
for i in $(seq 1 20); do cu 'curl -s -m 3 http://kb-tool:8080/healthz' 2>/dev/null | grep -q '"ok": true' && break; sleep 2; done
cu 'curl -s -m 3 http://model-gateway:8080/healthz; echo; curl -s -m 3 http://kb-tool:8080/healthz'; echo

s "4. a real user token (temporary test client gateway-selftest, role ai-user)"
kc 'id=$($k get clients -r slatff -q clientId=gateway-selftest --fields id --format csv --noquotes)
    [ -n "$id" ] && $k update "clients/$id" -r slatff -s enabled=true && echo "test client enabled" || echo "STOP: run scripts/mac-step3.sh first (creates gateway-selftest)"'
S=$(kc 'id=$($k get clients -r slatff -q clientId=gateway-selftest --fields id --format csv --noquotes); $k get "clients/$id/client-secret" -r slatff --fields value --format csv --noquotes')
T=$(cu "curl -s -d grant_type=client_credentials -d client_id=gateway-selftest -d client_secret=\"\$S\" $TOK" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("access_token",""))')
unset S
[ -n "$T" ] && echo "got a user token (not shown)" || echo "FAIL: no token"
python3 - "$T" <<'PY'
import sys, json, base64
p = sys.argv[1].split(".")[1]; c = json.loads(base64.urlsafe_b64decode(p + "=" * (-len(p) % 4)))
print("  user token: aud =", c.get("aud"), "| azp =", c.get("azp"), "| roles =", c.get("roles"))
PY

s "5. live tests"
t() { want=$1; name=$2; got=$(cu "$3" | head -c 600); code=${got:0:3}
  if [ "$code" = "$want" ]; then echo "PASS $name ($code)"; else echo "FAIL $name: got $code, want $want"; fi
  echo "     ${got:3:220}"; }
H='-H "Authorization: Bearer $T" -H "Content-Type: application/json"'
export B='{"query":"holiday leave forecast"}'
t 200 "tool call through the gateway (exchanged token)" "curl -s -m 30 -o /tmp/o -w %{http_code} $H -d \"\$B\" http://model-gateway:8080/v1/tools/kb-search; cat /tmp/o"
t 401 "user token sent straight to the tool is refused" "curl -s -m 10 -o /tmp/o -w %{http_code} $H -d \"\$B\" http://kb-tool:8080/search; cat /tmp/o"
t 403 "tool not in the policy" "curl -s -m 10 -o /tmp/o -w %{http_code} $H -d \"\$B\" http://model-gateway:8080/v1/tools/delete-everything; cat /tmp/o"
S=$(val GATEWAY_CLIENT_SECRET)
D=$(cu "curl -s $TOK -d grant_type=urn:ietf:params:oauth:grant-type:token-exchange -d client_id=model-gateway -d client_secret=\"\$S\" -d subject_token=\"\$T\" -d subject_token_type=urn:ietf:params:oauth:token-type:access_token -d audience=kb-tool -d scope=kb-search" \
    | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d.get("access_token") or "ERR "+json.dumps(d))')
W=$(cu "curl -s -o /dev/null -w %{http_code} $TOK -d grant_type=urn:ietf:params:oauth:grant-type:token-exchange -d client_id=model-gateway -d client_secret=\"\$S\" -d subject_token=\"\$T\" -d subject_token_type=urn:ietf:params:oauth:token-type:access_token -d audience=open-webui")
unset S
case "$D" in ERR*) echo "FAIL exchange by hand: ${D:0:300}";; *)
  python3 - "$D" "$T" <<'PY'
import sys, json, base64
def c(t):
    p = t.split(".")[1]; return json.loads(base64.urlsafe_b64decode(p + "=" * (-len(p) % 4)))
d, u = c(sys.argv[1]), c(sys.argv[2])
print("  exchanged token: aud =", d.get("aud"), "| scope =", d.get("scope"), "| azp =", d.get("azp"),
      "| expires", d["exp"] - u["exp"], "s relative to the user token")
ok = d.get("aud") in ("kb-tool", ["kb-tool"]) and "kb-search" in d.get("scope", "").split() and d["exp"] <= u["exp"] + 5
print("PASS exchanged token is narrower (aud kb-tool only, scope kb-search, not longer-lived)" if ok
      else "CHECK exchanged token is not as narrow as expected (see line above)")
PY
  T2=$T; T=$D
  t 401 "exchanged token is refused by the model gateway (it is only for kb-tool)" "curl -s -m 10 -o /tmp/o -w %{http_code} $H -d '{\"model\":\"llama3.2:1b\",\"messages\":[]}' http://model-gateway:8080/v1/chat/completions; cat /tmp/o"
  T=$T2;;
esac
[ "$W" = "200" ] && echo "FAIL exchange for audience open-webui was allowed (should be refused)" || echo "PASS exchange for an audience the gateway was not given is refused ($W)"
unset T T2 D

kc 'id=$($k get clients -r slatff -q clientId=gateway-selftest --fields id --format csv --noquotes); $k update "clients/$id" -r slatff -s enabled=false && echo "test client gateway-selftest disabled again"'

s "6. evidence: gateway and tool audit lines (last 3 each, joined by correlation_id)"
docker compose exec -T model-gateway sh -c 'grep "\"tool\"" /audit/audit.jsonl | tail -3'
docker compose exec -T kb-tool sh -c 'tail -3 /audit/kb-tool.jsonl'

s "done"; echo "Step 5 finished. Output saved in logs/mac-step5.log."
