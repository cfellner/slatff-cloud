# IDE bridge (step 6)

Lets Xcode, Visual Studio and Qt Creator use the model gateway as the signed-in user. Same
policy and audit as the browser chat.

## Why a bridge

IDEs send a fixed API key or none. Keycloak access tokens last 5 minutes. The bridge runs on
the developer's computer, signs in once and adds a fresh user token to every request.

```
IDE -> 127.0.0.1:11435 (local key) -> ide-bridge -> https://<AI_HOST>/gateway/v1 -> gateway -> model
```

- Sign-in: device code (RFC 8628) with PKCE, Keycloak client `ide-bridge` (public).
- Refresh token storage: macOS Keychain, Windows DPAPI, Linux Secret Service (`secret-tool`); fallback a mode-600 file with a warning.
- APIs on one port:

| Style | Paths | Used by |
|---|---|---|
| OpenAI | `/v1/models`, `/v1/chat/completions` | Xcode, Visual Studio (OpenAI endpoint) |
| Ollama | `/api/tags`, `/api/chat`, `/api/generate`, `/api/version`, `/api/show` (translated) | Qt AI Assistant, Visual Studio (Ollama endpoint) |

- Local key: in the API key field, or in the URL: `http://127.0.0.1:11435/k/<key>`. Created once, kept in the same secret store, so the IDE setting survives restarts.
- One file, `ide-bridge/bridge.py`, Python 3.9+, standard library only.

## Server setup (once)

```sh
bash scripts/mac-step6-ide-bridge.sh
```

Creates the Keycloak client, publishes only `/gateway/v1/models` and
`/gateway/v1/chat/completions` on the AI host, runs checks.

## Developer setup

```sh
python3 bridge.py configure --issuer https://<ID_HOST>/realms/slatff \
    --gateway https://<AI_HOST>/gateway/v1 --ide xcode      # visualstudio | qtcreator
python3 bridge.py login     # confirm the code in the browser; 'login private' for another user
python3 bridge.py serve     # keep open; prints the settings for each IDE
```

Windows: `python` or `py`. On the server Mac: `bash scripts/ide-bridge.sh login|serve` (reads `.env`).

## Run in the background (macOS)

```sh
cd ~/SLATFF.Cloud/slatff-cloud
bash scripts/ide-bridge.sh agent install
bash scripts/ide-bridge.sh key
bash scripts/ide-bridge.sh agent status
```

- LaunchAgent `cloud.slatff.ide-bridge`: starts at login, restarted if it stops.
- Copies `bridge.py` and the settings to `~/Library/Application Support/slatff/`.
- Log: `~/Library/Logs/slatff-ide-bridge.log`. The key is not written to the log.
- Starts even when signed out and refuses requests with a reason. `login` is still done by the user; the running agent picks it up on the next request.
- `key new` replaces the key; then `agent install` again to restart, and update the IDE.
- Remove: `agent uninstall` (sign-in and key stay in the Keychain; `logout` ends the session).
- Needs `/usr/bin/python3` (Xcode or Command Line Tools).

Windows (Task Scheduler) and Linux (systemd user unit): not built; testers wanted.

| IDE | Setting |
|---|---|
| Xcode | Intelligence > Add a Chat Provider > **Internet Hosted**, URL `http://127.0.0.1:11435`, API Key `<key>`, header `x-api-key`. (Locally Hosted has no key field.) |
| Visual Studio 2026 | Copilot Chat > Manage Models > OpenAI endpoint `http://127.0.0.1:11435/v1` + key, or Ollama endpoint `http://127.0.0.1:11435/k/<key>` |
| Qt Creator | Qt AI Assistant > Ollama / custom LLM, URL `http://127.0.0.1:11435/k/<key>` |

## Check

```sh
docker compose exec -T model-gateway sh -c 'tail -3 /audit/audit.jsonl'
```

Expect your user, `client: ide-bridge`, `ide: <label>`. The IDE label is reported by the
bridge, not verified.

Offline tests: `bash ide-bridge/tests/run.sh` (42 checks: both API styles, key in header and
URL, policy refusals, refresh, revocation, audit fields, stable key, start without sign-in,
secret store). CI also runs
`bridge.py selftest-store` on Windows and Linux.

## Xcode result, 25 Nov 2026

| Check | Result |
|---|---|
| Provider (Internet Hosted, `http://127.0.0.1:11435`, `x-api-key`) | accepted, models listed |
| Chat with llama3.2:1b | allowed; audit: user carol, client `ide-bridge`, ide `xcode` |
| Prompt with `CLASSIFICATION: TOP-SECRET` | refused; Xcode shows "SLATFF model gateway: the prompt contains TOP-SECRET content, which user 'carol' is not entitled to" |
| Prompt with `CLASSIFICATION: BOARD-ONLY` as alice (ai-user) | refused: "... BOARD-ONLY content, which user 'alice' is not entitled to" |
| `logout` | revokes the session at Keycloak (RFC 7009) |
| bob (no role) | Keycloak device sign-in succeeds (Keycloak does not check roles there); gateway returns an empty model list; Xcode: "Unable to load models" |
| alice signed out in the Keycloak admin console | bridge logs "Keycloak session ended" within 4 min; next Xcode request refused |

Observed:
- Xcode sends the whole conversation and project context: about 15,000 characters for a one-line question. The gateway sees all of it.
- Once a labelled message is in a conversation, every later request in it is refused, because the history is resent. Start a new conversation.
- Xcode runs its own documentation search before calling the model.
- llama3.2:1b answers Xcode's search tool with tool calls and returns no text; Xcode shows nothing. llama3.2:3b answers. Use 3b or larger, or turn off search (binoculars) in the chat box.
- Custom providers work only in Chat. Xcode 27 recommends agents (Claude Agent, Codex, Antigravity), which use their own accounts and bypass the gateway.

## Notes from the first Xcode run (25 Nov 2026)

- Locally Hosted offers only port and description; Internet Hosted has URL, API Key, API Key Header.
- Keycloak ends an idle session after 30 min (SSO Session Idle). The bridge refreshes every 4 min to keep it alive; the maximum session length still applies.
- Keycloak shows a consent screen on the first device sign-in.
- Each `serve` created a new local key, so Xcode had to be updated after a restart. Fixed: the key is now kept in the secret store.
- The secret store decides: a newer `login` takes over a running bridge; `logout` stops it.
- zsh does not treat `#` as a comment in pasted commands.
- Xcode shows the error text for 403 but not for 401; the bridge answers 403 when the session has ended.
- `login private` opens Chrome, Edge, Brave or Firefox in private mode; with Safari (`SLATFF_BROWSER=safari`) the link is copied for a new private window. Reusing an old private tab gives Keycloak's "Restart login cookie not found".

## Limits

- Chat only where the IDE uses this provider. Vendor agents and inline completions (Xcode Claude Agent and Codex, Copilot's own models) bypass it.
- Not yet tested with the real IDEs.
- Not a signed app. On macOS it runs as a LaunchAgent or in a terminal.
- The developer's computer must resolve and reach the SLATFF host names.

## Possible next steps

- Token from the platform sign-in (Platform SSO on Mac, Windows Hello / Entra) instead of a device code.
- Windows and Linux deployment (Intune, systemd). macOS with Jamf: [MDM.md](MDM.md).
- Tool calls from IDEs through [delegation](DELEGATION.md).
