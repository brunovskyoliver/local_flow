# Contract: pairing

Extends `specs/014-remote-dictation-server/contracts/remote-channel.md` and `flowd-cli.md`. Becomes part of `protocol/schemas/remote-message.schema.json`.

## Channel: `pair` (hello purpose `enroll`, within 5 minutes of `ready`)

```json
{ "schema_version": 1, "type": "pair", "op": 1, "pairing_token": "lfp_…",
  "device_name": "Oliver's iPhone", "device_key": "<base64url X9.63 P-256, 65 bytes>",
  "signature": "<base64url DER ECDSA over \"localflow-v1-pair\" ‖ binding>" }
```

Reply: `{ "type": "enrolled", "op": 1, "state": "approved", "refresh_token": "lfr_…" }`, then the client refreshes as usual.

| Condition | Reply |
|---|---|
| Bad signature | `unauthorized` |
| Unknown, expired, used by another key, or revoked token | `pairing_token_invalid` |
| Device key enrolled to another user | `unauthorized`, token unspent |
| Device key already revoked, or the token's target user revoked | `revoked`, token unspent |
| Too many hellos | `busy` (existing limit) |

Redemption is one immediate transaction. Token values never reach logs or audit rows.

## CLI

```
flowd admin --data-dir D [--dev] token create --label L [--user ID] [--ttl 1h|24h|7d] [--address ORIGIN] [--json]
flowd admin --data-dir D [--dev] token list [--json]
flowd admin --data-dir D [--dev] token revoke ID
```

`create` needs the identity key, so it fails with "unlock the login Keychain" over SSH; `list` and `revoke` don't need the key. `create` prints the token once, plus the app link if `--address` was given. Exit codes follow `flowd admin`: 1 usage or cap, 2 not found, 3 invalid transition. `--json` for `create`: `{id,label,expires_at,token,link}`; for `list`: `[{id,label,state,user_id,device_id,created_at,expires_at}]`, never a hash or value.

## Listener

`--remote-listen` accepts any IP literal `host:port`, still distinct from `--listen`. Client address rules: research R7.

## Client address rule

FR-012a. Shared by `RemoteDictationSettings.origin`, with a table test. `channelURL` maps `http` to `ws` and `https` to `wss`.

## UI identifiers

Mac: `settings.remotePairWithToken`, `settings.remotePairToken`, `settings.remoteAddressEdit`, `settings.serverMode`, `settings.serverModeAddress`, `settings.tokenCreate`, `settings.tokenRevoke`. iOS: `server.pairWithToken`, `server.pairToken`. Existing identifiers don't change.
