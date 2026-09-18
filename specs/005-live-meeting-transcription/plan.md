# Implementation plan: live meeting transcription

**Branch**: `main` | **Feature identifier**: `005-live-meeting-transcription` | **Date**: 2026-09-18 | **Spec**: [spec.md](spec.md)

The setup script reports the feature identifier in its `BRANCH` field. The actual Git branch remains `main`, matching the specification. `.specify/feature.json` selects Feature 005.

## Summary

A `MeetingTranscriptionCoordinator` on the main actor adds a second, independent lifecycle (`not_requested | pending → live → finalizing → final | failed | interrupted`) beside the Feature 004 meeting lifecycle, persisted in `history.sqlite` through migration `transcripts-v6` and a `TranscriptStore` actor. While a meeting records with transcription requested, each track worker hands its PCM blocks to an analysis tap (a second drop-and-count `MeetingSampleRing`); a mixer turns the two taps into one mono 16 kHz stream (`mixed_mono_16k_v1`) feeding a 30 s analysis queue; a live recognizer plans contiguous 6 s windows (`live_contiguous_96000_v1`), runs them through the leased Parakeet runtime, the existing assembler (two-window wrapper), a deterministic segmenter and the normalizer with a vocabulary snapshot taken at live start, and persists provisional segments in batches of ≤ 50. Lag beyond 10 s drops whole windows into recorded live gaps; a full queue suspends the live path; the recording is never throttled. On stop, the live path drains, and `MeetingFinalizer` re-transcribes the complete recording from the durable ADTS files with the production 239,360-sample geometry, persisting final segments and progress incrementally so a force-quit resumes at the next window. Retry and Transcribe run the same finalizer. Launch reconciliation marks pending/live transcripts `interrupted` (Retry offered), or `failed` when their meeting failed, and resumes interrupted finalizations. The model is leased only during live and finalization, retained through pauses for up to 10 minutes, and released through the existing cooldown. Deletion cascades through foreign keys and the existing files-first path.

Feature 004's write path is unchanged when the tap is nil; dictation refuses with a notice while a finalization holds the lease. Phase 2 measured a maximum recognition RTF of 0.0062642444 across six runs on the reference M5. The selected live geometry is `live_contiguous_96000_v1`; the SC-006 finalization gate is 0.01× audio duration, rounding 1.5× the maximum observed RTF upward to 0.01. See [throughput evidence](acceptance/throughput.md) for fixtures, cold/cached model loads and measurement limits.

## Technical context

| Item | Decision |
| --- | --- |
| Language/version | Swift 6 language mode, macOS 14.0 target; no C change |
| Dependencies | Existing FluidAudio 0.15.7 (Parakeet v3), GRDB 7.10.0, SwiftUI/AppKit, AVFoundation (`AVAudioFile`, `AVAudioConverter`, `AVAudioPCMBuffer`); no added dependency |
| Storage | Existing `history.sqlite` (128 MiB ceiling), migration `transcripts-v6`, tables `meeting_transcriptions`, `transcript_segments`, `transcript_live_gaps`, `transcript_usage`; no derived audio files |
| Testing | XCTest with `FakeTranscriptionRuntime`, `FakeMeetingAudioSource`, `FakeAnalysisTap`, `FakeTranscriptStore`, the test clock and synthetic ADTS fixtures; acceptance files under `acceptance/` |
| Platform/type | One native macOS app; no server work, no network, no new permission |
| Performance | SC-001 live median ≤ 5 s, p95 ≤ 10 s; SC-003 RSS slope < 1 MB/10 min, queue ≤ 480,000 samples; SC-006 finalization gate = 0.01× audio duration (Phase 2 maximum RTF 0.0062642444 × 1.5, rounded upward to 0.01); SC-008 first page ≤ 1 s, ≤ 400 resident segments; SC-009 WER within 1 point of dictation |
| Constraints | Every buffer bounded per [contracts/live-analysis.md](contracts/live-analysis.md); one model lease at a time; no audio, transcript or note text in logs or metrics; per-meeting 20,000 segments / 16 MiB text, global 48 MiB; offline after provisioning |
| Scope | Global setting and start override, live provisional transcript with backpressure, timestamped segments on the recorded-audio timeline, automatic restart-safe finalization, retry and transcribe, transcript view with paging and diagnostics, reconciliation, deletion cascade, instrumentation and tests; no diarization, identity, summaries, search, rewriting, edits, backup or cloud |

No unresolved design clarification remains; agenda items 6–11 and 13–20 keep their proposed defaults and are applied in [research.md](research.md). Phase 2 has recorded the real-time factor and frozen the live geometry; later latency and production finalization acceptance remain unmeasured.

## Constitution check

Pre-research gate: pass. No exception is proposed.

| Principles | Design and post-design result |
| --- | --- |
| 1, 14: native client and scope | Pass. Swift/SwiftUI/AppKit and Apple frameworks only; no package, no server work; one thin slice on top of 004 with no speculative infrastructure (no yield-to-dictation, no derived audio store, no streaming engine API). |
| 2, 6: bounded memory and incremental work | Pass by design. Every queue, buffer, batch, page and work list has a declared capacity and overload policy in [contracts/live-analysis.md](contracts/live-analysis.md), "Bounds summary". Live audio is processed per 4,096-frame block and per 96,000-sample window; finalization decodes 4,096 frames at a time into one 239,360-sample window; no whole-meeting audio, no unbounded segment array, no unbounded UI. SC-003 and SC-004 require hardware measurements, which remain pending. |
| 3: model lifecycle | Pass. Only `ModelLifecycleCoordinator` creates, leases and releases the runtime; the transcription coordinator holds one lease per live session and one per finalization, none when transcription is not requested (SC-002), retained ≤ 10 min through pauses, released through the existing cooldown. No second runtime, no diarization model. |
| 4, 5: offline and privacy | Pass. No network path, no new permission; audio and transcripts stay in the private database and the existing meeting directory; logs and recorder samples carry states, counts, codes and durations only, with the content-free test extended (SC-010); Feature 003 rewriting has no entry point from transcripts. |
| 7, 9: persistence and recovery | Pass. One migration, four tables, cascades, explicit transactions, write-then-publish for every transition; progress persisted with every batch; a final segment never updated; reconciliation at launch reads only transcript rows, deletes nothing and never touches audio; a failed save is never reported as saved. |
| 8: server isolation | Not exercised. |
| 10: speaker correctness | Pass. `speaker` is constrained to `'unassigned'`; the analysis descriptor records exactly which audio was analyzed so Feature 006 can attribute from the original tracks. |
| 11: structured output | Not exercised (no LLM). |
| 12: testability | Pass. Runtime, audio source, tap, store and clock have doubles; tests cover every transition and invalid pair, cancellation at pause/stop/delete, every capacity, every failure category, restart during live and finalization, and preservation of persisted text (FR-029). |
| 13: observability | Pass by design. New content-free metrics for model load, live latency, queue depths, segments produced, backpressure events, gap milliseconds, finalization duration, real-time factor, batch duration, reloads and failures; RSS through the existing sampler; acceptance files identify hardware, OS, build, model, planner version and conditions. |

Post-design gate: pass. Phase 2 added `docs/adr/0016-meeting-transcription-passes.md` (live preview pass with a separate versioned planner, finalization from durable audio with production geometry, one mixed analysis stream), recording the decisions from clarifications 2–4 and their limits. It amends no principle.

## Project structure

```text
specs/005-live-meeting-transcription/
  spec.md
  plan.md
  research.md
  data-model.md
  quickstart.md
  contracts/
    transcription-lifecycle.md
    live-analysis.md
    transcript-storage.md
  acceptance/                              # implementation: throughput, live-latency, long-run-memory, recovery, accuracy-parity, privacy, fr-029-traceability
  tasks.md                                 # next workflow; not generated by planning
apps/macos/LocalFlow/
  Core/TranscriptBoundaries.swift          # new: MeetingTranscriptionObserving, TranscriptStoring, TranscriptTransitionEffect, TranscriptErrorMessage
  Core/Meetings/
    MeetingTrackWorker.swift               # optional analysisSink call before encode
    MeetingBoundaries.swift                # MeetingTransitionEffect.insertTranscription, MeetingStartOptions
  Core/Transcripts/                        # new
    TranscriptLifecycle.swift              # states, transition table, TranscriptFailureCategory, LiveState
    TranscriptModels.swift                 # MeetingTranscription, TranscriptSegment, LiveGap, AnalysisStreamDescriptor, TranscriptStatus, FinalizationProgress
    MeetingAnalysisTap.swift               # second MeetingSampleRing, detach, dropped count
    AnalysisStreamMixer.swift              # downmix, resample, mix, gap accounting; shared by live and final
    AnalysisQueue.swift                    # 480,000-sample SPSC ring, lag policy constants
    LiveChunkPlanner.swift                 # live_contiguous_96000_v1 (+ 64000 variant)
    MeetingWindowAssembler.swift           # two-window TranscriptAssembler wrapper
    TranscriptSegmenter.swift              # segmenter_gap0.8_punct_v1
    LiveRecognizer.swift                   # serial loop: plan → transcribe → assemble → segment → normalize → buffer
    MeetingFinalizer.swift                 # decode stretches, production geometry, progress, completion transaction
    TranscriptReconciler.swift             # launch reconciliation of transcript rows
    WallClockDerivation.swift              # pure derivation over MeetingDetail + descriptor
  Core/Storage/
    HistoryMigrations.swift                # transcripts-v6
    TranscriptStore.swift                  # new actor sharing the DatabaseQueue
    MeetingStore.swift                     # deleteConfirmed usage decrement; insertTranscription effect
  Core/Observability/ResourceRecorder.swift  # transcript metrics and phases
  App/
    AppServices.swift                      # TranscriptStore, MeetingTranscriptionCoordinator, reconciler chaining, admissionGuard extension, debug flags
    LocalFlowApp.swift                     # menu-bar Start uses the preference
  Features/Settings/
    AppPreferences.swift                   # meetingTranscriptionEnabled
    SettingsView.swift                     # Meetings section toggle
  Features/Meetings/
    MeetingCoordinator.swift               # Dependencies.transcription observer, start(options:), tap installation per stretch, willDelete hook
    MeetingLibraryView.swift               # Transcribe toggle at Start; transcript glyphs
    ActiveMeetingView.swift                # Transcript section (live)
    MeetingDetailView.swift                # Transcript section (paged), actions, diagnostics, seek
  Features/Transcripts/                    # new
    MeetingTranscriptionCoordinator.swift  # live session, finalization queue, TranscriptStatus, retention timer
    LiveTranscriptModel.swift              # 200-segment ring, auto-follow
    TranscriptPager.swift                  # 200-row pages, 2 resident
    TranscriptSectionView.swift            # shared list rendering for active and detail views
apps/macos/LocalFlowTests/
  Support/TranscriptFakes.swift            # FakeTranscriptionRuntime, FakeAnalysisTap, FakeTranscriptStore, synthetic windows and PCM
  TranscriptLifecycleTests.swift, TranscriptStoreTests.swift, MeetingAnalysisTapTests.swift,
  AnalysisStreamMixerTests.swift, AnalysisQueueTests.swift, LiveChunkPlannerTests.swift,
  MeetingWindowAssemblerTests.swift, TranscriptSegmenterTests.swift, LiveRecognizerTests.swift,
  MeetingTranscriptionCoordinatorTests.swift, MeetingFinalizerTests.swift, TranscriptReconcilerTests.swift,
  TranscriptPagerTests.swift, TranscriptInstrumentationTests.swift, WallClockDerivationTests.swift,
  MeetingTrackWorkerTests.swift            # nil-sink equivalence and slow-sink isolation cases added
docs/adr/0016-meeting-transcription-passes.md
docs/architecture/audio-pipeline.md, storage.md, model-lifecycle.md  # meeting transcription sections
```

New files are proposed locations. Keep every transcript-table write under `TranscriptStore`; reuse `ModelLifecycleCoordinator`, `TranscriptAssembler`, `TranscriptSourceMapper`, `TranscriptNormalizer`, `VocabularyStore.snapshot()`, `TranscriptionPipelineIdentity`, `MeetingSampleRing`, `TrackPlaybackController`, `ResourceRecorder`, the indicator-panel notices and the confirmed-deletion dialog rather than adding parallel mechanisms. `ChunkPlanner`, `WindowedTranscriber`, `DictationCoordinator` and `AudioSpool` are not modified.

## Delivery sequence

1. Throughput measurement: a harness over the finalizer's decode-and-recognize loop against the real engine on the reference machine; file `acceptance/throughput.md`; freeze the live planner variant and the SC-006 gate; write ADR 0016.
2. Lifecycle and storage: `TranscriptLifecycle` with the full transition table and invalid-pair tests; migration `transcripts-v6`; `TranscriptStore` with transition effects, batched `appendSegments` with the capacity order, gaps, pass discard, completion transaction, paging, usage; `MeetingStore` changes (transcription row in the `preparing` transaction, usage decrement on delete); store tests including capacity refusal leaving nothing written, cascade, usage return-to-zero and stale revision.
3. Pure pipeline pieces: `LiveChunkPlanner` (both variants), `AnalysisStreamMixer` with synthetic PCM (both tracks, one track, failed track, tap-drop accounting), `AnalysisQueue` with the lag table, `MeetingWindowAssembler`, `TranscriptSegmenter`, `WallClockDerivation`; every bound asserted.
4. Tap and worker: `MeetingAnalysisTap`; `MeetingTrackWorker.analysisSink` with the nil-sink equivalence test and the slow-sink isolation test; `MeetingCoordinator` observer hooks, `start(options:)`, tap installation per stretch, `meetingWillDelete`; Feature 004 suites unchanged.
5. Live session: `LiveRecognizer` and `MeetingTranscriptionCoordinator` live path with `FakeTranscriptionRuntime` and the test clock: enabled start, disabled start with zero lease calls, provisional batches, pause/resume with retention and reload count, stop drain and gap, backpressure states and suspension, runtime failure, persistence failure, capacity failure, vocabulary snapshot stability.
6. Finalization: `MeetingFinalizer` over synthetic ADTS stretch files: production windows, progress per batch, resume reproducing identical windows, identity mismatch restart, single-track stretches, decode failure, cancellation on delete, completion transaction replacing provisional rows; Retry and Transcribe entry points; finalization queue; dictation `admissionGuard` extension.
7. Reconciliation: `TranscriptReconciler` cases per the policy table, chained after `MeetingReconciler`, outcome rows, launch resume enqueue; tests with seeded rows.
8. UI and settings: preference and Settings toggle; Start toggle; active-meeting Transcript section with `LiveTranscriptModel`; detail Transcript section with `TranscriptPager`, actions, confirmation sheet, diagnostics, seek; library glyphs; view-model tests for the ring, auto-follow and paging bounds.
9. Instrumentation and acceptance: recorder metrics and phases with the content-free assertion; debug flags (`--debug-slow-recognition`, `--debug-fail-recognition`, `--debug-fail-persistence`, `--debug-seed-transcript`); development 10–15 minute runs; reference-machine live-latency, long-run memory, slow run, force-quit, accuracy-parity and privacy acceptance files; FR-029 traceability audit; update `docs/architecture/*`. Continue to analyze/implement through the repository workflow.

## LocalFlow constitution gates

Bounds and overflow: all capacities and policies are normative in [contracts/live-analysis.md](contracts/live-analysis.md), "Bounds summary": tap rings of 32 × 4,096 frames that drop and count, 1 s stagings, a 30 s analysis queue with the 6 s / 10 s / 30 s lag policy, one in-flight window, a two-window assembler, a 200-segment provisional buffer, ≤ 50-segment or 2 s batches, 10,000 gap rows, 200-row pages with two resident, a 10,000-stretch work limit with derived items paged 100 at a time from loaded meeting metadata, a 100-meeting finalization queue and 100 reconciliation rows per launch. At capacity, live audio is dropped and recorded as a gap; segments are refused with a reported failure, never dropped silently; the worker's write path never waits on the tap.

Lifecycle owner and release: `ModelLifecycleCoordinator` is the only runtime owner. The transcription coordinator acquires one lease at live start and one at finalization start, finishes them at stop/failure/completion, keeps the live lease through pauses for at most 10 minutes, and takes none when transcription is not requested. Post-finalization release is the existing cooldown; the long-run report checks the post-finalization RSS.

Offline and privacy: no network path, no new permission, no derived audio on disk; transcript, note and audio content never reach logs or the recorder, with the content-free test extended and the privacy search in the quickstart; rewriting has no entry point.

Recovery and persistence: transcript row created with the meeting; every transition persisted before publication; segments and progress in one transaction per batch; final rows immutable; provisional rows replaced only in the completion transaction; reconciliation at every launch marks or resumes without touching audio; deletion cascades with counters adjusted in the same transaction; a refused or failed save is reported, never shown as saved.

Dependencies and licences: none added.

Memory acceptance: SC-003 and SC-004 on the reference machine with the ≥ 60-minute live run, the 20-minute slow run and a recording-only baseline, sampled every 10 s, reporting starting/settled/peak/post-finalization RSS, fitted slope (gate < 1 MB per 10 min), queue depth maximum, skipped intervals, latency distribution, finalization duration, real-time factor, coverage and storage growth, with hardware, macOS, build, model, planner version and conditions. Unmeasured until recorded; no unit test is presented as evidence.

Test strategy: deterministic XCTest for FR-029 with fakes and the test clock; the real engine only in the throughput harness and acceptance runs; the Feature 001–004 suites run unchanged as the FR-028 regression gate.

## Validation and requirement coverage

| Requirements | Primary validation |
| --- | --- |
| FR-001; SC-002 | Preference and start-option tests; disabled-start test asserting zero `acquire` calls and `not_requested`; recorder shows no model load in the quickstart |
| FR-002, FR-003 | Lifecycle table test over every state pair; store test that a failed write leaves the published status unchanged; every failure category test leaves `meetings.state` unchanged and files growing |
| FR-004, FR-027 | Only `ModelLifecycleCoordinator.transcribe` is called (fake runtime counts); no import of rewrite types in the transcript module; offline runs |
| FR-005, FR-019; SC-012 | Track-file checksum test before/after live and final passes; deletion cascade and usage tests; file-system search after deletion |
| FR-006 | Mixer tests (both, one, failed track, descriptor values); descriptor persisted per pass |
| FR-007, FR-008, FR-017; SC-005 | Segmenter and store validation tests (`start < end ≤ covered`); pause test asserting no cross-stretch segment; wall-clock derivation tests; no edit path exists |
| FR-009 | Store test: final rows immutable, provisional rows removed only by `completeFinalPass` with the count recorded |
| FR-010, FR-013 | Coordinator tests: stop → drain → finalizing → final without user action; Retry and Transcribe share `MeetingFinalizer.run`; window-close continuation in the quickstart |
| FR-011, FR-012, FR-018; SC-007 | Finalizer resume tests (identical windows, no re-finalized rows); identity-mismatch restart; reconciler case tests; live force-quit runs in `acceptance/recovery.md` |
| FR-014, FR-024 | Pause tests: no windows planned while paused, retention expiry finishes the lease, resume re-acquires with reload count; lease absent when not requested |
| FR-015 | Snapshot stability test: vocabulary edit mid-pass does not change later segments' normalization within the pass; finalization records its own revision |
| FR-016 | Notes byte-identity test through a transcribed meeting; segment texts never contain note text |
| FR-020, FR-021; SC-003, SC-004 | Bound assertions in every component test; slow-runtime coordinator tests for catching up, degraded, suspended and gap rows; long-run and slow acceptance files |
| FR-022, FR-023; SC-008 | Capacity-order tests; pager tests with 10,000 rows; first-page timing in the quickstart |
| FR-025; SC-001 | Planner contract tests for both variants; version persisted; latency distribution in `acceptance/live-latency.md` |
| FR-026; SC-010 | Recorder metric tests and the content-free assertion; privacy search |
| FR-028; SC-011 | Feature 001–004 suites unchanged; nil-sink worker equivalence test |
| FR-029 | Traceability audit: one named test per listed scenario, deterministic under three repeated local runs |
| SC-006 | Phase 2 maximum RTF 0.0062642444; selected planner `live_contiguous_96000_v1`; finalization gate ≤ 0.01× audio duration (1.5× RTF rounded upward to 0.01). Production finalization duration and RTF remain to be measured in the long-run file; [evidence](acceptance/throughput.md) |
| SC-009 | `acceptance/accuracy-parity.md` from the Feature 002 fixtures through the finalizer |

Run `make check` after repository changes. It establishes deterministic and scaffolding validity only; see [quickstart.md](quickstart.md) for throughput, live and acceptance steps.

## Complexity tracking

No constitution violations. The added moving parts are the analysis tap, the mixer, the live recognizer and the finalizer; each is required by a clarified decision (live preview with its own planner, one mixed stream, re-transcription from durable audio) and each has a declared bound and a double.

## Implementation reconciliation (2026-09-18)

`TranscriptReconciler.run()` returns `Summary`; launch enqueues `Summary.resume` after meeting reconciliation. Still-active meetings are deferred. Pending/live rows on terminal meetings become interrupted, or failed for failed meetings. Eligible finalizing rows keep their state for automatic resume.

`TranscriptStoring.recover(row:to:outcome:)` atomically commits recovery state and outcome with an expected-revision check, so failed outcome insertion leaves the active row retryable at launch. `TranscriptStoring` also includes `restartFinalPass` for an atomic identity-mismatch restart and `passSegmentCount` for resume ordinals. Reads lazily create `not_requested` rows for terminal pre-migration meetings. The finalizer pages derived work items from loaded `MeetingDetail` metadata; it does not page those metadata rows from SQLite. The pager's first segment query is separate from its row and gap reads.

The architecture and memory documentation distinguish Phase 2 process-RSS/throughput evidence from pending T087–T094 hardware acceptance. Test/check receipts are recorded separately in `acceptance/regression.md`; no hardware acceptance is inferred from those checks.
