#!/usr/bin/env bash
# Offline test of the model gateway and the delegation (token exchange) path:
# a fake Keycloak (own signing key, JWKS and token exchange), a fake model and the real
# kb-tool, then requests with expected status codes. No Docker, no network. Used by CI.
# Usage: bash model-gateway/tests/run.sh   (needs python3 with aiohttp and PyJWT[crypto])
set -u
cd "$(dirname "$0")"
W=$(mktemp -d); cp -r fake.py mint.py docs ../gateway.py ../../kb-tool/kb_tool.py "$W"/
sed 's#http://kb-tool:8080/search#http://127.0.0.1:9003/search#' ../policy.json > "$W/policy.json"; cd "$W"
python3 fake.py > fake.log 2>&1 & F=$!
sleep 2
ISS=http://127.0.0.1:9001/realms/slatff
OIDC_ISSUER=$ISS UPSTREAM_URL=http://127.0.0.1:9002/v1 GATEWAY_CLIENT_SECRET=test-secret \
  POLICY_FILE=./policy.json AUDIT_FILE=./audit/audit.jsonl python3 gateway.py > gw.log 2>&1 & G=$!
OIDC_ISSUER=$ISS DOCS_DIR=./docs POLICY_FILE=./policy.json AUDIT_FILE=./audit/kb-tool.jsonl \
  python3 -c "import kb_tool, aiohttp.web as w; a=w.Application(); a.router.add_post('/search', kb_tool.search); w.run_app(a, host='127.0.0.1', port=9003, access_log=None)" > kb.log 2>&1 & K=$!
trap 'kill $F $G $K 2>/dev/null' EXIT
for i in 1 2 3 4 5 6 7 8 9 10; do curl -sf localhost:8080/healthz >/dev/null && break; sleep 1; done
sleep 1
A=$(python3 mint.py alice ai-user); C=$(python3 mint.py carol ai-admin,ai-user); B=$(python3 mint.py bob "")
X=$(python3 mint.py alice ai-user wrong-aud); E=$(python3 mint.py alice ai-user model-gateway http://evil/realms/slatff)
OLD=$(python3 mint.py alice ai-user model-gateway $ISS -600)
P='{"model":"llama3.2:1b","messages":[{"role":"user","content":"hi"}]}'
BOARD='{"model":"llama3.2:1b","messages":[{"role":"system","content":"CLASSIFICATION: BOARD-ONLY x"},{"role":"user","content":"q"}]}'
UNK='{"model":"llama3.2:1b","messages":[{"role":"user","content":"CLASSIFICATION: TOP-SECRET x"}]}'
U=localhost:8080/v1/chat/completions; fail=0
t(){ want=$1; name=$2; shift 2; got=$(curl -s -o /tmp/gw_out -w "%{http_code}" "$@")
     if [ "$got" = "$want" ]; then echo "PASS $name ($got)"; else echo "FAIL $name: got $got, want $want"; fail=1; fi; }
echo "--- model access"
t 200 "model list without token" localhost:8080/v1/models
t 200 "chat as alice (ai-user)" $U -H "Authorization: Bearer $A" -d "$P"
t 200 "streaming chat as alice" $U -H "Authorization: Bearer $A" -d '{"model":"llama3.2:1b","stream":true,"messages":[]}'
t 401 "chat without token" $U -d "$P"
t 403 "chat as bob (no role)" $U -H "Authorization: Bearer $B" -d "$P"
t 403 "model not in policy" $U -H "Authorization: Bearer $A" -d '{"model":"secret-model","messages":[]}'
t 403 "BOARD-ONLY content for alice" $U -H "Authorization: Bearer $A" -d "$BOARD"
t 200 "BOARD-ONLY content for carol (ai-admin)" $U -H "Authorization: Bearer $C" -d "$BOARD"
t 403 "unknown label (fail closed)" $U -H "Authorization: Bearer $A" -d "$UNK"
t 401 "wrong audience" $U -H "Authorization: Bearer $X" -d "$P"
t 401 "wrong issuer" $U -H "Authorization: Bearer $E" -d "$P"
t 401 "expired token" $U -H "Authorization: Bearer $OLD" -d "$P"
t 401 "tampered token" $U -H "Authorization: Bearer ${A%?}x" -d "$P"
curl -s localhost:8080/v1/models -H "Authorization: Bearer $B" | grep -q '"data": \[\]' && echo "PASS bob sees no models" || { echo "FAIL bob model list"; fail=1; }

echo "--- delegation: authority narrows"
T=localhost:8080/v1/tools/kb-search; Q='{"query":"holiday"}'
t 200 "alice calls kb-search through the gateway" $T -H "Authorization: Bearer $A" -d "$Q"
grep -q staff-holidays /tmp/gw_out && ! grep -q board-acquisition /tmp/gw_out && grep -q '"withheld": 1' /tmp/gw_out \
  && echo "PASS alice gets STAFF doc, BOARD-ONLY withheld" || { echo "FAIL alice result: $(cat /tmp/gw_out)"; fail=1; }
t 200 "carol calls kb-search" $T -H "Authorization: Bearer $C" -d "$Q"
grep -q board-acquisition /tmp/gw_out && echo "PASS carol also gets the BOARD-ONLY doc" || { echo "FAIL carol result"; fail=1; }
t 401 "tool call without token" $T -d "$Q"
t 403 "bob may not use the tool" $T -H "Authorization: Bearer $B" -d "$Q"
t 403 "tool not in policy" localhost:8080/v1/tools/delete-everything -H "Authorization: Bearer $A" -d "$Q"
t 401 "user's own token sent straight to the tool is refused" 127.0.0.1:9003/search -H "Authorization: Bearer $A" -d "$Q"
# get an exchanged token the way the gateway does, then try to misuse it
D=$(curl -s 127.0.0.1:9001/realms/slatff/protocol/openid-connect/token -d grant_type=urn:ietf:params:oauth:grant-type:token-exchange \
    -d client_id=model-gateway -d client_secret=test-secret -d subject_token="$A" \
    -d subject_token_type=urn:ietf:params:oauth:token-type:access_token -d audience=kb-tool -d scope=kb-search \
    | python3 -c 'import sys,json; print(json.load(sys.stdin)["access_token"])')
t 200 "exchanged token works at the tool" 127.0.0.1:9003/search -H "Authorization: Bearer $D" -d "$Q"
t 401 "exchanged token is refused by the model gateway (narrower audience)" $U -H "Authorization: Bearer $D" -d "$P"
python3 - "$D" "$A" <<'PY' && echo "PASS exchanged token: aud kb-tool only, scope kb-search, expires no later than the user token" || { echo "FAIL exchanged token claims"; fail=1; }
import sys, jwt
d, a = (jwt.decode(x, options={"verify_signature": False}) for x in sys.argv[1:3])
assert d["aud"] == "kb-tool" and d["scope"] == "kb-search" and d["exp"] <= a["exp"] and d["azp"] == "model-gateway"
PY
X2=$(curl -s -o /dev/null -w "%{http_code}" 127.0.0.1:9001/realms/slatff/protocol/openid-connect/token -d grant_type=urn:ietf:params:oauth:grant-type:token-exchange \
    -d client_id=model-gateway -d client_secret=test-secret -d subject_token="$A" \
    -d subject_token_type=urn:ietf:params:oauth:token-type:access_token -d audience=payments-api -d scope=kb-search)
[ "$X2" = "400" ] && echo "PASS exchange for an audience outside the policy is refused" || { echo "FAIL widen audience: $X2"; fail=1; }

echo "--- evidence chain"
python3 - <<'PY' && echo "PASS gateway and tool audit lines join on correlation ID and token ID" || { echo "FAIL evidence chain"; fail=1; }
import json
g=[json.loads(l) for l in open("audit/audit.jsonl") if '"tool"' in l and '"allow"' in l]
k={r.get("correlation_id"): r for r in map(json.loads, open("audit/kb-tool.jsonl")) if r.get("decision")=="allow"}
assert g
for r in g:
    t=k[r["correlation_id"]]
    assert t["jti"]==r["delegated"]["jti"] and t["user"]==r["user"] and r["subject_jti"]
PY
n=$(wc -l < audit/audit.jsonl); [ "$n" -ge 16 ] && echo "PASS audit log has $n decisions" || { echo "FAIL audit lines $n"; fail=1; }
exit $fail
