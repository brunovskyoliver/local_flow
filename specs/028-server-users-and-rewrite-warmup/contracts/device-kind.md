# Contract: device kind in `pair` and `enroll`

Extends `specs/014-remote-dictation-server/contracts/remote-channel.md` and `specs/027-remote-pairing/contracts/pairing.md`. Becomes part of `protocol/schemas/remote-message.schema.json` and `remote-identity.schema.json`.

## Identity: `features`

`GET /v1/remote/identity` gains an optional array:

```json
{ "schema_version": 1, "server": "flowd/…", "protocol_versions": [1], "suite": "…",
  "server_key": "…", "fingerprint": "…", "features": ["device_kind"] }
```

| Feature | Meaning |
|---|---|
| `device_kind` | `pair` and `enroll` accept `device_kind` |
| `device_invite` | the session ops in [device-invites.md](device-invites.md) may be offered; `ready.capabilities.ops` stays the authority (added with User Story 4) |

Absent `features` means none. Clients ignore unknown feature names and unknown identity keys.

## `pair` and `enroll`: `device_kind`

```json
{ "schema_version": 1, "type": "pair", "op": 1, "pairing_token": "lfp_…",
  "device_name": "Oliver's MacBook Pro", "device_kind": "mac",
  "device_key": "…", "signature": "…" }
```

| Rule | |
|---|---|
| Values | `mac`, `windows`, `iphone` |
| Optional | Absent stores NULL ("Unknown") |
| Other value | `invalid_message`; nothing is redeemed or enrolled |
| When sent | Only when the identity's `features` includes `device_kind`. Older servers refuse unknown fields |
| Signature | Unchanged: the device kind is not signed, as the device name isn't |
| Stored | `devices.kind`. A NULL is filled by a later enroll or pair from the same key; a stored kind never changes |

What each client sends:

| Client | Value |
|---|---|
| Rust desktop on macOS | `mac` |
| Rust desktop on Windows | `windows` |
| Swift Mac app | `mac` |
| iOS app | `iphone` |

The platform layer chooses the value; `flow-core` receives it in `enrollment::Parts`, so it needs no target checks.

## Logs

The `remote … op=pair` and `op=enroll` lines may add `kind=<value|none>`. The kind is not content and not an identifier of a person.
