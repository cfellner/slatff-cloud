#!/usr/bin/env python3
"""One-off: publish two gateway paths on the AI host for the Xcode bridge, nothing else:
   https://<AI_HOST>/gateway/v1/models and /gateway/v1/chat/completions -> model-gateway:8080
Every request still needs a valid Keycloak token at the gateway. Safe to re-run.
Run from the repo root: python3 scripts/apply-gateway-caddy.py"""
from pathlib import Path
p = Path("caddy/Caddyfile"); s = p.read_text()
if "@gateway" in s:
    print("unchanged caddy/Caddyfile"); raise SystemExit
lines = s.splitlines(keepends=True)
for i, l in enumerate(lines):
    if "reverse_proxy open-webui" in l:
        ind = l[:len(l) - len(l.lstrip())]
        block = (f"{ind}# Model gateway for the IDE bridge (docs/IDE-BRIDGE.md): two paths only.\n"
                 f"{ind}@gateway path /gateway/v1/models /gateway/v1/chat/completions\n"
                 f"{ind}handle @gateway {{\n{ind}\turi strip_prefix /gateway\n"
                 f"{ind}\treverse_proxy model-gateway:8080\n{ind}}}\n")
        lines.insert(i, block)
        p.write_text("".join(lines)); print("updated caddy/Caddyfile"); break
else:
    raise SystemExit("STOP: no 'reverse_proxy open-webui' line found in caddy/Caddyfile")
