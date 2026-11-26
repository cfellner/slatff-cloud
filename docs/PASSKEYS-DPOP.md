# Passkeys and DPoP (step 9)

Follows the FIDO idea "prove you hold a key, never send a secret" in two places:

| Where | Before | Now | Standard |
|---|---|---|---|
| People signing in | password | passkey (Touch ID, iCloud Keychain, security key) | WebAuthn / FIDO2, Keycloak 26.4+ supported |
| IDE bridge tokens | bearer: a copied token works anywhere | bound to a key the bridge holds | DPoP, RFC 9449, Keycloak 26.4+ supported |

Open WebUI still uses plain Bearer tokens (it has no DPoP support).

## DPoP in the IDE bridge

- The bridge creates an RSA key once (2048 bit) and keeps it in the OS secret store
  (macOS Keychain). Standard library only, RS256.
- Every token request (device sign-in, refresh, logout) and every gateway request carries a
  DPoP proof signed with that key. Keycloak puts the key's thumbprint into the token (`cnf.jkt`).
- `SLATFF_DPOP=off` (or MDM key `DPoP` = `off`) turns it off.

## DPoP in the gateway

A token with `cnf.jkt` is accepted only with `Authorization: DPoP` and a proof that:
is signed by that key, has `typ` `dpop+jwt`, matches method and URL (`DPOP_HTU_BASE` + path),
is at most 60 s old, carries `ath` (hash of this token), and was not seen before.
Clients in `DPOP_REQUIRED_CLIENTS` (default `ide-bridge`) must send bound tokens.
The audit line has `"dpop": true` for bound tokens.

## Run

```sh
cd ~/SLATFF.Cloud/slatff-cloud
bash scripts/mac-step9-passkeys-dpop.sh
```

Then sign the bridge in again, ask in Xcode, check `"dpop": true` in the audit, and set up a
passkey for alice (steps printed by the script).

Offline: `bash model-gateway/tests/run.sh` (11 DPoP checks) and `bash ide-bridge/tests/run.sh`.

## Limits

- The bridge key is a software key in the Keychain, not in the Secure Enclave (Python's
  standard library cannot reach it). Next: a small Swift helper or Platform SSO keys.
- Replay cache is in memory per gateway process.
- No DPoP nonces (`DPoP-Nonce`); Keycloak does not require them by default.
- Tool calls: the gateway exchanges the user's token; Keycloak's handling of DPoP-bound
  subject tokens in token exchange is not tested yet.
