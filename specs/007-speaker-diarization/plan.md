# Implementation plan: speaker diarization and speaker assignment

**Branch**: `main` | **Feature identifier**: `007-speaker-diarization` | **Date**: 2026-09-18 | **Spec**: [spec.md](spec.md)

The command was invoked as `$speckit-plan 006`. Spec directory 006 is the finished Notetaker UI, and this spec records that its input was written as "Feature 006" and renumbered (spec.md, Input line). `.specify/feature.json` selects 007, so this plan is for 007. The setup script reports the feature identifier in its `BRANCH` field. The Git branch stays `main`.

## Summary

After Feature 005 publishes a `final` transcript and its ASR lease ends, `SpeakerDiarizationCoordinator` queues a run. The run executes even when the meeting window is closed.

`MeetingDiarizer` acquires a **diarization** lease from the now workload-keyed `ModelLifecycleCoordinator`, which releases ASR first. It then diarizes the system track and the microphone track separately with FluidAudio 0.15.7's offline VBx pipeline:

- windows of at most 10 minutes that never cross a stretch;
- overlap preserved;
- the microphone constrained to one local speaker unless the meeting is marked in-room.

Window clusters are reconciled across windows by in-memory centroid similarity with an "uncertain stays separate" rule. Turns are persisted on the transcript's recorded timeline.

After the lease is released, a deterministic aligner labels every final segment as a speaker, Unknown or Overlapping. Adoption happens in one transaction, which also carries earlier names and corrections over where turn overlap gives a safe match and flags the rest.

The Transcript tab then shows colored speaker labels, a speaker count, an Assign speakers sheet with quotes, merge and undo-merge, per-row speaker changes and labeled copy. When no current result exists, it falls back to the Feature 006 source labels.

Failures, cancellation, preemption by speech recognition and crashes never touch the audio, transcript, notes or the accepted result. Everything stays local, and no embedding outlives a run.

## Technical context

| Item | Decision |
| --- | --- |
| Language/version | Swift 6 language mode. The deployment target stays macOS 14.0, but diarization runs only on macOS 15+ ([research R8](research.md)) |
| Dependencies | Existing FluidAudio 0.15.7 (`OfflineDiarizerManager`, `OfflineDiarizerModels`, `ModelHub.offlineMode`), GRDB 7.10.0, SwiftUI/AppKit, AVFoundation. No new package. One new pinned model manifest (`FluidInference/speaker-diarization-coreml`, offline variant) |
| Storage | `history.sqlite`, migration `speakers-v7`: `meeting_diarization`, `diarization_runs`, `meeting_speakers`, `speaker_turns`, `speaker_assignments`, `speaker_corrections` ([data-model.md](data-model.md)). No audio or embedding files |
| Testing | XCTest with `FakeDiarizationRuntime`, the existing fake stores, clock and synthetic ADTS fixtures. The real engine is used only in the throughput harness and acceptance runs |
| Platform/type | One native macOS app. No server work, no network, no new permission |
| Performance | SC-003: relabel ≤ 1 s after Save. SC-004: RSS slope < 1 MB/10 min, post-release RSS within 20 MB of baseline. SC-005: the RTF and peak model memory gates are frozen in Phase 2 as the measured maximum × 1.5 rounded up (quickstart). Pages stay 200 rows with 2 resident |
| Constraints | Every buffer, queue and batch is bounded ([contracts/diarization-pipeline.md](contracts/diarization-pipeline.md), "Bounds summary"). One model lease at a time. No text, names, quotes, embeddings or audio in logs or metrics. Offline after provisioning |
| Scope | Post-meeting diarization, source-aware clusters, alignment, labeled transcript, naming, quotes, merge and undo, per-segment correction, carry-over on rerun, status, retry and recovery, labeled copy, settings, instrumentation. No live labels, identities, profiles, summaries or cloud |

Provisional values that Phase 2 measures before they are frozen: window length (10 min), reconciliation τ 0.70 / δ 0.10, and alignment 0.60 / 2× / 0.20. The spec's clarifications leave nothing open.

## Constitution check

Pre-research gate: pass. Post-design gate: pass. No exception is proposed. ADR 0017 records the engine choice, the workload-keyed lifecycle and the macOS 15 gate, and it amends no principle.

| Principles | Result |
| --- | --- |
| 1, 14: native client and scope | Pass. Swift/SwiftUI and the already-shipped FluidAudio. No package. One thin slice on top of 005/006. No generic plugin layer: one `DiarizationRuntime` protocol for the one engine plus its test double. Preemption restarts a run instead of adding mid-run resume state |
| 2, 6: bounded memory and streaming | Pass by design. Decoding uses 4,096 frames per track, and there is one reusable window buffer of ≤ 9.6 M samples. The engine's working set is bounded by the window length. Reconciliation state is bounded by clusters (64 per track). Turns, alignment pages, carry-over sweeps and writes are all paged. Full meeting audio is never loaded, and no temporary audio is written. SC-004/005 need hardware measurements, which are pending |
| 3: model lifecycle | Pass. `ModelLifecycleCoordinator` stays the only owner. It gains a diarization factory and workload key, and releases the resident runtime on a workload switch, so ASR and the diarizer are never co-resident (FR-032). Speech recognition preempts diarization. The diarizer is released at run end, failure or cancellation without a cooldown |
| 4, 5: offline and privacy | Pass. `ModelHub.offlineMode` is on, the loader never calls `prepareModels()`, and a missing model fails as `model_unavailable`. No data leaves the Mac. Embeddings exist only in memory during a run. Name suggestions are plain text. Logs and the recorder are content-free, and the content-free test is extended |
| 7, 9: persistence and recovery | Pass. One migration of new tables with cascades. Every transition is written before it is published. Adoption and carry-over form one transaction. Failed and interrupted runs delete only their own rows. Launch reconciliation marks running runs interrupted and re-enqueues pending ones, reading no audio. Final segment rows are never updated |
| 8: server isolation | Not exercised |
| 10: speaker attribution | Pass. Diarization only: clusters are meeting-local, and no identity or profile exists. Uncertain segments stay Unknown or Overlapping. Uncertain reconciliation stays a separate cluster. Corrections are manual, per meeting, and kept apart from machine evidence. No persistent embedding exists, so the metadata rule for stored embeddings has nothing to apply to |
| 11: structured LLM output | Not exercised |
| 12: testability | Pass. Runtime, stores, clock and lifecycle have doubles. The tests cover every run transition, cancellation, preemption, each capacity, each failure category, restart, carry-over, and preservation of transcript, notes, audio and the accepted result |
| 13: observability | Pass by design. The FR-037 metrics and the `diarizing` phase are listed in the pipeline contract. Acceptance files identify hardware, OS, build, model and pipeline version |

## Project structure

```text
specs/007-speaker-diarization/
  spec.md  plan.md  research.md  data-model.md  quickstart.md
  contracts/diarization-pipeline.md  contracts/ui.md
  acceptance/                  # implementation: throughput, accuracy, long-run-memory, naming, recovery, privacy
  tasks.md                     # next workflow; not generated by planning
Resources/Models/speaker-diarization-offline.json    # new pinned manifest (capability speaker_diarization)
apps/macos/LocalFlow/
  Core/DiarizationBoundaries.swift          # new: ModelWorkload, DiarizationRuntime, request/result, SpeakerStoring, DiarizationObserving
  Core/Models/
    ModelDescriptor.swift                   # + ModelCapability.speakerDiarization
    ModelLifecycleCoordinator.swift         # workload-keyed acquire, diarization factory, diarize(), no-cooldown finish, ASR preemption
  Core/Diarization/                         # new
    FluidAudioDiarizer.swift                # factory + runtime over OfflineDiarizerManager (offline mode, macOS 15 gate)
    DiarizationRun.swift                    # run states, transition table, failure categories, pipeline version
    MeetingDiarizer.swift                   # per-track windows over MeetingFinalizer.workItems, persistence, alignment, completion
    WindowClusterReconciler.swift           # xwin_cos_greedy_v2
    RunClusterMerge.swift                   # merge_cos0.70_v1
    SpeakerAligner.swift                    # align_dom0.60_ratio2_ovl0.20_v1
    CorrectionCarryOver.swift               # carry_ovl0.50_ratio2_v1
    QuoteSelector.swift
    DiarizationReconciler.swift             # launch reconciliation
  Core/Storage/
    HistoryMigrations.swift                 # speakers-v7
    SpeakerStore.swift                      # new actor on the shared DatabaseQueue
    MeetingStore.swift                      # insert meeting_diarization row with the meeting
    TranscriptStore.swift                   # page query variant joining the effective assignment
  Core/Observability/ResourceRecorder.swift # diarizing phase + FR-037 metrics
  App/AppServices.swift                     # ModelHub.offlineMode, second provisioner, factory, coordinator, reconciler chaining
  Features/Settings/AppPreferences.swift, SettingsView.swift   # meetingDiarizationEnabled, model row
  Features/Speakers/                        # new
    SpeakerDiarizationCoordinator.swift     # queue, triggers, status, preemption requeue, delete hook
    AssignSpeakersView.swift                # sheet
    AssignSpeakersModel.swift               # draft names, validation, suggestions, merge/unmerge
    SpeakerPalette.swift                    # 8 colors + label text rules
  Features/Transcripts/
    TranscriptPager.swift                   # labeled pages, labelsRevision, labeled copy, name search
    MeetingTranscriptionCoordinator.swift   # notify diarization after final + lease finished
  Features/Meetings/MeetingDetailView.swift # header count, Speakers menu, status line, row labels, Change speaker
apps/macos/LocalFlowTests/
  Support/DiarizationFakes.swift
  SpeakerAlignerTests, WindowClusterReconcilerTests, CorrectionCarryOverTests, QuoteSelectorTests,
  SpeakerStoreTests, MeetingDiarizerTests, SpeakerDiarizationCoordinatorTests, DiarizationReconcilerTests,
  AssignSpeakersModelTests; extended ModelLifecycleCoordinatorTests, TranscriptPagerTests,
  RuntimeCompatibilityTests (diarizer load from provisioned layout, no network), recorder content-free test
docs/adr/0017-speaker-diarization-engine-and-lifecycle.md
docs/architecture/model-lifecycle.md, storage.md, audio-pipeline.md   # diarization sections
THIRD_PARTY_NOTICES.md, docs/licenses/                                 # diarization model licences
```

Register every added source file in the Xcode project. Reuse `MeetingFinalizer.workItems`, `AnalysisStreamMixer`, `ModelProvisioner`, `ResourceRecorder`, `TranscriptPager`, the Feature 006 bubble and palette, and the confirmed-deletion path. Do not duplicate them. `MeetingFinalizer`, `LiveRecognizer`, `DictationCoordinator` and the recording path are not modified beyond the lifecycle call signature.

## Delivery sequence

1. **Measurement.** Build the manifest and provisioning, then `FluidAudioDiarizer` and `DiarizationThroughputHarness`. Measure on the reference M5 per the quickstart. Freeze the window length, τ/δ, the alignment thresholds and the SC-005 gates into `acceptance/throughput.md` and `acceptance/accuracy.md`. Write ADR 0017, and record the model licences.
2. **Lifecycle.** Add the workload key, the diarization factory, `diarize`, the switch-release, preemption, the no-cooldown finish and the Keep-ready re-prepare. Add race and exclusivity tests. The Feature 001/005 lifecycle suites must stay unchanged.
3. **Storage.** Add `speakers-v7`, `SpeakerStore` with every operation from the data model, capacity refusals, cascade tests (meeting delete, `discardPass`), atomic adoption and failure cleanup.
4. **Pure logic.** Add `SpeakerAligner`, `WindowClusterReconciler`, `CorrectionCarryOver` and `QuoteSelector`, with table-driven tests that assert determinism and every threshold edge.
5. **Run pipeline.** Add `MeetingDiarizer` with the fake runtime: windows per stretch, timeline offsets, microphone constraint, in-room mode, overflow, cancellation, transcript-changed, and each failure category with byte-identity checks.
6. **Scheduling and recovery.** Add `SpeakerDiarizationCoordinator`, the trigger from the transcription coordinator, the queue and preemption requeue, `DiarizationReconciler`, the delete hook, and the preference and Settings row.
7. **UI.** Add labeled pager pages and the stale-pass fallback, then the header count, Speakers menu, status line, row labels, Change speaker, the Assign speakers sheet and model, labeled copy and name search. Add view-model tests and native captures at wide, compact and dark sizes using synthetic records.
8. **Instrumentation and acceptance.** Add the recorder metrics and the content-free test, the debug flags, and the reference-machine 60-minute and 8-hour runs, force-quit, rerun, preemption and privacy acceptance files. Update `docs/architecture/*`. Continue through the tasks, analyze and implement workflow.

## LocalFlow constitution gates

**Bounds and overflow.** The pipeline contract's Bounds summary is normative:

- a queue of 100 deduplicated meeting ids, with automatic overflow skipped;
- one run at a time;
- one 9.6 M-sample window buffer and 4,096-frame decode buffers;
- 64 clusters per track, with overflow turns aligned as Unknown and counted;
- 20,000 turns per window and 100,000 per run, where exceeding either fails the run;
- 500-row write batches and 500-segment alignment pages;
- 1,000-turn carry-over sweep pages;
- 10,000 corrections per meeting;
- 100 reconciliation rows per launch.

Nothing is dropped silently.

**Lifecycle owner and release.** `ModelLifecycleCoordinator` is the only owner. A workload switch releases the resident runtime before preparing the other one. The diarizer is released at run end, failure, cancellation or preemption, with no cooldown. SC-004 checks post-release RSS.

**Offline and privacy.** No network path: `ModelHub.offlineMode` is on and `prepareModels()` is never called. No new permission. No embedding persists. Logs and metrics are content-free. Name suggestions are text only.

**Recovery and persistence.** Every transition is persisted before it is published. Adoption, carry-over and supersession form one transaction. Failed and interrupted runs remove only their own rows. Launch reconciliation touches rows only. Deletion cancels and joins, and foreign keys cascade.

**Dependencies and licences.** No new package. The diarization model licences are reviewed and recorded before the manifest is marked complete (research R2).

**Memory acceptance.** On the reference machine, the 60-minute run and the 8-hour synthetic concatenation are sampled every 10 s. The report gives baseline, model-load increase, peak, slope (gate < 1 MB/10 min), post-release RSS (gate ≤ baseline + 20 MB), RTF and window count, with hardware, OS, build, model and pipeline version. These remain unmeasured until recorded. Short fixtures and unit tests are not evidence of bounded operation.

**Test strategy.** Deterministic XCTest with fakes covers every requirement below. The real engine is used only in the harness and acceptance runs. The Feature 001–006 suites are the SC-009 regression gate.

## Validation and requirement coverage

| Requirements | Primary validation |
| --- | --- |
| FR-001, FR-013 | The aligner API takes turns and segment times only. A test asserts that segment text and timing are unchanged |
| FR-002, FR-003 | Coordinator tests: automatic on and off, manual always available, runs with no view open, cancel joins, restart via reconciler |
| FR-004, FR-005 | The run records `inferred_speaker_count`. The fake runtime covers 1–8 clusters. There is no count input |
| FR-006 | No live-path change. Live rows are unlabeled (UI test) |
| FR-007–FR-009 | Pipeline tests: separate tracks, source recorded per cluster and turn, microphone `numSpeakers = 1` by default and unconstrained in-room, the toggle triggers a rerun |
| FR-010–FR-012 | Store tests: overlapping turns accepted. Quality is stored only when the engine provides it, labeled as engine quality |
| FR-014, FR-015 | Aligner threshold-edge tables. Evidence columns are persisted. Thresholds are confirmed in `acceptance/accuracy.md` |
| FR-016–FR-020 | Pager and view-model tests (labels, colors, count, paging bounds, stale fallback, search, copy). Native captures |
| FR-021–FR-026 | Assign speakers model tests. Store transaction tests. Restart persistence. Automatic evidence kept |
| FR-027 | Carry-over tests: safe maps, unsafe flagged, never guessed |
| FR-028 | Suggestions are plain text. No identity table exists (schema test) |
| FR-029–FR-031; SC-006 | The run transition table test. Fault-injection tests for each category: transcript, notes, audio and accepted run byte-identical. Force-quit acceptance |
| FR-032, FR-033; SC-004, SC-005 | Lifecycle exclusivity tests. Bounds tests. Reference-machine runs in `acceptance/throughput.md` and `long-run-memory.md` |
| FR-034, FR-035 | Migration and cascade tests. A file-system and SQL search after deletion |
| FR-036; SC-008 | No networking symbols in the diarization module. Offline-mode assertion. Privacy acceptance |
| FR-037 | Recorder metric tests and the content-free test |
| FR-038; SC-009 | Feature 001–006 suites unchanged. With diarization off or not run, the UI renders exactly as in Feature 006 |
| SC-001, SC-002 | `acceptance/accuracy.md` over the RTTM fixtures |
| SC-003 | UI timing in `acceptance/naming.md` (four speakers named in under 1 min, relabel ≤ 1 s) |
| SC-007 | Restart tests for names, merges and corrections, with turns and automatic assignments retrievable |

## Risks

- **macOS 14 BNNS crash** in Core ML predictions (FluidAudio #878). Mitigated by the macOS 15 gate. Revisit if FluidAudio ships a workaround.
- **Preemption starvation** with very frequent dictation during a long run, because a preempted run restarts. The preemption count is recorded. Add per-window resume only if acceptance shows the problem.
- **Microphone bleed** of remote voices when speakers are used instead of headphones produces Overlapping labels. This is reported, not claimed as solved.
- **Window-boundary errors** (a turn split at a window edge, or a speaker unmatched across windows). Uncertain matches stay separate and the user can merge them. Consider overlapping windows if accuracy acceptance shows boundary loss.

## Complexity tracking

No constitution violations to justify.
