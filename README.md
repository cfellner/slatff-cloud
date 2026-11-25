# SLATFF.Cloud

Self-hosted identity in front of AI, files and meetings for a small business. Keycloak decides
who may use which model; a gateway enforces it at the model and logs every decision.

Personal project by Christoph Fellner. Development grade, not for production.

## Idea

The sovereignty boundary is the identity provider, not the GPU. A local model behind a foreign
SaaS login is not sovereign. Details: [docs/AI-ACCESS.md](docs/AI-ACCESS.md).

## Components

```
devices on your network
        | HTTPS
      Caddy (only open port)
   _____|______________________________
  |          |             |           |
Keycloak  Open WebUI   Nextcloud    Jitsi        (Nextcloud, Jitsi optional)
             |
       model gateway ── kb-tool (demo tool, delegated token)
             |
           Ollama (native on the host)
```

| Component | Purpose | Status |
|---|---|---|
| Keycloak + PostgreSQL | Identity, realm `slatff`, roles `ai-user`, `ai-admin`, `files-user` | Live 23 Nov 2026 |
| Caddy | HTTPS for all services, Let's Encrypt via Cloudflare DNS challenge | Live 23 Nov 2026 |
| Open WebUI + Ollama | Chat, local model, sign-in only through Keycloak | Live 23 Nov 2026 |
| Model gateway | Checks each user's token at the model; model and label policy; audit log | Live 23 Nov 2026 ([docs](docs/MODEL-GATEWAY.md)) |
| Delegation | Tool calls with a token exchanged for that tool only (RFC 8693) | Live 25 Nov 2026 ([docs](docs/DELEGATION.md)) |
| IDE bridge | Xcode, Visual Studio, Qt Creator use the gateway as the signed-in user | Xcode live 25 Nov 2026; Windows/Linux IDEs: [testers wanted](docs/IDES.md#testers-wanted) ([docs](docs/IDE-BRIDGE.md)) |
| Knowledge demo | Same assistant, different answers by group | Not run yet ([docs](docs/KNOWLEDGE-DEMO.md)) |
| Nextcloud (`--profile files`) | Files, calendars, contacts | Not run yet ([docs](docs/FILES.md)) |
| Jitsi (`--profile meet`) | Meetings | Experimental ([docs](docs/MEET.md)) |
| Cloudflare tunnel (`--profile tunnel`) | Remote access | Not run yet ([docs](docs/REMOTE-ACCESS.md)) |
| Platform SSO | Mac sign-in through Keycloak (University of Oslo extension) | Not run yet ([docs](docs/PLATFORM-SSO.md)) |

Only what is ticked in [docs/TESTING.md](docs/TESTING.md) counts as working.

## Requirements

- Docker with Compose
- [Ollama](https://ollama.com) installed natively (Docker on a Mac cannot use the GPU)
- A domain with DNS at Cloudflare and an API token ([docs/NETWORK.md](docs/NETWORK.md))

## Quick start

Step by step: [docs/GUIDE.md](docs/GUIDE.md).

```sh
./scripts/bootstrap.sh example.org      # writes .env with host names and random secrets
# add CLOUDFLARE_API_TOKEN to .env
docker compose up -d --build
./scripts/pull-model.sh
./scripts/create-demo-user.sh carol carol@example.org ai-admins
./scripts/create-demo-user.sh alice alice@example.org ai-users
./scripts/create-demo-user.sh bob   bob@example.org   none
```

Open `https://ai.<domain>`. Sign in as `carol` first (Open WebUI makes the first account admin).

| User | Group | Result |
|---|---|---|
| carol | ai-admins | chat and admin settings |
| alice | ai-users | chat |
| bob | none | refused at sign-in |

## Limits

- Keycloak runs `start-dev`. HTTP inside the Docker network.
- For your own network. Do not forward ports; use the tunnel or a VPN for remote access.
- The model runtime still accepts requests from the same machine ([details](docs/MODEL-GATEWAY.md#limits)).
- Label policy covers labelled text only. Not data-loss prevention.
- Role changes apply at the next token (5 min) or sign-in.
- Host names are public in DNS; certificates depend on Cloudflare and Let's Encrypt.

## Licence

Apache 2.0 ([LICENSE](LICENSE), [NOTICE](NOTICE)). Components keep their own licences. The
University of Oslo Platform SSO extension (GPL-2.0-or-later) is not included; the script
downloads it from its project. Not affiliated with Apple, the University of Oslo, Cloudflare
or any other project named here. How this repository was built: [docs/PROVENANCE.md](docs/PROVENANCE.md).
