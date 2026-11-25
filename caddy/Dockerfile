# Caddy with the Cloudflare DNS module, so certificates can be issued for names that
# are only reachable on your own network (DNS challenge, no inbound port needed).
FROM caddy:2-builder AS builder
RUN xcaddy build --with github.com/caddy-dns/cloudflare

FROM caddy:2
COPY --from=builder /usr/bin/caddy /usr/bin/caddy
