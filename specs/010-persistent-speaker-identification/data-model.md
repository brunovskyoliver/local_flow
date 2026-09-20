# Data model: persistent speaker identification

Migration `identities-v8` in `history.sqlite` adds only new tables. Feature 004–007 tables are not altered; `meeting_speakers.display_name` is written by this feature through the existing name path only. Every meeting-scoped table cascades from `meetings`, and every per-cluster table cascades from `meeting_speakers`, so a diarization rerun or a `discardPass` removes the rows that belonged to superseded clusters. All writes go through the new `IdentityStore` actor on the shared `DatabaseQueue`. Names never enter transcript text; vectors never leave the database ([research R12](research.md)).

The four vocabulary ideas of the spec map to four tables: meeting-local speaker = `meeting_speakers` (007), known speaker = `known_speakers`, identity assignment = `identity_assignments`, origin and certainty = columns of that row plus `match_candidates`.

## known_speakers

| Column | Type / rule |
| --- | --- |
| id | TEXT PK |
| display_name | TEXT NOT NULL, the `SpeakerNames` rules (1–80 scalars, trimmed, no control characters). Not unique: duplicates are allowed after the explicit "someone new" choice |
| is_local_user | INTEGER 0/1, default 0. Partial unique index `WHERE is_local_user = 1` |
| recognition_enabled | INTEGER 0/1, default 1 (FR-039) |
| created_at, updated_at | INTEGER ms |
| revision | INTEGER ≥ 0, bumped on every write; the Settings list edits with an expected revision |

Capacity: 1,000 rows; `create` refuses beyond it. **Profile state** is derived, never stored: `active` when at least one `voice_samples` row is active and compatible with the current model identity; otherwise `needs_reenrollment`. Deletion removes the row (FR-030); there is no `deleted` state.

## voice_samples

| Column | Type / rule |
| --- | --- |
| id | TEXT PK |
| known_speaker_id | TEXT NOT NULL → known_speakers ON DELETE CASCADE |
| engine, model_id, model_revision | TEXT NOT NULL (R1 identity) |
| model_manifest_hash | TEXT NOT NULL, 64 hex |
| dimension | INTEGER NOT NULL, CHECK 1…4096 |
| pipeline_version | TEXT ≤ 256 B, e.g. `embed_offline1spk_dw_v1+regions_v1` |
| vector | BLOB NOT NULL, CHECK `length(vector) = dimension * 4` (little-endian Float32, L2-normalized) |
| quality_label | `good`, `fair` |
| quality_score | REAL, CHECK 0…1, the selector's score |
| engine_quality | REAL NULL, the diarization turn quality when present |
| speech_ms | INTEGER > 0, the region's length |
| track | `microphone`, `system` |
| start_ms, end_ms | INTEGER, recorded timeline, CHECK `end_ms > start_ms` |
| source_meeting_id | TEXT NULL → meetings ON DELETE SET NULL (NULL = provenance-unavailable, FR-031) |
| source_speaker_id | TEXT NULL → meeting_speakers ON DELETE SET NULL |
| consent | `remember`, `also_remember`, `local_enroll` (FR-001, FR-008) |
| active | INTEGER 0/1, default 1 |
| created_at | INTEGER ms |
| retired_at | INTEGER NULL, CHECK `(retired_at IS NOT NULL) = (active = 0)` |

Indexes: `(known_speaker_id, active)`, `(source_meeting_id)`, `(source_speaker_id)`.

Rules: at most 10 active rows per `(known_speaker_id, engine, model_id, model_revision, dimension)` and at most 10 retired ones (R5); the store enforces both inside the insert transaction. A sample is **compatible** with a model identity when engine, model id, revision and dimension are equal (FR-028). The list shown in Known speakers (FR-043) joins `meetings` for title and date and shows "Source meeting deleted" with `created_at` when `source_meeting_id` is NULL.

## meeting_identification (one row per meeting)

| Column | Type / rule |
| --- | --- |
| meeting_id | TEXT PK → meetings ON DELETE CASCADE |
| accepted_run_id | TEXT NULL → identification_runs ON DELETE SET NULL |
| current_run_id | TEXT NULL → identification_runs ON DELETE SET NULL, the pending or running run |
| updated_at | INTEGER ms |

The migration inserts one row per existing meeting; `MeetingStore` inserts it with the meeting, as it does for `meeting_diarization`. **Meeting-level identification state** is derived exactly as `DiarizationRunLifecycle.meetingState` does it: current run state, else the latest run's `failed`/`interrupted`, else `succeeded` when accepted, else `not_requested`.

## identification_runs

| Column | Type / rule |
| --- | --- |
| id | TEXT PK |
| meeting_id | TEXT → meetings CASCADE |
| diarization_run_id | TEXT NOT NULL → diarization_runs ON DELETE CASCADE, the accepted run the identification read |
| state | `pending`, `running`, `succeeded`, `failed`, `interrupted`, `superseded` |
| trigger | `automatic`, `manual`, `retry`, `past_search`, `sample_change` |
| engine, model_id, model_revision, model_manifest_hash, dimension, pipeline_version | as in `voice_samples`; recorded even for the zero-candidate short circuit |
| threshold_policy | TEXT NOT NULL, e.g. `tiers_v1@wespeaker_resnet34lm_256/1ed7a662` (FR-012, FR-019) |
| created_at, started_at, completed_at | INTEGER ms |
| failure_category | NULL or `model_unavailable`, `os_unsupported`, `model_load_failure`, `audio_missing`, `audio_decode_failure`, `runtime_failure`, `diarization_changed`, `persistence_failure`, `persistence_capacity`, `interrupted`; CHECK non-null ⇔ state ∈ (failed, interrupted) |
| failure_detail | TEXT ≤ 512 B, content-free |
| cluster_count, candidate_count, region_count, rejected_region_count, comparison_count | INTEGER ≥ 0 |
| recognized_count, suggested_count, unknown_count, preserved_manual_count | INTEGER ≥ 0 |
| preemption_count | INTEGER ≥ 0 |

Partial unique index on `(meeting_id) WHERE state IN ('pending','running')`. Index `(meeting_id, created_at)`.

### Run state transitions

```text
pending → running → succeeded        adoption transaction; previous accepted run → superseded
pending → running → failed(category) match_candidates of this run deleted; assignments untouched
pending → succeeded                  zero-candidate short circuit (no lease, all remote roots unknown)
running → pending                    preempted by a speech workload (preemption_count + 1)
running → interrupted                launch reconciliation; candidates deleted; assignments untouched
pending|running → (row deleted)      user Cancel, meeting deletion
failed|interrupted → (new run)       Rerun / Retry admits a new pending run
```

## identity_assignments

One effective identity per display root (FR-009). Rows are per meeting speaker; the effective one for a root is resolved by the `scope` rule ([research R11](research.md)).

| Column | Type / rule |
| --- | --- |
| id | TEXT PK |
| meeting_id | TEXT → meetings CASCADE |
| meeting_speaker_id | TEXT NOT NULL → meeting_speakers ON DELETE CASCADE |
| scope | `self`, `merged`; UNIQUE `(meeting_speaker_id, scope)` |
| known_speaker_id | TEXT NULL → known_speakers ON DELETE CASCADE (the store copies names and deletes rows explicitly first; the cascade is the safety net) |
| state | `recognized`, `possible`, `confirmed`, `rejected_unknown`, `unknown` (FR-009) |
| origin | `automatic_match`, `user_confirmation`, `manual_profile_selection`, `new_profile_created`, `manual_correction`, `kept_unknown` (FR-018) |
| run_id | TEXT NULL → identification_runs ON DELETE SET NULL; NOT NULL for `recognized`, `possible` and automatic `unknown` rows |
| score | REAL NULL, CHECK −1…1; NOT NULL for `recognized` and `possible` |
| engine, model_id, model_revision, threshold_policy | TEXT NULL; NOT NULL when `score` is (FR-019) |
| second_known_speaker_id | TEXT NULL → known_speakers ON DELETE SET NULL, the within-margin runner-up shown under Choose another |
| confirmed_at, corrected_at | INTEGER NULL |
| created_at, updated_at | INTEGER ms |

CHECKs: `state IN ('recognized','possible','confirmed') = (known_speaker_id IS NOT NULL)`; `state IN ('recognized','possible') → origin = 'automatic_match'`; `state = 'confirmed' → origin IN ('user_confirmation','manual_profile_selection','new_profile_created','manual_correction')`; `state = 'rejected_unknown' → origin = 'kept_unknown'`; `(confirmed_at IS NOT NULL) = (state = 'confirmed')`.

**Manual rows** are those with origin other than `automatic_match`. Adoption replaces only rows with origin `automatic_match` (FR-024). Index `(known_speaker_id)` for rename and delete, `(meeting_id)` for page joins.

## match_candidates

| Column | Type / rule |
| --- | --- |
| run_id | TEXT → identification_runs CASCADE |
| meeting_speaker_id | TEXT → meeting_speakers CASCADE |
| known_speaker_id | TEXT → known_speakers CASCADE |
| score | REAL, CHECK −1…1 |
| tier | `recognized`, `possible`, `below`, `local_evidence` |
| reasons | TEXT ≤ 128 B, comma-separated flags from `below_medium`, `margin`, `support`, `min_speech`, `rejected`, `disabled` |
| sample_count, support_count | INTEGER ≥ 0 |
| PK | `(run_id, meeting_speaker_id, known_speaker_id)` WITHOUT ROWID |

Kept for the accepted run only; adoption deletes the superseded run's rows. Bounded by roots × known speakers per run (R13).

## rejected_candidates

| Column | Type / rule |
| --- | --- |
| meeting_speaker_id | TEXT → meeting_speakers CASCADE |
| known_speaker_id | TEXT → known_speakers CASCADE |
| rejected_at | INTEGER ms |
| PK | `(meeting_speaker_id, known_speaker_id)` WITHOUT ROWID |

Written by Keep Unknown and by corrections away from a candidate (FR-020). Read by the matcher (excluded from candidates) and by the sample writer (FR-007). At most 1,000 rows per meeting.

## Read models

- **`SpeakerIdentity`** (per display root, joined into `SpeakerSummary` for the sheet and into labeled pages for the transcript): `state`, `origin`, `knownSpeakerID?`, `knownSpeakerName?`, `secondCandidate?` (id and name), `needsChoice` (merge conflict), `sampleOfferAvailable` (regions exist).
- **`SegmentLabel`** gains `identity: SegmentIdentity?` with cases `named(confirmedOrRecognized)`, `suggested(name)`, `unknown`, so the transcript row renders "Name", "Name?" with the confirm control, or "Speaker N" (FR-040). No score is present in the read model.
- **`KnownSpeakerRow`** (Settings): `id`, `name`, `activeSampleCount`, `recognitionEnabled`, `state` (`active`, `needsReenrollment`), `isLocalUser`, `revision`.
- **`VoiceSampleRow`** (Settings, per known speaker): `id`, `sourceTitle?`, `sourceDate` (meeting start or, when provenance is unavailable, `created_at`), `provenanceUnavailable`, `speechMs`, `qualityLabel`. Never the vector or a score (FR-043).
- **`IdentificationStatus`** (status line): the derived meeting state, progress (regions done over planned), failure category, `pastSearchRemaining`.

## Cascade and deletion matrix

| Event | Effect |
| --- | --- |
| Delete meeting | `meeting_identification`, `identification_runs`, `match_candidates`, `identity_assignments`, `rejected_candidates` cascade; `voice_samples.source_*` set NULL |
| Diarization rerun adopted (007 supersedes clusters) | rows keyed by old `meeting_speakers` cascade; manual identity rows are carried over with names where the 007 carry-over map is safe |
| `discardPass` | as above through `meeting_speakers` |
| Delete known speaker | explicit transaction: keep copied names, delete its assignment rows, rejected and candidate rows, samples, profile |
| Remove one sample | row deleted; profile state re-derived |
| Retirement by cap | `active = 0`, `retired_at` set; oldest retired rows beyond 10 deleted |
