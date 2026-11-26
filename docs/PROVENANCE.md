# Provenance and credits

Proof of concept and personal project by Christoph Fellner, started November 2026. Built from
public documentation, public standards and open source projects only. It contains no code,
configuration, documents, customer information or other material from any employer, past or
present.

## Ideas and reading that shaped it

- Lothar Zeitler (ForFoxes), series "Souveräner Arbeitsplatz: Bausteine statt Big-Tech-Bundle",
  November 2026: the five questions in the README. [Conclusion](https://forfoxes.ninja/souveraener-arbeitsplatz-bausteine-statt-big-tech-bundle-das-fazit/),
  parts on [search](https://forfoxes.ninja/eu-parlament-wechselt-zu-qwant-wie-europaeisch-ist-das/),
  [ODF](https://forfoxes.ninja/odf-pflicht-ab-2027-was-verwaltungen-jetzt-wissen-muessen/),
  [e-mail](https://forfoxes.ninja/wem-gehoert-ihre-mailbox-souveraene-e-mail-im-vergleich/),
  [chat](https://forfoxes.ninja/matrix-statt-teams-souveraener-chat-fuer-behoerden-und-kmu/), and a
  part on Nextcloud
- IETF [draft-ietf-wimse-aims](https://datatracker.ietf.org/doc/draft-ietf-wimse-aims/): authority
  narrows along the chain (step 5); Steve Hutchinson's
  [article on AIMS](https://www.linkedin.com/pulse/aims-why-matters-your-agentic-identity-strategy-steve-hutchinson-xk1ce)
  for the reading of it
- Keycloak team blog posts: [standard token exchange](https://www.keycloak.org/2025/05/standard-token-exchange-kc-26-2),
  [JWT authorization grant and identity chaining](https://www.keycloak.org/2026/01/jwt-authorization-grant),
  [Keycloak 26.8.0](https://www.keycloak.org/2026/10/keycloak-2680-released)
- Skycloak, [token exchange delegation for AI agents in Keycloak 26.8](https://skycloak.io/blog/keycloak-26-8-token-exchange-delegation-ai-agents/):
  background for step 10; behaviour checked against the Keycloak source (below)

## Standards

Listed with links in [STANDARDS.md](STANDARDS.md): OpenID Connect Core; RFC 6749, 7009, 7519,
7523, 7636, 7638, 8252, 8628, 8693, 8707, 9449; W3C WebAuthn; IETF drafts ID-JAG and AIMS.

## Software and documentation

- [Keycloak](https://www.keycloak.org): documentation, container images, and
  [source code](https://github.com/keycloak/keycloak) to use its extension interfaces (step 8) and
  to check the delegation behaviour (step 10: `TokenExchangeDelegationProvider`,
  `ClientAgentDelegationTest`, `OIDCLoginProtocolFactory`, tag 26.8.2)
- [Caddy](https://caddyserver.com/docs/) and the [caddy-dns/cloudflare](https://github.com/caddy-dns/cloudflare) module
- [Open WebUI](https://docs.openwebui.com) documentation (Keycloak and SSO pages)
- [Ollama](https://ollama.com) and Meta's [Llama 3.2](https://ollama.com/library/llama3.2) models
- University of Oslo: [keycloak-psso-extension](https://github.com/unioslo/keycloak-psso-extension)
  and [weblogin-mac-sso-extension](https://github.com/unioslo/weblogin-mac-sso-extension)
  (README, wiki and releases)
- Nordeck: [jitsi-keycloak-adapter-v2](https://github.com/nordeck/jitsi-keycloak-adapter-v2);
  Jitsi: [docker-jitsi-meet](https://github.com/jitsi/docker-jitsi-meet) and the [handbook](https://jitsi.github.io/handbook/)
- Nextcloud: [container image](https://github.com/nextcloud/docker) and the [user_oidc](https://github.com/nextcloud/user_oidc) app
- Cloudflare: [tunnel](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/) and DNS documentation
- Apple: public deployment and developer documentation and the public device-management
  schema ([github.com/apple/device-management](https://github.com/apple/device-management))
- IDE vendor documentation: Apple Xcode, Microsoft Visual Studio and VS Code, Qt, JetBrains
- Python libraries [aiohttp](https://github.com/aio-libs/aiohttp), [PyJWT](https://github.com/jpadilla/pyjwt)
  and [cryptography](https://github.com/pyca/cryptography) (gateway, tools, tests)

Licences of the software this repository configures: [NOTICE](../NOTICE).

The University of Oslo Keycloak extension is licensed GPL-2.0-or-later. It is not copied,
vendored or modified here; SLATFF.Cloud only documents how to obtain and configure it.

## How it was made

The ideas, the design decisions and the testing are mine. Claude (Anthropic) wrote the code,
the scripts and the documentation. Every result marked as tested in [TESTING.md](TESTING.md)
was run by me on my own setup, with the date.
