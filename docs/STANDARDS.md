# Goal and standards

## Goal

An open source, self-hosted identity layer for people and AI, built on the OpenID Connect and
OAuth 2.0 RFCs: sign-in, who may use which AI model and data, AI tool access on the user's
behalf, audit. Each part uses an open standard, so it can be replaced.

| Function | SLATFF.Cloud | Status |
|---|---|---|
| Sign-in, MFA, roles | Keycloak | Live |
| AI access by user, role and data label | Model gateway | Live |
| AI tool calls with a narrow, per-tool token | Gateway + token exchange (RFC 8693) | Live (impersonation, see below) |
| AI in developer tools as the user | IDE bridge (Xcode) | Live on macOS |
| IDE bridge settings and install by MDM (Jamf) | Managed preferences profile + install script ([MDM.md](MDM.md)) | Prepared, not tested |
| Mac sign-in with the company account | Keycloak + University of Oslo Platform SSO extension | Built, not tested ([APPLE.md](APPLE.md)) |
| Apple Business / School Manager accounts from the company IdP | Keycloak OIDC + Shared Signals transmitter | Built, not tested ([APPLE.md](APPLE.md)) |
| Agent acting for a user, user and agent in every token | Keycloak delegation (preview) + gateway agent policy | Live 26 Nov 2026, one hop ([AGENTS.md](AGENTS.md)) |
| App-to-app access for agents | ID-JAG issuer (Keycloak extension) + Keycloak receiver | Live 25 Nov 2026 (gaps in [APP-TO-APP.md](APP-TO-APP.md)) |

## Standards

| Standard | Used for | Status |
|---|---|---|
| [OpenID Connect Core 1.0](https://openid.net/specs/openid-connect-core-1_0.html) | Sign-in, ID tokens | Live |
| [RFC 6749](https://www.rfc-editor.org/rfc/rfc6749) OAuth 2.0 | Access and refresh tokens | Live |
| [RFC 7519](https://www.rfc-editor.org/rfc/rfc7519) JWT | Tokens checked by gateway and tool | Live |
| [RFC 7636](https://www.rfc-editor.org/rfc/rfc7636) PKCE | IDE bridge device sign-in; agent-console browser sign-in | Tested 25 Nov 2026 (bridge), 26 Nov 2026 (agent-console) |
| [RFC 8252](https://www.rfc-editor.org/rfc/rfc8252) OAuth for native apps | Agent sign-in in the browser with a loopback redirect (127.0.0.1) | Tested 26 Nov 2026 |
| [RFC 8628](https://www.rfc-editor.org/rfc/rfc8628) Device Authorization Grant | IDE bridge sign-in | Tested 25 Nov 2026 |
| [RFC 7009](https://www.rfc-editor.org/rfc/rfc7009) Token Revocation | IDE bridge logout ends the session | Tested 25 Nov 2026 |
| [RFC 9449](https://www.rfc-editor.org/rfc/rfc9449) DPoP | IDE bridge tokens bound to a key; gateway checks the proof | Tested 26 Nov 2026 (Xcode through the bridge; key in Keychain, not Secure Enclave) |
| [RFC 7638](https://www.rfc-editor.org/rfc/rfc7638) JWK Thumbprint | Key binding in DPoP (`cnf.jkt`) and the agent's key id | Tested 26 Nov 2026 (with DPoP and step 10) |
| [WebAuthn](https://www.w3.org/TR/webauthn/) / FIDO2 passkeys | People sign in without a password | Tested 26 Nov 2026 (Touch ID in Safari, Apple Passwords) |
| [RFC 7523](https://www.rfc-editor.org/rfc/rfc7523) JWT Authorization Grant | App B redeems the ID-JAG (Keycloak receiver) | Tested 25 Nov 2026 |
| [RFC 7523](https://www.rfc-editor.org/rfc/rfc7523) client authentication (`private_key_jwt`) | Agent signs in with its own key, no secret | Tested 26 Nov 2026 (key in Keychain, not Secure Enclave) |
| [RFC 8693](https://www.rfc-editor.org/rfc/rfc8693) Token Exchange | Per-tool token for AI tool calls; agent acting for a user | Tool calls: audience and scope narrowed, no `act` ([DELEGATION.md](DELEGATION.md)). Agents: `actor_token` and `act`, one hop, tested 26 Nov 2026 ([AGENTS.md](AGENTS.md)) |
| [OpenID Shared Signals Framework 1.0](https://openid.net/specs/openid-sharedsignals-framework-1_0-final.html) | Keycloak tells Apple about sessions, credentials, accounts | Built, not tested; Keycloak feature experimental; Apple uses the older SSE profile |
| [CAEP 1.0](https://openid.net/specs/openid-caep-1_0-final.html), [RISC 1.0](https://openid.net/specs/openid-risc-1_0-final.html) | Event types: session-revoked, credential-change; account-disabled, -enabled, -purged | Built, not tested |
| [RFC 8417](https://www.rfc-editor.org/rfc/rfc8417) SET, [RFC 8935](https://www.rfc-editor.org/rfc/rfc8935) push, [RFC 8936](https://www.rfc-editor.org/rfc/rfc8936) poll | Signed events and their delivery | Built, not tested |
| [Apple Platform SSO](https://support.apple.com/guide/deployment/platform-sso-for-mac-dep7bbb05313/web) | Mac sign-in with Keycloak (Secure Enclave key; macOS 27 web-based method) | Built, not tested |
| [draft-ietf-wimse-aims](https://datatracker.ietf.org/doc/draft-ietf-wimse-aims/) | Agent identity model (IETF draft) | Read; not implemented |
| [draft-ietf-oauth-identity-assertion-authz-grant-06](https://datatracker.ietf.org/doc/draft-ietf-oauth-identity-assertion-authz-grant/) (ID-JAG) | App-to-app access for agents | Issuer tested 25 Nov 2026 (request, claims, typ, policy, errors). Receiver is Keycloak's, based on draft -01: takes scope from the request, not the ID-JAG. Not done: IdP metadata, refresh token or SAML subject, tenant, DPoP |

"Live" and "Tested" mean ticked in [TESTING.md](TESTING.md) with a date. Nothing here is
certified; "compliant" is only claimed where a row says Tested and the spec's required parts
are covered.

Known security gaps and what was hardened: [THREATS.md](THREATS.md). Sources and credits: [PROVENANCE.md](PROVENANCE.md).
