# Platform SSO for Mac with Keycloak

Mac sign-in (macOS 27: also FileVault unlock, lock screen, login window) through your Keycloak.
Status: guide and verified download script; not run against a Mac yet.

## Components

| Component | Source | Licence |
|---|---|---|
| Keycloak extension | github.com/unioslo/keycloak-psso-extension | GPL-2.0-or-later (not included here) |
| Mac SSO extension "Weblogin" | github.com/unioslo/weblogin-mac-sso-extension | Apache-2.0; no releases, build with Xcode |
| MDM | any that installs a package and custom profiles | |

Requirements (checked 10 Nov 2026): Keycloak 26.5+, PostgreSQL or MariaDB, feature
`declarative-ui`. Latest extension release 0.50b (0.44b added the OpenID method used by macOS 27).

## Steps

1. `./scripts/get-psso-extension.sh [version]`: downloads the jar, `.sha256` and `.sig`, checks
   the signer key against the maintainer's GitHub keys, verifies checksum and SSH signature,
   then copies the jar to `keycloak/providers/`. Installs nothing if a check fails.
2. Copy `caddy/well-known/apple-app-site-association.example` to
   `caddy/well-known/apple-app-site-association`; set your team ID and bundle IDs (`authsrv`
   for the extension, `webcredentials` for the app). Served at
   `https://<id host>/.well-known/apple-app-site-association`.
3. `.env`: `KC_FEATURES=declarative-ui`, then `docker compose up -d keycloak`.
4. Realm (per the extension wiki for your release):
   - client scope `urn:apple:platformsso`
   - public client `psso`, redirect URI `weblogin-sso://idp-login-redirect`, scope `urn:apple:platformsso`
   - the extension's authenticator in the browser flow, directly under Cookie
   - keep Revoke Refresh Token off
5. Build Weblogin with your team and bundle IDs; associated domain `authsrv:<id host>`. Deploy
   app and Platform SSO profile with your MDM.

## Associated domain without internet access

macOS normally fetches the association file through Apple's CDN, which needs a public host.

- Preferred: Associated Domains payload (`com.apple.associated-domains`) with `authsrv:<id host>`
  and `EnableDirectDownloads` = true. The Mac fetches the file directly; the id host stays local.
  Needs user-approved or automated enrolment. Whether `?mode=managed` is needed: to be tested.
- Alternative: publish the id host through the tunnel ([REMOTE-ACCESS.md](REMOTE-ACCESS.md)).

The Keycloak admin console stays local-only in both cases.

## Check

The Mac registers with Keycloak; a Keycloak user signs in at the login window (macOS 27) or
unlocks with the Keycloak password.

Sources: extension README, wiki and releases (University of Oslo);
[Apple: Platform SSO for Mac](https://support.apple.com/guide/deployment/platform-sso-for-mac-dep7bbb05313/web);
[What's new for enterprise in macOS 27](https://support.apple.com/en-us/148830).
