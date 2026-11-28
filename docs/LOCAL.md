# Local mode

Runs the core on one machine without a domain, without Cloudflare and without a public
certificate. For trying SLATFF.Cloud out. The names end in `slatff.test` and work on this
machine only.

Status: built 28 Nov 2026. Certificates, Caddy configuration and the Compose files are checked
in CI ([check](../.github/workflows/check.yml), [local-mode](../.github/workflows/local-mode.yml)).
Not yet run on a Mac with a browser: see [TESTING.md](TESTING.md#local-mode).

## Requirements

- Docker with Compose, [Ollama](https://ollama.com), `openssl`.
- Administrator rights once, for the hosts file and for trusting the certificate.
- No other SLATFF.Cloud installation on the same machine. Local mode uses the same Docker
  project name, volumes and port 443.

## Steps

```sh
./scripts/bootstrap.sh --local
echo '127.0.0.1 id.slatff.test ai.slatff.test meet.slatff.test files.slatff.test' | sudo tee -a /etc/hosts
# macOS: trust the local CA (asks for your password)
sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain local/ca.crt
docker compose up -d --build
./scripts/pull-model.sh
./scripts/create-demo-user.sh carol carol@slatff.test ai-admins
./scripts/create-demo-user.sh alice alice@slatff.test ai-users
./scripts/create-demo-user.sh bob   bob@slatff.test   none
```

Open `https://ai.slatff.test`. Sign in as `carol` first (Open WebUI makes the first account
admin), then as `alice` (chat) and `bob` (refused at sign-in). `./scripts/show-audit.sh` shows
the gateway's decisions.

Linux: `sudo cp local/ca.crt /usr/local/share/ca-certificates/slatff-local.crt && sudo update-ca-certificates`.
Firefox keeps its own list: import `local/ca.crt` under Settings, Privacy & Security, Certificates.
Without trusting the CA the browser warns on both hosts and passkeys do not work.

Check from a terminal:

```sh
curl --cacert local/ca.crt https://id.slatff.test/realms/slatff/.well-known/openid-configuration
```

## What is different

| | Normal | Local mode |
|---|---|---|
| Names | `id.<your domain>`, DNS at Cloudflare | `id.slatff.test`, hosts file |
| Certificate | Let's Encrypt, DNS challenge | Own CA from `scripts/local-certs.sh`, in `local/` |
| Reachable from | Your network | This machine |
| Containers trust Keycloak's certificate | Public CA | CA bundle with the local CA added (`docker-compose.local.yml`) |

Everything else is the same: same realm, same gateway, same policy, same audit log.

## Covered and not covered

| Part | Local mode |
|---|---|
| Sign-in, chat, model gateway, audit ([GUIDE.md](GUIDE.md) sections 3 to 5) | Yes |
| Test scripts `scripts/mac-step*.sh` | No. Their curl containers do not trust the local CA yet |
| IDE bridge and agent on the host | Not tried. Python on the host needs `SSL_CERT_FILE=local/ca.crt` |
| Files, meetings (`--profile files`, `--profile meet`) | No. Those containers do not get the CA bundle yet |
| Tunnel, Platform SSO, Apple Business | No. They need a public host name |

## The local CA

- `scripts/local-certs.sh` creates a CA and one certificate for the four names, then deletes
  the CA key. Nothing more can be issued from this CA.
- The CA carries a name constraint for `slatff.test`. OpenSSL refuses a certificate for any
  other name from it. Browsers apply name constraints to different degrees, so
  the deleted key is the control to rely on.
- Valid for 825 days. To replace: `./scripts/local-certs.sh`, trust the new `local/ca.crt`,
  then `docker compose up -d --force-recreate`.
- `local/` is in `.gitignore`. `local/tls.key` is the private key for the four names.

## Remove

```sh
docker compose down -v
sudo security delete-certificate -c "SLATFF.Cloud local mode CA (slatff.test only)" /Library/Keychains/System.keychain
sudo sed -i.bak '/slatff\.test/d' /etc/hosts
rm -rf local .env
```
