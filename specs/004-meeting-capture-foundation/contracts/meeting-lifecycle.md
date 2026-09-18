# Contract: meeting lifecycle and coordinator

Normative for `MeetingLifecycle` (pure state machine), `MeetingCoordinator` (main-actor owner of the active meeting) and the UI that observes it. The transition table itself is in [data-model.md](../data-model.md), "State transitions"; this file fixes the observable behaviour around it.

## Single active meeting (FR-002)

- `MeetingCoordinator.start()` first runs `MeetingStore.activeMeeting()`; when a row is in `created`, `preparing`, `recording`, `paused` or `finalizing`, it returns `.alreadyActive(id)` and shows the active meeting. No row is inserted.
- The check and the `created` insert happen in one write transaction, so two concurrent Start requests cannot both insert.
- A meeting that is `created` but never reached `preparing` (the app died between the two) is reconciled to `failed` with reason `not_running_at_last_state`, and it never blocks a new start after reconciliation.

## Start sequence (FR-001, FR-019, FR-021)

Order is fixed; a failure at any step before the row insert refuses the start with the named reason and persists nothing; after the insert the row moves to `failed` with the reason.

1. Refuse if dictation is busy ("Dictation in progress").
2. Reconciliation finished (the coordinator waits for the reconciler's completion; Start is disabled until then).
3. Microphone permission: `authorized` continues; `notDetermined` requests and waits; `denied`/`restricted` refuses with the microphone guidance.
4. Screen recording permission: `CGPreflightScreenCaptureAccess()`; when false, `CGRequestScreenCaptureAccess()` once, then re-check; still false refuses with the screen-recording guidance. The prompt is made only from this explicit action.
5. Storage preflight: `Meetings/` directory exists or is created with mode 0700; free space read; `< 500,000,000` bytes refuses ("Not enough free space"); `< 2,000,000,000` warns but continues.
6. Insert `meetings` row in `created` (with empty notes row), then `preparing` with two `healthy` track rows in the same transaction.
7. Open one `.part` segment file per track (sequence 1). A file open failure moves the row to `failed` with `segment_open_failed`, removes any file it did create, and reports.
8. Start both sources. Outcomes: both started → `recording`; one failed → `recording` with that track `failed` and a prominent warning; both failed → `failed` with `both_sources_failed`, files removed only if empty.
9. Publish `recording` after the write returns. SC-001: steps 3–9 complete within 3 s with permissions already granted; `meetingStartDuration` and `meetingCaptureInitDuration` are recorded.

## Published state (FR-006)

`MeetingCoordinator` exposes one observable `MeetingStatus` value:

| Field | Meaning |
| --- | --- |
| id, title | Current meeting |
| state | Lifecycle state as persisted |
| recordedElapsed | Recorded time, advances only in `recording`, at 1 Hz for display |
| microphone, system | Per-track `TrackStatus`: `capturing`, `failed(reason, at)`, `finalized`, `notStarted` |
| pauseReason | `user` or `systemSleep` while paused |
| storageWarning | Set from preflight when free space was between the thresholds |
| droppedFrames | Sum for both tracks, for the detail sheet |
| notice | Last user-facing message (permission, failure, recovery) |

A track whose storage or capture failed is never `capturing`. The menu bar item shows a recording glyph while `recording`, a pause glyph while `paused`, and nothing meeting-related otherwise. Closing the main window changes nothing.

## Pause and resume (FR-007)

- `pause(reason: .user)` is accepted only in `recording`. The coordinator stops both sources, finalizes both open segments (flush, fsync, rename), inserts the open pause row and the state change in one transaction, then publishes `paused`.
- System sleep calls the same path with `reason: .systemSleep`; it is idempotent when the meeting is already paused. On wake nothing happens; the notice says "Paused because the Mac went to sleep".
- `resume()` is accepted only in `paused`. The coordinator opens sequence n+1 files per healthy track, starts the sources, closes the pause row and persists `recording`, then publishes. A source that fails to restart follows the source-failure rule; if none restarts the meeting stops as `interrupted`.
- Elapsed recorded time does not advance while paused; nothing is written to any track.

## Stop and finalize (FR-008)

- `stop()` is accepted in `recording` and `paused`. The state becomes `finalizing` (persisted with `stopped_at`, and the open pause closed with `closed_by = 'stop'`), sources stop, each open segment is finalized in the order microphone then system, and `finalization_stage` is persisted after each ('mic', then 'both'). Then track totals, `recorded_ms`, `wall_clock_ms`, `duration_warning` and `completed` are written in one transaction, and `meetingFinalizationDuration` is recorded.
- A failure during finalization persists the stage reached, marks the failing track and moves the meeting to `interrupted` with the reason; the other track's finalized file is kept.
- A zero-length meeting completes normally with near-empty finalized files.

## Source failure (FR-020)

- A source reports failure through `MeetingAudioSourcing` events. The coordinator marks the track `failed(reason, now)`, finalizes its open segment with `close_reason = 'source_failed'`, persists, publishes the warning and continues.
- When the second track also fails, `stop()` runs with `failure_reason = both_sources_failed` and the result is `interrupted`.
- Permission revocation is detected by polling `AVCaptureDevice.authorizationStatus` every 250 ms for the microphone and by the `SCStream` error for system audio; the reason is `permission_revoked`.

## Storage failure (FR-018)

- Each track worker latches `storageFailure` on the first failed `write`, `fsync`, rename or encoder error. The coordinator polls both latches every 250 ms.
- On a latch: stop both sources, finalize what can be finalized (a track whose write failed is finalized by rename only when the file passes ADTS validation; otherwise it is `unrecoverable` with `storage_write_failed`), persist `interrupted` with `storage_write_failed` or `storage_unavailable`, publish the notice, and stop the elapsed timer. Bound: 5 s from the failed call to the published state; the poll makes the expected value under 1 s.
- Audio arriving while writes fail is dropped at the ring and counted; no buffer grows.
- There is no resume after a storage failure; a new meeting is required.

## Reconciliation (FR-012, FR-013)

`MeetingReconciler.run()` executes before any Start is enabled and never blocks launch. Its per-meeting behaviour is in [research.md](../research.md), "Reconciliation at launch". It publishes `ReconciliationSummary(meetingsFound, recovered, unrecoverable, orphansReconstructed, deferred)` which `AppServices` turns into one notice; each meeting's outcome row is visible in its detail view. When nothing was found the summary is silent and dictation starts as before.

## Notes (FR-009)

`MeetingNotesEditor` accepts edits for the active meeting and for any meeting opened from the library; it saves 2 s after the last edit, at most 10 s after the first unsaved edit, on window close, on stop and on quit. Saves are content-free in logs. A failed save shows "Notes not saved" and keeps retrying on the next edit or on the 10 s timer; the editor never claims a save that did not return.

## Deletion (FR-022)

Delete is offered for terminal meetings only. The confirmation names the meeting's title or fallback title and says audio and notes are removed. The order and partial-failure behaviour are in [data-model.md](../data-model.md), "Deletion".

## Exclusivity with dictation (FR-027)

`AppServices` refuses `DictationCoordinator.begin()` while `MeetingCoordinator.isActive` and shows "Meeting in progress" through the existing action notice; `MeetingCoordinator.start()` refuses while `DictationCoordinator.busy`. With no meeting active the dictation path has no meeting code in it.
