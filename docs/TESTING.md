# Testing checklist

Ticked = run, with date. Unticked = not verified.

Versions: Keycloak 26.5.7, PostgreSQL 17, Open WebUI v0.13.4, Ollama 0.40.16, Caddy 2.11.9,
Docker 29.9.3 / Compose v5.7.0, macOS 27.3, Apple M5 Max.

## Static

- [x] Realm file parses; scripts pass `bash -n`; `docker compose config` valid with all profiles (20 Nov 2026)

## Network

- [x] Certificates for `id` and `ai` from Let's Encrypt (23 Nov 2026)
- [ ] Names resolve from a second device
- [ ] Trusted certificate on a phone or tablet

## Core

- [x] `bootstrap.sh` writes `.env` (20 Nov 2026)
- [x] `docker compose up -d --build` starts postgres, keycloak, caddy, open-webui (23 Nov 2026)
- [x] Realm imported, placeholders substituted (23 Nov 2026)
- [x] Container reaches native Ollama at `host.docker.internal:11434` (20 Nov 2026)
- [x] User without a role refused at sign-in, no account created (23 Nov 2026)
- [x] Password form and sign-up off (23 Nov 2026)
- [ ] `create-demo-user.sh` sets a working password
- [ ] First sign-in as ai-admin gets admin functions
- [ ] Removing a group refuses the user at next sign-in
- [ ] Sign-out returns to the AI workspace (post-logout URIs added 23 Nov 2026)
- [ ] Sign-in and chat from a second device
- [ ] Port 11434 not reachable from a second device

## Model gateway

- [x] Live token: permitted request answered (23 Nov 2026, 849 ms)
- [x] Live: BOARD-ONLY for ai-user, model outside policy, no token: all refused (23 Nov 2026)
- [x] Open WebUI through the gateway; carol and alice in the audit by name (23 Nov 2026)
- [x] Known gap confirmed: Ollama reachable directly from a container (23 Nov 2026)

## Knowledge demo

- [ ] Same question, different answers for alice and carol
- [ ] Board papers shared with ai-users by mistake: gateway refuses alice

## Delegation (step 5)

- [x] Live: token exchange, tool call 200 with BOARD-ONLY withheld, user token refused at tool, exchanged token refused at gateway, other audience refused, audit chain (25 Nov 2026)
- [ ] As carol: BOARD-ONLY documents returned

## IDE bridge (step 6)

- [x] `mac-step6-ide-bridge.sh`: gateway model list, chat without token 401, tool path not published, device sign-in offered (25 Nov 2026)
- [ ] CI secret store on Windows and Linux
- [x] `bridge.py login` on macOS: device code, consent screen, token in Keychain (25 Nov 2026)
- [x] Xcode 27 (Internet Hosted provider): models listed, requests allowed, audit shows carol, `ide-bridge`, `xcode` (25 Nov 2026)
- [x] Xcode: unknown label (TOP-SECRET) refused by the gateway, message shown in Xcode with the user name (25 Nov 2026)
- [x] Xcode as alice: BOARD-ONLY refused (25 Nov 2026)
- [x] `logout` revokes the session at Keycloak (25 Nov 2026)
- [ ] Visual Studio 2026 (parked: no Windows machine; testers wanted, see IDES.md)
- [ ] Qt Creator (parked: testers wanted, see IDES.md)
- [x] bob (no role): Keycloak device sign-in succeeds, gateway returns an empty model list, Xcode shows "Unable to load models" (25 Nov 2026)
- [x] Session ended in Keycloak (admin console sign-out): bridge detects it within 4 min, Xcode requests refused (25 Nov 2026)
- [x] Offline: `bash ide-bridge/tests/run.sh` passes 40 checks incl. stable key, start without sign-in, managed settings (25 Nov 2026)
- [x] Local key unchanged after an agent restart; Xcode kept working without a new key (25 Nov 2026)
- [x] `agent install`: agent running, signed in as carol, Xcode chat answered with llama3.2:3b (25 Nov 2026)
- [ ] Agent still running after logout/login of the Mac user
- [x] After `logout`, Xcode shows "SLATFF bridge: not signed in, or your Keycloak session has ended" (25 Nov 2026)
- [x] After `login`, Xcode works again without restarting the agent (25 Nov 2026)
- [ ] `agent uninstall` removes it; port 11435 free afterwards

## App-to-app access, ID-JAG (step 8)

- [x] Offline: `bash app-to-app/tests/run.sh` (fake IdP and app B, real notes API) (25 Nov 2026)
- [x] CI builds the extension against Keycloak 26.8.2 (PR #3, 25 Nov 2026)
- [x] Keycloak upgrade 26.5 to 26.8.2, database backup taken (25 Nov 2026)
- [x] Steps 5, 6 and 8 re-run on 26.8.2: all PASS (25 Nov 2026, 12:06)
- [x] Extension loaded (Keycloak log names `slatff-id-jag`) (25 Nov 2026)
- [x] Live as alice: ID-JAG issued (typ, aud, client_id, scope narrowed), app B token, notes returned (25 Nov 2026)
- [x] Live refusals: reuse, other client, tampered, untrusted audience, two audiences, access token as subject, resource not allowed, IdP token at notes-api (25 Nov 2026)
- [x] Live as bob: `access_denied` (user does not have role ai-user) (25 Nov 2026)
- [x] Known gap confirmed: Keycloak as app B granted notes.write although the ID-JAG carried only notes.read (25 Nov 2026)

## IDE bridge with MDM (part B, steps 3 and 4)

- [ ] `make-mdm-files.py` output: profiles upload to Jamf without errors
- [ ] Settings profile installed: `bridge.py config` shows issuer, gateway, IDE as `managed`
- [ ] `configure --issuer ...` does not change a managed setting
- [ ] Jamf install script: bridge in `/Library/Application Support/SLATFF`, agent running for the console user, user agent replaced
- [ ] User signs in once, Xcode works through the managed bridge
- [ ] `agent install` as user refused while the organisation's agent is installed
- [ ] Uninstall script removes both
- [ ] `CodingAssistantAllowExternalIntegrations` false: what Xcode shows, provider, agents
- [ ] `IDEProhibitOnDeviceModelInteraction` true: effect, if any
- [ ] Can MDM preset the chat provider or "Allow external agents"? (no documented key yet)

## Passkeys and DPoP (step 9)

- [x] Offline gateway: 11 DPoP checks (stolen token as Bearer, no proof, replay, other key, other URL, other method, old proof, other token, unbound token from ide-bridge refused; valid proof and Open WebUI Bearer allowed) (26 Nov 2026)
- [x] Offline bridge: all requests DPoP-bound, incl. refresh (26 Nov 2026)
- [x] Keycloak offers RS256 for DPoP; ide-bridge requires bound tokens (26 Nov 2026)
- [x] Live: bridge signs in again, Xcode works, audit shows "dpop": true (carol, llama3.2:3b, 26 Nov 2026 09:02)
- [ ] Live: copied access token from the bridge refused at the gateway
- [x] Passkey set up for alice in Safari (Touch ID, Apple Passwords); sign-in with passkey, no password (26 Nov 2026)
- [ ] Passkey from another device (iPhone, hybrid)

## Agents acting for a user (step 10)

- [x] Offline gateway: 10 agent checks (allowed model, model not allowed for the agent, user without role, agent not in policy, agent alone, act/azp mismatch, may_act token, no tool calls, model list, audit with user and agent) (26 Nov 2026)
- [x] Offline agent: fake Keycloak with the 26.8 delegation rules, real gateway; demo, kill switch, bob refused (26 Nov 2026; also on the Mac in Docker, python:3.12-slim)
- [x] Live: features on, delegation scopes copied into the realm, clients and permission created, agent key in the Keychain (26 Nov 2026)
- [x] Live: consent screen, user token with may_act, private_key_jwt sign-in (alice, 26 Nov 2026 09:36)
- [x] Live: delegated token with act, gateway allows the agent's model and refuses the other, audit shows user and agent (26 Nov 2026)
- [x] Live: refusals (agent alone, user token, no actor_token, rogue-agent, other key) (26 Nov 2026)
- [x] Live: kill switch A (permission off, then refresh) and B (session ended) (26 Nov 2026)
- [x] Live: bob refused, agent gets no roles for him (26 Nov 2026 09:39)

## Hardening (scripts/harden.sh, docs/THREATS.md)

- [x] Master realm brute-force protection on (10 failures); personal admin signs in with authenticator app (26 Nov 2026 09:51)
- [x] Settings applied: slatff brute force 10, password policy, admin-cli password grant off, rogue-agent disabled (26 Nov 2026, read back by the script)
- [ ] Password grant refused for admin-cli in slatff (curl returns unauthorized_client)
- [ ] Password policy rejects a short password
- [ ] Step 10 still passes with rogue-agent off between runs
- [ ] Through the tunnel: /realms/master returns 403

## Files


- [ ] Profile starts (check `NEXTCLOUD_TAG` exists)
- [ ] `setup-files.sh` configures `user_oidc`
- [ ] files-users admitted, others refused; group mirrored
- [ ] Break-glass `ncadmin`
- [ ] App password in Apple clients; Keycloak token on WebDAV

## Meetings

- [ ] Profile starts; `https://meet.<domain>` loads
- [ ] Host signs in via Keycloak; guest waits in lobby
- [ ] Audio and video between two devices

## Remote access

- [ ] Tunnel healthy; sites and sign-in work on mobile data
- [ ] `/admin` 403 through the tunnel, works locally

## Platform SSO

- [x] Release asset names and checksum verified (21 Nov 2026, Linux; signature step not run)
- [ ] `get-psso-extension.sh` passes all checks on a Mac
- [ ] Keycloak starts with `declarative-ui` and the extension
- [ ] Association file served
- [ ] Managed Mac with direct downloads accepts the domain
- [ ] Mac registers and signs in

## Mac AI governance (lab)

- [ ] Claude "Install as app": signing of the installed app (`codesign -dvvv`)
- [ ] Its permission levels vs macOS 27.3 privacy prompts
- [ ] `app.settings` DeniedBinaries / AllowedBinaries with Claude's team ID (supervised Mac)
- [ ] `CodingAssistantAllowExternalIntegrations` = false turns the Xcode assistant off
- [ ] Xcode 27 agent filesystem layer: what is blocked and logged
- [ ] Admin-deployed skills in `/Library/Application Support/ClaudeCode/.claude/skills`
- [ ] New PPPC keys once the 27.3 schema is published
