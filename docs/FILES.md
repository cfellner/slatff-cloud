# Files, calendars, contacts (`--profile files`)

Nextcloud at `https://files.<domain>`, sign-in through Keycloak. Status: not run yet.

## Start

1. DNS record `files`, DNS only ([NETWORK.md](NETWORK.md)).
2. `docker compose --profile files up -d`
3. `./scripts/setup-files.sh` (connects Nextcloud to Keycloak; safe to re-run)
4. Add a user to `files-users`: `./scripts/create-demo-user.sh alice alice@example.org ai-users,files-users`

## Access

- Keycloak role `files-user` (group `files-users`), client `nextcloud` with groups in the token.
- Nextcloud `user_oidc` admits only tokens with group `files-users`; login page goes straight to Keycloak.
- Break-glass: `https://files.<domain>/login?direct=1`, user `ncadmin`, password `NEXTCLOUD_ADMIN_PASSWORD`.

## Clients (test in this order)

1. App password (Personal settings › Security) in the Mac, iPhone, iPad Files, Calendar, Contacts apps.
2. Keycloak token on WebDAV (`--check-bearer` is on):
   `curl -H "Authorization: Bearer <token>" https://files.<domain>/remote.php/dav/files/<user>/`
3. Nextcloud desktop and mobile apps (browser sign-in).

## Not included

- Office editing in the browser: Collabora Online (planned default) or Euro-Office.
- Nextcloud Office Desktop: untested whether its sign-in goes through Keycloak.
- Mail hosting.
- Backup: volumes `nextcloud-data`, `nextcloud-db`.

Reference design: openDesk (Kubernetes, own identity layer); here Docker Compose with your own Keycloak.
