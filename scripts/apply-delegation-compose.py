#!/usr/bin/env python3
"""One-off: add the delegation pieces to docker-compose.yml, .env.example, CI and TESTING.md.
Safe to re-run (skips what is already there). Run from the repo root:
  python3 scripts/apply-delegation-compose.py"""
import re, sys
from pathlib import Path

def edit(path, fn):
    p = Path(path); s = p.read_text(); n = fn(s)
    if n != s: p.write_text(n); print("updated", path)
    else: print("unchanged", path)

def compose(s):
    if "GATEWAY_CLIENT_SECRET" not in s:
        s = s.replace("      AUDIT_LOG_PROMPTS: ${GATEWAY_AUDIT_LOG_PROMPTS:-false}\n",
            "      AUDIT_LOG_PROMPTS: ${GATEWAY_AUDIT_LOG_PROMPTS:-false}\n"
            "      # Delegation (docs/DELEGATION.md): the gateway's own Keycloak client secret, used\n"
            "      # only for token exchange. Empty = tool calls are refused (503).\n"
            "      GATEWAY_CLIENT_SECRET: ${GATEWAY_CLIENT_SECRET:-}\n", 1)
    if "\n  kb-tool:" not in s:
        block = (
            "\n  # Demo tool for delegation (docs/DELEGATION.md): searches the fictional knowledge base.\n"
            "  # Accepts only tokens exchanged for it (audience kb-tool, scope kb-search).\n"
            "  kb-tool:\n"
            "    build: ./kb-tool\n"
            "    restart: unless-stopped\n"
            "    environment:\n"
            "      OIDC_ISSUER: https://${ID_HOST}/realms/slatff\n"
            "    volumes:\n"
            "      - ./demo/knowledge:/docs:ro\n"
            "      - ./model-gateway/policy.json:/config/policy.json:ro\n"
            "      - kb-tool-audit:/audit\n"
            "    # No published port. Only the gateway (and other containers here) reach it.\n")
        marker = "    # No published port. Only containers on this network reach it.\n"
        assert marker in s, "gateway block marker not found"
        s = s.replace(marker, marker + block, 1)
    if "\n  kb-tool-audit:" not in s:
        s = s.replace("\n  gateway-audit:", "\n  gateway-audit:\n  kb-tool-audit:", 1)
    return s

def envex(s):
    if "GATEWAY_CLIENT_SECRET" in s: return s
    return s.replace("GATEWAY_AUDIT_LOG_PROMPTS=false\n",
        "GATEWAY_AUDIT_LOG_PROMPTS=false\n# Model gateway's Keycloak client secret for token exchange (docs/DELEGATION.md).\n"
        "# scripts/mac-step5-delegation.sh fills it in if empty.\nGATEWAY_CLIENT_SECRET=\n", 1)

def ci(s):
    return s.replace("Model gateway policy tests (fake Keycloak and fake model, 15 checks)",
                     "Model gateway and delegation tests (fake Keycloak, fake model, kb-tool, 28 checks)")

def testing(s):
    if "Delegation (docs/DELEGATION.md)" in s: return s
    return s.rstrip("\n") + """

Delegation (docs/DELEGATION.md, step 5):

- [x] Offline: `bash model-gateway/tests/run.sh` passes 28 checks (25 Nov 2026, fake Keycloak)
- [ ] `bash scripts/mac-step5-delegation.sh`: Keycloak accepts the token exchange
      (client model-gateway, standard token exchange on)
- [ ] Tool call through the gateway returns STAFF documents, BOARD-ONLY withheld for an ai-user
- [ ] Exchanged token: aud kb-tool only, scope kb-search, expires no later than the user token
- [ ] Exchanged token is refused by the model gateway; the user token is refused by kb-tool
- [ ] Exchange for an audience the gateway was not given is refused by Keycloak
- [ ] Gateway and kb-tool audit lines join on correlation_id and jti
- [ ] As carol (ai-admin) in a real session: BOARD-ONLY documents are returned
"""

edit("docker-compose.yml", compose)
edit(".env.example", envex)
edit(".github/workflows/check.yml", ci)
edit("docs/TESTING.md", testing)
