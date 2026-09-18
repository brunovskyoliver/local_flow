# Contract: transcription lifecycle, coordinator and model ownership

Normative for `MeetingTranscriptionCoordinator`, `TranscriptLifecycle`, `MeetingFinalizer`, `TranscriptReconciler` and their doubles. States and columns are in [../data-model.md](../data-model.md); queue capacities are in [live-analysis.md](live-analysis.md).

## Ownership

- `MeetingTranscriptionCoordinator` (`@MainActor @Observable`) owns at most one live session and at most one finalization at a time, in that priority order: a finalization never runs while a live session exists, and a queued finalization waits for the live session's meeting to stop.
- It publishes one value, `TranscriptStatus`, only after the corresponding row change has committed. It never writes `meetings.*`.
- `MeetingCoordinator` is unchanged in behaviour when `Dependencies.transcription` is nil. When it is set, the meeting coordinator calls the observer below and installs the tap it returns; `meetingWillStart` is awaited for admission state and `meetingWillDelete` is awaited to join cancellation. Capture does not await model preparation or inference; pause, stop and completion callbacks schedule their work.

```swift
/// Implemented by MeetingTranscriptionCoordinator; nil in Feature 004 mode.
@MainActor protocol MeetingTranscriptionObserving: AnyObject {
  /// Called inside the meeting's `preparing` transition; returns the transcription row's initial state.
  func meetingWillStart(id: UUID, options: MeetingStartOptions) async -> TranscriptState   // .pending or .notRequested
  /// Called after a stretch's workers started. Returns one tap per capturing track, or nil when not requested.
  func stretchDidStart(meetingID: UUID, sequence: Int, tracks: [MeetingTrackKind: MeetingSourceFormat]) -> [MeetingTrackKind: MeetingAnalysisTap]?
  func meetingDidPause(id: UUID)                        // live work stops; retention timer starts
  func meetingDidStop(id: UUID)                          // meeting is `finalizing`; live drains
  func meetingDidComplete(id: UUID, detail: MeetingDetail) // meeting is `completed`/`interrupted`; finalization may start
  func meetingWillDelete(id: UUID) async                 // cancel and join any pass for this meeting before the files go
}
```

`MeetingStartOptions` carries `transcription: Bool`, defaulting to `AppPreferences.meetingTranscriptionEnabled`.

## Live session

1. `meetingWillStart` returns the initial state; `MeetingCoordinator` inserts the `meeting_transcriptions` row (`pending` or `not_requested`) in the meeting's `preparing` transaction through a `MeetingTransitionEffect.insertTranscription(...)` effect so the two rows commit together.
2. On the first `stretchDidStart` with `live_requested = 1`: take the vocabulary snapshot; `acquire(session: meetingID)` on the lifecycle; on success transition `pending → live` with engine/model/pipeline/planner/vocabulary identity and the live descriptor; on failure transition `pending → failed` with the mapped category. The meeting keeps recording either way. The lease is acquired on a detached task so `start()` returns without waiting for a model load; provisional text begins when the load completes.
3. Every later `stretchDidStart` (resume, device change) installs fresh taps into the same session; the planner continues on the new stretch with `windowIndex = 0` and the base offset advanced by the previous stretch's stream length.
4. `meetingDidPause`: taps are detached, the queue is drained into a final tail window (bounded by one inference), the retention timer (10 min on the injected clock) starts. When it fires with the meeting still paused: `finish(lease)`; `model_reload_count` is incremented on the next resume's `acquire`.
5. `meetingDidStop`: taps detached; in-flight inference completes or is cancelled within 30 s; remaining queued audio is discarded and recorded as one gap with reason `stop_drain`; batch flushed; `finish(lease)`; transition `live → finalizing`; finalization is enqueued and starts on `meetingDidComplete`.
6. Failure during live (`runtime_failure`, `persistence_failure`, `persistence_capacity`, `analysis_stream_failure`): transition `live → failed`, taps detached, lease finished, buffers released, meeting untouched. Already-persisted provisional segments are kept.

## Finalization

Entry points: automatic after stop; Retry (`failed`, `interrupted`, `final`); Transcribe (`not_requested`); automatic resume at launch (`finalizing` found). All four call `MeetingFinalizer.run(meetingID:, revision:)`:

1. Admission (store transaction): `revision` matches; meeting state is terminal; at least one track has a finalized or recovered segment file; no other pass is running for any meeting (else queued, queue ≤ 100, FIFO). Transition to `finalizing` with a new `pass_id` unless resuming a matching pass (same engine, model ID/revision, pipeline, planner, vocabulary revision/hash) in which case `pass_id` and progress are kept.
2. Snapshot: vocabulary snapshot; identity from `TranscriptionPipelineIdentity`; `acquire(session: meetingID)`; failures map to categories and transition `finalizing → failed`.
3. Work: per stretch, per window as in [live-analysis.md](live-analysis.md), "Finalization decode"; after each persisted batch `progress_sequence`/`progress_sample` are written in the same transaction.
4. Completion transaction: delete provisional segments and live gaps of the meeting, record `replaced_provisional_count`, write `covered_ms`, descriptor with stretches, `finalized_at`, transition `finalizing → final`. Then `finish(lease)`.
5. Cancellation (`meetingWillDelete`, app termination): the pass stops at the next window boundary, leaves its rows and progress in place (`finalizing` remains for launch resume; deletion cascades them anyway), finishes the lease.

Between windows the finalizer checks `Task.isCancelled` and yields. It never holds more than one window of audio.

## Dictation interplay

`AppServices` extends `admissionGuard`: when `MeetingTranscriptionCoordinator.isFinalizing`, dictation is refused with `TranscriptErrorMessage.finalizing` ("Meeting transcript is finalizing. Wait for it to finish."). The Feature 004 guard for active meetings is unchanged. Settings model load/unload controls already disable while a lease is held.

## Reconciliation

`TranscriptReconciler.run()` executes after `MeetingReconciler.run()` on the same detached launch task, bounded to 100 rows, following the table in [../research.md](../research.md), "Reconciliation and recovery policy". It calls `recover(row:to:outcome:)` to atomically persist the transition and one `meeting_recovery_outcomes` row per transcription changed and returns a summary containing the meeting IDs to resume, which the coordinator enqueues after `markReconciliationComplete`. It performs no file access.

The return type is `TranscriptReconciler.Summary`, with `found`, `interrupted`, `failed`, `resume: [UUID]`, `missingMeetings`, `deferred` and a derived `noticeText`. The launch caller enqueues `summary.resume`. Rows whose meeting remains active are deferred. For terminal meetings, `pending` and `live` become `interrupted`, except that a failed meeting makes them `failed`. A `finalizing` row on a failed meeting becomes `failed`; other terminal meetings retain `finalizing` and enter the resume list without a recovery-outcome write. Stable rows are untouched. Missing meeting rows are counted.

A resumed pass uses `passSegmentCount` for its next ordinal. Identity mismatch calls `restartFinalPass` while preserving the `finalizing` lifecycle state; the transaction removes earlier final rows and clears progress. A confirmed re-transcription of a completed final pass discards that previous pass after admission.

## Deletion

`MeetingStore.deleteConfirmed` is extended in its existing transaction: subtract the meeting's counters from `transcript_usage`, then rely on the cascade. The coordinator's `meetingWillDelete` runs first so no pass writes rows for a meeting whose directory is being removed. Global vocabulary and the model are untouched.

## Failure categories and user-facing text

| Category | Cause | Text (`TranscriptErrorMessage`) |
| --- | --- | --- |
| model_unavailable | no verified local model | "The speech model is not installed. Install it in Settings to transcribe." |
| model_provisioning | descriptor incomplete or verification failed | "The speech model could not be verified. Reinstall it in Settings." |
| model_load_failure | lifecycle factory threw | "The speech model failed to load. The recording was not affected." |
| audio_decode_failure | `AVAudioFile` open/read error | "A recorded track could not be decoded. The recording was kept." |
| analysis_stream_failure | converter/mixer error | "Audio could not be prepared for transcription. The recording was kept." |
| runtime_failure | inference threw, invalid result, vocabulary snapshot failure | "Transcription stopped because the speech model failed. The recording continues." |
| finalization_interrupted | app exited or work list exceeded | "Finalization was interrupted. It will resume automatically." / "…Choose Retry to finish it." |
| persistence_failure | batch write failed | "Transcript could not be saved. The recording continues; retry later." |
| persistence_capacity | per-meeting or global limit | "Transcript storage limit reached (N segments kept). Delete old meetings to free space." |

Every text is fixed; none carries a path, title or transcript text.

## Deterministic tests (FR-029)

With `FakeTranscriptionRuntime`, `FakeMeetingAudioSource`, `FakeTranscriptStore` (or the real store on a temp file) and the test clock: live start; disabled start (zero `acquire` calls, zero taps); provisional segment creation; final segment creation; pause/resume with retention expiry and reload count; stop with pending work and the `stop_drain` gap; recognition slowed 3× with backpressure, gap rows and suspension; live gap covered by finalization; model load failure; runtime failure mid-live; batch write failure; restart during live (reconciler marks `interrupted`); restart during finalization (resume from progress reproduces identical windows); Retry after failure; deletion cascade including usage counters; vocabulary snapshot stability across a mid-meeting edit; no transcript text in recorder samples or log messages; paging bounds; timestamps within covered duration; no segment across a pause; track files byte-identical before and after transcription; recording continues after every failure; the Feature 001–004 suites unchanged.
