# Fake Keycloak realm on :9201 with the 26.8 delegation behaviour the agent relies on, and a fake
# model on :9202. Rules copied from TokenExchangeDelegationProvider (Keycloak 26.8.2):
# may_act only with consent + delegate permission; exchange with actor_token checks may_act.sub
# and client_id; without actor_token a subject token with may_act is refused; the new token has
# sub = user, act = may_act, the actor client's audience, no refresh token.
import asyncio, base64, hashlib, json, time, uuid, urllib.parse
from aiohttp import web
from cryptography.hazmat.primitives.asymmetric import rsa
import jwt
from jwt.algorithms import RSAAlgorithm

ISS = "http://127.0.0.1:9201/realms/slatff"
TOKEN_URL = ISS + "/protocol/openid-connect/token"
key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
pub = key.public_key()
jwk = json.loads(RSAAlgorithm.to_jwk(pub)); jwk.update(kid="k1", use="sig", alg="RS256")
USERS = {"alice": ["ai-user"], "bob": []}
S = {"user": "alice", "permission": True, "sessions": set(), "codes": {}, "refresh": {}, "agent_jwks": None, "seen": set()}
AGENT_SA = "sa-research-agent"

def sign(c): return jwt.encode(c, key, algorithm="RS256", headers={"kid": "k1"})
def now(): return int(time.time())
def bad(status, e, d=""): return web.json_response({"error": e, "error_description": d}, status=status)

def user_token(user, sid, delegate):
    c = {"iss": ISS, "sub": "id-" + user, "aud": ["account"], "azp": "agent-console", "iat": now(), "exp": now() + 300,
         "jti": str(uuid.uuid4()), "sid": sid, "preferred_username": user, "scope": "openid profile",
         "realm_access": {"roles": USERS[user]}}
    if delegate and S["permission"]:
        c["may_act"] = {"sub": AGENT_SA, "client_id": "research-agent"}
        c["aud"].append("research-agent"); c["scope"] += " delegation:client:research-agent"
    return c

async def discovery(r):
    return web.json_response({"issuer": ISS, "authorization_endpoint": ISS + "/protocol/openid-connect/auth",
                              "token_endpoint": TOKEN_URL, "jwks_uri": ISS + "/protocol/openid-connect/certs"})
async def certs(r): return web.json_response({"keys": [jwk]})

async def auth(r):
    q = r.query
    assert q["client_id"] == "agent-console" and q["code_challenge_method"] == "S256" and q.get("prompt") == "login"
    code = str(uuid.uuid4())
    S["codes"][code] = (q["code_challenge"], q["redirect_uri"], "delegation:client:research-agent" in q["scope"].split())
    raise web.HTTPFound(q["redirect_uri"] + "?" + urllib.parse.urlencode({"code": code, "state": q["state"]}))

def client_auth(f):
    """client_secret for rogue-agent, private_key_jwt for research-agent (registered public key)."""
    cid = f.get("client_id")
    if cid == "rogue-agent":
        return cid if f.get("client_secret") == "rogue-secret" else None
    if cid == "research-agent" and f.get("client_assertion_type") == "urn:ietf:params:oauth:client-assertion-type:jwt-bearer":
        try:
            k = jwt.PyJWK(S["agent_jwks"]["keys"][0], algorithm="RS256").key
            c = jwt.decode(f["client_assertion"], k, algorithms=["RS256"], audience=ISS)
            assert c["iss"] == c["sub"] == cid and c["exp"] - c["iat"] <= 60 and c["jti"] not in S["seen"]
            S["seen"].add(c["jti"]); return cid
        except Exception:
            return None
    return None

def verify(tok):
    c = jwt.decode(tok, pub, algorithms=["RS256"], options={"verify_aud": False}, issuer=ISS)
    if c.get("sid") and c["sid"] not in S["sessions"]:
        raise ValueError("session ended")
    return c

async def token(r):
    f = await r.post(); g = f.get("grant_type")
    if g == "authorization_code":
        ch, redir, deleg = S["codes"].pop(f.get("code"), (None, None, None))
        if not ch or f.get("redirect_uri") != redir or \
           base64.urlsafe_b64encode(hashlib.sha256(f["code_verifier"].encode()).digest()).rstrip(b"=").decode() != ch:
            return bad(400, "invalid_grant")
        sid = str(uuid.uuid4()); S["sessions"].add(sid); rt = str(uuid.uuid4()); S["refresh"][rt] = (S["user"], sid, deleg)
        return web.json_response({"access_token": sign(user_token(S["user"], sid, deleg)), "refresh_token": rt, "token_type": "Bearer"})
    if g == "refresh_token":
        u = S["refresh"].get(f.get("refresh_token"))
        if not u or u[1] not in S["sessions"]:
            return bad(400, "invalid_grant")
        return web.json_response({"access_token": sign(user_token(*u)), "refresh_token": f["refresh_token"]})
    cid = client_auth(f)
    if not cid:
        return bad(401, "invalid_client")
    if g == "client_credentials":
        sa = AGENT_SA if cid == "research-agent" else "sa-" + cid
        return web.json_response({"access_token": sign({"iss": ISS, "sub": sa, "azp": cid, "aud": "model-gateway",
            "iat": now(), "exp": now() + 120, "jti": str(uuid.uuid4()), "preferred_username": "service-account-" + cid,
            "realm_access": {"roles": []}}), "token_type": "Bearer"})
    if g != "urn:ietf:params:oauth:grant-type:token-exchange":
        return bad(400, "unsupported_grant_type")
    try:
        s = verify(f.get("subject_token", ""))
    except Exception as e:
        return bad(400, "invalid_token", str(e))
    aud = s["aud"] if isinstance(s["aud"], list) else [s["aud"]]
    if cid not in aud:
        return bad(403, "access_denied", "client is not within the token audience")
    if not f.get("actor_token"):
        return bad(400, "invalid_request", "subject token with may_act needs actor_token")
    try:
        a = verify(f["actor_token"])
    except Exception:
        return bad(400, "invalid_request", "Invalid actor token")
    may = s.get("may_act")
    if not isinstance(may, dict) or may.get("sub") != a["sub"]:
        return bad(400, "invalid_request", "Invalid may_act claim in the subject_token")
    if may.get("client_id") not in (None, cid) or a.get("azp") != cid:
        return bad(400, "invalid_request", "client_id does not match may_act")
    roles = [x for x in s["realm_access"]["roles"] if x == "ai-user"]       # actor client scope: ai-user only
    t = {"iss": ISS, "sub": s["sub"], "aud": "model-gateway", "azp": cid, "iat": now(), "exp": now() + 120,
         "jti": str(uuid.uuid4()), "preferred_username": s["preferred_username"], "act": dict(may),
         "realm_access": {"roles": roles}, "scope": "profile"}
    return web.json_response({"access_token": sign(t), "token_type": "Bearer", "issued_token_type": "urn:ietf:params:oauth:token-type:access_token"})

async def register(r): S["agent_jwks"] = await r.json(); return web.json_response({"ok": True})
async def switch(r):
    a = r.query["action"]
    if a == "permission-off": S["permission"] = False
    elif a == "permission-on": S["permission"] = True
    elif a == "session-off": S["sessions"].clear()
    elif a == "user": S["user"] = r.query["u"]
    return web.json_response({"ok": True, "action": a})

async def models(r): return web.json_response({"object": "list", "data": [{"id": "llama3.2:1b"}, {"id": "llama3.2:3b"}]})
async def chat(r): return web.json_response({"choices": [{"message": {"content": "I am working for the signed-in user."}}]})

async def main():
    a = web.Application()
    a.router.add_get("/realms/slatff/.well-known/openid-configuration", discovery)
    a.router.add_get("/realms/slatff/protocol/openid-connect/certs", certs)
    a.router.add_get("/realms/slatff/protocol/openid-connect/auth", auth)
    a.router.add_post("/realms/slatff/protocol/openid-connect/token", token)
    a.router.add_post("/test/jwks", register); a.router.add_get("/test/switch", switch)
    b = web.Application(); b.router.add_get("/v1/models", models); b.router.add_post("/v1/chat/completions", chat)
    for app, port in ((a, 9201), (b, 9202)):
        rn = web.AppRunner(app); await rn.setup(); await web.TCPSite(rn, "127.0.0.1", port).start()
    await asyncio.Event().wait()
asyncio.run(main())
