#!/usr/bin/env bash
# Runs the app-to-app demo client (app-to-app/agent.py) inside the Docker network.
# Usage: bash scripts/app-to-app-demo.sh demo          sign in as alice or carol (role ai-user)
#        bash scripts/app-to-app-demo.sh demo-denied   sign in as bob (no role): IdP must refuse
cd "$(dirname "$0")/.."
export PATH="/usr/local/bin:/opt/homebrew/bin:/Applications/Docker.app/Contents/Resources/bin:$PATH"
val() { grep "^$1=" .env | cut -d= -f2-; }
docker run --rm --network slatff_default -v "$PWD/app-to-app":/a:ro \
  -e IDP_URL=http://keycloak:8080/realms/slatff -e APPS_URL=http://keycloak:8080/realms/apps \
  -e APPS_ISSUER="https://$(val ID_HOST)/realms/apps" -e RESOURCE="https://$(val AI_HOST)/notes" \
  -e NOTES_URL=http://notes-api:8080/notes \
  -e AGENT_SECRET="$(val NOTES_AGENT_SECRET)" -e APPS_AGENT_SECRET="$(val APPS_AGENT_SECRET)" \
  -e OTHER_SECRET="$(val OTHER_APP_SECRET)" \
  python:3.12-alpine python -u /a/agent.py "${1:-demo}"
