# App-to-app access (step 8)

App A gets access to app B's API for the signed-in user, without a second sign-in and without
app B trusting app A directly. The company IdP decides. Standard: Identity Assertion JWT
Authorization Grant (ID-JAG), draft-ietf-oauth-identity-assertion-authz-grant-06.

## Flow

```
user signs in to app A (notes-agent) at realm slatff        -> ID token (aud notes-agent)
app A -> realm slatff: token exchange (RFC 8693),
         requested_token_type id-jag, audience = realm apps   -> ID-JAG (typ oauth-id-jag+jwt)
app A -> realm apps: JWT bearer grant (RFC 7523), assertion   -> access token from realm apps
app A -> notes-api with that token                             -> the user's notes
```

| Role in the draft | Here |
|---|---|
| IdP Authorization Server | Keycloak realm `slatff` + extension `slatff-id-jag-issuer` |
| Client (app A) | `notes-agent`, demo client `app-to-app/agent.py` |
| Resource Authorization Server (app B) | Keycloak realm `apps`, feature `identity-assertion-jwt` (experimental) |
| Resource Server | `notes-api` |

Keycloak 26.8.2 can receive ID-JAGs but not issue them. The issuer is a Keycloak extension in
`keycloak/extensions/id-jag-issuer`: a token exchange provider that signs with the realm's RS256
key, so `iss` is the realm and keys are at its `jwks_uri`.

## Policy (IdP side)

Attributes on the requesting client in realm `slatff`:

| Attribute | Demo value | Effect |
|---|---|---|
| `id-jag.audiences` | `https://<ID_HOST>/realms/apps` | only these Resource AS; else `invalid_target` |
| `id-jag.scopes` | `notes.read` | other requested scopes are dropped |
| `id-jag.resources` | `https://<AI_HOST>/notes` | other resources: `invalid_target` |
| `id-jag.required-role` | `ai-user` | else `access_denied` |
| `id-jag.lifespan` | `300` | seconds |
| `id-jag.client-id` | (not set) | client id at the Resource AS, default the same |

The IdP also checks: client authenticated, subject token is an ID token from this realm for
this client, not expired, user enabled, user session still active, exactly one audience.

## Run

```sh
cd ~/SLATFF.Cloud/slatff-cloud
bash scripts/mac-step8-app-to-app.sh
```

1. Creates the three client secrets in `.env`.
2. Backs up the Keycloak database to `backups/`.
3. Sets `KEYCLOAK_VERSION=26.8.2`, adds `identity-assertion-jwt` to `KC_FEATURES`.
4. Builds the extension (Maven in Docker) into `keycloak/providers/`.
5. Restarts Keycloak, sets up both realms (`scripts/kc-apply-app-to-app.sh`), starts `notes-api`.
6. Runs the demo. Sign in as alice or carol in a private window.

Again, or as bob (no `ai-user`): `bash scripts/app-to-app-demo.sh demo` or `demo-denied`.

Undo the upgrade: stop Keycloak, restore the backup with `psql`, set `KEYCLOAK_VERSION=26.5`.

## Checks (agent.py)

ID-JAG issued with header `typ` `oauth-id-jag+jwt`, RS256, `aud` realm apps, `client_id`,
`jti`, `iat`, `exp` (300 s), scope narrowed, resource kept; app B token from realm apps; notes
returned. Refused: same ID-JAG twice, ID-JAG from another client, tampered ID-JAG, untrusted
audience, two audiences, access token as subject, resource not allowed, IdP token at notes-api,
bob (no role).

Offline: `bash app-to-app/tests/run.sh` (fake IdP and app B, real notes API, in CI). CI also
builds the extension against Keycloak 26.8.2.

## Result, 25 Nov 2026 (Keycloak 26.8.2)

| Check | Result |
|---|---|
| Extension loaded | `slatff-id-jag` in the Keycloak log |
| ID-JAG for alice | `typ` `oauth-id-jag+jwt`, RS256, `aud` realm apps, `client_id` notes-agent, scope `notes.read` (notes.write dropped), resource kept |
| App B token | issued by realm apps, `azp` notes-agent, user alice |
| Notes API | 200, alice's notes |
| Same ID-JAG twice | 400 "Token reuse detected" |
| ID-JAG from other-app | 400 client_id mismatch |
| Tampered ID-JAG | 400 "Invalid signature" |
| Untrusted audience / two audiences | 400 `invalid_target` / `invalid_request` |
| Access token as subject | 400, typ Bearer is not an ID token |
| Resource not allowed | 400 `invalid_target` |
| IdP token at notes API | 401 |
| bob (no ai-user) | 403 `access_denied` at the IdP |
| Scope at app B | gap confirmed: notes.write granted |

## Gaps

- Confirmed 25 Nov 2026: Keycloak's receiver grants the scope asked for at app B, not the ID-JAG's.
  Workaround until Keycloak fixes it: give app B's client only the scopes the IdP may grant.
- Keycloak's receiver follows draft -01; the issuer follows draft -06.
- Users must exist in realm `apps` and be linked to their `slatff` account (the script does it).
- Not done: `identity_chaining_requested_token_types_supported` in the IdP metadata, refresh
  token as subject, SAML subject, multi-tenant (`tenant`), DPoP.
- Experimental Keycloak feature: not for production.
