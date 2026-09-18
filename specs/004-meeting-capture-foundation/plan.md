# Implementation plan: meeting capture foundation

**Branch**: `main` | **Feature identifier**: `004-meeting-capture-foundation` | **Date**: 2026-09-18 | **Spec**: [spec.md](spec.md)

The setup script reports the feature identifier in its `BRANCH` field. The actual Git branch remains `main`, matching the specification. `.specify/feature.json` selects Feature 004.

## Summary

A `MeetingCoordinator` on the main actor owns at most one meeting at a time and drives an explicit lifecycle (`created → preparing → recording ⇄ paused → finalizing → completed | interrupted | failed`) whose every transition is written to SQLite before it is published. Two independent sources feed two independent tracks: the microphone through the existing `AVAudioEngine` tap and `LFAudioRing`, system audio through an audio-only ScreenCaptureKit stream that excludes the app's own output. Each track's worker drains a preallocated 4 MiB ring in 4,096-frame blocks, encodes with `AVAudioConverter` to AAC-LC and appends ADTS frames to a `.part` file it owns, syncing every 5 s; a segment is finalized (flush, fsync, rename) on every pause, stop, sleep, source failure and device change, and a resume opens the next sequence file. Rings drop and count on overflow, so memory stays fixed regardless of duration and disk stalls. Metadata (meetings, tracks, segments, pause intervals, user notes, recovery outcomes) lives in the existing `history.sqlite` through migration `meetings-v5` and a `MeetingStore` actor; media lives under `Meetings/<uuid>/` with relative paths in the database. A `MeetingReconciler` runs at every launch without blocking it, marks anything left active as interrupted, validates and truncates `.part` files to their last complete ADTS frame, reconstructs orphan directories as interrupted meetings, and never deletes. The Meetings page adds a library, a detail view with per-track `AVQueuePlayer` playback and a debounced notes editor, and confirmed deletion that removes files before the row. Dictation and meetings are mutually exclusive.

The codec decision (ADTS AAC-LC) is provisional until the recoverability spike in [research.md](research.md) is recorded; it is the first implementation task. Memory, duration accuracy, start latency and recovery figures are acceptance inputs, not results.

## Technical context

| Item | Decision |
| --- | --- |
| Language/version | Swift 6 language mode, macOS 14.0 target; one C ring change |
| Dependencies | Existing GRDB 7.10.0, SwiftUI/AppKit, AVFoundation (`AVAudioEngine`, `AVAudioConverter`, `AVQueuePlayer`, `AVAudioFile`), ScreenCaptureKit, CoreGraphics (screen-capture access), Darwin file APIs; no added dependency |
| Storage | Existing `history.sqlite`, migration `meetings-v5`, tables `meetings`, `meeting_tracks`, `meeting_segments`, `meeting_pauses`, `meeting_notes`, `meeting_recovery_outcomes`; media files under `Meetings/<uuid>/` as ADTS AAC-LC `.aac` (`.part` while open) |
| Testing | XCTest with `FakeMeetingAudioSource`, `FakeSegmentWriter`, the test clock and an in-memory or temp-dir store; ring C tests through the existing Swift wrapper; acceptance files under `acceptance/` |
| Platform/type | One native macOS app; no server work, no model, no network |
| Performance | SC-001 start ≤ 3 s; SC-003 RSS slope < 1 MB/10 min over the settled window and peak ≤ 100 MB above idle on the 60-minute reference run; SC-004 track duration within max(1%, 2 s); SC-005 recorded duration within 1 s; SC-006 storage failure stops capture within 5 s |
| Constraints | Every buffer bounded (see [contracts/meeting-capture.md](contracts/meeting-capture.md)); only microphone and screen-recording permissions; no audio in SQLite; no title in file names; notes ≤ 1 MiB; free-space warn < 2 GB, block < 500 MB; nothing deleted except by confirmed deletion |
| Scope | Start/pause/resume/stop, two tracks, bounded pipeline, notes, durable record, library and detail, playback, reconciliation, storage and source failure handling, permissions, deletion, instrumentation and tests; no transcription, diarization, identity, summaries, search, backup or cloud |

No unresolved design clarification remains. Capture API choice, codec, bounds, timeline, lifecycle, sleep, exclusivity, storage layout, reconciliation, playback and notes decisions are in [research.md](research.md).

## Constitution check

Pre-research gate: pass. No exception is proposed.

| Principles | Design and post-design result |
| --- | --- |
| 1, 14: native client and scope | Pass. Swift/SwiftUI/AppKit and Apple frameworks only; one C function pair added to the existing ring; no package, no server work, no speculative infrastructure. Combined monitoring playback is deferred as a MAY. |
| 2, 6: bounded memory and incremental work | Pass by design. Every queue, block, counter, page and work list has a declared capacity and overload policy in [contracts/meeting-capture.md](contracts/meeting-capture.md) and [research.md](research.md), "Bounded pipeline per track". Audio is encoded and appended per 4,096-frame block; overflow drops and counts at the ring; no write queue exists; playback streams from files. SC-003 is the measured gate with the 60-minute run and its evidence file. |
| 3: model lifecycle | Pass. No model is created, loaded or referenced by this feature. `ModelLifecycleCoordinator` is untouched; SC-010 confirms no load during capture through existing instrumentation. Dictation is refused while a meeting is active, so no ASR working set is added to a recording. |
| 4, 5: offline and privacy | Pass. Every story works with no network, server or model. Audio and notes stay on disk under 0600/0700 paths; only microphone and screen-recording permissions are requested; logs and `ResourceRecorder` records carry counts, durations, states and error codes only, with the content-free test extended (SC-012). `excludesCurrentProcessAudio` keeps the app's own sounds out of the system track. |
| 7, 9: persistence and recovery | Pass. One migration, six tables, cascades, explicit transactions; media in files with relative paths; write-then-publish for every transition; segment heartbeat every 5 s; finalized segment files after every pause; `.part` naming plus database authority; reconciliation at launch handles all FR-013 cases conservatively and deletes nothing. Backup is out of scope. |
| 8: server isolation | Not exercised. |
| 10, 11: speaker correctness, structured output | Not exercised. Tracks stay separate and unmixed so later features can attribute correctly. |
| 12: testability | Pass. `MeetingAudioSourcing`, `SegmentWriting`, the clock and the store have doubles; tests cover every transition and invalid pair, cancellation-equivalent stop paths, ring capacity and drop counting, storage and source failures, sleep, every reconciliation case, deletion, autosave and preservation of already-written media. |
| 13: observability | Pass by design. New content-free metrics for start and capture-init duration, transitions, per-track queue depth, dropped frames, bytes written, write and encoder failures, pause/resume counts, finalization duration, file sizes, recovery outcomes and RSS samples during meetings. Acceptance files identify hardware, macOS, build, codec settings and conditions. |

Post-design gate: pass. One ADR is expected at implementation time once the spike confirms the codec: `docs/adr/0015-adts-aac-segments.md` (ADTS AAC-LC segment files with database-authoritative manifest), which records how ADR 0008's "crash-recoverable fragments" requirement was met. It amends no principle.

## Project structure

```text
specs/004-meeting-capture-foundation/
  spec.md
  plan.md
  research.md
  data-model.md
  quickstart.md
  contracts/
    meeting-lifecycle.md
    meeting-capture.md
    meeting-storage.md
  acceptance/                              # implementation: codec-recoverability, recovery, storage-failure, long-run-memory, privacy, fr-028-traceability
  tasks.md                                 # next workflow; not generated by planning
apps/macos/LocalFlow/
  Info.plist                               # usage-description key only if the spike shows one is required
  Core/Audio/
    AudioCaptureRing.h / .c                # LFAudioRingSetDropOnOverflow, LFAudioRingDroppedFrames
    MeetingSampleRing.swift                # new: Swift wrapper with the drop-and-count policy
  Core/MeetingBoundaries.swift             # new: MeetingAudioSourcing, SegmentWriting, MeetingClock, MeetingStoring, error text
  Core/Meetings/                           # new
    MeetingLifecycle.swift                 # states, transition table, MeetingFailureReason
    MeetingModels.swift                    # Meeting, MeetingTrack, MeetingSegment, PauseInterval, MeetingNotes, RecoveryOutcome, MeetingStatus
    MicrophoneMeetingSource.swift          # AVAudioEngine tap into the ring; device change handling
    SystemAudioMeetingSource.swift         # SCStream audio-only capture
    MeetingTrackEncoder.swift              # AVAudioConverter → AAC-LC, ADTS header composition
    ADTSValidator.swift                    # frame scan, truncation point
    FileSegmentWriter.swift                # fd-owned .part files, sync, finalize, free space
    MeetingTrackWorker.swift               # per-track serial loop, heartbeat, failure latch
    MeetingReconciler.swift                # launch reconciliation and outcome summary
    MeetingPermissions.swift               # microphone and screen-recording checks and guidance
  Core/Storage/
    HistoryMigrations.swift                # meetings-v5
    MeetingStore.swift                     # new actor sharing the DatabaseQueue
  Core/Observability/ResourceRecorder.swift  # meeting metrics and phases
  App/
    AppServices.swift                      # reconciler at start, MeetingCoordinator wiring, exclusivity guards
    MainWindowRouter.swift                 # LocalFlowPage.meetings
    LocalFlowApp.swift                     # menu bar meeting items and glyph, Meetings page
  Features/Meetings/                       # new
    MeetingCoordinator.swift               # start/pause/resume/stop, sleep observer, source and storage failure polling
    MeetingNotesEditor.swift               # debounce, forced save, dirty state
    MeetingLibraryViewModel.swift          # paging (20 rows, 2 pages)
    MeetingLibraryView.swift
    MeetingDetailView.swift                # metadata, tracks, segments, pauses, outcomes, notes, delete
    ActiveMeetingView.swift                # elapsed, track indicators, controls, warning banner
    TrackPlaybackController.swift          # AVQueuePlayer over finalized segments
apps/macos/LocalFlowTests/
  Support/MeetingFakes.swift               # FakeMeetingAudioSource, FakeSegmentWriter, test clock helpers, synthetic ADTS fixtures
  MeetingLifecycleTests.swift, MeetingStoreTests.swift, MeetingCoordinatorTests.swift,
  MeetingTrackWorkerTests.swift, MeetingSampleRingTests.swift, ADTSValidatorTests.swift,
  MeetingReconcilerTests.swift, MeetingNotesEditorTests.swift, MeetingLibraryTests.swift,
  MeetingDeletionTests.swift, MeetingInstrumentationTests.swift  # new
apps/macos/LocalFlowUITests/PlatformProbeTests.swift  # optional ScreenCaptureKit availability probe
scripts/memory-report.sh                  # reused for the long-run RSS series
docs/adr/0015-adts-aac-segments.md        # after the spike
docs/architecture/audio-pipeline.md, storage.md  # update the "Meetings (future)" sections to the delivered design
```

New files are proposed locations. Keep every database write under `MeetingStore`; reuse `IndicatorPanel` action notices, `MainWindowRouter`, the confirmed-deletion dialog pattern and `ResourceRecorder` rather than adding parallel mechanisms. The existing `AudioCaptureService` and `AudioSpool` are not modified.

## Delivery sequence

1. Spike: codec recoverability harness, `kill -9` runs, ScreenCaptureKit audio-only stream and screen-recording permission check on macOS 14, `AVQueuePlayer` over consecutive ADTS files. File `acceptance/codec-recoverability.md`; confirm or switch the codec; write ADR 0015.
2. Lifecycle and storage: `MeetingLifecycle` with the full transition table and invalid-pair tests; migration `meetings-v5`; `MeetingStore` with single-active-meeting admission, segment open/heartbeat/finalize, pauses, notes, title, paging, detail, outcomes and files-first deletion; store tests including restart, cascade, one-open-segment and one-open-pause invariants, stale revision and the 1 MiB notes bound.
3. Pipeline: ring drop-and-count mode with C-level tests through the wrapper; `MeetingTrackEncoder` with ADTS header tests against `AVAudioFile` read-back; `ADTSValidator`; `FileSegmentWriter` with private-path checks; `MeetingTrackWorker` with the fake writer covering write, sync and finalize failures, the 5 s heartbeat and the failure latch; bounded-memory assertions on block sizes.
4. Sources: `MicrophoneMeetingSource` (reusing the tap pattern, one restart on device change) and `SystemAudioMeetingSource` (SCStream, `excludesCurrentProcessAudio`, delegate errors mapped to reasons); `MeetingPermissions` with guidance text; `FakeMeetingAudioSource`.
5. Coordinator: start sequence in contract order, write-then-publish transitions, pause/resume/stop, sleep observer, 250 ms failure polling, source-failure continuation, both-failed stop, storage-failure stop within the bound, elapsed timer, `MeetingStatus`; coordinator tests for every FR-028 scenario with fakes and the test clock; exclusivity guards in `AppServices` with the Feature 001–003 suites run unchanged.
6. Reconciliation: `MeetingReconciler` for every FR-013 case (record without files, files without record, stale metadata, one track finalized, active while not running, open pause), truncation and rename, outcome rows, launch summary notice; tests with synthetic `.part` fixtures; wiring in `AppServices.start()` before dictation is enabled and without blocking launch.
7. UI: Meetings page, active meeting view with controls and warnings, library paging, detail view, per-track playback with skip-unplayable and position, notes editor with debounce and forced save, title editing, confirmed deletion with partial-failure reporting, menu bar items and glyph; view-model tests for paging bounds, autosave timing and byte-identity after playback.
8. Instrumentation and acceptance: recorder metrics and phases with the content-free assertion; development 10–15 minute run; reference-machine force-quit run (`acceptance/recovery.md`), storage-failure run (`acceptance/storage-failure.md`), 60-minute run (`acceptance/long-run-memory.md`), privacy search (`acceptance/privacy.md`), FR-028 traceability audit; update `docs/architecture/audio-pipeline.md` and `storage.md`. Continue to analyze/implement through the repository workflow.

## LocalFlow constitution gates

Bounds and overflow: all capacities and policies are normative in [contracts/meeting-capture.md](contracts/meeting-capture.md) and summarized in [research.md](research.md), "Bounded pipeline per track": two 4 MiB rings that drop and count, one 4,096-frame input block and one 8-packet output block per track, synchronous writes with a failure latch and no write queue, 5 s sync and heartbeat, notes ≤ 1 MiB with one save in flight, 20-row pages with two resident, a reconciliation work list of at most 100 rows and 1,000 directory entries per launch, recorder samples every 10 s. Nothing accumulates while storage fails; audio is dropped at the ring and counted.

Lifecycle owner and release: no model is owned or touched. The meeting coordinator owns two sources and two workers per stretch and releases them on every pause, stop, sleep and failure; a stopped meeting holds no capture objects, which the post-stop RSS value in the long-run report checks.

Offline and privacy: no network path exists in this feature. Only microphone and screen-recording permissions are requested, from the explicit Start action. Files are private; titles never reach file names; instrumentation and logs are content-free with a test asserting it; the app's own audio is excluded from the system track.

Recovery and persistence: identity persisted before capture; every transition persisted before publication; segments finalized on every pause; heartbeat every 5 s; reconciliation at every launch marks interrupted, recovers to the last complete frame, reconstructs orphans, closes open pauses, records outcomes and deletes nothing; a save failure is never shown as saved; deletion removes files before the row and reports partial failure.

Dependencies and licenses: none added. ScreenCaptureKit and AVFoundation are system frameworks.

Memory acceptance: SC-003 on the reference machine with the 60-minute run and a 10–15 minute development run, both with two sources, notes edits and a pause/resume, sampled every 10 s, reporting starting/settled/peak/post-stop RSS, fitted slope (gate < 1 MB per 10 min), peak overhead above idle (gate ≤ 100 MB), file sizes, dropped frames, errors and finalization duration, with hardware, macOS, build, codec settings and conditions. Unmeasured until recorded; no unit test is presented as evidence.

Test strategy: deterministic XCTest for FR-028 with fakes and a test clock; real device and file paths only in the spike and acceptance runs; the Feature 001–003 suites run unchanged as the FR-027 regression gate.

## Validation and requirement coverage

| Requirements | Primary validation |
| --- | --- |
| FR-001, FR-002, FR-006, FR-008; SC-001 | Coordinator tests: row exists before sources start, second start refused without a row, `MeetingStatus` fields, finalize order and totals; live start timing in the quickstart |
| FR-003; SC-004 | Spike and quickstart playback of each track; store tests for two tracks per meeting; duration-warning computation test |
| FR-004, FR-005, FR-025; SC-003 | Contract block sizes asserted in worker tests; ring drop tests; codec spike evidence; long-run memory acceptance file |
| FR-007; SC-005 | Pause/resume/sleep tests: segment per stretch, pause rows, recorded duration arithmetic, no automatic resume after wake |
| FR-009; SC-007 | Notes editor tests with the test clock (2 s, 10 s, failure keeps dirty); live force-quit note check |
| FR-010, FR-011 | Lifecycle table test over every state pair; store test that a failed write leaves the published state unchanged; heartbeat test |
| FR-012, FR-013; SC-002 | Reconciler tests per case with synthetic fixtures; live force-quit, reboot and corrupt-file runs recorded in `acceptance/recovery.md` |
| FR-014, FR-015, FR-023 | Store round-trip tests for every column; relative-path validation test; relocation check in the quickstart |
| FR-016, FR-017 | Library paging bounds test; detail rendering test; playback byte-identity test; unplayable segment labelling |
| FR-018, FR-019; SC-006 | Worker and coordinator tests with `FakeSegmentWriter` failure knobs and the test clock; free-space threshold tests; live disk-image run |
| FR-020, FR-021; SC-008 | Source-failure tests for each and both; permission guidance tests with fake statuses; live denied-permission runs |
| FR-022; SC-009 | Deletion tests: cascade, files-first order, partial failure outcome, other meeting untouched by checksum |
| FR-024; SC-010 | No network or model symbol in the meeting targets; existing model lifecycle instrumentation shows no load during the long run |
| FR-026; SC-012 | Recorder metric tests and the content-free assertion; privacy search in the quickstart |
| FR-027; SC-011 | Feature 001–003 suites unchanged; exclusivity guard tests |
| FR-028 | Traceability audit: one named test per scenario, deterministic under three repeated local runs |

Run `make check` after repository changes. It establishes deterministic and scaffolding validity only; see [quickstart.md](quickstart.md) for live and acceptance steps.

## Complexity tracking

No constitution violations. The only added moving parts are the second capture source and the per-track worker, both required by the two-track and bounded-memory requirements.
