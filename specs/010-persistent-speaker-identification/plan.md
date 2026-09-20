# Implementation plan: persistent speaker identification

**Branch**: `main` | **Feature identifier**: `010-persistent-speaker-identification` | **Date**: 2026-09-20 | **Spec**: [spec.md](spec.md)

The command was invoked as `$speckit-plan 010`. `.specify/feature.json` selects this directory and the setup script reports the identifier in its `BRANCH` field. The Git branch stays `main`, as for 007–009.

## Summary

After Feature 007 adopts a diarization result and releases its model, `SpeakerIdentificationCoordinator` queues an identification run. `MeetingIdentifier` loads the known-speaker library, and when at least one recognition-enabled profile has a compatible sample it acquires a new `speakerIdentification` lease from `ModelLifecycleCoordinator`. The runtime is `FluidAudioVoiceEmbedder`, which reuses the already provisioned diarization model files (WeSpeaker 256-d) through FluidAudio 0.15.7's single-speaker offline pipeline, so no new model, manifest, download or licence is added.

For each remote display root the identifier selects a few clean single-speaker regions from the accepted turns, decodes them one at a time from the durable ADTS tracks, embeds each, releases the lease, then scores the root against every profile with the pure `IdentityMatcher`. Calibrated thresholds and a margin decide Recognized, Possible match or Unknown; every candidate score and reason is stored for audit. Adoption is one transaction that replaces automatic rows and never touches manual decisions.

Enrollment is explicit: after naming a speaker the sheet offers Remember or Not now; Remember creates a profile and stores per-region embeddings with the consent that created them. Confirming a suggestion or correcting to another profile adds samples only with "Also remember this voice sample" on. Known speakers are managed in Settings with rename, per-speaker recognition, sample removal and hard delete that leaves copied names behind. A one-time prompt after enrollment can search past meetings that still have Unknown remote speakers, one meeting at a time.

Nothing here alters transcript text, timing, turns or audio. Everything stays on the Mac.

## Technical context

| Item | Decision |
| --- | --- |
| Language/version | Swift 6 language mode; deployment target macOS 14.0. Embedding runs only on macOS 15+ behind the same gate diarization uses (FluidAudio #878), so identification on macOS 14 fails `os_unsupported` and changes nothing else |
| Dependencies | Existing FluidAudio 0.15.7 (`OfflineDiarizerModels`, `OfflineDiarizerManager`, `ChunkEmbedding`), GRDB 7.10.0, SwiftUI/AppKit, AVFoundation. No new package, model or manifest ([research R1](research.md)) |
| Storage | `history.sqlite`, migration `identities-v8`: `known_speakers`, `voice_samples`, `meeting_identification`, `identification_runs`, `identity_assignments`, `match_candidates`, `rejected_candidates` ([data-model.md](data-model.md)). Vectors are 1 KB BLOBs; no audio or vector files |
| Testing | XCTest with `FakeVoiceEmbeddingRuntime`, `FakeIdentityStore`, the 007 fakes, clock and synthetic ADTS fixtures. The real model is used only in `IdentificationCalibrationHarness` and acceptance runs |
| Platform/type | One native macOS app. No server work, no network, no new permission |
| Performance | SC-008: ≤ 60 s for a 60-minute, 6-speaker meeting with 100 profiles after diarization on the reference M5. SC-009: post-release RSS within the diarization-free baseline + 20 MB. Enrollment for one cluster ≤ 15 s. All measured in Phase 2, not assumed |
| Constraints | Every queue, region, buffer, table and candidate set is bounded ([contracts/identification-pipeline.md](contracts/identification-pipeline.md) "Bounds summary"). One heavy model at a time, identification after diarization. No names, vectors, times, audio or text in logs, metrics or exports. Offline after provisioning |
| Scope | Consented enrollment, per-region samples with model identity, calibrated three-tier matching with margin and support, assignment origin and audit, confirm/correct/reject, known-speaker picker and duplicate handling, Settings management and sample list, rerun, past-meeting search, merge rule, deletion semantics, local-voice enrollment (evidence only), instrumentation. No summaries, echo suppression, cloud, vector index or automatic backfill |

Provisional values frozen in Phase 2 (calibration and measurement): τ_high 0.72 / τ_medium 0.55 / δ 0.10, minimum support 2, minimum query speech 6 s, region 3–20 s, engine quality ≥ 0.5, clipping 0.1% at 0.99, quiet −45 dBFS, 5/100 s enrollment and 4/60 s query limits, cap 10 active + 10 retired samples. The spec's clarification session left nothing open; the 22 assumptions it listed are each settled in research.md.

## Constitution check

Pre-research gate: pass. Post-design gate: pass. No exception is proposed. ADR 0020 records the embedding reuse, the fourth workload and the storage of vectors in SQLite; it amends no principle.

| Principles | Result |
| --- | --- |
| 1, 14: native client and scope | Pass. Swift/SwiftUI over the shipped FluidAudio. No package, model or manifest. One `VoiceEmbeddingRuntime` protocol with one implementation and one double. No vector index, no generic profile platform, no automatic backfill. Thin slice on 007 |
| 2, 6: bounded memory and streaming | Pass by design. One region (≤ 1.25 MB) resident during extraction, 4,096-frame decode buffers, sequential single-pass decoding with no seek. Profiles are ≤ 10 MB at the 1,000-speaker cap and released at run end. Candidate rows are bounded and pruned. Full meeting audio is never loaded. SC-008/009 need hardware measurements, pending |
| 3: model lifecycle | Pass. `ModelLifecycleCoordinator` stays the only owner; it gains a factory, a resident case and `embed`. Speech workloads preempt identification; identification never preempts; the embedder is released at run end, failure, cancellation and preemption. Identification runs only after the diarization coordinator reports adoption, so the two are never resident together |
| 4, 5: offline and privacy | Pass. The embedder loads from the verified local directory with `ModelHub.offlineMode` on and never calls a download path. Samples, names and comparisons stay in `history.sqlite`; nothing reaches the control server, the LLM server or logs. The enrollment offer states what is stored, and no sample exists without an explicit Remember action; the consent value is stored on each sample |
| 7, 9: persistence and recovery | Pass. One migration of new tables with cascades and CHECKs. Every run transition is written before it is published. Adoption, enrollment and deletion are single transactions. Failed and interrupted runs delete only their candidates. Launch reconciliation marks running runs interrupted and re-enqueues pending ones without reading audio. The past-search queue is memory-only by design and is not "lost data" |
| 8: server isolation | Not exercised |
| 10: speaker attribution | Pass. Diarization and identification stay separate tables, runs and models. Uncertain matches stay Possible or Unknown and are correctable; nearest candidates below the tier are never shown. Every stored vector carries engine, model id, revision, manifest hash, dimension, pipeline version, quality and creation date; incompatible vectors are never compared |
| 11: structured LLM output | Not exercised. The read models carry state and origin so the future summary feature can filter (FR-021) |
| 12: testability | Pass. Runtime, store, reader, clock and lifecycle have doubles. Tests cover every run transition, preemption, cancellation, each capacity, each failure category, restart, consent paths, correction paths, deletion cascades and preservation of transcript, diarization and manual assignments |
| 13: observability | Pass by design. Content-free metrics and phases listed in research R14; acceptance files identify hardware, OS, build, model revision and policy version |

## Project structure

```text
specs/010-persistent-speaker-identification/
  spec.md  plan.md  research.md  data-model.md  quickstart.md
  contracts/identification-pipeline.md  contracts/ui.md
  acceptance/                  # implementation: calibration, throughput, memory, consent-and-privacy, recovery, regression
  tasks.md                     # next workflow; not generated by planning
apps/macos/LocalFlow/
  Core/DiarizationBoundaries.swift              # + ModelWorkload.speakerIdentification
  Core/IdentificationBoundaries.swift           # new: VoiceRegionRequest, VoiceEmbedding, VoiceEmbeddingRuntime, IdentityStoring, IdentificationObserving
  Core/Models/ModelLifecycleCoordinator.swift   # voice embedding factory, Resident.embedding, embed(), preemption parity with diarization
  Core/Identification/                          # new
    FluidAudioVoiceEmbedder.swift               # factory + runtime over OfflineDiarizerModels, single-speaker manager, chunk mean
    IdentificationRun.swift                     # run states, triggers, failure categories, VoiceModelIdentity, pipeline/policy versions
    IdentificationThresholds.swift              # tiers_v1 values keyed by model identity (frozen in Phase 2)
    VoiceRegionSelector.swift                   # regions_v1
    VoiceRegionReader.swift                     # single-pass stretch decoding, one region resident
    IdentityMatcher.swift                       # tiers_v1 scoring and decision
    SampleRetirementPolicy.swift                # retire_qd_v1
    MergedIdentityRule.swift                    # FR-026a effective identity
    MeetingIdentifier.swift                     # run pipeline
    EnrollmentJob.swift                         # profile + samples with consent
    IdentificationReconciler.swift              # launch reconciliation
  Core/Diarization/CorrectionCarryOver.swift    # carry manual identity rows with safe name maps
  Core/Storage/
    HistoryMigrations.swift                     # identities-v8
    IdentityStore.swift                         # new actor on the shared DatabaseQueue
    MeetingStore.swift                          # insert meeting_identification with the meeting
    SpeakerStore.swift                          # summaries joined with identities; unmerge clears merged resolution
    TranscriptStore.swift                       # page query variant joining effective identity for "Name?" rows
  Core/Observability/ResourceRecorder.swift     # identification phases and metrics
  App/AppServices.swift                         # embedder factory over the diarization provisioner, coordinator, reconciler, delete hook chaining
  Features/Settings/AppPreferences.swift, SettingsView.swift   # speakerIdentificationEnabled, Known speakers section
  Features/Speakers/
    SpeakerDiarizationCoordinator.swift         # publish diarizationDidAdopt after lease finish + adoption
    SpeakerIdentificationCoordinator.swift      # new: queue, triggers, enrollment jobs, past search, status
    AssignSpeakersModel.swift, AssignSpeakersView.swift   # identity block, Remember/Not now, picker, duplicate choice, suggestion actions, merge prompt
    KnownSpeakersModel.swift, KnownSpeakersView.swift     # new: Settings list, sample list
  Features/Transcripts/TranscriptPager.swift    # identity labels, identityRevision
  Features/Meetings/MeetingDetailView.swift     # "Name?" confirm control, Rerun identification, status line, past-search prompt
apps/macos/LocalFlowTests/
  Support/IdentificationFakes.swift             # FakeVoiceEmbeddingRuntime, FakeIdentityStore, vector fixtures
  VoiceRegionSelectorTests, IdentityMatcherTests, SampleRetirementPolicyTests, MergedIdentityRuleTests,
  IdentityStoreTests, VoiceRegionReaderTests, MeetingIdentifierTests, EnrollmentJobTests,
  SpeakerIdentificationCoordinatorTests, IdentificationReconcilerTests, KnownSpeakersModelTests,
  IdentificationCalibrationHarness (skipped without LOCALFLOW_CALIBRATION_ROOT);
  extended ModelLifecycleCoordinatorTests, CorrectionCarryOverTests, TranscriptPagerTests,
  AssignSpeakersModelTests, SettingsTests, ResourceRecorderTests, RuntimeCompatibilityTests, NativePresentationTests
docs/adr/0020-persistent-speaker-identification.md
docs/architecture/model-lifecycle.md, storage.md                       # identification sections
```

Register every added source file in the Xcode project. Reuse `AnalysisStreamMixer`, `MeetingFinalizer.workItems` and stretch bases, `ModelProvisioner` and the diarization descriptor, `ResourceRecorder`, `TranscriptPager`, `SpeakerNames`, the 007 sheet, palette and merge path, and the confirmed-deletion chain. Do not duplicate them. `MeetingDiarizer`, `MeetingFinalizer`, `LiveRecognizer` and the recording path are not modified beyond the one adoption notification and the lifecycle signature.

## Delivery sequence

1. **Boundaries and lifecycle.** Add `IdentificationBoundaries`, the workload, the factory and `embed`, with exclusivity, preemption and no-cooldown tests. Feature 001/005/007 lifecycle suites must stay unchanged.
2. **Embedder and calibration harness.** Build `FluidAudioVoiceEmbedder` over the provisioned models and the `IdentificationCalibrationHarness`. Run it on the reference M5 against the calibration corpus. Freeze τ_high, τ_medium, δ, support and minimum-speech values into `IdentificationThresholds` and record `acceptance/calibration.md`. Write ADR 0020.
3. **Storage.** Add `identities-v8` and `IdentityStore` with every operation of the contract, capacity refusals, cascade and deletion matrix tests, atomic adoption, failed-run cleanup, revision checks.
4. **Pure logic.** `VoiceRegionSelector`, `IdentityMatcher`, `SampleRetirementPolicy`, `MergedIdentityRule` with table-driven tests at every threshold edge and determinism checks.
5. **Reader and run pipeline.** `VoiceRegionReader`, `MeetingIdentifier` and `EnrollmentJob` with the fake runtime: zero-candidate short circuit, region accounting, each failure category with byte-identity checks, preemption, cancellation, manual preservation, consent paths, FR-007 refusal.
6. **Scheduling and recovery.** `SpeakerIdentificationCoordinator`, the adoption trigger from the diarization coordinator, the global setting short circuit, enrollment queueing, the past-search queue, `IdentificationReconciler`, the delete hook, `AppPreferences`.
7. **UI.** Pager identity labels and "Name?" confirm control, the Assign speakers identity block with all actions and the duplicate and merge prompts, the Rerun item and status line, the past-search prompt, Settings › Known speakers with the sample list. View-model tests and native captures.
8. **Instrumentation and acceptance.** Recorder metrics and the content-free test, `docs/architecture/*`, then the reference-machine throughput, memory, consent-and-privacy, recovery and regression files. Continue through tasks, analyze and implement.

## LocalFlow constitution gates

**Bounds and overflow.** The pipeline contract's Bounds summary is normative: a 100-id identification queue and a 500-id past-search queue, one run at a time; 3–20 s regions, 5 per enrollment and 4 per query root, one region resident; ≤ 1,000 profiles × 10 active samples in memory per run; ≤ 64,000 candidate rows per run (`persistence_capacity` above); 10 active + 10 retired samples per profile per model; 1,000 known speakers; 1,000 rejected pairs per meeting; 500-row rename batches. Every overflow is counted or refused with a notice; nothing is dropped silently.

**Lifecycle owner and release.** `ModelLifecycleCoordinator` is the only owner. Identification acquires its own `speakerIdentification` lease only after the diarization coordinator has finished its lease and committed adoption. A workload switch releases the resident runtime first. The embedder is released at run end, failure, cancellation and preemption with no cooldown. SC-009 checks post-release RSS.

**Offline and privacy.** The embedder loads from the verified diarization directory with `ModelHub.offlineMode` on; no download path exists. No new permission. Samples, candidates and assignments live in `history.sqlite` only, outside preferences, exports and logs. Diagnostics carry counts and durations. Each sample records the consent action that created it, and no code path creates a sample without one (enrollment tests assert zero rows after Not now, Confirm without the toggle, and automatic runs).

**Recovery and persistence.** Every transition is persisted before it is published. Adoption, enrollment, deletion and rename are single transactions. Failed and interrupted runs delete only their candidate rows. Launch reconciliation touches rows only. Meeting deletion cancels and joins the active run, drops the meeting from both queues, and lets foreign keys cascade; sample provenance is nulled, never the sample.

**Dependencies and licences.** No new package, model or manifest. The diarization model licence recorded for 007 covers the embedding files used here; ADR 0020 says so explicitly.

**Memory acceptance.** On the reference machine a 60-minute, 6-speaker run against 10, 50 and 100 profiles, and one enrollment, are sampled every 10 s. The report gives baseline, model-load increase, peak, post-release RSS (gate ≤ baseline + 20 MB), extraction, comparison and adoption durations (gate ≤ 60 s total), with hardware, OS, build, model revision and policy version. These stay unmeasured until recorded.

**Test strategy.** Deterministic XCTest with fakes covers every requirement below. The real model is used only in the calibration harness and acceptance runs. The Feature 001–009 suites with the setting off are the SC-010 regression gate.

## Validation and requirement coverage

| Requirements | Primary validation |
| --- | --- |
| FR-001, FR-002; SC-005, SC-011 | `EnrollmentJobTests` (Not now writes nothing), `AssignSpeakersModelTests` (offer copy, three interactions), consent acceptance |
| FR-003, FR-004 | `VoiceRegionSelectorTests` (overlap, minimum, trim, spread, audio checks) |
| FR-005, FR-006, FR-027 | `IdentityStoreTests` (per-region rows, cap in one transaction, metadata CHECKs), `SampleRetirementPolicyTests` |
| FR-007, FR-008; SC-006 | `EnrollmentJobTests` and `IdentityStoreTests.rejectedSource`; toggle default off in the view-model test; automatic runs never call `addSamples` (identifier test) |
| FR-009–FR-014; SC-001–SC-004 | `IdentityMatcherTests` threshold tables; `acceptance/calibration.md`; no numeric label in any read model (pager and view-model tests) |
| FR-015, FR-038, FR-039; SC-010 | Coordinator short-circuit tests, `SettingsTests` default on, disabled profile excluded in matcher and store tests, Feature 001–009 suites with the setting off |
| FR-016, FR-017 | Identifier tests: "You" never queried; local profile tier `local_evidence` only |
| FR-018–FR-021 | Store CHECKs and tests for state/origin pairs; candidate rows per run; rejected pairs excluded on rerun; read models carry state and origin |
| FR-022 | Lifecycle tests and the coordinator trigger test (identification after adoption, never during a diarization lease) |
| FR-023, FR-023a | Identifier rerun test (no transcription or diarization call); coordinator past-search tests (prompt once, Unknown-only meetings, order, skip, cancel, memory-only) |
| FR-024, FR-025; SC-007 | Adoption transaction tests: automatic replaced, manual kept, failure leaves previous rows and transcript byte-identical |
| FR-026 | Identifier and store tests assert no write to transcript, turn or audio tables (schema diff before/after) |
| FR-026a | `MergedIdentityRuleTests`, store merge/unmerge tests, sheet prompt test |
| FR-028, FR-029 | Store compatibility filter tests; profile state derivation; model-change test keeps old rows |
| FR-030–FR-033; SC-012 | Deletion matrix tests: zero referencing rows, copied names, nulled provenance, transcript sum unchanged |
| FR-034–FR-037 | No networking symbols in `Core/Identification`; offline-mode assertion; recorder content-free test; export path tests unchanged; privacy acceptance |
| FR-040–FR-043 | Pager label tests, view-model tests, `KnownSpeakersModelTests`, native captures |
| SC-008, SC-009 | `acceptance/throughput.md`, `acceptance/memory.md` |

## Risks

- **Threshold generalization.** The calibration corpus is small and internal; thresholds tuned on it may be optimistic on other microphones and languages. Mitigation: the margin and support conditions, conservative τ_high, and the corpus requirement of several devices and days per speaker. Revisit with PLDA scoring or CAM++ (research R1, R6) if SC-001 or SC-003 fail.
- **Single-speaker pipeline on short regions.** The offline segmentation model is tuned for 10 s windows; 3 s regions may yield weak embeddings. Mitigation: the calibration harness reports score spread by region length; raise the minimum if 3 s regions hurt.
- **Enrollment latency in the sheet.** Enrollment needs a model load after Save. Mitigation: profile and link commit first, the sheet reports progress, and Keep-ready re-prepare is unchanged. Measured in Phase 2.
- **Preemption starvation** by frequent dictation during a past search. A preempted run restarts from its first region (no mid-run state); the count is recorded, and the queue can be cancelled.
- **Name copies drift** if a rename batch is interrupted. The rename is one transaction; a crash rolls it back entirely.

## Complexity tracking

No constitution violations to justify.
