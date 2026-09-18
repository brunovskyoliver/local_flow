# Contract: transcript store, paging, settings and UI

Normative for `TranscriptStore`, `TranscriptStoring`, `TranscriptPager`, the Settings and Meetings UI additions and the user-facing texts. Schema is in [../data-model.md](../data-model.md).

## `TranscriptStoring`

```swift
protocol TranscriptStoring: Sendable {
  func transcription(meetingID: UUID) async throws -> MeetingTranscription?
  /// Write-then-publish, inside one transaction with the lifecycle check.
  @discardableResult
  func transition(meetingID: UUID, to: TranscriptState, now: Int64, effects: [TranscriptTransitionEffect]) async throws -> MeetingTranscription
  func setLiveState(meetingID: UUID, liveState: LiveState?, now: Int64) async throws
  /// Update the live pass's descriptor/reload counter without a lifecycle self-transition.
  func updateLiveMetadata(meetingID: UUID, descriptor: AnalysisStreamDescriptor, incrementModelReloads: Bool, now: Int64) async throws -> MeetingTranscription
  /// One transaction: validates, inserts ≤ 50 rows, updates counters and progress, throws `capacityExceeded` before writing anything.
  func appendSegments(meetingID: UUID, passID: UUID, drafts: [TranscriptSegmentDraft], progress: FinalizationProgress?, now: Int64) async throws -> Int
  func appendGap(_ gap: LiveGap) async throws
  /// Completion transaction (see transcription-lifecycle.md, "Finalization", step 4).
  func completeFinalPass(meetingID: UUID, passID: UUID, descriptor: AnalysisStreamDescriptor, coveredMs: Int64, now: Int64) async throws -> MeetingTranscription
  /// Deletes the pass's rows; used when a pass restarts under a new identity.
  func discardPass(meetingID: UUID, passID: UUID) async throws
  /// Restart a finalizing row atomically: remove earlier final rows, recount usage,
  /// clear progress and apply identity/timestamp/descriptor effects.
  func restartFinalPass(meetingID: UUID, passID: UUID, now: Int64, effects: [TranscriptTransitionEffect]) async throws -> MeetingTranscription
  /// Next ordinal for a resumed pass.
  func passSegmentCount(meetingID: UUID, passID: UUID) async throws -> Int
  func page(meetingID: UUID, finality: SegmentFinality, after ordinal: Int?, limit: Int) async throws -> [TranscriptSegment]
  func gaps(meetingID: UUID) async throws -> [LiveGap]
  func activeRows(limit: Int) async throws -> [MeetingTranscription]
  /// Atomically validate the expected row revision/state, transition and insert the outcome.
  func recover(row: MeetingTranscription, to: TranscriptState, outcome: RecoveryOutcome) async throws
  func recordOutcome(_ outcome: RecoveryOutcome) async throws
  func usage() async throws -> TranscriptUsage
}
```

`transcription(meetingID:)` lazily inserts `not_requested` for an existing terminal pre-migration meeting without a transcript row. Active meetings without a row return nil, preserving the preparing transaction as the owner of new-row creation. It returns nil when the meeting does not exist.

`TranscriptTransitionEffect`: `setIdentity(engine:model:pipeline:planner:vocabulary:)`, `setDescriptor(AnalysisStreamDescriptor)`, `setPass(id:kind:)`, `setFailure(category:detail:)`, `clearFailure`, `setProgress(FinalizationProgress)`, `incrementModelReloads`, `setTimestamps(...)`. `MeetingTransitionEffect` gains `insertTranscription(liveRequested: Bool)` so the row is created in the meeting's `preparing` transaction.

Errors (`TranscriptStore.Error`): `invalidTransition(from:to:)`, `staleRevision`, `missingRow`, `capacityExceeded(meetingSegments|meetingBytes|globalBytes)`, `invalidSegment(reason)`, `passMismatch`, `damagedDatabase`. Every error is content-free.

Capacity check order in `appendSegments`: byte caps per column → `start_ms < end_ms` and `end_ms ≤ covered` → ordinal continuity → `segment_count + n ≤ 20,000` → `text_bytes + Σ ≤ 16 MiB` → `transcript_usage.text_bytes + Σ ≤ 48 MiB`. A refused batch leaves every row and counter unchanged; the caller maps `capacityExceeded` to `persistence_capacity` and reports the kept count.

`recover(row:to:outcome:)` checks the expected revision/state and matching outcome meeting ID in the SQLite transaction. It writes `finalization_interrupted` with the fixed found-state detail, clears live state, and inserts the recovery outcome. Any failure rolls back both changes, leaving the active row eligible for the next launch.

`MeetingStore.deleteConfirmed`: before the existing `DELETE FROM meetings`, `UPDATE transcript_usage SET text_bytes = text_bytes − ?, segment_rows = segment_rows − ?` from the meeting's counters, in the same transaction. A store test asserts usage returns to zero after deleting every meeting.

## Paging

`TranscriptPager` (view model, `@MainActor @Observable`): `pageSize = 200`, `maximumResidentPages = 2`. `loadFirst()` fetches ordinals `< 200`; `loadNext()` fetches after the last ordinal; `loadPrevious()` before the first; whichever page is farther from the viewport is evicted so at most 400 segments are held. `count` comes from `segment_count`, never from loading rows. During `finalizing`, the pager reads `provisional` rows; on `final` it switches to `final` rows and reloads the first page. Tests: never more than 400 resident with 10,000 synthetic rows; first page load issues exactly one segment-page query (row and gaps are read separately); eviction order.

Failed or interrupted rows display the finality of their last pass, preserving access to partial final text. Gap metadata is loaded separately, bounded to 10,000 rows per meeting; page eviction diagnostics retain at most 1,000 ordinals.

`LiveTranscriptModel`: ring of the 200 newest provisional segments fed by the coordinator's batch flushes (never by re-querying during live); `autoFollow` true until the user scrolls up, restored when scrolled to the bottom.

Adjacent gaps with the same meeting, pass, stretch and reason merge into one row.
`updateLiveMetadata` requires `state = live`, increments `revision` and commits before
its returned row is published. It does not add a `live → live` lifecycle transition.

## Settings

`AppPreferences.meetingTranscriptionEnabled: Bool` (UserDefaults key `meetingTranscriptionEnabled`, default `true`), shown in Settings > Meetings as "Transcribe meetings while recording" with the caption "Uses the local speech model. Recording never depends on it." No other preference is added.

## Meetings UI

Start: the Meetings page's Start control shows a "Transcribe" toggle pre-filled from the preference; the value goes into `MeetingStartOptions.transcription`. The menu-bar Start item uses the preference without a toggle.

Active meeting view, Transcript section (below the track indicators, above notes):

- State line: "Transcribing", "Catching up", "Degraded — some live text skipped; the full transcript is produced when the meeting stops", "Live transcription suspended — catching up", "Transcription failed: <category text>", or "Transcription off" with the activity indicator animating only while a window is in flight.
- Segment list: the 200 newest provisional segments, each with `mm:ss` from `start_ms`, normalized text, and a "provisional" marker (italic text plus a trailing dot glyph with accessibility label "Provisional").
- Auto-follow per `LiveTranscriptModel`.

Meeting detail view, Transcript section (after tracks, before notes, separately selectable and copyable from notes):

- Header: state badge (`Not requested`, `Pending`, `Live`, `Finalizing n %`, `Final`, `Failed`, `Interrupted`), coverage line "Covers m:ss of m:ss recorded" when final, failure text when failed, and the actions: "Transcribe" (`not_requested`), "Retry" (`failed`, `interrupted`), "Re-transcribe" (`final`, confirmation sheet: "Replace the final transcript by transcribing the recording again?").
- Segments through `TranscriptPager` with `h:mm:ss` timestamps; clicking a timestamp seeks the microphone track's playback controller to `start_ms` (best effort; disabled when no track is playable).
- Diagnostics disclosure: engine, model id and revision, pipeline version, planner version, vocabulary revision and hash prefix, analysis descriptor version and contributing tracks, replaced provisional count, live gap count and total seconds, model reload count, pass id.
- Text selection uses the normalized text; copying a range yields normalized text joined by newlines.

Library rows show a small transcript glyph for `final` and a warning glyph for `failed`/`interrupted`; nothing else changes.

## Instrumentation contract

New `ResourceRecorder.Metric` cases and phases as listed in [../research.md](../research.md), "Instrumentation". `meetingKey` for transcript metrics is one of: a `TranscriptState` raw value, a `LiveState` raw value, a failure category, or a gap reason. The content-free test enumerates the new cases and asserts each rejects any string outside those sets. Log lines carry state names, counts, codes and durations only.

## Privacy and offline

No new network path; no new permission; no file written outside `history.sqlite`. The tap, mixer, queue and finalizer never write audio to disk. `Feature 003` rewriting has no entry point from any transcript type (compile-time: the transcript module does not import `RewriteRequesting`).
