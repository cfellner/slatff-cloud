#!/usr/bin/env bash
# Step 6: IDEs as governed clients: Xcode, Visual Studio, Qt Creator (docs/IDE-BRIDGE.md).
# Keycloak client ide-bridge, two gateway paths on the AI host, checks. Then you sign in and
# add the provider in Xcode (printed at the end). Writes logs/mac-step6.log. Nothing secret printed.
cd "$(dirname "$0")/.."
mkdir -p logs
exec > >(tee logs/mac-step6.log) 2>&1
export PATH="/usr/local/bin:/opt/homebrew/bin:/Applications/Docker.app/Contents/Resources/bin:$PATH"
s() { echo; echo "=== $* ==="; }
val() { grep "^$1=" .env | cut -d= -f2-; }
AI=$(val AI_HOST); ID=$(val ID_HOST)
s date; date
s "1. Keycloak: client ide-bridge (device sign-in)"
bash scripts/kc-apply-ide-bridge.sh || { echo "STOP: Keycloak setup failed"; exit 1; }
s "2. Caddy: publish /gateway/v1/models and /gateway/v1/chat/completions on $AI"
python3 scripts/apply-gateway-caddy.py || exit 1
# recreate (not reload): picks up the Caddyfile and every host name from .env
docker compose up -d --force-recreate caddy 2>&1 | tail -2
for i in $(seq 1 15); do curl -s -m 3 -o /dev/null https://$AI/ && break; sleep 2; done
sleep 2
s "3. checks from this Mac"
c() { curl -s -m 15 -o /tmp/x6 -w "%{http_code}" "$@"; }
r=$(c https://$AI/gateway/v1/models)
if [ "$r" = 200 ] && grep -q '"object"' /tmp/x6; then echo "PASS gateway model list reachable ($r): $(head -c 120 /tmp/x6)"
else echo "FAIL gateway model list: $r $(head -c 80 /tmp/x6)"; fi
r=$(c -H 'Content-Type: application/json' -d '{"model":"llama3.2:1b","messages":[]}' https://$AI/gateway/v1/chat/completions)
[ "$r" = 401 ] && echo "PASS chat without a Keycloak token refused ($r)" || echo "FAIL chat without token: $r"
r=$(c -d '{}' https://$AI/gateway/v1/tools/kb-search); [ "$r" != 200 ] && echo "PASS tool path not published ($r)" || echo "FAIL tool path is reachable"
r=$(c -d client_id=ide-bridge -d code_challenge=E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM -d code_challenge_method=S256 https://$ID/realms/slatff/protocol/openid-connect/auth/device)
[ "$r" = 200 ] && echo "PASS Keycloak offers device sign-in for ide-bridge ($r)" || echo "FAIL device sign-in: $r $(head -c 160 /tmp/x6)"
s "4. your turn"
cat <<TXT
a) Sign in (browser opens, confirm the code, sign in as alice or carol):
     bash scripts/ide-bridge.sh login
b) Start the bridge for an IDE and keep the window open (it prints the exact settings):
     IDE=xcode bash scripts/ide-bridge.sh serve
c) Xcode > Settings > Intelligence > Add a Chat Provider > Internet Hosted:
     URL http://127.0.0.1:11435, API Key as printed by serve, API Key Header x-api-key.
d) Ask something in the coding assistant, then:
     docker compose exec -T model-gateway sh -c 'tail -3 /audit/audit.jsonl'
   should show your user, client "ide-bridge" and ide "xcode".
Visual Studio and Qt Creator: on a Windows or Linux computer copy ide-bridge/bridge.py and follow
docs/IDE-BRIDGE.md (configure, login, serve with --ide visualstudio or qtcreator).
TXT
s "done"; echo "Step 6 checks finished. Output saved in logs/mac-step6.log."
