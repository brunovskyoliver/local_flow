# Data model: Feature 028

Schema versions 4 and 5 of `flowd-remote.sqlite`. Version 3 is in `specs/027-remote-pairing/data-model.md`. Each migration writes a consistent `VACUUM INTO` copy beside the database first (`flowd-remote.pre-v4.sqlite`, `flowd-remote.pre-v5.sqlite`, mode 0600), generalising `copyBeforeV3` in `server/internal/accounts/store.go`, because an older flowd refuses a newer schema and the copy is the way back.

Version 4 belongs to User Story 3. Version 5 belongs to User Story 4 and is written only after constitution 7.0.0 and ADR 0039 are accepted.

## Version 4 (User Story 3)

### devices (column added)

| Column | Constraint |
|---|---|
| kind | TEXT NULL, CHECK `kind IS NULL OR kind IN ('mac', 'windows', 'iphone')`. NULL is shown as "Unknown" |

Set from `device_kind` on `pair` and `enroll` ([contracts/device-kind.md](contracts/device-kind.md)). A later enrollment of the same key with a kind fills a NULL; it never changes a kind already stored.

### users (no schema change)

A user created by name has `provider = 'token'`, `subject = 'named:<32 lowercase hex>'`, `display` = the name (1-320 bytes, no control characters) and starts `approved`. `display` can be renamed.

### audit (rebuilt)

`action` gains `user_create` and `rename`. Targets and outcomes are unchanged.

## Version 5 (User Story 4, after the amendment)

### pairing_tokens (rebuilt)

| Column | Constraint |
|---|---|
| id … created_by | As version 3 |
| purpose | TEXT NOT NULL DEFAULT 'admin', `admin` or `invite` |
| state | `live`, `redeemed`, `revoked`, `awaiting_confirm` or `declined` |
| inviter_device_id | INTEGER NULL REFERENCES devices(id); set exactly when purpose is `invite` |
| pair_binding | BLOB NULL, 32 bytes; the redeeming channel's binding, set on redemption of an invite |
| confirm_by | INTEGER NULL, ms; redemption time plus 10 minutes, set on redemption of an invite |

Invite rows: `created_by = 'device:<id>'`, `user_id` = the inviting device's user, `expires_at = created_at + 10 min`.

Transitions for an invite:

```
live ──redeem──▶ awaiting_confirm ──confirm──▶ redeemed
  │                     │
  │                     ├──decline / confirm_by passes / inviter revoked──▶ declined
  │
  └──newer invite from same device / inviter revoked / admin revoke──▶ revoked
```

Expired is still derived from `expires_at` for `live` rows. On `declined` the pending device row is deleted and `device_id` is cleared; `device_key` stays so a retry by the same key is answered `pairing_token_invalid`. Admin tokens keep the version 3 transitions.

Limits checked in the creating transaction:

- the inviting device and its user are `approved`
- at most 3 unexpired `live` or `awaiting_confirm` invites per user; past that, `busy`
- at most 10 invites created by one device in the last hour (counted from rows, which are kept 90 days); past that, `busy`
- creating an invite revokes the same device's earlier `live` invite in the same transaction
- the 100 live token cap of version 3 counts invites too

An administrator approving a pending invited device with `flowd admin approve device <id>` also confirms it: the token moves to `redeemed`.

### audit (rebuilt)

`action` gains `invite_create`, `invite_confirm`, `invite_decline` and `invite_expire`. Invite rows use actor `device:<id>` (create, confirm, decline) or `system` (expire) and target `token:<id>`. A device revoking one of its own user's devices writes `revoke` with actor `device:<id>`.

### Expiry sweep

`Store.ExpireInvites(now)` moves `awaiting_confirm` rows past `confirm_by` to `declined` and deletes their pending devices. flowd calls it from the accounts watcher at most once a minute, and the invite, confirm and list operations call it first for the rows they touch.

## Read models (no tables)

| Name | Source | Bound |
|---|---|---|
| Admin list | `flowd admin list --json` | 500 devices, 500 users, `truncated` flag |
| Live channels | `GET /v1/admin/status` → `channels` | 500 device entries; at most 4 channels each (`MaxChannelsPerDevice`) |
| Account devices | `account_devices` list reply | the caller's user only; 100 devices |

## Rust client

### Preferences

| Key | Values |
|---|---|
| `setup.role` | `client` or `server`; absent means `client` |
| `serverMode.enabled` | bool |
| `serverMode.customAddress` | origin text, FR-012a rules |
| `serverMode.plistSHA256` | hex SHA-256 of the plist this app wrote |
| `serverMode.openPending` | bool, set while an open-to-network change awaits its 60 s check |
| `serverMode.helpersStamp` | bundle version whose helpers were copied |

Same key names as the Swift app's `ServerModeController`, kept in the Rust app's own preferences. Rust reads none of Swift's server-mode values; an existing Swift server is recognised by its agent and plist and treated as adopted (research R6).

### Session state

`State::StartingModel`, between `Persisting` and `Rewriting`, entered only when the first readiness check fails. Leaves to `Rewriting` when the request starts, or to `Inserting` with the original text on timeout or cancel.

### ColdStart record (log only)

| Field | Meaning |
|---|---|
| ready_ms, sent_ms, finished_ms, inserted_ms | ms after key release; absent when not reached |
| cold | the first readiness check failed |
| outcome | `ok`, `timeout`, `cancelled`, `unavailable` or `failed` |
| model | flowd's reported model identity |
| build | app version and commit |

Never holds dictated or rewritten text, app names or field contents. Written to `~/Library/Logs/LocalFlow/rewrite-timing.log`, 256 KB cap with one rollover file.

### Pairing state after an invite

A device that redeems an invite stores credentials as today with `remote.state = pending`, plus, in memory only, the inviting device's key and the pair binding needed to show the code. Once it sees `approved` on refresh it clears them.
