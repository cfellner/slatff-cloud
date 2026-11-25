# Guide

From nothing to a running SLATFF.Cloud on your network. Each part ends with a check.
Background: [HOW-IT-WORKS.md](HOW-IT-WORKS.md). Verified so far: [TESTING.md](TESTING.md).

1. Requirements
2. Network and DNS
3. Core
4. Users
5. Model gateway
6. Delegation
7. IDEs
8. Optional: files, meetings, remote access, Mac sign-in
9. Operations
10. Troubleshooting

## 1. Requirements

- Mac with Apple silicon (tested: M5 Max, 36 GB) or Linux.
- Docker with Compose (Mac: Docker Desktop, wait for "Engine running").
- [Ollama](https://ollama.com) installed natively, default settings. Linux without native Ollama: profile `ollama-container`.
- git.
- A domain with DNS at Cloudflare (free plan).
- Optional: MDM and Apple Developer membership (Mac sign-in); Cloudflare Zero Trust or a VPN (remote access).

## 2. Network and DNS

Details: [NETWORK.md](NETWORK.md).

1. DHCP reservation for the server (`ipconfig getifaddr en0` shows the address).
2. Cloudflare A records `id`, `ai` (and optionally `meet`, `files`) to that address, DNS only.
3. API token, template "Edit zone DNS", your zone only.

Check: `id.<domain>` resolves to the server from another device.

## 3. Core

```sh
git clone https://github.com/<owner>/slatff-cloud.git
cd slatff-cloud
./scripts/bootstrap.sh <domain>
printf "Token: "; read -rs T; echo; sed -i '' "s|^CLOUDFLARE_API_TOKEN=.*|CLOUDFLARE_API_TOKEN=$T|" .env; unset T
```

(Linux: `sed -i` without `''`.) A token contains only letters, digits, `_`, `-`; new tokens start with `cfut_`.

Mac, with checks:

```sh
./scripts/mac-step1.sh   # Docker, Ollama, ports; pulls images and model
./scripts/mac-step2.sh   # starts the core; checks DNS, certificates, realm
```

Or by hand:

```sh
docker compose up -d --build
./scripts/pull-model.sh
docker compose ps
```

First start takes a few minutes (certificates).

Check:
- `https://id.<domain>` shows Keycloak with a valid certificate.
- `https://id.<domain>/realms/slatff/.well-known/openid-configuration` returns JSON.
- `https://ai.<domain>` redirects to Keycloak.

Admin console: `https://id.<domain>/admin/`, user `admin`, password `KC_BOOTSTRAP_ADMIN_PASSWORD` in `.env`.

## 4. Users

```sh
./scripts/create-demo-user.sh carol carol@example.org ai-admins
./scripts/create-demo-user.sh alice alice@example.org ai-users
./scripts/create-demo-user.sh bob   bob@example.org   none
```

Passwords are asked, not passed on the command line. Several groups: `ai-users,files-users`.
Sign in as carol first.

| User | Expected |
|---|---|
| carol | chat and admin settings |
| alice | chat |
| bob | "You do not have permission to access this resource" |

Then remove alice from `ai-users`, sign her out and in: refused.

## 5. Model gateway

```sh
bash scripts/mac-step3.sh     # gateway, live tests, fresh Open WebUI (type RESET when asked)
bash scripts/show-audit.sh    # recent decisions
```

After the reset: sign in as carol first; in Admin Panel grant the models to group `ai-users`;
for small models set Advanced Params › Function Calling: Legacy. Then
[KNOWLEDGE-DEMO.md](KNOWLEDGE-DEMO.md). Details: [MODEL-GATEWAY.md](MODEL-GATEWAY.md).

## 6. Delegation

```sh
bash scripts/mac-step5-delegation.sh
```

All lines PASS. Details: [DELEGATION.md](DELEGATION.md).

## 7. IDEs

```sh
bash scripts/mac-step6-ide-bridge.sh          # server side
bash scripts/ide-bridge.sh login              # on the server Mac
IDE=xcode bash scripts/ide-bridge.sh serve    # prints the IDE settings
```

Other computers and IDEs: [IDE-BRIDGE.md](IDE-BRIDGE.md).

## 8. Optional

| Part | Start | Docs |
|---|---|---|
| Files | `docker compose --profile files up -d` then `./scripts/setup-files.sh` | [FILES.md](FILES.md) |
| Meetings | `LAN_IP` in `.env`, then `docker compose --profile meet up -d` | [MEET.md](MEET.md) |
| Remote access | tunnel token in `.env`, DNS changes, `docker compose --profile tunnel up -d` | [REMOTE-ACCESS.md](REMOTE-ACCESS.md) |
| Mac sign-in | `./scripts/get-psso-extension.sh`, realm, Mac extension, MDM | [PLATFORM-SSO.md](PLATFORM-SSO.md) |

## 9. Operations

| Task | Command |
|---|---|
| Status | `docker compose ps` |
| Logs | `docker compose logs -f <service>` |
| Stop all | `docker compose --profile files --profile meet --profile tunnel down` |
| Update | `docker compose pull && docker compose up -d` |
| Change model | `SLATFF_MODEL` in `.env`, then `./scripts/pull-model.sh` |
| Realm changes after first start | admin console or `scripts/kc-apply-*.sh` (the realm file is imported once) |
| Reset everything | `docker compose --profile files --profile meet down -v` (deletes users, chats, files) |

Back up: volumes `postgres-data`, `open-webui-data`, `nextcloud-data`, `nextcloud-db`,
`gateway-audit`, and `.env` (all secrets).

## 10. Troubleshooting

| Symptom | Fix |
|---|---|
| `zsh: command not found: docker` | `/Applications/Docker.app/Contents/Resources/bin/docker`, or Docker Desktop › Settings › Advanced › System |
| `permission denied` on `./scripts/...` | `bash scripts/...` |
| Names do not resolve at home | router DNS rebinding protection |
| Server address changed | DHCP reservation; Mac: Private Wi-Fi address Fixed |
| Caddy restarts, token "appears invalid" | stray character or wrong line in `.env`; fix, `docker compose up -d --force-recreate caddy`. This log prints the token: do not share it |
| Caddy reload: `subject does not qualify ... {$FILES_HOST` | container older than `.env`; `docker compose up -d --force-recreate caddy` |
| Keycloak: `'' is an unrecognized feature` | empty `KC_FEATURES`; compose falls back to a default |
| Sign-out ends on "Invalid redirect uri" | `bash scripts/kc-apply-client-settings.sh` |
| User added to a group still refused | sign out and in again |
| Wrong user became Open WebUI admin | reset Open WebUI's volume, sign in as an ai-admin first |
| alice sees no models | Admin Panel: grant models to group `ai-users` |
| Small model prints raw JSON | Function Calling: Legacy |
| Container restarts, `Permission denied` on `/app/*.py` | rebuild; Dockerfiles use `COPY --chmod=755` |
| `docker compose` reports a missing value | `./scripts/bootstrap.sh` or copy the value from `.env.example` |
