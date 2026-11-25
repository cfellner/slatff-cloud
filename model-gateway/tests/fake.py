# Fake Keycloak on :9001 (JWKS + RFC 8693 token exchange) and fake OpenAI-compatible model on :9002
import json, asyncio, time, uuid
from aiohttp import web
from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.hazmat.primitives import serialization
import jwt
from jwt.algorithms import RSAAlgorithm
ISS = "http://127.0.0.1:9001/realms/slatff"
key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
open("key.pem","wb").write(key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, serialization.NoEncryption()))
jwk = json.loads(RSAAlgorithm.to_jwk(key.public_key())); jwk.update(kid="k1", use="sig", alg="RS256")
pub = key.public_key()
# What the realm allows: requester client -> optional scope -> audience it adds
CLIENTS = {"model-gateway": {"secret": "test-secret", "scopes": {"kb-search": "kb-tool"}}}
async def certs(r): return web.json_response({"keys":[jwk]})
# Device flow (RFC 8628) and refresh for the IDE bridge tests: client ide-bridge, user alice
DEV = {"polls": 0, "revoked": False}
def user_token(lifetime=60):
    now = int(time.time())
    return jwt.encode({"iss":ISS,"sub":"id-alice","aud":"model-gateway","azp":"ide-bridge","iat":now,
        "exp":now+lifetime,"jti":str(uuid.uuid4()),"preferred_username":"alice","roles":["ai-user"]},
        key, algorithm="RS256", headers={"kid":"k1"})
async def device(r):
    f = await r.post()
    if f.get("client_id") != "ide-bridge":
        return web.json_response({"error":"invalid_client"}, status=401)
    return web.json_response({"device_code":"dc-1","user_code":"ABCD-EFGH","verification_uri":"http://127.0.0.1:9001/device",
        "verification_uri_complete":"http://127.0.0.1:9001/device?user_code=ABCD-EFGH","expires_in":60,"interval":1})
async def revoke(r):
    DEV["revoked"] = True; return web.json_response({"ok": True})
async def token(r):
    f = await r.post()
    if f.get("grant_type") == "urn:ietf:params:oauth:grant-type:device_code":
        DEV["polls"] += 1
        if DEV["polls"] < 2:
            return web.json_response({"error":"authorization_pending"}, status=400)
        return web.json_response({"access_token":user_token(40),"refresh_token":"rt-alice","token_type":"Bearer","expires_in":40})
    if f.get("grant_type") == "refresh_token":
        if DEV["revoked"] or f.get("refresh_token") != "rt-alice":
            return web.json_response({"error":"invalid_grant"}, status=400)
        return web.json_response({"access_token":user_token(40),"refresh_token":"rt-alice","token_type":"Bearer","expires_in":40})
    if f.get("grant_type") != "urn:ietf:params:oauth:grant-type:token-exchange":
        return web.json_response({"error":"unsupported_grant_type"}, status=400)
    c = CLIENTS.get(f.get("client_id"))
    if not c or f.get("client_secret") != c["secret"]:
        return web.json_response({"error":"unauthorized_client"}, status=401)
    try:   # like Keycloak: subject token must be valid and include the requester in aud
        s = jwt.decode(f.get("subject_token",""), pub, algorithms=["RS256"], audience=f["client_id"], issuer=ISS)
    except Exception:
        return web.json_response({"error":"invalid_token"}, status=400)
    scopes = [x for x in f.get("scope","").split() if x in c["scopes"]]
    auds = {c["scopes"][x] for x in scopes}
    want = f.get("audience")
    if want and want not in auds:
        return web.json_response({"error":"invalid_request","error_description":"audience not available"}, status=400)
    now = int(time.time())
    t = {"iss":ISS,"sub":s["sub"],"aud":want or sorted(auds),"azp":f["client_id"],"iat":now,
         "exp":min(s["exp"], now+300),"jti":str(uuid.uuid4()),"scope":" ".join(scopes),
         "preferred_username":s.get("preferred_username"),"roles":s.get("roles",[])}
    return web.json_response({"access_token": jwt.encode(t, key, algorithm="RS256", headers={"kid":"k1"}),
                              "token_type":"Bearer","expires_in":t["exp"]-now})
async def models(r): return web.json_response({"object":"list","data":[{"id":"llama3.2:1b"},{"id":"llama3.2:3b"},{"id":"secret-model"}]})
async def chat(r):
    b = await r.json()
    if b.get("stream"):
        resp = web.StreamResponse(headers={"Content-Type":"text/event-stream"}); await resp.prepare(r)
        for w in ["Hel","lo"]:
            await resp.write(f'data: {json.dumps({"choices":[{"delta":{"content":w}}]})}\n\n'.encode())
        await resp.write(b"data: [DONE]\n\n"); await resp.write_eof(); return resp
    return web.json_response({"choices":[{"message":{"content":"OK from fake model"}}]})
async def main():
    a=web.Application(); a.router.add_get("/realms/slatff/protocol/openid-connect/certs",certs)
    a.router.add_post("/realms/slatff/protocol/openid-connect/token",token)
    a.router.add_post("/realms/slatff/protocol/openid-connect/auth/device",device)
    a.router.add_post("/test/revoke",revoke)
    b=web.Application(); b.router.add_get("/v1/models",models); b.router.add_post("/v1/chat/completions",chat)
    for app,port in ((a,9001),(b,9002)):
        rn=web.AppRunner(app); await rn.setup(); await web.TCPSite(rn,"127.0.0.1",port).start()
    await asyncio.Event().wait()
asyncio.run(main())
