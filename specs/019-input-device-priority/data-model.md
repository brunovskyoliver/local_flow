# Data model: input device priority

Entities from the [spec](spec.md#key-entities), with storage decisions from [research R10](research.md#r10-where-the-data-lives).

## InputDeviceKind

`builtIn`, `usb`, `bluetooth`, `iPhone`, `virtual`, `other`, `systemDefault`.

Derived from the Core Audio transport type (research R1). `systemDefault` is used only by the "System default" entry. Raw values are the strings above; they are stored in `UserDefaults` and in `transcriptions.input_device_kind`.

## RankedInputEntry

One position in the list. Stored in order; the array index is the rank.

| Field | Type | Rules |
| --- | --- | --- |
| `id` | UUID | Stable row identity for SwiftUI and moves. Never shown |
| `kind` | InputDeviceKind | Required |
| `uid` | String? | Core Audio device UID. Nil only for `systemDefault`. 1–256 bytes |
| `modelUID` | String? | Core Audio model UID when the device reported one. ≤ 256 bytes |
| `name` | String | Last name macOS reported. 1–128 characters. "System default" for that entry |
| `lastSeenAt` | Date? | Last time the device was in a snapshot. Nil for `systemDefault` |

### Stored form

`UserDefaults` key `inputDevices.priority.v1`: JSON `{ "version": 1, "entries": [RankedInputEntry] }`.

### Validation

- V1: exactly one `systemDefault` entry. A decoded list without one gets it appended at the end.
- V2: no two entries share a `uid`. On decode, the later duplicate is dropped.
- V3: at most 32 entries. "Add microphone" is disabled at 32.
- V4: a missing key, unreadable JSON or an unknown version reads as `[systemDefault]` (FR-016). Unreadable data is logged once and then overwritten on the next edit, not on read.
- V5: the `systemDefault` entry can move but not be removed (FR-002).

## ConnectedInput (not stored)

What the catalog reports for one device right now.

| Field | Type |
| --- | --- |
| `deviceID` | `AudioDeviceID` (valid only for this boot) |
| `uid` | String |
| `modelUID` | String? |
| `name` | String |
| `kind` | InputDeviceKind |
| `isAlive` | Bool |

`InputDeviceSnapshot` holds up to 64 `ConnectedInput` values plus the default input's `AudioDeviceID` (or none), the clamshell flag (research R3) and a `generation` counter that increases on every rebuild.

## Matching saved entries to connected devices

Run on every snapshot, in this order:

- **M1**: same `uid` → match.
- **M2**: no UID match, and the entry and the device have the same `kind` and `name` and the same `modelUID` (both nil counts as the same) → candidate.
- **M3**: a candidate from M2 is accepted only when exactly one unmatched entry and exactly one unmatched device share that key. The entry's `uid` is then updated to the new one and saved (FR-007). Any ambiguity leaves both unmatched: the entry shows "Not connected" and the device appears under "Add microphone".

Matching updates `name` and `lastSeenAt` for matched entries. A rename on the device side changes the stored name; it does not create a new entry.

## Availability (not stored)

An entry is **available** when:

- `systemDefault`: the snapshot has a default input.
- otherwise: it matched a `ConnectedInput` that is alive, and it is not the built-in input while the clamshell flag is set.

## InputCandidate (not stored)

The resolver's output for one key-down: available entries in rank order, each with the `AudioDeviceID` to bind (nil for `systemDefault`). The coordinator marks the device it ends up using as a fallback when at least one entry ranked above it was unavailable or was tried and failed in this key-hold.

## DeviceTimingProfile

Per device, kept for measurement and logs (FR-018, SC-005). The tail does not read it (research R6).

| Field | Type | Rules |
| --- | --- | --- |
| `uid` | String | Key |
| `kind` | InputDeviceKind | |
| `uses` | Int | ≥ 0 |
| `connectTimeouts` | Int | ≥ 0 |
| `recentConnectMs` | [Int] | Last 16 values, oldest dropped, each 0–3000 |
| `recentDelayMs` | [Int] | Last 16 session-maximum delivery delays, each 0–2000 |
| `lastUsedAt` | Date | Drives least-recently-used eviction |

`UserDefaults` key `inputDevices.timings.v1`, JSON, at most 32 profiles.

## Dictation device record

Migration `input-device-v18` (appended to `HistoryMigrations`, frozen list updated):

```sql
ALTER TABLE transcriptions ADD COLUMN input_device_name TEXT
  CHECK (input_device_name IS NULL OR length(input_device_name) BETWEEN 1 AND 128);
ALTER TABLE transcriptions ADD COLUMN input_device_kind TEXT
  CHECK (input_device_kind IS NULL OR input_device_kind IN
    ('builtIn','usb','bluetooth','iPhone','virtual','other','systemDefault'));
ALTER TABLE meeting_segments ADD COLUMN input_device_name TEXT
  CHECK (input_device_name IS NULL OR length(input_device_name) BETWEEN 1 AND 128);
ALTER TABLE pending_remote_dictations ADD COLUMN input_device_name TEXT
  CHECK (input_device_name IS NULL OR length(input_device_name) BETWEEN 1 AND 128);
ALTER TABLE pending_remote_dictations ADD COLUMN input_device_kind TEXT
  CHECK (input_device_kind IS NULL OR input_device_kind IN
    ('builtIn','usb','bluetooth','iPhone','virtual','other','systemDefault'));
```

- `TranscriptionEntry` gains `inputDevice: (name: String, kind: InputDeviceKind)?`. Rows from before the migration read nil and History shows "Not recorded".
- For a `systemDefault` dictation, the stored name is the name of the device macOS used (read from the engine's bound device after start), and the kind is `systemDefault`.
- `meeting_segments.input_device_name` is set for microphone-track segments only; system-audio segments keep NULL.
- Pending remote dictations (Feature 014) store the device fields in `pending_remote_dictations` when queued (`PendingRemoteDictationStore`), and `PendingRemoteRetrier` copies them into the final `transcriptions` row, so the device survives a restart between queueing and retry. Rows queued before the migration read NULL and the final entry shows "Not recorded".

## DictationSession.State

Adds `connecting` between `preparing` and `recording`:

```text
preparing → connecting → recording → transcribing → …
             │   ▲
             │   └─ connect limit passed, next candidate starts (stays connecting)
             ├─ key released → cancelling → idle (nothing inserted)
             └─ no candidate left → failed ("<name> didn't respond")
preparing → failed ("No microphone available")   when no entry is available
```

A candidate that delivers non-zero audio in its first buffer passes through `connecting` within one poll, so built-in and wired devices show no visible connecting step.

## Fallback notice memory (not stored)

`lastAnnouncedAvailableSet: Int?`, a hash of the sorted UIDs of available entries at the time of the last "Using <name>" notice. A fallback shows the notice only when the current hash differs.
