#!/usr/bin/env bash
# Pulls the small test model. Uses the native Ollama on this machine if there is one,
# otherwise the optional Ollama container.
set -euo pipefail
cd "$(dirname "$0")/.."
# Docker Desktop and Homebrew paths, in case the shell does not have them.
export PATH="/usr/local/bin:/opt/homebrew/bin:/Applications/Docker.app/Contents/Resources/bin:$PATH"
set -a; . ./.env; set +a
model="${SLATFF_MODEL:-llama3.2:1b}"
if command -v ollama >/dev/null 2>&1; then
  ollama pull "$model"
else
  docker compose --profile ollama-container exec ollama ollama pull "$model"
fi
