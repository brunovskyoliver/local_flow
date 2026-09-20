---

description: "Task list for Feature 010 — persistent speaker identification"
---

# Tasks: Persistent speaker identification

**Input**: Design documents from `/specs/010-persistent-speaker-identification/`

**Prerequisites**: plan.md, spec.md, research.md, data-model.md, contracts/identification-pipeline.md, contracts/ui.md, quickstart.md

**Tests**: Included. The plan's test strategy and the quickstart name the XCTest suites `make check` must run, and constitution principle 12 requires them. Write each story's tests first and confirm they fail before implementing.

**Organization**: Tasks are grouped by user story so each story can be implemented and tested on its own.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependency on an unfinished task)
- **[Story]**: The user story the task serves (US1–US7)
- Paths are relative to the repository root. App sources live under `apps/macos/LocalFlow/`, tests under `apps/macos/LocalFlowTests/`
- Every new Swift file must be registered in `apps/macos/LocalFlow.xcodeproj/project.pbxproj` in the same task that creates it

## Provisional values

τ_high 0.72 / τ_medium 0.55 / δ 0.10, minimum support 2, minimum query speech 6 s, region 3–20 s with 0.2 s trim, engine quality ≥ 0.5, clipping 0.1% at |x| ≥ 0.99, quiet −45 dBFS, 5 regions / 100 s for enrollment and 4 regions / 60 s for a query, cap 10 active + 10 retired samples per speaker per model identity. Implement each as a named constant that feeds the `regions_v1`, `tiers_v1` or `retire_qd_v1` version string. T014 freezes the thresholds from the calibration corpus; T091 freezes the rest from measurement. No task may claim a measured value before its acceptance file records it.

## Vocabulary guard

Four ideas stay separate in every type and column name: meeting-local speaker (`meeting_speakers`, 007), known speaker (`known_speakers`), identity assignment (`identity_assignments`), and origin/certainty (columns of that row plus `match_candidates`). No task may collapse them into one name string, and no read model may carry a raw score to the UI.

---

## Phase 1: Setup (shared infrastructure)

**Purpose**: Acceptance scaffolding, the ADR and the calibration-corpus documentation.

- [X] T001 Create `specs/010-persistent-speaker-identification/acceptance/` with `calibration.md`, `throughput.md`, `memory.md`, `consent-and-privacy.md`, `recovery.md` and `regression.md`, each containing only a heading and the status line "Unmeasured"
- [X] T002 [P] Write `docs/adr/0020-persistent-speaker-identification.md` (reuse of the provisioned WeSpeaker ResNet34-LM 256-d embedding through FluidAudio's single-speaker offline pipeline, the fourth `speakerIdentification` workload under the same lifecycle rules, vectors as 1 KB BLOBs in `history.sqlite`, no SQLCipher, the 007 model licence covering the embedding files, no new package or manifest) and list it in `docs/adr/README.md`
- [X] T003 [P] Document the calibration corpus in `fixtures/audio/README.md`: at least 8 consenting speakers each in ≥ 3 recordings on different days or devices, plus the 007 synthetic RTTM meetings, a manifest mapping recording → speaker, the `LOCALFLOW_CALIBRATION_ROOT` variable, and the rule that the corpus stays outside git

---

## Phase 2: Foundational (blocking prerequisites)

**Purpose**: Boundaries, lifecycle workload, embedder, calibration harness, thresholds, schema, store, region selection, retirement policy and the region reader. Every user story depends on this phase.

**⚠️ CRITICAL**: No user story work can begin until this phase is complete. T014 needs the reference machine and the calibration corpus; story work may proceed on provisional thresholds while it is pending.

### Boundaries and lifecycle (delivery step 1)

- [X] T004 Add `case speakerIdentification` to `ModelWorkload` in `apps/macos/LocalFlow/Core/DiarizationBoundaries.swift` and adjust every exhaustive switch that the compiler flags; the 001/005/007 lifecycle suites must stay unchanged
- [X] T005 Create `apps/macos/LocalFlow/Core/IdentificationBoundaries.swift` exactly as in `contracts/identification-pipeline.md`: `VoiceRegionRequest` (`minSamples = 48_000`, `maxSamples = 320_000`, "Mono 16 kHz, minSamples...maxSamples, all finite", `isValid`), `VoiceEmbedding` (`dimension = 256`, "L2-normalized, `dimension` finite values", `speechSeconds`, `isValid`), `VoiceEmbeddingFailure` (`noSpeech`), `VoiceEmbeddingRuntime` (`embed`, `shutdown`), `VoiceEmbeddingFactory`, `VoiceRegion` (track, `startMs`, `endMs`, `engineQuality`), `CandidateProfile`, `QueryRegion`, `VoiceSampleDraft`, `MatchCandidateDraft`, `IdentityStoring`, `IdentificationObserving`, and the read models `SpeakerIdentity` (`state`, `origin`, `knownSpeakerID?`, `knownSpeakerName?`, `secondCandidate?`, `needsChoice`, `sampleOfferAvailable`), `SegmentIdentity` (`named`, `suggested(name)`, `unknown`), `KnownSpeakerRow`, `VoiceSampleRow` (never a vector or score), `IdentificationStatus`. Every value `Sendable`; no FluidAudio import
- [X] T006 Create `apps/macos/LocalFlow/Core/Identification/IdentificationRun.swift` with run states (`pending`, `running`, `succeeded`, `failed`, `interrupted`, `superseded`), triggers (`automatic`, `manual`, `retry`, `past_search`, `sample_change`), failure categories (`model_unavailable`, `os_unsupported`, `model_load_failure`, `audio_missing`, `audio_decode_failure`, `runtime_failure`, `diarization_changed`, `persistence_failure`, `persistence_capacity`, `interrupted`), `IdentityState` (`recognized`, `possible`, `confirmed`, `rejected_unknown`, `unknown`), `IdentityOrigin` (`automatic_match`, `user_confirmation`, `manual_profile_selection`, `new_profile_created`, `manual_correction`, `kept_unknown`), `SampleConsent` (`remember`, `also_remember`, `local_enroll`), `CandidateTier` (`recognized`, `possible`, `below`, `local_evidence`), `CandidateReason` (`below_medium`, `margin`, `support`, `min_speech`, `rejected`, `disabled`), `VoiceModelIdentity` (engine, model id, revision, manifest hash, dimension; compatibility = equality on engine, model id, revision and dimension per FR-028), the transition table from data-model.md, the derived meeting-level state (same rule as `DiarizationRunLifecycle.meetingState`), and the pipeline version builder (≤ 256 bytes, e.g. `embed_offline1spk_dw_v1+regions_v1`)
- [X] T007 [P] Create `apps/macos/LocalFlowTests/Support/IdentificationFakes.swift`: `FakeVoiceEmbeddingRuntime` (scripted vectors per call, records every request, failure injection at region N, `noSpeech` result, delay), `FakeVoiceEmbeddingFactory`, `FakeIdentityStore`, vector fixtures (unit vectors with controlled pairwise cosine for same-person and different-person cases), a `VoiceModelIdentity` fixture, and helpers that build accepted diarization runs with turns per root on top of `DiarizationFakes.swift` and `MeetingFakes.swift`
- [X] T008 [P] Add identification lifecycle cases to `apps/macos/LocalFlowTests/ModelOwnershipTests.swift` and `apps/macos/LocalFlowTests/ModelCooldownTests.swift`: a workload switch releases the diarizer (or ASR) before the embedder prepares and the two are never resident together; an identification `acquire` throws `busy` while any owner exists and never preempts; a speech-recognition `acquire` preempts an identification lease through `cancelAndJoin` and joins the in-flight `embed`; `finish` releases with no cooldown; Keep model ready re-prepares ASR afterwards; `embed` on a non-identification lease throws `staleLease`; `embed` validates `request.isValid` and `result.isValid` and allows one in-flight call. Existing 001/005/007 cases stay unchanged
- [X] T009 Extend `apps/macos/LocalFlow/Core/Models/ModelLifecycleCoordinator.swift` with `init(… voiceEmbeddingFactory:)`, `Resident.embedding(any VoiceEmbeddingRuntime)`, `embed(_ lease:, region:)` guarded by owner, `.active`, resident workload `.speakerIdentification`, one in-flight call and both `isValid` checks; speech workloads preempt identification exactly as diarization; identification never preempts; release at run end, failure, cancellation and preemption with no cooldown. Add phases `modelLoading(identification)`, `modelActive(identification)`, `modelReleasing(identification)` and `identifying` in `apps/macos/LocalFlow/Core/Observability/ResourceRecorder.swift`. Make T008 pass

### Embedder, calibration harness and thresholds (delivery step 2)

- [X] T010 Implement `FluidAudioVoiceEmbedderFactory` and `FluidAudioVoiceEmbedder` in `apps/macos/LocalFlow/Core/Identification/FluidAudioVoiceEmbedder.swift` per research R1: refuse unless `ModelHub.offlineMode` is true, fail `os_unsupported` below macOS 15, verify the pinned diarization descriptor like `FluidAudioDiarizerFactory`, load `OfflineDiarizerModels.load(from:)` from the provisioned diarization directory, run `OfflineDiarizerManager` with `clustering.numSpeakers = 1`, `exposeChunkEmbeddings = true`, `postProcessing.exclusiveSegments = false` over one region at a time, reduce the dominant cluster's `ChunkEmbedding.embedding256` values to a duration-weighted L2-normalized mean, report `speechSeconds`, map no speech to `VoiceEmbeddingFailure.noSpeech`, never call a download path, and expose the `VoiceModelIdentity` (`engine = wespeaker_resnet34lm_256`, `model_id = FluidInference/speaker-diarization-coreml`, the manifest `sourceRevision`, the manifest SHA-256, `dimension = 256`)
- [X] T011 [P] Extend `apps/macos/LocalFlowTests/RuntimeCompatibilityTests.swift`: the embedder loads from the provisioned diarization directory with no network, refuses when offline mode is off, a missing file fails `model_unavailable` without a download, macOS 14 maps to `os_unsupported`, and the reported identity matches the manifest (skip real-model cases when the model is not provisioned, as the diarizer cases do)
- [X] T012 [P] Create `apps/macos/LocalFlowTests/IdentificationCalibrationHarness.swift`: skipped without `LOCALFLOW_CALIBRATION_ROOT`; enrolls each corpus speaker from one recording through `VoiceRegionSelector` and the real embedder, queries every other cluster, and writes same-person and different-person score distributions, false-accept and miss rates at candidate `τ_high`/`τ_medium`, margin sensitivity, score spread by region length, hardware, macOS, build, model revision and policy version, in the shape `acceptance/calibration.md` expects
- [X] T013 Create `apps/macos/LocalFlow/Core/Identification/IdentificationThresholds.swift` (`high`, `medium`, `margin`, `minSupport`, `minQuerySpeechMs`, `policyVersion` = `tiers_v1@<engine>/<revision8>`, `static func current(for:) -> IdentificationThresholds?` keyed by `VoiceModelIdentity`, returning nil for an unknown identity) with the provisional values 0.72 / 0.55 / 0.10 / 2 / 6_000 for the WeSpeaker identity. No UI code may read these values
- [ ] T014 On the reference M5 32 GB (macOS 15+), run T012 against the calibration corpus, record the distributions and chosen values in `specs/010-persistent-speaker-identification/acceptance/calibration.md` (τ_high = smallest value with zero different-person automatic acceptance and ≥ 0.05 above the highest different-person score; τ_medium chosen for SC-002 ≥ 70% and SC-003 < 5%), freeze them in `IdentificationThresholds.swift`, raise the 3 s region minimum if short regions hurt, and note in `plan.md` whether PLDA or CAM++ needs a follow-up (research R6)

### Storage (delivery step 3)

- [X] T015 [P] Create `apps/macos/LocalFlowTests/IdentityStoreTests.swift` with schema and core tests: `identities-v8` migrates a Feature 007 database, inserts one `meeting_identification` row per existing meeting and alters no 004–007 table; create/rename/setRecognition/delete known speakers with `revisionMismatch` on a stale revision; the `is_local_user = 1` partial unique index rejects a second local profile; create refuses beyond 1,000 known speakers with `capacity`; `addSamples` stores one row per region with the model identity, quality, track, times, source and consent, enforces `length(vector) = dimension * 4`, applies the 10-active cap and retirement in one transaction, keeps at most 10 retired rows, refuses `rejectedSource`; `profiles(compatibleWith:)` excludes disabled, incompatible-model and zero-sample profiles; the partial unique index rejects a second `pending`/`running` run per meeting; admit/start/appendCandidates/complete/fail/interrupt/requeue/cancel follow the transition table; `complete` adopts atomically, supersedes the previous run and deletes its `match_candidates`; a failed or interrupted run deletes only its own candidates and leaves assignments byte-identical; more than 64,000 candidate rows fails `persistence_capacity` before writing; restart persistence
- [X] T016 Register migration `identities-v8` in `apps/macos/LocalFlow/Core/Storage/HistoryMigrations.swift` creating `known_speakers`, `voice_samples`, `meeting_identification`, `identification_runs`, `identity_assignments`, `match_candidates` and `rejected_candidates` exactly as in data-model.md, including: `display_name` "TEXT NOT NULL, the `SpeakerNames` rules (1–80 scalars, trimmed, no control characters)"; `recognition_enabled` "INTEGER 0/1, default 1"; `revision` "INTEGER ≥ 0"; `model_manifest_hash` "TEXT NOT NULL, 64 hex"; `dimension` "INTEGER NOT NULL, CHECK 1…4096"; `pipeline_version` "TEXT ≤ 256 B"; `vector` "BLOB NOT NULL, CHECK `length(vector) = dimension * 4`"; `quality_label` "`good`, `fair`"; `quality_score` "REAL, CHECK 0…1"; `speech_ms` "INTEGER > 0"; `start_ms, end_ms` "CHECK `end_ms > start_ms`"; `source_meeting_id` and `source_speaker_id` "ON DELETE SET NULL"; `consent` "`remember`, `also_remember`, `local_enroll`"; `retired_at` "CHECK `(retired_at IS NOT NULL) = (active = 0)`"; `failure_category` "CHECK non-null ⇔ state ∈ (failed, interrupted)"; `failure_detail` "TEXT ≤ 512 B, content-free"; the partial unique index on `(meeting_id) WHERE state IN ('pending','running')`; `scope` "`self`, `merged`; UNIQUE `(meeting_speaker_id, scope)`"; `score` "REAL NULL, CHECK −1…1; NOT NULL for `recognized` and `possible`"; the assignment CHECKs "`state IN ('recognized','possible','confirmed') = (known_speaker_id IS NOT NULL)`; `state IN ('recognized','possible') → origin = 'automatic_match'`; `state = 'confirmed' → origin IN ('user_confirmation','manual_profile_selection','new_profile_created','manual_correction')`; `state = 'rejected_unknown' → origin = 'kept_unknown'`; `(confirmed_at IS NOT NULL) = (state = 'confirmed')`"; `reasons` "TEXT ≤ 128 B"; the `WITHOUT ROWID` primary keys of `match_candidates` and `rejected_candidates`; every index listed; `ON DELETE CASCADE` from `meetings`, `meeting_speakers`, `diarization_runs`, `identification_runs` and `known_speakers` as specified. Insert one `meeting_identification` row per existing meeting
- [X] T017 Insert the `meeting_identification` row in the same transaction that creates a meeting in `apps/macos/LocalFlow/Core/Storage/MeetingStore.swift`, with a case in `apps/macos/LocalFlowTests/MeetingStoreTests.swift`
- [X] T018 Create the `IdentityStore` actor on the shared `DatabaseQueue` in `apps/macos/LocalFlow/Core/Storage/IdentityStore.swift` conforming to `IdentityStoring`, with the known-speaker and sample operations (`knownSpeakers`, `createKnownSpeaker`, `rename` in one transaction copying `display_name` of every linked `confirmed`/`recognized` speaker in batches of 500, `setRecognition`, `deleteKnownSpeaker` per research R9, `samples`, `removeSample`, `addSamples` with cap, retirement and `rejectedSource`, `profiles(compatibleWith:)`) and the run operations (`identification`, `admit` against the accepted diarization run, `start`, `appendCandidates` with the 64,000 bound, `complete` as one transaction replacing only `automatic_match` rows, `fail`, `interrupt`, `requeue`, `cancel`, `activeRuns`, `meetingState`, `meetingsWithUnknownRemoteSpeakers`), plus `IdentityStore.Error` (`capacity(kind)`, `persistenceCapacity`, `revisionMismatch`, `rejectedSource`). Make T015 pass
- [X] T019 Add the assignment operations to `apps/macos/LocalFlow/Core/Storage/IdentityStore.swift`: `identities(meetingID:)` resolved per display root through `MergedIdentityRule`, `link` (copies the known speaker's name into `meeting_speakers.display_name` through the existing name path), `reject` (writes `rejected_candidates`, refuses beyond 1,000 rows per meeting, `keepUnknown` upserts `rejected_unknown / kept_unknown`), `resolveMerged`, `clearMergedResolution`, `unlink`, and the `SpeakerIdentity` read model, with cases in `apps/macos/LocalFlowTests/IdentityStoreTests.swift` for every state/origin pair the CHECKs allow and forbid

### Region selection, retirement and reader (delivery steps 4–5)

- [X] T020 [P] Create `apps/macos/LocalFlowTests/VoiceRegionSelectorTests.swift`: regions come only from `overlapped = 0` turns that intersect no other speaker's turn on either track; 0.2 s trim at each end; 3.0 s minimum after trim; regions over 20 s cut to 20 s; `engine_quality < 0.5` excluded and absent quality allowed; five-span spread takes the longest eligible region per span first; enroll limit 5 / 100 s and query limit 4 / 60 s; `audioCheck` rejects `clipped` (> 0.1% of samples |x| ≥ 0.99) and `too_quiet` (RMS < −45 dBFS); `qualityLabel` is `good` at ≥ 6 s and quality ≥ 0.7 or absent, else `fair`; identical output for identical input; zero eligible regions returns an empty list
- [X] T021 [P] Implement `VoiceRegionSelector` (`regions_v1`) in `apps/macos/LocalFlow/Core/Identification/VoiceRegionSelector.swift` per research R4 with `select`, `audioCheck`, `qualityLabel` and `qualityScore`, every number a named constant. Make T020 pass
- [X] T022 [P] Create `apps/macos/LocalFlowTests/SampleRetirementPolicyTests.swift`: the cap holds after adding; score is `0.6 × quality_score + 0.4 × (1 − max cosine to any other retained sample)`; higher-quality and more diverse samples survive; the lowest-scoring are retired first; deterministic ties by id; no retirement below the cap
- [X] T023 [P] Implement `SampleRetirementPolicy` (`retire_qd_v1`) in `apps/macos/LocalFlow/Core/Identification/SampleRetirementPolicy.swift` per research R5. Make T022 pass
- [X] T024 [P] Create `apps/macos/LocalFlowTests/VoiceRegionReaderTests.swift`: regions from synthetic ADTS stretches arrive in start order with exact sample counts (16 kHz mono); the handler runs before the next region is decoded and only one region is resident; a region spanning stretch bases maps through `transcriptBases`; a missing stretch file skips its regions and is counted `audio_missing`, and every file missing fails `audio_missing`; open, read and convert errors map to `audio_decode_failure`; no seek is issued
- [X] T025 Implement the `VoiceRegionReader` actor in `apps/macos/LocalFlow/Core/Identification/VoiceRegionReader.swift` per research R3: open each stretch like `MeetingDiarizer.diarizeStretch` (`AVAudioFile`, 4,096-frame reads, `AnalysisStreamMixer(decoding:)` with a one-track map), one forward pass per file, discard samples outside every region, hand each region to the handler at its end and drop it, never seek, hold at most 320,000 samples plus decode buffers. Make T024 pass
- [X] T026 Register every file added in Phase 2 in `apps/macos/LocalFlow.xcodeproj/project.pbxproj` if not already done, and run `make check`

**Checkpoint**: Boundaries, lifecycle, embedder, thresholds, schema, store, selector, retirement and reader are ready. User stories can start.

---

## Phase 3: User Story 1 — Remember a voice only when asked (Priority: P1) 🎯 MVP

**Goal**: After naming a speaker in Assign speakers, the sheet offers Remember / Not now with the FR-002 sentence. Remember creates a known speaker and stores eligible samples from that cluster with consent `remember`; Not now stores nothing.

**Independent Test**: Name "Speaker 2" in a fixture meeting, decline, and confirm `known_speakers` and `voice_samples` are empty. Repeat and accept; confirm one known speaker with ≥ 1 sample whose source is that meeting and cluster, and an assignment `confirmed / new_profile_created`.

### Tests for User Story 1

- [X] T027 [P] [US1] Create `apps/macos/LocalFlowTests/EnrollmentJobTests.swift` with `FakeVoiceEmbeddingRuntime` and a real `IdentityStore`: Not now writes no known speaker, sample, assignment or run row; Remember creates the profile and the `confirmed / new_profile_created` row in one transaction before any lease is acquired; samples are stored with consent `remember`, source meeting, source cluster, track and times; zero eligible regions gives a profile with 0 samples and outcome `noUsableSample`; an embedder failure after the profile commit leaves the profile with 0 samples and the linked name; the lease is finished on success, failure and cancellation; `stored(n)` with `n ≥ 1` publishes `enrollmentDidStore`
- [X] T028 [P] [US1] Extend `apps/macos/LocalFlowTests/AssignSpeakersModelTests.swift`: a new typed name on a section without identity shows the Remember row with the exact FR-002 sentence; Remember and Not now are drafts committed only on Save; choosing neither equals Not now; Cancel discards the Remember draft; Save with Remember issues one `IdentityStore` call per section in section order; the enrollment result line shows "Storing voice sample…", then "n samples stored" or "No usable voice sample was found in this meeting"; enrolling takes three interactions (name, Remember, Save) (SC-011); with `speakerIdentificationEnabled` off no identity block exists and the sheet equals the 007 sheet
- [X] T029 [P] [US1] Create `apps/macos/LocalFlowTests/SpeakerIdentificationCoordinatorTests.swift` with enrollment cases: `enroll` runs queue-ordered with its own `.speakerIdentification` lease; enrollment never runs while a diarization or ASR lease is active; the global setting off returns `disabled` without touching the store; `meetingWillDelete` cancels a pending enrollment for that meeting; `status` reports the enrollment phase

### Implementation for User Story 1

- [X] T030 [P] [US1] Add `speakerIdentificationEnabled` (default on, key `settings.speakerIdentificationEnabled`) to `apps/macos/LocalFlow/Features/Settings/AppPreferences.swift`, with the default covered in `apps/macos/LocalFlowTests/AppPreferencesTests.swift`
- [X] T031 [US1] Implement `EnrollmentJob` in `apps/macos/LocalFlow/Core/Identification/EnrollmentJob.swift` per the enrollment algorithm in `contracts/identification-pipeline.md`: `EnrollmentRequest` (meeting, root, name or existing known speaker id, origin, consent, track), profile and identity row first, `VoiceRegionSelector` with enroll limits over the root's turns on its track, `VoiceRegionReader` feeding `ModelLifecycleCoordinator.embed` one region at a time, `audioCheck` rejections counted, `addSamples` with the consent value, `EnrollmentOutcome` (`stored(n)`, `noUsableSample`, `disabled`, `failed(category)`). Make T027 pass
- [X] T032 [US1] Create `SpeakerIdentificationCoordinator` (main actor, `@Observable`, `IdentificationObserving`) in `apps/macos/LocalFlow/Features/Speakers/SpeakerIdentificationCoordinator.swift` with the enrollment queue, `enroll(_:)`, the global-setting short circuit, `meetingWillDelete(id:)`, `status`, and stubs for `diarizationDidAdopt`, `requestRun`, `cancel`, `startPastSearch`, `cancelPastSearch` and `resume` to be filled in US2 and US6. Make T029 pass
- [X] T033 [US1] Join `identity_assignments` into `speakerSummaries(meetingID:)` so each `SpeakerSummary` carries a `SpeakerIdentity` (from `IdentityStore.identities`) and `sampleOfferAvailable` (the selector finds ≥ 1 eligible region), in `apps/macos/LocalFlow/Core/Storage/SpeakerStore.swift`, with a case in `apps/macos/LocalFlowTests/SpeakerStoreTests.swift`
- [X] T034 [US1] Add the identity section per row to `apps/macos/LocalFlow/Features/Speakers/AssignSpeakersModel.swift`: match state line text, the Remember / Not now draft, the enrollment result line, per-section identity actions committed on Save in section order, Cancel discarding all identity drafts, and no identity state at all when `speakerIdentificationEnabled` is off. Make T028 pass
- [X] T035 [US1] Render the identity block under the name field in `apps/macos/LocalFlow/Features/Speakers/AssignSpeakersView.swift` per `contracts/ui.md`: the match state line, the row **Remember this voice for future meetings?** with `identity.remember` and `identity.notNow` under the sentence *"LocalFlow will store data that can recognize this voice in future meetings on this Mac. It stays on this Mac and you can delete it in Settings › Known speakers."*, and the `identity.enrollmentResult` line; nothing rendered when the setting is off
- [X] T036 [US1] Wire `IdentityStore`, the `FluidAudioVoiceEmbedderFactory` over the diarization `ModelProvisioner`, the lifecycle factory, `EnrollmentJob` and `SpeakerIdentificationCoordinator` in `apps/macos/LocalFlow/App/AppServices.swift`, set `ModelHub.offlineMode` before any embedder load, and hand enrollment requests from the sheet's Save to the coordinator
- [X] T037 [US1] Register every file added in Phase 3 in `apps/macos/LocalFlow.xcodeproj/project.pbxproj` and run `make check`

**Checkpoint**: Consented enrollment works end to end with zero rows after Not now. This is the MVP.

---

## Phase 4: User Story 2 — Recognize a known voice in a later meeting (Priority: P1)

**Goal**: After diarization adopts and releases its model, an identification run compares each remote root against known speakers and writes exactly one assignment per root: Recognized, Possible match or Unknown. The transcript shows names, "Name?" or "Speaker N"; "You" stays track-origin.

**Independent Test**: Enroll from meeting A. Run identification on meeting B (same person, a different person, one short cluster) through the fake runtime with scripted vectors. The same person is Recognized or Possible per the tiers, the other stays Unknown, the short cluster stays Unknown with reason `min_speech`, and no networking symbol is imported.

### Tests for User Story 2

- [X] T038 [P] [US2] Create `apps/macos/LocalFlowTests/IdentityMatcherTests.swift`: table-driven tiers at each edge (`score = τ_high` with margin and support → Recognized; margin `< δ` → Possible with `second` set and reason `margin`; support `< 2` → Possible with reason `support`; total region audio `< 6 s` → Possible at most with `min_speech`; `score < τ_medium` → Unknown with reason `below_medium`); `sim` is the mean of the top `min(3, n)` cosines; `score` is duration-weighted across regions; rejected candidates excluded with reason `rejected`; disabled profiles excluded with `disabled`; nearest candidate never surfaced below medium (`best == nil`); the local-user profile is scored with tier `local_evidence` and never becomes `best`; no profiles → Unknown; every scored profile appears in `candidates`; identical input gives identical output
- [X] T039 [P] [US2] Create `apps/macos/LocalFlowTests/MeetingIdentifierTests.swift` for the success path: admission verifies the accepted diarization run id; zero compatible profiles completes the run with every remote root `unknown / automatic_match` and no score, without acquiring a lease; `busy` leaves the run pending; a speech preemption moves `running → pending` and bumps `preemption_count`; the "You" root is never queried; query regions use the query limits; each region is embedded as it is read and rejections are counted; the lease is finished before matching; candidates are appended per root; `complete` writes exactly one row per remote root; transcript segments, turns, audio files and samples are byte-identical afterwards; recorder metrics carry only counts and durations
- [X] T040 [P] [US2] Add run-trigger cases to `apps/macos/LocalFlowTests/SpeakerIdentificationCoordinatorTests.swift`: `diarizationDidAdopt` enqueues an automatic run only after the diarization lease has finished; no run while a diarization lease is active; the global setting off ignores triggers; the queue deduplicates, holds 100 ids, skips automatic overflow with a notice and refuses manual overflow with a notice; one run at a time; `cancel` deletes the run row; `status` reports progress as regions done over planned
- [X] T041 [P] [US2] Add a case to `apps/macos/LocalFlowTests/SpeakerDiarizationCoordinatorTests.swift`: `diarizationDidAdopt(meetingID:)` is published to the observer after the lease finished and the adoption committed, and not on failure or cancel
- [X] T042 [P] [US2] Extend `apps/macos/LocalFlowTests/TranscriptPagerTests.swift`: `confirmed`/`recognized` rows carry `identity = .named`; `possible` rows carry `.suggested(name)` and render "Name?"; `unknown`, `rejected_unknown` and absent rows carry `.unknown` and the 007 "Speaker N" label; the local "You" row is unchanged; no read model field holds a score; an adoption bumps `identityRevision` and reloads the first page without mixing two results
- [X] T043 [P] [US2] Extend `apps/macos/LocalFlowTests/ResourceRecorderTests.swift`: the identification metrics from research R14 and the four phases are recorded, and the content-free assertion covers them (no name, vector, time range, transcript text or meeting id)

### Implementation for User Story 2

- [X] T044 [P] [US2] Implement `IdentityMatcher` (`tiers_v1`) in `apps/macos/LocalFlow/Core/Identification/IdentityMatcher.swift` per research R6 with `Candidate`, `Decision` and `decide(query:profiles:rejected:thresholds:)`. Make T038 pass
- [X] T045 [US2] Implement the `MeetingIdentifier` actor in `apps/macos/LocalFlow/Core/Identification/MeetingIdentifier.swift` per the run algorithm in `contracts/identification-pipeline.md`: load the pending run, check `diarization_changed`, load compatible profiles (≤ 1,000 × 10 × 256 floats, released at run end), zero-candidate short circuit, acquire, `start`, per-root region selection and reading, embed per region, progress, `finish`, `decide` per root, `appendCandidates`, second diarization check, `complete`, `fail` with category and candidate cleanup, cancellation deleting the row, and `ResourceRecorder` metrics. Make T039 pass
- [X] T046 [US2] Publish `diarizationDidAdopt(meetingID:)` from `apps/macos/LocalFlow/Features/Speakers/SpeakerDiarizationCoordinator.swift` after the lease has finished and adoption has committed, through an optional `IdentificationObserving` reference. Make T041 pass
- [X] T047 [US2] Fill in `diarizationDidAdopt`, `requestRun(meetingID:trigger:)`, `cancel(meetingID:)`, the bounded deduplicated identification queue, one active run, and the `IdentificationStatus` publication in `apps/macos/LocalFlow/Features/Speakers/SpeakerIdentificationCoordinator.swift`. Make T040 pass
- [X] T048 [US2] Add the page query variant that joins the effective identity per display root (through `identity_assignments` with the `scope` rule) and returns `SegmentIdentity` on `SegmentLabel` in `apps/macos/LocalFlow/Core/Storage/TranscriptStore.swift`; named rows keep reading `display_name`
- [X] T049 [US2] Serve identity labels, keep `identityRevision` and reload on adoption or confirmation in `apps/macos/LocalFlow/Features/Transcripts/TranscriptPager.swift`. Make T042 pass
- [X] T050 [US2] Render "Name?" rows in the speaker color and the status line precedence (007 diarization status first, then "Identifying speakers… n%") in `apps/macos/LocalFlow/Features/Meetings/MeetingDetailView.swift`; the confirm control itself is US3
- [X] T051 [US2] Add the identification metrics (`identificationModelLoadDuration`, `identificationModelReleaseDuration`, `identificationDuration`, `identificationRegionsExtracted`, `identificationRegionsRejected`, `identificationComparisons`, `identificationRecognized`, `identificationSuggested`, `identificationUnknown`, `identificationConfirmations`, `identificationCorrections`, `identificationFailure`, `enrollmentSamplesStored`) and 10 s RSS sampling during runs and enrollment in `apps/macos/LocalFlow/Core/Observability/ResourceRecorder.swift`. Make T043 pass
- [X] T052 [US2] Wire `MeetingIdentifier` and the diarization → identification observer link in `apps/macos/LocalFlow/App/AppServices.swift`, register every file added in Phase 4 in `apps/macos/LocalFlow.xcodeproj/project.pbxproj`, and run `make check`

**Checkpoint**: Recognition runs after diarization and shows names, suggestions and Speaker N.

---

## Phase 5: User Story 3 — Confirm, reject or correct an identity (Priority: P1)

**Goal**: The user confirms a Possible match, keeps it Unknown, or corrects any identity to another known speaker. Rejections are recorded per cluster, samples are added only with "Also remember this voice sample" on and never to a rejected speaker, manual decisions survive reruns, and a merge conflict prompts for a choice.

**Independent Test**: From a meeting where Speaker 2 was Recognized as Tomáš, change it to Lukáš with the toggle off. The transcript shows Lukáš, origin is `manual_correction`, `rejected_candidates` holds (Speaker 2, Tomáš), Tomáš gained no sample, Lukáš gained none; repeat with the toggle on and Lukáš gains eligible samples with consent `also_remember`. Rerun identification: the row is unchanged.

### Tests for User Story 3

- [X] T053 [P] [US3] Add correction cases to `apps/macos/LocalFlowTests/IdentityStoreTests.swift`: `link` with `user_confirmation` sets `confirmed` with `confirmed_at`; `reject(keepUnknown: true)` writes `rejected_unknown / kept_unknown` and the rejected pair; `link` with `manual_correction` records the previous candidate as rejected and sets `corrected_at`; `addSamples` refuses `rejectedSource` for a rejected pair; `complete` after a manual row keeps it and counts `preserved_manual_count`; a rerun never re-suggests a rejected pair; `unlink` returns to `unknown / kept_unknown`; more than 1,000 rejected pairs per meeting is refused
- [X] T054 [P] [US3] Add cases to `apps/macos/LocalFlowTests/AssignSpeakersModelTests.swift`: a `possible` section shows Confirm, Choose another… and Keep Unknown; Confirm drafts `user_confirmation`; Keep Unknown drafts the rejection; Choose another opens the picker with the within-margin runner-up first; "Also remember this voice sample" is off by default, hidden when `sampleOfferAvailable` is false, and only when on does Save request `also_remember` samples; a merged section with `needsChoice` shows "Choose an identity" and blocks Save until resolved; Cancel discards everything
- [X] T055 [P] [US3] Add cases to `apps/macos/LocalFlowTests/EnrollmentJobTests.swift`: Confirm with the toggle off adds nothing; Confirm with the toggle on adds eligible samples with consent `also_remember`; a correction never adds to the rejected speaker even with the toggle on; low-quality regions are not added because the toggle was on; automatic runs never call `addSamples`
- [X] T056 [P] [US3] Create `apps/macos/LocalFlowTests/MergedIdentityRuleTests.swift`: same known speaker on both sides survives; one side linked and the other absent survives; different known speakers → Unknown with `needsChoice`; a `possible` on either side → Unknown with `needsChoice`; a `merged` resolution row wins; unmerge (resolution removed) restores both `self` rows unchanged
- [X] T057 [P] [US3] Add cases to `apps/macos/LocalFlowTests/SpeakerStoreTests.swift` and `apps/macos/LocalFlowTests/CorrectionCarryOverTests.swift`: unmerge calls `clearMergedResolution`; `self` rows are never modified by merge or unmerge; a manual identity row is carried to the new root with a safe 007 name map and listed as a review notice otherwise; automatic rows are never carried
- [X] T058 [P] [US3] Add cases to `apps/macos/LocalFlowTests/TranscriptPagerTests.swift`: a `possible` row exposes the `speaker.confirm` action; confirming from the transcript issues one `link` with `user_confirmation` and no sample request, and bumps `identityRevision`

### Implementation for User Story 3

- [X] T059 [P] [US3] Implement `MergedIdentityRule` in `apps/macos/LocalFlow/Core/Identification/MergedIdentityRule.swift` per research R11 with `effective(root:members:resolution:) -> EffectiveIdentity`. Make T056 pass
- [X] T060 [US3] Use `MergedIdentityRule` in `IdentityStore.identities`, and make `unmerge` in `apps/macos/LocalFlow/Core/Storage/SpeakerStore.swift` call `clearMergedResolution` in the same transaction. Make T053 and the `SpeakerStoreTests` half of T057 pass
- [X] T061 [US3] Carry manual identity rows with names in `apps/macos/LocalFlow/Core/Diarization/CorrectionCarryOver.swift` and its call site in `SpeakerStore.complete`, flagging rows that cannot be carried as review notices. Make the `CorrectionCarryOverTests` half of T057 pass
- [X] T062 [US3] Add the suggestion actions, the Also remember toggle, the correction path (record rejection, then link) and the merge-conflict prompt to `apps/macos/LocalFlow/Features/Speakers/AssignSpeakersModel.swift`; route `also_remember` sample requests through the coordinator after Save. Make T054 and T055 pass
- [X] T063 [US3] Render `identity.confirm`, `identity.chooseAnother`, `identity.keepUnknown`, `identity.alsoRemember` (off by default, hidden without eligible regions), the match state lines "Recognized as Tomáš" / "Possible match: Tomáš?" / "Confirmed" / "Unknown" / "Choose an identity" in `apps/macos/LocalFlow/Features/Speakers/AssignSpeakersView.swift`
- [X] T064 [US3] Add the subtle checkmark `speaker.confirm` control on "Name?" rows in `apps/macos/LocalFlow/Features/Meetings/MeetingDetailView.swift`, calling `link` with `user_confirmation` and bumping `identityRevision` in `apps/macos/LocalFlow/Features/Transcripts/TranscriptPager.swift`; count confirmations and corrections in the recorder. Make T058 pass
- [X] T065 [US3] Register every file added in Phase 5 in `apps/macos/LocalFlow.xcodeproj/project.pbxproj` and run `make check`

**Checkpoint**: All P1 stories are done. Wrong names are cheap to fix and never poison a profile.

---

## Phase 6: User Story 4 — Choose an existing known speaker while naming (Priority: P2)

**Goal**: The name field offers a picker of known speakers; picking links without creating a profile; typing an exact existing name with Remember asks "same person or someone new".

**Independent Test**: With three known speakers, pick "Lukáš Kocman" for Speaker 3 and Save; the assignment is `confirmed / manual_profile_selection` and `known_speakers` still has three rows. Type "Lukáš Kocman" and choose Remember: the same/new choice appears and `Someone new` creates a fourth row.

### Tests for User Story 4

- [X] T066 [P] [US4] Add cases to `apps/macos/LocalFlowTests/AssignSpeakersModelTests.swift`: the picker lists known speakers sorted by name with sample count and a "needs re-enrollment" tag; the local-user profile is not offered for remote speakers; picking fills the name field and drafts `manual_profile_selection` with no Remember row; typing a name exactly equal to an existing known speaker's (case-sensitive after `SpeakerNames.validate`) and choosing Remember replaces the row with "Is this Tomáš Novák you already remember?" offering `Same person` (drafts `manual_profile_selection`) and `Someone new` (drafts a new profile)
- [X] T067 [P] [US4] Add a case to `apps/macos/LocalFlowTests/IdentityStoreTests.swift`: `link` with `manual_profile_selection` copies the known speaker's name into `display_name`, creates no profile and no sample, and a second known speaker with the same name is allowed after the explicit choice

### Implementation for User Story 4

- [X] T068 [US4] Add the known-speaker picker source, the duplicate-name detection and the `Same person` / `Someone new` draft to `apps/macos/LocalFlow/Features/Speakers/AssignSpeakersModel.swift`. Make T066 and T067 pass
- [X] T069 [US4] Render the `identity.picker` menu and the inline duplicate choice in `apps/macos/LocalFlow/Features/Speakers/AssignSpeakersView.swift`

---

## Phase 7: User Story 5 — Manage known speakers (Priority: P2)

**Goal**: Settings › Known speakers lists each profile with name, sample count and recognition state; supports Rename, Disable/Enable, Delete and sample removal; the global toggle turns identification and enrollment off without touching diarization or naming.

**Independent Test**: Create three known speakers, disable one, rerun on a meeting with that person: not named or suggested. Delete a speaker: zero rows reference it, `sum(length(text))` of `transcript_segments` is unchanged, historical names remain as plain metadata. Turn the global setting off: the 007 sheet renders, no run is admitted and no enrollment offer appears.

### Tests for User Story 5

- [X] T070 [P] [US5] Create `apps/macos/LocalFlowTests/KnownSpeakersModelTests.swift`: rows show name, "n voice samples", recognition switch, "Needs re-enrollment" when no compatible active sample exists; Rename validates through `SpeakerNames`; Delete requires the confirmation sheet with the exact copy from `contracts/ui.md`; sample rows show source meeting title and date, "12 s" and "Good"/"Fair"; a provenance-unavailable sample shows "Source meeting deleted" with its creation date; Remove issues one `removeSample`; a `revisionMismatch` reloads the list with a notice; no row exposes a vector, score or audio control
- [X] T071 [P] [US5] Add the deletion matrix to `apps/macos/LocalFlowTests/IdentityStoreTests.swift`: deleting a known speaker leaves zero rows in `voice_samples`, `identity_assignments`, `match_candidates` and `rejected_candidates` referencing it, keeps `display_name` on every previously `confirmed`/`recognized` speaker, turns `possible` rows into no name, and changes zero bytes in `transcript_segments`, `speaker_turns` and audio (SC-012); deleting a meeting cascades every identity table and sets `source_meeting_id`/`source_speaker_id` NULL on its samples while the samples stay active; `removeSample` of the last compatible active sample derives `needsReenrollment`; `setRecognition(false)` excludes the profile from `profiles(compatibleWith:)` and leaves historical rows; a model identity change keeps old rows and excludes them from `profiles(compatibleWith:)`; rename copies names in batches of 500 in one transaction and leaves unlinked names alone
- [X] T072 [P] [US5] Extend `apps/macos/LocalFlowTests/SettingsTests.swift` and `apps/macos/LocalFlowTests/MeetingDeletionTests.swift`: the toggle defaults on with the detail text "Nothing is stored until you choose Remember for a voice."; with the toggle off the 007 sheet renders without the identity block and the coordinator admits no run and no enrollment; confirmed meeting deletion calls `SpeakerIdentificationCoordinator.meetingWillDelete` before the row is deleted and leaves no identity rows

### Implementation for User Story 5

- [X] T073 [US5] Implement `KnownSpeakersModel` in `apps/macos/LocalFlow/Features/Speakers/KnownSpeakersModel.swift` over `IdentityStoring` (list, rename with expected revision, recognition toggle, delete confirmation, sample list, remove sample, mismatch reload). Make T070 pass
- [X] T074 [US5] Build `apps/macos/LocalFlow/Features/Speakers/KnownSpeakersView.swift` with identifiers `settings.knownSpeakers` and `settings.voiceSamples`, and add the **Remember and recognize speakers across meetings** toggle (`settings.speakerIdentificationEnabled`) plus the Known speakers section under the Speaker labels group in `apps/macos/LocalFlow/Features/Settings/SettingsView.swift`
- [X] T075 [US5] Chain `SpeakerIdentificationCoordinator.meetingWillDelete` after the diarization hook in the confirmed-deletion path in `apps/macos/LocalFlow/App/AppServices.swift`, cancelling and joining the active run and dropping the meeting from both queues. Make T071 and T072 pass
- [X] T076 [US5] Extend `apps/macos/LocalFlowTests/NativePresentationTests.swift`: the sheet with a Recognized, a Possible, an Unknown and a merged-conflict section, and Settings with three known speakers (one needing re-enrollment, one with a deleted-source sample), at the three 007 sizes in light and dark
- [X] T077 [US5] Register every file added in Phases 6–7 in `apps/macos/LocalFlow.xcodeproj/project.pbxproj` and run `make check`

**Checkpoint**: Everything LocalFlow remembers about a voice is visible and removable.

---

## Phase 8: User Story 6 — Rerun identification without redoing transcription (Priority: P2)

**Goal**: Rerun identification alone from the Speakers menu; failed runs show a reason and Retry; a crash leaves prior assignments intact; after an enrollment stores a sample, a one-time prompt offers to search past meetings that still have Unknown remote speakers, one meeting at a time.

**Independent Test**: Run identification on meeting C with an empty library (all Unknown, no lease acquired). Enroll from A, accept "Look for this voice in past meetings?": C is identified without transcription or diarization repeating and with zero transcript changes; a meeting with no Unknown remote root is skipped.

### Tests for User Story 6

- [X] T078 [P] [US6] Add rerun and failure cases to `apps/macos/LocalFlowTests/MeetingIdentifierTests.swift`: `Rerun` admits a `manual` run and calls neither the transcription nor the diarization path; every failure category (`model_unavailable`, `os_unsupported`, `model_load_failure`, `audio_missing`, `audio_decode_failure`, `runtime_failure`, `diarization_changed`, `persistence_failure`, `persistence_capacity`) leaves transcript, diarization, samples and previous assignments byte-identical and deletes only the run's candidates; a preempted run restarts from its first region; a rerun replaces `automatic_match` rows and keeps manual rows (SC-007)
- [X] T079 [P] [US6] Add past-search cases to `apps/macos/LocalFlowTests/SpeakerIdentificationCoordinatorTests.swift`: `enrollmentDidStore` is published once per enrollment with ≥ 1 sample; `startPastSearch` asks `meetingsWithUnknownRemoteSpeakers(limit: 500)` newest first and returns the queued count; meetings without an Unknown remote root are skipped at admission; runs carry trigger `past_search` one at a time; `cancelPastSearch` drops the remaining queue; the queue is memory-only and empty after a simulated relaunch; `status` shows "Looking for <name> in past meetings (k left)"
- [X] T080 [P] [US6] Create `apps/macos/LocalFlowTests/IdentificationReconcilerTests.swift`: at launch `running` becomes `interrupted` with its candidates deleted and assignments kept, `pending` is re-enqueued through `resume`, at most 100 rows are handled per launch, and no audio is read
- [X] T081 [P] [US6] Add a case to `apps/macos/LocalFlowTests/IdentityStoreTests.swift`: `meetingsWithUnknownRemoteSpeakers` returns only meetings with an accepted diarization run and at least one remote root whose effective identity is `unknown` or absent, newest first, capped by `limit`

### Implementation for User Story 6

- [X] T082 [US6] Implement `IdentificationReconciler` in `apps/macos/LocalFlow/Core/Identification/IdentificationReconciler.swift` and chain it after `DiarizationReconciler` in `apps/macos/LocalFlow/App/AppServices.swift`. Make T080 pass
- [X] T083 [US6] Fill in `startPastSearch(knownSpeakerID:)`, `cancelPastSearch`, `resume(_:)`, the 500-id past-search queue, retry after failure, and the `enrollmentDidStore` publication in `apps/macos/LocalFlow/Features/Speakers/SpeakerIdentificationCoordinator.swift`. Make T078, T079 and T081 pass
- [X] T084 [US6] Add **Rerun identification** (`speakers.rerunIdentification`, enabled with an accepted diarization run) to the Speakers menu, the "Identification failed: <reason>" status with Retry, the past-search status with Cancel, and the one-time **Look for this voice in past meetings?** prompt (`identity.pastSearch` / Not now, naming how many meetings would be checked) in `apps/macos/LocalFlow/Features/Meetings/MeetingDetailView.swift` and `apps/macos/LocalFlow/Features/Speakers/AssignSpeakersView.swift`; register the reconciler file in `apps/macos/LocalFlow.xcodeproj/project.pbxproj` and run `make check`

**Checkpoint**: Older meetings benefit from a growing library, and failed runs are never dead ends.

---

## Phase 9: User Story 7 — Enroll the local user's own voice (Priority: P3)

**Goal**: The "You" row offers Remember my voice; the local profile is built from microphone regions only, is scored as evidence only, and never changes "You" labeling.

**Independent Test**: Enroll the local voice from a meeting; `known_speakers.is_local_user = 1` with samples whose `track = microphone`. In a new meeting "You" is labeled exactly as before and the local profile appears in `match_candidates` only with tier `local_evidence`.

### Tests for User Story 7

- [X] T085 [P] [US7] Add cases to `apps/macos/LocalFlowTests/EnrollmentJobTests.swift` and `apps/macos/LocalFlowTests/MeetingIdentifierTests.swift`: local enrollment reads only microphone-track regions with consent `local_enroll`; a second local profile is refused; the local profile is scored against remote roots with tier `local_evidence` and never names, suggests or relabels; "You" labeling is identical with and without the profile
- [X] T086 [P] [US7] Add a case to `apps/macos/LocalFlowTests/AssignSpeakersModelTests.swift`: the local section shows `identity.rememberLocal` when no local profile exists and "Your voice is remembered" otherwise; the local profile is never offered in the picker

### Implementation for User Story 7

- [X] T087 [US7] Support `isLocalUser` enrollment in `apps/macos/LocalFlow/Core/Identification/EnrollmentJob.swift` and local-evidence scoring in `apps/macos/LocalFlow/Core/Identification/MeetingIdentifier.swift`. Make T085 pass
- [X] T088 [US7] Add the `Remember my voice` link and the "Your voice is remembered" state to the local section in `apps/macos/LocalFlow/Features/Speakers/AssignSpeakersModel.swift` and `apps/macos/LocalFlow/Features/Speakers/AssignSpeakersView.swift`. Make T086 pass

---

## Phase 10: Polish, instrumentation and acceptance

**Purpose**: Documentation, privacy checks, the frozen values, the hardware acceptance files and the regression gate.

- [X] T089 [P] Add the identification sections to `docs/architecture/model-lifecycle.md` (fourth workload, ordering after diarization, preemption, release) and `docs/architecture/storage.md` (`identities-v8` tables, vector BLOBs, the deletion matrix, name copies)
- [X] T090 [P] Add a `make check` step (script under `scripts/`) that fails when any file under `apps/macos/LocalFlow/Core/Identification/` imports `Network`, `URLSession` or `Foundation.URLRequest`, and confirm the 006/007 export and copy paths read none of the new tables with a case in `apps/macos/LocalFlowTests/TranscriptStoreTests.swift`
- [ ] T091 Freeze the region, quality, limit and cap constants from T014 and the measurements below in `apps/macos/LocalFlow/Core/Identification/VoiceRegionSelector.swift`, `apps/macos/LocalFlow/Core/Identification/SampleRetirementPolicy.swift` and `apps/macos/LocalFlow/Core/Identification/IdentificationThresholds.swift`, bump `regions_v1` / `tiers_v1` / `retire_qd_v1` and the pipeline version in `apps/macos/LocalFlow/Core/Identification/IdentificationRun.swift` if any value changed, and update the edge tables in T020, T022 and T038
- [X] T092 On the reference M5, run a 60-minute, 6-remote-speaker meeting against 10, 50 and 100 known speakers × 10 samples (synthetic vectors for 50 and 100, timing only) with `LOCALFLOW_RESOURCE_RECORDING=1`, and record model load, extraction, comparison and adoption durations in `specs/010-persistent-speaker-identification/acceptance/throughput.md` (gate ≤ 60 s after diarization, SC-008)
- [X] T093 On the reference M5, sample RSS every 10 s across one run and one enrollment with `scripts/memory-report.sh`, and record baseline, load increase, peak and post-release RSS in `specs/010-persistent-speaker-identification/acceptance/memory.md` (gate: post-release ≤ diarization-free baseline + 20 MB, SC-009)
- [ ] T094 Run quickstart scenarios 1 and 3 with Wi-Fi off and the Go server stopped, capture `nettop`, and search logs and exports with `strings` and SQL for names and vectors; record in `specs/010-persistent-speaker-identification/acceptance/consent-and-privacy.md` (SC-005, SC-006)
- [ ] T095 Force-quit during a run and during a past search; on relaunch confirm the run is `interrupted`, previous assignments intact, the remaining queue dropped and Rerun available; record in `specs/010-persistent-speaker-identification/acceptance/recovery.md`
- [X] T096 Run the Feature 001–009 suites with `speakerIdentificationEnabled` off and record the unchanged pass in `specs/010-persistent-speaker-identification/acceptance/regression.md` (SC-010)
- [ ] T097 Walk through every scenario in `specs/010-persistent-speaker-identification/quickstart.md` on the real app with fixture meetings A, B and C, fix anything found, and run `make check` one last time

---

## Dependencies and execution order

- **Phase 1 → Phase 2 → stories**: T001–T003 have no code dependency. Phase 2 blocks every story; within it T004 → T005 → T006 → (T007, T008) → T009; T009 → T010 → (T011, T012) → T013 → T014 (hardware, may lag); T006 → T015 → T016 → T017 → T018 → T019; T005 → (T020/T021, T022/T023, T024/T025); T026 last.
- **US1 (Phase 3)** needs all of Phase 2 except T014. T030 is independent; T031 needs T009, T018, T021, T025; T032 needs T031; T033 needs T019; T034 needs T030, T033; T035 needs T034; T036 needs T032, T035.
- **US2 (Phase 4)** needs US1's T032 and T036. T044 needs T013; T045 needs T044, T025, T018; T046 is independent of T045; T047 needs T045, T046; T048 needs T019; T049 needs T048; T050 needs T049; T051 needs T009; T052 last.
- **US3 (Phase 5)** needs US2 (a Possible match to act on). T059 first; T060 needs T059, T019; T061 needs T060; T062 needs T034, T060; T063 needs T062; T064 needs T049.
- **US4 (Phase 6)** needs US1 (Remember flow) and US3's picker entry point (T062).
- **US5 (Phase 7)** needs Phase 2 storage and T030; independent of US2–US4 except the deletion hook (T075) which needs T047.
- **US6 (Phase 8)** needs US2 (runs) and US1 (enrollment publishes `enrollmentDidStore`).
- **US7 (Phase 9)** needs US1 and US2.
- **Phase 10** needs everything; T091 needs T014, T092 and T093; T096 needs T030 and T074.

## Parallel execution examples

- **Phase 2**: T007, T008 alongside T005/T006; T011 and T012 alongside T013; T015 while T016 is written; T020, T022 and T024 together, then T021, T023 and T025 together.
- **US1**: T027, T028, T029 and T030 in parallel, then T031 → T032 while T033 → T034 → T035 proceed.
- **US2**: T038–T043 all in parallel; then T044 with T046 and T048; then T045, T047, T049.
- **US3**: T053–T058 in parallel; T059 in parallel with the tests.
- **US5**: T070, T071, T072 in parallel, then T073 with T074.
- **US6**: T078–T081 in parallel, then T082 with T083.
- **Phase 10**: T089 and T090 in parallel with the hardware runs T092–T096.

## Implementation strategy

1. **MVP = Phase 1 + Phase 2 (on provisional thresholds) + US1.** Ship consented enrollment with zero rows after Not now. This proves the privacy guarantee and the lifecycle integration before any matching exists.
2. **Add US2, then US3** to complete the P1 set: recognition that is conservative by construction, and correction that never poisons a profile. Freeze thresholds (T014) as soon as the reference machine and corpus are available; story work does not wait for it.
3. **Add US5 next** (management and the global toggle) because it is the trust surface and the SC-010 regression gate, then **US4** and **US6**, then **US7**.
4. **Phase 10** records every measured number. No acceptance file leaves "Unmeasured" until its run is done on the reference machine.

## Format validation

Every task starts with `- [ ]`, has a sequential `T###` id, carries `[P]` only when it touches different files from every unfinished task it could run beside, carries a `[US#]` label only in Phases 3–9, and names at least one file path.
