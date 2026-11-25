# Meetings: Jitsi (`--profile meet`, experimental)

Hosts sign in through Keycloak; guests wait in the lobby. Status: not run yet; most likely to need fixes.

## Parts

- `jitsi-web`, `jitsi-prosody`, `jitsi-jicofo`, `jitsi-jvb`, pinned `stable-10532-1`.
- `jitsi-adapter`: Nordeck jitsi-keycloak-adapter-v2 (Apache-2.0), turns the Keycloak sign-in into a Jitsi token.
- Caddy: `/oidc/*` to the adapter, the rest to `jitsi-web`.
- Keycloak client `jitsi`, redirect `https://meet.<domain>/oidc/tokenize`.

## Start

1. `.env`: `LAN_IP=<server address>` (video on UDP 10000 to this address).
2. `docker compose --profile meet up -d`
3. Open `https://meet.<domain>`, start a meeting, sign in.

## Limits

- The adapter's Docker guide is marked "not ready"; the Caddy route replaces its web server step (untested).
- Jitsi images use built-in defaults, not the full docker-jitsi-meet env file. Compare with the [handbook](https://jitsi.github.io/handbook/docs/devops-guide/devops-guide-docker) if a service fails.
- Adapter image not pinned; pin a digest once it works.
- Any realm user can host (no `meet-user` role).
- Local network only.
