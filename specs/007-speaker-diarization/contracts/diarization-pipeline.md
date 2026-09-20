# Contract: diarization pipeline, runtime boundary and bounds

## Runtime boundary (`Core/DiarizationBoundaries.swift`)

The meeting domain never imports FluidAudio types.

```swift
enum ModelWorkload: Sendable, Equatable { case speechRecognition, diarization }

struct DiarizationWindowRequest: Sendable {
  let samples: [Float]          // mono 16 kHz, 1...9_600_000 samples, all finite
  let numSpeakers: Int?         // 1 for the default microphone track; nil otherwise
}
struct DiarizationWindowResult: Sendable {
  struct Turn: Sendable { let cluster: Int; let startSeconds: Double; let endSeconds: Double; let quality: Float? }
  let turns: [Turn]                       // ≤ 20_000 per window, else invalidResult
  let centroids: [Int: [Float]]           // cluster → mean embedding; in memory only
}
protocol DiarizationRuntime: Sendable {
  func diarize(_ request: DiarizationWindowRequest) async throws -> DiarizationWindowResult
  func shutdown() async
}
```

`FluidAudioDiarizerFactory.makeRuntime()` checks that `ModelHub.offlineMode` is true, that the OS is macOS 15 or later, and that the pinned descriptor matches. It then calls `OfflineDiarizerModels.load(from:)` and `OfflineDiarizerManager(config:).initialize(models:)`, where the config is community defaults with `exclusiveSegments = false`, `exposeChunkEmbeddings = true` and, per request, `clustering.numSpeakers`. Centroids are the normalized means of each cluster's chunk embeddings (research R4). A cluster without chunk embeddings is omitted from `centroids`. It never calls `prepareModels()`. The runtime maps `speakerId` values "S1…" to integer clusters. `noSpeechDetected` becomes an empty result, not an error.

## Lifecycle (`ModelLifecycleCoordinator` changes)

| Call | Behavior |
| --- | --- |
| `acquire(session:workload: .speechRecognition)` | Unchanged when no owner holds a lease. When a diarization lease is held, it calls `cancelAndJoin(that lease)` and then proceeds. A resident diarizer is released before ASR prepares. |
| `acquire(session:workload: .diarization)` | Throws `busy` if any lease is held or installation is running. A resident ASR runtime (cooling or kept loaded) is released first, then the diarizer is prepared. |
| `diarize(lease, request)` | Requires the lease's workload to be `.diarization` and the state to be active, with one inference at a time. Validates the request bounds. |
| `finish(diarization lease)` | Releases immediately (no cooldown). If Keep model ready is on, it schedules an ASR prepare afterwards. |
| `transcribe(lease, …)` on a diarization lease | `staleLease` |

State observation adds the workload to the phase, so `modelLoading(diarization)` and similar values are recorded separately.

## Run pipeline (`MeetingDiarizer` actor)

1. **Admission**: The meeting must be terminal and its transcript `final`. The run's `transcript_pass_id` is the transcript's current `pass_id`. At least one track needs a finalized segment file on disk; otherwise the run fails with `audio_missing` and the transcript is untouched.
2. **Acquire** the diarization lease. The failure mapping is `model_unavailable`, `os_unsupported` or `model_load_failure`.
3. **For each track** (system first, then microphone): walk `MeetingFinalizer.workItems(detail:page:)` pages of 100 stretches, using the same `baseMs` as the transcript. Decode the stretch's single track through `AnalysisStreamMixer` into the reusable window buffer. For each full window, and for the stretch tail:
   - `diarize` the window.
   - Reconcile the window's clusters (R4).
   - Convert the turns to recorded-timeline milliseconds: `baseMs + windowOffsetMs + seconds × 1000`, clamped to the stretch.
   - Persist the new speakers and the turns in batches of ≤ 500.
   - Check for cancellation.
   - Check that the transcript `pass_id` is unchanged, otherwise fail with `transcript_changed`.
4. **Finish** the lease, which releases the diarizer (FR-032).
5. **Align**: page the final segments 500 at a time in ordinal order. For each page, read the turns overlapping [page start, page end) through the `(run_id, start_ms)` index, bounded by the page's time span. Run `SpeakerAligner` and write the assignments into the completion transaction's staging (the batches are inserted inside the completion `write`).
6. **Complete** atomically, including carry-over (R7) and the colors and ordinals. On any error before commit, the run fails and its rows are deleted.

Preemption applies only to steps 2–4, while the lease is held. It is checked between windows, and the in-flight window is joined, never abandoned. After `finish` there is no lease to revoke, so alignment and completion (steps 5–6) run to the end unless the user cancels or the meeting is deleted. Those two are checked between windows and between alignment pages.

## Coordinator (`SpeakerDiarizationCoordinator`, main actor)

- `meetingTranscriptDidFinalize(id:)` enqueues when automatic diarization is enabled and the model is installed.
- `requestRun(meetingID:revision:trigger:)` handles Run, Retry and the in-room change.
- `cancel(meetingID:)`, `meetingWillDelete(id:) async` (cancel and join), and `resume(_ ids:)` (from reconciliation).
- It publishes `DiarizationStatus { meetingID, state, progress (windows done / planned), failure, labelsRevision }`.

## Bounds summary

| Item | Capacity | At capacity |
| --- | --- | --- |
| Run queue | 100 meeting ids, deduplicated | Automatic requests are skipped (meeting stays `not_requested`); manual requests show "queue is full" |
| Concurrent runs | 1 | Others wait in the queue |
| Decode buffer | 4,096 frames per track, one track at a time | n/a |
| Window buffer | 9,600,000 samples (38.4 MB), one reusable buffer (provisional, R4) | The stretch is split into further windows |
| Engine working set per window | ≤ ~300 segmentation chunks, ≤ ~900 embeddings | Bounded by window length |
| Run clusters per track | 64 | Turns stored with no speaker, counted as `overflow_turns`, aligned as Unknown |
| Turns per window result | 20,000 | Run fails with `runtime_failure` / `invalid_result` |
| Turns per run | 100,000 | Run fails with `persistence_capacity`; nothing is adopted |
| Write batch | 500 rows | Next batch |
| Alignment page | 500 segments; turns bounded by the page's time span | Next page |
| Carry-over sweep | 1,000 turns per page per run | Next page |
| Speakers resident in UI | Speaker rows for one meeting (≤ 128 engine plus manual speakers) | n/a |
| Corrections per meeting | 10,000 | Save refused with a message |
| Reconciliation per launch | 100 runs | The rest wait for the next launch |
| Name suggestions | 8 | Truncated |

## Failure mapping

| Cause | Run result | Transcript, audio, notes, accepted run |
| --- | --- | --- |
| Model not installed / manifest mismatch | failed(`model_unavailable`) | untouched |
| macOS 14 | failed(`os_unsupported`) | untouched |
| Load error | failed(`model_load_failure`) | untouched |
| No finalized track file | failed(`audio_missing`) | untouched |
| Decode or open error | failed(`audio_decode_failure`) | untouched |
| Engine error / invalid result | failed(`runtime_failure`) | untouched |
| Transcript re-finalized mid-run | failed(`transcript_changed`); automatic re-enqueue if enabled | untouched |
| SQLite error / ceiling | failed(`persistence_failure` / `persistence_capacity`) | untouched |
| Crash or force quit | interrupted at the next launch | untouched |
| Preemption by speech recognition | back to pending at the queue head | untouched |
| User Cancel / meeting deleted | run row deleted | untouched / removed with the meeting |

## Instrumentation (content-free, FR-037)

New `ResourceRecorder` phase: `diarizing`. The new metrics are:

- `diarizationModelLoadDuration`, `diarizationModelReleaseDuration`
- `diarizationDuration`, `diarizationRealTimeFactor`, `diarizationAudioMs`
- `diarizationWindowCount`, `diarizationSpeakerCount`, `diarizationTurnCount`, `diarizationOverlapTurnCount`
- `diarizationUnknownCount`, `diarizationAmbiguousCount`
- `diarizationReconciledMatches`, `diarizationReconciledNew`, `diarizationReconciledUncertain`, `diarizationOverflowTurns`
- `diarizationPreemption`, `diarizationFailure` (the key is the category)
- `speakerRenameCount`, `speakerMergeCount`, `speakerUnmergeCount`, `speakerSegmentCorrectionCount`
- Peak RSS and RSS after release, through the existing 10 s sampler during `diarizing`.

The metrics never include names, text, quotes, embeddings, audio or file paths. The existing content-free recorder test is extended to cover them.
