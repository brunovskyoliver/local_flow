# Tasks: meeting capture foundation

**Input**: Design documents in `specs/004-meeting-capture-foundation/`.
**Prerequisites**: `plan.md`, `spec.md`, `research.md`, `data-model.md`, `quickstart.md` and the three files in `contracts/`.
**Tests**: Required by the specification (FR-028 lists the deterministic scenarios; SC-002, SC-003, SC-006, SC-007, SC-009, SC-011, SC-012) and by constitution principle 12. Write the deterministic tests before the code they exercise, confirm they fail for the intended reason, then make them pass. Hardware runs (force quit, reboot, storage failure on a disk image, denied permissions, the 60-minute memory run) are separate acceptance tasks and are never marked done from fakes.
**Organization**: Setup, the codec spike, foundational lifecycle/storage/pipeline/source work, one phase per user story in priority order (P1 stories first, then P2), then instrumentation, acceptance and polish. All paths are relative to the repository root. New Swift files stay in the existing `LocalFlow` and `LocalFlowTests` targets and are registered in `apps/macos/LocalFlow.xcodeproj/project.pbxproj`.

`[P]` marks tasks that touch different files and can run alongside the other `[P]` tasks in the same phase. It never bypasses a phase gate. All tasks start unchecked; planning establishes no implementation or acceptance completion.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Story]**: Which user story this task belongs to (US1 to US13)
- Every task names the file(s) it changes

## Phase 1: Setup

**Purpose**: Record the starting point, register the files the plan introduces and confirm the platform pieces the design depends on exist on macOS 14.

- [X] T001 Record the implementation starting commit, dirty-tree state, Xcode/macOS/GRDB pins, the reference machine and the constitution scope check (no model, no server, no network, only microphone and screen-recording permissions) in `specs/004-meeting-capture-foundation/acceptance/baseline.md`; state that no memory, latency, duration-accuracy or recovery figure exists yet.
- [X] T002 [P] Register the new source and test files from the plan's project structure (`Core/Audio/MeetingSampleRing.swift`, `Core/MeetingBoundaries.swift`, `Core/Meetings/*.swift`, `Core/Storage/MeetingStore.swift`, `Features/Meetings/*.swift`, `LocalFlowTests/Support/MeetingFakes.swift`, `LocalFlowTests/Meeting*Tests.swift`, `LocalFlowTests/ADTSValidatorTests.swift`) as empty placeholders in `apps/macos/LocalFlow.xcodeproj/project.pbxproj` so `plutil -lint` and the Xcode build stay green while later phases fill them in.
- [X] T003 [P] Add `LOCALFLOW_MEETING_ROOT` (storage-root override for acceptance runs) and `--debug-slow-finalize` (10 s sleep between track finalizations, debug builds only) next to the existing `LOCALFLOW_RESOURCE_RECORDING` read in `apps/macos/LocalFlow/App/AppServices.swift` (a small `MeetingRuntimeOptions` struct parsed from `ProcessInfo`), with a test in `apps/macos/LocalFlowTests/AppConfigurationTests.swift` that both default off and that the root override is ignored when it is not an absolute path.
- [X] T004 [P] Add an optional platform probe in `apps/macos/LocalFlowUITests/PlatformProbeTests.swift` that checks `SCShareableContent`, `SCStreamConfiguration.capturesAudio`, `excludesCurrentProcessAudio` and `CGPreflightScreenCaptureAccess` are available on the build SDK, skipped (not failed) when screen-recording access is not granted.

## Phase 2: Codec recoverability spike (delivery step 1)

**Purpose**: FR-005 requires a measured comparison before the storage layer is built. The ADTS AAC-LC decision in `plan.md` is provisional until this phase records the evidence.

- [X] T005 Build a throwaway harness (a `swift` script or an `LocalFlowUITests` skipped-by-default test under `specs/004-meeting-capture-foundation/acceptance/spike/`) that records 60 s of microphone audio three ways in parallel — ADTS AAC-LC through `AVAudioConverter` with hand-built 7-byte headers, fragmented MP4 through `AVAssetWriter` with `movieFragmentInterval`, plain M4A through `AVAudioFile` — syncing every 5 s, and prints bytes on disk and RSS every second.
- [X] T006 Run the harness with `kill -9` at 5, 20 and 55 s, three runs per writer, and record per run: playable through `AVAudioFile` (yes/no), recoverable seconds, bytes lost, bytes on disk, RSS while writing, hardware, macOS, build and settings in `specs/004-meeting-capture-foundation/acceptance/codec-recoverability.md`. Expected per `quickstart.md`: ADTS playable in every run with under one frame lost; M4A unplayable; fMP4 playable with at most one fragment lost.
- [X] T007 Confirm ADTS AAC-LC or switch to fMP4 based on T006, and record the choice with the evidence pointer in `docs/adr/0015-adts-aac-segments.md` (title adjusted if the choice changes), stating how ADR 0008's crash-recoverable fragment requirement is met and that the database manifest, not the file, is the authority. If the choice changes, update `data-model.md` (`codec`/`container` check values), `contracts/meeting-capture.md` and the file extensions in `contracts/meeting-storage.md` before Phase 3 starts.
- [X] T008 Confirm in the same spike that `AVQueuePlayer` plays two consecutive ADTS files as one queue with correct durations and that `CGRequestScreenCaptureAccess()` prompts once from an explicit action on macOS 14; note both outcomes and any required `Info.plist` usage-description key in `acceptance/codec-recoverability.md` and add the key to `apps/macos/LocalFlow/Info.plist` only if the spike shows it is required.

**Checkpoint**: Codec decision recorded with evidence; ADR 0015 written; no production code changed.

## Phase 3: Foundational lifecycle, storage, pipeline and sources

**Purpose**: Every user story depends on the state machine, the migration and store, the bounded per-track pipeline and the two sources with their fakes. Complete this phase before any story phase. No user-visible behaviour changes yet; with no meeting started, the app is the Feature 003 app.

### Lifecycle and models (delivery step 2)

- [X] T009 [P] Write failing tests in `apps/macos/LocalFlowTests/MeetingLifecycleTests.swift`: every allowed pair in the `data-model.md` transition table is accepted; every other pair of the eight states (a full 8×8 sweep) throws `MeetingLifecycle.Error.invalidTransition(from:to:)`; `completed`, `interrupted` and `failed` are terminal; `isActive` is true for `created`, `preparing`, `recording`, `paused`, `finalizing` only; `MeetingFailureReason` has exactly the twelve cases from the reason set and each maps to a non-empty `MeetingErrorMessage` text that contains no `%@`, path or title placeholder.
- [X] T010 [P] Implement `apps/macos/LocalFlow/Core/Meetings/MeetingLifecycle.swift` (`MeetingState`, `MeetingLifecycle.transition(from:to:)` as a pure table lookup, `isActive`, `isTerminal`, `MeetingFailureReason`, `MeetingErrorMessage` with the exact texts from `contracts/meeting-storage.md`) and `apps/macos/LocalFlow/Core/Meetings/MeetingModels.swift` (`Meeting`, `MeetingTrack`, `MeetingTrackKind`, `TrackHealth`, `MeetingSegment`, `SegmentState`, `PauseInterval`, `PauseReason`, `MeetingNotes`, `RecoveryOutcome`, `MeetingSummary`, `MeetingDetail`, `MeetingStatus`, `TrackStatus`, `fallbackTitle(createdAt:)` producing "Meeting " + local short date and time); make T009 pass.
- [X] T011 [P] Declare the boundary protocols in `apps/macos/LocalFlow/Core/MeetingBoundaries.swift`: `MeetingAudioSourcing`, `MeetingSourceFormat`, `MeetingSourceFailure` (seven cases with the mapping to `MeetingFailureReason`), `SegmentWriting`, `SegmentHandle`, `ADTSFrame`, `MeetingCaptureFailure`, `MeetingClock` (now, monotonic ns, sleep/timer hooks compatible with the existing test clock) and `MeetingStoring` (the `MeetingStore` method list from `contracts/meeting-storage.md`), all `Sendable`.

### Migration and store (delivery step 2)

- [X] T012 [P] Write failing tests in `apps/macos/LocalFlowTests/MeetingStoreTests.swift` against a temp-dir `DatabaseQueue`: migration `meetings-v5` creates the six tables with the columns, check constraints, cascades and indexes in `data-model.md` and alters no Feature 001–003 table; `create(now:)` inserts `created` plus an empty notes row with `author = 'user'` and throws `alreadyActive` without inserting when an active row exists (two concurrent creates yield one row); `transition` applies the lifecycle check and its listed side effects in one write and a rejected transition writes nothing; `openSegment` refuses a second open segment per track (`segmentAlreadyOpen`) and rejects a `relative_path` containing `..` or starting with `/`; `progressSegment` updates duration, bytes and dropped frames; `finalizeSegment` rewrites the path from `.part` to `.aac`, updates totals and sets `duration_warning` per the max(1%, 2 s) rule at stop; `openPause` refuses a second open pause (`pauseAlreadyOpen`) and `closePause` records `closed_by`; `saveNotes` enforces 1,048,576 bytes (`notesTooLarge`), bumps and returns the revision and throws `staleRevision` on conflict; `setTitle` enforces 256 bytes; `page(before:limit:)` returns newest first by `(created_at, id)` with limit clamped to 20 and stable across a boundary of equal `created_at`; `detail(id:)` round-trips every column of every table; `activeStateRows()` lists exactly the active states; `recordOutcome` stores a row visible in `detail`; a pre-004 database opens and lists zero meetings; a failed write inside `transition` leaves the row unchanged (FR-010 partial-mutation rule) using a store double that throws mid-transaction.
- [X] T013 Add migration `meetings-v5` to `apps/macos/LocalFlow/Core/Storage/HistoryMigrations.swift` exactly as specified in `data-model.md` (tables `meetings`, `meeting_tracks`, `meeting_segments`, `meeting_pauses`, `meeting_notes`, `meeting_recovery_outcomes`; the `meetings_created_at_id` and partial `meetings_active` indexes; the partial unique index on open pauses; `ON DELETE CASCADE` on every child; all check constraints including the closed `codec`/`container`/`author` value sets).
- [X] T014 Implement the `MeetingStore` actor in `apps/macos/LocalFlow/Core/Storage/MeetingStore.swift` sharing the existing `DatabaseQueue`, with every method in `contracts/meeting-storage.md`, the `MeetingStore.Error` set, `updated_at` bumped on every write, `recorded_ms`/`wall_clock_ms` recomputed on each persisted change, relative-path validation, the notes and title byte limits, and content-free logging; make T012 pass. `deleteConfirmed` is implemented in Phase 15 (US13); leave it throwing `unimplemented` here.

### Bounded ring and encoder (delivery step 3)

- [X] T015 [P] Write failing tests in `apps/macos/LocalFlowTests/MeetingSampleRingTests.swift`: a ring created at 32 slots × 4,096 frames × 8 channels preallocates once (allocation count or `capacity` assertion); with drop-on-overflow enabled a push beyond capacity is dropped whole, `droppedFrames` grows by the pushed frame count and later pushes are still admitted; `highWater` reports the maximum occupancy; `pop` returns at most 32 slots per call; the existing `AudioCaptureTests` still pass because the default policy (latching `overflow`) is unchanged.
- [X] T016 Add `LFAudioRingSetDropOnOverflow(ring, bool)` and `LFAudioRingDroppedFrames(ring)` to `apps/macos/LocalFlow/Core/Audio/AudioCaptureRing.h` and `apps/macos/LocalFlow/Core/Audio/AudioCaptureRing.c` (drop path increments an atomic frame counter and returns without touching the latch; default behaviour unchanged for `AudioCaptureService`), then implement the `MeetingSampleRing` wrapper in `apps/macos/LocalFlow/Core/Audio/MeetingSampleRing.swift` with `push`, `pop(maxSlots:)`, `capacity`, `highWater` and `droppedFrames`; make T015 pass.
- [X] T017 [P] Write failing tests in `apps/macos/LocalFlowTests/MeetingTrackEncoderTests.swift`: encoding 4,096-frame Float32 blocks of a 1 kHz tone at 44.1 kHz stereo into a microphone track yields mono 48 kHz AAC-LC ADTS frames whose 7-byte headers carry the sync word, MPEG-4 flag, AAC-LC profile, sampling index 3, the channel configuration and `frame length = 7 + payload`; `encode` returns at most 8 frames per call; `finish()` drains trailing frames and a second call throws; a concatenation of frames written to a temp file reads back through `AVAudioFile` with a duration within one frame of `frames × 1,024 / 48,000`; a system-track encoder keeps 2 channels for a stereo source and downmixes 6 to 2; a converter error surfaces as `MeetingCaptureFailure.encoder(code)`.
- [X] T018 Implement `apps/macos/LocalFlow/Core/Meetings/MeetingTrackEncoder.swift` (one `AVAudioConverter` per instance, input block of 4,096 frames, output block of at most 8 packets of 1,536 bytes, ADTS header composition, `encode(block:)`, `finish()`, `encodedFrameCount` as the duration source of truth, bitrate 64,000 for microphone and 96,000 for system); make T017 pass.

### Validator and segment writer (delivery step 3)

- [X] T019 [P] Write failing tests in `apps/macos/LocalFlowTests/ADTSValidatorTests.swift` using synthetic fixtures from `MeetingFakes`: a file of N complete frames returns `completeFrames = N`, `completeBytes` equal to the file size and `trailingBytes = 0`; a file cut mid-frame reports the last complete boundary and the trailing byte count; a file with a corrupt header in the middle stops at that frame; a 3-byte file reports zero complete frames; scanning reads in 64 KiB windows (assert through a counting `FileHandle` double or by file-size independence of peak allocation); sample rate and channel count are read from the first header.
- [X] T020 [P] Implement `apps/macos/LocalFlow/Core/Meetings/ADTSValidator.swift` with `scan(url:) -> ScanResult` per `contracts/meeting-capture.md`; make T019 pass.
- [X] T021 [P] Write failing tests in `apps/macos/LocalFlowTests/FileSegmentWriterTests.swift` on a temp directory: `open` creates `<root>/<meeting>/<type>-<seq>.aac.part` with `O_CREAT|O_EXCL` and mode 0600 inside a 0700 meeting directory and throws when the file already exists; a symlinked meeting directory or root is refused (mirroring `AudioSpool`'s private-path checks); `append` writes every byte of a partial-write sequence or throws with `errno` only; `sync` fsyncs; `finalize` fsyncs, closes, renames to `.aac`, fsyncs the directory and returns the byte size; `abandon` closes without renaming; `freeSpace(at:)` returns a positive number for the temp volume; no error carries a path or title.
- [X] T022 [P] Implement `apps/macos/LocalFlow/Core/Meetings/FileSegmentWriter.swift` owning file descriptors per `SegmentWriting`; make T021 pass.
- [X] T023 [P] Add `apps/macos/LocalFlowTests/Support/MeetingFakes.swift`: `FakeMeetingAudioSource` (pushes synthetic frames into the ring on the test clock's schedule, `fail(with:)` on command, records start/stop calls, can refuse to start), `FakeSegmentWriter` (in-memory or temp-dir backed with `failAfterBytes`, `failOnSync`, `failOnFinalize`, `failOnOpen`, `freeSpace` knobs and a byte log per handle), `FakeMeetingClock` built on the existing test clock, `FakeResourceRecorder` capture, and synthetic ADTS fixture builders (`completeFrames(n:)`, `truncatedMidFrame`, `corruptHeaderAt(index:)`).

### Track worker (delivery step 3)

- [X] T024 Write failing tests in `apps/macos/LocalFlowTests/MeetingTrackWorkerTests.swift` with `FakeMeetingAudioSource`, `FakeSegmentWriter`, a real `MeetingSampleRing` and the test clock: the worker pops at most 32 slots per 10 ms tick, encodes one 4,096-frame block at a time and never allocates a buffer larger than the declared input/output blocks (assert on block sizes handed to the encoder and writer); bytes written accumulate; every 5 s of test-clock time `sync` is called and a `progressSegment` heartbeat with duration, bytes and dropped frames is issued exactly once; on `failAfterBytes` the worker latches `storageFailure(.storageWriteFailed)`, stops popping and the ring's `droppedFrames` keeps growing while its occupancy stays at capacity; `failOnSync` and `failOnFinalize` latch the matching reason; an encoder error latches `encoderFailed`; `finalize` stops the timer, drains the ring once, calls `finish()`, appends trailing frames, calls the writer's `finalize` and reports `(durationMs, byteSize)` where `durationMs = encodedFrames × 1,024 / 48,000`; finalize after a write failure returns the failure instead of renaming; `meetingBytesWritten`, queue high water and dropped frames reach the recorder per track kind.
- [X] T025 Implement `apps/macos/LocalFlow/Core/Meetings/MeetingTrackWorker.swift` (serial `DispatchQueue`, 10 ms timer, the four-step loop from `contracts/meeting-capture.md`, 5 s sync and heartbeat, `storageFailure` latch readable without blocking, `finalize()` returning the result or the latched failure); make T024 pass.

### Sources and permissions (delivery step 4)

- [X] T026 [P] Implement `apps/macos/LocalFlow/Core/Meetings/MicrophoneMeetingSource.swift`: `AVAudioEngine` input tap into the `MeetingSampleRing` following the `AudioCaptureService` tap pattern without modifying it, `AVAudioEngineConfigurationChange` observer with one restart attempt then `deviceLost`, `permissionRevoked` when `AVCaptureDevice.authorizationStatus` leaves `authorized`, `unsupportedFormat` when the input format cannot be represented, idempotent `stop()` that joins the tap.
- [X] T027 [P] Implement `apps/macos/LocalFlow/Core/Meetings/SystemAudioMeetingSource.swift`: `SCStream` over the display's shareable content with `capturesAudio = true`, `excludesCurrentProcessAudio = true`, 48 kHz, 2 channels, a `.audio` output only (no video frames requested), `CMSampleBuffer` → Float32 push into the ring, `SCStreamDelegate.stream(_:didStopWithError:)` mapped to `streamStopped` or `permissionRevoked`, idempotent `stop()`.
- [X] T028 [P] Write failing tests in `apps/macos/LocalFlowTests/MeetingPermissionsTests.swift` with fake status providers: microphone `authorized` → proceed; `notDetermined` → request once then re-check; `denied`/`restricted` → refusal carrying the existing microphone guidance text; screen recording preflight false → request once, re-check, still false → refusal with the exact screen-recording text from `contracts/meeting-storage.md`; the request closures are called at most once per start and never when the status is already granted; no other permission API is invoked (the fake records every call).
- [X] T029 [P] Implement `apps/macos/LocalFlow/Core/Meetings/MeetingPermissions.swift` (`check(microphone:screenRecording:) async -> PermissionOutcome` using `AVCaptureDevice.authorizationStatus`/`requestAccess` and `CGPreflightScreenCaptureAccess`/`CGRequestScreenCaptureAccess` behind injectable closures); make T028 pass.
- [X] T030 [P] Add the meeting `Metric` cases (`meetingStartDuration`, `meetingCaptureInitDuration`, `meetingTransition` keyed by target state, `meetingMicQueueDepth`, `meetingSystemQueueDepth`, `meetingDroppedFrames`, `meetingBytesWritten` per track kind, `meetingWriteFailure`, `meetingEncoderFailure`, `meetingPauseCount`, `meetingResumeCount`, `meetingFinalizationDuration`, `meetingSegmentBytes`, `meetingRecoveryOutcome` keyed by outcome kind) and the RSS phases `meetingRecording`, `meetingPaused`, `meetingFinalizing` to `apps/macos/LocalFlow/Core/Observability/ResourceRecorder.swift`, keeping the existing item and payload limits, and extend `apps/macos/LocalFlowTests/ResourceRecorderTests.swift` so the content-free assertion covers every new metric (no string dimension other than track kind, state name, outcome kind or numeric code).

**Checkpoint**: Lifecycle, migration, store, ring, encoder, validator, writer, worker, sources, permissions, metrics and fakes exist with tests. `make check` passes; no production flow has changed; the Feature 001–003 suites are untouched.

## Phase 4: User Story 1 - Start and stop a meeting (P1) 🎯 MVP

**Goal**: One `MeetingCoordinator` owns at most one meeting, runs the start sequence in contract order with the row persisted before capture, publishes `MeetingStatus`, and stops through `finalizing` to `completed` with durations and per-track totals persisted.
**Independent test**: With fakes, start, advance the test clock a few minutes, stop; one `completed` row with two finalized tracks and the expected recorded duration. Spec US1 scenarios 1–4.

### Tests

- [X] T031 [US1] Write failing tests in `apps/macos/LocalFlowTests/MeetingCoordinatorTests.swift` with `FakeMeetingAudioSource`, `FakeSegmentWriter`, the fake permissions, a temp-dir `MeetingStore` and the test clock: the start sequence runs in the contract order (dictation-busy check, reconciliation gate, microphone permission, screen-recording permission, storage preflight, `created` insert, `preparing` with two track rows, two segment files opened, sources started, `recording` persisted then published); the `meetings` row exists before either source's `start` is called; a second `start()` while active returns `.alreadyActive(id)` and inserts nothing; a preflight or permission refusal before the insert persists nothing; a segment open failure after the insert moves the row to `failed` with `segment_open_failed`, removes the file it created and leaves no orphan; `MeetingStatus` shows `recording`, both tracks `capturing`, and `recordedElapsed` advancing at 1 Hz only in `recording`; `stop()` persists `finalizing` with `stopped_at`, finalizes microphone then system with `finalization_stage` written after each, writes totals, `recorded_ms`, `wall_clock_ms`, `duration_warning` and `completed` in one transaction, records `meetingFinalizationDuration`, and releases both sources and workers (fakes report `stop` called and no strong reference remains); a zero-length meeting (start then immediate stop) completes with two finalized near-empty segments; a `.debugSlowFinalize` hook delays between the two tracks only in debug builds; `meetingStartDuration` and `meetingCaptureInitDuration` are recorded; the published state never changes before the store write returns (store double with a gate).

### Implementation

- [X] T032 [US1] Implement `apps/macos/LocalFlow/Features/Meetings/MeetingCoordinator.swift` (`@MainActor @Observable`): `start()`, `stop()`, the `MeetingStatus` value, the 1 Hz elapsed timer, write-then-publish for every transition through `MeetingStore.transition`, ownership of two sources and two workers per stretch and their release on stop, start/finalization metrics; make the T031 start/stop assertions pass. Pause, resume, sleep and failure paths are added in their story phases.
- [X] T033 [US1] Wire `MeetingCoordinator` in `apps/macos/LocalFlow/App/AppServices.swift` with the production `MicrophoneMeetingSource`, `SystemAudioMeetingSource`, `FileSegmentWriter`, `MeetingPermissions`, `MeetingStore` and `ResourceRecorder`, resolving the storage root from the application data directory or `LOCALFLOW_MEETING_ROOT`; Start Meeting is disabled until Phase 12's reconciler reports completion (a completed-by-default gate until then).
- [X] T034 [US1] Add `LocalFlowPage.meetings` ("Meetings", symbol `waveform.badge.mic`, placed before Transcriptions) to `apps/macos/LocalFlow/App/MainWindowRouter.swift` and extend `apps/macos/LocalFlowTests/MainWindowRouterTests.swift` for the new page and its order.
- [X] T035 [US1] Implement `apps/macos/LocalFlow/Features/Meetings/ActiveMeetingView.swift` (state label, elapsed recorded time, microphone and system indicators fed by `TrackStatus`, Stop control, Pause/Resume placeholders enabled in Phase 7, a warning banner slot and the notice line) and show it at the top of a minimal `MeetingLibraryView` in `apps/macos/LocalFlow/Features/Meetings/MeetingLibraryView.swift` (full library in Phase 10), routed from `apps/macos/LocalFlow/App/LocalFlowApp.swift`.
- [X] T036 [US1] Add "Start Meeting" and "Stop Meeting" items to the menu bar extra in `apps/macos/LocalFlow/App/LocalFlowApp.swift`, show the recording glyph in its label while `recording`, make Start from the menu bar show the active meeting instead of creating a second one, and confirm closing the main window leaves the coordinator untouched (no `onDisappear` side effects); extend `apps/macos/LocalFlowTests/NativePresentationTests.swift` for the glyph and label states.

**Checkpoint**: Start and stop work end to end against fakes and against the real sources on the development machine (a completed meeting with two `.aac` files appears under `Meetings/<uuid>/`). Spec US1 scenarios 1–4 hold; SC-001 timing is measured live in Phase 16, not here.

## Phase 5: User Story 2 - Microphone and system audio as separate tracks (P1)

**Goal**: Two independent tracks from platform capture only, each persisted with the full FR-015 metadata.
**Independent test**: Record while playing known audio and speaking; two files exist, each containing only its source; the detail lists every track and segment field. Spec US2 scenarios 1–3.

- [X] T037 [P] [US2] Extend `apps/macos/LocalFlowTests/MeetingStoreTests.swift`: `preparing` creates exactly one `microphone` and one `system` track with `codec = 'aac_lc'`, `container = 'adts'`, `sample_rate = 48000`, the channel counts 1 and 2 and the bitrates 64,000 and 96,000; the unique `(meeting_id, type)` constraint rejects a third track; `detail(id:)` returns per-track type, codec, container, sample rate, channels, bitrate, total duration, total bytes, health, failure reason and time, dropped frames and duration warning, and per-segment sequence, relative path, start offset, duration, bytes, state, open/close reasons and recovery note.
- [X] T038 [P] [US2] Extend `apps/macos/LocalFlowTests/MeetingCoordinatorTests.swift`: frames pushed by the microphone fake land only in the microphone segment's byte log and frames pushed by the system fake only in the system segment's (distinct synthetic payloads); the coordinator never mixes or cross-feeds rings; a source that reports `unsupportedFormat` at start is treated as a failed start for that track only.
- [X] T039 [US2] Complete the per-track wiring in `apps/macos/LocalFlow/Features/Meetings/MeetingCoordinator.swift` (one ring, encoder, worker and source per track; per-track channel policy) and the track-card rendering of every FR-015 field in a first version of `apps/macos/LocalFlow/Features/Meetings/MeetingDetailView.swift`; make T037 and T038 pass.
- [ ] T040 [US2] Run the live two-source check from `quickstart.md` "Start, record, stop" steps 1–3 on the development machine with no virtual audio device installed, and record in `specs/004-meeting-capture-foundation/acceptance/baseline.md` that the microphone file contains only speech, the system file only the played audio, and that no driver was needed; mark unmeasured until run.

**Checkpoint**: Two unmixed tracks with complete metadata; the system track works without a virtual device.

## Phase 6: User Story 3 - Audio streams to disk with bounded memory (P1)

**Goal**: The bounded pipeline is proven by assertions on every capacity and by the deterministic no-growth checks; the measured 60-minute run lives in Phase 16.
**Independent test**: Worker and coordinator tests show fixed block sizes, ring drops at capacity and steady file growth; no audio bytes in SQLite. Spec US3 scenarios 1–3.

- [X] T041 [P] [US3] Add a bounded-memory test group to `apps/macos/LocalFlowTests/MeetingTrackWorkerTests.swift`: with the fake source pushing at 10× real time for a simulated 30 minutes of test-clock time, the worker's resident structures (ring capacity, one input block, one output block, one frames array of ≤ 8) never change size, `highWater` stays ≤ 32, the writer's byte log grows monotonically at every heartbeat and no `Data` accumulator exists between heartbeats (assert through the writer's per-append sizes, each ≤ 8 × 1,543 bytes).
- [X] T042 [P] [US3] Add a store test to `apps/macos/LocalFlowTests/MeetingStoreTests.swift` that the schema has no BLOB column and that `detail` after a simulated meeting returns only paths for media; and add a coordinator test in `apps/macos/LocalFlowTests/MeetingCoordinatorTests.swift` that after one simulated minute each open segment's `byte_size` heartbeat has increased at least once and the recorder received `meetingMicQueueDepth`, `meetingSystemQueueDepth` and `meetingDroppedFrames` samples.
- [X] T043 [US3] Adjust `MeetingTrackWorker.swift`, `MeetingSampleRing.swift` and `MeetingCoordinator.swift` as needed so T041 and T042 pass without introducing any queue, array or `Data` that grows with duration; document every bound in a doc comment at the top of `apps/macos/LocalFlow/Core/Meetings/MeetingTrackWorker.swift` matching `contracts/meeting-capture.md`.
- [ ] T044 [US3] Run the 10–15 minute development memory run from `quickstart.md` "Long-run memory acceptance" with `LOCALFLOW_RESOURCE_RECORDING=1`, both sources, notes typed (after Phase 8) and one pause/resume (after Phase 7), sampling RSS with `scripts/memory-report.sh <pid>` every 10 s, and record the series, slope and peak as a development datapoint in `specs/004-meeting-capture-foundation/acceptance/long-run-memory.md`, labelled "development run, not acceptance". Run this after Phases 7 and 8; list it here because it belongs to US3.

**Checkpoint**: Every capacity is asserted; growth-free operation is shown deterministically; the development run is recorded as a datapoint only.

## Phase 7: User Story 4 - Pause and resume (P2, but a prerequisite for sleep handling in US9 and the acceptance runs)

**Goal**: Pause finalizes the open segments and opens a pause row; resume opens sequence n+1 and closes the pause; recorded duration excludes pauses; system sleep pauses with its own reason and never resumes on its own.
**Independent test**: Start, pause, advance the clock, resume, stop; one meeting, two segments per track, one pause row, `recorded_ms = wall_clock_ms − pause_ms`. Spec US4 scenarios 1–4 and the sleep edge case.

- [X] T045 [US4] Extend `apps/macos/LocalFlowTests/MeetingCoordinatorTests.swift`: `pause(reason: .user)` in `recording` stops both sources, finalizes both open segments with `close_reason = 'pause'`, inserts an open pause row and `paused` in one transaction, then publishes; `pause` in any other state is rejected without writes; elapsed stops advancing while paused and no bytes reach the writer; `resume()` opens `mic-0002`/`system-0002` with `open_reason = 'resume'` and `start_offset_ms` equal to the recorded time so far, restarts the sources, closes the pause with `closed_by = 'resume'` and persists `recording` before publishing; `resume` in `recording` is rejected; `stop()` from `paused` closes the pause with `closed_by = 'stop'` and completes normally; after start → pause 30 s → resume → stop, `recorded_ms = wall_clock_ms − 30,000 ± 1,000` and the pause is listed with both timestamps; `pause(reason: .systemSleep)` behaves like a user pause with `reason = 'system_sleep'`, is idempotent when already paused, sets the notice "Paused because the Mac went to sleep", and a simulated wake changes nothing (no source `start` call, still `paused`); a source that fails to restart on resume follows the source-failure rule and when none restarts the meeting ends `interrupted`; `meetingPauseCount`/`meetingResumeCount` are recorded.
- [X] T046 [US4] Implement `pause(reason:)`, `resume()`, the `NSWorkspace.willSleepNotification` observer (injectable notification center for tests) and the paused-state notice in `apps/macos/LocalFlow/Features/Meetings/MeetingCoordinator.swift`, enable the Pause/Resume controls and the pause-reason label in `apps/macos/LocalFlow/Features/Meetings/ActiveMeetingView.swift`, and add "Pause"/"Resume" menu bar items with the pause glyph in `apps/macos/LocalFlow/App/LocalFlowApp.swift`; make T045 pass.

**Checkpoint**: Pause and resume produce explicit segments and pause rows; sleep pauses with reason and stays paused. SC-005 arithmetic holds under the test clock.

## Phase 8: User Story 5 - Manual notes during and after a meeting (P2)

**Goal**: A notes editor for the active meeting and for library meetings that saves 2 s after the last edit, at most 10 s into continuous editing, on stop, window close and quit, and never claims a save that did not return.
**Independent test**: Type, stop typing, saved within 2 s; type continuously 30 s, at least three saves; simulate a failed save, "Not saved" stays until a later save succeeds. Spec US5 scenarios 1–4.

- [X] T047 [P] [US5] Write failing tests in `apps/macos/LocalFlowTests/MeetingNotesEditorTests.swift` with the test clock and a store double: an edit followed by 2 s of idle produces exactly one `saveNotes` call with the full text; edits every 500 ms for 30 s produce a save at 10 s, 20 s and 30 s (forced) plus one 2 s after the last edit; only one save is in flight and later edits during a save coalesce into the next; `flush()` (stop, window close, quit) saves immediately when dirty; a `staleRevision` response re-reads and retries once, then wins with the local text; a thrown save leaves `isDirty` true, shows "Notes not saved" and retries on the next edit or 10 s timer; text over 1 MiB is refused in the editor with a notice and not sent; the editor works with no network object at all (no `URLSession` symbol referenced); log capture contains no note text.
- [X] T048 [P] [US5] Implement `apps/macos/LocalFlow/Features/Meetings/MeetingNotesEditor.swift` (`@MainActor @Observable`: `text`, `isDirty`, `saveState`, debounce and forced-save timers on `MeetingClock`, single in-flight save, `flush()`, revision tracking); make T047 pass.
- [X] T049 [US5] Bind a `TextEditor` to `MeetingNotesEditor` inside `apps/macos/LocalFlow/Features/Meetings/ActiveMeetingView.swift` and `apps/macos/LocalFlow/Features/Meetings/MeetingDetailView.swift` with the Saved / Saving / Not saved indicator, call `flush()` from `MeetingCoordinator.stop()`, from the window's close handler in `apps/macos/LocalFlow/App/LocalFlowApp.swift` and from the app termination hook in `apps/macos/LocalFlow/App/AppServices.swift`; add a coordinator test that `stop()` flushes before `finalizing` is published.

**Checkpoint**: Notes autosave within the bounds offline; a failed save is visible. SC-007's live force-quit check is in Phase 16.

## Phase 9: User Story 6 - Durable meeting metadata (P2)

**Goal**: Every FR-014 and FR-015 field round-trips; paths are relative and survive a root move; the fallback title is derived, never stored.
**Independent test**: Record with a pause and a title, reopen the store, every field is present; move the root, paths still resolve. Spec US6 scenarios 1–3.

- [X] T050 [P] [US6] Extend `apps/macos/LocalFlowTests/MeetingStoreTests.swift`: after a coordinator-driven start → pause → resume → stop with `setTitle`, a fresh `MeetingStore` on the same database returns every FR-014 field (identity, created/started/stopped/completed timestamps, state, recorded and wall-clock durations, pause list, title, notes, tracks, finalization stage, reason fields) and every FR-015 field; `relative_path` values never start with `/` and never contain the storage root; resolving them against a different root URL yields the moved files; a meeting with `title = nil` renders `fallbackTitle` as "Meeting " + local short date/time of `created_at`, and a stored title is never written into any file name (scan the meeting directory).
- [X] T051 [US6] Add `setTitle` to the detail view header in `apps/macos/LocalFlow/Features/Meetings/MeetingDetailView.swift` and an optional title field in `apps/macos/LocalFlow/Features/Meetings/ActiveMeetingView.swift` (revision-checked, 256-byte limit with a notice), resolve every path through a single `MeetingStorageRoot.resolve(relativePath:)` helper in `apps/macos/LocalFlow/Core/Meetings/FileSegmentWriter.swift`, and make T050 pass.
- [ ] T052 [US6] Perform the relocation check from `quickstart.md` step 4 (move `Meetings/` aside, launch, tracks show "file missing"; move back, relaunch, tracks play) on the development machine and record the outcome in `specs/004-meeting-capture-foundation/acceptance/baseline.md`.

**Checkpoint**: The durable record is complete and relocatable; the contract with Features 005–008 is in place.

## Phase 10: User Story 7 - Meeting library and detail (P2)

**Goal**: A paged, newest-first library with status badges and a detail view with metadata, notes, tracks, segments, pauses and recovery outcomes; bounded memory for the list.
**Independent test**: Seed several meetings including an interrupted one; the library lists them with correct titles, times, durations and badges; opening one shows its detail; the page cache holds at most two pages. Spec US7 scenarios 1–3.

- [X] T053 [P] [US7] Write failing tests in `apps/macos/LocalFlowTests/MeetingLibraryTests.swift`: `MeetingLibraryViewModel` loads 20 rows per page newest first by `(created_at, id)`; scrolling past the end loads the next page and evicts the oldest so at most two pages (40 rows) are resident; rows carry the title or fallback, local start date/time, recorded duration, the state badge text (Recording, Paused, Finalizing, Completed, Interrupted, Failed), a warning flag when any track is `failed` or `unrecoverable`, and "Deletion incomplete" when flagged; the active meeting is pinned at the top; no search field or query API exists on the view model; a store error surfaces as a notice, not a crash.
- [X] T054 [P] [US7] Implement `apps/macos/LocalFlow/Features/Meetings/MeetingLibraryViewModel.swift` (paging with `page(before:limit:)`, two-page window, refresh on coordinator state changes, active meeting pin); make T053 pass.
- [X] T055 [US7] Complete `apps/macos/LocalFlow/Features/Meetings/MeetingLibraryView.swift` (list rows, badges, warning glyph, navigation to detail, active view at the top) and `apps/macos/LocalFlow/Features/Meetings/MeetingDetailView.swift` (title editor, state and reason text from `MeetingErrorMessage`, timestamps, durations, pause list with reasons, per-track cards with segment lists, notes editor, recovery outcome rows, Delete button wired in Phase 15), and add a rendering test in `apps/macos/LocalFlowTests/MeetingLibraryTests.swift` that an interrupted meeting with one failed track shows the reason text and time.

**Checkpoint**: Users can find, open and inspect every recorded meeting; the library holds a bounded window.

## Phase 11: User Story 8 - Play back captured audio (P2)

**Goal**: Per-track playback across finalized segments as one timeline, unplayable segments labelled and skipped, source files untouched.
**Independent test**: Open a completed meeting, play each track start to end; checksums unchanged. Spec US8 scenarios 1–3.

- [X] T056 [P] [US8] Write failing tests in `apps/macos/LocalFlowTests/TrackPlaybackTests.swift`: `TrackPlaybackController.load(track:)` builds one queue item per `finalized` segment in `sequence` order, skips `open` and `unrecoverable` segments and lists each skipped one as "Not playable: <reason text>"; the displayed position is `start_offset_ms + currentTime`; `play`, `pause`, `stop` update `isPlaying` and reset the position on stop; files are opened read-only (assert the `AVURLAsset` options or a file-open double); SHA-256 of every segment file is identical before and after a load/play/stop cycle on synthetic ADTS fixtures; a track with zero playable segments reports "No playable audio".
- [X] T057 [P] [US8] Implement `apps/macos/LocalFlow/Features/Meetings/TrackPlaybackController.swift` (`AVQueuePlayer`, periodic time observer, per-item offset table, skip-unplayable list, release on deinit); make T056 pass.
- [X] T058 [US8] Add per-track playback controls (play/pause/stop, position, duration) to `apps/macos/LocalFlow/Features/Meetings/MeetingDetailView.swift`, stopping playback when the view disappears or the meeting is deleted; note the combined-monitoring seam (two controllers started together) as a comment and leave it unimplemented (spec MAY).

**Checkpoint**: Each track plays end to end from the detail view; unplayable segments are labelled; files are byte-identical afterwards.

## Phase 12: User Story 9 - Recover after a crash, force quit or reboot (P1)

**Goal**: `MeetingReconciler` runs at every launch without blocking it, marks active rows `interrupted` (or `failed`), closes open pauses, validates and truncates `.part` files, reconstructs orphan directories, records outcomes, deletes nothing and publishes one summary notice.
**Independent test**: Seed a database and directory in each FR-013 state, run the reconciler, assert the resulting rows, files and outcome rows. Spec US9 scenarios 1–5, the "record missing"/"stale metadata"/"file missing" edge cases and the `created`-never-`preparing` case.

- [X] T059 [US9] Write failing tests in `apps/macos/LocalFlowTests/MeetingReconcilerTests.swift` on a temp-dir store and directory with synthetic `.part` fixtures: a `recording` row with two `.part` files of N complete frames plus trailing bytes becomes `interrupted` with `not_running_at_last_state`, both files are truncated at `completeBytes` (`bytes_truncated` recorded), renamed to `.aac`, their rows `finalized` with `close_reason = 'recovered'` and updated duration/bytes, both tracks `finalized`, notes untouched; a `paused` row with an open pause closes it at `updated_at` with `closed_by = 'reconciliation'` and `recorded_ms` excludes it; a `finalizing` row with `finalization_stage = 'mic'` keeps the microphone segment finalized and recovers the system one, recording the stage found; a `.part` with zero complete frames stays `.part`, its segment `unrecoverable` with `unrecoverable_media`, the file still present, the other track and notes intact; a segment row whose file is missing is `unrecoverable` with `file_missing`; a `finalized` row whose file still ends in `.part` (stale metadata) is re-validated and corrected; a `Meetings/<uuid>/` directory with no row yields an `interrupted` meeting with `record_missing`, tracks and segments reconstructed from file names, each validated; a `created` row that never reached `preparing` becomes `failed` with `not_running_at_last_state` and no longer blocks `create`; a row already carrying a fatal reason with no media becomes `failed`; a row in a terminal state is untouched; a launch with nothing active changes no row, creates no outcome and reports a silent summary; every processed meeting gets one `meeting_recovery_outcomes` row and a `meetingRecoveryOutcome` metric; no file is ever deleted (directory listing before and after); the work list is bounded to 100 rows and 1,000 directory entries per launch with the remainder reported as `deferred`; the reconciler runs on a detached task and `run()` returns a `ReconciliationSummary(meetingsFound, recovered, unrecoverable, orphansReconstructed, deferred)`.
- [X] T060 [US9] Implement `apps/macos/LocalFlow/Core/Meetings/MeetingReconciler.swift` per `research.md` "Reconciliation at launch" using `ADTSValidator`, `ftruncate`, rename, directory fsync and `MeetingStore` (`activeStateRows`, `markSegmentUnrecoverable`, `finalizeSegment`, `closePause`, `transition`, `recordOutcome`); make T059 pass.
- [X] T061 [US9] Wire the reconciler into `apps/macos/LocalFlow/App/AppServices.swift` `start()`: launch it on a detached task before the dictation coordinator is enabled, gate `MeetingCoordinator.start()` on its completion, turn the summary into one action notice through the existing `IndicatorPanel` notice ("1 meeting recovered" style, silent when nothing was found), and add an `AppServices`-level test in `apps/macos/LocalFlowTests/MeetingReconcilerTests.swift` that launch does not await the reconciler and that dictation is available when the summary is silent.
- [X] T062 [US9] Show the meeting's recovery outcome rows and the `not_running_at_last_state` text in `apps/macos/LocalFlow/Features/Meetings/MeetingDetailView.swift` and the "Interrupted" badge in the library row (already rendered in Phase 10; verify with a test in `apps/macos/LocalFlowTests/MeetingLibraryTests.swift`).

**Checkpoint**: Every FR-013 case is handled deterministically; nothing is deleted; launch is not blocked. The real force-quit, reboot and corrupt-file runs are Phase 16.

## Phase 13: User Story 10 - Storage failure during recording (P1)

**Goal**: A latched write, sync, rename or encoder failure stops capture within 5 s, ends the meeting `interrupted` with the storage reason, keeps written audio, drops overflow at the ring and removes the healthy indication; preflight warns below 2 GB and blocks below 500 MB.
**Independent test**: `FakeSegmentWriter.failAfterBytes` mid-meeting; capture stops within 5 s of test-clock time, state `interrupted` with `storage_write_failed`, drops counted, no buffer growth, earlier bytes retained. Spec US10 scenarios 1–4.

- [X] T063 [US10] Extend `apps/macos/LocalFlowTests/MeetingCoordinatorTests.swift`: with `failAfterBytes` on the microphone writer during `recording`, the coordinator's 250 ms latch poll detects the failure, stops both sources, finalizes the system segment normally, finalizes the microphone segment by rename only when `ADTSValidator` reports complete frames (otherwise marks it `unrecoverable` with `storage_write_failed`), persists `interrupted` with `storage_write_failed`, publishes the exact `MeetingErrorMessage` notice, stops the elapsed timer and shows neither track as `capturing` — all within 5,000 ms of test-clock time from the failed call (assert the actual value and that it is under 1,000 ms); `failOnSync`, `failOnFinalize` and an encoder error produce the matching reasons; an unavailable directory at `open` on resume yields `storage_unavailable`; frames arriving after the latch increase `droppedFrames` while ring occupancy stays at capacity and the writer receives no further bytes; a storage failure while `paused` ends the meeting `interrupted` without opening a segment; there is no resume path after a storage failure (`resume()` rejected); preflight with `freeSpace = 499,999,999` refuses with "Not enough free space to record (needs at least 500 MB)" and inserts nothing, `1,999,999,999` starts with `storageWarning` set and the "Less than 2 GB free" text, `2,000,000,000` starts clean; `meetingWriteFailure`/`meetingEncoderFailure` are recorded.
- [X] T064 [US10] Implement the storage-failure path in `apps/macos/LocalFlow/Features/Meetings/MeetingCoordinator.swift` (250 ms latch poll on the test clock, stop-and-finalize sequence, `interrupted` transition with reason, notice, timer stop, no resume), the preflight thresholds and `storageWarning`, and the "Recording stopped" banner plus warning text in `apps/macos/LocalFlow/Features/Meetings/ActiveMeetingView.swift`; make T063 pass.

**Checkpoint**: SC-006 holds under the test clock; the live disk-image run is Phase 16.

## Phase 14: User Story 11 - One audio source fails, and User Story 12 - Permissions (P1)

**Goal**: A failed source marks its track with reason and time, finalizes its segment, warns prominently and the meeting continues; both failed stops the meeting `interrupted` with `both_sources_failed`; device changes are recorded; permissions are checked before start with exact guidance and revocation is detected during a meeting.
**Independent test**: Fail one fake source mid-meeting, then the other; check the track states, notice, final record. With each permission denied, start is refused with the named permission and no active row. Spec US11 scenarios 1–4, US12 scenarios 1–4.

- [X] T065 [P] [US11] Extend `apps/macos/LocalFlowTests/MeetingCoordinatorTests.swift`: microphone fake fails with `deviceLost` → microphone track `failed(device_lost, now)`, its segment finalized with `close_reason = 'source_failed'`, `MeetingStatus.microphone == .failed`, the "The microphone disconnected. The meeting continued with system audio." notice, state still `recording`, system bytes keep flowing; the symmetric case for `streamStopped`; after the second failure `stop()` runs with `failure_reason = both_sources_failed`, the meeting is `interrupted` with the both-failed text and both reasons visible on the tracks, already-written segments kept; a start where one source refuses to start reaches `recording` with that track `failed` and the warning, and a start where both refuse reaches `failed` with `both_sources_failed` and empty files removed; a microphone device change with a successful restart opens a new segment with `open_reason = 'device_changed'` and `close_reason = 'device_changed'` on the previous one, and a failed restart becomes `device_lost`; a failed track stays `failed` (not `finalized`) after stop even though its segments are finalized; a failed track is never restarted on resume and the meeting continues on the healthy one.
- [X] T066 [P] [US12] Extend `apps/macos/LocalFlowTests/MeetingCoordinatorTests.swift`: microphone `denied` → `start()` returns `.refused` with the existing microphone guidance and no row; screen recording preflight false and request false → `.refused` with the exact screen-recording text and no row; `notDetermined` microphone → the request closure runs once and start waits for it; only the microphone and screen-recording request closures are ever invoked; a `permissionRevoked` event during a meeting marks that track `failed(permission_revoked)` with the "<Track> permission was revoked during the meeting." text and the meeting continues per US11; the microphone revocation is detected through the 250 ms authorization poll.
- [X] T067 [US11] Implement source-failure handling in `apps/macos/LocalFlow/Features/Meetings/MeetingCoordinator.swift` (250 ms poll of `failure()` on both sources, per-track mark/finalize/persist/publish, both-failed stop, device-change segment rollover, failed tracks excluded from resume) and the prominent per-track warning in `apps/macos/LocalFlow/Features/Meetings/ActiveMeetingView.swift`; make T065 pass.
- [X] T068 [US12] Implement the permission steps of the start sequence in `apps/macos/LocalFlow/Features/Meetings/MeetingCoordinator.swift` through `MeetingPermissions`, the revocation poll, and the guidance notice with a "Open System Settings" action (deep link to the Microphone or Screen & System Audio Recording pane) in `apps/macos/LocalFlow/Features/Meetings/ActiveMeetingView.swift`; make T066 pass.

**Checkpoint**: Source failures and permission problems are visible, persisted and never presented as healthy. SC-008's live denied-permission runs are Phase 16.

## Phase 15: User Story 13 - Delete a meeting (P2)

**Goal**: Confirmed deletion removes files first, then the row with cascades; partial failure is reported and the meeting stays listed as "Deletion incomplete"; other meetings are untouched.
**Independent test**: Two meetings, delete one with confirmation; its rows and directory are gone and the other's rows and checksums are unchanged. Spec US13 scenarios 1–4.

- [X] T069 [P] [US13] Write failing tests in `apps/macos/LocalFlowTests/MeetingDeletionTests.swift`: `deleteConfirmed(id:revision:)` refuses an active meeting; removes every listed segment file, then remaining entries in `Meetings/<id>/`, then the directory, and only then deletes the row so tracks, segments, pauses, notes and outcomes cascade to zero rows; the other meeting's rows and SHA-256 file checksums are identical afterwards; a `staleRevision` refuses; a file made unremovable (permission bit or a writer double that fails on one path) leaves the row, returns a `DeletionOutcome` listing the remaining relative path, and the library shows "Deletion incomplete" until a retry succeeds; deleting a recovered `interrupted` meeting with an `unrecoverable` retained `.part` file removes that file too; a directory that is already gone still deletes the row.
- [X] T070 [US13] Implement `deleteConfirmed` in `apps/macos/LocalFlow/Core/Storage/MeetingStore.swift` with the files-first order and `DeletionOutcome`, the in-memory `deletionPending` flag in `apps/macos/LocalFlow/Features/Meetings/MeetingLibraryViewModel.swift`, and the confirmation dialog (existing confirmed-deletion pattern; names the title or fallback and says audio and notes are removed; dismiss changes nothing) plus the partial-failure notice with Retry in `apps/macos/LocalFlow/Features/Meetings/MeetingDetailView.swift`; stop any playback controller for that meeting first; make T069 pass.

**Checkpoint**: SC-009 holds deterministically; the live `chflags uchg` check is Phase 16.

## Phase 16: Instrumentation, exclusivity, acceptance and polish

**Purpose**: Cross-cutting requirements (FR-024, FR-026, FR-027), the hardware evidence the specification lists as separate, the FR-028 traceability audit and documentation.

### Exclusivity and privacy (deterministic)

- [X] T071 [P] Add exclusivity guards to `apps/macos/LocalFlow/App/AppServices.swift`: `DictationCoordinator.begin()` is refused with the "Meeting in progress" action notice while `MeetingCoordinator.isActive`, and `MeetingCoordinator.start()` is refused with "Dictation in progress" while `DictationCoordinator.busy`; write tests in `apps/macos/LocalFlowTests/MeetingCoordinatorTests.swift` and `apps/macos/LocalFlowTests/DictationCoordinatorTests.swift` for both directions, and a guard that with no meeting active the dictation coordinator's dependencies and call sequence are unchanged from the Feature 003 expectations (the FR-027 gate).
- [X] T072 [P] Write `apps/macos/LocalFlowTests/MeetingInstrumentationTests.swift`: a full start → pause → resume → source failure → stop run with fakes emits every metric listed in `data-model.md` "Instrumentation records" with the expected keys and phases; the captured recorder payloads and log lines contain none of a seeded title, a seeded note sentence, any `.aac` path or any audio bytes; RSS samples are tagged `meetingRecording`, `meetingPaused`, `meetingFinalizing`; sampling stays at the existing 10 s cadence and item limit.
- [X] T073 [P] Add a symbol check to `scripts/test.sh` (or a dedicated test in `apps/macos/LocalFlowTests/MeetingInstrumentationTests.swift`) that no file under `apps/macos/LocalFlow/Core/Meetings/` or `Features/Meetings/` references `URLSession`, `RewriteClient`, `ModelLifecycleCoordinator`, `FluidAudio` or `WhisperKit` (FR-024, SC-010's deterministic half).
- [X] T074 [P] Extend the content-free assertion in `apps/macos/LocalFlowTests/ResourceRecorderTests.swift` to fail if any new meeting metric gains a free-text dimension, and add the meeting phases to the report printer with "unmeasured" under 5 samples (SC-012 groundwork).

### Reference-machine acceptance (owner runs; never marked done from fakes)

- [ ] T075 Run `quickstart.md` "Start, record, stop" with permissions granted on the reference machine and record the Start-to-recording time for five runs (gate SC-001 ≤ 3 s), the SC-004 per-track duration against `recorded_ms` for each completed meeting, and the second-Start refusal, in `specs/004-meeting-capture-foundation/acceptance/baseline.md`.
- [ ] T076 Run `quickstart.md` "Force quit and reboot recovery" steps 1–7 on the reference machine (force quit while recording, while paused, during finalizing with `--debug-slow-finalize`, reboot, corrupt `.part`, deleted row with directory kept, clean launch) and record each outcome, the recovery notice, the outcome rows, playability and note integrity in `specs/004-meeting-capture-foundation/acceptance/recovery.md`; SC-002 requires at least one real force-quit run with playable audio and intact notes.
- [ ] T077 Run `quickstart.md` "Storage failure" on a 20 MB disk image through `LOCALFLOW_MEETING_ROOT`, plus the under-500 MB refusal and the 500 MB–2 GB warning, and record time-to-notice, final state and reason, last playable file and RSS delta in `specs/004-meeting-capture-foundation/acceptance/storage-failure.md` (SC-006 live half).
- [ ] T078 Run `quickstart.md` "Source failure and permissions" (USB microphone unplug, screen-recording denied, microphone denied, screen-recording revoked mid-meeting) and "Notes" (2 s save, 30 s continuous typing, force quit while typing, offline edit of a completed meeting) on the reference machine and record outcomes in `specs/004-meeting-capture-foundation/acceptance/recovery.md` under SC-007 and SC-008 headings; confirm only the two expected permission prompts appeared.
- [ ] T079 Run `quickstart.md` "Deletion" including the `chflags uchg` partial-failure case and the sleep case from "Pause and resume" on the reference machine; record checksums before and after and the sleep outcome in `specs/004-meeting-capture-foundation/acceptance/baseline.md` (SC-009 live half, sleep edge case).
- [ ] T080 Run the final 60-minute long-run acceptance on the reference M5 MacBook Pro per `quickstart.md` "Long-run memory acceptance" (both sources, notes edited, one pause/resume, no model loaded, `LOCALFLOW_RESOURCE_RECORDING=1`, RSS sampled every 10 s with `scripts/memory-report.sh`) and write `specs/004-meeting-capture-foundation/acceptance/long-run-memory.md` with hardware, macOS, build/commit, codec settings, conditions, the RSS series, starting/settled/peak/post-stop RSS, the fitted slope over the settled window (gate < 1 MB per 10 min), peak overhead above idle (gate ≤ 100 MB), per-track file sizes, dropped frames, write errors, finalization duration, the comparison with the T044 development run, and the model-lifecycle instrumentation showing no load (SC-003, SC-010). Unmeasured values are written as unmeasured.
- [ ] T081 Run the privacy check from `quickstart.md` over the T080 logs and `Measurements/` records (search for the title, a note sentence and any title-derived path; confirm `meeting_notes.text` is the only note location and no table stores audio) and record zero-match evidence in `specs/004-meeting-capture-foundation/acceptance/privacy.md` (SC-012).

### Regression, traceability and documentation

- [X] T082 Run the full Feature 001–003 suites and `make check` with the feature present and no meeting active, three consecutive local runs of the meeting suites for determinism, and record pass/fail with output in `specs/004-meeting-capture-foundation/acceptance/baseline.md` (SC-011, FR-028 determinism).
- [X] T083 [P] Write `specs/004-meeting-capture-foundation/acceptance/fr-028-traceability.md` mapping each FR-028 scenario (every transition and invalid pair; start → stop; start → pause → resume → stop; interruption while recording, paused and finalizing; system sleep; microphone failure; system-audio failure; storage write failure; each FR-013 reconciliation case; deletion of a recovered meeting; buffer capacity and overflow; note autosave) to one named test, and each SC to its deterministic test and/or acceptance file.
- [X] T084 [P] Update the "Meetings (future)" sections of `docs/architecture/audio-pipeline.md` and `docs/architecture/storage.md` to the delivered design (two sources, per-track worker, ring drop policy, ADTS segments, `meetings-v5` tables, reconciliation, files-first deletion) and add ADR 0015 to `docs/adr/README.md`.
- [X] T085 [P] Update `apps/macos/README.md` with the Meetings page, the two permissions, `LOCALFLOW_MEETING_ROOT`, `--debug-slow-finalize` and the acceptance file locations; confirm `.specify/memory/constitution.md` needs no amendment.
- [X] T086 Review every `Core/Meetings/` and `Features/Meetings/` file against the constitution gates in `plan.md` (bounds documented, no model reference, content-free logs, nothing deleted outside `deleteConfirmed`), remove dead code and placeholder comments from T002, and run `make check` one last time.

## Dependencies and execution order

### Phase dependencies

- **Phase 1 (Setup)**: none.
- **Phase 2 (Spike)**: after T002; blocks Phase 3's storage and writer tasks because the codec check values and extensions depend on T007.
- **Phase 3 (Foundational)**: after Phase 2; blocks every story phase.
- **Phase 4 (US1)**: after Phase 3. MVP.
- **Phase 5 (US2)**, **Phase 6 (US3)**: after Phase 4.
- **Phase 7 (US4)**: after Phase 4; needed by Phase 12's paused-recovery case, T044 and T080.
- **Phase 8 (US5)**: after Phase 4; T049's `flush()` on stop needs T032.
- **Phase 9 (US6)**: after Phases 7 and 8 (the round-trip fixture uses a pause and notes).
- **Phase 10 (US7)**: after Phase 4; the interrupted-row test needs Phase 12 data shapes but can seed rows directly.
- **Phase 11 (US8)**: after Phase 10 (detail view host).
- **Phase 12 (US9)**: after Phases 3 and 7; T062 needs Phase 10.
- **Phase 13 (US10)**: after Phase 7 (paused storage failure case).
- **Phase 14 (US11/US12)**: after Phase 7 (failed tracks excluded from resume).
- **Phase 15 (US13)**: after Phases 11 and 12 (stops playback; deletes a recovered meeting).
- **Phase 16**: T071–T074 after Phase 14; T075–T081 after every story phase; T082–T086 last.

### User story dependencies

- **US1 (P1)**: foundation only. MVP.
- **US2 (P1)**: US1.
- **US3 (P1)**: US1; its development run (T044) also needs US4 and US5.
- **US4 (P2)**: US1. Pulled forward because US9, US10, US11 and the acceptance runs need pause/resume.
- **US5 (P2)**: US1.
- **US6 (P2)**: US4 and US5 for the round-trip fixture.
- **US7 (P2)**: US1.
- **US8 (P2)**: US7.
- **US9 (P1)**: foundation and US4.
- **US10 (P1)**: US4.
- **US11, US12 (P1)**: US4.
- **US13 (P2)**: US8 and US9.

### Parallel opportunities

- Phase 3: `[P]` groups T009/T010/T011, T012, T015, T017, T019/T020, T021/T022, T023, T026–T030.
- After Phase 4: Phases 5, 6, 7, 8 and 10 can proceed in parallel when staffed.
- After Phase 7: Phases 12, 13 and 14 can proceed in parallel; they touch `MeetingCoordinator.swift` and `MeetingCoordinatorTests.swift`, so merge sequentially.
- Phase 16: T071–T074 and T083–T085 in parallel; T075–T081 need the reference machine and run sequentially.

## Parallel example: Phase 3 foundation

```text
# After the spike (T007), launch the independent foundation tests together:
Task: T009 lifecycle tests in apps/macos/LocalFlowTests/MeetingLifecycleTests.swift
Task: T012 store tests in apps/macos/LocalFlowTests/MeetingStoreTests.swift
Task: T015 ring tests in apps/macos/LocalFlowTests/MeetingSampleRingTests.swift
Task: T017 encoder tests in apps/macos/LocalFlowTests/MeetingTrackEncoderTests.swift
Task: T019 validator tests in apps/macos/LocalFlowTests/ADTSValidatorTests.swift
Task: T021 writer tests in apps/macos/LocalFlowTests/FileSegmentWriterTests.swift

# Then: T010/T011 → T013 → T014; T016; T018; T020; T022; T023 → T024 → T025; T026–T030
```

## Implementation strategy

### MVP first (User Story 1)

1. Phases 1–3 (setup, codec evidence, lifecycle, storage, pipeline, sources, fakes).
2. Phase 4: start, stop, status, Meetings page, menu bar items.
3. Stop and validate: a real start → stop on the development machine produces a completed meeting with two playable `.aac` files; Feature 001–003 suites pass; `make check` passes.

### Incremental delivery

1. US2 and US3 → two unmixed tracks with full metadata, bounded pipeline asserted.
2. US4 → segments per stretch, pause rows, sleep handling.
3. US5, US6, US7, US8 → notes, durable record, library, playback.
4. US9, US10, US11/US12 → reconciliation, storage failure, source failure and permissions (the P1 safety stories; they need US4 first).
5. US13 → deletion of any meeting including recovered ones.
6. Phase 16 → exclusivity, instrumentation, reference-machine evidence, traceability, docs.

### LocalFlow required task coverage

Lifecycle and cancellation: T009, T031, T045, T063, T065, T071. Bounded overload: T015, T016, T024, T041, T053, T059 (work-list bound), T063. Offline and recovery: T047, T059–T062, T063, T076, T077. Local instrumentation: T030, T072, T074, T081. Repeatable resource acceptance: T044 (development datapoint), T080 (60-minute gate), T082 (three-run determinism). Hardware, recovery, storage-failure, permission and memory acceptance (T075–T081) are recorded only from real runs on the reference machine, never from fakes or scaffolding builds.
