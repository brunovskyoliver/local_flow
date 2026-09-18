# Contract: meeting storage layout, store API and UI surfaces

## Filesystem layout (FR-023)

```text
<Application Support>/LocalFlow/
  history.sqlite                 # existing database; migration meetings-v5
  Meetings/                      # meeting storage root, mode 0700
    <meeting-uuid>/              # mode 0700, created at preparing
      mic-0001.aac.part          # open microphone segment
      mic-0001.aac               # finalized
      system-0001.aac
      mic-0002.aac               # after a resume or device change
      system-0002.aac
```

- File names carry only the track type and sequence; titles never appear (FR-023).
- `relative_path` in `meeting_segments` is `<meeting-uuid>/<type>-<seq>.aac[.part]`, resolved against the current root at read time; moving the root is supported by pointing the app at it (no UI in this feature).
- `.part` means "open or not yet reconciled". The database row decides what a file is; a `.part` file with a `finalized` row is corrected by reconciliation after re-validation.
- Files are 0600. Playback opens read-only. Nothing but confirmed deletion removes a file.

## `MeetingStore` (actor, shares the `DatabaseQueue`)

| Method | Rule |
| --- | --- |
| `activeMeeting()` | Row in any active state, or nil |
| `create(now:) -> Meeting` | Inserts `created` + empty notes; refuses with `alreadyActive` inside the transaction when an active row exists |
| `transition(id:to:effects:)` | Applies the lifecycle check and the listed side effects (tracks, segments, pauses, timestamps) in one write; throws `invalidTransition` without writing |
| `openSegment(trackID:sequence:path:startedAt:hostStartNs:reason:)` | Refuses when the track already has an `open` row |
| `progressSegment(id:durationMs:byteSize:droppedFrames:)` | The 5 s heartbeat |
| `finalizeSegment(id:durationMs:byteSize:path:closeReason:)` | Updates the row and track totals |
| `markSegmentUnrecoverable(id:reason:note:)` | Recovery only |
| `markTrackFailed(id:reason:at:)` / `markTrackFinalized(id:)` | Health changes |
| `openPause(meetingID:reason:at:)` / `closePause(id:at:closedBy:)` | One open pause per meeting |
| `saveNotes(meetingID:text:revision:) -> Int64` | ≤ 1 MiB; returns the new revision; `staleRevision` on conflict |
| `setTitle(meetingID:title:revision:)` | ≤ 256 bytes |
| `page(before:limit:) -> [MeetingSummary]` | Newest first by `(created_at, id)`; limit ≤ 20 |
| `detail(id:) -> MeetingDetail?` | Meeting, tracks with segments, pauses, notes, outcomes |
| `activeStateRows()` / `recordOutcome(_:)` | Reconciliation |
| `deleteConfirmed(id:revision:) -> DeletionOutcome` | Files first, row last; see [data-model.md](../data-model.md) |

All methods are content-free in logs. Errors are `MeetingStore.Error` values (`alreadyActive`, `invalidTransition`, `segmentAlreadyOpen`, `pauseAlreadyOpen`, `staleRevision`, `missingMeeting`, `notesTooLarge`, `titleTooLarge`, `damagedDatabase`).

## Library and detail (FR-016, FR-017)

- New page `LocalFlowPage.meetings` ("Meetings", symbol `waveform.badge.mic` or similar) in `MainWindowRouter`, placed before Transcriptions.
- Library rows: title or fallback, local start date/time, recorded duration, state badge (Recording, Paused, Finalizing, Completed, Interrupted, Failed), a warning glyph when any track is failed or unrecoverable, and "Deletion incomplete" when applicable. 20 rows per page, at most two pages resident, newest first; no search field.
- Detail: title editor, state and reason text, timestamps, recorded and wall-clock duration, pause list with reasons, per-track card (type, codec/container, sample rate, channels, bitrate, total duration, total bytes, health with reason and time, dropped frames, duration warning) with a segment list, a playback control per track (play/pause/stop, position, duration), the notes editor, recovery outcomes, and Delete.
- Active meeting: the same page shows the active meeting at the top with elapsed time, microphone and system indicators, pause/resume, stop and the notes editor. The menu bar extra gets "Start Meeting" / "Pause" / "Resume" / "Stop Meeting" items and shows the recording or paused glyph in its label.
- Playback: `AVQueuePlayer` with one item per finalized segment in sequence order; unrecoverable segments are listed as "Not playable: <reason>" and skipped. The position label is `start_offset_ms + currentTime`. Files are opened read-only; the byte-identity test (story 8, scenario 3) hashes files before and after.

## Preflight thresholds

| Free space at `Meetings/` | Behaviour |
| --- | --- |
| ≥ 2,000,000,000 bytes | Start |
| 500,000,000 … 1,999,999,999 bytes | Start with the warning "Less than 2 GB free" shown in the active view |
| < 500,000,000 bytes | Refuse with "Not enough free space to record (needs at least 500 MB)" |

## User-facing failure text (`MeetingErrorMessage`)

| Reason | Text |
| --- | --- |
| microphone permission | "Microphone access is not allowed. Enable LocalFlow in System Settings > Privacy & Security > Microphone." (existing) |
| screen recording permission | "System audio needs Screen & System Audio Recording. Enable LocalFlow in System Settings > Privacy & Security > Screen & System Audio Recording, then try again." |
| `storage_write_failed` | "Recording stopped: audio could not be written to disk. What was recorded so far was kept." |
| `storage_unavailable` | "Recording stopped: the meeting folder is unavailable." |
| `not_running_at_last_state` | "LocalFlow did not exit cleanly during this meeting. Recorded audio was recovered where possible." |
| `device_lost` | "The microphone disconnected. The meeting continued with system audio." |
| `stream_stopped` | "System audio stopped. The meeting continued with the microphone." |
| `permission_revoked` | "<Track> permission was revoked during the meeting." |
| `both_sources_failed` | "Recording stopped because both audio sources failed." |
| `record_missing` | "Files were found without a meeting record. They were kept and listed here." |
| `unrecoverable_media` | "This track could not be made playable. The file was kept." |

Texts never include paths, titles or error descriptions from the OS beyond a numeric code.
