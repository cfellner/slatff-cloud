#!/usr/bin/env bash
# Step 10: an agent acts for a signed-in user (docs/AGENTS.md).
# Turns on Keycloak's delegation preview features (database backup first), creates the agent's
# key in the Keychain, sets up the clients and the permission, updates the model gateway, then
# runs the demo with the kill switch: you sign in once and approve the agent.
# Writes logs/mac-step10.log. No token, key or secret is printed.
cd "$(dirname "$0")/.."
mkdir -p logs backups
exec > >(tee logs/mac-step10.log) 2>&1
export PATH="/usr/local/bin:/opt/homebrew/bin:/Applications/Docker.app/Contents/Resources/bin:$PATH"
s() { echo; echo "=== $* ==="; }
val() { grep "^$1=" .env | cut -d= -f2-; }
setenv() { if grep -q "^$1=" .env; then sed -i '' "s|^$1=.*|$1=$2|" .env; else echo "$1=$2" >> .env; fi; }
NET=slatff_default
cu() { docker run --rm --network "$NET" --entrypoint sh curlimages/curl:latest -c "$1"; }
MODE=${1:-kill-switch}

s date; date

s "1. secret for the rogue agent in .env"
if [ -z "$(val ROGUE_AGENT_SECRET)" ]; then setenv ROGUE_AGENT_SECRET "$(openssl rand -hex 24)"; echo "generated ROGUE_AGENT_SECRET (not shown)"; else echo "ROGUE_AGENT_SECRET already set"; fi

s "2. database backup"
F="backups/keycloak-$(date +%Y%m%d-%H%M%S).sql"
docker compose exec -T postgres pg_dump -U keycloak keycloak > "$F" && echo "saved $F ($(wc -c < "$F") bytes)" \
  || { echo "STOP: backup failed"; exit 1; }

s "3. Keycloak features token-exchange-delegation, parameterized-scopes (preview)"
FEAT=$(val KC_FEATURES)
for f in token-exchange-delegation parameterized-scopes; do
  case ",$FEAT," in *,$f,*) ;; *) FEAT="${FEAT:+$FEAT,}$f";; esac
done
if [ "$FEAT" != "$(val KC_FEATURES)" ]; then
  setenv KC_FEATURES "$FEAT"
  docker compose up -d keycloak
fi
echo "KEYCLOAK_VERSION=$(val KEYCLOAK_VERSION)  KC_FEATURES=$(val KC_FEATURES)"
for i in $(seq 1 60); do cu 'curl -sf -m 3 http://keycloak:8080/realms/slatff/.well-known/openid-configuration' >/dev/null 2>&1 && break; sleep 3; done
cu 'curl -sf -m 3 http://keycloak:8080/realms/slatff/.well-known/openid-configuration' >/dev/null && echo "Keycloak is up" || { echo "STOP: Keycloak did not come up; docker compose logs keycloak"; exit 1; }
docker compose logs keycloak 2>/dev/null | grep -E "Preview features enabled|token-exchange-delegation" | tail -2

s "4. the agent's key (created once in your Keychain; only the public key goes to Keycloak)"
JWKS=$(python3 agents/agent.py jwks) || { echo "STOP: could not create the key"; exit 1; }
echo "public key id: $(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["keys"][0]["kid"])' "$JWKS")"

s "5. Keycloak: agent-console, research-agent, rogue-agent, delegate permission"
AGENT_JWKS="$JWKS" bash scripts/kc-apply-agents.sh || { echo "STOP: Keycloak setup failed"; exit 1; }

s "6. model gateway with agent policy"
docker compose up -d --build model-gateway
for i in $(seq 1 20); do cu 'curl -sf -m 3 http://model-gateway:8080/healthz' >/dev/null 2>&1 && break; sleep 2; done
cu 'curl -s -m 3 http://model-gateway:8080/healthz'; echo

s "7. demo: sign in as alice or carol, answer Yes to \"Allow research-agent to act on your behalf?\""
ISSUER="https://$(val ID_HOST)/realms/slatff" GATEWAY="https://$(val AI_HOST)/gateway/v1" \
ROGUE_SECRET="$(val ROGUE_AGENT_SECRET)" SWITCH_CMD="bash scripts/kc-apply-agents.sh" \
  python3 agents/agent.py "$MODE"; R=$?
bash scripts/kc-apply-agents.sh permission-on >/dev/null 2>&1   # always leave the permission on
bash scripts/kc-apply-agents.sh rogue-off >/dev/null 2>&1       # test client off outside test runs

s "8. evidence: gateway audit lines with an agent"
docker compose exec -T model-gateway sh -c 'grep "\"act\"" /audit/audit.jsonl | tail -3' 2>/dev/null
echo
echo "Again: bash scripts/mac-step10-agents.sh demo | kill-switch | demo-denied (sign in as bob)"
exit $R
