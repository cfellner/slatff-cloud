# Model gateway (step 3)

Sits between Open WebUI (or the IDE bridge) and the model. Checks the user's own Keycloak token
on every request, applies policy, writes an audit line. The decision no longer depends on the
chat application being configured correctly.

```
Open WebUI --(user token)--> model gateway --> Ollama
                              token: signature, issuer, audience model-gateway, expiry
                              policy: model by role, document label by role
                              audit: one JSON line per decision
```

## Configuration

| Setting | Value |
|---|---|
| Open WebUI connection | `OPENAI_API_BASE_URLS=http://model-gateway:8080/v1`, auth type `system_oauth` (forwards the user token), `ENABLE_OLLAMA_API=false` |
| Keycloak | audience mapper `model-gateway` on client `open-webui` |
| Policy | `model-gateway/policy.json`: `models`, `labels`, `tools` by realm role; reloaded on change; unknown labels refused |
| Labels | text markers `CLASSIFICATION: <LABEL>` in the prompt (for example from retrieved documents) |
| Audit | volume `gateway-audit`, `/audit/audit.jsonl`; prompt text only if `GATEWAY_AUDIT_LOG_PROMPTS=true` |
| Model list | `GET /v1/models` without token returns the catalogue; with a token, filtered by role |

Show recent decisions: `bash scripts/show-audit.sh`.

## Run and test

```sh
bash scripts/mac-step3.sh     # Keycloak settings, gateway, live tests, fresh Open WebUI
bash model-gateway/tests/run.sh   # offline, fake Keycloak and model, 28 checks, in CI
```

Live result, 23 Nov 2026: permitted request 200; BOARD-ONLY for ai-user 403; model outside
policy 403; no token 401. Audit shows real users (carol, alice).

## Limits

- Ollama on the host accepts any request from the same machine, including containers via
  `host.docker.internal:11434`. The gateway protects the path users take, not the host.
  Decision 23 Nov 2026: out of scope for the PoC. Options to close it: Docker network
  isolation; a model server that requires a key only the gateway has (for example llama.cpp
  server); the model on its own host with a firewall.
- Labels are text markers. Unlabelled content is not checked.
- Role changes apply with the next token (5 min default), not instantly.
- Trusts Keycloak signing keys fetched over HTTPS.
- A minimal gateway written for this PoC, about 400 lines of Python. Maintained gateways cover
  the same checks and more: [agentgateway](https://agentgateway.dev) (open source) and
  [LiteLLM](https://docs.litellm.ai) (SSO and audit logs in its paid Enterprise edition). See
  [README, Related projects](../README.md#related-projects).

## Planned: auto-routing (not built)

An `auto` model that picks the cheapest sufficient model:

1. Only models the user's roles allow.
2. Labels that must stay local (for example BOARD-ONLY) allow only local models.
3. Cheapest model expected to handle the request (rules first: prompt length, documents, task type).
4. Choice, candidates and reason in the audit line.

Cost per model in policy.json; optional monthly budget per group. Identity and labels always
come before cost.

Prediction, in stages: log metadata per request (task type, tokens, latency, model; no prompt
text) → rule-based tiers → outcome signals (ratings, regenerations, shadow evaluation) → small
classifier per task type with a confidence threshold. Pays off once a paid cloud model sits
next to the local ones.

Next: [DELEGATION.md](DELEGATION.md).
