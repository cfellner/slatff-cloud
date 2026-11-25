# Network, names, certificates

Reachable by name over HTTPS on your own network. Nothing opened to the internet. Remote access: [REMOTE-ACCESS.md](REMOTE-ACCESS.md).

## 1. Fixed address

DHCP reservation for the server, for example `192.168.1.50`. On a Mac also set Wi-Fi
"Private Wi-Fi address" to Fixed for that network.

## 2. DNS records (Cloudflare)

A records to that address, **DNS only** (grey cloud):

| Name | For |
|---|---|
| `id` | Keycloak |
| `ai` | Open WebUI, gateway |
| `meet` | meetings (optional) |
| `files` | Nextcloud (optional) |

## 3. API token

My Profile › API Tokens › Create Token › template "Edit zone DNS", Zone Resources: your domain
only. Put it in `.env` as `CLOUDFLARE_API_TOKEN`. Never in chats, screenshots or git.

## 4. Model stays local

Ollama on its default address (localhost only). Do not set `OLLAMA_HOST=0.0.0.0`.

## Troubleshooting

| Symptom | Fix |
|---|---|
| Names do not resolve at home | Router DNS rebinding protection: add an exception or use another DNS server |
| Browser cannot connect | macOS firewall blocks Docker; allow it |
| Certificate errors at first start | Wait; check `docker compose logs caddy` for token errors |
| No models in the chat | Ollama not running or no model: `./scripts/pull-model.sh` |
| Other devices cannot connect | Server asleep, or guest Wi-Fi isolates devices |
