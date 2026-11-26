#!/usr/bin/env bash
# Offline test of the agent demo (step 10): fake Keycloak with the 26.8 delegation rules
# (fake_kc.py), fake model, and the real model gateway and policy. Keycloak itself is tested live.
# Usage: bash agents/tests/run.sh   (python3 with aiohttp and PyJWT[crypto])
set -u
cd "$(dirname "$0")"
W=$(mktemp -d); cp fake_kc.py ../agent.py ../../model-gateway/gateway.py ../../model-gateway/policy.json "$W"/; cd "$W"
python3 fake_kc.py > fake.log 2>&1 & F=$!
for i in $(seq 1 15); do curl -sf localhost:9201/realms/slatff/protocol/openid-connect/certs >/dev/null && break; sleep 1; done
OIDC_ISSUER=http://127.0.0.1:9201/realms/slatff UPSTREAM_URL=http://127.0.0.1:9202/v1 \
  POLICY_FILE=./policy.json AUDIT_FILE=./audit/audit.jsonl python3 gateway.py > gw.log 2>&1 & G=$!
trap 'kill $F $G 2>/dev/null' EXIT
for i in $(seq 1 15); do curl -sf localhost:8080/healthz >/dev/null && break; sleep 1; done
export ISSUER=http://127.0.0.1:9201/realms/slatff GATEWAY=http://127.0.0.1:8080/v1 AGENT_KEY_STORE=memory \
  AGENT_BROWSER=none ROGUE_SECRET=rogue-secret
# the agent's key lives in memory for one process: register it from the same process that runs the demo
cat > run_agent.py <<'PY'
import sys, json, urllib.request, agent
jwks = json.dumps({"keys": [agent.public_jwk(agent.agent_key())]}).encode()
urllib.request.urlopen(urllib.request.Request("http://127.0.0.1:9201/test/jwks", data=jwks, headers={"Content-Type": "application/json"}))
sys.argv = ["agent.py"] + sys.argv[1:]
agent.main()
PY
export SWITCH_CMD="python3 switch.py"
cat > switch.py <<'PY'
import sys, urllib.request
print(urllib.request.urlopen("http://127.0.0.1:9201/test/switch?action=" + sys.argv[1]).read().decode())
PY
fail=0
echo "--- alice (role ai-user), with kill switch"
python3 run_agent.py kill-switch || fail=1
echo "--- bob (no role), kill-switch mode: the agent notices he has no role"
curl -sf "localhost:9201/test/switch?action=user&u=bob" >/dev/null
python3 run_agent.py kill-switch || fail=1
grep '"act": \["research-agent"\]' audit/audit.jsonl | grep '"user": "alice"' | grep -q '"decision": "allow"' \
  && echo "PASS gateway audit: alice and research-agent, allowed" || { echo "FAIL gateway audit"; fail=1; }
exit $fail
