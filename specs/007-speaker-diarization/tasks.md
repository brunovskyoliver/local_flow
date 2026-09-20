---

description: "Task list for Feature 007 — speaker diarization and speaker assignment"
---

# Tasks: Speaker diarization and speaker assignment

**Input**: Design documents from `/specs/007-speaker-diarization/`

**Prerequisites**: plan.md, spec.md, research.md, data-model.md, contracts/diarization-pipeline.md, contracts/ui.md, quickstart.md

**Tests**: Included. The plan's test strategy and quickstart name the XCTest suites that `make check` must run, and constitution principle 12 requires them. Write each story's tests first and confirm they fail before implementing.

**Organization**: Tasks are grouped by user story so each story can be implemented and tested on its own.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependency on an unfinished task)
- **[Story]**: The user story the task serves (US1–US7)
- Paths are relative to the repository root. App sources live under `apps/macos/LocalFlow/`, tests under `apps/macos/LocalFlowTests/`
- Every new Swift file must be registered in `apps/macos/LocalFlow.xcodeproj/project.pbxproj` in the same task that creates it

## Provisional values

Window length 10 min (9,600,000 samples), reconciliation τ 0.70 / δ 0.10, alignment 0.60 / 2× / 0.20 and carry-over 0.50 / 2× are provisional. Implement them as named constants that feed the pipeline version string. T016 and T044–T045 freeze them from measurements. No task may claim a measured value before its acceptance file records it.

---

## Phase 1: Setup (shared infrastructure)

**Purpose**: Acceptance scaffolding, the pinned model manifest, licences and the ADR.

- [X] T001 Create `specs/007-speaker-diarization/acceptance/` with `throughput.md`, `accuracy.md`, `long-run-memory.md`, `naming.md`, `recovery.md` and `privacy.md`, each containing only a heading and the status line "Unmeasured"
- [X] T002 [P] Add the pinned manifest `Resources/Models/speaker-diarization-offline.json` for `FluidInference/speaker-diarization-coreml` (offline variant: `Segmentation.mlmodelc`, `FBank.mlmodelc`, `Embedding.mlmodelc`, `PldaRho.mlmodelc`, `plda-parameters.json`) with capability `speaker_diarization`, `automaticLanguage: false`, a 40-hex source revision, file sizes and SHA-256 hashes, following the shape of `Resources/Models/parakeet-v3.json` (research R2)
- [X] T003 [P] Review and record the licences of the pyannote community-1 segmentation, WeSpeaker ResNet34 and PLDA assets at the pinned revision in `docs/licenses/speaker-diarization-coreml.md` and `THIRD_PARTY_NOTICES.md`. The manifest from T002 is not complete until this is done
- [X] T004 [P] Write `docs/adr/0017-speaker-diarization-engine-and-lifecycle.md` (FluidAudio `OfflineDiarizerManager`, workload-keyed lifecycle, no co-residency, macOS 15 gate, no persisted embeddings) and list it in `docs/adr/README.md`
- [X] T005 [P] Document the evaluation set (synthetic RTTM meetings: local + 1, 2 and 3 remote voices with an overlap stretch, one-word interjections and a pause; one speaker-playback bleed meeting; consented 30–60 min owner meetings) in `fixtures/audio/README.md`, keeping the audio itself outside git

---

## Phase 2: Foundational (blocking prerequisites)

**Purpose**: Runtime boundary, engine adapter, measurement, workload-keyed lifecycle, schema, core store operations and the aligner. Every user story depends on this phase.

**⚠️ CRITICAL**: No user story work can begin until this phase is complete. T016 needs the reference machine; story work may proceed on provisional constants while it is pending.

### Boundaries and engine

- [X] T006 Add `ModelCapability.speakerDiarization` in `apps/macos/LocalFlow/Core/Models/ModelDescriptor.swift`, with `validate()` requiring `automaticLanguage == false` for it, and cover decoding of `Resources/Models/speaker-diarization-offline.json` in `apps/macos/LocalFlowTests/ModelProvisionerTests.swift`
- [X] T007 Create `apps/macos/LocalFlow/Core/DiarizationBoundaries.swift` with `ModelWorkload { speechRecognition, diarization }`, `DiarizationWindowRequest` (samples "mono 16 kHz, 1...9_600_000 samples, all finite"; `numSpeakers` 1 for the default microphone track, nil otherwise), `DiarizationWindowResult` (turns "≤ 20_000 per window, else invalidResult"; `centroids: [Int: [Float]]`, in memory only), `DiarizationRuntime` (`diarize`, `shutdown`), `SpeakerStoring` and `DiarizationObserving`, exactly as in `contracts/diarization-pipeline.md`. No FluidAudio import
- [X] T008 Create `apps/macos/LocalFlow/Core/Diarization/DiarizationRun.swift` with run states (`pending`, `running`, `succeeded`, `failed`, `interrupted`, `superseded`), triggers (`automatic`, `manual`, `retry`, `in_room_change`), failure categories (`model_unavailable`, `os_unsupported`, `model_load_failure`, `audio_missing`, `audio_decode_failure`, `runtime_failure`, `transcript_changed`, `persistence_failure`, `persistence_capacity`, `interrupted`), the transition table from data-model.md, the derived meeting-level state (FR-029) and the pipeline version builder (≤ 256 bytes, e.g. `offline_vbx_community1_nonexcl+win600s_v1+xwin_cos_greedy_v1+align_dom0.60_ratio2_ovl0.20_v1`)
- [X] T009 [P] Create `apps/macos/LocalFlowTests/Support/DiarizationFakes.swift`: `FakeDiarizationRuntime` (scripted turns and centroids per window, records every request, failure injection at window N, delay, `noSpeech` result), `FakeDiarizationFactory` and helpers for building stretches with pauses on top of `MeetingFakes.swift` and `TranscriptFakes.swift`
- [X] T010 Implement `FluidAudioDiarizerFactory` and its runtime in `apps/macos/LocalFlow/Core/Diarization/FluidAudioDiarizer.swift`: refuse unless `ModelHub.offlineMode` is true, fail `os_unsupported` below macOS 15, verify the pinned descriptor like `FluidAudioEngineFactory`, load with `OfflineDiarizerModels.load(from:)` then `OfflineDiarizerManager(config:).initialize(models:)` (community defaults, `exclusiveSegments = false`, `exposeChunkEmbeddings = true`, per-request `clustering.numSpeakers`), never call `prepareModels()`, map "S1…" ids to integer clusters, compute L2-normalized centroids from `embedding256` (omit clusters without chunk embeddings), and map `noSpeechDetected` to an empty result
- [X] T011 Set `ModelHub.offlineMode = true` once at launch and add a second `ModelProvisioner` for the speaker diarization manifest (own directory, `<root>/speaker-diarization/…` layout under `Models/speaker-diarization-offline/`) in `apps/macos/LocalFlow/App/AppServices.swift`
- [X] T012 [P] Extend `apps/macos/LocalFlowTests/RuntimeCompatibilityTests.swift`: the diarizer loads from the provisioned layout with no network, refuses when offline mode is off, a missing file fails as `model_unavailable` without a download, and macOS 14 maps to `os_unsupported` (skip real-model cases when the model is not provisioned, as the existing ASR cases do)

### Model lifecycle (FR-032)

- [X] T013 [P] Add lifecycle tests to `apps/macos/LocalFlowTests/ModelOwnershipTests.swift` and `apps/macos/LocalFlowTests/ModelCooldownTests.swift`: a workload switch releases ASR before the diarizer prepares and the two are never resident together; a diarization `acquire` throws `busy` while any lease is held or installation runs; a speech-recognition `acquire` preempts a diarization lease through `cancelAndJoin` and joins the in-flight window; `finish` on a diarization lease releases with no cooldown; Keep model ready re-prepares ASR afterwards; `transcribe` on a diarization lease throws `staleLease`; `diarize` validates request bounds and allows one inference at a time. Existing Feature 001/005 lifecycle cases stay unchanged
- [X] T014 Make `apps/macos/LocalFlow/Core/Models/ModelLifecycleCoordinator.swift` workload-keyed per the lifecycle table in `contracts/diarization-pipeline.md`: `acquire(session:workload:)` defaulting to `.speechRecognition`, a diarization factory, `diarize(_:window:)`, release-on-switch replacing the `if runtime != nil` fast path, ASR preemption, no-cooldown diarization finish and the Keep model ready re-prepare. Add the workload to observed phases (`modelLoading(diarization)`, `modelActive(diarization)`, `modelReleasing(diarization)`; speech-recognition phases keep their unqualified names) in `apps/macos/LocalFlow/Core/Observability/ResourceRecorder.swift`, plus the new `diarizing` phase

### Measurement (delivery step 1)

- [X] T015 Add `apps/macos/LocalFlowTests/DiarizationThroughputHarness.swift`: runs the real engine through `ModelLifecycleCoordinator` with no UI over a meeting's tracks at 10 and 20 min windows, and records audio seconds, diarization seconds, RTF, model load duration, model RSS increase, peak RSS, RSS slope (10 s samples), RSS after release, window count, speaker count, hardware, macOS, build and model revision. Skipped unless the model and fixture are provisioned, like `QualityEvaluationTests.swift`
- [ ] T016 On the reference M5 32 GB (macOS 15+), run T015 three times each over the 10-minute synthetic fixtures, a consented 60-minute meeting and an 8-hour synthetic concatenation. Record results and measured bytes per 60-minute meeting in `specs/007-speaker-diarization/acceptance/throughput.md`, freeze the window length, set the SC-005 gates (max RTF × 1.5 rounded up to the next 0.01; max model RSS increase × 1.5 rounded up to the next 10 MB) and write them into the validation table of `specs/007-speaker-diarization/plan.md`. If bytes per 60-minute meeting exceed 1 MB, add a follow-up task for a `speaker_usage` ceiling

### Storage (FR-034, FR-035)

- [X] T017 [P] Create `apps/macos/LocalFlowTests/SpeakerStoreTests.swift` with schema and core-run tests: `speakers-v7` migrates a Feature 006 database and inserts one `meeting_diarization` row per existing meeting; no identity or embedding table exists; the partial unique index rejects a second `pending`/`running` run; admit/start/window batch/complete/fail/interrupt/cancel follow the transition table; completion adopts atomically and supersedes the previous run, deleting its turns and assignments; a failed or interrupted run deletes only its own rows and leaves the accepted run byte-identical; meeting delete and `TranscriptStore.discardPass` cascade; overlapping turns are accepted; `engine_quality` stays NULL when the runtime returns no quality and is never exposed as confidence (FR-012); 100,000 turns per run fails with `persistence_capacity`
- [X] T018 Register migration `speakers-v7` in `apps/macos/LocalFlow/Core/Storage/HistoryMigrations.swift` creating `meeting_diarization`, `diarization_runs`, `meeting_speakers`, `speaker_turns`, `speaker_assignments` and `speaker_corrections` exactly as in data-model.md, including: `failure_category` CHECK "non-null ⇔ state ∈ (failed, interrupted)"; `failure_detail` "TEXT ≤ 512 B, content-free"; `model_manifest_hash` 64 hex; `cluster_key` "INTEGER ≥ 0, unique per run"; `label_ordinal` "INTEGER ≥ 1"; `color_index` "INTEGER 0–7"; `display_name` "TEXT NULL; trimmed, 1–80 characters, no control characters"; turns "0 ≤ start < end"; `auto_speaker_id` "required ⇔ auto_kind = speaker"; `manual_speaker_id` "required ⇔ manual_kind = speaker"; correction `previous_value`/`new_value` "TEXT ≤ 80 characters NULL"; index `(run_id, start_ms)`; PK `(run_id, segment_id)`; `ON DELETE CASCADE` from `meetings` everywhere and from `transcript_segments` for assignments. `transcript_segments` is not altered
- [X] T019 Insert the `meeting_diarization` row in the same transaction that creates a meeting in `apps/macos/LocalFlow/Core/Storage/MeetingStore.swift`, with a case in `apps/macos/LocalFlowTests/MeetingStoreTests.swift`
- [X] T020 Create the `SpeakerStore` actor on the shared `DatabaseQueue` in `apps/macos/LocalFlow/Core/Storage/SpeakerStore.swift` conforming to `SpeakerStoring`, with the run operations from data-model.md "Operations and their transactions": Admit (revision-checked), Start, Window batch (speakers then turns in batches of ≤ 500, counters), Complete (assignments batched inside one `write`, color indexes by first-turn order ties by key, label ordinals by first appearance per source, supersede, set `accepted_run_id`, clear `current_run_id`; carry-over hook left as a no-op until T065), Fail/Interrupt, Cancel, derived meeting state, and a paged "turns overlapping [start, end)" read. Make T017 pass

### Alignment (FR-013–FR-015; needed by US1 and US2)

- [X] T021 [P] Create `apps/macos/LocalFlowTests/SpeakerAlignerTests.swift`: table-driven dominant, ambiguous, unknown and overflow (`speaker_id` NULL counts toward no speaker) cases; exact threshold edges (c1 = 0.60, c1 = 2 × c2, c2 = 0.20); ties broken by lower speaker key; overlapping turns of one speaker counted as a union; two runs give identical output; the API takes turns and segment times only, and segment text and timing are unchanged
- [X] T022 [P] Implement `SpeakerAligner` (`align_dom0.60_ratio2_ovl0.20_v1`) in `apps/macos/LocalFlow/Core/Diarization/SpeakerAligner.swift` per research R6, returning kind, speaker and the evidence (`top_speaker_id`, `second_speaker_id`, `top_coverage`, `second_coverage`) for every segment. Make T021 pass

**Checkpoint**: Engine, lifecycle, schema, store and aligner are ready. User stories can start.

---

## Phase 3: User Story 1 — See who said what in a completed meeting (Priority: P1) 🎯 MVP

**Goal**: A finalized meeting is diarized locally without the window open, and the Transcript tab shows You / Speaker N rows with stable colors and a "N SPEAKERS • mm:ss" header, falling back to Feature 006 source labels when no result exists.

**Independent Test**: Diarize a fixture meeting (local + two remote speakers of known timing) through `FakeDiarizationRuntime`. The pager returns You, Speaker 1 and Speaker 2 in chronological order with stable colors, the header count is 3, and transcript rows, notes and audio files are byte-identical.

### Tests for User Story 1

- [X] T023 [P] [US1] Create `apps/macos/LocalFlowTests/WindowClusterReconcilerTests.swift`: matched (sim ≥ 0.70 and margin ≥ 0.10), new (no pair at τ), uncertain (pair at τ, margin < δ → new cluster marked `uncertain`), cluster without a centroid → new `uncertain`, one-to-one greedy order with ties by window cluster id then run cluster key, same-track only, duration-weighted run centroids, the 64-cluster-per-track capacity producing overflow turns, and determinism
- [X] T024 [P] [US1] Create `apps/macos/LocalFlowTests/MeetingDiarizerTests.swift` for the success path: admission requires a terminal meeting and a `final` transcript; system track first, then microphone; windows never cross a stretch; turn times are `baseMs + windowOffsetMs + seconds × 1000` clamped to the stretch; the microphone request has `numSpeakers = 1` and yields one local speaker; the system track is unconstrained and yields remote speakers; every speaker and turn records its source and track; a silent system track gives only the local speaker (count 1); a missing microphone track invents no local speaker; `noSpeech` gives an empty result; the lease is finished before alignment; the transcript segment rows, notes and audio files are byte-identical afterwards; the run records `inferred_speaker_count` with no count input
- [X] T025 [P] [US1] Create `apps/macos/LocalFlowTests/SpeakerDiarizationCoordinatorTests.swift`: automatic trigger only after `final` and the finalization lease finished; automatic on and off via `meetingDiarizationEnabled`; no automatic run when the model is not installed; manual Run always available; the queue deduplicates, holds at most 100 ids, skips automatic overflow (meeting stays `not_requested`) and reports "Speaker labeling queue is full" for manual overflow; one run at a time; runs with no meeting view open; `meetingWillDelete` cancels and joins and leaves no rows
- [X] T026 [P] [US1] Create `apps/macos/LocalFlowTests/DiarizationReconcilerTests.swift`: at launch `running` becomes `interrupted` with its rows deleted and the accepted run kept, `pending` is re-enqueued, at most 100 rows are handled per launch, and no audio is read
- [X] T027 [P] [US1] Extend `apps/macos/LocalFlowTests/TranscriptPagerTests.swift`: labeled pages carry `SegmentLabel` from the page query; pages stay 200 rows with 2 resident; an accepted run whose `transcript_pass_id` differs from the transcript `pass_id` yields nil labels (Feature 006 source labels); a result change bumps `labelsRevision` and reloads the first page, never mixing labels from two results; with no diarization rows the pager output equals Feature 006 (FR-038); live rows during recording carry no speaker label even when an accepted result exists from an earlier pass (FR-006)

### Implementation for User Story 1

- [X] T028 [P] [US1] Implement `WindowClusterReconciler` (`xwin_cos_greedy_v1`) in `apps/macos/LocalFlow/Core/Diarization/WindowClusterReconciler.swift` per research R4, holding run-cluster centroids in memory for the run only. Make T023 pass
- [X] T029 [US1] Implement the `MeetingDiarizer` actor in `apps/macos/LocalFlow/Core/Diarization/MeetingDiarizer.swift` per the run pipeline in `contracts/diarization-pipeline.md`: walk `MeetingFinalizer.workItems(detail:page:)` in pages of 100 stretches with the transcript's `baseMs`; decode one track through `AnalysisStreamMixer(decoding:)` with 4,096-frame buffers into one reusable 9,600,000-sample window buffer; diarize, reconcile, offset and persist per window in batches of ≤ 500; finish the lease; align in 500-segment pages reading turns bounded by the page time span; complete through `SpeakerStore`. Microphone uses `numSpeakers = 1` unless the run's `in_room` snapshot is set. Make T024 pass
- [X] T030 [US1] Implement `DiarizationReconciler` in `apps/macos/LocalFlow/Core/Diarization/DiarizationReconciler.swift`. Make T026 pass
- [X] T031 [US1] Implement `SpeakerDiarizationCoordinator` (main actor) in `apps/macos/LocalFlow/Features/Speakers/SpeakerDiarizationCoordinator.swift`: `meetingTranscriptDidFinalize(id:)`, `requestRun(meetingID:revision:trigger:)`, `cancel(meetingID:)`, `meetingWillDelete(id:) async`, `resume(_:)`, the bounded deduplicated queue, one active run, and a published `DiarizationStatus { meetingID, state, progress, failure, labelsRevision }`. Make T025 pass
- [X] T032 [P] [US1] Add `meetingDiarizationEnabled` (default on) to `apps/macos/LocalFlow/Features/Settings/AppPreferences.swift`, and in the Meetings section of `apps/macos/LocalFlow/Features/Settings/SettingsView.swift` add the "Label speakers automatically after transcription" toggle and the "Speaker labeling model" row using the existing Install/Verify flow without loading the model. Cover the default in `apps/macos/LocalFlowTests/AppPreferencesTests.swift`
- [X] T033 [US1] Call `SpeakerDiarizationCoordinator.meetingTranscriptDidFinalize(id:)` after `final` is published and the finalization lease has finished in `apps/macos/LocalFlow/Features/Transcripts/MeetingTranscriptionCoordinator.swift`, with a case in `apps/macos/LocalFlowTests/MeetingTranscriptionCoordinatorTests.swift`
- [X] T034 [US1] Wire `SpeakerStore`, the diarizer factory, `MeetingDiarizer`, `SpeakerDiarizationCoordinator` and `DiarizationReconciler` (chained after `TranscriptReconciler`) in `apps/macos/LocalFlow/App/AppServices.swift`, and call `meetingWillDelete` from the confirmed-deletion path before the row is deleted, with a case in `apps/macos/LocalFlowTests/MeetingDeletionTests.swift`
- [X] T035 [P] [US1] Create `apps/macos/LocalFlow/Features/Speakers/SpeakerPalette.swift`: 8 colors checked for contrast in light and dark mode, index cycling after 8, and label text rules ("You", "Name (You)", "Local N", "Speaker N", "Name", "Unknown", "Overlapping")
- [X] T036 [US1] Add a page query variant that left-joins the effective assignment (`manual ?? auto`, mapped to the display root `merged_into ?? id`) for the accepted run and returns `LabeledSegment` in `apps/macos/LocalFlow/Core/Storage/TranscriptStore.swift`, returning nil labels when the accepted run's `transcript_pass_id` differs from the current pass
- [X] T037 [US1] Serve labeled pages, keep the meeting's speaker rows resident, expose the header count (distinct display roots with at least one effective `speaker` assignment) and bump `labelsRevision` on result change in `apps/macos/LocalFlow/Features/Transcripts/TranscriptPager.swift`. Make T027 pass
- [X] T038 [US1] In `apps/macos/LocalFlow/Features/Meetings/MeetingDetailView.swift`: the header `N SPEAKERS • mm:ss` (or `h:mm:ss`) when an accepted result exists; a label with color dot and text above each contiguous group with the same display root, with an accessibility label that names the speaker; the `meeting.speakers.status` line for `not_requested` ("Speakers aren't labeled yet." + Label speakers), `pending` ("Waiting to label speakers…") and `running` ("Labeling speakers… 40%"); the `meeting.speakers.menu` Speakers menu with Label speakers; and unchanged Feature 006 rendering when there is no current result
- [X] T039 [US1] Register every file added in Phases 2–3 in `apps/macos/LocalFlow.xcodeproj/project.pbxproj` if not already done, and run `make check`

**Checkpoint**: A finalized meeting gets speaker labels end to end. This is the MVP.

---

## Phase 4: User Story 2 — Uncertain speech stays Unknown (Priority: P1)

**Goal**: Segments without a clearly dominant speaker show as Unknown or Overlapping, never as the nearest cluster, and they do not add to the count.

**Independent Test**: Over a fixture with one segment split evenly between two turns, one in silence and one inside a single turn, the transcript shows Overlapping, Unknown and that speaker, identically across two runs, and the header count ignores Unknown and Overlapping.

### Tests for User Story 2

- [X] T040 [P] [US2] Add end-to-end cases to `apps/macos/LocalFlowTests/MeetingDiarizerTests.swift`: the split/silence/inside fixture persists `ambiguous`, `unknown` and `speaker` assignments with coverage evidence; turns beyond the 64-cluster capacity are stored with `speaker_id` NULL, counted in `overflow_turns` and aligned to Unknown; `unknown_count` and `ambiguous_count` are recorded on the run; rerunning with identical fake output gives identical assignments
- [X] T041 [P] [US2] Add cases to `apps/macos/LocalFlowTests/TranscriptPagerTests.swift`: Unknown and Overlapping rows carry text labels and a neutral style, contiguous Unknown or Overlapping rows group under one label, and many Unknown segments leave the header count unchanged

### Implementation for User Story 2

- [X] T042 [US2] Handle overflow turns and the Unknown/Ambiguous counters in `apps/macos/LocalFlow/Core/Diarization/MeetingDiarizer.swift` and `apps/macos/LocalFlow/Core/Storage/SpeakerStore.swift`. Make T040 pass
- [X] T043 [US2] Map `unknown` and `ambiguous` effective labels to "Unknown" and "Overlapping" rows (neutral, non-palette style, text always present) in `apps/macos/LocalFlow/Features/Transcripts/TranscriptPager.swift` and `apps/macos/LocalFlow/Features/Meetings/MeetingDetailView.swift`, and exclude them from the header count. Make T041 pass
- [ ] T044 [US2] Run the evaluation sweep over the RTTM fixtures, choose τ/δ and the alignment thresholds that keep wrong-speaker assignments under 5% of segments with the most speaker-labeled time, and record correct-time share, wrong-speaker share, Unknown/Ambiguous share, and confusion, missed speech, false alarm and DER only where RTTM exists in `specs/007-speaker-diarization/acceptance/accuracy.md` (SC-001, SC-002)
- [ ] T045 [US2] Freeze the values from T044 in `apps/macos/LocalFlow/Core/Diarization/SpeakerAligner.swift` and `apps/macos/LocalFlow/Core/Diarization/WindowClusterReconciler.swift`, bump their version tags and the pipeline version in `apps/macos/LocalFlow/Core/Diarization/DiarizationRun.swift` if any value changed, and update the edge tables in T021 and T023

**Checkpoint**: US1 and US2 together deliver trustworthy anonymous labels.

---

## Phase 5: User Story 3 — Name speakers with Assign speakers (Priority: P1)

**Goal**: The Assign speakers sheet names every voice at once, and the whole transcript relabels immediately.

**Independent Test**: Open Assign speakers on a diarized meeting, name two speakers, save, restart (reopen the store) and confirm every row for those clusters shows the new names. Change a name, Cancel, and confirm nothing changed.

### Tests for User Story 3

- [X] T046 [P] [US3] Create `apps/macos/LocalFlowTests/AssignSpeakersModelTests.swift`: sections one per display root in color order with the local speaker first; the field is prefilled with the current name and the placeholder is the anonymous label; Cancel, Escape and close discard edits; Save names issues one store call; names are trimmed, whitespace-only counts as empty and keeps the anonymous label; more than 80 characters or a control character shows an inline error and disables Save names; up to 8 plain-text suggestions, most recently used first, prefix-matched, and picking one only fills text; a named local speaker renders as "Name (You)"
- [X] T047 [P] [US3] Add naming cases to `apps/macos/LocalFlowTests/SpeakerStoreTests.swift`: Save names updates every `display_name` and inserts one `rename` correction per change in one transaction; a rename touches no turns, assignments, clusters or segments and starts no run; names persist across a reopened store; name suggestions come from distinct stored names across meetings; at 10,000 corrections per meeting the save is refused and nothing is written

### Implementation for User Story 3

- [X] T048 [US3] Add `saveNames`, `nameSuggestions(prefix:limit:)` and `speakerSummaries(meetingID:)` (id, display label, color index, source, root, `speech_ms`, empty quotes until US4, review entries) with the 10,000-correction refusal in `apps/macos/LocalFlow/Core/Storage/SpeakerStore.swift`. Make T047 pass
- [X] T049 [US3] Implement `AssignSpeakersModel` (draft names, validation, suggestions, save) in `apps/macos/LocalFlow/Features/Speakers/AssignSpeakersModel.swift`. Make T046 pass
- [X] T050 [US3] Build the sheet in `apps/macos/LocalFlow/Features/Speakers/AssignSpeakersView.swift` per `contracts/ui.md`: title "Assign speakers", subtitle "Name each voice and we'll relabel the whole transcript.", scrolling sections with color dot, caps anonymous label, quotes area and name field, the local section tinted with the caption "This Mac's microphone", a completion list for suggestions, Cancel and Save names, Tab order, Return saves, Escape cancels, and identifiers `meeting.speakers.assign`, `meeting.speakers.save`, `meeting.speakers.cancel`, `meeting.speakers.name.<ordinal>`
- [X] T051 [US3] Add "Assign speakers…" (enabled only with an accepted result) to the Speakers menu, present the sheet, and bump `labelsRevision` after save so rows and the header relabel within 1 s, in `apps/macos/LocalFlow/Features/Meetings/MeetingDetailView.swift` and `apps/macos/LocalFlow/Features/Speakers/SpeakerDiarizationCoordinator.swift`

**Checkpoint**: All P1 stories are done.

---

## Phase 6: User Story 4 — Useful representative quotes (Priority: P2)

**Goal**: Each speaker section shows up to three longer, confidently assigned quotes spread across the meeting.

**Independent Test**: For a speaker with many "OK." turns and a few long turns, the long, non-overlapping turns from different thirds are chosen, and reopening shows the same quotes.

### Tests for User Story 4

- [X] T052 [P] [US4] Create `apps/macos/LocalFlowTests/QuoteSelectorTests.swift`: best candidate per third, fill from remaining candidates by length, candidates need ≥ 4 words, ambiguous segments and manual reassignments to other speakers are excluded, fallback to the longest available segment when only short ones exist, ties broken by ordinal, stable output across calls

### Implementation for User Story 4

- [X] T053 [US4] Add the candidate query (up to 10 longest candidates per third of the meeting whose effective label is the speaker, ties by ordinal) in `apps/macos/LocalFlow/Core/Storage/SpeakerStore.swift`
- [X] T054 [US4] Implement `QuoteSelector` in `apps/macos/LocalFlow/Core/Diarization/QuoteSelector.swift` per research R9. Make T052 pass
- [X] T055 [US4] Fill `SpeakerSummary.quotes` from T053/T054 and render up to 3 quotes in quotation marks per section in `apps/macos/LocalFlow/Features/Speakers/AssignSpeakersModel.swift` and `apps/macos/LocalFlow/Features/Speakers/AssignSpeakersView.swift`

---

## Phase 7: User Story 5 — Merge and per-segment correction (Priority: P2)

**Goal**: The user can merge two speakers, undo the merge and change a single row's speaker, all meeting-local, manual and non-destructive to machine evidence.

**Independent Test**: Merge Speaker 1 into Speaker 4, confirm one label and a lower count with `speaker_turns` unchanged, undo it, then reassign one row, reopen the store and confirm the correction persists as manual with `auto_kind` unchanged.

### Tests for User Story 5

- [X] T056 [P] [US5] Add correction cases to `apps/macos/LocalFlowTests/SpeakerStoreTests.swift`: merge sets `merged_into` with a chain depth of 1 and inserts a `merge` correction; unmerge restores the earlier name and color; turn and automatic assignment counts are unchanged by merge, unmerge and segment corrections; a segment correction to a speaker, Unknown or a new manual speaker (`run_id` NULL, `origin` manual, `track` NULL) sets the `manual_*` columns and inserts a `segment` correction; all of it survives a reopened store (SC-007)
- [X] T057 [P] [US5] Add cases to `apps/macos/LocalFlowTests/AssignSpeakersModelTests.swift` and `apps/macos/LocalFlowTests/TranscriptPagerTests.swift`: merged speakers appear under their target as "Includes Speaker N" with Undo merge; two sections with the same name show "Same name as Speaker N" and a Merge button; merged pairs count once in the header and quotes; manually changed rows carry an "Edited" marker; only the corrected row relabels

### Implementation for User Story 5

- [X] T058 [US5] Add `merge`, `unmerge`, `correctSegment` (speaker, Unknown or new speaker) to `apps/macos/LocalFlow/Core/Storage/SpeakerStore.swift`, each in one transaction with its correction row and the 10,000-correction refusal. Make T056 pass
- [X] T059 [US5] Add the Merge into ▸ menu, "Includes Speaker N" with Undo merge, and the duplicate-name note with Merge in `apps/macos/LocalFlow/Features/Speakers/AssignSpeakersModel.swift` and `apps/macos/LocalFlow/Features/Speakers/AssignSpeakersView.swift`. Merge and unmerge apply immediately
- [X] T060 [US5] Add the row context menu "Change speaker ▸" (every display root, Unknown, New speaker; identifier `meeting.transcript.row.changeSpeaker`) and the "Edited" marker in `apps/macos/LocalFlow/Features/Meetings/MeetingDetailView.swift`, bumping `labelsRevision` in `apps/macos/LocalFlow/Features/Transcripts/TranscriptPager.swift`. Make T057 pass

---

## Phase 8: User Story 6 — Status, failure, retry and recovery (Priority: P2)

**Goal**: Every run state is visible, failures never touch primary data, reruns keep the accepted result until they succeed, and names and corrections carry over safely.

**Independent Test**: Inject a failure at window 2 and confirm the transcript, notes, audio and previous result are byte-identical with Retry offered. Simulate a crash mid-run, run launch reconciliation, and confirm `interrupted` with Retry. Rerun a named meeting and confirm old labels stay until adoption, safe names carry over and the rest are flagged.

### Tests for User Story 6

- [X] T061 [P] [US6] Create `apps/macos/LocalFlowTests/CorrectionCarryOverTests.swift`: a name maps only when overlap ≥ 0.50 × speech(S), ≥ 2 × the next-best overlap, reciprocal, and unique among named speakers; same source track only; a merge carries only when both members map to different new clusters; a segment correction carries only when the pass is unchanged and its target is mapped, Unknown or manual; everything else becomes `needs_review = 1` and is never applied; sweep pages of 1,000 turns; determinism
- [X] T062 [P] [US6] Add fault-injection and rerun cases to `apps/macos/LocalFlowTests/MeetingDiarizerTests.swift`: each failure category (`model_unavailable`, `os_unsupported`, `model_load_failure`, `audio_missing`, `audio_decode_failure`, `runtime_failure` including more than 20,000 turns in a window, `transcript_changed`, `persistence_failure`, `persistence_capacity`) leaves transcript rows, notes, audio files and the accepted run byte-identical and deletes only the run's rows; cancellation between windows and alignment pages joins and deletes the run; preemption during steps 2–4 joins the in-flight window and returns the run to `pending`; alignment and completion are not preemptible; a rerun that fails keeps the accepted result; a rerun that succeeds adopts in one transaction with carry-over (SC-006)
- [X] T063 [P] [US6] Add cases to `apps/macos/LocalFlowTests/SpeakerDiarizationCoordinatorTests.swift`: Retry after `failed` and `interrupted` creates a new pending run; a preempted run goes back to the queue head with `preemption_count + 1` and resumes when the lifecycle has no lease; `transcript_changed` re-enqueues automatically when enabled; the in-room toggle updates `in_room` and admits an `in_room_change` run; Cancel while pending or running deletes the run; with a pending re-finalized pass the stale result is not shown and an automatic run is enqueued

### Implementation for User Story 6

- [X] T064 [US6] Implement `CorrectionCarryOver` (`carry_ovl0.50_ratio2_v1`) in `apps/macos/LocalFlow/Core/Diarization/CorrectionCarryOver.swift` per research R7. Make T061 pass
- [X] T065 [US6] Run carry-over inside the Complete transaction (streamed 1,000-turn sweep pages, `needs_review` rows) and add `dismissReview` in `apps/macos/LocalFlow/Core/Storage/SpeakerStore.swift`
- [X] T066 [US6] Map every failure cause to its category per the failure mapping table, check cancellation and the transcript `pass_id` between windows and alignment pages, and join the in-flight window on preemption in `apps/macos/LocalFlow/Core/Diarization/MeetingDiarizer.swift`. Make T062 pass
- [X] T067 [US6] Add Retry, Cancel, preemption requeue at the queue head, `transcript_changed` re-enqueue and the in-room change trigger to `apps/macos/LocalFlow/Features/Speakers/SpeakerDiarizationCoordinator.swift`. Make T063 pass
- [X] T068 [US6] Extend the Speakers menu and status line in `apps/macos/LocalFlow/Features/Meetings/MeetingDetailView.swift`: In-room meeting (checkmark), Re-run speaker labels, Retry, Cancel speaker labeling; failed category messages (for example "Speaker labeling model isn't installed. Install it in Settings → Models." and "Speaker labeling needs macOS 15 or later."), "Speaker labeling was interrupted." with Retry, and "Updating speaker labels…" with the accepted labels still visible during a rerun
- [X] T069 [US6] List "Couldn't carry over: <name>" review notices at the top of the sheet, each dismissible, in `apps/macos/LocalFlow/Features/Speakers/AssignSpeakersModel.swift` and `apps/macos/LocalFlow/Features/Speakers/AssignSpeakersView.swift`

---

## Phase 9: User Story 7 — Copy a speaker-labeled transcript (Priority: P3)

**Goal**: Copy yields `Label:\n<text>` blocks with current display names and no hidden metadata.

**Independent Test**: Copy a named, diarized transcript and compare it with the expected blocks. Copy an undiarized transcript and confirm the Feature 006 output is unchanged.

### Tests for User Story 7

- [X] T070 [P] [US7] Add cases to `apps/macos/LocalFlowTests/TranscriptPagerTests.swift`: consecutive rows with the same label are joined with newlines under `Label:`, blocks are separated by a blank line, output is chronological, no confidence, keys or ids appear, undiarized copy equals Feature 006, and search matches speaker display names

### Implementation for User Story 7

- [X] T071 [US7] Implement labeled copy (paged, not loading the whole meeting at once) and display-name search in `apps/macos/LocalFlow/Features/Transcripts/TranscriptPager.swift`, and hook it to the existing Copy action in `apps/macos/LocalFlow/Features/Meetings/MeetingDetailView.swift`. Make T070 pass

---

## Phase 10: Polish, instrumentation and acceptance

**Purpose**: FR-037 metrics, debug flags, documentation and the hardware evidence.

- [X] T072 [P] Add the FR-037 metrics from `contracts/diarization-pipeline.md` "Instrumentation" (`diarizationModelLoadDuration` through `speakerSegmentCorrectionCount`, failure keyed by category) to `apps/macos/LocalFlow/Core/Observability/ResourceRecorder.swift`, emit them from `MeetingDiarizer`, `SpeakerDiarizationCoordinator` and `SpeakerStore`, and extend the content-free test in `apps/macos/LocalFlowTests/ResourceRecorderTests.swift` to prove no names, text, quotes, embeddings, audio or paths are recorded
- [X] T073 [P] Add a test in `apps/macos/LocalFlowTests/RuntimeCompatibilityTests.swift` that no networking symbol (`URLSession`, `Network`) is referenced from `apps/macos/LocalFlow/Core/Diarization/` or `apps/macos/LocalFlow/Features/Speakers/`, and that `ModelHub.offlineMode` is true after `AppServices` starts (FR-036)
- [X] T074 Add debug-only flags `--debug-fail-diarization window=N`, `--debug-slow-diarization <s>` and `--debug-seed-diarization` in `apps/macos/LocalFlow/App/AppServices.swift`, compiled out of release builds
- [X] T075 [P] Add diarization sections to `docs/architecture/model-lifecycle.md` (workload key, preemption, no co-residency), `docs/architecture/storage.md` (`speakers-v7`, cascades, capacities) and `docs/architecture/audio-pipeline.md` (per-track windows, timeline offsets)
- [ ] T076 Capture native screenshots of the labeled transcript, status line and Assign speakers sheet at wide, compact and dark sizes with synthetic records (`--debug-seed-diarization`), and store them with `specs/007-speaker-diarization/acceptance/naming.md`
- [ ] T077 On the reference machine, record the 60-minute run and the 8-hour synthetic concatenation sampled every 10 s (baseline, model-load increase, peak, slope gate < 1 MB/10 min, post-release gate ≤ baseline + 20 MB, RTF, window count, hardware, OS, build, model and pipeline version) in `specs/007-speaker-diarization/acceptance/long-run-memory.md` (SC-004, SC-005)
- [ ] T078 Time naming four speakers (under 1 min) and relabel after Save names (≤ 1 s) and record it in `specs/007-speaker-diarization/acceptance/naming.md` (SC-003)
- [ ] T079 Run the quickstart "Failure, rerun and recovery" list (failure mid-run, `kill -9`, rerun on a named meeting, dictation during a run, re-transcribe, delete during a run, missing audio, model not installed) and record results in `specs/007-speaker-diarization/acceptance/recovery.md` (SC-006)
- [ ] T080 Run the quickstart privacy checks (no connections under `nettop` or Little Snitch, no typed names or text in `log show` or the recorder CSV, no diarization rows after deleting the meeting) and record them in `specs/007-speaker-diarization/acceptance/privacy.md` (SC-008)
- [X] T081 Run `make check`, confirm every Feature 001–006 suite passes unchanged (SC-009), and confirm every new file is in `apps/macos/LocalFlow.xcodeproj/project.pbxproj`

---

## Dependencies and execution order

### Phase dependencies

- **Setup (Phase 1)**: none. T003 must finish before the manifest from T002 counts as complete.
- **Foundational (Phase 2)**: after Setup. Blocks every story. T016 (hardware) may finish later; stories use the provisional constants until then.
- **US1 (Phase 3)**: after Phase 2. The MVP.
- **US2 (Phase 4)**: after US1 (it extends the diarizer, pager and view). T044–T045 also need the evaluation set.
- **US3 (Phase 5)**: after US1 (needs speakers and the Speakers menu). Independent of US2.
- **US4 (Phase 6)**: after US3 (fills the sheet's quotes).
- **US5 (Phase 7)**: after US3 (merge lives in the sheet). The row correction (T060) needs only US1.
- **US6 (Phase 8)**: after US1. T069 needs US3; carry-over of merges and segment corrections is only exercised once US5 exists, but T064–T065 can be built and tested against fixtures earlier.
- **US7 (Phase 9)**: after US1. Independent of the other stories.
- **Polish (Phase 10)**: after the stories it measures. T077–T080 need a signed build on the reference machine.

### Story completion order

```text
Setup → Foundational → US1 ─┬→ US2
                            ├→ US3 ─┬→ US4
                            │       └→ US5
                            ├→ US6 (T069 after US3)
                            └→ US7
                                   → Polish
```

### Within each story

Tests first and failing, then store, then pure logic, then pipeline and coordinator, then UI. A story is done when its checkpoint test passes in `make check`.

## Parallel opportunities

- Phase 1: T002, T003, T004 and T005 are independent files.
- Phase 2: T009, T012, T013, T017 and T021/T022 touch separate files; T006 → T007 → T008 and T018 → T019 → T020 are sequential chains.
- US1: all five test tasks (T023–T027) in parallel, then T028, T032 and T035 in parallel with T029.
- US2: T040 and T041 in parallel.
- US3: T046 and T047 in parallel.
- US5: T056 and T057 in parallel.
- US6: T061, T062 and T063 in parallel; T064 alongside T066.
- After US1, US3/US6/US7 can be worked by different people at once; US2 conflicts with US7 only in `TranscriptPager.swift`.
- Polish: T072, T073 and T075 in parallel.

### Parallel example: User Story 1

```text
T023 WindowClusterReconcilerTests.swift
T024 MeetingDiarizerTests.swift
T025 SpeakerDiarizationCoordinatorTests.swift
T026 DiarizationReconcilerTests.swift
T027 TranscriptPagerTests.swift
then: T028 WindowClusterReconciler.swift | T032 AppPreferences + SettingsView | T035 SpeakerPalette.swift
```

### Parallel example: User Story 6

```text
T061 CorrectionCarryOverTests.swift
T062 MeetingDiarizerTests.swift (fault injection)
T063 SpeakerDiarizationCoordinatorTests.swift
then: T064 CorrectionCarryOver.swift alongside T066 MeetingDiarizer.swift
```

## Implementation strategy

### MVP first (US1)

1. Phase 1 and Phase 2, with T016 scheduled on the reference machine.
2. Phase 3 (US1).
3. Stop and validate: a finalized fixture meeting shows You / Speaker N with a correct count and byte-identical transcript, notes and audio.

### Incremental delivery

1. US1 → labeled transcript (MVP).
2. US2 → Unknown/Overlapping and frozen thresholds; safe to feed the future summary feature.
3. US3 → names. All P1 stories done.
4. US4 → quotes; US5 → merge and correction; US6 → failure UI, rerun and carry-over.
5. US7 → labeled copy.
6. Polish → metrics and the hardware acceptance files. No target counts as met until its acceptance file records it.
