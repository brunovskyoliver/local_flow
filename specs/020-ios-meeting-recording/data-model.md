# Data model: Feature 020

The phone uses the shared meeting schema from `HistoryMigrations` (already on the phone). New schema is only what this feature needs.

## Shared migration `phone-meetings-v19` (HistoryMigrations, both apps and flowd-meeting)

- `meeting_segments` rebuilt with:
  - `open_reason IN ('start','resume','device_changed','rotated')`
  - `close_reason IS NULL OR close_reason IN ('pause','system_sleep','stop','source_failed','storage_failed','device_changed','recovered','rotated')`
  - all other columns, indexes and foreign keys unchanged; rows copied as they are.
- `meetings.origin TEXT NOT NULL DEFAULT 'local' CHECK (origin IN ('local','iphone'))`. The phone writes `iphone`; the Mac's import keeps it.

## Phone migration `phone-meetings-v1` (PhoneMigrations, phone only)

`phone_meeting_uploads`, one row per meeting the phone handles with the server:

| Column | Type | Notes |
| --- | --- | --- |
| `meeting_id` | TEXT PK, FK `meetings(id)` ON DELETE CASCADE | |
| `stage` | TEXT NOT NULL | `waiting`, `uploading`, `processing`, `merging`, `summarizing`, `ready`, `failed` (CHECK) |
| `detail` | TEXT | reason code: `not_signed_in`, `pending`, `revoked`, `unreachable`, `server_limit`, `server_outdated`, `identity_changed`, or the server's failure detail |
| `bundle_uploaded` | INTEGER NOT NULL DEFAULT 0 | `bundle.sqlite` sent (it can be sent only once) |
| `confirmed_segments` | TEXT NOT NULL DEFAULT '' | comma-separated relative paths the server confirmed with a matching SHA-256 |
| `transcribed_ms` | INTEGER | last value from the server's list entry |
| `server_progress` | INTEGER | 0–100 while processing |
| `copy_to_mac` | INTEGER NOT NULL DEFAULT 1 | snapshot of the setting at first upload |
| `mac_copy` | TEXT NOT NULL DEFAULT 'none' | `none`, `waiting`, `delivered`, `expired` (CHECK) |
| `released_at` | INTEGER | ms since epoch, when `release` was sent |
| `attempts` | INTEGER NOT NULL DEFAULT 0 | for backoff `min(cap, 30 << min(attempts, 5))` seconds; `cap` is 120 after `unreachable` or `server_busy` (SC-004), 600 otherwise |
| `updated_at` | INTEGER NOT NULL | ms since epoch |

## Phone migration `phone-meetings-v2` (PhoneMigrations, phone only)

`phone_meeting_server_deletes(meeting_id TEXT PK, queued_at INTEGER NOT NULL)`: a meeting deleted on the phone whose server copy still exists (US5, FR-033). The uploader sends `delete` with the next connection and removes the row. No foreign key: the meeting row is already gone.

## State transitions

Meeting (shared `MeetingState`): `created → preparing → recording ⇄ paused → finalizing → completed`; a crash leads through the reconciler to `interrupted`. The phone also uses `paused` for interruptions (calls).

Upload stage (phone):

```
waiting ──(approved, switch on, reachable)──▶ uploading
uploading ──(final start accepted)──▶ processing
processing ──(server done)──▶ merging ──(merged)──▶ summarizing ──▶ ready
any ──(server failed / merge failed twice)──▶ failed ──(Retry)──▶ waiting
any ──(unreachable / not approved / limit)──▶ waiting (detail set)
```

During recording the meeting is in `uploading` with partial runs; `transcribed_ms` advances.

Mac copy (phone): `none → waiting` on `release` with copy; `waiting → delivered` when the entry is gone within 7 days of `released_at`; `waiting → expired` when gone later; `expired → waiting` on Send to Mac again (re-upload).

## Server files per meeting (`<data-dir>/handoff/<user>/<MEETING-UUID>/`)

Existing: `bundle.sqlite`, `<UUID>/mic-NNNN.aac`, `state`, `progress`. New: `rows.sqlite` (replaceable input rows, deleted by the processor after import), `transcribed_ms`, `device`, `copy`, `released`.

## Key validation rules

- A segment is uploaded only when its row is `finalized`; its SHA-256 goes with the last chunk.
- `rows.sqlite` is uploaded only after every segment it references is confirmed.
- The phone never sends anything unless enrollment state is approved and the switch is on (SC-008).
- Recording stops at 4 hours, at 200 MB free storage; warning at 1 GB free.
