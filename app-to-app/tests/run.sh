#!/usr/bin/env bash
# Offline test of the app-to-app demo client and the notes API (step 8), with a fake IdP and a
# fake app B authorization server (fake_idp.py). The Keycloak extension is tested live.
# Usage: bash app-to-app/tests/run.sh   (python3 with aiohttp and PyJWT[crypto])
set -u
cd "$(dirname "$0")"
W=$(mktemp -d); cp fake_idp.py ../agent.py ../../notes-api/notes_api.py "$W"/; cd "$W"
python3 fake_idp.py > fake.log 2>&1 & F=$!
OIDC_ISSUER=http://127.0.0.1:9101/realms/apps AUDIT_FILE=./audit/notes.jsonl PORT=9102 \
  python3 notes_api.py > notes.log 2>&1 & N=$!
trap 'kill $F $N 2>/dev/null' EXIT
for i in $(seq 1 15); do curl -sf localhost:9101/realms/slatff/protocol/openid-connect/certs >/dev/null \
  && curl -sf localhost:9102/healthz >/dev/null && break; sleep 1; done
export IDP_URL=http://127.0.0.1:9101/realms/slatff APPS_URL=http://127.0.0.1:9101/realms/apps \
  APPS_ISSUER=http://127.0.0.1:9101/realms/apps RESOURCE=https://ai.example.org/notes \
  NOTES_URL=http://127.0.0.1:9102/notes AGENT_SECRET=agent-secret APPS_AGENT_SECRET=apps-secret \
  OTHER_SECRET=other-secret
fail=0
echo "--- alice (role ai-user)"
python3 agent.py demo || fail=1
echo "--- bob (no role)"
curl -sf "localhost:9101/test/user?u=bob" >/dev/null
python3 agent.py demo-denied || fail=1
grep -q '"user": "alice"' audit/notes.jsonl && grep -q '"decision": "allow"' audit/notes.jsonl \
  && echo "PASS notes API audit has alice allowed" || { echo "FAIL notes audit"; fail=1; }
exit $fail
