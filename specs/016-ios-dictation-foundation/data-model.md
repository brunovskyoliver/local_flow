# Data model: iOS dictation foundation

Three places hold state on the phone:

1. **History database**: `history.sqlite` in the app container. It uses the shared schema plus one phone-only table.
2. **Handoff files**: small JSON files in the App Group container, the only state the keyboard and the app share ([contract](contracts/keyboard-handoff.md)).
3. **In-memory state**: the listening session and the model keep-ready holds, owned by the app process.

The Mac database is not changed.

## 1. History database (app container, app-only)

Path: `Application Support/LocalFlow/history.sqlite`. File protection `completeUntilFirstUserAuthentication`. Opened by `TranscriptionStore` with the same settings as the Mac: WAL, `synchronous=FULL`, 0600 permissions, 128 MB page cap.

Migrations: `HistoryMigrations.migrator()` (the 16 shared migrations, unchanged), then `phone-dictations-v1`. Only the iOS app registers `phone-dictations-v1`.

### Dictation → existing `transcriptions` row

| Spec field | Column | Phone values |
| --- | --- | --- |
| id | `id` | UUID string, the same as `dictation_id` in the handoff |
| text | `text` | Normalized transcript after Dictionary rules. Empty results are not saved (edge case "didn't catch that") |
| time | `created_at` | Milliseconds since the epoch at stop |
| delivery result | `delivery_state` | `confirmed` = inserted; `not_inserted` = offered or saved only, including before the keyboard acknowledges (the phone table says which). The phone never writes `attempting`: the shared store's launch repair turns every `attempting` row into `uncertain` + `needs_review`, which would mark ordinary unacknowledged dictations as recovered |
| — | `quality`, `stop_reason` | `complete`, or `duration_limited` with `duration_limit`; `incomplete` with `failure`, `overflow` or `permission_revoked`. An interruption uses `stop_reason = failure` and `phone_dictations.end_detail = interrupted` |
| target app | `target_bundle_id` | Usually NULL, because iOS 26.4+ does not report the host app |
| — | `recovery_state` | `resolved`. Orphaned-spool recoveries (below) use `needs_review` so History can mark them |
| — | rewrite columns | Defaults (`not_requested`). Rewriting is Feature 018 |

### New table `phone_dictations` (migration `phone-dictations-v1`, iOS only)

| Column | Type | Rule |
| --- | --- | --- |
| `transcription_id` | TEXT PK | FK → `transcriptions(id)` ON DELETE CASCADE |
| `source` | TEXT NOT NULL | `keyboard` or `app` |
| `duration_ms` | INTEGER NOT NULL | 0 ≤ value ≤ 300,000 |
| `delivery` | TEXT NOT NULL | `inserted`, `offered`, `saved_only` |
| `end_detail` | TEXT | NULL, `limit_reached`, `interrupted`, `recovered_after_termination` |
| `session_id` | TEXT | Session UUID. NULL only for recovered orphans whose session is unknown |

Rules:

- `delivery` and `transcriptions.delivery_state` are written in the same transaction. `inserted` ↔ `confirmed`; `offered` and `saved_only` ↔ `not_inserted`.
- The phone writes only `confirmed` and `not_inserted`, never `attempting` or `uncertain`, so the launch repair in `TranscriptionStore` never touches phone rows.
- `source = app` rows always have `delivery = saved_only`. These are the in-app notes (FR-019).
- Deleting an entry (US3 AS3) deletes the `transcriptions` row. The cascade removes the phone row, and the existing quality and usage rows are removed as they are on the Mac.
- A History write failure never blocks delivery (FR-023). The result is still published to the keyboard, and the failure is logged as `history_write_failed` with no text.

### Dictionary

These are the existing `vocabulary_entries`, `vocabulary_state`, `dictionary_usage_*` and `term_suggestions` tables, used through `VocabularyStore` with the same validation as the Mac: canonical text, aliases, enabled flag, and the same size limits of ≤ 512 entries and ≤ 4,608 keys. The phone does not record usage or retire terms (adaptive learning is out of scope), so the usage tables stay empty and every enabled entry counts as active. `VocabularySnapshot` is rebuilt when `vocabulary_state.revision` changes, so an edit applies to the next dictation (US4 AS3).

### Settings

Settings live in `UserDefaults.standard` in the app, which survives a reinstall:

| Key | Values | Default |
| --- | --- | --- |
| `session.idleTimeout` | `afterOne`, `5m`, `15m`, `1h` | `5m` |
| `setup.completedSteps` | set of `keyboard`, `fullAccess`, `microphone`, `model`, `firstDictation` | empty |
| `diagnostics.enabled` | Bool | false |

`fullAccess` and `keyboard` are re-checked when the app launches. They are read from the keyboard's `keyboard-status.json` (contract) because the app cannot query them directly.

## 2. Speech model (files, app container)

`Application Support/LocalFlow/Models/<descriptor name>/` holds the files, `manifest.json` and fingerprints, and is excluded from backup. The descriptors are the shared `parakeet-v3` and `parakeet-ctc-110m` JSON files.

| State | Meaning | Next |
| --- | --- | --- |
| `absent` | No promoted directory | `downloading` when the user taps Download (after the space check) |
| `downloading(progress)` | Staging under `Models/.staging/<name>`, resume data kept | `verifying`, or `paused` on error or network loss |
| `paused` | Staging and resume data kept | `downloading` |
| `verifying` | SHA-256 and sizes checked | `ready`, or `damaged` (staging deleted) |
| `ready` | Manifest and fingerprints match | `damaged` when the launch check fails; `absent` after Delete in Settings |
| `damaged` | Promoted files are missing or wrong | The user is offered a new download. History and the Dictionary are not touched |

The boost model is optional in the same way it is on the Mac. Without it, dictation runs and V002 is skipped.

## 3. Listening session (app memory)

The `PhoneSession` is owned by the app's `SessionController`. At most one exists at a time.

| Field | Type |
| --- | --- |
| `id` | UUID |
| `origin` | `keyboard` (opened by URL, follows the idle timeout) or `app` (one-shot from the Dictate button, always ends after its dictation) |
| `startedAt` | Date |
| `idleDeadline` | Date, or nil while recording/finishing |
| `state` | `starting`, `ready`, `recording`, `finishing`, `ended` |
| `endReason` | `idleTimeout`, `afterOneDictation` (also used when an `origin = app` session ends after its dictation), `userEnded`, `interrupted`, `audioFailure`, `modelUnavailable`, `permissionDenied`, `appTerminated` (seen only by the keyboard, inferred when the app does not answer a ping) |
| `currentDictation` | `ActiveDictation`, or nil |

```text
          open app (URL or in-app)
                 │
             starting ──(mic denied / engine fails / model missing)──► ended
                 │ engine running, model kept ready
                 ▼
   ┌──────────► ready ──(idle deadline / user ends)──────────────────► ended
   │             │ start request
   │             ▼
   │         recording ──(stop request / 5 min limit / interruption)─┐
   │                                                                 ▼
   └──(result published; deadline = now + idle timeout)──────── finishing
         (with afterOne: ended instead of ready)             (interruption → ended after finishing)
```

Invariants:

- The engine is running and the microphone indicator is on only in `starting`, `ready`, `recording` and `finishing`. `ended` releases the engine, the audio session and the session's keep-ready hold (SC-009).
- A start request in any state other than `ready` is rejected with `busy` or `noSession`. A stop request that doesn't match the current dictation's request ID is ignored.
- The idle deadline is checked by a 1 s timer, so the session ends at most 1 s after the deadline (under SC-009's 10 s).
- Opening the URL while a session exists in any state other than `ended` keeps that session. If its `origin` is `app`, it becomes `keyboard` and follows the idle timeout from then on.
- The Dictate button uses a running session when one is `ready`. Otherwise it starts a session with `origin = app`, which goes `starting → ready → recording → finishing → ended` regardless of the idle timeout setting. The microphone indicator is therefore on only while some session exists (FR-011).
- A session keeps the model ready through `PhoneServices.keepReady`; each dictation acquires and finishes its own lease.

### ActiveDictation

| Field | Type |
| --- | --- |
| `id` | UUID (becomes `transcriptions.id`) |
| `requestID` | UUID from the keyboard, or a fresh one for in-app dictation |
| `source` | `keyboard` or `app` |
| `startedAt` | Date |
| `spool` | `AudioSpool` in `Application Support/LocalFlow/TemporaryAudio/`, 19.2 MB cap (5 min at 16 kHz Float32) |

The spool is deleted after the transcript is saved, after cancellation, and after failure. A spool found at launch is an **orphan**: the app was killed while recording or finishing. If the model is `ready`, it is transcribed and saved with `recovery_state = needs_review` and `end_detail = recovered_after_termination`, then deleted. If the model is not `ready` (absent, downloading, paused or damaged), the orphan is kept and recovered the moment the model state becomes `ready`; no new dictation can start before then, so the one-orphan bound holds. If transcription fails, the orphan is deleted and one content-free log line is written. Settings > Speech model shows "1 unrecovered recording" while an orphan waits and offers Delete. At most one orphan exists, because there is one dictation at a time.

## 4. Keyboard state (extension memory)

This state is not persisted, except for `Pending insert`, which lives in the handoff `result.json`.

| Field | Meaning |
| --- | --- |
| `hasFullAccess` | `UIInputViewController.hasFullAccess` |
| `sessionView` | `unknown`, `none`, `ready`, `recording`, `working`, `ended(reason)`. Derived from `session.json` and a ping to the app |
| `pendingRequest` | request ID, `documentIdentifier` at start, start time |
| `lastInsertion` | text and time; used by Undo for up to 10 s or until the next text change |
| `offered` | `dictation_id` and text shown as "Insert last dictation" |

## Bounds summary

| Item | Bound | When exceeded |
| --- | --- | --- |
| Dictation length | 5 min (spool 19.2 MB) | Stop, transcribe, `limit_reached` |
| Capture ring (audio thread → spool) | 1 s of audio | End the dictation with `overflow`; the text captured so far is transcribed |
| Handoff request | 1 file, newest wins | Older request overwritten; app answers only the newest ID |
| Handoff result | 1 file | Replaced by the next result; the previous one is already in History |
| Level file | 31 levels plus a write index, fixed 128 bytes | Circular overwrite |
| Orphan spools | 1 | — |
| History and Dictionary | Mac store limits (admission reserves capacity, never evicts) | The same errors as on the Mac. Text is still delivered |
