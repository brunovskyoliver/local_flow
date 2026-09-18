# Tasks: live meeting transcription

**Input**: Design documents in `specs/005-live-meeting-transcription/`.
**Prerequisites**: `plan.md`, `spec.md`, `research.md`, `data-model.md`, `quickstart.md` and the three files in `contracts/`.
**Tests**: Required by the specification (FR-029 lists the deterministic scenarios; SC-001 to SC-012) and by constitution principle 12. Write the deterministic tests before the code they exercise, confirm they fail for the intended reason, then make them pass. The throughput harness, the live-latency run, the 60-minute memory run, the slow run, the force-quit runs, accuracy parity and the privacy search are separate acceptance tasks on the reference machine and are never marked done from fakes or scaffolding builds.
**Organization**: Setup, the throughput measurement that freezes the live geometry, foundational lifecycle/storage/pure-pipeline/tap work, one phase per user story in priority order (P1 stories first, then P2), then instrumentation, acceptance and polish. All paths are relative to the repository root. New Swift files stay in the existing `LocalFlow` and `LocalFlowTests` targets and are registered in `apps/macos/LocalFlow.xcodeproj/project.pbxproj`.

`[P]` marks tasks that touch different files and can run alongside the other `[P]` tasks in the same phase. It never bypasses a phase gate. All tasks start unchecked; planning establishes no implementation or acceptance completion.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Story]**: Which user story this task belongs to (US1 to US10)
- Every task names the file(s) it changes

## Phase 1: Setup

**Purpose**: Record the starting point, register the files the plan introduces and add the debug knobs the acceptance runs need.

- [X] T001 Record the implementation starting commit, dirty-tree state, Xcode/macOS/FluidAudio/GRDB pins, the reference machine and the constitution scope check (no new package, no server work, no network, no new permission, one runtime owner) in `specs/005-live-meeting-transcription/acceptance/baseline.md`; state that no real-time factor, live-latency, memory-slope or recovery figure exists yet and that the live planner variant is provisional until Phase 2.
- [X] T002 [P] Register the new source and test files from the plan's project structure (`Core/TranscriptBoundaries.swift`, `Core/Transcripts/*.swift`, `Core/Storage/TranscriptStore.swift`, `Features/Transcripts/*.swift`, `LocalFlowTests/Support/TranscriptFakes.swift`, `LocalFlowTests/Transcript*Tests.swift`, `LocalFlowTests/MeetingAnalysisTapTests.swift`, `LocalFlowTests/AnalysisStreamMixerTests.swift`, `LocalFlowTests/AnalysisQueueTests.swift`, `LocalFlowTests/LiveChunkPlannerTests.swift`, `LocalFlowTests/MeetingWindowAssemblerTests.swift`, `LocalFlowTests/LiveRecognizerTests.swift`, `LocalFlowTests/MeetingTranscriptionCoordinatorTests.swift`, `LocalFlowTests/MeetingFinalizerTests.swift`, `LocalFlowTests/WallClockDerivationTests.swift`) as empty placeholders in `apps/macos/LocalFlow.xcodeproj/project.pbxproj` so `plutil -lint` and the Xcode build stay green while later phases fill them in.
- [X] T003 [P] Add `--debug-slow-recognition <factor>`, `--debug-fail-recognition <n>`, `--debug-fail-persistence` and `--debug-seed-transcript <count>` (debug builds only) to the existing runtime-options struct in `apps/macos/LocalFlow/App/AppServices.swift`, with tests in `apps/macos/LocalFlowTests/AppConfigurationTests.swift` that all four default off, that non-numeric factors and counts are ignored, and that release builds never read them.

## Phase 2: Throughput measurement (delivery step 1)

**Purpose**: No Parakeet real-time factor exists in the repository. The `live_contiguous_96000_v1` geometry and the SC-006 gate are provisional until this phase records the evidence (`quickstart.md`, "Throughput measurement").

- [X] T004 Build a throwaway harness under `specs/005-live-meeting-transcription/acceptance/spike/` (a skipped-by-default `LocalFlowUITests` test or a `swift` script) that decodes a stretch file 4,096 frames at a time through `AVAudioFile` + `AVAudioConverter` into 239,360-sample windows and runs each through the real `ModelLifecycleCoordinator.transcribe`, printing audio seconds, recognition seconds, model load duration and RSS before/peak/after; no UI, no store writes.
- [X] T005 Run T004 on the reference machine over the Feature 002 long-continuous fixture and one 10-minute meeting-style fixture, three runs each, and record per run: audio seconds, recognition seconds, real-time factor, model load duration, RSS before/peak/after, hardware, macOS, build and model revision in `specs/005-live-meeting-transcription/acceptance/throughput.md`.
- [X] T006 Decide from T005: RTF ≤ 0.25 keeps `live_contiguous_96000_v1`, above it selects `live_contiguous_64000_v1`; set the SC-006 finalization gate to `measured RTF × 1.5` rounded up; write both into the validation table of `specs/005-live-meeting-transcription/plan.md`, the "Throughput measurement" section of `specs/005-live-meeting-transcription/quickstart.md` and, if the variant changed, `contracts/live-analysis.md` (`AnalysisQueue.catchingUpLagSamples` follows the window size) and `data-model.md` (`planner_version` values).
- [X] T007 Write `docs/adr/0016-meeting-transcription-passes.md` (live preview pass with a separate versioned planner, finalization from durable audio with production geometry, one mixed mono analysis stream; the echo/overlap limitation; the evidence pointer to `acceptance/throughput.md`) and add it to `docs/adr/README.md`.

**Checkpoint**: Real-time factor recorded, live geometry frozen, SC-006 gate set, ADR 0016 written; no production code changed.

## Phase 3: Foundational lifecycle, storage, pure pipeline, tap and fakes

**Purpose**: Every user story depends on the transcript state machine, the migration and store, the pure pipeline pieces, the analysis tap on the track worker and the doubles. Complete this phase before any story phase. With `Dependencies.transcription` nil the app is the Feature 004 app.

### Boundaries, lifecycle and models (delivery step 2)

- [X] T008 [P] Write failing tests in `apps/macos/LocalFlowTests/TranscriptLifecycleTests.swift`: every pair in the `data-model.md` transition table is accepted; every other pair of the seven states (full 7×7 sweep) throws `TranscriptStore.Error.invalidTransition(from:to:)`; `notRequested`, `final`, `failed` and `interrupted` are stable and `pending`, `live`, `finalizing` are active; `TranscriptFailureCategory` has exactly the nine raw values from `data-model.md` and each maps to a non-empty `TranscriptErrorMessage` text from `contracts/transcription-lifecycle.md` containing no path, title or `%@` placeholder; `LiveState` has exactly `live`, `catching_up`, `degraded`, `suspended`, `stopped`.
- [X] T009 [P] Implement `apps/macos/LocalFlow/Core/Transcripts/TranscriptLifecycle.swift` (`TranscriptState`, `LiveState`, `TranscriptLifecycle.transition(from:to:)` as a pure table lookup, `isActive`, `isStable`, `TranscriptFailureCategory`, `TranscriptErrorMessage` with the exact texts) and `apps/macos/LocalFlow/Core/Transcripts/TranscriptModels.swift` (`MeetingTranscription`, `TranscriptSegment`, `TranscriptSegmentDraft`, `SegmentFinality`, `TimingBasis`, `LiveGap`, `LiveGapReason`, `AnalysisStreamDescriptor` with its `Codable` shape, 200-entry stretch cap and `stretchesTruncated`, `TranscriptStatus`, `FinalizationProgress`, `LiveWindow`, `TranscriptPage`, `FinalizationWorkItem`, `TranscriptUsage`); make T008 pass.
- [X] T010 [P] Declare the boundary protocols in `apps/macos/LocalFlow/Core/TranscriptBoundaries.swift`: `MeetingTranscriptionObserving` (the six methods from `contracts/transcription-lifecycle.md`), `TranscriptStoring` (the method list from `contracts/transcript-storage.md`), `TranscriptTransitionEffect` (all eight cases), `TranscriptStore.Error` (`invalidTransition`, `staleRevision`, `missingRow`, `capacityExceeded(meetingSegments|meetingBytes|globalBytes)`, `invalidSegment(reason)`, `passMismatch`, `damagedDatabase`), all `Sendable`; add `MeetingStartOptions` (`transcription: Bool`) and `MeetingTransitionEffect.insertTranscription(liveRequested:)` to `apps/macos/LocalFlow/Core/Meetings/MeetingBoundaries.swift`.

### Migration and store (delivery step 2)

- [X] T011 Write failing tests in `apps/macos/LocalFlowTests/TranscriptStoreTests.swift` against a temp-dir `DatabaseQueue`: migration `transcripts-v6` creates `meeting_transcriptions`, `transcript_segments`, `transcript_live_gaps` and `transcript_usage` with the columns, check constraints (state, live_state, pass_kind, finality, timing_basis, analysis_tracks, reason, `speaker = 'unassigned'`, `end_ms > start_ms`, `id = 1`), cascades and the `meeting_transcriptions_active`, `transcript_segments_page`, `transcript_segments_pass` indexes from `data-model.md`, and alters no Feature 001–004 table; `transition` applies the lifecycle check and its effects in one write and a rejected transition writes nothing; a store double that throws mid-transaction leaves the row unchanged; `setLiveState` accepts non-nil only while `state = 'live'`; `appendSegments` validates in the contract order (byte caps → `start_ms < end_ms ≤ covered` → ordinal continuity → 20,000 rows → 16 MiB → 48 MiB global), refuses a whole batch with `capacityExceeded` leaving every row and counter unchanged, inserts ≤ 50 rows with counters and `progress_sequence`/`progress_sample` in one transaction, and never updates an existing `final` row; `appendGap` merges beyond 10,000 rows into the last row; `completeFinalPass` deletes provisional rows and gaps, records `replaced_provisional_count`, `covered_ms`, descriptor, `finalized_at` and moves to `final` in one transaction; `discardPass` deletes only that pass's rows; `page` returns rows by `(finality, ordinal)` with limit clamped to 200 and issues one query; `activeRows(limit:)` lists only `pending`, `live`, `finalizing`; `recordOutcome` writes a `meeting_recovery_outcomes` row with the `transcript:` prefix; `usage()` round-trips; `revision` bumps on every write and a stale revision on Retry throws `staleRevision`; a pre-005 database opens with zero transcript rows and `transcript_usage` at zero.
- [X] T012 Add migration `transcripts-v6` to `apps/macos/LocalFlow/Core/Storage/HistoryMigrations.swift` exactly as specified in `data-model.md` (four tables, all checks, `ON DELETE CASCADE` on every child, the three indexes, the `transcript_usage` seed row).
- [X] T013 Implement the `TranscriptStore` actor in `apps/macos/LocalFlow/Core/Storage/TranscriptStore.swift` sharing the existing `DatabaseQueue`, with every `TranscriptStoring` method, the write-then-publish transition, the capacity-check order, `updated_at` and `revision` bumped on every write, and content-free logging; make T011 pass.
- [X] T014 Extend `apps/macos/LocalFlow/Core/Storage/MeetingStore.swift`: handle `MeetingTransitionEffect.insertTranscription(liveRequested:)` inside the `preparing` transaction (row `pending` when requested, `not_requested` otherwise), and in `deleteConfirmed` subtract the meeting's `text_bytes` and `segment_count` from `transcript_usage` before the existing `DELETE FROM meetings`; extend `apps/macos/LocalFlowTests/MeetingStoreTests.swift` so the transcription row commits with the meeting row (and neither exists when the transition is rolled back), the cascade removes transcription, segments and gaps, and usage returns to zero after deleting every meeting.

### Pure pipeline pieces (delivery step 3)

- [X] T015 [P] Write failing contract tests in `apps/macos/LocalFlowTests/LiveChunkPlannerTests.swift` for both `live_contiguous_96000_v1` and `live_contiguous_64000_v1`: windows contiguous and non-overlapping; `Σ window samples + Σ skipped samples == streamEnd` at pause/stop; a window never crosses a stretch boundary; `windowIndex` restarts at 0 per stretch; the version string is constant; fixtures for exact multiples, a 1-sample tail, skips inside and across window boundaries, and 8 hours of counters with no allocation growth.
- [X] T016 [P] Implement `apps/macos/LocalFlow/Core/Transcripts/LiveChunkPlanner.swift` (pure state machine over `streamEnd`/`nextStart`, `skip(_:)`, `nextWindow(tail:)`, the two static configurations selected once at live start); make T015 pass.
- [X] T017 [P] Write failing tests in `apps/macos/LocalFlowTests/AnalysisQueueTests.swift`: a 480,000-Float32 ring is preallocated once; `write` returns the accepted count and 0 while suspended; `read` and `discardOldest` keep `occupancy` consistent; `highWater` reports the maximum; suspension at capacity clears when occupancy ≤ 160,000; the lag table (≤ 6 s live, 6–10 s catching_up, > 10 s discard whole windows to ≤ 10 s, capacity → suspended) is evaluated from `streamEnd − consumedEnd` with the in-flight window counted as unconsumed; single-producer/single-consumer access from two threads for 10,000 iterations is consistent.
- [X] T018 [P] Implement `apps/macos/LocalFlow/Core/Transcripts/AnalysisQueue.swift` (SPSC ring, the four constants, `write`, `read(into:count:)`, `discardOldest`, `occupancy`, `highWater`, `suspended`, and a pure `lagPolicy(lag:occupancy:) -> LiveState` helper); make T017 pass.
- [X] T019 [P] Write failing tests in `apps/macos/LocalFlowTests/AnalysisStreamMixerTests.swift` with synthetic 48 kHz PCM from `FakeAnalysisTap`: both tracks staged → `mean_0.5` mix clamped to ±1 with `tracks = both`; one staging > 8,000 samples and the other empty → emitted alone with `tracks = mic|system`; failed/absent track → the healthy track alone; staging never exceeds 16,000 samples (a conversion that would overflow is deferred to the next tick); `emittedSamples` equals the stretch stream length; `flush()` emits every staged sample; a tap-ring `droppedFrames` delta advances the stream position and yields a `tap_overflow` gap of the converted length; the descriptor reports `mixed_mono_16k_v1`, 16,000, 1, `mean_0.5` and the contributing tracks; a converter error surfaces as `analysis_stream_failure`.
- [X] T020 [P] Implement `apps/macos/LocalFlow/Core/Transcripts/AnalysisStreamMixer.swift` (one `AVAudioConverter` per track per stretch with `primeMethod = .none`, channel average to mono, 16,000-sample stagings, the three emit rules, `flush()`, gap accounting, descriptor construction; usable by both the live session with `source = live_pcm_tee` and the finalizer with `source = decoded_tracks`); make T019 pass.
- [X] T021 [P] Write failing tests in `apps/macos/LocalFlowTests/MeetingWindowAssemblerTests.swift`: for both geometries the seam decision is always `adjacent` with zero discards; the wrapper never retains more than two windows; the output is the current window's raw text minus `discardedPrefixBytes` with its source mapping; `assembly_version` equals `"\(TranscriptAssembler.version)/\(geometry)"`; the first window of a stretch assembles alone.
- [X] T022 [P] Implement `apps/macos/LocalFlow/Core/Transcripts/MeetingWindowAssembler.swift` (previous-window holder, fresh `TranscriptAssembler` over the rebased pair per window, `append(window:) -> AssembledWindow`); make T021 pass without modifying `TranscriptAssembler`.
- [X] T023 [P] Write failing tests in `apps/macos/LocalFlowTests/TranscriptSegmenterTests.swift`: gap split at 0.8 s; punctuation split at and below the 3-word minimum; the 40-word cap; missing timings → one segment with `timing_basis = window`; empty text → no segment; monotonic `start_ms < end_ms` clamped to the window; raw-byte exactness through `TranscriptSourceMapper`; a segment whose text exceeds 4,096 bytes is split at the previous word; normalization per segment uses the injected `VocabularySnapshot` and records reasons as counts only.
- [X] T024 [P] Implement `apps/macos/LocalFlow/Core/Transcripts/TranscriptSegmenter.swift` (`segmenter_gap0.8_punct_v1`, `segments(window:base:) -> [TranscriptSegmentDraft]`, normalization through `TranscriptNormalizer(vocabulary:)`); make T023 pass.
- [X] T025 [P] Write failing tests in `apps/macos/LocalFlowTests/WallClockDerivationTests.swift`: `wallClock(startMs:)` over a `MeetingDetail` with three stretches and two pauses returns the microphone segment's `started_at` plus the offset inside the stretch; the system segment is used when the microphone segment is absent; nil when the stretch row is missing; a `startMs` beyond the last stretch returns nil; a truncated descriptor (`stretchesTruncated = true`) derives the remaining bases from `meeting_segments.duration_ms`.
- [X] T026 [P] Implement `apps/macos/LocalFlow/Core/Transcripts/WallClockDerivation.swift` as a pure function over `MeetingDetail` and `AnalysisStreamDescriptor`; make T025 pass.

### Tap, worker and coordinator hooks (delivery step 4)

- [X] T027 [P] Add `apps/macos/LocalFlowTests/Support/TranscriptFakes.swift`: `FakeTranscriptionRuntime` (scripted windows with word timings, configurable delay through the test clock, failure on the nth call, cancellation observation, `acquire`/`finish` call counts), `FakeAnalysisTap` (synthetic 48 kHz PCM at a schedule, `droppedFrames` knob), `FakeTranscriptStore` (in-memory `TranscriptStoring` with failure knobs, capacity limits and a per-call log), `FakeMeetingTranscriptionObserver` (records every observer call), synthetic window and PCM builders, and a synthetic two-track stretch-file builder reusing `MeetingFakes` ADTS fixtures.
- [X] T028 [P] Write failing tests in `apps/macos/LocalFlowTests/MeetingAnalysisTapTests.swift`: `push` copies a 4,096-frame block into a `MeetingSampleRing` sized for the stretch's source format; overflow drops the whole block and grows `droppedFrames`; `detach()` refuses further pushes and is idempotent; `push` never blocks, throws or retains the buffer (assert on a full ring with a timing bound on the test clock).
- [X] T029 [P] Implement `apps/macos/LocalFlow/Core/Transcripts/MeetingAnalysisTap.swift` (`kind`, `ring`, `push`, `detach`, `droppedFrames`, `@unchecked Sendable`); make T028 pass.
- [X] T030 Extend `apps/macos/LocalFlowTests/MeetingTrackWorkerTests.swift`: with a nil `analysisSink`, encoded frames, bytes written, sync times and heartbeats equal the existing fixture run (byte-for-byte comparison); with a slow or full sink the worker's write timing and output are unchanged and the tap's `droppedFrames` grows; a sink is never called after `detach`.
- [X] T031 Add the optional `analysisSink` to `apps/macos/LocalFlow/Core/Meetings/MeetingTrackWorker.swift` (`drainOnce` calls `analysisSink?.push(block)` before `encoder.encode(block:)`, never awaiting it); make T030 pass with the existing worker tests unchanged.
- [X] T032 Extend `apps/macos/LocalFlowTests/MeetingCoordinatorTests.swift` with `FakeMeetingTranscriptionObserver`: with `Dependencies.transcription` nil every existing test passes unchanged and no observer method is called; with it set, `start(options:)` calls `meetingWillStart` inside `preparing` and passes the returned state into `insertTranscription`, `stretchDidStart` is called after each stretch's workers start (start and every resume) and the returned taps are installed on that stretch's workers, `meetingDidPause`/`meetingDidStop`/`meetingDidComplete` fire in order with the meeting state already persisted, `meetingWillDelete` is awaited before any file is removed, and `MeetingStatus.transcriptionRequested` reflects the option; no meeting transition awaits transcription work (assert with an observer that never returns from a fire-and-forget call).
- [X] T033 Add `Dependencies.transcription: MeetingTranscriptionObserving?`, `start(options: MeetingStartOptions)` (default from `AppPreferences.meetingTranscriptionEnabled`), tap installation per stretch, the observer calls and `MeetingStatus.transcriptionRequested` to `apps/macos/LocalFlow/Features/Meetings/MeetingCoordinator.swift`; make T032 pass with the Feature 004 suites unchanged.

### Instrumentation cases (delivery step 9, pulled forward so stories can record)

- [X] T034 [P] Add the transcript `Metric` cases (`transcriptLiveLatency`, `transcriptAnalysisQueueDepth`, `transcriptRecognitionQueueDepth`, `transcriptSegmentsProvisional`, `transcriptSegmentsFinal`, `transcriptBackpressureEvent` keyed by live state, `transcriptLiveGapMs` keyed by reason, `transcriptFinalizationDuration`, `transcriptRealTimeFactor`, `transcriptPersistenceBatchDuration`, `transcriptModelReload`, `transcriptFailure` keyed by category, `transcriptTransition` keyed by target state) and the phases `transcriptLive`, `transcriptFinalizing` to `apps/macos/LocalFlow/Core/Observability/ResourceRecorder.swift`, keeping the existing item and payload limits, and extend `apps/macos/LocalFlowTests/ResourceRecorderTests.swift` so the content-free assertion enumerates every new case and rejects any `meetingKey` outside the `TranscriptState`, `LiveState`, failure-category and gap-reason sets.

**Checkpoint**: Lifecycle, migration, store, planner, queue, mixer, assembler wrapper, segmenter, wall-clock derivation, tap, worker sink, coordinator hooks, metrics and fakes exist with tests. `make check` passes; no user-visible behaviour has changed; the Feature 001–004 suites are untouched.

## Phase 4: User Story 1 - Live transcript while recording (P1) 🎯 MVP

**Goal**: One `MeetingTranscriptionCoordinator` owns the live session: lease, snapshot, taps, mixer, queue, `LiveRecognizer`, provisional batches, `TranscriptStatus`; the active-meeting view shows provisional text while the recording continues.
**Independent test**: With fakes, start a meeting with transcription on, push two minutes of synthetic PCM, and confirm provisional rows appear in batches while the meeting stays `recording` and the segment writer's byte log keeps growing. Spec US1 scenarios 1–4.

### Tests

- [X] T035 [P] [US1] Write failing tests in `apps/macos/LocalFlowTests/LiveRecognizerTests.swift` with `FakeTranscriptionRuntime`, a real `AnalysisQueue`, the planner and the test clock: the loop plans one window at a time and never has more than one inference in flight; each window goes through transcribe → assemble → segment → normalize → provisional buffer; latency per window is `now − last sample's emit time` and reaches the recorder as `transcriptLiveLatency`; the tail window on pause/stop is at most one inference; an inference error other than cancellation fails the session with `runtime_failure`; the provisional buffer refuses the 201st unpersisted segment with `persistence_failure`; the window buffer is allocated once.
- [X] T036 [P] [US1] Write failing tests in `apps/macos/LocalFlowTests/MeetingTranscriptionCoordinatorTests.swift` with `FakeTranscriptionRuntime`, `FakeTranscriptStore`, `FakeAnalysisTap` and the test clock: `meetingWillStart(options: transcription = true)` returns `.pending`; the first `stretchDidStart` takes the vocabulary snapshot, calls `acquire(session:)` exactly once on a detached task (the call returns before the load completes), transitions `pending → live` with engine, model, pipeline, planner version and vocabulary revision/hash persisted before `TranscriptStatus` publishes, and returns one tap per capturing track; provisional drafts flush in batches of ≤ 50 or after 2 s of clock time; `TranscriptStatus.provisionalCount` follows persisted rows only; a second `stretchDidStart` installs fresh taps and continues the planner with `windowIndex = 0` and the advanced base; only `ModelLifecycleCoordinator.transcribe` is ever called on the runtime.
- [X] T037 [P] [US1] Write failing tests in `apps/macos/LocalFlowTests/TranscriptPagerTests.swift` for `LiveTranscriptModel`: the ring keeps the 200 newest provisional segments and overwrites the oldest; `autoFollow` turns off when the user scrolls up and back on at the bottom; segments arrive only from batch flushes, never from a query during live.

### Implementation

- [X] T038 [US1] Implement `apps/macos/LocalFlow/Core/Transcripts/LiveRecognizer.swift` (one serial task per live session, the plan → read → transcribe → assemble → segment → normalize → buffer loop, latency measurement, tail handling, 200-segment provisional buffer, cancellation only through `lifecycle.cancelSessionAndJoin` after the 30 s bound); make T035 pass.
- [X] T039 [US1] Implement `apps/macos/LocalFlow/Features/Transcripts/MeetingTranscriptionCoordinator.swift` (`@MainActor @Observable`; `MeetingTranscriptionObserving`; the live session with snapshot, lease, taps, `AnalysisStreamMixer` on a 100 ms main-actor timer over the injected clock, `AnalysisQueue`, `LiveRecognizer`, batch flushes through `TranscriptStoring.appendSegments`, `TranscriptStatus` published after each committed change, `transcriptLive` phase and metrics); make T036 pass. Pause, stop, backpressure, failure and finalization behaviour are completed in Phases 5–9.
- [X] T040 [US1] Implement `apps/macos/LocalFlow/Features/Transcripts/LiveTranscriptModel.swift` (200-segment ring, `autoFollow`); make T037 pass.
- [X] T041 [US1] Wire `TranscriptStore` and `MeetingTranscriptionCoordinator` in `apps/macos/LocalFlow/App/AppServices.swift` (shared `DatabaseQueue`, `ModelLifecycleCoordinator`, `VocabularyStore`, `TranscriptionPipelineIdentity`, `ResourceRecorder`, the app clock) and set `MeetingCoordinator.Dependencies.transcription`; keep the object absent in tests that exercise Feature 004 alone.
- [X] T042 [US1] Implement `apps/macos/LocalFlow/Features/Transcripts/TranscriptSectionView.swift` (shared list rendering: `mm:ss`/`h:mm:ss` timestamps, normalized text, the italic "provisional" marker with the trailing dot glyph and accessibility label "Provisional", selectable text) and add the Transcript section to `apps/macos/LocalFlow/Features/Meetings/ActiveMeetingView.swift` below the track indicators and above notes with the state line texts from `contracts/transcript-storage.md`, the activity indicator animating only while a window is in flight, and auto-follow from `LiveTranscriptModel`.

**Checkpoint**: Live provisional text appears end to end against fakes and against the real engine on the development machine while the recording continues. Spec US1 scenarios 1, 2 and 4 pass; scenario 3 completes in Phase 9.

## Phase 5: User Story 2 - Transcription disabled is a first-class mode (P1)

**Goal**: A meeting started with transcription off creates a `not_requested` row, takes no lease, installs no tap and behaves exactly as Feature 004.
**Independent test**: Start with transcription off, pause, resume, stop; zero `acquire` calls, zero taps, no transcript rows, state `not_requested`. Spec US2 scenarios 1–2.

- [X] T043 [P] [US2] Extend `apps/macos/LocalFlowTests/MeetingTranscriptionCoordinatorTests.swift`: with `transcription = false`, `meetingWillStart` returns `.notRequested`, every `stretchDidStart` returns nil, `acquire` is never called, no `transcriptLive` phase is recorded, no segment or gap row exists after start → pause → resume → stop, `TranscriptStatus.state` is `notRequested`, and `meetingDidComplete` starts no finalization.
- [X] T044 [P] [US2] Extend `apps/macos/LocalFlowTests/AppPreferencesTests.swift` and `apps/macos/LocalFlowTests/SettingsTests.swift`: `meetingTranscriptionEnabled` defaults to true, round-trips through UserDefaults key `meetingTranscriptionEnabled`, and the Meetings section shows "Transcribe meetings while recording" with the caption "Uses the local speech model. Recording never depends on it."; `MeetingStartOptions()` defaults from the preference.
- [X] T045 [US2] Add `meetingTranscriptionEnabled` to `apps/macos/LocalFlow/Features/Settings/AppPreferences.swift`, the toggle to the Meetings section of `apps/macos/LocalFlow/Features/Settings/SettingsView.swift`, and the `not_requested` path to `apps/macos/LocalFlow/Features/Transcripts/MeetingTranscriptionCoordinator.swift`; make T043 and T044 pass.
- [X] T046 [US2] Add the "Transcribe" toggle pre-filled from the preference to the Start control in `apps/macos/LocalFlow/Features/Meetings/MeetingLibraryView.swift` (value into `MeetingStartOptions.transcription`) and make the menu-bar Start item in `apps/macos/LocalFlow/App/LocalFlowApp.swift` pass the preference without a toggle; extend `apps/macos/LocalFlowTests/MeetingLibraryTests.swift` so the toggle value reaches `start(options:)`.
- [ ] T047 [US2] Show "Transcription off" in the active-meeting Transcript section of `apps/macos/LocalFlow/Features/Meetings/ActiveMeetingView.swift` when the status is `notRequested`, and confirm `quickstart.md` "Transcription off" on the development machine with `LOCALFLOW_RESOURCE_RECORDING=1`: no `modelLoading` phase during the meeting, `state = not_requested`, playback and notes unchanged; record the datapoint in `specs/005-live-meeting-transcription/acceptance/baseline.md`.

**Implementation note (2026-09-18)**: T043–T046 are validated by deterministic tests. T047's UI is implemented, but its signed recording/playback/notes run is blocked by macOS assistive-access denial; see `acceptance/baseline.md`.

**Checkpoint**: Transcription off is indistinguishable from Feature 004 apart from the `not_requested` row and the later Transcribe action (Phase 12).

## Phase 6: User Story 3 - Bounded live analysis and backpressure (P1)

**Goal**: The FR-021 lag policy runs end to end with gap rows, live-state transitions persisted before publication and every bound asserted; the recording is never throttled.
**Independent test**: With `FakeTranscriptionRuntime` delayed 3× real time, the queue never exceeds 480,000 samples, `backpressure` and `suspended` gap rows appear, the meeting stays `recording` and the writer's byte log grows at the same rate as without transcription. Spec US3 scenarios 1–4.

- [X] T048 [P] [US3] Extend `apps/macos/LocalFlowTests/MeetingTranscriptionCoordinatorTests.swift` with slow-runtime cases: lag ≤ 6 s keeps `live`; 6–10 s persists `catching_up` before `TranscriptStatus` publishes and records `transcriptBackpressureEvent`; > 10 s discards whole windows down to ≤ 10 s, writes one `backpressure` gap row per contiguous range, persists `degraded` and keeps it until lag ≤ 6 s; queue at capacity → `suspended`, the mixer's `write` returns 0, one merged `suspended` gap row per suspension, writing resumes at ≤ 10 s; `transcriptAnalysisQueueDepth` never exceeds 480,000; every gap range lies within the stretch's stream length and gaps never overlap; a 30-minute simulated run at 3× slowdown allocates no buffer beyond the declared bounds (assert on the planner counters, queue high water, provisional buffer and batch sizes).
- [X] T049 [P] [US3] Add a bounded-memory group to `apps/macos/LocalFlowTests/MeetingTrackWorkerTests.swift`: with a tap that never drains, a simulated 30 minutes of pushes keeps the tap ring at capacity, `droppedFrames` grows, and the worker's encoder and writer receive identical block sizes and byte counts as the nil-sink run.
- [X] T050 [US3] Complete the lag policy, gap recording (`backpressure`, `suspended`, `tap_overflow`), `setLiveState` persistence, backpressure metrics and queue-depth sampling in `apps/macos/LocalFlow/Features/Transcripts/MeetingTranscriptionCoordinator.swift` and `apps/macos/LocalFlow/Core/Transcripts/LiveRecognizer.swift`; make T048 and T049 pass.
- [X] T051 [US3] Add the "Catching up", "Degraded — some live text skipped; the full transcript is produced when the meeting stops" and "Live transcription suspended — catching up" state lines to `apps/macos/LocalFlow/Features/Meetings/ActiveMeetingView.swift`, and wire `--debug-slow-recognition <factor>` in `apps/macos/LocalFlow/App/AppServices.swift` to a runtime wrapper that sleeps `factor × audio duration` per window through the injected clock (debug builds only).
- [ ] T052 [US3] Run the 5-minute backpressure check from `quickstart.md` "Live transcript while recording" step 4 on the development machine and record queue high water, gap rows, state sequence and recording continuity in `specs/005-live-meeting-transcription/acceptance/baseline.md` as a development datapoint (not the SC-004 gate).

**Implementation note (2026-09-18)**: T048–T051 are validated by deterministic tests, including 30 minutes of simulated slow recognition and a separate 30-minute undrained-tap recorder comparison. T052 remains unmeasured because macOS denied UI automation. Final transcript recovery belongs to Phase 8.

**Checkpoint**: Backpressure is deterministic under fakes and observable in a real run; no bound is exceeded.

## Phase 7: User Story 4 - Timestamped segments aligned to recorded audio (P1)

**Goal**: Every segment's `start_ms`/`end_ms` lies on the recorded-audio timeline within its stretch; pauses produce no text and no implied duration; wall-clock is derivable.
**Independent test**: A two-stretch fake meeting with a pause yields segments whose times are within each stretch's covered length, none spanning the pause, and `wallClock(startMs:)` returns the expected value for each. Spec US4 scenarios 1–3.

- [X] T053 [P] [US4] Extend `apps/macos/LocalFlowTests/MeetingTranscriptionCoordinatorTests.swift`: after pause → resume the second stretch's segments carry `stretch_sequence = 2`, `window_index` restarting at 0, and `start_ms` continuing from the first stretch's stream length with no segment claiming time inside the pause; `end_ms ≤` the stretch's covered length at insert time; ordinals increase with `start_ms` across the pass; `meetingDidPause` detaches taps, flushes the mixer, drains one tail window at most and produces a `pause_drain` gap for anything left; no window is planned while paused; the retention timer (10 min on the test clock) finishes the lease while still paused, the next resume re-acquires and increments `model_reload_count` with a `model_reload` gap for audio before the reload completes and `transcriptModelReload` recorded; a resume before expiry keeps the lease.
- [X] T054 [P] [US4] Extend `apps/macos/LocalFlowTests/TranscriptStoreTests.swift`: `appendSegments` rejects `start_ms ≥ end_ms`, `end_ms >` covered, a non-contiguous ordinal and a `stretch_sequence` lower than the previous row's with `invalidSegment(reason)` and writes nothing.
- [X] T055 [US4] Implement pause and resume in `apps/macos/LocalFlow/Features/Transcripts/MeetingTranscriptionCoordinator.swift` (`meetingDidPause`, tap detach, mixer flush, tail window, retention timer, lease finish and re-acquire, reload count, per-stretch planner reset with the advanced base) and the store-side validation in `apps/macos/LocalFlow/Core/Storage/TranscriptStore.swift`; make T053 and T054 pass.

**Checkpoint**: Timestamps are correct across pauses under fakes; the wall-clock derivation from Phase 3 applies to real rows.

## Phase 8: User Story 5 - Finalize the transcript after the meeting stops (P1)

**Goal**: Stop drains the live path and starts `MeetingFinalizer` automatically; the finalizer re-transcribes the durable tracks with the production geometry, persists progress per batch, resumes after termination and completes by replacing provisional rows in one transaction.
**Independent test**: Stop a fake meeting with live gaps, cancel the finalizer mid-pass, run it again from persisted progress, and confirm identical windows, no re-finalized rows and full coverage. Spec US5 scenarios 1–4.

### Tests

- [X] T056 [P] [US5] Write failing tests in `apps/macos/LocalFlowTests/MeetingFinalizerTests.swift` over synthetic two-track ADTS stretch files from `TranscriptFakes`, `FakeTranscriptionRuntime` and a temp-dir `TranscriptStore`: admission checks revision, terminal meeting state and at least one finalized or recovered track file, and transitions to `finalizing` with a new `pass_id` and `recorded_ms_at_pass`; decode reads 4,096 frames per call into one buffer per track and fills exactly one 239,360-sample window at a time (no larger allocation); windows run through the assembler with geometry `contiguous_fixed239360_preserve_v1`, the segmenter and the normalizer with the pass's own vocabulary snapshot; each batch persists segments and `progress_sequence`/`progress_sample` in one transaction; cancelling at a window boundary leaves rows and progress in place and `finalizing` intact; a second run with matching identity resumes at the first window whose start ≥ `progress_sample` and reproduces byte-identical windows with no re-finalized row; a run under a different engine/model/pipeline/planner/vocabulary revision discards the pass's rows and restarts; a stretch with one missing or `unrecoverable` track uses the other alone with `tracks = mic|system`; both missing → the stretch is skipped with `lengthMs = 0` in the descriptor; an `AVAudioFile` error → `audio_decode_failure`; a converter error → `analysis_stream_failure`; the work list loads 100 stretches at a time and a 10,001st stretch fails with `finalization_interrupted` / `work_list_capacity`; `completeFinalPass` deletes provisional rows and gaps, records `replaced_provisional_count`, `covered_ms` equal to Σ decoded stretch length, the descriptor with ordered stretches, `finalized_at` and `final`; `transcriptFinalizationDuration`, `transcriptRealTimeFactor` and `transcriptPersistenceBatchDuration` are recorded; source track files are byte-identical before and after the pass; `Task.isCancelled` is checked between windows.
- [X] T057 [P] [US5] Extend `apps/macos/LocalFlowTests/MeetingTranscriptionCoordinatorTests.swift`: `meetingDidStop` detaches taps, waits for the in-flight inference up to 30 s of test-clock time then cancels it, records remaining queued audio as one `stop_drain` gap, flushes the batch, finishes the lease and transitions `live → finalizing`; `meetingDidComplete` starts the finalizer without user action; a finalization never runs while a live session exists and a queued finalization waits for that meeting's stop; the queue holds 100 meeting ids FIFO and refuses the 101st with the "Too many transcripts waiting" notice; closing the view does not affect the coordinator (no view lifetime dependency); a live gap from Phase 6 is covered by the final pass (`covered_by_final = 1` reported before the row is removed).

### Implementation

- [X] T058 [US5] Implement `apps/macos/LocalFlow/Core/Transcripts/MeetingFinalizer.swift` (`run(meetingID:revision:)`; admission transaction; snapshot and identity; lease; work list in pages of 100; per-stretch decode with `AVAudioFile` and the shared `AnalysisStreamMixer` in `decoded_tracks` mode; production geometry through `MeetingWindowAssembler` and `TranscriptSegmenter`; batches with progress; resume logic; identity-mismatch restart via `discardPass`; completion transaction; cancellation at window boundaries; metrics); make T056 pass.
- [X] T059 [US5] Implement stop drain, the finalization queue, `meetingDidComplete`, `isFinalizing`, the `transcriptFinalizing` phase and `TranscriptStatus.progress` in `apps/macos/LocalFlow/Features/Transcripts/MeetingTranscriptionCoordinator.swift`; make T057 pass.
- [X] T060 [US5] Extend `admissionGuard` in `apps/macos/LocalFlow/App/AppServices.swift` so dictation is refused with `TranscriptErrorMessage.finalizing` while `MeetingTranscriptionCoordinator.isFinalizing`, leaving the Feature 004 active-meeting guard unchanged; extend `apps/macos/LocalFlowTests/DictationCoordinatorTests.swift` (or the existing admission test) for the refusal and for normal admission once finalization ends.
- [ ] T061 [US5] Show the "Finalizing n %" badge and the state after stop in the Transcript section of `apps/macos/LocalFlow/Features/Meetings/MeetingDetailView.swift` (header only; the paged list arrives in Phase 10), then confirm `quickstart.md` "Stop, finalize, timestamps" steps 1–2 on the development machine (timed 30 s pause; close the detail view and window during finalization; reopen) and record the datapoint in `specs/005-live-meeting-transcription/acceptance/baseline.md`.

**Implementation note (2026-09-18)**: T056–T060 are validated by deterministic tests (`MeetingFinalizerTests`, `MeetingTranscriptionCoordinatorTests`, `DictationCoordinatorTests`). T061's badge and post-stop state are implemented in `MeetingDetailView`; its development-machine run is unmeasured (see `acceptance/baseline.md`). `TranscriptStoring` gained `restartFinalPass` and `passSegmentCount` for resume; reconcile in T098.

**Checkpoint**: Stop → finalizing → final runs without user action, survives cancellation and resumes from progress under fakes; the real engine finalizes a short meeting on the development machine.

## Phase 9: User Story 6 - Transcription failure is separate from recording (P1)

**Goal**: Every failure category leaves the meeting untouched, keeps already-persisted segments, releases the lease and offers Retry through the one finalization path.
**Independent test**: With the fake runtime refusing to load, failing on the nth window, and the fake store failing writes, the meeting completes normally each time, the transcript is `failed` with the right category, and Retry produces `final`. Spec US6 scenarios 1–4.

- [X] T062 [P] [US6] Extend `apps/macos/LocalFlowTests/MeetingTranscriptionCoordinatorTests.swift`: `acquire` throwing the lifecycle's not-provisioned, verification-failed and factory errors maps to `model_unavailable`, `model_provisioning` and `model_load_failure` with `pending → failed`, zero taps left installed, no lease held, and the meeting's `MeetingStatus` and the writer's byte log unchanged; the nth window throwing → `runtime_failure`, `live → failed`, earlier provisional rows kept, taps detached, lease finished, recording continues to a normal stop; four consecutive batch write failures → `persistence_failure`; `capacityExceeded` → `persistence_capacity` with the kept count in the failure text; a mixer converter error → `analysis_stream_failure`; a vocabulary snapshot failure → `runtime_failure` with detail `vocabulary_unavailable`; every failure records `transcriptFailure` keyed by category and publishes `TranscriptStatus.failure` only after the row committed; `meetings.state` is never written by the coordinator (assert on the meeting store's call log).
- [X] T063 [P] [US6] Extend `apps/macos/LocalFlowTests/MeetingFinalizerTests.swift`: Retry from `failed` and from `interrupted` admits with the current revision and runs the same `run(meetingID:revision:)`; Retry with a stale revision throws `staleRevision` and writes nothing; Retry with no track file is refused with `model`-independent guidance and no lease; a runtime failure mid-pass → `finalizing → failed`, rows before the failure kept, lease finished; a failed transcript retried three times stays retryable.
- [X] T064 [US6] Implement the failure mapping, cleanup and Retry entry point in `apps/macos/LocalFlow/Features/Transcripts/MeetingTranscriptionCoordinator.swift` and `apps/macos/LocalFlow/Core/Transcripts/MeetingFinalizer.swift`; wire `--debug-fail-recognition <n>` and `--debug-fail-persistence` in `apps/macos/LocalFlow/App/AppServices.swift` (debug builds only); make T062 and T063 pass.
- [ ] T065 [US6] Add the "Transcription failed: <category text>" state line to `apps/macos/LocalFlow/Features/Meetings/ActiveMeetingView.swift` and the failure text plus "Retry" action (`failed`, `interrupted`) to the Transcript header in `apps/macos/LocalFlow/Features/Meetings/MeetingDetailView.swift`; confirm `quickstart.md` "Failure separation" steps 1–3 on the development machine and record the datapoint in `specs/005-live-meeting-transcription/acceptance/baseline.md`.

**Implementation note (2026-09-18)**: T062–T064 are validated by deterministic tests; `--debug-fail-recognition` and `--debug-fail-persistence` are wired in `AppServices` (debug builds). T065's state line, failure text and Retry action are implemented; its development-machine run is unmeasured.

**Checkpoint**: All P1 stories are complete: live text, disabled mode, backpressure, timestamps, finalization and failure separation work under fakes and on the development machine.

## Phase 10: User Story 7 - Transcript view in meeting detail (P2)

**Goal**: The detail view shows a paged transcript with timestamps, state badge, coverage, diagnostics, copy and best-effort seek; no more than 400 segments resident.
**Independent test**: Seed 12,000 synthetic final rows; the first page loads with one query, scrolling pages in and evicts, resident count ≤ 400. Spec US7 scenarios 1–4.

- [X] T066 [P] [US7] Extend `apps/macos/LocalFlowTests/TranscriptPagerTests.swift` for `TranscriptPager`: `pageSize = 200`, `maximumResidentPages = 2`; `loadFirst()` issues exactly one query for ordinals `< 200`; `loadNext()`/`loadPrevious()` page by keyset; the page farther from the viewport is evicted so at most 400 segments are held with 10,000 synthetic rows; `count` comes from `segment_count`, never from loaded rows; during `finalizing` the pager reads `provisional` rows and on `final` switches to `final` rows and reloads the first page; eviction order is deterministic.
- [X] T067 [US7] Implement `apps/macos/LocalFlow/Features/Transcripts/TranscriptPager.swift` (`@MainActor @Observable`); make T066 pass.
- [X] T068 [US7] Complete the Transcript section in `apps/macos/LocalFlow/Features/Meetings/MeetingDetailView.swift` after tracks and before notes: the state badge set (`Not requested`, `Pending`, `Live`, `Finalizing n %`, `Final`, `Failed`, `Interrupted`), the coverage line "Covers m:ss of m:ss recorded" when final, the paged list through `TranscriptSectionView` with `h:mm:ss` timestamps, the "Re-transcribe" action for `final` with the confirmation sheet "Replace the final transcript by transcribing the recording again?", the diagnostics disclosure (engine, model id and revision, pipeline version, planner version, vocabulary revision and hash prefix, descriptor version and contributing tracks, replaced provisional count, live gap count and total seconds, model reload count, pass id), selection and copy yielding normalized text joined by newlines, separately selectable from notes.
- [X] T069 [US7] Add timestamp click → `TrackPlaybackController` seek to `start_ms` on the microphone track (disabled when no track is playable) in `apps/macos/LocalFlow/Features/Meetings/MeetingDetailView.swift`, and extend `apps/macos/LocalFlowTests/TrackPlaybackTests.swift` so a seek request lands within the recorded duration and is ignored when nothing is playable.
- [X] T070 [US7] Add the transcript glyph for `final` and the warning glyph for `failed`/`interrupted` to the library rows in `apps/macos/LocalFlow/Features/Meetings/MeetingLibraryView.swift` and `apps/macos/LocalFlow/Features/Meetings/MeetingLibraryViewModel.swift`, extending `apps/macos/LocalFlowTests/MeetingLibraryTests.swift`; wire `--debug-seed-transcript <count>` in `apps/macos/LocalFlow/App/AppServices.swift` to insert synthetic final rows on an existing completed meeting (debug builds only).
- [ ] T071 [US7] Run `quickstart.md` "Paging" with 12,000 seeded segments and "Stop, finalize, timestamps" steps 3–4 on the development machine; record first-page time and the pager's resident count in `specs/005-live-meeting-transcription/acceptance/baseline.md`.

**Implementation note (2026-09-18)**: T066–T070 are validated by deterministic tests; `--debug-seed-transcript` is wired. Copy uses an explicit Copy / Copy selected action over `TranscriptPager.copyText()` (normalized text, one segment per line). T071's timing run is unmeasured.

**Checkpoint**: A three-hour transcript opens promptly, pages, copies and seeks.

## Phase 11: User Story 8 - Notes stay independent (P2)

**Goal**: Notes are byte-identical through a transcribed meeting and never reach the recognizer, the normalizer or a segment.
**Independent test**: Edit notes during a fake transcribed meeting; after finalization the notes column is unchanged and no segment text contains the note phrase. Spec US8 scenarios 1–2.

- [X] T072 [P] [US8] Extend `apps/macos/LocalFlowTests/MeetingTranscriptionCoordinatorTests.swift`: with notes saved during live and during finalization, `meeting_notes` is byte-identical afterwards, no segment's raw, assembled or normalized text contains a unique note phrase, and the notes store's read methods are never called by any transcript type (assert on the meeting store call log); the transcript module has no import of `RewriteRequesting` (a compile-time check via a `grep` in `scripts/` run by `make check`).
- [X] T073 [US8] Keep notes and transcript as separate, separately selectable and copyable sections in `apps/macos/LocalFlow/Features/Meetings/MeetingDetailView.swift` and `apps/macos/LocalFlow/Features/Meetings/ActiveMeetingView.swift`; add the rewrite-import check to `scripts/` and `Makefile`; make T072 pass.

**Implementation note (2026-09-18)**: T072–T073 done; `scripts/check-transcript-imports.sh` runs from `scripts/test.sh` (`make check`).

**Checkpoint**: Notes independence is asserted deterministically and enforced at build time.

## Phase 12: User Story 9 - Transcribe a meeting recorded without transcription (P2)

**Goal**: The Transcribe action runs the same finalizer over `not_requested` meetings, including pre-005 meetings and interrupted meetings with recovered audio.
**Independent test**: A `not_requested` completed meeting and an `interrupted` meeting with one recovered stretch both reach `final` with coverage matching their audio. Spec US9 scenarios 1–2.

- [X] T074 [P] [US9] Extend `apps/macos/LocalFlowTests/MeetingFinalizerTests.swift`: Transcribe on `not_requested` transitions `not_requested → pending → finalizing` with `live_requested` still 0 and runs the same `run(meetingID:revision:)`; a pre-005 meeting row with no transcription row gets one inserted as `not_requested` on first read (or through the migration backfill) and can be transcribed; an `interrupted` meeting with one recovered stretch produces coverage equal to that stretch and a descriptor listing only recovered stretches; Transcribe with the model not provisioned fails with `model_unavailable` guidance and no network access (assert no provisioning call).
- [X] T075 [US9] Implement the Transcribe entry point in `apps/macos/LocalFlow/Features/Transcripts/MeetingTranscriptionCoordinator.swift`, the `not_requested` backfill for pre-005 meetings in `apps/macos/LocalFlow/Core/Storage/TranscriptStore.swift` (or `HistoryMigrations.swift` if done in the migration), and the "Transcribe" action for `not_requested` in `apps/macos/LocalFlow/Features/Meetings/MeetingDetailView.swift`; make T074 pass.
- [ ] T076 [US9] Confirm `quickstart.md` "Transcribe an untranscribed meeting" on the development machine with a Feature 004 meeting recorded before this feature; record coverage and the descriptor in `specs/005-live-meeting-transcription/acceptance/baseline.md`.

**Checkpoint**: Stop, Retry and Transcribe share one finalization path.

## Phase 13: User Story 10 - Deletion and recovery cascade (P2)

**Goal**: Launch reconciliation puts every transcript row into a truthful state without touching audio; deletion removes every transcript artifact and adjusts usage; nothing global is touched.
**Independent test**: Seed rows for each reconciliation case, run the reconciler, check outcomes and resumed ids; delete a transcribed meeting and confirm zero rows and unchanged usage for other meetings. Spec US10 scenarios 1–3.

### Tests

- [X] T077 [P] [US10] Write failing tests in `apps/macos/LocalFlowTests/TranscriptReconcilerTests.swift` with seeded rows on a temp-dir store: `live`/`pending` with meeting `interrupted` or `completed` → `interrupted` with `finalization_interrupted`, provisional segments and gaps kept, one outcome row with the `transcript:` prefix, not in the resume list; `finalizing` with meeting `completed` or `interrupted` → unchanged, id in the resume list; `finalizing` with meeting `failed` → `failed` with `finalization_interrupted`; a missing meeting row is counted and logged; the reconciler processes at most 100 rows per launch and defers the rest; it performs no file access (no file-system dependency; assert the directory listing and file hashes are unchanged) and never calls `acquire`; running it twice is idempotent; it runs after `MeetingReconciler` on the same task.
- [X] T078 [P] [US10] Extend `apps/macos/LocalFlowTests/MeetingDeletionTests.swift`: deleting a transcribed meeting removes its `meeting_transcriptions`, `transcript_segments` and `transcript_live_gaps` rows, decrements `transcript_usage` by exactly its counters, leaves other meetings' rows and files byte-identical (checksum), leaves `vocabulary` and the model descriptor untouched; `meetingWillDelete` cancels and joins a running finalization before the directory is removed and the lease is finished; deleting during live detaches taps and ends the session; the confirmed-deletion dialog is the existing one.

### Implementation

- [X] T079 [US10] Implement `apps/macos/LocalFlow/Core/Transcripts/TranscriptReconciler.swift` (`run() -> Summary` with `resume: [UUID]` per the policy table, atomic state/outcome writes, 100-row bound, no file access); make T077 pass.
- [X] T080 [US10] Chain `TranscriptReconciler.run()` after `MeetingReconciler.run()` on the launch task in `apps/macos/LocalFlow/App/AppServices.swift`, enqueue the returned ids after `markReconciliationComplete`, show the "transcript resuming" notice through the existing indicator-panel notices, and implement `meetingWillDelete` in `apps/macos/LocalFlow/Features/Transcripts/MeetingTranscriptionCoordinator.swift`; make T078 pass.
- [X] T081 [US10] Add the restart-during-live and restart-during-finalization scenarios to `TranscriptRestartTests` in `apps/macos/LocalFlowTests/TranscriptReconcilerTests.swift`: a coordinator torn down mid-live leaves `live` rows that the reconciler marks `interrupted` with provisional rows intact and Retry admitted; a finalizer torn down mid-pass leaves `finalizing` with progress that a fresh coordinator resumes on launch, producing identical windows and no re-finalized rows.
- [ ] T082 [US10] Confirm `quickstart.md` "Deletion" and "Restart safety" step 1 on the development machine; record in `specs/005-live-meeting-transcription/acceptance/baseline.md` (the force-quit during finalization is the reference-machine run T091).

**Checkpoint**: Every story is implemented and deterministically tested; `make check` passes; the Feature 001–004 suites are unchanged.

## Phase 14: Instrumentation, acceptance, traceability and polish

**Purpose**: Vocabulary stability, the remaining FR-029 scenarios, the reference-machine evidence, the traceability audit and documentation.

### Remaining deterministic coverage

- [X] T083 [P] Add the vocabulary snapshot stability test to `apps/macos/LocalFlowTests/MeetingTranscriptionCoordinatorTests.swift`: a vocabulary edit through `VocabularyStore` mid-live does not change the normalization of later segments in the same pass; finalization takes its own snapshot and records its revision and hash; the two passes' recorded revisions differ when the edit happened between them.
- [X] T084 [P] Add `apps/macos/LocalFlowTests/TranscriptInstrumentationTests.swift`: over a full fake live → stop → finalize → fail → retry run, every `ResourceRecorder` sample and every log message (captured through injected content-free log sinks) contains none of three unique spoken phrases, one note phrase or any audio bytes; the `transcriptLive`/`transcriptFinalizing` phases bracket the passes; `transcriptRealTimeFactor` is recognition seconds per audio second; RSS samples continue through finalization.
- [X] T085 [P] Add a track-integrity test to `apps/macos/LocalFlowTests/MeetingFinalizerTests.swift` and `MeetingTranscriptionCoordinatorTests.swift`: SHA-256 of every stretch file is identical before and after a live pass, a final pass, a failed pass and a Retry; no file outside `history.sqlite` is written by any transcript type (temp-dir listing before/after).
- [X] T086 Run the Feature 001–004 suites and `make check` with `Dependencies.transcription` nil in the Feature 004 tests and confirm results are unchanged; record the run in `specs/005-live-meeting-transcription/acceptance/regression.md` (SC-011, FR-028).

### Reference-machine acceptance (never from fakes)

- [ ] T087 Record the 60-minute recording-only baseline per Feature 004's procedure on the reference machine (`scripts/memory-report.sh` every 10 s) in `specs/005-live-meeting-transcription/acceptance/long-run-memory.md`, "Baseline".
- [ ] T088 Run the ≥ 60-minute live run from `quickstart.md` "Memory and duration independence" step 2 (fixture playback and speech, one pause/resume, notes edits, `LOCALFLOW_RESOURCE_RECORDING=1`) and report starting, settled, peak and post-finalization RSS, fitted slope over the settled window (gate < 1 MB per 10 min), `transcriptAnalysisQueueDepth` maximum (gate ≤ 480,000), skipped-interval count, finalization duration, real-time factor against the T006 gate, coverage, file and database growth, with hardware, macOS, build, model, planner version and conditions, in `specs/005-live-meeting-transcription/acceptance/long-run-memory.md` (SC-003, SC-006).
- [ ] T089 During T088 speak twenty short phrases with 5 s silence between them and report the `transcriptLiveLatency` median and p95 with the planner version in `specs/005-live-meeting-transcription/acceptance/live-latency.md` (gate median ≤ 5 s, p95 ≤ 10 s; SC-001).
- [ ] T090 Run the 20-minute slow run with `--debug-slow-recognition 3` (`quickstart.md` step 3) and report bounds held, full-length tracks and final coverage of speech intervals in `specs/005-live-meeting-transcription/acceptance/long-run-memory.md`, "Slow run" (SC-004).
- [ ] T091 Run `quickstart.md` "Restart safety" steps 1–2 on the reference machine (`kill -9` during live and during finalization), compare a `sqlite3 .dump` of the rows before the progress point before and after the resume, and record outcomes with the recovery-outcome rows in `specs/005-live-meeting-transcription/acceptance/recovery.md` (SC-007).
- [ ] T092 Run the Feature 002 quality fixtures through the finalization path (fixture audio copied into a synthetic meeting's stretch files, reusing `apps/macos/LocalFlowTests/Support/QualityEvaluationRunner.swift` where possible) and compare WER against `specs/002-transcription-quality/acceptance/quality-results.md`; report per fixture set with the mixed-language limitation in `specs/005-live-meeting-transcription/acceptance/accuracy-parity.md` (gate within 1 absolute point; SC-009).
- [ ] T093 After T088–T092, `grep -r` the recorder files and `log show --predicate 'subsystem == "org.localflow.LocalFlow"' --last 2h` for the three spoken phrases and the note phrase; record the empty result and the exact commands in `specs/005-live-meeting-transcription/acceptance/privacy.md` (SC-010).
- [ ] T094 Confirm `quickstart.md` "Transcription off" on the reference machine with the recorder on: zero `modelLoading` phases during a full meeting and Feature 004 acceptance figures unchanged within noise; record in `specs/005-live-meeting-transcription/acceptance/long-run-memory.md`, "Transcription off" (SC-002).

### Traceability and documentation

- [X] T095 Run every deterministic transcript suite three times locally and record the identical results, then write `specs/005-live-meeting-transcription/acceptance/fr-029-traceability.md` mapping each FR-029 scenario to one named test (live enabled start T036; disabled start T043; provisional creation T036; final creation T056; pause/resume T053; stop with pending work T057; recognition falling behind and bounded backpressure T048; live gap recovered T057; model load failure, runtime failure, database write failure T062; restart during live and finalization T081; retry T063; deletion cascade T078; vocabulary stability T083; no text in logs T084; paging T066; timestamps within duration and no false duration across pauses T053/T054; raw audio unchanged T085; capture continues after failure T062; Feature 001–003 regressions T086) and each SC to its acceptance file.
- [X] T096 [P] Update `docs/architecture/audio-pipeline.md` (analysis tap, mixer, live planner, queue and lag policy, finalization decode), `docs/architecture/storage.md` (`transcripts-v6` tables, capacity model, cascade, usage row) and `docs/architecture/model-lifecycle.md` (transcript leases, pause retention, finalization interplay with dictation) to match the shipped code.
- [X] T097 [P] Update `docs/performance/memory-budget.md` with the measured recognition working set, the transcript bounds table and pointers to the T088/T090 evidence; state explicitly which figures are measured and which remain unmeasured.
- [X] T098 Reconcile `specs/005-live-meeting-transcription/plan.md`, `contracts/*.md` and `data-model.md` with any name, bound or column that changed during implementation, and confirm `make check` and `.specify/scripts/bash/check-prerequisites.sh --json --require-spec` pass.

**Phases 12–14 validation (2026-09-18):** `make check` passed with 715 tests
passed, zero failures and thirteen opt-in skips. Recovery writes are atomic;
legacy read backfill is restricted to terminal meetings; deletion retains the
current cancellation marker when its bounded set rolls over. See
[regression results](acceptance/regression.md) and
[FR-029 coverage](acceptance/fr-029-traceability.md). T076, T082 and T087–T094 remain
unchecked at the user's request; [manual checks](acceptance/manual-checks.md)
list the procedures and evidence destinations. T097 documents the available
process-RSS measurements and bounds; an isolated production model working set
remains unmeasured.

## Dependencies and execution order

### Phase dependencies

- **Phase 1 (Setup)**: no dependencies.
- **Phase 2 (Throughput)**: after T002; it needs the reference machine and the real model. T006 gates the live planner variant used by T015/T016 and the SC-006 gate used by T088.
- **Phase 3 (Foundational)**: T008–T010 first; T011–T014 after T010; T015–T026 after T009 (T015/T016 after T006); T027 after T009/T010; T028–T033 after T027; T034 independent. Blocks every story phase.
- **Phase 4 (US1)**: after Phase 3. MVP.
- **Phase 5 (US2)**: after Phase 4 (shares the coordinator).
- **Phase 6 (US3)**: after Phase 4.
- **Phase 7 (US4)**: after Phase 4.
- **Phase 8 (US5)**: after Phases 6 and 7 (stop drain needs the gap and pause machinery; the finalizer needs the pause-aware stretch handling).
- **Phase 9 (US6)**: after Phase 8 (Retry uses the finalizer).
- **Phase 10 (US7)**: after Phase 8 (final rows to page).
- **Phase 11 (US8)**: after Phase 8.
- **Phase 12 (US9)**: after Phase 9.
- **Phase 13 (US10)**: after Phase 9 (reconciler resumes finalization; deletion cancels a pass).
- **Phase 14**: T083–T086 after Phase 13; T087–T094 after T086 and need the reference machine; T095–T098 last.

### User story dependencies

- **US1 (P1)**: foundation only. MVP.
- **US2 (P1)**: US1.
- **US3 (P1)**: US1.
- **US4 (P1)**: US1.
- **US5 (P1)**: US3 and US4.
- **US6 (P1)**: US5.
- **US7 (P2)**: US5.
- **US8 (P2)**: US5.
- **US9 (P2)**: US6.
- **US10 (P2)**: US6.

### Parallel opportunities

- Phase 3: `[P]` groups T008/T009/T010, T015/T016, T017/T018, T019/T020, T021/T022, T023/T024, T025/T026, T027, T028/T029, T034; T011–T014 and T030–T033 are sequential within their group.
- Phase 4: T035, T036 and T037 in parallel, then T038–T042.
- After Phase 4: Phases 5, 6 and 7 can proceed in parallel when staffed; they all touch `MeetingTranscriptionCoordinator.swift` and its tests, so merge sequentially.
- After Phase 9: Phases 10, 11, 12 and 13 can proceed in parallel; Phases 12 and 13 both touch `MeetingFinalizer.swift`/`MeetingTranscriptionCoordinator.swift`, so merge sequentially.
- Phase 14: T083–T085 in parallel; T096 and T097 in parallel; T087–T094 need the reference machine and run sequentially.

## Parallel example: Phase 3 foundation

```text
# After the throughput decision (T006), launch the independent contract tests together:
Task: T008 lifecycle tests in apps/macos/LocalFlowTests/TranscriptLifecycleTests.swift
Task: T015 planner tests in apps/macos/LocalFlowTests/LiveChunkPlannerTests.swift
Task: T017 queue tests in apps/macos/LocalFlowTests/AnalysisQueueTests.swift
Task: T019 mixer tests in apps/macos/LocalFlowTests/AnalysisStreamMixerTests.swift
Task: T021 assembler wrapper tests in apps/macos/LocalFlowTests/MeetingWindowAssemblerTests.swift
Task: T023 segmenter tests in apps/macos/LocalFlowTests/TranscriptSegmenterTests.swift
Task: T025 wall-clock tests in apps/macos/LocalFlowTests/WallClockDerivationTests.swift

# Then: T009/T010 → T011 → T012 → T013 → T014; T016; T018; T020; T022; T024; T026; T027 → T028/T029 → T030 → T031 → T032 → T033; T034
```

## Implementation strategy

### MVP first (User Story 1)

1. Phases 1–3 (setup, throughput evidence, lifecycle, storage, pure pipeline, tap, hooks, fakes, metrics).
2. Phase 4: live session, coordinator, active-meeting Transcript section.
3. Stop and validate: a real meeting on the development machine shows provisional text while both `.part` files grow; Feature 001–004 suites pass; `make check` passes.

### Incremental delivery

1. US2, US3, US4 → disabled mode, bounded backpressure, timestamps across pauses.
2. US5, US6 → automatic restart-safe finalization, failure separation and Retry (the remaining P1 safety stories).
3. US7, US8 → paged transcript view, notes independence.
4. US9, US10 → Transcribe, reconciliation and deletion.
5. Phase 14 → vocabulary stability, privacy, track integrity, reference-machine evidence, traceability, docs.

### LocalFlow required task coverage

Lifecycle and cancellation: T008, T036, T053, T056, T057, T062, T078, T081. Bounded overload: T011 (capacity order), T015, T017, T019, T035 (provisional buffer), T048, T049, T056 (work list), T066. Offline and recovery: T062, T063, T074 (no network on Retry/Transcribe), T077, T081, T091. Local instrumentation: T034, T084, T093. Repeatable resource acceptance: T052 and T061 (development datapoints), T087–T090 (60-minute gate, slow run), T095 (three-run determinism). Throughput, latency, memory, slow-run, force-quit, accuracy-parity and privacy acceptance (T005, T087–T094) are recorded only from real runs on the reference machine, never from fakes or scaffolding builds.
