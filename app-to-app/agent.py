#!/usr/bin/env python3
"""SLATFF.Cloud app-to-app demo (step 8): app A gets access to app B for the signed-in user.

Identity Assertion JWT Authorization Grant (ID-JAG),
draft-ietf-oauth-identity-assertion-authz-grant-06:

  1. The user signs in to app A ("notes-agent") at the company IdP (realm "slatff").
     Device code, so it runs in a terminal. App A gets an ID token.
  2. App A asks the IdP for an ID-JAG for app B's authorization server (realm "apps").
     Token exchange (RFC 8693), requested_token_type id-jag. The IdP applies its policy.
  3. App A presents the ID-JAG to app B's token endpoint (JWT bearer grant, RFC 7523)
     and gets an access token for app B.
  4. App A calls app B's API (notes-api) with that token.

Then it runs the refusal checks. Tokens are never printed, only their claims.
Python 3.9+ standard library only.

Environment (set by scripts/mac-step8-app-to-app.sh):
  IDP_URL           realm "slatff" base URL reachable from here, e.g. http://keycloak:8080/realms/slatff
  APPS_URL          realm "apps" base URL reachable from here
  APPS_ISSUER       issuer of realm "apps" (public URL), the ID-JAG audience
  RESOURCE          resource identifier of the notes API
  NOTES_URL         notes API, e.g. http://notes-api:8080/notes
  AGENT_SECRET      secret of client notes-agent in realm slatff
  APPS_AGENT_SECRET secret of client notes-agent in realm apps
  OTHER_SECRET      secret of client other-app in realm apps
Usage: python3 agent.py demo            all checks for a user with role ai-user
       python3 agent.py demo-denied     for a user without the role (expects access_denied)
"""
import base64
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

ID_JAG = "urn:ietf:params:oauth:token-type:id-jag"
ID_TOKEN = "urn:ietf:params:oauth:token-type:id_token"
TOKEN_EXCHANGE = "urn:ietf:params:oauth:grant-type:token-exchange"
JWT_BEARER = "urn:ietf:params:oauth:grant-type:jwt-bearer"

E = os.environ.get
IDP = E("IDP_URL", "").rstrip("/")
APPS = E("APPS_URL", "").rstrip("/")
APPS_ISSUER = E("APPS_ISSUER", "").rstrip("/")
RESOURCE = E("RESOURCE", "")
NOTES = E("NOTES_URL", "")
CLIENT = "notes-agent"

fails = 0


def post(url, data):
    req = urllib.request.Request(url, data=urllib.parse.urlencode(data, doseq=True).encode(),
                                 headers={"Content-Type": "application/x-www-form-urlencoded"})
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return r.status, json.loads(r.read() or b"{}")
    except urllib.error.HTTPError as e:
        try:
            return e.code, json.loads(e.read() or b"{}")
        except ValueError:
            return e.code, {}


def get(url, token):
    req = urllib.request.Request(url, headers={"Authorization": f"Bearer {token}"})
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return r.status, json.loads(r.read() or b"{}")
    except urllib.error.HTTPError as e:
        try:
            return e.code, json.loads(e.read() or b"{}")
        except ValueError:
            return e.code, {}


def part(token, i):
    p = token.split(".")[i]
    return json.loads(base64.urlsafe_b64decode(p + "=" * (-len(p) % 4)))


def check(ok, name, detail=""):
    global fails
    print(("PASS " if ok else "FAIL ") + name + (f"  ({detail})" if detail else ""))
    if not ok:
        fails += 1


def err(body):
    return f"{body.get('error', '')}: {body.get('error_description', '')}".strip(": ")


def login():
    st, d = post(f"{IDP}/protocol/openid-connect/auth/device",
                 {"client_id": CLIENT, "client_secret": E("AGENT_SECRET"), "scope": "openid"})
    if st != 200:
        sys.exit(f"device sign-in refused ({st} {err(d)})")
    print(f"\nOpen {d.get('verification_uri_complete') or d['verification_uri']}")
    print(f"and confirm code {d['user_code']}. Use a private window to choose the user.\n")
    interval, deadline = d.get("interval", 5), time.time() + d.get("expires_in", 600)
    while time.time() < deadline:
        time.sleep(interval)
        st, t = post(f"{IDP}/protocol/openid-connect/token", {
            "grant_type": "urn:ietf:params:oauth:grant-type:device_code", "device_code": d["device_code"],
            "client_id": CLIENT, "client_secret": E("AGENT_SECRET")})
        if st == 200:
            return t
        if t.get("error") == "slow_down":
            interval += 5
        elif t.get("error") != "authorization_pending":
            sys.exit(f"sign-in failed: {err(t)}")
    sys.exit("sign-in timed out")


def id_jag(subject, audience=None, scope="notes.read notes.write", resource=None, subject_type=ID_TOKEN):
    data = {"grant_type": TOKEN_EXCHANGE, "requested_token_type": ID_JAG,
            "client_id": CLIENT, "client_secret": E("AGENT_SECRET"),
            "subject_token": subject, "subject_token_type": subject_type,
            "audience": audience if audience is not None else APPS_ISSUER}
    if scope:
        data["scope"] = scope
    r = RESOURCE if resource is None else resource
    if r:
        data["resource"] = r
    return post(f"{IDP}/protocol/openid-connect/token", data)


def redeem(assertion, client=CLIENT, secret=None, scope="notes.read"):
    return post(f"{APPS}/protocol/openid-connect/token", {
        "grant_type": JWT_BEARER, "assertion": assertion, "scope": scope,
        "client_id": client, "client_secret": secret or E("APPS_AGENT_SECRET")})


def demo(expect_denied=False):
    t = login()
    idt = t.get("id_token")
    if not idt:
        sys.exit("no ID token returned (scope openid missing?)")
    c = part(idt, 1)
    print(f"Signed in as {c.get('preferred_username')} (ID token aud {c.get('aud')}).")

    print("\n--- 1. IdP issues an ID-JAG (token exchange)")
    st, r = id_jag(idt)
    if expect_denied:
        check(st == 403 and r.get("error") == "access_denied", "IdP refuses a user without the required role",
              f"{st} {err(r)}")
        return
    check(st == 200, "ID-JAG issued", f"{st} {err(r)}" if st != 200 else "")
    if st != 200:
        return
    jag = r["access_token"]
    h, j = part(jag, 0), part(jag, 1)
    print("     response:", {k: r.get(k) for k in ("issued_token_type", "token_type", "expires_in", "scope")})
    print("     ID-JAG header:", {k: h.get(k) for k in ("typ", "alg", "kid")})
    print("     ID-JAG claims:", {k: j.get(k) for k in ("iss", "sub", "aud", "client_id", "scope", "resource",
                                                       "preferred_username")})
    check(r.get("issued_token_type") == ID_JAG and r.get("token_type") == "N_A", "issued_token_type id-jag, token_type N_A")
    check(h.get("typ") == "oauth-id-jag+jwt" and h.get("alg") == "RS256", "header typ oauth-id-jag+jwt, RS256")
    check(j.get("aud") == APPS_ISSUER, "aud is app B's issuer")
    check(j.get("client_id") == CLIENT, "client_id is app A's client at app B")
    check(all(j.get(k) for k in ("iss", "sub", "jti", "iat", "exp")), "iss, sub, jti, iat, exp present")
    check(j["exp"] - j["iat"] <= 300, "lifetime at most 300 s")
    check(j.get("scope") == "notes.read", "scope narrowed by IdP policy (notes.write dropped)", j.get("scope"))
    if RESOURCE:
        check(j.get("resource") == RESOURCE, "resource kept exactly as sent")

    print("\n--- 2. App B's authorization server exchanges it (JWT bearer grant)")
    st, a = redeem(jag)
    check(st == 200, "access token from app B", f"{st} {err(a)}" if st != 200 else "")
    if st != 200:
        return
    at = part(a["access_token"], 1)
    print("     app B token:", {k: at.get(k) for k in ("iss", "aud", "azp", "preferred_username", "scope")})
    check(at.get("iss") == APPS_ISSUER, "issued by app B (realm apps), not by the IdP")

    print("\n--- 3. App A calls app B's API")
    st, n = get(NOTES, a["access_token"])
    check(st == 200, "notes API answers for the user", f"{st} {n.get('user')}, {len(n.get('notes', []))} notes")

    print("\n--- 4. refusals")
    st, x = redeem(jag)
    check(st >= 400, "same ID-JAG used twice is refused", f"{st} {err(x)}")
    st, r2 = id_jag(idt)
    if st == 200:
        st, x = redeem(r2["access_token"], client="other-app", secret=E("OTHER_SECRET"))
        check(st >= 400, "ID-JAG presented by another client is refused (client_id)", f"{st} {err(x)}")
    st, r3 = id_jag(idt)
    if st == 200:
        p = r3["access_token"].split(".")
        bad = p[0] + "." + p[1] + "." + ("A" if p[2][0] != "A" else "B") + p[2][1:]
        st, x = redeem(bad)
        check(st >= 400, "tampered ID-JAG is refused", f"{st} {err(x)}")
    st, x = id_jag(idt, audience="https://untrusted.example/realms/x")
    check(st == 400 and x.get("error") == "invalid_target", "untrusted audience: invalid_target", f"{st} {err(x)}")
    st, x = id_jag(idt, audience=[APPS_ISSUER, "https://second.example"])
    check(st == 400 and x.get("error") == "invalid_request", "two audiences: invalid_request", f"{st} {err(x)}")
    st, x = id_jag(t["access_token"])
    check(st == 400, "access token as subject_token is refused", f"{st} {err(x)}")
    st, x = id_jag(idt, resource="https://not-allowed.example/api")
    check(st == 400 and x.get("error") == "invalid_target", "resource not allowed: invalid_target", f"{st} {err(x)}")
    st, x = get(NOTES, t["access_token"])
    check(st == 401, "notes API refuses the IdP's own token", f"{st}")

    print("\n--- 5. known gap check (Keycloak as app B)")
    st, r4 = id_jag(idt, scope="notes.read")
    if st == 200:
        st, a2 = redeem(r4["access_token"], scope="notes.read notes.write")
        got = set((a2.get("scope") or "").split()) if st == 200 else set()
        if "notes.write" in got:
            print("KNOWN GAP app B granted notes.write although the ID-JAG only carried notes.read "
                  "(Keycloak takes scope from the request, not from the ID-JAG)")
        else:
            check(True, "app B does not grant more scope than the ID-JAG carries", f"{st} {sorted(got)}")


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else "demo"
    if not all([IDP, APPS, APPS_ISSUER, NOTES, E("AGENT_SECRET")]):
        sys.exit(__doc__)
    if cmd == "demo":
        demo()
    elif cmd == "demo-denied":
        demo(expect_denied=True)
    else:
        sys.exit(__doc__)
    print(f"\n{'all checks passed' if fails == 0 else str(fails) + ' check(s) failed'}")
    sys.exit(1 if fails else 0)
