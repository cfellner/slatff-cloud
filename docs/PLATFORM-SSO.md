# Platform SSO for Mac with Keycloak

Mac sign-in (macOS 27: also FileVault unlock, lock screen, login window) through your Keycloak.
Status: scripts and profiles built (step 11); not run against a Mac yet.

## Components

| Component | Source | Licence |
|---|---|---|
| Keycloak extension | github.com/unioslo/keycloak-psso-extension | GPL-2.0-or-later (not included here) |
| Mac SSO extension "Weblogin" | github.com/unioslo/weblogin-mac-sso-extension | Apache-2.0; no releases, build with Xcode |
| MDM | any that installs a package and custom profiles | |

Requirements (checked 10 Nov 2026): Keycloak 26.5+, PostgreSQL or MariaDB, feature
`declarative-ui`. Extension version 0.58b (26 Nov 2026; 0.44b added the OpenID method used by macOS 27).

## Steps

Automated by `bash scripts/mac-step11-apple.sh psso` (part of [APPLE.md](APPLE.md)):

1. `scripts/get-psso-extension.sh [version]`: downloads the jar, `.sha256` and `.sig`, checks
   the signer key against the maintainer's GitHub keys, verifies checksum and SSH signature,
   then copies the jar to `keycloak/providers/`. Installs nothing if a check fails.
2. `KC_FEATURES` gets `declarative-ui`; Keycloak restarts.
3. `scripts/kc-apply-psso.sh`, following the extension's wiki:
   - client scope `urn:apple:platformsso`; public client `psso`, redirect URI
     `weblogin-sso://idp-login-redirect`, optional `offline_access`, access token 8 hours
   - required action `psso-required-action` enabled
   - authenticator `psso-authenticator` in a copy of the browser flow (`browser-psso`), directly under Cookie
   - realm tab "Platform Single Sign-on": registration token not required
   - macOS 27 web-based method: confidential client `psso-oidc`, pushed authorization requests
     required, scopes `urn:apple:platformsso:auth:*` optional
   - Revoke Refresh Token stays off (the extension uses the refresh token for login)
4. `caddy/well-known/apple-app-site-association` from `APPLE_TEAM_ID` and `WEBLOGIN_BUNDLE_ID`
   (the app's ID under `authsrv` and `webcredentials`).
5. `dist/mdm/slatff-platform-sso.mobileconfig` and `slatff-associated-domains.mobileconfig`
   (profile based on the example in the Weblogin wiki: `UserSecureEnclaveKey`, shared device keys,
   create user at login).
6. Build Weblogin with your team and bundle IDs; associated domain `authsrv:<id host>`. Deploy
   app and profiles with your MDM.

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
