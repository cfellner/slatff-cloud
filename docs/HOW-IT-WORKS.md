# How it works

Setup: [GUIDE.md](GUIDE.md). Verified items: [TESTING.md](TESTING.md).

## Configuration

`scripts/bootstrap.sh <domain>` copies `.env.example` to `.env`, sets the host names and fills
every secret with a random value (`openssl rand`). Compose reads all `${...}` from `.env`.
`.env` is in `.gitignore`. Only the Cloudflare token is added by hand.

## Model on the host

Docker on a Mac runs in a Linux VM without GPU access. Ollama runs natively, listens on
`127.0.0.1:11434` and is reached from containers at `host.docker.internal`.

## Caddy

Only published port: 443. Keycloak, Open WebUI, Nextcloud and the gateway publish nothing.
Inside the Docker network the public host names are aliases for Caddy, so containers and
browsers use the same names and certificates.

## Certificates

Let's Encrypt DNS challenge: Caddy writes a TXT record with a Cloudflare token limited to
"Edit zone DNS" for one zone. No inbound port needed. A records point to the server's private
address, DNS only (grey cloud). Some routers block private addresses in DNS answers (DNS
rebinding protection).

## Keycloak

Realm `slatff` is imported once from `keycloak/realm-slatff.json`, placeholders filled from the
environment. Later changes: admin console or the `scripts/kc-apply-*.sh` scripts.

| Object | Purpose |
|---|---|
| roles `ai-user`, `ai-admin`, `files-user` | who may use what |
| groups `ai-users`, `ai-admins`, `files-users` | carry the roles |
| client `open-webui` | chat sign-in; audience `model-gateway`; roles and groups in the token |
| clients `jitsi`, `nextcloud` | meetings, files |
| clients `model-gateway`, `kb-tool`, scope `kb-search` | delegation ([DELEGATION.md](DELEGATION.md)) |
| client `ide-bridge` | IDE sign-in ([IDE-BRIDGE.md](IDE-BRIDGE.md)) |

## Open WebUI

Password form and sign-up off; sign-in only through Keycloak.

- `OAUTH_ALLOWED_ROLES=ai-user,ai-admin`: others are refused, no account created.
- `OAUTH_ADMIN_ROLES=ai-admin`.
- Keycloak groups become Open WebUI groups at each sign-in.
- The first account ever created becomes admin regardless of roles: sign in as an ai-admin first.

## Model gateway, knowledge, delegation

- Gateway: [MODEL-GATEWAY.md](MODEL-GATEWAY.md)
- Knowledge bases shared by group: [KNOWLEDGE-DEMO.md](KNOWLEDGE-DEMO.md)
- Tool calls with exchanged tokens: [DELEGATION.md](DELEGATION.md)
- IDEs: [IDE-BRIDGE.md](IDE-BRIDGE.md)

## Optional profiles

| Profile | What | Docs |
|---|---|---|
| `files` | Nextcloud, role `files-user` | [FILES.md](FILES.md) |
| `meet` | Jitsi; hosts sign in via Keycloak, guests wait in the lobby; UDP 10000 on `LAN_IP` | [MEET.md](MEET.md) |
| `tunnel` | Cloudflare tunnel; Keycloak admin console stays local-only | [REMOTE-ACCESS.md](REMOTE-ACCESS.md) |

## Step scripts

Each `scripts/mac-step*.sh` writes its output to `logs/`.

| Script | Does |
|---|---|
| `mac-step1.sh` | checks address, iCloud sync, Docker, Ollama, port 443, compose file; pulls images and model |
| `mac-step2.sh` | starts the core; checks DNS, certificates, realm |
| `mac-step3.sh` | model gateway with live tests |
| `mac-step5-delegation.sh` | token exchange and kb-tool with live tests |
| `mac-step6-ide-bridge.sh` | Keycloak client and Caddy route for the IDE bridge |
