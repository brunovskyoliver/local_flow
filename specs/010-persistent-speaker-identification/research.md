# Research: persistent speaker identification

Date: 2026-09-20. Spec: [spec.md](spec.md). Each item is a decision, its rationale and the alternatives set aside. Values marked **provisional** are frozen by the Phase 2 calibration and measurement step and recorded under `acceptance/`; none is presented as measured. The spec's Assumptions section listed the defaults this research had to confirm or replace; every one is settled below.

## R1. Embedding engine: the provisioned diarization models, no second model

- **Decision**: Voice embeddings come from the WeSpeaker ResNet34-LM embedding model that Feature 007 already provisions (`FluidInference/speaker-diarization-coreml`, offline variant: `FBank.mlmodelc` + `Embedding.mlmodelc`, 256 dimensions, L2-normalized). A new `VoiceEmbeddingRuntime` protocol has one production implementation, `FluidAudioVoiceEmbedder`, which loads the same `OfflineDiarizerModels` from the same verified `LocalModelDescriptor` and runs an `OfflineDiarizerManager` configured with `clustering.numSpeakers = 1`, `exposeChunkEmbeddings = true` and `postProcessing.exclusiveSegments = false` over one speech region at a time. The region embedding is the duration-weighted, L2-normalized mean of the `ChunkEmbedding.embedding256` values of the dominant cluster in that region, which is the same reduction `FluidAudioDiarizer.map` already applies to window centroids. Regions are 3–20 s (R4), so a region is one or two segmentation chunks.
- **Model identity stored with every sample and run**: `engine = wespeaker_resnet34lm_256`, `model_id = FluidInference/speaker-diarization-coreml`, `model_revision = 1ed7a662…` (the manifest's `sourceRevision`), `model_manifest_hash` (SHA-256 of the manifest, as `diarization_runs` records it), `dimension = 256`, `pipeline_version = embed_offline1spk_dw_v1`. Compatibility (FR-028) is equality on engine, model id, revision and dimension. A future model change bumps the revision or the engine, and existing samples stay stored but stop being compared.
- **Rationale**: The same toolkit, the same files and the same licence review as Feature 007. No new manifest, no new download, no second Settings model row, and the diarization centroids and the stored samples live in one vector space, which lets the calibration corpus reuse the 007 evaluation fixtures. The full model set is about 21 MB of weights, and the segmentation model doubles as the speech detector inside a region, so silence and non-speech inside a chosen region do not enter the embedding.
- **Alternatives**: `CampPlusEmbedder` (FluidAudio 0.15.7, 192-d): purpose-built for verification and small, but marked beta, needs a second pinned manifest, a second licence review and a second lifecycle workload, and its embeddings are not comparable to the diarization space. Kept as the documented upgrade path if calibration on WeSpeaker misses SC-001 to SC-003. Calling the public `fbankModel` and `embeddingModel` `MLModel`s directly: fewer moving parts per call, but the mask and batch shapes are internal to `OfflineEmbeddingExtractor` and change between SDK versions; rejected as fragile. Persisting per-cluster centroids during diarization: rejected because 007 guarantees that no embedding outlives a run, and enrollment happens later, at naming time, after consent.

## R2. Model lifecycle: a fourth workload, same coordinator, same rules

- **Decision**: `ModelWorkload` gains `.speakerIdentification`. `ModelLifecycleCoordinator` gains a `VoiceEmbeddingFactory`, a `Resident.embedding(any VoiceEmbeddingRuntime)` case and one inference entry, `embed(_ lease:, region: VoiceRegionRequest) -> VoiceEmbedding`. The workload-switch release, the "speech workloads preempt, identification never preempts", the no-cooldown `finish` and the Keep-ready re-prepare are the diarization rules applied unchanged. An identification `acquire` that finds any owner throws `busy` and the run stays `pending`.
- **Ordering (FR-022)**: `SpeakerDiarizationCoordinator` publishes `diarizationDidAdopt(meetingID:)` after the diarization lease has finished and the adoption transaction has committed. `SpeakerIdentificationCoordinator` observes it and enqueues an automatic run. Because the coordinator holds one lease at a time and identification acquires its own lease, the diarizer is never resident while the embedder loads. The embedder is released by `finish` at run end, on failure, on cancellation and on preemption.
- **Rationale**: One authority for heavy models (constitution 3). Reusing the loaded-model type but not the lease keeps the ordering rule visible in the coordinator instead of implicit in a shared lease.
- **Alternatives**: Reusing the diarization lease and running identification inside the diarization run (violates FR-022's "after diarization released its model" and couples two run tables). A separate coordinator for embeddings (breaks constitution 3).

## R3. Audio access: a single sequential pass per stretch file, one region resident

- **Decision**: `VoiceRegionReader` opens each ADTS stretch file the same way `MeetingDiarizer.diarizeStretch` does (`AVAudioFile`, 4,096-frame reads, `AnalysisStreamMixer(decoding:)` with a one-track format map, 16 kHz mono output). Regions requested from that file are sorted by start time and consumed in one forward pass: samples outside every region are discarded as they are decoded, and a region's samples are handed to the embedder as soon as its end is reached, then dropped. The reader never seeks and never keeps more than one region (≤ 320,000 samples, 1.25 MB) plus the decode buffers in memory. Region times on the recorded timeline map to a stretch and an in-file offset through the same `transcriptBases` computation the diarizer uses.
- **Rationale**: Constitution 6 (no full meeting audio in memory) and spec "Bounded audio". Sequential decoding avoids AAC seek imprecision (priming frames) and reuses the 005 decode path without a new decoder.
- **Alternatives**: `AVAudioFile.framePosition` seeking per region (fewer decoded bytes but AAC seek lands on packet boundaries and the priming offset is codec-specific; rejected until measured as necessary). Reading through `MeetingFinalizer` work items with a sample sink (would change 005 code).

## R4. Region eligibility and selection (FR-003, FR-004)

- **Decision** (`VoiceRegionSelector`, pure, versioned `regions_v1`). Input: the accepted diarization run's turns for one display root (the root and every speaker merged into it) on one track, every other turn of the run on both tracks in the same time span, and the run's engine quality values. Output: an ordered list of regions with a quality label.
  - A candidate region is one turn with `overlapped = 0` that does not intersect any turn of another speaker on either track, trimmed by 0.2 s at each end.
  - Duration ≥ **3.0 s** (provisional). Regions over **20 s** are cut to their first 20 s. Three seconds of continuous single-speaker speech excludes one-word acknowledgements without reading transcript text; if calibration shows short acknowledgements slipping through, the selector may additionally require an overlapping transcript segment with ≥ 3 words (a count, never the text).
  - `engine_quality`, when present, ≥ **0.5** (provisional). Absent quality does not disqualify.
  - After decoding, a region is rejected as `clipped` when more than 0.1% of its samples have |x| ≥ 0.99, and as `too_quiet` when its RMS is below −45 dBFS (provisional). Rejections are counted per reason, never logged with times.
  - Ranking: the meeting is split into five equal spans; the longest eligible region in each span is taken first, then the remaining longest regions, up to **5 regions and 100 s of audio for enrollment** and **4 regions and 60 s for a match query** (provisional). The label is `good` when duration ≥ 6 s and quality ≥ 0.7 (or absent), otherwise `fair`.
  - A cluster with no eligible region enrolls zero samples and the user is told "No usable voice sample was found" (US1 scenario 3). For a query it stays Unknown with reason `no_regions`.
- **Rationale**: Same-speaker embeddings of clean single-speaker speech are what the model was trained to compare; spread across the meeting covers channel drift and speaking styles (FR-004). Every number is a named constant that feeds the pipeline version string, so a change is visible in stored rows.
- **Alternatives**: Using whole-cluster centroids from diarization (not available after a run; also averages overlap and noise in). Random sampling (not reproducible).

## R5. Sample storage and the per-speaker cap (FR-005, FR-006, FR-027)

- **Decision**: One sample = one region's embedding, stored as a 1,024-byte `BLOB` of 256 little-endian Float32 values in `voice_samples`, with the model identity, quality label and score, source meeting, source speaker, track, start and end, creation date and an `active` flag. Samples are never averaged into one vector; matching compares against each sample (R6).
  - **Cap**: **10 active samples per known speaker per model identity** (provisional, the spec's "on the order of 10"). When adding would exceed it, `SampleRetirementPolicy` (pure, versioned `retire_qd_v1`) scores every active sample plus the newcomers as `0.6 × quality_score + 0.4 × (1 − max cosine to any other retained sample)` and retires the lowest-scoring until the cap holds. Retired samples get `active = 0` and `retired_at`; at most 10 retired samples are kept per speaker, oldest deleted first, so a speaker holds at most 20 rows per model identity. Retired samples are not compared and are not shown in the UI count.
  - **Consent trail**: every sample row carries `consent = remember | also_remember | local_enroll`, matching the explicit action that created it (FR-001, FR-008).
- **Rationale**: Individual samples let the policy weigh support and diversity (FR-013) and let the user remove one (FR-032). A 1 KB structured value in SQLite is not media and stays inside the history ceiling; constitution 7's "media in files" rule concerns audio. Keeping a few retired rows makes "why did my sample count drop" debuggable without unbounded growth.
- **Alternatives**: Averaged prototype per speaker (loses diversity, forbidden by FR-005 without toolkit guidance). Files per sample (adds a second store to clean on delete).

## R6. Matching policy and certainty tiers (FR-009 to FR-014)

- **Decision** (`IdentityMatcher`, pure, threshold policy `tiers_v1`). For one remote display root with query region embeddings `r_1…r_k` (weights = region durations) and the candidate set `C` (known speakers with `recognition_enabled = 1`, not the local-user profile, at least one active compatible sample, and not in `rejected_candidates` for this cluster):
  - `sim(r_i, c)` = mean of the top `min(3, |samples(c)|)` cosine values between `r_i` and `c`'s active compatible samples.
  - `score(c)` = duration-weighted mean of `sim(r_i, c)` over the regions.
  - `support(c)` = number of `c`'s samples whose best cosine against any region ≥ `τ_medium`.
  - Let `c1`, `c2` be the top two by score. Tier:
    - **Recognized** when `score(c1) ≥ τ_high`, `score(c1) − score(c2) ≥ δ` (or no `c2`), `support(c1) ≥ 2`, and the query's total region audio ≥ 6 s.
    - **Possible match** when `score(c1) ≥ τ_medium` and not Recognized. When `c2` is within `δ`, both are recorded as candidates and the sheet lists `c2` under Choose another.
    - **Unknown** otherwise. No name is shown, not even the nearest (FR-011).
  - Provisional values for this model: **τ_high = 0.72, τ_medium = 0.55, δ = 0.10**. Every candidate's score, tier and reason flags (`below_medium`, `margin`, `support`, `min_speech`, `rejected`) are written to `match_candidates` for the run (FR-019, FR-020).
  - The local-user profile, if present, is scored against each remote root and stored with tier `local_evidence`; it never names or suggests anything (FR-016, FR-017).
- **Calibration (FR-012)**: `IdentificationCalibrationHarness` (XCTest, skipped without `LOCALFLOW_CALIBRATION_ROOT`) enrolls each speaker of the corpus from one meeting, queries every other cluster, and writes the same-person and different-person score distributions, the false-accept and miss rates at candidate thresholds, and the margin sensitivity to `acceptance/calibration.md`. `τ_high` is the smallest value at which different-person automatic acceptance is 0 on the corpus with at least a 0.05 buffer above the highest different-person score; `τ_medium` is chosen so that non-enrolled clusters are suggested in under 5% of cases (SC-003) while at least 70% of enrolled clusters with ≥ 3 samples reach Possible or better (SC-002). The frozen values live in `IdentificationThresholds` keyed by model identity and are part of the threshold policy version stored with every assignment. UI code never sees a number.
- **Rationale**: Top-k mean against individual samples is the standard multi-enrollment scoring for x-vector-style embeddings; the support and minimum-speech conditions implement FR-013 and keep single-sample profiles conservative.
- **Alternatives**: PLDA scoring with the shipped `PldaRho` model (rho128 is available per chunk; kept as a Phase 2 experiment if cosine calibration is marginal, since PLDA rho magnitude carries a confidence the spec cannot show as a percentage anyway). A vector index (unneeded: 100 speakers × 10 samples × 256 floats is 1 MB and 30,000 dot products per meeting).

## R7. Runs, adoption, rerun and preservation (FR-022 to FR-026)

- **Decision**: `identification_runs` mirrors `diarization_runs`: `pending → running → succeeded | failed`, `running → pending` on preemption, `running → interrupted` at launch reconciliation, `succeeded → superseded` on the next adoption. A run is admitted only against the meeting's accepted diarization run and records its id; if the accepted diarization run changes before adoption, the run fails with `diarization_changed`.
  - **Adoption** is one transaction in `IdentityStore`: delete the previous accepted run's automatic rows in `identity_assignments` (states `recognized`, `possible`), insert the new automatic rows for roots that have no manual row (`confirmed`, `rejected_unknown`, or a `kept_unknown` origin), mark the previous run `superseded`, delete `match_candidates` of superseded runs, and set `meeting_identification.accepted_run_id`. Manual rows are never touched by adoption (FR-024).
  - A failed, interrupted or cancelled run deletes its own `match_candidates` rows and nothing else (FR-025).
  - **Rerun** (`Rerun identification` in the Speakers menu, trigger `manual`) and **retry** admit a new pending run; neither touches transcription or diarization (FR-023).
  - **Zero candidates**: when no recognition-enabled known speaker has a compatible sample, the run completes without acquiring a lease and writes every remote root as `unknown` with origin `automatic_match` and no score (edge case "zero recognition-enabled known speakers").
  - **Diarization rerun**: `identity_assignments` cascade from `meeting_speakers`, so superseded clusters take their assignments with them. `CorrectionCarryOver` already maps names between old and new roots when turn overlap makes the match safe; the same map now also copies the old root's manual identity row to the new root, and a manual row that cannot be carried is listed as a review notice like a name. Automatic rows are not carried; the automatic identification run that follows the diarization adoption recomputes them.
- **Rationale**: Same shape as 007, so recovery, reconciliation and tests follow the existing patterns. Carrying manual identity with the name honors FR-024 across the one rerun path the spec leaves implicit.
- **Alternatives**: Storing assignments per run and resolving "effective" at read time (more joins on every page and no simple invariant for one effective row per speaker).

## R8. Enrollment, confirmation and correction flows (US1, US3, US4, US7)

- **Decision**: The Assign speakers model gains an identity section per row. Actions, all executed by `IdentityStore` in one transaction each:
  - **Remember** (new name typed): create `known_speakers` row, extract and store samples with consent `remember`, upsert the root's identity row `confirmed / new_profile_created`. When the typed name exactly equals an existing known speaker's name (case-sensitive after `SpeakerNames.validate`), the sheet asks "Same person, or someone new with this name?" before saving (US4 scenario 3).
  - **Not now**: save the name as today; nothing else is written.
  - **Pick a known speaker**: upsert `confirmed / manual_profile_selection`, copy the known speaker's name into `display_name`, no samples.
  - **Confirm a Possible match**: `confirmed / user_confirmation`; samples only when "Also remember this voice sample" was turned on (`also_remember`).
  - **Choose another / correct**: record the previous candidate in `rejected_candidates`, upsert `confirmed / manual_correction` to the chosen speaker; samples only with the control on, and never to a speaker in `rejected_candidates` for this cluster (FR-007).
  - **Keep Unknown**: record the candidate as rejected, upsert `rejected_unknown / kept_unknown`.
  - **Remember my voice** (the "You" row): creates the `is_local_user = 1` profile from microphone-track regions, consent `local_enroll`. Only one local-user profile may exist.
  - Sample extraction needs the embedder, so enrollment is an `EnrollmentJob` run by `SpeakerIdentificationCoordinator` on its queue with a lease of its own; the sheet shows "Storing voice sample…" and the profile row is created first with zero samples so a failed extraction leaves an honest state (US1 scenario 3).
  - After an enrollment that stored at least one sample, the sheet shows once "Look for this voice in past meetings?" (R10).
- **Rationale**: Every sample traces to one explicit action with its consent value stored; confirmation and automatic assignments add nothing by themselves (FR-008).

## R9. Deletion, retention and rename (FR-030 to FR-033)

- **Decision**:
  - **Delete known speaker**: one transaction: for each `identity_assignments` row linked to it with state `confirmed` or `recognized`, ensure `meeting_speakers.display_name` holds the name (it already does; the write is idempotent), then delete the assignment rows (Possible rows become Unknown with no name), delete `rejected_candidates` and `match_candidates` rows, delete `voice_samples` (FK cascade), delete the profile. Nothing in `transcript_segments`, `speaker_turns` or audio is touched. The store's cascade test counts zero rows referencing the id afterwards (FR-033).
  - **Delete meeting**: `identity_assignments`, `identification_runs`, `match_candidates` and `rejected_candidates` cascade with the meeting's speakers and runs. `voice_samples.source_meeting_id` and `source_speaker_id` are `ON DELETE SET NULL`; a sample with a null source is provenance-unavailable, still matched, listed as "Source meeting deleted" with its creation date, and excluded from re-extraction (FR-031, FR-043).
  - **Remove one sample**: delete the row; the next run no longer sees it (FR-032). If it was the last active compatible sample, the profile shows "needs re-enrollment".
  - **Rename known speaker**: update the profile and, in the same transaction, `display_name` of every meeting speaker whose identity row links to it with state `confirmed` or `recognized`, in batches of 500. Unlinked names are untouched.
- **Rationale**: Hard delete and copied names are what the clarification session chose; keeping the label in `display_name` means `TranscriptPager` needs no join for named rows and deletion needs no rewrite of pages.

## R10. Past-meeting search after enrollment (FR-023a)

- **Decision**: After an enrollment job stores ≥ 1 sample, the coordinator publishes `enrollmentDidStore(knownSpeakerID:)` and the sheet shows one prompt with "Look" and "Not now". "Look" asks `IdentityStore.meetingsWithUnknownRemoteSpeakers(limit: 500)` (meetings with an accepted diarization run and at least one remote root whose effective identity is `unknown` or absent, newest first) and appends them to the identification queue with trigger `past_search`. The queue holds meeting ids only, is capped at 500, is processed one meeting at a time under the single-model rule, is dropped on quit and is cancellable from the status line. Meetings with no Unknown remote root are skipped at admission, not just at prompt time (US6 scenario 5).
- **Rationale**: The prompt keeps backfill explicit; the newest-first order gives the most likely useful results first if the user cancels.

## R11. Merge and unmerge (FR-026a)

- **Decision**: `identity_assignments` has a `scope` column: `self` (the speaker's own row) or `merged` (a resolution recorded on a display root while it has merged members). The effective identity of a root is its `merged` row when one exists; otherwise the rule over the `self` rows of the root and its members: if every linked row names the same known speaker with state `recognized` or `confirmed`, or exactly one side has a linked row and no row is `possible`, that identity applies; otherwise the root is Unknown with origin `kept_unknown` and the sheet marks it "Choose an identity". Resolving writes the `merged` row. Unmerging the last member deletes the root's `merged` row, so both `self` rows apply again unchanged. `self` rows are never modified by merge or unmerge.
- **Rationale**: Honors "undo restores both original assignments" without a snapshot table and without touching 007's merge implementation beyond one hook.

## R12. Privacy and storage (FR-034 to FR-037)

- **Decision**: Samples, candidates and assignments live in `history.sqlite` next to the diarization tables, never in `UserDefaults` or files. No encryption beyond app-private storage is added: the database is already under the user's home protection (FileVault) and adding SQLCipher would be a substantial dependency for a threat model (another local user with the same account) that the constitution does not ask this feature to cover; recorded as a decision. Exports and copy paths of Features 006 and 007 do not read the new tables. Logs and `ResourceRecorder` metrics carry counts and durations only, and the existing content-free recorder test is extended to the new metrics. The identification module imports no networking symbol; `ModelHub.offlineMode` stays on (R1 loads from the verified local directory only).

## R13. Bounds and capacities

| Bound | Value | Overflow behavior |
| --- | --- | --- |
| Identification queue | 100 meeting ids, deduplicated | automatic triggers skipped with a notice; manual rerun refused with a notice |
| Past-search queue | 500 meeting ids, memory only | the prompt says how many were queued; the rest are not queued |
| Regions per cluster | 5 enroll / 4 query | ranked selection, rest ignored |
| Region length | 3–20 s | trimmed to 20 s |
| Resident audio | one region (≤ 320,000 samples) + 4,096-frame decode buffers | by construction |
| Active samples per known speaker per model | 10 (+10 retired) | retirement policy (R5) |
| Known speakers | 1,000 rows | create refused with a notice; acceptance measures 10/50/100 |
| Candidates per run | roots × known speakers, ≤ 64 × 1,000 | above 64,000 the run fails `persistence_capacity` before writing |
| Candidate vectors in memory | ≤ 1,000 speakers × 10 samples × 256 floats ≈ 10 MB | loaded once per run, released at run end |
| Rejected candidates | per (cluster, known speaker) pair; ≤ 1,000 per meeting | refusal with a notice |
| Storage | history database ceiling | `persistence_capacity`, no adoption |

## R14. Observability and acceptance

- **Metrics** (`ResourceRecorder`): `identificationModelLoadDuration`, `identificationModelReleaseDuration`, `identificationDuration`, `identificationRegionsExtracted`, `identificationRegionsRejected`, `identificationComparisons`, `identificationRecognized`, `identificationSuggested`, `identificationUnknown`, `identificationConfirmations`, `identificationCorrections`, `identificationFailure`, `enrollmentSamplesStored`, plus phases `identifying` and `modelLoading/Active/Releasing(identification)`. RSS is sampled every 10 s while a run or enrollment is active, as diarization does.
- **Acceptance files** (Phase 2, all "Unmeasured" until written): `calibration.md` (R6), `throughput.md` (SC-008 at 10, 50 and 100 known speakers, synthetic vectors for scale-only timing), `memory.md` (SC-009), `consent-and-privacy.md` (SC-005, SC-006, network and log checks), `recovery.md` (force quit during a run and during a past search), `regression.md` (SC-010).
