"""Offline stand-in for two Keycloak realms on :9101, for testing app-to-app/agent.py and
notes-api without Keycloak.

/realms/slatff  the IdP: device sign-in, and ID-JAG issuing with the same rules as the
                Java extension (keycloak/extensions/id-jag-issuer)
/realms/apps    app B's authorization server: JWT bearer grant with the checks Keycloak's
                ID-JAG receiver makes, including taking scope from the request (known gap)

This tests the client and the API. The Java extension itself is tested live (step 8).
"""
import json
import time
import uuid

import jwt
from aiohttp import web
from cryptography.hazmat.primitives.asymmetric import rsa
from jwt.algorithms import RSAAlgorithm

BASE = "http://127.0.0.1:9101/realms"
IDP, APPS = f"{BASE}/slatff", f"{BASE}/apps"
RESOURCE = "https://ai.example.org/notes"
keys = {r: rsa.generate_private_key(public_exponent=65537, key_size=2048) for r in ("slatff", "apps")}
USERS = {"alice": {"id": "u-alice", "roles": ["ai-user"]}, "bob": {"id": "u-bob", "roles": []}}
STATE = {"user": "alice", "polls": 0, "used_jti": set(), "sessions": set()}
POLICY = {"audiences": {APPS}, "scopes": {"notes.read"}, "resources": {RESOURCE}, "role": "ai-user"}
APP_CLIENTS = {"notes-agent": "apps-secret", "other-app": "other-secret"}


def sign(realm, claims, typ="JWT"):
    return jwt.encode(claims, keys[realm], algorithm="RS256", headers={"kid": realm, "typ": typ})


def error(code, err, desc=""):
    return web.json_response({"error": err, "error_description": desc}, status=code)


async def certs(r):
    realm = r.match_info["realm"]
    jwk = json.loads(RSAAlgorithm.to_jwk(keys[realm].public_key()))
    jwk.update(kid=realm, use="sig", alg="RS256")
    return web.json_response({"keys": [jwk]})


async def device(r):
    f = await r.post()
    if f.get("client_id") != "notes-agent" or f.get("client_secret") != "agent-secret":
        return error(401, "invalid_client")
    STATE["polls"] = 0
    return web.json_response({"device_code": "dc", "user_code": "ABCD", "verification_uri": f"{IDP}/device",
                              "expires_in": 60, "interval": 1})


def idp_tokens():
    u = STATE["user"]
    now, sid = int(time.time()), str(uuid.uuid4())
    STATE["sessions"].add(sid)
    base = {"iss": IDP, "sub": USERS[u]["id"], "iat": now, "exp": now + 300, "sid": sid,
            "preferred_username": u, "auth_time": now}
    idt = sign("slatff", {**base, "aud": "notes-agent", "typ": "ID", "azp": "notes-agent"})
    at = sign("slatff", {**base, "aud": "account", "typ": "Bearer", "azp": "notes-agent", "scope": "openid"})
    return web.json_response({"access_token": at, "id_token": idt, "token_type": "Bearer", "expires_in": 300})


def issue_id_jag(f):
    if f.get("client_id") != "notes-agent" or f.get("client_secret") != "agent-secret":
        return error(401, "invalid_client")
    if f.get("subject_token_type") != "urn:ietf:params:oauth:token-type:id_token":
        return error(400, "invalid_request", "subject_token_type must be id_token")
    try:
        c = jwt.decode(f.get("subject_token", ""), keys["slatff"].public_key(), algorithms=["RS256"],
                       options={"verify_aud": False}, issuer=IDP)
    except Exception:
        return error(400, "invalid_request", "subject_token invalid")
    if c.get("typ") != "ID":
        return error(400, "invalid_request", "subject_token is not an ID token")
    aud = c.get("aud")
    if "notes-agent" not in (aud if isinstance(aud, list) else [aud]):
        return error(400, "invalid_request", "audience mismatch")
    user = next(n for n, u in USERS.items() if u["id"] == c["sub"])
    auds = f.getall("audience", [])
    if len(auds) != 1:
        return error(400, "invalid_request", "exactly one audience")
    if auds[0] not in POLICY["audiences"]:
        return error(400, "invalid_target", "untrusted audience")
    if POLICY["role"] not in USERS[user]["roles"]:
        return error(403, "access_denied", "role missing")
    res = [x for x in f.getall("resource", []) if x in POLICY["resources"]]
    if f.getall("resource", []) and not res:
        return error(400, "invalid_target", "resource not allowed")
    scope = " ".join(s for s in f.get("scope", "").split() if s in POLICY["scopes"])
    now = int(time.time())
    claims = {"iss": IDP, "sub": c["sub"], "aud": auds[0], "client_id": "notes-agent", "jti": str(uuid.uuid4()),
              "iat": now, "exp": now + 300, "preferred_username": user}
    if scope:
        claims["scope"] = scope
    if res:
        claims["resource"] = res[0] if len(res) == 1 else res
    return web.json_response({"access_token": sign("slatff", claims, typ="oauth-id-jag+jwt"),
                              "issued_token_type": "urn:ietf:params:oauth:token-type:id-jag",
                              "token_type": "N_A", "expires_in": 300, "scope": scope})


def redeem(f):
    client = f.get("client_id")
    if APP_CLIENTS.get(client) != f.get("client_secret"):
        return error(401, "invalid_client")
    a = f.get("assertion", "")
    try:
        if jwt.get_unverified_header(a).get("typ") != "oauth-id-jag+jwt":
            return error(400, "invalid_grant", "typ")
        c = jwt.decode(a, keys["slatff"].public_key(), algorithms=["RS256"], audience=APPS, issuer=IDP)
    except Exception as e:
        return error(400, "invalid_grant", type(e).__name__)
    if c.get("client_id") != client:
        return error(400, "invalid_grant", "client_id mismatch")
    if c["jti"] in STATE["used_jti"]:
        return error(400, "invalid_grant", "assertion reused")
    STATE["used_jti"].add(c["jti"])
    now = int(time.time())
    at = {"iss": APPS, "sub": "apps-" + c["sub"], "aud": "notes-api", "azp": client, "iat": now, "exp": now + 300,
          "jti": str(uuid.uuid4()), "preferred_username": c["preferred_username"], "scope": f.get("scope", "")}
    return web.json_response({"access_token": sign("apps", at), "token_type": "Bearer", "expires_in": 300,
                              "scope": at["scope"]})


async def token(r):
    realm, f = r.match_info["realm"], await r.post()
    g = f.get("grant_type")
    if realm == "slatff" and g == "urn:ietf:params:oauth:grant-type:device_code":
        STATE["polls"] += 1
        return error(400, "authorization_pending") if STATE["polls"] < 2 else idp_tokens()
    if realm == "slatff" and g == "urn:ietf:params:oauth:grant-type:token-exchange":
        return issue_id_jag(f)
    if realm == "apps" and g == "urn:ietf:params:oauth:grant-type:jwt-bearer":
        return redeem(f)
    return error(400, "unsupported_grant_type")


async def set_user(r):
    STATE["user"] = r.query["u"]
    return web.json_response({"user": STATE["user"]})


app = web.Application()
app.router.add_get("/realms/{realm}/protocol/openid-connect/certs", certs)
app.router.add_post("/realms/slatff/protocol/openid-connect/auth/device", device)
app.router.add_post("/realms/{realm}/protocol/openid-connect/token", token)
app.router.add_get("/test/user", set_user)
web.run_app(app, host="127.0.0.1", port=9101, access_log=None)
