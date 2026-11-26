# Apple end to end (step 11)

One Keycloak account from Apple Business Manager to the Mac login window to the AI gateway.
Status: built, not run yet. See [TESTING.md](TESTING.md).

```
Apple Business Manager / Apple School Manager
  federated authentication: Managed Apple Accounts sign in with Keycloak (OIDC)
  Shared Signals: Keycloak tells Apple about revoked sessions, changed credentials,
  disabled accounts (SSF transmitter, legacy SSE CAEP profile)
        |
        |  device assigned to the MDM (Automated Device Enrolment), or user-approved enrolment
        v
Jamf: Weblogin SSO app, Platform SSO profile, associated domain, IDE bridge settings
        |
        v
Mac: Platform SSO with Keycloak (University of Oslo extension), Secure Enclave key,
     macOS 27 login window and web-based sign-in
        |
        v
IDE bridge (DPoP), agents, model gateway: steps 6 to 10
```

| Part | Here | Status |
|---|---|---|
| ABM/ASM federation | client `apple-business`, `scripts/kc-apply-apple-business.sh` | Built, not run |
| Shared Signals to Apple | Keycloak SSF transmitter (experimental), receiver profile `SSE_CAEP` | Built, not run |
| Platform SSO, Keycloak side | [keycloak-psso-extension](https://github.com/unioslo/keycloak-psso-extension) 0.58b, `scripts/kc-apply-psso.sh` | Built, not run |
| Platform SSO, Mac side | [Weblogin SSO](https://github.com/unioslo/weblogin-mac-sso-extension), built with your Team ID | Not built |
| MDM profiles | `scripts/make-mdm-files.py`: Platform SSO, associated domain, IDE bridge | Generated, not tested |

## What you need

| Need | Why |
|---|---|
| Apple Business Manager or Apple School Manager, admin role for domains and federation | Federation is configured there |
| A domain you can verify there (DNS TXT record) | Users sign in as `name@that-domain`. Verifying, locking and capturing it stops new personal Apple Accounts on the domain |
| The id host reachable from the internet | Apple's servers call Keycloak. Tunnel profile, id host only ([REMOTE-ACCESS.md](REMOTE-ACCESS.md)) |
| Keycloak users with email at that domain, first and last name | Apple matches the Managed Apple Account by email and reads `given_name`, `family_name` |
| Apple Developer Program team | Build and sign Weblogin SSO; associated domains |
| A Mac (or macOS VM) enrolled in Jamf | Platform SSO; macOS 27 for the login window and web-based sign-in |

## Run

```sh
cd ~/SLATFF.Cloud/slatff-cloud
# .env: APPLE_TEAM_ID, WEBLOGIN_BUNDLE_ID, APPLE_FEDERATION_ADMIN (see .env.example)
bash scripts/mac-step11-apple.sh          # all; or: psso | apple
```

1. Creates `PSSO_OIDC_CLIENT_SECRET` and `APPLE_BUSINESS_CLIENT_SECRET` in `.env`, backs up the database.
2. Downloads and verifies the University of Oslo extension (`scripts/get-psso-extension.sh`:
   checksum, SSH signature, signer key matched against the maintainer's GitHub keys).
3. Adds `declarative-ui,ssf` to `KC_FEATURES`, restarts Keycloak.
4. Platform SSO realm settings, `apple-app-site-association`, MDM profiles in `dist/mdm/`.
5. Apple federation client and SSF transmitter. Prints the values for Apple Business Manager and
   copies the client secret to the clipboard.

## Apple Business Manager

Apple's steps ([Apple Business guide](https://support.apple.com/guide/business/federated-authentication-identity-provider-axmfcab66783/web)):

1. Add and verify the domain (DNS TXT record), lock it.
2. Domains > User sign-in and directory sync > Get Started > Custom Identity Provider:
   client ID `apple-business`, the secret, OpenID configuration URL
   `https://<ID_HOST>/realms/slatff/.well-known/openid-configuration`, SSF configuration URL
   `https://<ID_HOST>/realms/slatff/.well-known/ssf-configuration`.
3. Continue: Keycloak's sign-in page opens. Sign in as `APPLE_FEDERATION_ADMIN`
   (role `apple-federation-admin`; only that role may create Apple's SSF stream).
4. Turn on Domain Capture, then "Sign in with your Identity Provider" for the domain.
5. Test: a private browser window, sign in to an Apple service with a Managed Apple Account.

If Apple asks for push delivery to a URL that is not allowed, Keycloak refuses and logs it:
`docker compose logs keycloak | grep -i validPushUrls`. Put the URL in `APPLE_SSF_PUSH_URLS`
and run `bash scripts/kc-apply-apple-business.sh` again.

## Platform SSO on the Mac

1. Build Weblogin SSO in Xcode with your team; bundle ID = `WEBLOGIN_BUNDLE_ID`; associated
   domain `authsrv:<ID_HOST>` (remove the University of Oslo domains).
2. Jamf: the app package, `dist/mdm/slatff-platform-sso.mobileconfig`,
   `dist/mdm/slatff-associated-domains.mobileconfig`.
3. Register the Mac when macOS asks; sign in with a Keycloak user.
4. Check: Keycloak account console lists the registration; lock screen and (macOS 27) login
   window take the Keycloak password or the Secure Enclave key.

## Signals sent to Apple

| Keycloak event | SSF event |
|---|---|
| Session ended (logout, admin) | CAEP `session-revoked` |
| Password or credential changed | CAEP `credential-change` |
| User disabled / enabled | RISC `account-disabled` / `account-enabled` |
| User deleted (admin API, account console) | RISC `account-purged` |

Events for all users (`ssf.defaultSubjects=ALL`). Signed with the realm key. What Apple does with
each event is Apple's decision and not documented here.

## Limits

- Keycloak SSF is experimental; the SSE CAEP profile exists because Apple still uses the older draft.
- The id host must be public for Apple. The admin console and realm master stay blocked through
  the tunnel ([THREATS.md](THREATS.md)).
- Directory sync (SCIM) not covered: accounts are created at first sign-in.
- The Weblogin SSO extension has no signed release; you build and sign it.
- Platform SSO needs a registered device per user; registration token not required here (PoC).
- One stream per receiver client in Keycloak.

## Sources

[Keycloak SSF guide](https://www.keycloak.org/securing-apps/ssf-support) ·
[Keycloak: experimental SSF support](https://www.keycloak.org/2026/07/experimental-ssf-support) (Thomas Darimont) ·
[Apple Business: federated authentication with your IdP](https://support.apple.com/guide/business/federated-authentication-identity-provider-axmfcab66783/web) ·
[Apple Business: intro to federated authentication](https://support.apple.com/en-au/guide/business/axmb19317543/web) ·
[authentik: Apple Business integration](https://integrations.goauthentik.io/device-management/apple/) ·
University of Oslo [keycloak-psso-extension wiki](https://github.com/unioslo/keycloak-psso-extension/wiki) and
[weblogin-mac-sso-extension wiki](https://github.com/unioslo/weblogin-mac-sso-extension/wiki) ·
[OpenID Shared Signals Framework 1.0](https://openid.net/specs/openid-sharedsignals-framework-1_0-final.html)
