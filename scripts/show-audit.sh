#!/usr/bin/env bash
# Shows the model gateway's last decisions in a readable table.
# Usage: bash scripts/show-audit.sh [number of lines, default 15]
cd "$(dirname "$0")/.."
export PATH="/usr/local/bin:/opt/homebrew/bin:/Applications/Docker.app/Contents/Resources/bin:$PATH"
docker compose exec -T model-gateway sh -c "tail -${1:-15} /audit/audit.jsonl" | python3 scripts/show-audit.py
