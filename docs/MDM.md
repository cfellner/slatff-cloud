# IDE bridge with MDM (Jamf)

Part B, steps 3 and 4. The organisation sets where the bridge connects and runs it for every
user. The user only signs in.

## What MDM sets

Preference domain `cloud.slatff.ide-bridge`:

| Key | Example | |
|---|---|---|
| `Issuer` | `https://<ID_HOST>/realms/slatff` | Keycloak realm |
| `Gateway` | `https://<AI_HOST>/gateway/v1` | model gateway |
| `IDE` | `xcode` | label in the audit log |
| `Port` | `11435` | local port |
| `ClientID` | (not set) | default `ide-bridge` |

Managed settings win over environment and the user's config file. `bridge.py configure` does
not change them. `bridge.py config` shows each setting and its source.

## Make the files

```sh
cd ~/SLATFF.Cloud/slatff-cloud
python3 scripts/make-mdm-files.py
```

Writes `dist/mdm/` (not in git):

| File | Use in Jamf |
|---|---|
| `cloud.slatff.ide-bridge.plist` | Configuration Profile > Application & Custom Settings > Upload, domain `cloud.slatff.ide-bridge` |
| `slatff-ide-bridge-settings.mobileconfig` | same settings as a profile; for Upload, or another MDM (Iru: Custom Profile) |
| `jamf-install-ide-bridge.sh` | Settings > Scripts; policy "Once per computer" |
| `jamf-uninstall-ide-bridge.sh` | Settings > Scripts; policy to remove |
| `xcode-coding-assistant-off.mobileconfig` | test profile, step 4 |
| `xcode-on-device-models-off.mobileconfig` | test profile, step 4 |

The install script puts `bridge.py` in `/Library/Application Support/SLATFF/` (root-owned) and a
LaunchAgent in `/Library/LaunchAgents/cloud.slatff.ide-bridge.plist` (every user, at login). It
replaces a LaunchAgent the user installed. Needs `/usr/bin/python3` (Xcode or Command Line Tools).

Each user then signs in once:

```sh
/usr/bin/python3 "/Library/Application Support/SLATFF/bridge.py" login
/usr/bin/python3 "/Library/Application Support/SLATFF/bridge.py" key | pbcopy
```

## Step 4: Xcode controls

| Profile | Key in payload `com.apple.dt.Xcode` | Source |
|---|---|---|
| coding assistant off | `CodingAssistantAllowExternalIntegrations` = false | Apple: Xcode docs, Mac restrictions (macOS 26) |
| on-device models off | `IDEProhibitOnDeviceModelInteraction` = true | not in Apple's public docs; effect to be tested |

Record for each: what Xcode shows in Settings > Intelligence, whether the bridge provider still
works, whether agents (Claude Agent, Codex) still work.

Open question: can MDM preset the chat provider (URL, key header) or "Allow external agents to
use Xcode tools"? No documented key found.

## Iru

Not tested. Iru takes the `.mobileconfig` files as Custom Profile and the install script as
Custom Script (run once). Same files.
