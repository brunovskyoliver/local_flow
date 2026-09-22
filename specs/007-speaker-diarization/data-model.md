# Data model: speaker diarization

Migration `speakers-v7` in `history.sqlite` adds only new tables. Feature 004–006 tables are not altered. `transcript_segments.speaker` stays `'unassigned'`, and final segment rows are never updated. Every table cascades from `meetings`. Assignments also cascade from `transcript_segments`, so `discardPass` removes them. All writes go through the `SpeakerStore` actor, which shares the existing `DatabaseQueue`. Speaker names never enter transcript text (FR-034).

## meeting_diarization (one row per meeting)

| Column | Type / rule |
| --- | --- |
| meeting_id | TEXT PK → meetings ON DELETE CASCADE |
| accepted_run_id | TEXT NULL → diarization_runs(id) |
| current_run_id | TEXT NULL → diarization_runs(id), the pending or running run, if any |
| in_room | INTEGER 0/1, default 0 (FR-009) |
| updated_at, revision | INTEGER; revision-checked writes like `meeting_transcriptions` |

The migration inserts one row per existing meeting. `MeetingStore` inserts the row in the same transaction that creates a meeting.

**Meeting-level state (FR-029)** is derived and never stored twice. It is the current run's state when there is one; otherwise the latest run's `failed` or `interrupted` state; otherwise `succeeded` when `accepted_run_id` is set; otherwise `not_requested`.

## diarization_runs

| Column | Type / rule |
| --- | --- |
| id | TEXT PK |
| meeting_id | TEXT → meetings CASCADE |
| transcript_pass_id | TEXT NOT NULL, the final pass the run aligned against |
| state | `pending`, `running`, `succeeded`, `failed`, `interrupted`, `superseded` |
| trigger | `automatic`, `manual`, `retry`, `in_room_change` |
| in_room | INTEGER 0/1 (snapshot at admission) |
| engine, model_id, model_revision, model_manifest_hash | TEXT; manifest hash 64 hex |
| pipeline_version | TEXT ≤ 256 B, e.g. `offline_vbx_community1_nonexcl+win600s_v1+xwin_cos_greedy_v2+echo_lag1s_p20_k12_min300_v1+merge_cos0.70_v1+minor10s_5pct_cos0.60_v1+align_dom0.60_ratio2_ovl0.20_bytrack_v3` |
| created_at, started_at, completed_at | INTEGER ms |
| failure_category | NULL or one of `model_unavailable`, `os_unsupported`, `model_load_failure`, `audio_missing`, `audio_decode_failure`, `runtime_failure`, `transcript_changed`, `persistence_failure`, `persistence_capacity`, `interrupted`; CHECK: non-null ⇔ state ∈ (failed, interrupted) |
| failure_detail | TEXT ≤ 512 B, content-free |
| inferred_speaker_count | INTEGER ≥ 0, clusters that received at least one turn (FR-004) |
| audio_ms, window_count, turn_count, overlap_turn_count | INTEGER ≥ 0 |
| unknown_count, ambiguous_count | INTEGER ≥ 0 |
| uncertain_reconciliations, overflow_turns, preemption_count | INTEGER ≥ 0 |

A meeting has at most one `succeeded` run that is not `superseded`, and it is `accepted_run_id`. It has at most one run in `pending` or `running`, enforced by a partial unique index on `(meeting_id) WHERE state IN ('pending','running')`.

### Run state transitions

```text
pending → running → succeeded (adopted atomically; the previous accepted run → superseded)
pending → running → failed(category)       rows of this run deleted; accepted run untouched
running → pending                          preempted by speech recognition (preemption_count+1)
running → interrupted                      launch reconciliation; rows deleted; accepted run untouched
pending|running → (row deleted)            user Cancel, or meeting deletion
failed|interrupted → (new run)             Retry creates a new pending run
```

A failed, interrupted or cancelled run never modifies `meetings`, `meeting_transcriptions`, segments, notes, audio or the accepted run (FR-029 to FR-031).

## meeting_speakers

| Column | Type / rule |
| --- | --- |
| id | TEXT PK |
| meeting_id | TEXT → meetings CASCADE |
| run_id | TEXT NULL → diarization_runs CASCADE; NULL for a manual "new speaker" |
| cluster_key | INTEGER ≥ 0, unique per run |
| source | `local` or `remote` |
| track | `microphone`, `system`, or NULL for manual speakers |
| origin | `engine` or `manual` |
| label_ordinal | INTEGER ≥ 1; N in "Speaker N" / "Local N", in first-appearance order within the source; stable |
| color_index | INTEGER 0–7, in first-turn order at adoption (FR-017) |
| display_name | TEXT NULL; trimmed, 1–80 characters, no control characters (FR-021) |
| merged_into | TEXT NULL → meeting_speakers(id); a chain depth of 1 is enforced by the store |
| reconciliation | `confident` or `uncertain` (R4) |
| first_ms, speech_ms | INTEGER ≥ 0 |
| engine_quality | REAL NULL; the engine's segment quality averaged over turns. It is labeled as engine quality, never as confidence (FR-012) |

Display root is `merged_into ?? id`. Unknown and Overlapping are not rows.

## speaker_turns (machine evidence; never edited by corrections)

| Column | Type / rule |
| --- | --- |
| id | INTEGER PK |
| run_id | TEXT → diarization_runs CASCADE |
| speaker_id | TEXT NULL → meeting_speakers CASCADE; NULL marks reconciliation overflow |
| track | `microphone` or `system` |
| start_ms, end_ms | INTEGER, 0 ≤ start < end; the recorded timeline; within one stretch |
| engine_quality | REAL NULL |
| overlapped | INTEGER 0/1; another turn overlaps it in the same run |

Index `(run_id, start_ms)`. Turns may overlap (FR-011). Capacity is 100,000 turns per run. Exceeding it fails the run with `persistence_capacity`, and nothing is adopted.

## speaker_assignments

| Column | Type / rule |
| --- | --- |
| run_id | TEXT → diarization_runs CASCADE |
| segment_id | TEXT → transcript_segments(id) CASCADE |
| auto_kind | `speaker`, `unknown` or `ambiguous` |
| auto_speaker_id | TEXT NULL → meeting_speakers; required ⇔ auto_kind = speaker |
| top_speaker_id, second_speaker_id | TEXT NULL; alignment evidence |
| top_coverage, second_coverage | REAL 0…1 (FR-015) |
| manual_kind | NULL, `speaker` or `unknown` |
| manual_speaker_id | TEXT NULL; required ⇔ manual_kind = speaker |
| manual_at | INTEGER NULL |

PK `(run_id, segment_id)`. The effective label is `manual ?? auto`, mapped to the display root. Writes happen in batches of at most 500 rows per transaction.

## speaker_corrections (user actions; replay, undo and carry-over)

| Column | Type / rule |
| --- | --- |
| id | TEXT PK |
| meeting_id | TEXT → meetings CASCADE |
| run_id | TEXT → diarization_runs CASCADE, the run the action applied to |
| kind | `rename`, `merge`, `unmerge`, `segment` |
| speaker_id | TEXT NULL; the renamed speaker, or the absorbed speaker of a merge |
| target_speaker_id | TEXT NULL; the merge target or the segment's new speaker |
| segment_id | TEXT NULL (kind = segment) |
| previous_value, new_value | TEXT ≤ 80 characters NULL; names or `unknown` |
| needs_review | INTEGER 0/1 (R7) |
| created_at, undone_at | INTEGER |

Capacity is 10,000 corrections per meeting. At the limit, a save is refused with a visible message and nothing is written.

## Storage capacity

The feature adds no separate usage table. The per-run caps and the deletion rules bound growth: each meeting keeps at most one accepted run plus one in-progress run, and adoption deletes the superseded run's turns and assignments. Failure and interruption delete the run's own rows. Meeting deletion cascades. That leaves roughly 100,000 turns and 20,000 assignments at most per meeting (about 10 MB per 8-hour meeting, and far less for typical meetings). Totals across meetings then run into the existing 128 MiB `history.sqlite` ceiling. A write that hits the ceiling fails the run as `persistence_capacity`, and nothing is adopted. Phase 2 records measured bytes per 60-minute meeting in `acceptance/throughput.md`. If they exceed 1 MB, add a `speaker_usage` ceiling like `transcript_usage` before release.

## Operations and their transactions

| Operation | One transaction |
| --- | --- |
| Admit | Insert the `pending` run and set `current_run_id` (with the revision check) |
| Start | pending → running, with `started_at` |
| Window batch | Insert the window's speakers (new run clusters), then its turns in batches of ≤ 500; update run counters |
| Complete | Insert all assignments (batched inside one `write` block), set color indexes and label ordinals, run carry-over, mark the previous accepted run `superseded` and delete its turns and assignments, set `accepted_run_id` and clear `current_run_id`. Either all of it commits or nothing does (FR-030) |
| Fail / interrupt | Set the state and category, delete the run's speakers, turns and assignments, and clear `current_run_id` |
| Save names | Update every `display_name` in the modal and insert one `rename` correction per change (FR-022) |
| Merge / unmerge | Set or clear `merged_into` and insert a correction. Unmerge restores the earlier name and color, which were never changed (FR-025) |
| Segment correction | Set the `manual_*` columns and insert a `segment` correction (FR-026) |
| In-room toggle | Update `in_room` and admit a run with trigger `in_room_change` (FR-009) |

## Read models (not tables)

- **SpeakerSummary**: id, display label, color index, source, root, speech_ms, quotes (up to 3), needs-review entries. Built for Assign speakers.
- **LabeledSegment**: `TranscriptSegment` plus an optional `SegmentLabel` (speaker root id, text, color index, or Unknown/Overlapping). It is produced by the pager's page query. When the accepted run's `transcript_pass_id` differs from the transcript's `pass_id`, the label is nil and the Feature 006 source labels apply.
- **Header count**: the number of distinct display roots with at least one effective `speaker` assignment in the accepted run (FR-018).
