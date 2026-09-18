# Data model

The production database remains the existing private GRDB/SQLite store (`history.sqlite`) shared by `TranscriptionStore` and `VocabularyStore`. A new `MeetingStore` actor uses the same `DatabaseQueue`. Migration `meetings-v5` adds the tables below; no Feature 001–003 table is altered. Timestamps are Unix milliseconds unless named `_ns`. Text is UTF-8 and byte limits are UTF-8 bytes. Audio bytes never enter SQLite; files live under the meeting storage root (`<Application Support>/LocalFlow/Meetings/`).

## Meeting

Table `meetings`. One row per recording session. Created in state `created` before any capture starts (FR-001).

| Column | Type and rule |
| --- | --- |
| id | TEXT primary key, UUID; also the media directory name |
| state | TEXT in `('created','preparing','recording','paused','finalizing','completed','interrupted','failed')` |
| title | TEXT nullable, ≤ 256 bytes; never used in file names |
| created_at | INTEGER not null; the Start action time |
| started_at | INTEGER nullable; first transition into `recording` |
| stopped_at | INTEGER nullable; transition into `finalizing` (user stop or failure) |
| completed_at | INTEGER nullable; transition into a terminal state |
| wall_clock_ms | INTEGER not null default 0, ≥ 0; `stopped_at − started_at` when both exist, else elapsed at last persist |
| recorded_ms | INTEGER not null default 0, ≥ 0; `wall_clock_ms − Σ closed pause_ms` at last persist |
| finalization_stage | TEXT nullable in `('none','mic','system','both')`; which tracks had finalized when the row was last persisted during finalizing |
| failure_reason | TEXT nullable in the reason set below; non-null only when state is `interrupted` or `failed` |
| failure_detail | TEXT nullable, ≤ 512 bytes, content-free (OS error codes, stage names) |
| updated_at | INTEGER not null; bumped on every persisted change; used to close open pauses at reconciliation |
| revision | INTEGER not null default 0, ≥ 0; optimistic concurrency for title, notes and deletion |

Indexes: `meetings_created_at_id ON meetings(created_at DESC, id DESC)` for the library; partial index `meetings_active ON meetings(state) WHERE state IN ('created','preparing','recording','paused','finalizing')` for the FR-002 guard and reconciliation.

Fallback title (derived, not stored): `"Meeting " + local short date and time of created_at`.

**Reason set** (`MeetingFailureReason`, shared by meetings and tracks): `not_running_at_last_state`, `storage_write_failed`, `storage_unavailable`, `encoder_failed`, `permission_revoked`, `device_lost`, `stream_stopped`, `both_sources_failed`, `record_missing`, `file_missing`, `segment_open_failed`, `unrecoverable_media`. User-facing text is mapped in `MeetingErrorMessage`.

## Audio track

Table `meeting_tracks`. Exactly two rows per meeting once preparing succeeds: one `microphone`, one `system`.

| Column | Type and rule |
| --- | --- |
| id | TEXT primary key, UUID |
| meeting_id | TEXT not null, references `meetings(id)` `ON DELETE CASCADE` |
| type | TEXT in `('microphone','system')`; unique `(meeting_id, type)` |
| codec | TEXT not null, `'aac_lc'` for this feature (check admits only that value; widen in a later migration) |
| container | TEXT not null, `'adts'` (same rule) |
| sample_rate | INTEGER not null, 48000 (check `> 0`) |
| channel_count | INTEGER not null, 1 or 2 |
| bitrate | INTEGER not null, > 0 |
| health | TEXT in `('healthy','failed','finalized','unrecoverable')` |
| failure_reason | TEXT nullable from the reason set; non-null iff health is `failed` or `unrecoverable` |
| failed_at | INTEGER nullable; set with `failure_reason` |
| total_duration_ms | INTEGER not null default 0, ≥ 0; Σ duration of finalized segments |
| total_bytes | INTEGER not null default 0, ≥ 0; Σ byte size of segments |
| duration_warning | INTEGER 0/1; 1 when total_duration_ms differs from the meeting's recorded_ms by more than max(1%, 2 s) at stop (SC-004 evidence) |
| dropped_frames | INTEGER not null default 0, ≥ 0; ring overflow count for the whole track |

`finalized` is a derived state: `health = 'finalized'` is set when the track's last segment is finalized at stop or by reconciliation; a failed track whose segments were finalized keeps `failed` (the reason must stay visible) with all segments individually finalized.

## Audio segment

Table `meeting_segments`. One row per file. At most one open (non-finalized) segment per track at any time, enforced in `MeetingStore.openSegment` inside the transaction that inserts it.

| Column | Type and rule |
| --- | --- |
| id | TEXT primary key, UUID |
| track_id | TEXT not null, references `meeting_tracks(id)` `ON DELETE CASCADE` |
| sequence | INTEGER not null, ≥ 1; unique `(track_id, sequence)` |
| relative_path | TEXT not null, ≤ 255 bytes; relative to the meeting storage root, e.g. `A1B2…/mic-0001.aac`; must not contain `..` or start with `/` |
| state | TEXT in `('open','finalized','unrecoverable')` |
| start_offset_ms | INTEGER not null, ≥ 0; position in the track's recorded timeline |
| duration_ms | INTEGER not null default 0, ≥ 0; from frames encoded; updated every 5 s while open and at finalization |
| byte_size | INTEGER not null default 0, ≥ 0; updated every 5 s while open and at finalization |
| started_at | INTEGER not null; wall clock of the first accepted frame |
| host_start_ns | INTEGER not null, ≥ 0; `CLOCK_MONOTONIC_RAW` of the first accepted frame, for later cross-track alignment |
| open_reason | TEXT in `('start','resume','device_changed')` |
| close_reason | TEXT nullable in `('pause','system_sleep','stop','source_failed','storage_failed','device_changed','recovered')` |
| dropped_frames | INTEGER not null default 0, ≥ 0 |
| recovery_note | TEXT nullable, ≤ 512 bytes, content-free (bytes truncated, parse position, reason) |
| failure_reason | TEXT nullable from the reason set; non-null iff state is `unrecoverable` |

A `relative_path` ends in `.part` while `state = 'open'` and in `.aac` otherwise; renaming and the state change happen in this order: rename on disk, fsync directory, update row. A row that says `finalized` while the file still ends in `.part` is a reconciliation case (`stale metadata`): the file is re-validated and the row corrected.

## Pause interval

Table `meeting_pauses`.

| Column | Type and rule |
| --- | --- |
| id | TEXT primary key, UUID |
| meeting_id | TEXT not null, references `meetings(id)` `ON DELETE CASCADE` |
| started_at | INTEGER not null |
| ended_at | INTEGER nullable; null while the meeting is paused; `ended_at ≥ started_at` |
| reason | TEXT in `('user','system_sleep')` |
| closed_by | TEXT nullable in `('resume','stop','reconciliation')` |

At most one open pause per meeting (partial unique index on `meeting_id WHERE ended_at IS NULL`). Reconciliation closes an open pause with `ended_at = meetings.updated_at` and `closed_by = 'reconciliation'` so recorded duration excludes the whole open pause (story 9, scenario 2).

## Meeting notes

Table `meeting_notes`, one row per meeting, created empty with the meeting.

| Column | Type and rule |
| --- | --- |
| meeting_id | TEXT primary key, references `meetings(id)` `ON DELETE CASCADE` |
| text | TEXT not null, ≤ 1,048,576 bytes |
| author | TEXT not null, `'user'` (check admits only that value; a future generated-content table is separate) |
| updated_at | INTEGER not null |
| revision | INTEGER not null default 0 |

Saves compare `revision`; two editors on one meeting resolve last-write-wins by re-reading and retrying once, never by cross-meeting effect.

## Recovery outcome

Table `meeting_recovery_outcomes`. One row per reconciliation of one meeting; kept for display in the detail view.

| Column | Type and rule |
| --- | --- |
| id | TEXT primary key, UUID |
| meeting_id | TEXT not null, references `meetings(id)` `ON DELETE CASCADE` |
| ran_at | INTEGER not null |
| found_state | TEXT; the state the row had before reconciliation |
| found_stage | TEXT nullable; `finalization_stage` found |
| segments_recovered | INTEGER ≥ 0 |
| segments_unrecoverable | INTEGER ≥ 0 |
| segments_missing | INTEGER ≥ 0 |
| pause_closed | INTEGER 0/1 |
| bytes_truncated | INTEGER ≥ 0 |
| summary | TEXT ≤ 512 bytes, content-free |

The application also keeps an in-memory launch summary (count of meetings reconciled, recovered, unrecoverable) for the notice shown after launch (FR-012).

## State transitions

Meeting states and the only allowed transitions (`MeetingLifecycle.transition`), with the persisted side effects:

| From | To | Trigger | Persisted in the same transaction |
| --- | --- | --- | --- |
| created | preparing | permissions and preflight passed, row inserted | two track rows, empty notes row |
| created | failed | preflight or permission failure after row creation | `failure_reason` |
| preparing | recording | both sources started, first segments open | `started_at`, two open segment rows |
| preparing | recording | one source failed to start, the other started | as above plus the failed track's reason (meeting continues, story 11) |
| preparing | failed | no source could start, or a segment file could not be opened | reason; no orphan file left |
| recording | paused | user pause or system sleep | pause row (open), open segments closed and finalized |
| recording | finalizing | user stop, storage failure, both sources failed | `stopped_at`, `failure_reason` when any |
| paused | recording | user resume | pause `ended_at`, new open segment rows |
| paused | finalizing | user stop, storage failure | pause `ended_at`, `stopped_at` |
| finalizing | completed | every track finalized, no failure reason | `completed_at`, durations, `finalization_stage = 'both'` |
| finalizing | interrupted | finalization ended with a storage or source failure, or reconciliation found the row here | `completed_at`, reason, stage found |
| preparing, recording, paused, finalizing | interrupted | reconciliation at launch | reason `not_running_at_last_state` (or the recorded reason), stage, recovery outcome |
| any active | failed | reconciliation finds a persisted fatal reason with no media written | reason |

Every other pair is rejected with `MeetingLifecycle.Error.invalidTransition(from:to:)` and mutates nothing (FR-010). `completed`, `interrupted` and `failed` are terminal; only title and notes edits and confirmed deletion touch a terminal meeting.

Track health transitions: `healthy → failed` (source or storage failure with reason), `healthy → finalized` (stop), `failed` stays `failed` after its segments are finalized, `healthy|failed → unrecoverable` only by reconciliation when no segment could be validated. Segment states: `open → finalized` (pause, stop, device change, recovery) or `open → unrecoverable` (recovery failed; file kept).

## Deletion

`MeetingStore.deleteConfirmed(id:revision:)` follows the existing confirmed-deletion pattern with files first: refuse when the meeting is active; remove every segment file listed for the meeting, then any remaining entries in `Meetings/<id>/`, then the directory; only when the directory is gone, delete the `meetings` row in one transaction (tracks, segments, pauses, notes and outcomes cascade). A partial file failure leaves the row, records which paths remain in the returned outcome and marks the meeting `deletion_pending` in memory only; the library keeps showing it with a "Deletion incomplete" label until a retry succeeds. Another meeting's rows and files are never touched (SC-009).

## Preferences

None added. Meeting storage root is derived from the application data directory; no relocation UI.

## Instrumentation records

`ResourceRecorder` gains metrics (content-free, bounded by the existing item and payload limits): `meetingStartDuration`, `meetingCaptureInitDuration`, `meetingTransition` (count keyed by target state), `meetingMicQueueDepth`, `meetingSystemQueueDepth`, `meetingDroppedFrames`, `meetingBytesWritten` (per track type), `meetingWriteFailure`, `meetingEncoderFailure`, `meetingPauseCount`, `meetingResumeCount`, `meetingFinalizationDuration`, `meetingSegmentBytes`, `meetingRecoveryOutcome` (count keyed by outcome kind), and RSS samples with phase `meetingRecording`, `meetingPaused`, `meetingFinalizing`. Titles, note text, file names derived from titles and audio never enter a record; the existing content-free test pattern is extended to the new metrics.
