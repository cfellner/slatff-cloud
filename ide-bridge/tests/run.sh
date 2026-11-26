#!/usr/bin/env bash
# Offline test of the IDE bridge: fake Keycloak (device flow, refresh, revocation), the real model
# gateway, a fake model, and the bridge in memory-token mode. curl plays Xcode, Visual Studio
# (OpenAI style) and Qt Creator (Ollama style). No network, no OS secret store.
# Usage: bash ide-bridge/tests/run.sh   (python3 with aiohttp and PyJWT[crypto] for the fakes)
set -u
cd "$(dirname "$0")"
G=../../model-gateway
W=$(mktemp -d); cp $G/tests/fake.py $G/gateway.py $G/policy.json ../bridge.py "$W"/; cd "$W"
python3 fake.py > fake.log 2>&1 & F=$!
sleep 2
ISS=http://127.0.0.1:9001/realms/slatff
OIDC_ISSUER=$ISS UPSTREAM_URL=http://127.0.0.1:9002/v1 POLICY_FILE=./policy.json AUDIT_FILE=./audit/audit.jsonl \
  python3 gateway.py > gw.log 2>&1 & GW=$!
for i in $(seq 1 10); do curl -sf localhost:8080/healthz >/dev/null && break; sleep 1; done
KEY=local-test-key
SLATFF_ISSUER=$ISS SLATFF_GATEWAY=http://127.0.0.1:8080/v1 SLATFF_TOKEN_STORE=memory SLATFF_LOCAL_KEY=$KEY \
  SLATFF_IDE=qtcreator SLATFF_BRIDGE_PORT=11435 python3 -u bridge.py login-and-serve > bridge.log 2>&1 & B=$!
trap 'kill $F $GW $B 2>/dev/null' EXIT
for i in $(seq 1 15); do curl -sf localhost:11435/healthz >/dev/null && break; sleep 1; done
fail=0; X=localhost:11435; K=$X/k/$KEY; H="Authorization: Bearer $KEY"
t(){ want=$1; name=$2; shift 2; got=$(curl -s -o /tmp/br_out -w "%{http_code}" "$@")
     if [ "$got" = "$want" ]; then echo "PASS $name ($got)"; else echo "FAIL $name: got $got, want $want ($(head -c 200 /tmp/br_out))"; fail=1; fi; }
has(){ if grep -q "$1" /tmp/br_out; then echo "PASS $2"; else echo "FAIL $2: $(head -c 200 /tmp/br_out)"; fail=1; fi; }
grep -q "Signed in as alice" bridge.log && echo "PASS device sign-in completed (after authorization_pending)" || { echo "FAIL sign-in: $(cat bridge.log)"; fail=1; }
echo "--- OpenAI style (Xcode, Visual Studio)"
t 200 "models with key header" $X/v1/models -H "$H"
grep -q llama3.2:1b /tmp/br_out && ! grep -q secret-model /tmp/br_out && echo "PASS model list filtered for alice" || { echo "FAIL model list"; fail=1; }
t 200 "chat" $X/v1/chat/completions -H "$H" -d '{"model":"llama3.2:1b","messages":[{"role":"user","content":"hi"}]}'
t 200 "streaming chat" $X/v1/chat/completions -H "$H" -d '{"model":"llama3.2:1b","stream":true,"messages":[]}'
has '\[DONE\]' "stream passed through"
t 200 "key in path instead of header" $K/v1/models
t 403 "gateway policy still applies (BOARD-ONLY for alice)" $X/v1/chat/completions -H "$H" -d '{"model":"llama3.2:1b","messages":[{"role":"system","content":"CLASSIFICATION: BOARD-ONLY x"}]}'
echo "--- Ollama style (Qt Creator, Visual Studio Ollama provider)"
t 200 "/api/version" $K/api/version
t 200 "/api/tags" $K/api/tags
has '"name": "llama3.2:1b"' "tags list models in Ollama format"
t 200 "/api/chat streaming (NDJSON)" $K/api/chat -d '{"model":"llama3.2:1b","messages":[{"role":"user","content":"hi"}]}'
python3 - <<'PY' && echo "PASS NDJSON pieces join to the model answer, last one done" || { echo "FAIL ndjson"; fail=1; }
import json
lines=[json.loads(l) for l in open("/tmp/br_out") if l.strip()]
assert "".join(l["message"]["content"] for l in lines)=="Hello" and lines[-1]["done"] and not lines[0]["done"]
PY
t 200 "/api/chat non-streaming" $K/api/chat -d '{"model":"llama3.2:1b","stream":false,"messages":[{"role":"user","content":"hi"}]}'
has '"content": "Hello"' "non-streaming answer assembled"
t 200 "/api/generate non-streaming" $K/api/generate -d '{"model":"llama3.2:1b","stream":false,"prompt":"hi"}'
has '"response": "Hello"' "generate answer in Ollama format"
t 403 "Ollama style: policy applies (BOARD-ONLY)" $K/api/chat -d '{"model":"llama3.2:1b","stream":false,"messages":[{"role":"system","content":"CLASSIFICATION: BOARD-ONLY x"}]}'
t 403 "Ollama style: model outside policy" $K/api/chat -d '{"model":"secret-model","stream":false,"messages":[]}'
echo "--- local protection"
t 401 "wrong key in header" $X/v1/models -H "Authorization: Bearer nope"
t 401 "no key" $X/api/tags
t 401 "wrong key in path" $X/k/nope/api/tags
t 404 "other paths not forwarded (tools)" $K/v1/tools/kb-search -d '{}'
echo "--- tokens and evidence"
echo "waiting for the 40 s access token to need a refresh..."; sleep 12
t 200 "access token refreshed silently" $K/api/chat -d '{"model":"llama3.2:1b","stream":false,"messages":[]}'
python3 - <<'PY' && echo "PASS gateway audit: user alice, client ide-bridge, ide qtcreator" || { echo "FAIL audit"; fail=1; }
import json
r=[json.loads(l) for l in open("audit/audit.jsonl")]
assert any(x.get("user")=="alice" and x.get("client")=="ide-bridge" and x.get("ide")=="qtcreator" for x in r)
PY
curl -s -X POST localhost:9001/test/revoke >/dev/null
echo "Keycloak session revoked; waiting until the bridge must refresh again..."; sleep 12
t 403 "after revocation the bridge stops" $K/v1/models
has "session has ended" "clear message to sign in again"
echo "--- part B: stable key, start without sign-in"
C=$W/cfg; K1=$(SLATFF_CONFIG_DIR=$C SLATFF_TOKEN_STORE=file python3 bridge.py key)
K2=$(SLATFF_CONFIG_DIR=$C SLATFF_TOKEN_STORE=file python3 bridge.py key)
NEWOUT=$(SLATFF_CONFIG_DIR=$C SLATFF_TOKEN_STORE=file python3 bridge.py key new 2>&1)
K3=$(SLATFF_CONFIG_DIR=$C SLATFF_TOKEN_STORE=file python3 bridge.py key)
echo "$NEWOUT" | grep -qF "$K3" && { echo "FAIL key new prints the key"; fail=1; } || echo "PASS key new does not print the key"
[ -n "$K1" ] && [ "$K1" = "$K2" ] && echo "PASS local key is the same on the next run" || { echo "FAIL key not stable"; fail=1; }
[ -n "$K3" ] && [ "$K3" != "$K1" ] && echo "PASS key new replaces it" || { echo "FAIL key new"; fail=1; }
[ "$(stat -c %a $C/local-key 2>/dev/null || stat -f %Lp $C/local-key)" = "600" ] && echo "PASS key file readable only by the user (file store)" || { echo "FAIL key file mode"; fail=1; }
SLATFF_CONFIG_DIR=$C SLATFF_ISSUER=$ISS SLATFF_GATEWAY=http://127.0.0.1:8080/v1 SLATFF_TOKEN_STORE=file \
  SLATFF_BRIDGE_PORT=11436 python3 -u bridge.py serve > bridge2.log 2>&1 & B2=$!
trap 'kill $F $GW $B $B2 2>/dev/null' EXIT
for i in $(seq 1 10); do curl -sf localhost:11436/healthz >/dev/null && break; sleep 1; done
t 403 "serve starts without sign-in and refuses with a reason" localhost:11436/v1/models -H "x-api-key: $K3"
has "not signed in" "message tells the user to sign in"
grep -q "$K3" bridge2.log && { echo "FAIL key written to the log"; fail=1; } || echo "PASS key not written to a non-terminal log"
kill $B2 2>/dev/null
echo "--- part B: settings from MDM (managed preferences)"
M=$W/managed; mkdir -p "$M/$(id -un)"
python3 - "$M" "$(id -un)" <<'PY2'
import plistlib, sys
base, user = sys.argv[1], sys.argv[2]
plistlib.dump({"Issuer": "https://id.managed.example/realms/slatff", "IDE": "xcode", "Port": 11500},
              open(f"{base}/cloud.slatff.ide-bridge.plist", "wb"))
plistlib.dump({"IDE": "xcode-user-scope"}, open(f"{base}/{user}/cloud.slatff.ide-bridge.plist", "wb"))
PY2
OUT=$(SLATFF_MANAGED_DIR=$M SLATFF_CONFIG_DIR=$C SLATFF_ISSUER=https://user.example SLATFF_TOKEN_STORE=file python3 bridge.py config)
echo "$OUT" | grep -E "^issuer .*id.managed.example.*managed" >/dev/null && echo "PASS managed issuer wins over the environment" || { echo "FAIL managed issuer: $OUT"; fail=1; }
echo "$OUT" | grep -E "^ide .*xcode-user-scope .*managed" >/dev/null && echo "PASS user-scope managed setting wins over device scope" || { echo "FAIL user scope: $OUT"; fail=1; }
echo "$OUT" | grep -E "^port .*11500 .*managed" >/dev/null && echo "PASS managed port" || { echo "FAIL managed port: $OUT"; fail=1; }
echo "$OUT" | grep -E "^gateway .*-.*default" >/dev/null && echo "PASS unmanaged setting falls back" || { echo "FAIL fallback: $OUT"; fail=1; }
CO=$(SLATFF_MANAGED_DIR=$M SLATFF_CONFIG_DIR=$C SLATFF_TOKEN_STORE=file python3 bridge.py configure --issuer https://mine.example --gateway https://gw.example/gateway/v1)
echo "$CO" | grep -q "not changed: issuer is set by your organisation" && grep -q gw.example "$C/ide-bridge.json" && ! grep -q mine.example "$C/ide-bridge.json" \
  && echo "PASS configure keeps managed settings, saves the others" || { echo "FAIL configure: $CO"; fail=1; }
SLATFF_TOKEN_STORE=auto python3 bridge.py selftest-store && echo "PASS OS secret store on this machine" || { echo "FAIL secret store"; fail=1; }
exit $fail
