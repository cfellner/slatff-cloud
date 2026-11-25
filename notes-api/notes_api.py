"""SLATFF.Cloud demo app B: a notes API in its own trust domain (Keycloak realm "apps").

Accepts only access tokens issued by the "apps" realm with audience "notes-api" and scope
"notes.read". It never sees a token from the company realm "slatff": an app A gets in only
through an ID-JAG that "slatff" issued and "apps" exchanged (docs/APP-TO-APP.md).
"""
import asyncio
import json
import logging
import os
import time

import jwt
from aiohttp import web
from jwt import PyJWKClient

ISSUER = os.environ["OIDC_ISSUER"].rstrip("/")
JWKS_URL = os.environ.get("JWKS_URL") or f"{ISSUER}/protocol/openid-connect/certs"
AUDIENCE = os.environ.get("API_AUDIENCE", "notes-api")
SCOPE = os.environ.get("API_SCOPE", "notes.read")
AUDIT_FILE = os.environ.get("AUDIT_FILE", "/audit/notes-api.jsonl")
NOTES = {
    "alice": ["Team offsite: book the room by Friday", "Expenses due on the 3rd"],
    "carol": ["Board pack review on Tuesday", "Renew the TLS certificates in March"],
}

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("notes-api")
jwks = PyJWKClient(JWKS_URL, cache_keys=True, lifespan=300)


def audit(record):
    record["ts"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    line = json.dumps(record, ensure_ascii=False)
    log.info("AUDIT %s", line)
    try:
        os.makedirs(os.path.dirname(AUDIT_FILE), exist_ok=True)
        with open(AUDIT_FILE, "a") as f:
            f.write(line + "\n")
    except Exception as e:
        log.error("audit write failed: %s", e)


async def notes(request):
    record = {"app": "notes-api"}
    auth = request.headers.get("Authorization", "")
    token = auth[7:] if auth.startswith("Bearer ") else ""
    try:
        key = await asyncio.to_thread(jwks.get_signing_key_from_jwt, token)
        c = jwt.decode(token, key.key, algorithms=["RS256", "PS256", "ES256"], audience=AUDIENCE,
                       issuer=ISSUER, leeway=30, options={"require": ["exp", "iat", "iss", "sub"]})
    except Exception as e:
        record.update(decision="deny", reason=f"token rejected ({type(e).__name__})")
        audit(record)
        return web.json_response({"error": f"notes-api: a token from {ISSUER} for {AUDIENCE} is required"},
                                 status=401)
    scopes = set((c.get("scope") or "").split())
    user = c.get("preferred_username")
    record.update(user=user, sub=c.get("sub"), azp=c.get("azp"), jti=c.get("jti"), scope=sorted(scopes))
    if SCOPE not in scopes:
        record.update(decision="deny", reason=f"scope {SCOPE} missing")
        audit(record)
        return web.json_response({"error": f"notes-api: scope {SCOPE} required"}, status=403)
    record.update(decision="allow")
    audit(record)
    return web.json_response({"user": user, "notes": NOTES.get(user, [])})


async def health(request):
    return web.json_response({"ok": True, "issuer": ISSUER, "audience": AUDIENCE, "scope": SCOPE})


def main():
    app = web.Application()
    app.router.add_get("/healthz", health)
    app.router.add_get("/notes", notes)
    web.run_app(app, host="0.0.0.0", port=int(os.environ.get("PORT", "8080")), access_log=None)


if __name__ == "__main__":
    main()
