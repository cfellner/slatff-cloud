# Remote access: Cloudflare tunnel (`--profile tunnel`)

Publishes `id`, `ai`, `files` through an outbound connection to Cloudflare. No router port.
Status: not run yet.

## Trade-offs

- The sign-in page is on the internet. Keycloak brute-force protection is on; add OTP or passkeys first.
- Cloudflare terminates TLS and sees the traffic. A VPN (WireGuard, Tailscale, Headscale, NetBird) keeps it end to end.
- Meetings (UDP) do not work through the tunnel.
- `/admin` on the id host returns 403 for tunnel requests (`Cf-Connecting-Ip` present).
- Free plan: 100 MB per upload.
- Home devices also go through Cloudflare (one name per service, required by OpenID Connect).

## Step 11 (Apple Business / School Manager)

Apple's servers call the id host, so it must be public. Publish only `id` (skip `ai` and `files` in
steps 3 and 4 below); everything else stays on the local network. See [APPLE.md](APPLE.md).

## Setup

1. Zero Trust › Networks › Tunnels › Create (Cloudflared), name `slatff`; copy only the token.
2. `.env`: `CLOUDFLARE_TUNNEL_TOKEN=...`
3. Delete the A records for `id`, `ai`, `files` (keep `meet`).
4. Public hostnames per name: service `HTTPS caddy:443`, TLS Origin Server Name = the same name.
5. `docker compose --profile tunnel up -d`

## Check

Sites work from a phone on mobile data; `https://id.<domain>/admin/` returns 403 there.

## Off

`docker compose stop cloudflared`, remove the public hostnames, restore the A records.
