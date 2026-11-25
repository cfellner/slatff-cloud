# AI access

Question: who may use which AI, from which device, on whose hardware?

## Layers

| Layer | Decides | In SLATFF.Cloud |
|---|---|---|
| Device | which AI features and providers exist on the device | not managed here (MDM, see below) |
| Identity | who the person is and what they may use | Keycloak realm, roles, groups |
| Model and tools | what reaches the model and the tools | model gateway, label policy, delegation, audit |

## What is shown

- Sign-in only through Keycloak; no role, no account (bob refused, 23 Nov 2026).
- Every model request checked with the user's own token at the gateway; model and label policy; audit line ([MODEL-GATEWAY.md](MODEL-GATEWAY.md)).
- Same assistant, different knowledge by group ([KNOWLEDGE-DEMO.md](KNOWLEDGE-DEMO.md)).
- Tools get a narrowed, exchanged token, never the user's ([DELEGATION.md](DELEGATION.md)).
- IDEs use the same path ([IDE-BRIDGE.md](IDE-BRIDGE.md)).

## Not shown

- Data-loss prevention for unlabelled content.
- Isolation of the model runtime from other programs on the same host.
- Mid-session revocation.
- Control over what a model learned in training. Access sovereignty is not knowledge sovereignty.

## Apple device controls

From Apple's device-management schema (github.com/apple/device-management) and the Mac
restrictions page. Supervised devices. Check the schema for your OS version before use.

| Control | Key / declaration | Effect |
|---|---|---|
| External intelligence | `com.apple.configuration.external-intelligence.settings`: `Enabled`, `AllowSignIn`, `AllowedWorkspaceIDs` | off, sign-in off, or one workspace (Apple's integrated providers only, not a self-hosted workspace) |
| Apple Intelligence | `com.apple.configuration.intelligence.settings` | per feature: Writing Tools, Genmoji, Image Playground, Visual Intelligence, per app |
| Siri AI | `com.apple.configuration.siri.settings`: `AllowSiriAI` (macOS 27) | Siri AI features off |
| Xcode coding assistant | `CodingAssistantAllowExternalIntegrations` = false in `com.apple.dt.Xcode` (macOS 26) | assistant off |
| Predictive code completion | `IDEProhibitOnDeviceModelInteraction` = true in `com.apple.dt.Xcode` | off |
| App launch (macOS 27) | `com.apple.configuration.app.settings`: `AllowedBinaries`, `DeniedBinaries` | allow or block binaries by team ID, signing ID, hash |

The 15.x restriction keys for external intelligence are deprecated from 26.4 in favour of the
declarations above.

Gaps found (Nov 2026): no administrator setting that limits what an arbitrary agent or MCP
server may do on a Mac, and no system-wide audit of agent actions. macOS 27.3 adds per-app and
per-folder scopes for System & App Protection Override and Full Disk Access; MDM keys for them
were not published at the time of writing.

## Combined

1. MDM decides which AI the device may use.
2. Platform SSO signs the person in at the device with Keycloak ([PLATFORM-SSO.md](PLATFORM-SSO.md)).
3. Keycloak and the gateway decide what that person gets from the self-hosted AI.

## Model licence

The test model (`SLATFF_MODEL`) has its own licence. Check it before use.
