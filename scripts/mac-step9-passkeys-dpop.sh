#!/usr/bin/env bash
# Step 9: passkeys for people, DPoP-bound tokens for the IDE bridge (docs/PASSKEYS-DPOP.md).
# Writes logs/mac-step9.log. No token or secret is printed.
cd "$(dirname "$0")/.."
mkdir -p logs
exec > >(tee logs/mac-step9.log) 2>&1
export PATH="/usr/local/bin:/opt/homebrew/bin:/Applications/Docker.app/Contents/Resources/bin:$PATH"
s() { echo; echo "=== $* ==="; }
val() { grep "^$1=" .env | cut -d= -f2-; }
cu() { docker run --rm --network slatff_default --entrypoint sh curlimages/curl:latest -c "$1"; }
ID=$(val ID_HOST); AI=$(val AI_HOST)

s date; date

s "1. Keycloak: passkeys on, DPoP required for ide-bridge"
bash scripts/kc-apply-passkeys-dpop.sh || { echo "STOP: Keycloak setup failed"; exit 1; }

s "2. Keycloak offers DPoP"
cu "curl -s http://keycloak:8080/realms/slatff/.well-known/openid-configuration" | python3 -c '
import sys, json; c = json.load(sys.stdin); a = c.get("dpop_signing_alg_values_supported") or []
print(("PASS" if "RS256" in a else "FAIL"), "DPoP algorithms offered:", ", ".join(a))'

s "3. gateway with DPoP checks"
chmod a+r model-gateway/*.py
docker compose up -d --build model-gateway
for i in $(seq 1 20); do cu 'curl -sf -m 3 http://model-gateway:8080/healthz' >/dev/null 2>&1 && break; sleep 2; done
docker compose exec -T model-gateway sh -c 'echo "DPOP_HTU_BASE=$DPOP_HTU_BASE DPOP_REQUIRED_CLIENTS=$DPOP_REQUIRED_CLIENTS"'

s "4. IDE bridge: new version with DPoP"
if [ -f "$HOME/Library/LaunchAgents/cloud.slatff.ide-bridge.plist" ]; then
  bash scripts/ide-bridge.sh agent install
else
  echo "no bridge agent installed; start it with: IDE=xcode bash scripts/ide-bridge.sh serve"
fi

s "5. your turn"
cat <<TXT
a) Bridge: sign in again, so the new tokens are bound to the bridge's key:
     bash scripts/ide-bridge.sh logout
     bash scripts/ide-bridge.sh login private
   Then ask something in Xcode and check the audit line shows "dpop": true:
     docker compose exec -T model-gateway sh -c 'tail -1 /audit/audit.jsonl'
b) Passkey for alice (normal Safari window, not private):
     https://$ID/realms/slatff/account  >  sign in as alice  >  Account security  >  Signing in
     >  Passkey: Set up  >  confirm with Touch ID
   Then sign out and sign in again: choose "Sign in with passkey".
c) Device sign-in with the passkey: bash scripts/ide-bridge.sh login (sign in as alice with the passkey).
TXT

s done
echo "Step 9 checks finished. Output saved in logs/mac-step9.log."
