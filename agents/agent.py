#!/usr/bin/env python3
"""SLATFF.Cloud agent demo (step 10): an agent acts for a signed-in user.

OAuth 2.0 Token Exchange (RFC 8693) with an actor, as implemented by Keycloak 26.8
(preview features token-exchange-delegation and parameterized-scopes):

  1. The user signs in to "agent-console" (browser, PKCE, loopback redirect) and asks for
     scope delegation:client:research-agent. Keycloak shows a consent screen. If the agent
     has the "delegate" permission (fine-grained admin permissions v2), the user's token gets
     may_act = {sub: the agent's service account, client_id: research-agent}.
  2. The agent signs in as itself: client credentials, authenticated with its own key
     (private_key_jwt, RFC 7523). The private key stays in the macOS Keychain; Keycloak only
     has the public key. No client secret exists.
  3. The agent exchanges the user's token, sending its own token as actor_token. The new
     token has sub = the user, act = the agent, the agent's audience (model-gateway) and the
     agent's role limits. No refresh token: the agent exchanges again when it needs to.
  4. The agent calls the model gateway with it. The gateway checks user and agent and logs both.

Then the refusal checks, and with "kill-switch" the two ways to stop an agent.
Tokens are never printed, only their claims. Python 3.9+ standard library only.

Environment (set by scripts/mac-step10-agents.sh):
  ISSUER          realm URL, e.g. https://id.example/realms/slatff
  GATEWAY         model gateway base, e.g. https://ai.example/gateway/v1
  AGENT_ID        default research-agent;  CONSOLE_ID  default agent-console
  ROGUE_SECRET    secret of client rogue-agent (an agent the user did not approve)
  SWITCH_CMD      command for the kill switch, called with permission-off|permission-on|session-off <user>
  AGENT_KEY_STORE keychain (macOS default) | file | memory
  AGENT_BROWSER   open (default) | none (tests: follow the sign-in redirect without a browser)
Usage:
  python3 agent.py jwks          public key set to register at Keycloak (creates the key once)
  python3 agent.py demo          sign in, act for the user, refusal checks
  python3 agent.py kill-switch   demo, then stop the agent two ways
  python3 agent.py demo-denied   for a user without role ai-user (gateway refuses)
"""
import base64
import hashlib
import http.server
import json
import os
import secrets
import shlex
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
import webbrowser

E = os.environ.get
ISSUER = E("ISSUER", "").rstrip("/")
GATEWAY = E("GATEWAY", "").rstrip("/")
AGENT = E("AGENT_ID", "research-agent")
CONSOLE = E("CONSOLE_ID", "agent-console")
PORT = int(E("CALLBACK_PORT", "8766"))
REDIRECT = f"http://127.0.0.1:{PORT}/callback"
MODEL_OK = E("AGENT_MODEL", "llama3.2:3b")       # in policy.json "agents" for research-agent
MODEL_NO = E("OTHER_MODEL", "llama3.2:1b")       # the user may use it, the agent may not
TE = "urn:ietf:params:oauth:grant-type:token-exchange"
AT = "urn:ietf:params:oauth:token-type:access_token"
JWT_ASSERTION = "urn:ietf:params:oauth:client-assertion-type:jwt-bearer"
SERVICE = "cloud.slatff.agent"
fails = 0
META = {}


# --- small helpers ------------------------------------------------------------------------
def b64u(b):
    return base64.urlsafe_b64encode(b).rstrip(b"=").decode()


def claims(token):
    p = token.split(".")[1]
    return json.loads(base64.urlsafe_b64decode(p + "=" * (-len(p) % 4)))


def check(ok, name, detail=""):
    global fails
    print(("PASS " if ok else "FAIL ") + name + (f"  ({detail})" if detail else ""))
    if not ok:
        fails += 1


def err(body):
    return f"{body.get('error', '')}: {body.get('error_description', '')}".strip(": ")


def req(method, url, form=None, token=None, body=None):
    headers = {}
    data = None
    if form is not None:
        data = urllib.parse.urlencode(form).encode()
        headers["Content-Type"] = "application/x-www-form-urlencoded"
    if body is not None:
        data = json.dumps(body).encode()
        headers["Content-Type"] = "application/json"
    if token:
        headers["Authorization"] = f"Bearer {token}"
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=120) as r:
            raw = r.read()
            status = r.status
    except urllib.error.HTTPError as e:
        raw, status = e.read(), e.code
    try:
        return status, json.loads(raw or b"{}")
    except ValueError:
        return status, {"raw": raw[:200].decode(errors="replace")}


def meta():
    if not META:
        st, d = req("GET", f"{ISSUER}/.well-known/openid-configuration")
        if st != 200:
            sys.exit(f"cannot read {ISSUER}/.well-known/openid-configuration ({st})")
        META.update(d)
    return META


# --- the agent's key: RSA 2048, created once, private part never leaves this computer ------
_SMALL_PRIMES = [p for p in range(3, 2000, 2) if all(p % q for q in range(3, int(p ** 0.5) + 1, 2))]


def _probable_prime(n, rounds=40):
    for p in _SMALL_PRIMES:
        if n % p == 0:
            return n == p
    d, r = n - 1, 0
    while d % 2 == 0:
        d //= 2
        r += 1
    for _ in range(rounds):
        x = pow(secrets.randbelow(n - 3) + 2, d, n)
        if x in (1, n - 1):
            continue
        for _ in range(r - 1):
            x = pow(x, 2, n)
            if x == n - 1:
                break
        else:
            return False
    return True


def rsa_generate(bits=2048, e=65537):
    def prime():
        while True:
            c = secrets.randbits(bits // 2) | (3 << (bits // 2 - 2)) | 1
            if (c - 1) % e and _probable_prime(c):
                return c
    while True:
        p, q = prime(), prime()
        if p != q and (p * q).bit_length() == bits:
            return {"n": p * q, "e": e, "d": pow(e, -1, (p - 1) * (q - 1))}


def _ib(i):
    return i.to_bytes((i.bit_length() + 7) // 8, "big")


class KeyStore:
    """Private key in the macOS Keychain (default on macOS), a 0600 file, or memory (tests)."""

    def __init__(self):
        self.kind = E("AGENT_KEY_STORE") or ("keychain" if sys.platform == "darwin" else "file")
        self.account = f"{AGENT}-signing-key"
        self.path = os.path.join(os.path.expanduser("~/.config/slatff-agent"), self.account)
        self.mem = None

    def load(self):
        if self.kind == "memory":
            return self.mem
        if self.kind == "keychain":
            r = subprocess.run(["security", "find-generic-password", "-a", self.account, "-s", SERVICE, "-w"],
                               capture_output=True, text=True)
            return r.stdout.strip() or None
        try:
            with open(self.path) as f:
                return f.read().strip() or None
        except OSError:
            return None

    def save(self, raw):
        if self.kind == "memory":
            self.mem = raw
        elif self.kind == "keychain":
            subprocess.run(["security", "add-generic-password", "-U", "-a", self.account, "-s", SERVICE,
                            "-w", raw], check=True, capture_output=True)
        else:
            os.makedirs(os.path.dirname(self.path), exist_ok=True)
            fd = os.open(self.path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
            with os.fdopen(fd, "w") as f:
                f.write(raw)


_store = KeyStore()
_key = None


def agent_key():
    global _key
    if _key:
        return _key
    raw = _store.load()
    if raw:
        _key = {a: int(v, 16) for a, v in json.loads(raw).items()}
    else:
        _key = rsa_generate()
        _store.save(json.dumps({a: format(v, "x") for a, v in _key.items()}))
    return _key


def public_jwk(k):
    jwk = {"e": b64u(_ib(k["e"])), "kty": "RSA", "n": b64u(_ib(k["n"]))}
    kid = b64u(hashlib.sha256(json.dumps(jwk, separators=(",", ":"), sort_keys=True).encode()).digest())  # RFC 7638
    return dict(jwk, kid=kid, use="sig", alg="RS256")


def sign(k, header, payload):
    si = b64u(json.dumps(header, separators=(",", ":")).encode()) + "." + \
        b64u(json.dumps(payload, separators=(",", ":")).encode())
    size = (k["n"].bit_length() + 7) // 8
    t = bytes.fromhex("3031300d060960864801650304020105000420") + hashlib.sha256(si.encode()).digest()
    em = b"\x00\x01" + b"\xff" * (size - len(t) - 3) + b"\x00" + t
    return si + "." + b64u(pow(int.from_bytes(em, "big"), k["d"], k["n"]).to_bytes(size, "big"))


def agent_auth(k=None):
    """private_key_jwt (RFC 7523 section 2.2): a short JWT signed with the agent's key."""
    k = k or agent_key()
    now = int(time.time())
    a = sign(k, {"alg": "RS256", "typ": "JWT", "kid": public_jwk(k)["kid"]},
             {"iss": AGENT, "sub": AGENT, "aud": meta()["issuer"], "jti": secrets.token_urlsafe(16),
              "iat": now, "exp": now + 50})
    return {"client_id": AGENT, "client_assertion_type": JWT_ASSERTION, "client_assertion": a}


# --- user sign-in: authorization code + PKCE, loopback redirect (RFC 8252) -------------------
def sign_in():
    verifier = secrets.token_urlsafe(48)
    state = secrets.token_urlsafe(16)
    got = {}

    class Callback(http.server.BaseHTTPRequestHandler):
        def log_message(self, *a):
            pass

        def do_GET(self):
            q = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
            got.update({k: v[0] for k, v in q.items()})
            self.send_response(200)
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.end_headers()
            self.wfile.write(b"Signed in. You can close this window and go back to the terminal.")

    srv = http.server.HTTPServer(("127.0.0.1", PORT), Callback)
    threading.Thread(target=srv.handle_request, daemon=True).start()
    url = meta()["authorization_endpoint"] + "?" + urllib.parse.urlencode({
        "client_id": CONSOLE, "response_type": "code", "redirect_uri": REDIRECT, "state": state,
        "scope": f"openid delegation:client:{AGENT}", "prompt": "login",
        "code_challenge": b64u(hashlib.sha256(verifier.encode()).digest()), "code_challenge_method": "S256"})
    if E("AGENT_BROWSER", "open") == "none":
        urllib.request.urlopen(url, timeout=30).read()
    else:
        print(f"\nSign in in the browser (opening it now). Keycloak will ask:\n"
              f"  \"Allow {AGENT} to act on your behalf?\"  Answer Yes.\n\n{url}\n")
        webbrowser.open(url)
    deadline = time.time() + 300
    while "code" not in got and "error" not in got and time.time() < deadline:
        time.sleep(0.3)
    srv.server_close()
    if got.get("state") != state or "code" not in got:
        sys.exit(f"sign-in failed: {got.get('error', 'timeout')} {got.get('error_description', '')}")
    st, t = req("POST", meta()["token_endpoint"], form={
        "grant_type": "authorization_code", "client_id": CONSOLE, "code": got["code"],
        "redirect_uri": REDIRECT, "code_verifier": verifier})
    if st != 200:
        sys.exit(f"code exchange failed ({st} {err(t)})")
    return t


def actor_token(auth=None):
    return req("POST", meta()["token_endpoint"], form=dict(auth or agent_auth(), grant_type="client_credentials"))


def exchange(subject, actor=None, auth=None):
    form = dict(auth or agent_auth(), grant_type=TE, subject_token=subject, subject_token_type=AT)
    if actor:
        form.update(actor_token=actor, actor_token_type=AT)
    return req("POST", meta()["token_endpoint"], form=form)


def chat(token, model, text="Reply with one short sentence: who are you working for?"):
    return req("POST", f"{GATEWAY}/chat/completions", token=token,
                body={"model": model, "stream": False, "messages": [{"role": "user", "content": text}]})


def switch(*args):
    cmd = E("SWITCH_CMD")
    if not cmd:
        sys.exit("SWITCH_CMD is not set")
    r = subprocess.run(shlex.split(cmd) + list(args), capture_output=True, text=True)
    print(f"  kill switch: {' '.join(args)} -> {(r.stdout.strip().splitlines() or ['?'])[-1]}")
    return r.returncode == 0


# --- the demo -------------------------------------------------------------------------------
def demo(denied=False, kill=False):
    print(f"Issuer {ISSUER}\nGateway {GATEWAY}\nAgent {AGENT} (key: {_store.kind})")
    login = sign_in()
    user, refresh = login["access_token"], login.get("refresh_token")
    u = claims(user)
    may = u.get("may_act") or {}
    name = u.get("preferred_username")
    print(f"\n--- 1. user token: {name}")
    check(may.get("client_id") == AGENT, "user token carries may_act for the agent",
          f"may_act.client_id={may.get('client_id')}")
    aud = u.get("aud") if isinstance(u.get("aud"), list) else [u.get("aud")]
    check(AGENT in aud, "agent is in the user token's audience", f"aud={aud}")
    check("act" not in u, "user token has no act claim")

    print(f"\n--- 2. agent signs in as itself (private_key_jwt, no secret)")
    st, a = actor_token()
    check(st == 200, "client credentials with the agent's key", f"{st} {err(a)}")
    if st != 200:
        return
    actor = a["access_token"]
    ac = claims(actor)
    check(ac.get("azp") == AGENT and "act" not in ac, "agent token: azp is the agent, no act",
          f"sub={ac.get('sub')}")
    st, b = actor_token(agent_auth(rsa_generate()))
    check(st in (400, 401), "another key is refused", f"{st} {err(b)}")

    print("\n--- 3. refusals before delegation")
    st, b = chat(actor, MODEL_OK)
    check(st == 403, "agent alone (no user) at the gateway is refused", str(st))
    st, b = chat(user, MODEL_OK)
    check(st == 401, "user token sent straight to the gateway is refused", str(st))
    st, b = exchange(user)
    check(st in (400, 403), "exchange without actor_token is refused", f"{st} {err(b)}")
    if E("ROGUE_SECRET"):
        rogue = {"client_id": "rogue-agent", "client_secret": E("ROGUE_SECRET")}
        st, r = actor_token(rogue)
        st, b = exchange(user, r.get("access_token", "x"), rogue) if st == 200 else (st, r)
        check(st in (400, 401, 403), "an agent the user did not approve is refused", f"{st} {err(b)}")

    print("\n--- 4. delegated token (RFC 8693 with actor_token)")
    st, d = exchange(user, actor)
    check(st == 200, "exchange with actor_token", f"{st} {err(d)}")
    if st != 200:
        return
    dt = d["access_token"]
    c = claims(dt)
    act = c.get("act") or {}
    daud = c.get("aud") if isinstance(c.get("aud"), list) else [c.get("aud")]
    check(c.get("sub") == u.get("sub"), "sub is still the user", name)
    check(act.get("client_id") == AGENT and act.get("sub") == ac.get("sub"), "act names the agent",
          f"act.client_id={act.get('client_id')}")
    check("may_act" not in c, "no may_act in the delegated token")
    check("model-gateway" in daud, "audience is the model gateway", f"aud={daud}")
    check(c.get("azp") == AGENT, "azp is the agent")
    check("refresh_token" not in d, "no refresh token")
    life = c.get("exp", 0) - c.get("iat", 0)
    check(0 < life <= 300, "short-lived", f"{life} s")
    roles = sorted((c.get("realm_access") or {}).get("roles", []))
    print(f"  roles in the delegated token: {roles}")
    if not denied and "ai-user" not in roles:
        denied = True
        print(f"  {name} has no role ai-user: expecting the gateway to refuse")

    print("\n--- 5. gateway")
    st, b = chat(dt, MODEL_OK)
    if denied:
        check(st == 403, f"{name} has no role ai-user: the agent cannot use more than the user", str(st))
        if not kill:
            return
    else:
        text = ((b.get("choices") or [{}])[0].get("message") or {}).get("content", "")
        check(st == 200, f"agent for {name}, model {MODEL_OK}", f"{st} {text[:70]!r}" if st == 200 else f"{st} {b}")
        st, b = chat(dt, MODEL_NO)
        check(st == 403, f"model {MODEL_NO}: allowed for {name}, not for the agent", str(st))
    sig = dt.rsplit(".", 1)[1]
    st, b = chat(dt.rsplit(".", 1)[0] + "." + ("B" if sig[0] == "A" else "A") + sig[1:], MODEL_OK)
    check(st == 401, "tampered delegated token is refused", str(st))

    if not kill:
        return
    print("\n--- 6. kill switch A: remove the agent's delegate permission")
    if switch("permission-off"):
        st, b = exchange(user, actor_token()[1].get("access_token", "x"))
        check(st == 200, "a user token issued before still works until it expires (limit, documented)", str(st))
        st, r = req("POST", meta()["token_endpoint"], form={"grant_type": "refresh_token",
                                                             "client_id": CONSOLE, "refresh_token": refresh})
        new = r.get("access_token")
        check(st == 200 and new and "may_act" not in claims(new), "after refresh the user token has no may_act",
              f"{st} {err(r)}")
        if new:
            st, b = exchange(new, actor_token()[1].get("access_token", "x"))
            check(st in (400, 403), "exchange with the refreshed token is refused", f"{st} {err(b)}")
        switch("permission-on")
    print("\n--- 7. kill switch B: end the user's Keycloak session")
    if switch("session-off", name):
        st, b = exchange(user, actor_token()[1].get("access_token", "x"))
        check(st in (400, 401, 403), "no new agent token after the session ends", f"{st} {err(b)}")
        st, b = chat(dt, MODEL_OK)
        print(f"  token issued before: gateway says {st} (valid until it expires, {life} s at most; limit, documented)")


def main():
    cmd = sys.argv[1] if len(sys.argv) > 1 else ""
    if cmd == "jwks":
        print(json.dumps({"keys": [public_jwk(agent_key())]}))
        return
    if cmd not in ("demo", "demo-denied", "kill-switch"):
        sys.exit(__doc__)
    if not ISSUER or not GATEWAY:
        sys.exit("ISSUER and GATEWAY must be set")
    demo(denied=cmd == "demo-denied", kill=cmd == "kill-switch")
    print(f"\n{'All checks passed.' if not fails else f'{fails} check(s) failed.'}")
    sys.exit(1 if fails else 0)


if __name__ == "__main__":
    main()
