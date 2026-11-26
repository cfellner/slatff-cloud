# Docs

Read in this order.

## Start

| Page | What it covers |
|---|---|
| [../README.md](../README.md) | What SLATFF.Cloud is, status, requirements |
| [GUIDE.md](GUIDE.md) | Setup steps 1 to 10, troubleshooting |
| [STANDARDS.md](STANDARDS.md) | Goal, standards and their status |
| [HOW-IT-WORKS.md](HOW-IT-WORKS.md) | Parts and how a request flows |
| [AI-ACCESS.md](AI-ACCESS.md) | Why Keycloak decides AI access |
| [NETWORK.md](NETWORK.md) | Host names, DNS, certificates |

## Parts

| Page | What it covers |
|---|---|
| [MODEL-GATEWAY.md](MODEL-GATEWAY.md) | Token check, model and label policy, audit (step 3) |
| [DELEGATION.md](DELEGATION.md) | Tool calls with token exchange, RFC 8693 (step 5) |
| [IDE-BRIDGE.md](IDE-BRIDGE.md) | Xcode and other IDEs as the signed-in user (step 6) |
| [APP-TO-APP.md](APP-TO-APP.md) | App-to-app access with ID-JAG (step 8) |
| [PASSKEYS-DPOP.md](PASSKEYS-DPOP.md) | Passkeys for people, DPoP-bound tokens for the IDE bridge (step 9) |
| [AGENTS.md](AGENTS.md) | An agent acting for a user: act claim, consent, kill switch (step 10) |
| [MDM.md](MDM.md) | IDE bridge settings and install with Jamf; Xcode controls |
| [IDES.md](IDES.md) | IDE support matrix, testers wanted |
| [KNOWLEDGE-DEMO.md](KNOWLEDGE-DEMO.md) | Same assistant, different answers by group |
| [APPLE.md](APPLE.md) | Apple end to end: ABM/ASM federation, Shared Signals, Platform SSO (step 11) |
| [PLATFORM-SSO.md](PLATFORM-SSO.md) | Mac sign-in through Keycloak |
| [FILES.md](FILES.md) | Nextcloud: files, calendars, contacts |
| [MEET.md](MEET.md) | Jitsi meetings (experimental) |
| [REMOTE-ACCESS.md](REMOTE-ACCESS.md) | Cloudflare tunnel |

## Contributing

| Page | What it covers |
|---|---|
| [../CONTRIBUTING.md](../CONTRIBUTING.md) | How to help, tests, rules |
| [TESTING.md](TESTING.md) | What is tested and when. Only ticked items count as working. |
| [THREATS.md](THREATS.md) | Security review: fixed, open, checked |
| [PROVENANCE.md](PROVENANCE.md) | Sources and how this repo was built |
