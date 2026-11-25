#!/usr/bin/env bash
# Step 1 on a Mac: checks prerequisites, pulls images and the test model.
# Starts nothing permanent. Writes logs/mac-step1.log.
cd "$(dirname "$0")/.."
mkdir -p logs
exec > >(tee logs/mac-step1.log) 2>&1
export PATH="/usr/local/bin:/opt/homebrew/bin:/Applications/Docker.app/Contents/Resources/bin:$PATH"
s() { echo; echo "=== $* ==="; }

s date; date; sw_vers 2>/dev/null; uname -m
s "LAN address (en0)"; ipconfig getifaddr en0 || echo "no en0 address"
s "iCloud Desktop & Documents sync"
if [ -d "$HOME/Library/Mobile Documents/com~apple~CloudDocs/Documents" ]; then echo "LIKELY ON (Documents folder exists in iCloud Drive)"; else echo "looks off"; fi
s "disk"; df -h "$HOME" | tail -1
s "docker"
echo "docker binaries:"; which -a docker
ls -d /Applications/Docker.app 2>/dev/null || echo "Docker.app NOT in /Applications"
echo "contexts:"; docker context ls 2>&1
echo "cli plugins:"; ls ~/.docker/cli-plugins 2>&1
if ! docker info >/dev/null 2>&1 || ! docker compose version >/dev/null 2>&1; then
  docker compose version 2>&1
  echo "STOP: Docker engine or Compose not available. Open Docker Desktop, finish its first-run setup, wait for 'Engine running', then run this again."
  exit 1
fi
docker version --format 'client {{.Client.Version}} / server {{.Server.Version}}'; docker compose version
s "ollama"; ollama --version || echo "OLLAMA CLI NOT FOUND: open the Ollama app once"
s "who listens on 11434 (should be 127.0.0.1 only)"; lsof -nP -iTCP:11434 -sTCP:LISTEN || echo "nothing listening: open the Ollama app"
s "anything already on 443"; lsof -nP -iTCP:443 -sTCP:LISTEN || echo "443 free"
s "compose config (placeholder token, check only)"
CLOUDFLARE_API_TOKEN=placeholder docker compose config -q && echo "compose config OK"
CLOUDFLARE_API_TOKEN=placeholder docker compose --profile meet config -q && echo "compose config with meet OK"
s "pull images"; CLOUDFLARE_API_TOKEN=placeholder docker compose --profile meet pull --ignore-buildable
s "build caddy"; CLOUDFLARE_API_TOKEN=placeholder docker compose build caddy
s "pull model"; model=$(grep '^SLATFF_MODEL=' .env | cut -d= -f2); ollama pull "$model" 2>&1 | tail -1
s "model test"; ollama run "$model" "Reply with the single word OK." 2>&1 | tail -3
s "container to native Ollama via host.docker.internal"
docker run --rm curlimages/curl:latest -s -m 5 http://host.docker.internal:11434/api/version || echo "NOT REACHABLE from containers"
s "done"; echo "Step 1 finished. Output saved in logs/mac-step1.log."
