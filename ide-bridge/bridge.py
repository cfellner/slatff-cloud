#!/usr/bin/env python3
"""SLATFF.Cloud IDE bridge: lets Xcode, Visual Studio and Qt Creator use the model gateway as you.

IDEs can only send a fixed API key (or none), and a Keycloak access token lives 5 minutes, so
this small program on the developer's computer does the identity part:

1. Sign-in: OAuth 2.0 Device Authorization Grant (RFC 8628) against Keycloak, client
   "ide-bridge" (public, no secret). You confirm a code in the browser; your normal Keycloak
   sign-in (password, passkey, MFA) applies.
2. Tokens: the refresh token is kept in the operating system's secret store
   (macOS Keychain, Windows DPAPI, Linux Secret Service via secret-tool; a 0600 file only as
   a last resort on Linux, with a warning). A fresh access token is fetched before expiry.
3. Forwarding: the gateway gets your own access token on every request. It decides (roles,
   models, labels) and writes the audit line with your name and the IDE label.
   Two API styles are offered on the same port, so each IDE can use what it supports:
     OpenAI style:  /v1/models, /v1/chat/completions   (Xcode, Visual Studio custom OpenAI endpoint)
     Ollama style:  /api/tags, /api/chat, /api/generate, /api/version, /api/show
                    (Qt AI Assistant and Visual Studio's Ollama provider; translated to OpenAI)
4. Local only: listens on 127.0.0.1. Every request must carry the local key, either as
   API key (Authorization: Bearer <key> or x-api-key) or, for IDEs without a key field, in the
   base URL path: http://127.0.0.1:11435/k/<key>  (then /v1/... or /api/... after it).
   The key is created once and kept in the same secret store, so the IDE setting survives
   restarts. `key new` replaces it.
5. macOS: `agent install` runs the bridge as a LaunchAgent (starts at login, restarts if it
   stops). Signing in stays a user action (`login`); the agent picks up the new sign-in.

Python 3.9+ standard library only. Commands:
  python3 bridge.py configure --issuer https://id.example/realms/slatff --gateway https://ai.example/gateway/v1
  python3 bridge.py login       sign in (device code), store the refresh token
  python3 bridge.py login private   same, in a private browser window (to sign in as another user)
  python3 bridge.py serve       run for the IDE (prints the settings to enter)
  python3 bridge.py logout      end the session at Keycloak and remove the refresh token
  python3 bridge.py key         show the local key;  key new   create a new one
  python3 bridge.py config      effective settings and their source (MDM, environment, config file)
  python3 bridge.py agent install | uninstall | status    macOS LaunchAgent
  python3 bridge.py selftest-store   check the secret store on this computer (used by CI)
"""
import base64
import http.server
import json
import os
import platform
import secrets
import shutil
import socketserver
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
import webbrowser

SYSTEM = platform.system()          # Darwin, Windows, Linux


def config_dir():
    if os.environ.get("SLATFF_CONFIG_DIR"):          # tests
        return os.environ["SLATFF_CONFIG_DIR"]
    if SYSTEM == "Windows":
        return os.path.join(os.environ.get("APPDATA", os.path.expanduser("~")), "slatff")
    if SYSTEM == "Darwin":
        return os.path.expanduser("~/Library/Application Support/slatff")
    return os.path.join(os.environ.get("XDG_CONFIG_HOME", os.path.expanduser("~/.config")), "slatff")


CONFIG_FILE = os.path.join(config_dir(), "ide-bridge.json")


def load_config():
    try:
        with open(CONFIG_FILE) as f:
            return json.load(f)
    except Exception:
        return {}


MANAGED_DOMAIN = "cloud.slatff.ide-bridge"
# managed preference key -> (config key, environment variable)
MANAGED_KEYS = {"Issuer": ("issuer", "SLATFF_ISSUER"), "Gateway": ("gateway", "SLATFF_GATEWAY"),
                "ClientID": ("client_id", "SLATFF_CLIENT_ID"), "Port": ("port", "SLATFF_BRIDGE_PORT"),
                "IDE": ("ide", "SLATFF_IDE"), "DPoP": ("dpop", "SLATFF_DPOP")}


def load_managed():
    """Settings pushed by MDM (configuration profile, domain cloud.slatff.ide-bridge).
    macOS writes them to /Library/Managed Preferences (device) and
    /Library/Managed Preferences/<user> (user). They win over environment and config file."""
    base = os.environ.get("SLATFF_MANAGED_DIR") or ("/Library/Managed Preferences" if SYSTEM == "Darwin" else "")
    if not base:
        return {}
    import getpass
    import plistlib
    out = {}
    for path in (os.path.join(base, f"{MANAGED_DOMAIN}.plist"),
                 os.path.join(base, getpass.getuser(), f"{MANAGED_DOMAIN}.plist")):   # user scope wins
        try:
            with open(path, "rb") as f:
                d = plistlib.load(f)
        except Exception:
            continue
        for k, (ck, _) in MANAGED_KEYS.items():
            if k in d and str(d[k]).strip():
                out[ck] = str(d[k]).strip()
    return out


_cfg = load_config()
_managed = load_managed()


def setting(key, env, default):
    """Managed preference, then environment, then config file, then default."""
    if key in _managed:
        return _managed[key], "managed"
    if os.environ.get(env):
        return os.environ[env], "environment"
    if key in _cfg and str(_cfg[key]).strip():
        return str(_cfg[key]), "config file"
    return default, "default"


SOURCES = {}
for _k, (_ck, _env) in MANAGED_KEYS.items():
    SOURCES[_ck] = setting(_ck, _env, {"client_id": "ide-bridge", "port": "11435", "ide": "unspecified"}.get(_ck, ""))
ISSUER = SOURCES["issuer"][0].rstrip("/")
GATEWAY = SOURCES["gateway"][0].rstrip("/")
CLIENT_ID = SOURCES["client_id"][0]
PORT = int(SOURCES["port"][0])
IDE = SOURCES["ide"][0]
SERVICE = "slatff-ide-bridge"
TOKEN_STORE = os.environ.get("SLATFF_TOKEN_STORE", "auto")      # auto | memory | file (tests)
AGENT_LABEL = "cloud.slatff.ide-bridge"

_lock = threading.Lock()
_state = {"access": None, "exp": 0, "refresh": None, "user": None}


def die(msg):
    print(msg, file=sys.stderr)
    sys.exit(1)


# --- secret store ---------------------------------------------------------------------
class Store:
    """Refresh token storage in the OS secret store."""

    def __init__(self, kind=None, account=None, name="refresh-token"):
        self.kind = kind or self._pick()
        self.mem = None
        self.account = account or CLIENT_ID
        self.path = os.path.join(config_dir(), name + (".dpapi" if self.kind == "dpapi" else ""))

    @staticmethod
    def _pick():
        if TOKEN_STORE in ("memory", "file"):
            return TOKEN_STORE
        if SYSTEM == "Darwin":
            return "keychain"
        if SYSTEM == "Windows":
            return "dpapi"
        if shutil.which("secret-tool"):
            return "secret-tool"
        return "file"

    def describe(self):
        return {"keychain": "macOS Keychain", "dpapi": "Windows DPAPI (encrypted for your account)",
                "secret-tool": "Linux Secret Service", "file": "file readable only by you (no secret service found)",
                "memory": "memory only"}[self.kind]

    def save(self, tok):
        if self.kind == "memory":
            self.mem = tok
        elif self.kind == "keychain":
            subprocess.run(["security", "add-generic-password", "-U", "-a", self.account, "-s", SERVICE,
                            "-w", tok], check=True, capture_output=True)
        elif self.kind == "secret-tool":
            subprocess.run(["secret-tool", "store", "--label=SLATFF IDE bridge", "service", SERVICE,
                            "account", self.account], input=tok.encode(), check=True, capture_output=True)
        else:
            os.makedirs(config_dir(), exist_ok=True)
            data = _dpapi(tok.encode(), protect=True) if self.kind == "dpapi" else tok.encode()
            fd = os.open(self.path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
            with os.fdopen(fd, "wb") as f:
                f.write(data)
            if self.kind == "file":
                print("WARNING: no secret service found; stored in a file only you can read: "
                      + self.path, file=sys.stderr)

    def load(self):
        try:
            if self.kind == "memory":
                return self.mem
            if self.kind == "keychain":
                r = subprocess.run(["security", "find-generic-password", "-a", self.account, "-s", SERVICE, "-w"],
                                   capture_output=True, text=True)
                return r.stdout.strip() or None
            if self.kind == "secret-tool":
                r = subprocess.run(["secret-tool", "lookup", "service", SERVICE, "account", self.account],
                                   capture_output=True, text=True)
                return r.stdout.strip() or None
            with open(self.path, "rb") as f:
                data = f.read()
            return (_dpapi(data, protect=False) if self.kind == "dpapi" else data).decode() or None
        except Exception:
            return None

    def delete(self):
        if self.kind == "memory":
            self.mem = None
        elif self.kind == "keychain":
            subprocess.run(["security", "delete-generic-password", "-a", self.account, "-s", SERVICE],
                           capture_output=True)
        elif self.kind == "secret-tool":
            subprocess.run(["secret-tool", "clear", "service", SERVICE, "account", self.account],
                           capture_output=True)
        elif os.path.exists(self.path):
            os.remove(self.path)


def _dpapi(data, protect):
    """Windows Data Protection API (CryptProtectData), standard library ctypes only."""
    import ctypes
    from ctypes import wintypes

    class BLOB(ctypes.Structure):
        _fields_ = [("cbData", wintypes.DWORD), ("pbData", ctypes.POINTER(ctypes.c_char))]

    buf = ctypes.create_string_buffer(data, len(data))
    blob_in = BLOB(len(data), ctypes.cast(buf, ctypes.POINTER(ctypes.c_char)))
    blob_out = BLOB()
    crypt32, kernel32 = ctypes.windll.crypt32, ctypes.windll.kernel32
    fn = crypt32.CryptProtectData if protect else crypt32.CryptUnprotectData
    ok = fn(ctypes.byref(blob_in), None, None, None, None, 0x01, ctypes.byref(blob_out))  # UI_FORBIDDEN
    if not ok:
        raise OSError("DPAPI call failed")
    try:
        return ctypes.string_at(blob_out.pbData, blob_out.cbData)
    finally:
        kernel32.LocalFree(blob_out.pbData)


store = Store()
key_store = Store(account="local-key", name="local-key")


def local_key(new=False):
    """The key the IDE sends. Kept in the secret store so it survives restarts.
    SLATFF_LOCAL_KEY overrides it (tests). In memory mode a new key per run."""
    if os.environ.get("SLATFF_LOCAL_KEY"):
        return os.environ["SLATFF_LOCAL_KEY"]
    k = None if new else key_store.load()
    if not k:
        k = secrets.token_urlsafe(24)
        key_store.save(k)
    return k


LOCAL_KEY = None          # set in serve()


# --- OIDC ----------------------------------------------------------------------------
# --- DPoP (RFC 9449): tokens bound to a key this bridge holds ---------------------------
# A copied access or refresh token is useless without the private key. Standard library only
# (RSA keygen and RS256 signing in Python), so the bridge still runs anywhere Python 3.9 does.
# The key is created once and kept in the OS secret store. SLATFF_DPOP=off disables it.
DPOP = (SOURCES["dpop"][0] or "on").lower() != "off"     # MDM, environment or config; default on
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
        a = secrets.randbelow(n - 3) + 2
        x = pow(a, d, n)
        if x in (1, n - 1):
            continue
        for _ in range(r - 1):
            x = pow(x, 2, n)
            if x == n - 1:
                break
        else:
            return False
    return True


def _rsa_generate(bits=2048, e=65537):
    def prime():
        while True:
            c = secrets.randbits(bits // 2) | (3 << (bits // 2 - 2)) | 1
            if (c - 1) % e and _probable_prime(c):
                return c
    while True:
        p, q = prime(), prime()
        if p != q and (p * q).bit_length() == bits:
            return {"n": p * q, "e": e, "d": pow(e, -1, (p - 1) * (q - 1))}


def _b64u(b):
    return base64.urlsafe_b64encode(b).rstrip(b"=").decode()


def _int_bytes(i):
    return i.to_bytes((i.bit_length() + 7) // 8, "big")


_dpop_key = None


def dpop_key():
    """The bridge's DPoP key pair, created once and kept in the secret store."""
    global _dpop_key
    if _dpop_key:
        return _dpop_key
    ks = Store(account="dpop-key", name="dpop-key")
    raw = ks.load()
    if raw:
        k = {a: int(v, 16) for a, v in json.loads(raw).items()}
    else:
        k = _rsa_generate()
        ks.save(json.dumps({a: format(v, "x") for a, v in k.items()}))
    _dpop_key = k
    return k


def dpop_jwk():
    k = dpop_key()
    return {"kty": "RSA", "e": _b64u(_int_bytes(k["e"])), "n": _b64u(_int_bytes(k["n"]))}


def _rs256(k, data):
    import hashlib
    size = (k["n"].bit_length() + 7) // 8
    t = bytes.fromhex("3031300d060960864801650304020105000420") + hashlib.sha256(data).digest()
    em = b"\x00\x01" + b"\xff" * (size - len(t) - 3) + b"\x00" + t
    return pow(int.from_bytes(em, "big"), k["d"], k["n"]).to_bytes(size, "big")


def dpop_proof(method, url, access_token=None):
    """DPoP proof JWT for one request (RFC 9449 section 4)."""
    import hashlib
    header = {"typ": "dpop+jwt", "alg": "RS256", "jwk": dpop_jwk()}
    payload = {"jti": secrets.token_urlsafe(16), "htm": method, "htu": url.split("?")[0], "iat": int(time.time())}
    if access_token:
        payload["ath"] = _b64u(hashlib.sha256(access_token.encode()).digest())
    signing_input = (_b64u(json.dumps(header, separators=(",", ":")).encode()) + "." +
                     _b64u(json.dumps(payload, separators=(",", ":")).encode()))
    return signing_input + "." + _b64u(_rs256(dpop_key(), signing_input.encode()))


def post_form(url, data, dpop=False):
    headers = {"Content-Type": "application/x-www-form-urlencoded"}
    if dpop and DPOP:
        headers["DPoP"] = dpop_proof("POST", url)
    req = urllib.request.Request(url, data=urllib.parse.urlencode(data).encode(), headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return r.status, json.loads(r.read() or b"{}")
    except urllib.error.HTTPError as e:
        try:
            return e.code, json.loads(e.read() or b"{}")
        except ValueError:
            return e.code, {}


def claims(token):
    p = token.split(".")[1]
    return json.loads(base64.urlsafe_b64decode(p + "=" * (-len(p) % 4)))


def open_private(url):
    """Open the sign-in page in a private window, so another signed-in user is not reused.
    Safari has no command-line option for this; Chrome, Edge, Brave and Firefox do."""
    if SYSTEM == "Darwin":
        apps = [("Google Chrome", "--incognito"), ("Microsoft Edge", "--inprivate"),
                ("Brave Browser", "--incognito"), ("Firefox", "-private-window")]
        if os.environ.get("SLATFF_BROWSER", "").lower() == "safari":
            apps = []
        for app, flag in apps:
            if os.path.isdir(f"/Applications/{app}.app"):
                subprocess.run(["open", "-na", app, "--args", flag, url], capture_output=True)
                print(f"Opened a private window in {app}.")
                return
        subprocess.run(["pbcopy"], input=url.encode())
        print("Link copied. In Safari: Shift+Cmd+N (private window), then Cmd+V and Return.")
        return
    for exe, flag in (("google-chrome", "--incognito"), ("chromium", "--incognito"),
                      ("msedge", "--inprivate"), ("firefox", "-private-window")):
        if shutil.which(exe):
            subprocess.Popen([exe, flag, url], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            return
    print("No browser with a private mode found; open the link above in a private window.")


def login(open_browser=True, private=False):
    # PKCE (RFC 7636) on the device flow: the code can only be redeemed by this bridge process
    import hashlib
    verifier = secrets.token_urlsafe(48)
    challenge = base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).rstrip(b"=").decode()
    st, d = post_form(f"{ISSUER}/protocol/openid-connect/auth/device", {
        "client_id": CLIENT_ID, "scope": "openid",
        "code_challenge": challenge, "code_challenge_method": "S256"})
    if st != 200:
        die(f"device sign-in refused by Keycloak ({st} {d.get('error', '')})")
    url = d.get("verification_uri_complete") or d["verification_uri"]
    print(f"Open {url} and confirm code {d['user_code']} (valid {d.get('expires_in', 600)} s)")
    if private:
        open_private(url)
    elif open_browser:
        try:
            webbrowser.open(url)
        except Exception:
            pass
    interval, deadline = d.get("interval", 5), time.time() + d.get("expires_in", 600)
    while time.time() < deadline:
        time.sleep(interval)
        st, t = post_form(f"{ISSUER}/protocol/openid-connect/token", dpop=True, data={
            "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
            "device_code": d["device_code"], "client_id": CLIENT_ID, "code_verifier": verifier})
        if st == 200:
            accept(t)
            print(f"Signed in as {_state['user']}. Refresh token stored in: {store.describe()}.")
            return
        err = t.get("error")
        if err == "slow_down":
            interval += 5
        elif err != "authorization_pending":
            die(f"sign-in failed: {err} {t.get('error_description', '')}")
    die("sign-in timed out")


def accept(t, save=True):
    c = claims(t["access_token"])
    with _lock:
        _state.update(access=t["access_token"], exp=c.get("exp", 0), user=c.get("preferred_username"))
        if t.get("refresh_token"):
            _state["refresh"] = t["refresh_token"]
            if save:
                store.save(t["refresh_token"])


def logout():
    """Revoke the refresh token at Keycloak (RFC 7009), which ends the session, then delete it
    locally. A bridge that is still running stops at its next refresh (within 4 minutes)."""
    tok = store.load()
    if tok:
        st, _ = post_form(f"{ISSUER}/protocol/openid-connect/revoke", dpop=True, data={
            "client_id": CLIENT_ID, "token": tok, "token_type_hint": "refresh_token"})
        print("Session ended at Keycloak." if st == 200 else f"Keycloak revoke answered {st}; removing the local token anyway.")
    store.delete()
    print(f"Refresh token removed ({store.describe()}).")


def access_token():
    """A valid access token, refreshed when less than 30 s remain. None if signed out.

    The secret store is the source of truth: if it holds a different refresh token than this
    process (a newer `login`, possibly as another user), the bridge switches to it. A rotated
    token is written back only if the store still holds this process's token, so a running
    bridge never overwrites a newer sign-in."""
    stored = store.load()
    with _lock:
        mine = _state["refresh"]
        if stored and mine and stored != mine:          # newer login happened: adopt it
            _state.update(access=None, exp=0, refresh=stored, user=None)
            mine = stored
        if not stored and mine:                         # logout happened: stop
            _state.update(access=None, exp=0, refresh=None, user=None)
            return None
        if _state["access"] and _state["exp"] - time.time() > 30:
            return _state["access"]
        refresh = mine or stored
    if not refresh:
        return None
    st, t = post_form(f"{ISSUER}/protocol/openid-connect/token", dpop=True, data={
        "grant_type": "refresh_token", "refresh_token": refresh, "client_id": CLIENT_ID})
    if st != 200:          # session ended in Keycloak (revoked, user disabled, timed out)
        with _lock:
            _state.update(access=None, exp=0, refresh=None)
        if store.load() == refresh:
            store.delete()
        return None
    accept(t, save=(store.load() in (refresh, None)))
    return _state["access"]


# --- gateway calls ----------------------------------------------------------------------
def gateway(method, path, body=None):
    """Open a request to the gateway with the user's token. Returns (response, status) or raises."""
    tok = access_token()
    if not tok:
        return None, 401
    headers = {"Authorization": f"Bearer {tok}", "Content-Type": "application/json",
               "X-SLATFF-IDE": IDE, "User-Agent": f"slatff-ide-bridge ({IDE})"}
    if (claims(tok).get("cnf") or {}).get("jkt"):      # DPoP-bound token: prove the key
        headers["Authorization"] = f"DPoP {tok}"
        headers["DPoP"] = dpop_proof(method, GATEWAY + path, tok)
    req = urllib.request.Request(GATEWAY + path, data=body, method=method, headers=headers)
    try:
        up = urllib.request.urlopen(req, timeout=600)
        return up, up.status
    except urllib.error.HTTPError as e:
        return e, e.code


def read_chunks(up):
    while True:
        chunk = up.read1(65536) if hasattr(up, "read1") else up.read(65536)
        if not chunk:
            return
        yield chunk


def sse_deltas(up):
    """Yield content strings from an OpenAI streaming (SSE) response."""
    buf = b""
    for chunk in read_chunks(up):
        buf += chunk
        while b"\n" in buf:
            line, buf = buf.split(b"\n", 1)
            line = line.strip()
            if not line.startswith(b"data:"):
                continue
            data = line[5:].strip()
            if data == b"[DONE]":
                return
            try:
                ch = json.loads(data)["choices"][0]
                yield (ch.get("delta") or {}).get("content") or ""
            except Exception:
                continue


def now_iso():
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


# --- HTTP server for the IDE -----------------------------------------------------------------
class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        sys.stderr.write("bridge: " + fmt % args + "\n")

    # helpers
    def _json(self, code, obj):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _start_chunked(self, code, ctype):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Transfer-Encoding", "chunked")
        self.end_headers()

    def _chunk(self, data):
        if data:
            self.wfile.write(b"%x\r\n%s\r\n" % (len(data), data))
            self.wfile.flush()

    def _end_chunked(self):
        self.wfile.write(b"0\r\n\r\n")

    def _route(self):
        """Check the local key (header or /k/<key> prefix). Returns the path after the prefix, or None."""
        path = self.path.split("?")[0]
        if path.startswith("/k/"):
            parts = path.split("/", 3)
            key = parts[2] if len(parts) > 2 else ""
            path = "/" + (parts[3] if len(parts) > 3 else "")
            return path if secrets.compare_digest(key, LOCAL_KEY) else None
        got = self.headers.get("Authorization", "") or self.headers.get("x-api-key", "") or self.headers.get("api-key", "")
        got = got[7:] if got.startswith("Bearer ") else got
        return path if secrets.compare_digest(got.strip(), LOCAL_KEY) else None

    def _body(self):
        n = int(self.headers.get("Content-Length") or 0)
        return self.rfile.read(n) if n else b""

    def _signed_out(self):
        sys.stderr.write("bridge: refused, not signed in (or Keycloak session ended); run: python3 bridge.py login\n")
        # 403, not 401: Xcode shows the message text for 403 but not for 401
        return self._json(403, {"error": {"message":
            "SLATFF bridge: not signed in, or your Keycloak session has ended. Sign in: python3 bridge.py login",
            "type": "access_denied"}})

    # OpenAI style: pass through
    def _openai(self, method, path):
        up, code = gateway(method, path[len("/v1"):], self._body() if method == "POST" else None)
        if up is None:
            return self._signed_out()
        self._start_chunked(code, up.headers.get("Content-Type", "application/json"))
        try:
            for chunk in read_chunks(up):
                self._chunk(chunk)
            self._end_chunked()
        finally:
            up.close()

    # Ollama style: translate
    def _ollama_tags(self):
        up, code = gateway("GET", "/models")
        if up is None:
            return self._signed_out()
        try:
            data = json.loads(up.read() or b"{}")
        finally:
            up.close()
        if code != 200:
            return self._json(code, data)
        models = [{"name": m["id"], "model": m["id"], "modified_at": now_iso(), "size": 0,
                   "digest": "", "details": {"family": "", "format": "gguf"}} for m in data.get("data", [])]
        self._json(200, {"models": models})

    def _ollama_chat(self, generate=False):
        try:
            req = json.loads(self._body() or b"{}")
        except ValueError:
            return self._json(400, {"error": "body is not JSON"})
        model = req.get("model")
        if generate:
            msgs = ([{"role": "system", "content": req["system"]}] if req.get("system") else []) + \
                   [{"role": "user", "content": req.get("prompt", "")}]
        else:
            msgs = [{"role": m.get("role", "user"), "content": m.get("content", "")} for m in req.get("messages") or []]
        stream = req.get("stream", True)          # Ollama streams by default
        opts = req.get("options") or {}
        out = {"model": model, "messages": msgs, "stream": True}
        for a, b in (("temperature", "temperature"), ("top_p", "top_p"), ("num_predict", "max_tokens"), ("stop", "stop")):
            if a in opts:
                out[b] = opts[a]
        up, code = gateway("POST", "/chat/completions", json.dumps(out).encode())
        if up is None:
            return self._signed_out()
        if code != 200:
            try:
                err = json.loads(up.read() or b"{}")
            finally:
                up.close()
            msg = (err.get("error") or {}).get("message") if isinstance(err.get("error"), dict) else err.get("error")
            return self._json(code, {"error": msg or f"gateway refused ({code})"})
        key = "response" if generate else "message"
        started = time.monotonic()

        def piece(text, done):
            o = {"model": model, "created_at": now_iso(), "done": done}
            o[key] = text if generate else {"role": "assistant", "content": text}
            if done:
                o.update(done_reason="stop", total_duration=int((time.monotonic() - started) * 1e9))
            return o
        try:
            if stream:
                self._start_chunked(200, "application/x-ndjson")
                for text in sse_deltas(up):
                    if text:
                        self._chunk((json.dumps(piece(text, False)) + "\n").encode())
                self._chunk((json.dumps(piece("", True)) + "\n").encode())
                self._end_chunked()
            else:
                self._json(200, piece("".join(sse_deltas(up)), True))
        finally:
            up.close()

    def _dispatch(self, method):
        if self.path == "/healthz":
            access_token()          # reflect a login or logout done since the last request
            return self._json(200, {"ok": True, "signed_in_as": _state["user"], "ide": IDE})
        path = self._route()
        if path is None:
            sys.stderr.write("bridge: refused, wrong or missing local key (headers: %s)\n"
                             % (", ".join(h for h in ("Authorization", "x-api-key", "api-key") if self.headers.get(h)) or "none"))
            return self._json(401, {"error": {"message": "SLATFF bridge: wrong or missing local key"}})
        if method == "GET" and path in ("/", "/api/version"):
            return self._json(200, {"version": "0.0.0-slatff-bridge"})
        if path in ("/v1/models", "/v1/chat/completions"):
            return self._openai(method, path)
        if method == "GET" and path == "/api/tags":
            return self._ollama_tags()
        if method == "POST" and path == "/api/chat":
            return self._ollama_chat()
        if method == "POST" and path == "/api/generate":
            return self._ollama_chat(generate=True)
        if method == "POST" and path == "/api/show":
            return self._json(200, {"details": {"family": "", "format": "gguf"}, "model_info": {}, "capabilities": ["completion"]})
        return self._json(404, {"error": {"message": "SLATFF bridge: not forwarded"}})

    def do_GET(self):
        self._dispatch("GET")

    def do_POST(self):
        self._dispatch("POST")


class Server(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True


def keep_alive(interval=240):
    """Refresh the access token every few minutes, so an idle IDE does not let the Keycloak
    session time out (SSO Session Idle, 30 min by default). Max session length still applies.
    Keeps running when signed out, so a later `login` is picked up."""
    signed_in = bool(_state["user"])
    while True:
        time.sleep(interval)
        with _lock:
            _state["exp"] = 0          # force a refresh on the next call
        now = bool(access_token())
        if signed_in and not now:
            sys.stderr.write("bridge: Keycloak session ended; run: python3 bridge.py login\n")
        elif now and not signed_in:
            print(f"bridge: signed in as {_state['user']}")
        signed_in = now


def serve():
    global LOCAL_KEY
    LOCAL_KEY = local_key()
    if access_token():
        print(f"Signed in as {_state['user']} (IDE label: {IDE}). Token store: {store.describe()}.")
    else:
        print("Not signed in yet. Run: python3 bridge.py login  (requests are refused until then)")
    threading.Thread(target=keep_alive, daemon=True).start()
    base = f"http://127.0.0.1:{PORT}"
    shown = LOCAL_KEY if sys.stdout.isatty() or os.environ.get("SLATFF_LOCAL_KEY") else "<key>"
    if shown == "<key>":
        print("(not a terminal, so the key is not written here; show it with: python3 bridge.py key)")
    print("Settings for your IDE (the key stays the same across restarts):")
    print(f"  Xcode:          Intelligence > Add a Chat Provider > Internet Hosted, URL {base},")
    print(f"                  API Key {shown}, API Key Header x-api-key")
    print(f"  Visual Studio:  Copilot Chat > Manage Models > OpenAI, custom endpoint {base}/v1,")
    print(f"                  API key {shown}   (or Ollama provider, endpoint {base}/k/{shown})")
    print(f"  Qt Creator:     Qt AI Assistant > custom/Ollama LLM, URL {base}/k/{shown}")
    print(f"  Any other:      OpenAI base URL {base}/k/{shown}/v1  or Ollama URL {base}/k/{shown}")
    try:
        srv = Server(("127.0.0.1", PORT), Handler)
    except OSError:
        die(f"Port {PORT} is in use, probably by another bridge. Stop it (Ctrl+C in its window, or: "
            f"lsof -ti tcp:{PORT} | xargs kill) and start again.")
    srv.serve_forever()


def configure(args):
    cfg = load_config()
    it = iter(args)
    for a in it:
        if a in ("--issuer", "--gateway", "--ide", "--port", "--client-id"):
            key, value = a[2:].replace("-", "_"), next(it, "")
            if key in _managed:
                print(f"not changed: {key} is set by your organisation (MDM) to {_managed[key]}")
                continue
            cfg[key] = value
    if "port" in cfg:
        cfg["port"] = int(cfg["port"])
    os.makedirs(config_dir(), exist_ok=True)
    with open(CONFIG_FILE, "w") as f:
        json.dump(cfg, f, indent=2)
    print(f"saved {CONFIG_FILE}: {cfg}")


def show_config():
    """Effective settings and where each comes from."""
    for key, (value, source) in SOURCES.items():
        print(f"{key:10} {value or '-':55} {source}")
    print(f"{'token':10} {store.describe()}")


def show_key(args):
    if args[:1] == ["new"]:
        local_key(new=True)
        print("New local key stored (not shown). Restart the bridge or the agent, then copy it to")
        print("the IDE with: python3 bridge.py key | pbcopy")
        return
    print(local_key())


def agent(args):
    """macOS LaunchAgent: copies bridge.py and the settings to ~/Library/Application Support/slatff,
    starts it at login and restarts it if it stops. Log: ~/Library/Logs/slatff-ide-bridge.log"""
    if SYSTEM != "Darwin":
        die("agent is macOS only. Windows: Task Scheduler; Linux: a systemd user unit (docs/IDE-BRIDGE.md).")
    import plistlib
    sub = args[0] if args else "status"
    plist = os.path.expanduser(f"~/Library/LaunchAgents/{AGENT_LABEL}.plist")
    domain = f"gui/{os.getuid()}"
    org_plist = f"/Library/LaunchAgents/{AGENT_LABEL}.plist"
    if sub in ("install", "uninstall") and os.path.exists(org_plist):
        die(f"The bridge agent is installed by your organisation ({org_plist}). "
            "It starts at login for every user; nothing to install here.")
    if sub == "status":
        r = subprocess.run(["launchctl", "print", f"{domain}/{AGENT_LABEL}"], capture_output=True, text=True)
        if r.returncode != 0:
            print("agent not loaded")
        else:
            seen = set()
            for line in r.stdout.splitlines():
                k = line.strip().split(" =")[0]
                if k in ("state", "pid", "last exit code") and k not in seen:
                    seen.add(k)
                    print(line.strip())
        return
    subprocess.run(["launchctl", "bootout", f"{domain}/{AGENT_LABEL}"], capture_output=True)
    if sub == "uninstall":
        if os.path.exists(plist):
            os.remove(plist)
        print("agent removed (sign-in and local key stay in the Keychain; use logout to end the session)")
        return
    if sub != "install":
        die("usage: bridge.py agent install | uninstall | status")
    if not ISSUER or not GATEWAY:
        die("Not configured. Run configure first.")
    cfg = load_config()
    cfg.update(issuer=ISSUER, gateway=GATEWAY, client_id=CLIENT_ID, port=PORT, ide=IDE)
    os.makedirs(config_dir(), exist_ok=True)
    with open(CONFIG_FILE, "w") as f:
        json.dump(cfg, f, indent=2)
    target = os.path.join(config_dir(), "bridge.py")
    if os.path.abspath(__file__) != target:
        shutil.copyfile(os.path.abspath(__file__), target)
    log = os.path.expanduser("~/Library/Logs/slatff-ide-bridge.log")
    os.makedirs(os.path.dirname(plist), exist_ok=True)
    with open(plist, "wb") as f:
        plistlib.dump({
            "Label": AGENT_LABEL,
            "ProgramArguments": ["/usr/bin/python3", target, "serve"],
            "EnvironmentVariables": {"PYTHONUNBUFFERED": "1"},
            "RunAtLoad": True,
            "KeepAlive": True,
            "ThrottleInterval": 30,
            "LimitLoadToSessionType": "Aqua",
            "ProcessType": "Background",
            "StandardOutPath": log,
            "StandardErrorPath": log,
        }, f)
    local_key()                      # create the key now, so it can be shown
    r = subprocess.run(["launchctl", "bootstrap", domain, plist], capture_output=True, text=True)
    if r.returncode != 0:
        die(f"launchctl bootstrap failed: {r.stderr.strip()}")
    print(f"agent installed: {plist}")
    print(f"log: {log}")
    print("local key: python3 bridge.py key")


def selftest_store():
    s = Store()
    probe = "selftest-" + secrets.token_hex(8)
    s.save(probe)
    ok = s.load() == probe
    s.delete()
    gone = s.load() is None
    print(f"store {s.describe()}: save/load {'OK' if ok else 'FAILED'}, delete {'OK' if gone else 'FAILED'}")
    sys.exit(0 if ok and gone else 1)


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else "serve"
    if cmd == "configure":
        configure(sys.argv[2:])
        sys.exit(0)
    if cmd == "selftest-store":
        selftest_store()
    if cmd == "key":
        show_key(sys.argv[2:])
        sys.exit(0)
    if cmd == "config":
        show_config()
        sys.exit(0)
    if not ISSUER or not GATEWAY:
        die("Not configured. Run: python3 bridge.py configure --issuer https://id.<domain>/realms/slatff "
            "--gateway https://ai.<domain>/gateway/v1")
    if cmd == "login":
        login(private=len(sys.argv) > 2 and sys.argv[2] == "private")
    elif cmd == "logout":
        logout()
    elif cmd == "serve":
        serve()
    elif cmd == "agent":
        agent(sys.argv[2:])
    elif cmd == "login-and-serve":      # tests
        login(open_browser=False)
        serve()
    else:
        die(__doc__)
