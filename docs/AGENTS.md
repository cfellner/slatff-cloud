# Agents acting for a user (step 10)

An agent works for a signed-in user. Every token it uses says who the user is (`sub`) and which
agent is acting (`act`). The agent can never do more than the user may, and never more than the
agent may. The user approves the agent at sign-in, and an admin can stop it.

Standards: RFC 8693 Token Exchange with `actor_token` and the `act` claim; RFC 7523 client
authentication with a private key (`private_key_jwt`); RFC 7636 PKCE; RFC 8252 loopback redirect.
Keycloak 26.8 preview features `token-exchange-delegation` and `parameterized-scopes`.

## Flow

```
user signs in to agent-console, scope delegation:client:research-agent
  Keycloak: consent screen "Allow research-agent to act on your behalf?"
  Keycloak: research-agent has the "delegate" permission (fine-grained admin permissions v2)
  -> user token with may_act {sub: agent's service account, client_id: research-agent}
agent signs in as itself: client credentials, private_key_jwt (key in the Mac's Keychain)
  -> agent token
agent -> Keycloak: token exchange, subject_token = user token, actor_token = agent token
  -> delegated token: sub = user, act = {sub, client_id: research-agent}, aud model-gateway,
     roles = user's roles limited to ai-user, 120 s, no refresh token
agent -> model gateway with the delegated token
  gateway: user's roles allow the model AND policy.json "agents" allows it for this agent
  audit: "user": "alice", "act": ["research-agent"]
```

| Part | Here |
|---|---|
| User's sign-in client | `agent-console`: public, PKCE, redirect `http://127.0.0.1:8766/callback`, consent required |
| Agent | `research-agent`: service account, standard token exchange on, `private_key_jwt`, full scope off, realm role `ai-user` mapped, audience `model-gateway`, tokens 120 s |
| Permission | "research-agent may act for users": resource type Users, scope `delegate`, client policy for `research-agent` |
| Agent not approved | `rogue-agent`: has a secret and token exchange, no permission |
| Demo agent | `agents/agent.py` (Python standard library only) |
| Enforcement | Model gateway: `agent_check` and policy.json `agents` |

## Run

```sh
cd ~/SLATFF.Cloud/slatff-cloud
bash scripts/mac-step10-agents.sh
```

1. Creates `ROGUE_AGENT_SECRET` in `.env`, backs up the Keycloak database to `backups/`.
2. Adds `token-exchange-delegation,parameterized-scopes` to `KC_FEATURES`, restarts Keycloak.
3. Creates the agent's RSA key in the Keychain (`cloud.slatff.agent`, account
   `research-agent-signing-key`). Only the public key is sent to Keycloak.
4. Sets up the clients and the permission (`scripts/kc-apply-agents.sh`).
5. Rebuilds the model gateway.
6. Runs the demo with the kill switch. The browser opens: sign in as alice or carol and answer
   Yes on the consent screen. The kill switch ends that user's Keycloak sessions at the end.

Other runs: `bash scripts/mac-step10-agents.sh demo` (no kill switch),
`bash scripts/mac-step10-agents.sh demo-denied` (sign in as bob).

Offline: `bash agents/tests/run.sh` (fake Keycloak with the 26.8 rules, real gateway) and the
agent section of `bash model-gateway/tests/run.sh`.

## Checks (agent.py)

User token carries `may_act` for the agent and the agent in `aud`. Agent signs in with its key;
another key is refused. Refused: agent alone at the gateway, user token at the gateway, exchange
without `actor_token`, an agent the user did not approve. Delegated token: `sub` is the user,
`act` names the agent, no `may_act`, audience `model-gateway`, `azp` the agent, no refresh
token, at most 300 s. Gateway: allowed model works; a model the user may use but the agent may
not is refused; tampered token refused. bob (no `ai-user`): refused at the gateway.

## Kill switch

| Action | Effect | When |
|---|---|---|
| Remove the permission (`kc-apply-agents.sh permission-off`) | Next sign-in or refresh: no `may_act`, exchange refused | At the next refresh. A user token issued before keeps working for the exchange until it expires (5 min) |
| End the user's session (`kc-apply-agents.sh session-off <user>`, or admin console) | Exchange refused | Immediately for new agent tokens |
| Disable the agent's client | Agent cannot sign in | Immediately for new agent tokens |
| Remove the agent from policy.json `agents` | Gateway refuses its tokens | Next request |

Tokens already issued to the agent stay valid until they expire (120 s here). Keycloak does not
re-check the permission at the exchange, and the gateway does not check sessions.

## Limits

- Keycloak preview features: not for production.
- One hop. An agent cannot hand the work to a second agent for the same user with a nested
  `act` (A, then B). Keycloak nests `act` only when the actor token itself carries one, and a
  sign-in can ask for one `delegation:client` scope only. Agents also cannot call tools through
  the gateway (step 5), because standard token exchange refuses subject tokens with `act`.
- Consent is not stored: the user approves on every sign-in.
- The private key is a Keychain item, not in the Secure Enclave, and not deployed by MDM yet.
- No revocation signal to the gateway (no Shared Signals / CAEP); short token lifetimes limit the window.
- The agent's identity is a Keycloak client. Not covered: agent registration by the agent itself,
  workload identity (WIMSE, SPIFFE), attestation of where the agent runs.

## Result, 26 Nov 2026 (Keycloak 26.8.2, alice)

| Check | Result |
|---|---|
| Delegation scopes | Missing in the existing realm (Keycloak adds them only to new realms or at upgrade with the feature on); the script copies Keycloak's definition from a temporary realm |
| User token | `may_act.client_id` research-agent, `aud` research-agent, no `act` |
| Agent sign-in | `private_key_jwt` 200; another key 400 "Unable to load public key" |
| Agent alone at the gateway | 403 |
| User token at the gateway | 401 |
| Exchange without `actor_token` | 400 "Subject token with a delegation claim is not allowed for standard token exchange" |
| rogue-agent | 400 "Actor user is not allowed by the may_act claim inside the subject_token" |
| Delegated token | `sub` alice, `act.client_id` research-agent, no `may_act`, `aud` model-gateway, `azp` research-agent, no refresh token, 120 s, roles `ai-user` |
| Gateway | llama3.2:3b 200; llama3.2:1b 403 "agent 'research-agent' may not use model"; tampered 401 |
| Audit | `"user": "alice"`, `"client": "research-agent"`, `"act": ["research-agent"]` |
| Kill switch A (permission removed) | Old user token still exchangeable (200, until it expires); after refresh no `may_act`, exchange 400 |
| Kill switch B (session ended) | Exchange 400 "Invalid token"; delegated token issued before still 200 at the gateway until it expires |
| bob (no `ai-user`) | Delegated token has no roles; gateway 403 "user 'bob' may not use model" for both models; kill switch A and B as for alice |
