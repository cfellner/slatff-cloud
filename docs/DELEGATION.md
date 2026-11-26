# Delegation (step 5)

A tool called on the user's behalf gets a token valid for that tool only, never the user's own
token. Based on the IETF AIMS draft (draft-ietf-wimse-aims): authority narrows along the chain.

## Flow

```
user token (aud model-gateway)
 -> gateway: verify token, check policy.json "tools"
 -> Keycloak token exchange (RFC 8693)
      new token: aud kb-tool, scope kb-search, exp <= user token, azp model-gateway
 -> kb-tool: accepts only aud kb-tool + scope kb-search, checks labels again
 -> audit: gateway line and tool line share correlation_id and jti
```

## Run

```sh
bash scripts/mac-step5-delegation.sh
```

Creates `GATEWAY_CLIENT_SECRET` if missing, sets up Keycloak, builds `model-gateway` and
`kb-tool`, runs the live tests with a temporary client, prints the audit lines.

Offline: `bash model-gateway/tests/run.sh` (fake Keycloak, 28 checks, in CI).

## Result, 25 Nov 2026 (Keycloak 26.5)

| Check | Result |
|---|---|
| Tool call through the gateway (ai-user) | 200, STAFF documents, 1 BOARD-ONLY withheld |
| User token sent to kb-tool | 401 wrong audience |
| Tool not in policy | 403 |
| Exchanged token | aud `kb-tool`, scope `kb-search profile`, azp `model-gateway`, exp = user token (+1 s) |
| Exchanged token sent to the gateway | 401 wrong audience |
| Exchange for another audience | 400 from Keycloak |
| Audit | both lines share correlation_id and jti |

## Keycloak objects (`scripts/kc-apply-delegation.sh`)

| Object | Settings |
|---|---|
| client `kb-tool` | no flows; exists as an audience |
| client scope `kb-search` | optional; audience mapper `kb-tool` |
| client `model-gateway` | confidential; `standard.token.exchange.enabled=true`; optional scope `kb-search`; flat realm roles mapper; no `email` scope |

Keycloak rules relied on: the subject token must contain the requesting client in `aud`;
`scope` adds the requester's optional scopes; `audience` filters, never adds; the new token
expires with the subject token; no refresh token by default.

## Add a tool

1. Keycloak: client for the tool, optional client scope with an audience mapper, attached to `model-gateway`.
2. `model-gateway/policy.json` → `tools`: `roles`, `audience`, `scope`, `url`.
3. The tool verifies issuer, signature, audience and scope, and logs `X-Correlation-Id`.

## Limits

- One hop (gateway to tool). No agent chains.
- Impersonation semantics: no `act` claim (Keycloak standard exchange does not add it).
- Scope fixed per tool in policy.json, not computed per task.
- No mid-session revocation signal (no Shared Signals / CAEP). Token lifetime limits the window.
- Open WebUI does not call tools this way yet; the tests call the gateway directly.
- kb-tool is plain HTTP, standing in for an MCP server or internal API.

## Troubleshooting

| Symptom | Fix |
|---|---|
| `awk: command not found` in Keycloak setup | The Keycloak image has no awk/cut/tr; scripts use plain bash |
| Container restarts, `Permission denied` on `/app/*.py` | Files were mode 600; Dockerfiles use `COPY --chmod=755` (644 locks the `/app` folder) |

## Next: full RFC 8693 delegation

Agents acting for a user with `actor_token` and `act`: done as step 10 ([AGENTS.md](AGENTS.md)). Still open for tool calls:

1. Require `issued_token_type` and `token_type` in the exchange response.
2. Send `actor_token` (gateway's own token) so the new token carries `act`. Keycloak 26.8 needs `may_act` in the user's token for this, so the user would approve `model-gateway` at sign-in (scope `delegation:client:model-gateway` in Open WebUI).
3. kb-tool requires and logs `act.sub`; gateway refuses unexpected `act`.
4. Nested `act` once there is a second hop.
5. Conformance table: RFC section, implementation, test.
