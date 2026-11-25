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
| Mac sign-in with the company account | Keycloak + University of Oslo Platform SSO extension | Prepared, not tested |
| App-to-app access for agents | Not built | Planned |

## Standards

| Standard | Used for | Status |
|---|---|---|
| OpenID Connect Core 1.0 | Sign-in, ID tokens | Live |
| RFC 6749 OAuth 2.0 | Access and refresh tokens | Live |
| RFC 7519 JWT | Tokens checked by gateway and tool | Live |
| RFC 7636 PKCE | Device sign-in of the IDE bridge | Tested 25 Nov 2026 |
| RFC 8628 Device Authorization Grant | IDE bridge sign-in | Tested 25 Nov 2026 |
| RFC 7009 Token Revocation | IDE bridge logout ends the session | Tested 25 Nov 2026 |
| RFC 8693 Token Exchange | Per-tool token for AI tool calls | Partial: audience and scope narrowed; impersonation only, no `act` claim. Full delegation is step 7 ([DELEGATION.md](DELEGATION.md)) |
| draft-ietf-wimse-aims | Agent identity model (IETF draft) | Read; not implemented |
| Identity Assertion Authorization Grant (IETF draft) | App-to-app access for agents | Not built |

"Live" and "Tested" mean ticked in [TESTING.md](TESTING.md) with a date. Nothing here is
certified; "compliant" is only claimed where a row says Tested and the spec's required parts
are covered.
