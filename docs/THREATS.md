# Threats and open issues

Security review of the whole setup, 26 Nov 2026 (repo, scripts, live realm settings, git
history). SLATFF.Cloud is a proof of concept. This page lists what is open, not only what works.

## Fixed by `scripts/harden.sh`

| # | Issue | Fix |
|---|---|---|
| 1 | Realm master: brute-force protection off; only the temporary bootstrap admin, password only | Brute-force protection on (10 failures). Personal admin with authenticator app (TOTP) required |
| 2 | Realm slatff: `admin-cli` allows the password grant, so a password can be tried at the token endpoint without the login page, passkey or MFA | Password grant off on `admin-cli` in slatff |
| 3 | Realm slatff: no password policy; brute-force threshold 30 | Policy: 12+ characters, not user name or email, not one of the last 3. Threshold 10 |
| 4 | Through the Cloudflare tunnel only `/admin` was blocked; the master realm sign-in and token endpoint were reachable | Caddy blocks `/realms/master` for tunnel requests too |
| 6 | Test client `rogue-agent` (secret, token exchange, full scope) always enabled | Disabled; step 10 enables it for its run only |

## Open: before production or wider use

| # | Issue | Next step |
|---|---|---|
| 1b | Scripts still sign in as the temporary bootstrap `admin` (password in the Keycloak container environment) | Service-account client in master for the scripts, then delete the bootstrap admin |
| 5 | Floating image tags (`curlimages/curl:latest`, `python:3.12-slim`, `caddy:2`); GitHub Actions on tags; pip version ranges | Pin by digest or exact version; Dependabot after going public |
| 7 | Keycloak runs with `start-dev` (development mode) | Switch to `start` (production mode) and test all steps again |
| 8 | Bearer tokens remain: Open WebUI to gateway, agent tokens (120 s). DPoP only for the IDE bridge | DPoP for the agent; Open WebUI cannot send DPoP |
| 9 | Keys are Keychain items, not in the Secure Enclave: bridge local key, bridge DPoP key, agent key | Secure Enclave keys (needs a small native helper); MDM-deployed agent keys |
| 10 | Database dumps in `backups/` are unencrypted and contain realm signing keys, client secrets, password hashes (file mode 600, not in git) | Keep one, encrypted; delete the rest |
| 11 | Cloudflare API token in `.env` | Scope it to DNS edit on the one zone |
| 12 | Ollama can be called directly by any process or container on the Mac, bypassing the gateway | Test "port 11434 not reachable from a second device"; run the model where only the gateway reaches it |
| 13 | One Docker network: every container reaches Keycloak's internal port, kb-tool and notes-api | Separate networks per tier |
| 14 | Preview and experimental Keycloak features and an own Java extension in the same realm | Separate realm or instance for experiments |
| 15 | Audit log is local JSON lines, not tamper-evident, no retention | Ship to append-only storage; hash chain |
| 16 | Labels fail open: only exact uppercase `CLASSIFICATION:` markers are checked | Enforce access at retrieval; treat labels as a second line |
| 17 | No rate limit at the gateway; model list answered without a token | Rate limit per user; token for the model list from the IDE path |
| 18 | Issued tokens cannot be revoked early (bridge 5 min, agent 120 s); no Shared Signals / CAEP | Shorter lifetimes where possible; SSF when Keycloak's transmitter is usable |

## Checked and fine

- Git history: no private keys, tokens, secrets, LAN addresses or real host names.
- `.env` and `backups/` are mode 600 and ignored by git; secrets are generated randomly.
- Keycloak 26.8.2 is the current release ([release notes](https://www.keycloak.org/2026/11/keycloak-2682-released), 5 Nov 2026,
  33 security fixes per [Keycloak Advisory Watch](https://buttondown.com/keycloak-advisory-watch/archive/keycloak-security-fixes-in-2682-8042/)).
  Keycloak lists most CVEs in release notes, not in GitHub advisories: watch the release notes.
- [CVE-2026-97846](https://access.redhat.com/security/cve/CVE-2026-97846) (standard token exchange drops mTLS binding) needs mTLS-bound clients; none here.
- Only port 443 (Caddy) and, with the meet profile, 10000/udp (Jitsi) are published.
