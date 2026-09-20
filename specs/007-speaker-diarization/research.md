# Research: speaker diarization and speaker assignment

Date: 2026-09-18. Spec: [spec.md](spec.md). Every item below is a decision with its rationale and the alternatives set aside. Values marked **provisional** are frozen by the Phase 2 measurement step and recorded in `acceptance/`; none is presented as measured.

## R1. Engine

- **Decision**: FluidAudio 0.15.7 `OfflineDiarizerManager` (the pyannote community-1 pipeline: powerset segmentation, WeSpeaker embeddings, PLDA, AHC warm start, VBx refinement), running over bounded windows (R4). Assets come from `FluidInference/speaker-diarization-coreml`, offline variant: `Segmentation.mlmodelc`, `FBank.mlmodelc`, `Embedding.mlmodelc`, `PldaRho.mlmodelc`, `plda-parameters.json`.
- **Rationale**: This is the library LocalFlow already ships (ADR 0002 names a future `DiarizationEngine` on FluidAudio), so no dependency is added. The offline pipeline infers the speaker count and has no fixed speaker cap (FR-004, FR-005). It is deterministic for fixed input (US2 scenario 3), it can output overlapping turns (FR-011), and it has the best offline accuracy of the FluidAudio diarizers.
- **Alternatives**: Sortformer caps at 4 speakers, which fails FR-005. LS-EEND is a streaming research model with more false alarms and weaker stability. `DiarizerManager` is the legacy online pipeline, the weakest option in noise and overlap. A second library would add a dependency without a measured gain.

## R2. Loading without downloads

- **Decision**: The app never calls `OfflineDiarizerManager.prepareModels()`, which purges its cache and re-downloads after a failed load, and never lets `prepare()` reach it. That second path is closed by always calling `initialize(models:)` first. `AppServices` sets `ModelHub.offlineMode = true` once at launch. `FluidAudioDiarizerFactory` then calls `OfflineDiarizerModels.load(from:)` against the app-owned directory, so a missing file throws a typed error and never triggers a fetch. Offline mode also stops `ModelHub` from purging a cache it considers corrupted, which would otherwise delete the provisioned files. The factory refuses to load unless `ModelHub.offlineMode` is true. It verifies the pinned descriptor first, the same way `FluidAudioEngineFactory` does.
- **Provisioning**: Add a pinned manifest `Resources/Models/speaker-diarization-offline.json` with the new `ModelCapability.speakerDiarization` (`automaticLanguage: false`, which `validate()` requires for non-ASR descriptors), a 40-hex source revision, file sizes and SHA-256 hashes. It installs through the existing `ModelProvisioner` into its own directory, laid out as `ModelHub` expects (`<root>/speaker-diarization/…`; FluidAudio's `Repo.diarizer.folderName` drops the `-coreml` suffix, so the app installs into `Models/speaker-diarization-offline/speaker-diarization`). Settings shows a separate Speaker labels model row with the same Install/Verify flow. A missing model gives the run state `failed(model_unavailable)` with guidance, and transcription is untouched.
- **Rationale**: This keeps the Feature 001 rule "direct local URLs only, never a download-capable loader", reuses the verification and licence path, and needs no custom PLDA decoder.
- **Alternatives**: Building `OfflineDiarizerModels` through its public init and decoding `plda-parameters.json` ourselves (more code for the same result). Letting FluidAudio download into its default cache (a silent network path, rejected by FR-036).
- **Licence review (task)**: Record the licences of the pyannote community-1 segmentation, WeSpeaker ResNet34 and PLDA assets at the pinned revision in `docs/licenses` and `THIRD_PARTY_NOTICES.md` before the manifest is marked complete.

## R3. Model lifecycle

- **Decision**: `ModelLifecycleCoordinator` becomes keyed by workload and keeps one exclusive lease and one resident runtime. `acquire(session:workload:)` takes `.speechRecognition` (the default, so existing callers are unchanged) or `.diarization`. A second factory builds `any DiarizationRuntime`. When the requested workload differs from the resident runtime, `acquire` calls `beginRelease()` before preparing, which replaces the fast path `if runtime != nil { return lease }`. That guarantees ASR and the diarizer are never resident together (FR-032). `diarize(_:window:)` is the only diarization inference entry. `finish` on a diarization lease releases the runtime immediately, with no 30-second cooldown.
- **Priority**: A speech-recognition `acquire` (dictation, live meeting, finalization) that finds a diarization owner revokes that lease through `cancelAndJoin`. This waits for the in-flight Core ML prediction, then releases the runtime, and then proceeds. A diarization `acquire` that finds any owner throws `busy`. The diarization coordinator returns a preempted run to the head of its queue as `pending` (preemption count +1) and pumps again when the lifecycle reports no lease. A preempted run restarts from its first window, because within-run embeddings are never persisted (FR-036). This is acceptable because a 60-minute diarization is expected to take minutes of work (confirmed in Phase 2). The preemption count is recorded.
- **Idle retention (ADR 0007)**: With Keep model ready on, diarization still releases ASR first (the exclusivity default), and the coordinator re-prepares ASR once the diarization lease ends. Retention is a residency preference, not a license for co-residency.
- **Alternatives**: A second coordinator for diarization, which would break the single-authority principle (constitution 3). Keeping ASR resident during diarization, which would need an exception ADR backed by measurements.

## R4. Bounded windows and cross-window reconciliation

- **Problem**: `prepare()` keeps every embedding for the whole input, and `cluster()` copies them into `[[Double]]` and runs `fastcluster` centroid linkage plus VBx. That work grows superlinearly in time with the embedding count. At the default 10 s window and 0.2 step ratio, 8 hours means about 14,400 chunks with up to 3 embeddings each, which is not bounded for the Feature 005 maximum.
- **Decision**: Diarize each track in windows of at most **10 minutes of audio (9,600,000 samples at 16 kHz, 38.4 MB Float32; provisional, candidates 10 and 20 minutes)**. A window never crosses a stretch boundary, so no turn spans a pause gap. Windows inside a stretch are contiguous and do not overlap, and turns are clipped to the window. One reusable `[Float]` buffer is refilled per window and passed through `ArrayAudioSampleSource`. The segmentation-to-embedding `AsyncThrowingStream` in `prepare()` uses the default unbounded buffer, so no chunk is dropped, and the window size bounds its backlog.
- **Reconciliation** (`WindowClusterReconciler`, pure, versioned `xwin_cos_greedy_v1`): the runtime sets `exposeChunkEmbeddings = true`. Each window cluster's centroid is the L2-normalized mean of that cluster's `ChunkEmbedding.embedding256` values, matched on `speakerId`, so every centroid has the same dimension. `speakerDatabase` is not used: it is optional and traps on a dimension mismatch. A cluster that has segments but no chunk embedding gets no centroid, becomes a new run cluster marked `uncertain`, and is never matched. Pairs of (window cluster, run cluster) from the same track are sorted by cosine similarity descending, ties broken by window cluster id, then run cluster key. They are matched greedily one-to-one. A pair is **matched** when similarity ≥ τ = **0.70** and exceeds that window cluster's next-best run cluster by ≥ δ = **0.10** (both provisional). A cluster with no pair at τ becomes a **new** run cluster. A cluster with a pair at τ but a margin under δ also becomes a new run cluster, marked `reconciliation = uncertain`, so the user can merge it. It is never guessed into a match. Run-cluster centroids are duration-weighted means kept in memory for the run only and discarded at the end (FR-036). State is bounded by the cluster count, not by duration.
- **Capacity**: 64 run clusters per track per run. This is a working-memory capacity, not an acceptance limit (2–6 speakers). Turns from a window cluster that arrives beyond it are stored with no cluster (`speaker_id NULL`) and counted as `reconciliation_overflow`. They therefore align to Unknown and are never truncated silently.
- **Alternatives**: Whole-file `process(url)` (not bounded at 8 hours). Overlapping windows with turn-level stitching (more code; revisit only if Phase 2 shows boundary errors). Persisting window centroids for mid-run resume (keeps embeddings beyond a window, adds a table, and brings little benefit at the expected run times).

## R5. Source-aware attribution

- **Decision**: The microphone and system tracks are diarized separately, each decoded to mono 16 kHz with `AnalysisStreamMixer(decoding:)` given a single-track format map. That reuses the 005 decode and resample path without mixing the tracks (FR-008).
  - **System track**: unconstrained clustering, which produces remote clusters labeled Speaker N.
  - **Microphone track, default**: `clustering.numSpeakers = 1`, which produces exactly one local speaker, "You" (FR-009). The segmentation model still supplies its speech/non-speech boundaries, so no VAD model is added.
  - **Microphone track, in-room toggle on**: unconstrained, which produces local speakers Local N, kept distinct from remote clusters.
- **Configuration**: `postProcessing.exclusiveSegments = false`, so overlap survives (FR-011). `embedding.excludeOverlap` stays at its default. The other community defaults are unchanged, and the pipeline version string records the configuration.
- **Echo and bleed**: Remote voices played through speakers into the microphone produce local turns during remote speech. The alignment rule (R6) then labels those segments Overlapping rather than guessing. System audio that contains the local voice may form a remote cluster. Each turn and cluster keeps its source track, which lets the future identification feature detect this. The evaluation set includes a speaker-playback fixture, and results are reported rather than claimed as solved.

## R6. Alignment rule

- **Decision** (`SpeakerAligner`, pure, versioned `align_dom0.60_ratio2_ovl0.20_v1`): for each final transcript segment [start, end), compute each speaker's coverage as the length of the union of that speaker's turns intersected with the segment, divided by the segment duration. Let the top two coverages be c1 ≥ c2, with ties broken by lower speaker key.
  - `speaker` if c1 ≥ **0.60** and c1 ≥ **2 × c2**.
  - Otherwise `ambiguous` (shown as Overlapping) if c2 ≥ **0.20**.
  - Otherwise `unknown`.
  - Turns with no cluster (R4 overflow) count toward no speaker.
- All three thresholds are provisional and confirmed against the evaluation set in Phase 2 (FR-014). The chosen values target SC-001: wrong-speaker assignments under 5% of segments, even if that means more Unknown. The rule reads turns only, never text (FR-001). Coverage values (c1, c2 and both speaker ids) are stored as evidence (FR-015).
- **Merges** do not rerun alignment. A merged pair is displayed as one speaker. An ambiguous segment stays ambiguous unless the user corrects it.

## R7. Carry-over of names and corrections (FR-027)

- **Decision** (`CorrectionCarryOver`, pure over streamed overlaps, versioned `carry_ovl0.50_ratio2_v1`): for each pair of old speaker (with a name, a merge or a segment correction) and new cluster **from the same source track**, compute their overlap in milliseconds with a sweep over both runs' turns, read in start order in pages of 1,000. An old speaker S maps to new cluster N when all of these hold:
  - overlap(S, N) ≥ **0.50** × speech(S),
  - overlap(S, N) ≥ **2 ×** the next-best overlap for S,
  - N's best old speaker is S (reciprocal),
  - no other named speaker maps to N.
- **Effects**:
  - Names follow mapped speakers.
  - A merge is carried only when both members map to different new clusters.
  - A segment correction is carried only when the transcript pass is unchanged (same segment id) and its target is mapped, Unknown or a manual speaker.
  - Everything else becomes a correction row with `needs_review = 1`, listed in Assign speakers as "Couldn't carry over: <name>". It is never applied.
- **Alternatives**: Carrying over by label ordinal (unsafe, because clusters renumber). Asking the user before adoption (blocks unattended runs).

## R8. Scheduling and recovery

- **Decision**: `SpeakerDiarizationCoordinator` (main actor) owns a queue of at most **100** meeting ids with deduplication and one active run.
  - **Triggers**: after `MeetingTranscriptionCoordinator` publishes `final` for a meeting and the finalization lease has finished. It runs automatically only when the `meetingDiarizationEnabled` preference (default on) is set and the model is installed. Run and Retry actions are always available (FR-002).
  - **Overflow**: an automatic request beyond capacity is not queued, and the meeting stays `not_requested` with Run available. A manual request beyond capacity shows "Speaker labeling queue is full".
  - **Launch reconciliation** (`DiarizationReconciler`, chained after `TranscriptReconciler`, at most 100 rows): `running` becomes `interrupted` (its rows are deleted and the accepted result is kept), and `pending` is re-enqueued.
  - **Deletion**: `meetingWillDelete` cancels and joins the run, and foreign keys cascade the rows.
- **Re-finalized transcript**: A run records the transcript `pass_id` it aligned against. If the pass changes, the accepted result stops being shown (source labels return), and an automatic run is enqueued if enabled. A run whose transcript pass changes mid-run is discarded as `failed(transcript_changed)`.
- **OS gate**: `OfflineDiarizerManager` is exposed to an Apple BNNS crash on macOS 14 (FluidAudio issue #878). Diarization requires macOS 15 or later. On macOS 14 the run is `failed(os_unsupported)` with an explanation, and nothing loads. The deployment target stays 14.0.

## R9. Display

- **Colors**: A fixed palette of 8 colors (`SpeakerPalette`), each checked for contrast in light and dark mode. The color index is assigned at adoption by first-turn order (ties broken by key) and cycles after 8. Labels always carry text, and color is never identity (FR-017).
- **Labels**:
  - "You" or "Name (You)" for the default local speaker.
  - "Local N" or "Name" with the in-room toggle on.
  - "Speaker N" or "Name" for remote clusters.
  - "Unknown" and "Overlapping" for unassigned segments.
  - N is the first-appearance order within a source and stays stable after merges.
- **Paging**: `TranscriptPager` pages stay at 200 rows with 2 resident. Each page query left-joins the effective assignment for the accepted run, so labels arrive together with their page and cannot mix results. The meeting's speaker rows (at most 64 per source plus manual speakers) stay resident per meeting. A result change bumps a `labelsRevision` and reloads the first page (FR-019, the tab-switching edge case).
- **Quotes** (`QuoteSelector`, deterministic): candidates are segments whose effective label is the speaker, excluding manual reassignments to other speakers and ambiguous segments. The meeting is split into thirds. SQL fetches up to 10 of the longest candidates per third (ties broken by ordinal), and Swift keeps those with ≥ 4 words. The selector takes the best one per third, fills from the remaining candidates by length, and falls back to the longest available segment (FR-023).
- **Suggestions**: distinct stored display names across meetings that match the typed prefix, at most 8, most recently used first. They are plain text only (FR-028).

## R10. Measurements the plan leaves open

The Phase 2 harness (`DiarizationThroughputHarness`, real engine, reference M5 32 GB) measures the following and freezes them into `acceptance/throughput.md`:

- model load time and RSS increase;
- RTF per window size (10 and 20 minutes);
- peak RSS and RSS slope over a 60-minute meeting and over a synthetic 8-hour concatenation;
- RSS after release;
- τ/δ and the alignment thresholds against the evaluation set.

The SC-005 gates are set as the measured maximum × 1.5, rounded up, the same rule used by Feature 005.
