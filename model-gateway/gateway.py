"""SLATFF.Cloud model gateway.

Sits between Open WebUI and the model runtime (Ollama's OpenAI-compatible API) and makes
the access decision at the model boundary, independent of the chat application:

1. Identity: every inference request must carry the user's own Keycloak access token
   (Open WebUI forwards it with connection auth type "system_oauth"). The gateway checks
   signature (realm keys), issuer, audience "model-gateway" and expiry.
2. Model policy: the user's realm roles must allow the requested model (policy.json).
3. Label policy: if the prompt contains "CLASSIFICATION: <LABEL>" markers (for example from
   retrieved documents), the user's roles must allow every label found. Unknown labels are
   refused (fail closed).
4. Audit: one JSON line per decision (who, which model, labels, allow or deny, why).
   Prompt text is not logged unless AUDIT_LOG_PROMPTS=true.
5. Delegation (tools): POST /v1/tools/<name> calls a tool on the user's behalf. The gateway
   never forwards the user's token. It exchanges it at Keycloak (RFC 8693 standard token
   exchange) for a new token that is only valid for that one tool (audience), carries only
   that tool's scope, and expires no later than the user's token. Authority gets narrower
   as it moves: the tool cannot reuse it against the model gateway or another tool.
   Both token IDs and a correlation ID are written to the audit log (the evidence chain).

6. Proof of possession (DPoP, RFC 9449): a token bound to a key (claim cnf.jkt) is only
   accepted with "Authorization: DPoP" and a valid DPoP proof signed by that key, for this
   method and URL, recent, not replayed. A copied token alone is refused. Clients listed in
   DPOP_REQUIRED_CLIENTS must use bound tokens.

7. Agents acting for a user (RFC 8693 delegation, Keycloak 26.8 preview): a token with an
   "act" claim was issued to an agent for the user in "sub". Both must be allowed: the user's
   roles decide as usual, and policy.json "agents" lists the agents and the models each may
   use for a user. An agent in that list may not call the gateway on its own (no "act"), and a
   token that still carries "may_act" (the user's grant to the agent) is refused. The audit
   line names the user and the agent.

Model listing (GET /v1/models) is answered without a token so the chat application can
build its model list; with a token the list is filtered to what that user may use.
"""
import asyncio
import base64
import hashlib
import json
import logging
import os
import re
import time
import uuid

import jwt
from aiohttp import ClientSession, ClientTimeout, web
from jwt import PyJWKClient

UPSTREAM = os.environ.get("UPSTREAM_URL", "http://host.docker.internal:11434/v1").rstrip("/")
ISSUER = os.environ["OIDC_ISSUER"].rstrip("/")
AUDIENCE = os.environ.get("GATEWAY_AUDIENCE", "model-gateway")
POLICY_FILE = os.environ.get("POLICY_FILE", "/config/policy.json")
AUDIT_FILE = os.environ.get("AUDIT_FILE", "/audit/audit.jsonl")
LOG_PROMPTS = os.environ.get("AUDIT_LOG_PROMPTS", "false").lower() == "true"
# Token exchange: the gateway is a confidential Keycloak client (client ID = AUDIENCE).
TOKEN_URL = os.environ.get("TOKEN_URL", f"{ISSUER}/protocol/openid-connect/token")
CLIENT_SECRET = os.environ.get("GATEWAY_CLIENT_SECRET", "")
LABEL_RE = re.compile(r"CLASSIFICATION:\s*([A-Z][A-Z0-9-]*)")
TOOL_RE = re.compile(r"^[a-z0-9][a-z0-9-]{0,40}$")

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("gateway")
DPOP_HTU_BASE = os.environ.get("DPOP_HTU_BASE", "").rstrip("/")   # public base, e.g. https://ai.example/gateway
DPOP_REQUIRED_CLIENTS = {c.strip() for c in os.environ.get("DPOP_REQUIRED_CLIENTS", "").split(",") if c.strip()}
DPOP_MAX_AGE = 60
_dpop_seen = {}      # proof jti -> expiry (replay check)
jwks = PyJWKClient(f"{ISSUER}/protocol/openid-connect/certs", cache_keys=True, lifespan=300)

_policy = {"mtime": 0.0, "data": {}}


def policy():
    """Load policy.json, reloading when the file changes."""
    try:
        m = os.path.getmtime(POLICY_FILE)
        if m != _policy["mtime"]:
            with open(POLICY_FILE) as f:
                _policy["data"] = json.load(f)
            _policy["mtime"] = m
            d = _policy["data"]
            log.info("policy loaded: %d models, %d labels, %d tools", len(d.get("models", {})),
                     len(d.get("labels", {})), len(d.get("tools", {})))
            if d.get("agents"):
                log.info("policy: %d agents", len(d["agents"]))
    except Exception as e:  # keep the last good policy, or deny everything if none
        log.error("policy load failed: %s", e)
    return _policy["data"]


def audit(record):
    record["ts"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    line = json.dumps(record, ensure_ascii=False)
    log.info("AUDIT %s", line)
    try:
        with open(AUDIT_FILE, "a") as f:
            f.write(line + "\n")
    except Exception as e:
        log.error("audit write failed: %s", e)


def bearer(request):
    """(scheme, token) from Authorization: Bearer or DPoP."""
    auth = request.headers.get("Authorization", "")
    for scheme in ("Bearer", "DPoP"):
        if auth.startswith(scheme + " ") and len(auth) > len(scheme) + 13:
            return scheme, auth[len(scheme) + 1:]
    return None, None


def _b64u(b):
    return base64.urlsafe_b64encode(b).rstrip(b"=").decode()


def jwk_thumbprint(jwk):
    """RFC 7638."""
    members = {"RSA": ("e", "kty", "n"), "EC": ("crv", "kty", "x", "y"), "OKP": ("crv", "kty", "x")}[jwk["kty"]]
    canon = json.dumps({m: jwk[m] for m in members}, separators=(",", ":"), sort_keys=True)
    return _b64u(hashlib.sha256(canon.encode()).digest())


def check_dpop(request, scheme, token, claims):
    """None if fine, else the reason. RFC 9449 sections 4.3 and 7.1."""
    jkt = (claims.get("cnf") or {}).get("jkt")
    if not jkt:
        if claims.get("azp") in DPOP_REQUIRED_CLIENTS:
            return f"client {claims.get('azp')} must use a DPoP-bound token"
        return "DPoP scheme used with a token that is not bound" if scheme == "DPoP" else None
    if scheme != "DPoP":
        return "token is DPoP-bound: send it as Authorization: DPoP with a DPoP proof"
    proof = request.headers.get("DPoP", "")
    try:
        h = jwt.get_unverified_header(proof)
        jwk, alg = h.get("jwk") or {}, h.get("alg")
        if h.get("typ") != "dpop+jwt" or alg not in ("RS256", "PS256", "ES256") or "d" in jwk:
            return "DPoP proof header not acceptable"
        c = jwt.decode(proof, jwt.PyJWK(jwk, algorithm=alg).key, algorithms=[alg],
                       options={"verify_aud": False, "require": ["iat", "jti", "htm", "htu"]})
    except Exception as e:
        return f"DPoP proof missing or invalid ({type(e).__name__})"
    if jwk_thumbprint(jwk) != jkt:
        return "DPoP key does not match the token (cnf.jkt)"
    expected = (DPOP_HTU_BASE + request.path) if DPOP_HTU_BASE else str(request.url).split("?")[0]
    if c["htm"] != request.method or c["htu"].split("?")[0].split("#")[0] != expected:
        return "DPoP proof is for another method or URL"
    now = time.time()
    if abs(now - c["iat"]) > DPOP_MAX_AGE:
        return "DPoP proof too old or from the future"
    if c.get("ath") != _b64u(hashlib.sha256(token.encode()).digest()):
        return "DPoP proof is for another token (ath)"
    for k in [k for k, exp in _dpop_seen.items() if exp < now]:
        del _dpop_seen[k]
    if c["jti"] in _dpop_seen:
        return "DPoP proof replayed"
    _dpop_seen[c["jti"]] = now + 2 * DPOP_MAX_AGE
    return None


async def verify(request):
    scheme, token = bearer(request)
    if not token:
        return None, "no user token"
    try:
        key = await asyncio.to_thread(jwks.get_signing_key_from_jwt, token)
        claims = jwt.decode(
            token, key.key, algorithms=["RS256", "PS256", "ES256"],
            audience=AUDIENCE, issuer=ISSUER, leeway=30,
            options={"require": ["exp", "iat", "iss", "sub"]},
        )
    except Exception as e:
        return None, f"token rejected ({type(e).__name__})"
    why = check_dpop(request, scheme, token, claims)
    if why:
        return None, why
    return claims, None


def roles_of(claims):
    roles = set(claims.get("roles") or [])
    roles |= set((claims.get("realm_access") or {}).get("roles") or [])
    return roles


def who(claims):
    if not claims:
        return {"user": None}
    return {
        "user": claims.get("preferred_username"),
        "sub": claims.get("sub"),
        "client": claims.get("azp"),
        "roles": sorted(r for r in roles_of(claims) if not r.startswith("default-roles")),
        "groups": claims.get("groups"),
        "dpop": bool((claims.get("cnf") or {}).get("jkt")),
        **({"act": actor_chain(claims)} if claims.get("act") else {}),
    }


def actor_chain(claims):
    """Actors in "act", outermost (the one presenting the token) first."""
    chain, a = [], claims.get("act")
    while isinstance(a, dict) and len(chain) < 5:
        chain.append(a.get("client_id") or a.get("sub"))
        a = a.get("act")
    return chain


def agent_check(claims, model=None):
    """(status, reason) if the agent part of the token is not allowed, else None."""
    agents = policy().get("agents", {})
    if "may_act" in claims:
        return 401, "token carries may_act: it is the user's grant to an agent, not an access token"
    act = claims.get("act")
    if act is None:
        if claims.get("azp") in agents:
            return 403, f"agent '{claims['azp']}' may only act for a user (token has no act claim)"
        return None
    if not isinstance(act, dict) or not (act.get("client_id") or act.get("sub")):
        return 401, "malformed act claim"
    actor = act.get("client_id") or act.get("sub")
    if act.get("client_id") and act["client_id"] != claims.get("azp"):
        return 401, "act claim does not match the client presenting the token"
    rule = agents.get(actor)
    if not rule:
        return 403, f"agent '{actor}' is not allowed to act for users"
    if model is not None and model not in rule.get("models", []):
        return 403, f"agent '{actor}' may not use model '{model}'"
    return None


def allows(rule, roles):
    return bool(rule) and bool(set(rule.get("roles", [])) & roles)


def prompt_text(body):
    parts = []
    for m in body.get("messages") or []:
        c = m.get("content")
        if isinstance(c, str):
            parts.append(c)
        elif isinstance(c, list):
            parts += [p.get("text", "") for p in c if isinstance(p, dict)]
    if isinstance(body.get("prompt"), str):
        parts.append(body["prompt"])
    return "\n".join(parts)


def deny(status, message, record):
    record.update(decision="deny", reason=message)
    audit(record)
    return web.json_response(
        {"error": {"message": f"SLATFF model gateway: {message}", "type": "access_denied"}},
        status=status)


async def list_models(request):
    claims, _ = await verify(request)
    pol = policy().get("models", {})
    async with request.app["http"].get(f"{UPSTREAM}/models") as r:
        upstream = await r.json(content_type=None)
    data = [m for m in upstream.get("data", []) if m.get("id") in pol]
    if claims:
        roles = roles_of(claims)
        data = [m for m in data if allows(pol.get(m["id"]), roles)]
        if claims.get("act") or "may_act" in claims:
            data = [m for m in data if not agent_check(claims, m["id"])]
    return web.json_response({"object": "list", "data": data})


async def inference(request):
    started = time.monotonic()
    record = {"path": request.path, "chat_id": request.headers.get("X-OpenWebUI-Chat-Id")}
    if request.headers.get("X-SLATFF-IDE"):           # set by the IDE bridge; self-reported label
        record["ide"] = request.headers["X-SLATFF-IDE"][:40]
    claims, why = await verify(request)
    record.update(who(claims))
    try:
        body = await request.json()
    except Exception:
        return deny(400, "request body is not JSON", record)
    model = body.get("model")
    record["model"] = model
    if not claims:
        return deny(401, f"a valid Keycloak token is required ({why})", record)
    roles = roles_of(claims)
    pol = policy()
    if not allows(pol.get("models", {}).get(model), roles):
        return deny(403, f"user '{record['user']}' may not use model '{model}'", record)
    refused = agent_check(claims, model)
    if refused:
        return deny(*refused, record)
    text = prompt_text(body)
    labels = sorted(set(LABEL_RE.findall(text)))
    record.update(labels=labels, prompt_chars=len(text), messages=len(body.get("messages") or []))
    if LOG_PROMPTS:
        record["prompt"] = text
    for label in labels:
        if not allows(pol.get("labels", {}).get(label), roles):
            return deny(403, f"the prompt contains {label} content, which user "
                             f"'{record['user']}' is not entitled to", record)

    # Allowed: forward to the model runtime, streaming the answer back unchanged.
    headers = {"Content-Type": "application/json"}
    upstream = await request.app["http"].post(f"{UPSTREAM}{request.path[len('/v1'):]}",
                                              data=json.dumps(body), headers=headers)
    resp = web.StreamResponse(status=upstream.status, headers={
        "Content-Type": upstream.headers.get("Content-Type", "application/json")})
    await resp.prepare(request)
    try:
        async for chunk in upstream.content.iter_any():
            await resp.write(chunk)
    finally:
        upstream.release()
    record.update(decision="allow", status=upstream.status,
                  stream=bool(body.get("stream")), ms=int((time.monotonic() - started) * 1000))
    audit(record)
    await resp.write_eof()
    return resp


async def exchange(http, subject_token, tool):
    """RFC 8693 standard token exchange at Keycloak: user token in, tool-only token out.

    'scope' asks for the tool's optional client scope (it carries the tool's audience
    mapper); 'audience' then filters the new token down to that tool alone. Keycloak caps
    the new token's lifetime at the subject token's expiry.
    """
    form = {
        "grant_type": "urn:ietf:params:oauth:grant-type:token-exchange",
        "client_id": AUDIENCE,
        "client_secret": CLIENT_SECRET,
        "subject_token": subject_token,
        "subject_token_type": "urn:ietf:params:oauth:token-type:access_token",
        "requested_token_type": "urn:ietf:params:oauth:token-type:access_token",
        "audience": tool["audience"],
        "scope": tool["scope"],
    }
    async with http.post(TOKEN_URL, data=form) as r:
        body = await r.json(content_type=None)
        if r.status != 200 or "access_token" not in body:
            return None, f"token exchange refused by Keycloak ({r.status} {body.get('error', '')})"
        return body["access_token"], None


async def tool_call(request):
    """Call a tool on the user's behalf with a narrowed, exchanged token."""
    started = time.monotonic()
    name = request.match_info["name"]
    corr = str(uuid.uuid4())
    record = {"path": request.path, "tool": name, "correlation_id": corr}
    claims, why = await verify(request)
    record.update(who(claims))
    if not claims:
        return deny(401, f"a valid Keycloak token is required ({why})", record)
    record["subject_jti"] = claims.get("jti")
    refused = agent_check(claims)
    if refused:
        return deny(*refused, record)
    if claims.get("act"):   # Keycloak's standard exchange refuses subject tokens with act
        return deny(403, "agents cannot call tools through the gateway yet (no second delegation hop)", record)
    tool = policy().get("tools", {}).get(name) if TOOL_RE.match(name) else None
    if not tool:
        return deny(403, f"tool '{name}' is not in the policy", record)
    if not allows(tool, roles_of(claims)):
        return deny(403, f"user '{record['user']}' may not use tool '{name}'", record)
    try:
        body = await request.json()
    except Exception:
        return deny(400, "request body is not JSON", record)
    if not CLIENT_SECRET:
        return deny(503, "gateway has no client secret, delegation is not configured", record)

    token, why = await exchange(request.app["http"], bearer(request)[1], tool)
    if not token:
        return deny(502, why, record)
    # Record what was actually delegated (read from the token Keycloak issued).
    d = jwt.decode(token, options={"verify_signature": False})
    record["delegated"] = {"jti": d.get("jti"), "aud": d.get("aud"), "scope": d.get("scope"),
                           "azp": d.get("azp"), "expires_in": int(d.get("exp", 0) - time.time())}
    async with request.app["http"].post(
            tool["url"], json=body,
            headers={"Authorization": f"Bearer {token}", "X-Correlation-Id": corr}) as r:
        result = await r.json(content_type=None)
        status = r.status
    record.update(decision="allow" if status < 400 else "tool_refused", status=status,
                  ms=int((time.monotonic() - started) * 1000))
    audit(record)
    return web.json_response(result, status=status, headers={"X-Correlation-Id": corr})


async def health(request):
    return web.json_response({"ok": True, "issuer": ISSUER, "audience": AUDIENCE,
                              "delegation": bool(CLIENT_SECRET)})


async def startup(app):
    app["http"] = ClientSession(timeout=ClientTimeout(total=None, sock_read=600))
    policy()
    os.makedirs(os.path.dirname(AUDIT_FILE), exist_ok=True)


async def cleanup(app):
    await app["http"].close()


def main():
    app = web.Application(client_max_size=32 * 1024 * 1024)
    app.on_startup.append(startup)
    app.on_cleanup.append(cleanup)
    app.router.add_get("/healthz", health)
    app.router.add_get("/v1/models", list_models)
    for p in ("/v1/chat/completions", "/v1/completions", "/v1/embeddings"):
        app.router.add_post(p, inference)
    app.router.add_post("/v1/tools/{name}", tool_call)
    web.run_app(app, host="0.0.0.0", port=8080, access_log=None)


if __name__ == "__main__":
    main()
