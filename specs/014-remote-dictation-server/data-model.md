# Data model: Remote dictation on a self-hosted LocalFlow server

The server persists accounts, devices, token state and audit metadata only (FR-026). The client adds one column to history, one table for pending retries, and Keychain items. Everything else is in memory for one channel.

## Server: `<data-dir>/flowd-remote.sqlite`

SQLite, WAL mode, `PRAGMA user_version = 2` (version 1 files are migrated in place), file mode 0600 in a 0700 directory. Written by `flowd serve` (sign-in, refresh, last-seen) and `flowd admin` (state changes). All timestamps are Unix milliseconds from the server clock.

### `users`

| Column | Type | Rules |
| --- | --- | --- |
| `id` | INTEGER PRIMARY KEY | server-assigned; never accepted from a client |
| `provider` | TEXT NOT NULL | `apple` or `google` |
| `subject` | TEXT NOT NULL | provider `sub`, ≤ 255 bytes |
| `display` | TEXT | email or name the provider returned, ≤ 320 bytes; shown only by `flowd admin` |
| `state` | TEXT NOT NULL | `pending`, `approved`, `rejected`, `revoked` |
| `created_at`, `changed_at` | INTEGER NOT NULL | |

`UNIQUE(provider, subject)`. At most 100 rows in `pending`.

State transitions (only `flowd admin` changes state, except creation):

```text
(new identity) → pending
pending  → approved | rejected
approved → revoked
rejected → approved            (explicit admin approval only; sign-in never changes it)
revoked  → approved            (explicit admin approval only)
```

### `devices`

| Column | Type | Rules |
| --- | --- | --- |
| `id` | INTEGER PRIMARY KEY | |
| `user_id` | INTEGER NOT NULL REFERENCES users(id) | |
| `name` | TEXT NOT NULL | client-supplied, ≤ 64 bytes, control characters removed |
| `public_key` | BLOB NOT NULL UNIQUE | Secure Enclave P-256 public key, X9.63 uncompressed, 65 bytes |
| `state` | TEXT NOT NULL | `pending`, `approved`, `revoked` |
| `refresh_hash` | BLOB | SHA-256 of the current refresh token |
| `previous_refresh_hash` | BLOB | SHA-256 of the token it replaced; presenting it revokes the device |
| `refresh_expires_at` | INTEGER | 30 days after issuance |
| `access_hash` | BLOB | SHA-256 of the current access token; one live access token per device |
| `access_expires_at` | INTEGER | 15 minutes after issuance |
| `revoked_access_hash` | BLOB | SHA-256 of the access token that was live when the device was revoked; lets a session hello with that token get `revoked` instead of `unauthorized`. Added in version 2 |
| `revoked_refresh_hash`, `revoked_previous_refresh_hash` | BLOB | SHA-256 of the current and previous refresh tokens when the device was revoked; lets `refresh` with either token get `revoked` instead of `unauthorized`. Added in version 2 |
| `enrolled_at`, `last_seen_at`, `changed_at` | INTEGER NOT NULL | `last_seen_at` updated at most once a minute |

Token columns hold 32-byte SHA-256 hashes, never tokens. The *Refresh token record* entity of the spec is the refresh and access columns; one device has one lineage, so it needs no separate table.

Device transitions: `pending → approved | revoked`, `approved → revoked`, `revoked → approved` (admin only). Revoking a user leaves device rows as they are but every device of a non-approved user is refused. Revocation or refresh reuse clears `refresh_hash`, `previous_refresh_hash` and `access_hash`, and moves the cleared hashes to `revoked_refresh_hash`, `revoked_previous_refresh_hash` and `revoked_access_hash` (a hash already cleared keeps its earlier tombstone). The tombstones authenticate and redeem nothing, and apply only while the device is revoked: they turn the answer for those tokens, at a session hello or a refresh, from `unauthorized` into `revoked`; after refresh reuse, later presentations of either token answer `revoked` without further reuse handling (contract: "`revoked`: user or device revoked"), so the client deletes its tokens and shows "Removed from the server" instead of "Sign in again". A device approved again after revocation gets no new token from them; its old tokens are then simply unknown (`unauthorized`) and it must enroll again. A revoked user's devices keep their token hashes, so their access and refresh tokens are answered `revoked` without the tombstones (and presenting a previous refresh token is still refresh reuse, which revokes that device).

A request is served only when `users.state = 'approved'` and `devices.state = 'approved'`, checked from the in-memory snapshot reloaded on every `data_version` change ([research.md](research.md) R9).

### `audit`

| Column | Type | Rules |
| --- | --- | --- |
| `id` | INTEGER PRIMARY KEY | |
| `at` | INTEGER NOT NULL | |
| `actor` | TEXT NOT NULL | `admin:<unix user>`, `user:<id>`, `device:<id>` or `system` |
| `action` | TEXT NOT NULL | `sign_in`, `enroll`, `approve`, `reject`, `revoke`, `refresh`, `refresh_reuse`, `cross_user_attempt`, `rate_limited`, `pin_rejected` |
| `target` | TEXT | `user:<id>` or `device:<id>` |
| `outcome` | TEXT NOT NULL | `ok` or an error code from the channel contract |

No content, tokens, claims or keys (FR-012). At most 10,000 rows; the oldest are deleted in the same transaction as an insert that exceeds the cap.

### Server identity key

X25519 private key, 32 bytes, stored in the login Keychain of the account that runs flowd: generic password, service `org.localflow.LocalFlow.remote.identity` (development: `org.localflow.LocalFlow.dev.remote.identity`), account = absolute data directory path. Created by `flowd admin init` through `/usr/bin/security`; flowd reads it at start and refuses to serve remote clients without it. The public key and fingerprint are printed by `flowd admin identity`.

### In memory only

| Entity | Contents | Lifetime | Bound |
| --- | --- | --- | --- |
| Channel | WebSocket, HPKE contexts, send and receive counters, user and device IDs after authentication, current operation | until closed | 16 total, 2 per device |
| Remote dictation session | boost terms, samples received, the current partial window buffer, window jobs issued, results sent | one dictation | 1 per user, 8 total; buffer ≤ one window plus one frame |
| Window job | user ID, channel ID, window index, sample start and count, samples, terms | until the worker answers or the job deadline | 2 waiting per user |
| JWKS cache | provider keys | per `Cache-Control`, 5 min–24 h | 64 KiB per provider |
| Account snapshot | user and device states, public keys, token hashes | reloaded on `data_version` change | row count |

Session identifiers are channel-scoped: operations carry a client-chosen `op` number that is echoed back and has no meaning outside its channel. There is no global table of sessions or requests a client could name. Server temporary files are not used in this slice; audio lives only in the session buffer and window jobs, freed when the job or channel ends.

## Client

### History: migration `remote-dictation-v15`

```sql
ALTER TABLE transcriptions ADD COLUMN recognition_path TEXT NOT NULL DEFAULT 'local'
  CHECK (recognition_path IN ('local', 'server', 'local_after_server_failure'));
ALTER TABLE transcriptions ADD COLUMN server_failure TEXT
  CHECK (server_failure IS NULL OR length(server_failure) <= 32);
CREATE TABLE pending_remote_dictations (
  id TEXT PRIMARY KEY,                 -- the dictation's session UUID
  audio_file TEXT NOT NULL,            -- file name inside PendingAudio/, never a path
  sample_count INTEGER NOT NULL CHECK (sample_count BETWEEN 1 AND 2880000),
  created_at INTEGER NOT NULL,
  attempts INTEGER NOT NULL DEFAULT 0,
  next_attempt_at INTEGER NOT NULL,
  last_failure TEXT,                   -- failure reason code
  target_bundle_id TEXT
);
```

`server_failure` is set only with `local_after_server_failure`, and later for `server` entries produced by a retry (`pending_retry`). Codes: `unreachable`, `timeout`, `busy`, `unauthorized`, `not_approved`, `revoked`, `pin_mismatch`, `worker_unavailable`, `protocol_error`, `limit_exceeded`. `TranscriptionEntry` gains `recognitionPath` and `serverFailure`; History shows a small path label.

`pending_remote_dictations` holds at most 20 rows. A row older than 24 hours, or a new failure when 20 rows exist, is not deleted: the app asks the user to recognize it locally (if a model is now provisioned), copy what exists, or discard it. Audio files live in `<Application Support>/PendingAudio/`, 0700, removed with their row; at startup, files without rows are deleted and rows without files are dropped with a content-free log line. The Dictionary snapshot is taken again at retry time.

### Remote dictation settings (`UserDefaults`, not secret)

| Key | Type | Meaning |
| --- | --- | --- |
| `remote.enabled` | Bool | set only after the consent step |
| `remote.serverURL` | String | `https://` origin, no path, no credentials |
| `remote.state` | String | `off`, `pinned`, `pending`, `approved`, `rejected`, `revoked`, `pin_mismatch` (display cache; the server decides) |
| `remote.consentVersion` | Int | consent text version the user confirmed |
| `remote.fallbackThresholdMs` | Int | development builds only; default 1,500 |

### Keychain (service `<bundle id>.remote`)

| Account | Value |
| --- | --- |
| `device-key` | Secure Enclave key `dataRepresentation` |
| `server-key` | pinned X25519 public key, 32 bytes |
| `refresh-token` | `lfr_…` |
| `access-token` | `lfa_…`, with its monotonic issue time held in memory only |

Turning remote dictation off deletes all four items and the `remote.*` defaults except `remote.enabled = false`. History is kept (FR-003).

### `RemoteDictationSession` (in memory, one dictation)

| Field | Meaning |
| --- | --- |
| `channel` | the open channel, or nil after failure |
| `sentSamples` | samples streamed so far |
| `windows` | `[sampleStart: TranscriptionWindow]` received |
| `identity` | server model identity from `dictation_accepted` |
| `state` | see below |
| `failure` | first failure reason code |

```text
connecting → streaming → ending → complete
     │           │          │
     └───────────┴──────────┴──→ failed(reason) → local fallback | pending retry
streaming → restarting → streaming       (at most once, only before key release)
```

## Relationships

```text
users 1 ── * devices
users, devices ── * audit (by target text, no foreign key so pruning never blocks)
channel ── 0..1 remote dictation session ── * window jobs
client dictation ── 0..1 pending_remote_dictations ── 1 PendingAudio file
```
