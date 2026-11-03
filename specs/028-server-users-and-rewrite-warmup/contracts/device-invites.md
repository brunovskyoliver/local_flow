# Contract: device invites and "Your devices"

**Blocked** until constitution 7.0.0 (principle 15) and ADR 0039 are accepted. Extends `specs/014-remote-dictation-server/contracts/remote-channel.md` and `specs/027-remote-pairing/contracts/pairing.md`; becomes part of `protocol/schemas/remote-message.schema.json`. Design reasons: research R13. Storage: data-model.md, version 5.

All three operations run on an authenticated **session** channel and are scoped to the channel's principal (user and device from the verified access token). No field names a user. They are listed in `ready.capabilities.ops` as `device_invite`, `device_confirm` and `account_devices`; a client that doesn't see them there gets `not_offered` and hides the controls. The identity's `features` gains `device_invite` at the same time.

Signatures are DER ECDSA P-256 over SHA-256 of the concatenated parts, verified with the device's stored X9.63 key, like `pair` and `refresh`.

## `device_invite`

```json
{ "schema_version": 1, "type": "device_invite", "op": 7 }
```

Reply:

```json
{ "schema_version": 1, "type": "device_invite_reply", "op": 7, "invite_id": 12,
  "pairing_token": "lfp_…", "expires_at": "2026-11-03T10:20:00Z" }
```

The token has the 027 format (server key plus 32 random bytes), stored only as its hash, with purpose `invite`, the caller's user as target, 10 minutes of life and one use. A newer invite from the same device revokes its earlier `live` one. The client builds the existing 027 link, `localflow://pair?address=<origin>#token=<token>`, from the addresses it knows for this server (the one that worked last first), and shows it as text, link and QR code.

| Condition | Reply |
|---|---|
| Caller's device or user not approved | `not_approved` |
| 3 open invites for the user, or 10 created by this device in the last hour, or 100 live tokens on the server | `busy` |
| Op not served | `not_offered` |

Audit `invite_create`, actor `device:<id>`, target `token:<id>`. The token value never reaches logs or audit rows.

## Redeeming an invite: `pair`

The new device sends the unchanged `pair` message (with `device_kind` per [device-kind.md](device-kind.md)). For an invite the reply is:

```json
{ "schema_version": 1, "type": "enrolled", "op": 1, "state": "pending",
  "refresh_token": "lfr_…", "inviter_device_key": "<base64url X9.63, 65 bytes>",
  "confirm_by": "2026-11-03T10:24:30Z" }
```

`inviter_device_key` and `confirm_by` appear only in replies to invite redemptions. The device then refreshes as a pending device does today: sessions answer `not_approved` until it is confirmed.

| Condition | Reply |
|---|---|
| Unknown, expired, revoked, declined or already redeemed invite | `pairing_token_invalid` |
| Key enrolled to another user | `unauthorized`, invite unspent. Client shows "This device already belongs to another account on this server." |
| Key enrolled to the same user | `pairing_token_invalid`, invite unspent: the device is already on the account |
| Inviting device or user revoked meanwhile | `pairing_token_invalid` |

## Comparison code

Both devices show `code = (uint32_be(SHA-256("localflow-v1-device-code" ‖ inviter_key ‖ new_key ‖ pair_binding)[0..4]) mod 1000000)`, as six digits with leading zeros, grouped `123 456`. `inviter_key` and `new_key` are 65-byte X9.63 keys; `pair_binding` is the 32-byte binding of the channel that carried `pair`. Test vectors: `fixtures/remote/device-code.json`, shared by the Go, Rust and Swift tests.

## `account_devices`

List:

```json
{ "schema_version": 1, "type": "account_devices", "op": 8, "action": "list" }
```

```json
{ "schema_version": 1, "type": "account_devices_reply", "op": 8, "devices": [
  { "id": 3, "name": "Oliver's iPhone", "kind": "iphone", "state": "approved",
    "enrolled_at": "…Z", "last_seen_at": "…Z", "connected": true, "this_device": false },
  { "id": 9, "name": "iPad", "kind": null, "state": "pending",
    "enrolled_at": "…Z", "last_seen_at": null, "connected": false, "this_device": false,
    "invite": { "invite_id": 12, "device_key": "…", "pair_binding": "…", "confirm_by": "…Z" } }
] }
```

Only the caller's user's devices, at most 100, ordered by `id`. Revoked devices are left out. `invite` appears only on a pending device that redeemed an invite **this caller created**, and carries what the caller needs for the code and the confirmation. While its invite sheet is open the inviting device sends `list` every 2 s; it stops when the sheet closes.

Revoke:

```json
{ "schema_version": 1, "type": "account_devices", "op": 9, "action": "revoke", "device_id": 9 }
```

Reply `{ "type": "account_devices_reply", "op": 9, "devices": [ … ] }` with the updated list. Revoking a device of another user, or an unknown one, answers `unauthorized` and writes a `cross_user_attempt` row. Revoking the caller's own device answers first, then the channel closes as for any revocation. Revocation closes the device's channels within 2 s (SC-005), through the existing watcher and `Listener.Revoke`. Revoking a pending invited device also declines its invite. Audit `revoke`, actor `device:<caller>`, target `device:<id>`.

## `device_confirm`

```json
{ "schema_version": 1, "type": "device_confirm", "op": 10, "invite_id": 12,
  "accept": true, "signature": "<base64url DER>" }
```

The signature covers `"localflow-v1-device-confirm"` ‖ the caller's own session channel binding ‖ `invite_id` as 8 bytes big-endian ‖ new device key ‖ `pair_binding`. It is checked against the stored key of the device that created the invite, so only that device can confirm, and a captured confirmation can't be replayed on another channel. A decline (`accept: false`) carries the same signature.

Reply:

```json
{ "schema_version": 1, "type": "device_confirm_reply", "op": 10, "state": "approved" }
```

`state` is `approved` or `removed`. On `approved` the pending device becomes approved within the same transaction, and its next refresh opens sessions. On `removed` it is deleted.

| Condition | Reply |
|---|---|
| Bad signature, or caller didn't create the invite | `unauthorized` |
| Invite not `awaiting_confirm`, or past `confirm_by` | `pairing_token_invalid` |

Audit `invite_confirm` or `invite_decline`. Past `confirm_by` the server sweeps the invite to `declined` and deletes the device (audit `invite_expire`, actor `system`).

## Never

- An invite can't target another user, an existing device or admin rights; there are no admin ops on the remote listener.
- No device opens a listener; everything goes through the server (FR-024).
- Codes, tokens, bindings and keys never reach logs. `scripts/check-remote-logs.sh` keeps rejecting `lfp_`.

## UI identifiers

Rust: `settings.addDevice`, `settings.addDeviceQR`, `settings.addDeviceCode`, `settings.addDeviceConfirm`, `settings.addDeviceDecline`, `settings.yourDevices`, `settings.yourDeviceRemove`, `settings.yourDeviceNotMe`. iOS: `server.inviteCode`, `server.yourDevices`, `server.yourDeviceRemove`, `server.yourDeviceNotMe`.
