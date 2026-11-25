#!/usr/bin/env bash
# Generates .env with your host names and random secrets.
# Usage: ./scripts/bootstrap.sh <your-domain>      e.g. ./scripts/bootstrap.sh example.org
# Safe to re-run: it refuses to overwrite an existing .env.
set -euo pipefail
cd "$(dirname "$0")/.."

domain="${1:?usage: ./scripts/bootstrap.sh <your-domain>}"
if ! [[ "$domain" =~ ^[A-Za-z0-9.-]+$ ]]; then
  echo "That does not look like a domain name: $domain" >&2
  exit 1
fi
if [ -f .env ]; then
  echo ".env already exists. Delete it first if you want new secrets." >&2
  exit 1
fi

rand() { openssl rand -base64 33 | tr -d '/+=\n' | cut -c1-32; }

cp .env.example .env
sed -i.bak \
  -e "s|example\.org|$domain|g" \
  -e "s|^KC_BOOTSTRAP_ADMIN_PASSWORD=.*|KC_BOOTSTRAP_ADMIN_PASSWORD=$(rand)|" \
  -e "s|^POSTGRES_PASSWORD=.*|POSTGRES_PASSWORD=$(rand)|" \
  -e "s|^OPEN_WEBUI_CLIENT_SECRET=.*|OPEN_WEBUI_CLIENT_SECRET=$(rand)|" \
  -e "s|^WEBUI_SECRET_KEY=.*|WEBUI_SECRET_KEY=$(rand)|" \
  -e "s|^JITSI_CLIENT_SECRET=.*|JITSI_CLIENT_SECRET=$(rand)|" \
  -e "s|^JITSI_JWT_SECRET=.*|JITSI_JWT_SECRET=$(rand)|" \
  -e "s|^JICOFO_AUTH_PASSWORD=.*|JICOFO_AUTH_PASSWORD=$(rand)|" \
  -e "s|^JVB_AUTH_PASSWORD=.*|JVB_AUTH_PASSWORD=$(rand)|" \
  -e "s|^NEXTCLOUD_CLIENT_SECRET=.*|NEXTCLOUD_CLIENT_SECRET=$(rand)|" \
  -e "s|^NEXTCLOUD_DB_PASSWORD=.*|NEXTCLOUD_DB_PASSWORD=$(rand)|" \
  -e "s|^NEXTCLOUD_ADMIN_PASSWORD=.*|NEXTCLOUD_ADMIN_PASSWORD=$(rand)|" \
  .env
rm -f .env.bak
chmod 600 .env
echo "Wrote .env for id.$domain, ai.$domain, meet.$domain and files.$domain, with generated secrets."
echo "Next: add your CLOUDFLARE_API_TOKEN to .env (docs/NETWORK.md), then: docker compose up -d --build"
