# Provenance

Proof of concept and personal project by Christoph Fellner, started November 2026. Built from public documentation,
public standards and open source projects only:

- Keycloak documentation, container images and source code (to use its extension interfaces)
- Caddy documentation and the caddy-dns/cloudflare module
- Open WebUI documentation (Keycloak and SSO pages)
- University of Oslo: keycloak-psso-extension and weblogin-mac-sso-extension (README,
  wiki and releases)
- Nordeck: jitsi-keycloak-adapter-v2; Jitsi: docker-jitsi-meet and handbook
- Nextcloud: container image and the user_oidc app documentation
- Cloudflare: tunnel and DNS documentation
- Apple: public deployment and developer documentation and the public device-management
  schema (github.com/apple/device-management)
- IETF: RFC 7009, RFC 7523, RFC 7636, RFC 8628, RFC 8693, RFC 8707,
  draft-ietf-oauth-identity-assertion-authz-grant, draft-ietf-wimse-aims
- IDE vendor documentation: Apple Xcode, Microsoft Visual Studio and VS Code, Qt, JetBrains
- Lothar Zeitler, ForFoxes series "Souveräner Arbeitsplatz: Bausteine statt Big-Tech-Bundle"
  (November 2026): the five questions in the README

It contains no code, configuration, documents, customer information or other material
from any employer, past or present.

The University of Oslo Keycloak extension is licensed GPL-2.0-or-later. It is not copied,
vendored or modified here; SLATFF.Cloud only documents how to obtain and configure it.

## How it was made

The ideas, the design decisions and the testing are mine. Claude (Anthropic) wrote the code,
the scripts and the documentation. Every result marked as tested in [TESTING.md](TESTING.md)
was run by me on my own setup, with the date.
