# Data model

Storage stays in the private GRDB/SQLite `history.sqlite` shared by `TranscriptionStore`, `VocabularyStore` and `MeetingStore`. A new `TranscriptStore` actor uses the same `DatabaseQueue`. Migration `transcripts-v6` adds the four tables below; no Feature 001–004 table is altered. Timestamps are Unix milliseconds; positions on the recorded-audio timeline are milliseconds unless the column ends in `_sample` (16 kHz analysis-stream samples). Text is UTF-8 and every byte limit is a UTF-8 byte count. No audio and no derived audio enters SQLite.

## Meeting transcription

Table `meeting_transcriptions`. Exactly one row per new meeting, created in the meeting's `preparing` transaction (FR-001); terminal pre-migration meetings get a `not_requested` row on their first transcript read and never deleted except by the meeting cascade.

| Column | Type and rule |
| --- | --- |
| meeting_id | TEXT primary key, references `meetings(id)` `ON DELETE CASCADE` |
| state | TEXT in `('not_requested','pending','live','finalizing','final','failed','interrupted')` |
| live_requested | INTEGER 0/1; the start-time decision (global setting plus override) |
| live_state | TEXT nullable in `('live','catching_up','degraded','suspended','stopped')`; non-null only while `state = 'live'` |
| pass_id | TEXT nullable, UUID of the current or last pass (live or final) |
| pass_kind | TEXT nullable in `('live','final')` |
| engine | TEXT nullable, `'FluidAudio'` |
| model_id | TEXT nullable |
| model_revision | TEXT nullable |
| model_manifest_hash | TEXT nullable, 64 hex |
| pipeline_version | TEXT nullable, ≤ 256 bytes; `"<planner>+<assembler>+<segmenter>+<normalizer>"` identities joined with `+` |
| planner_version | TEXT nullable; `live_contiguous_96000_v1` or `contiguous_fixed239360_preserve_v1` |
| vocabulary_revision | INTEGER nullable, ≥ 0 |
| vocabulary_hash | TEXT nullable, 64 hex |
| analysis_descriptor_json | TEXT nullable, ≤ 16,384 bytes; the Analysis Stream Descriptor (below) |
| started_at | INTEGER nullable; first transition out of `not_requested`/`pending` |
| live_started_at | INTEGER nullable |
| finalization_started_at | INTEGER nullable; start of the current final pass |
| finalized_at | INTEGER nullable; transition into `final` |
| progress_sequence | INTEGER nullable, ≥ 1; stretch sequence of the last persisted final window |
| progress_sample | INTEGER nullable, ≥ 0; analysis-stream samples of that stretch covered by persisted final windows |
| covered_ms | INTEGER not null default 0, ≥ 0; Σ decoded stretch length of the last completed final pass |
| recorded_ms_at_pass | INTEGER not null default 0; the meeting's `recorded_ms` when the pass started, for the coverage report |
| replaced_provisional_count | INTEGER not null default 0; provisional segments deleted when the last final pass completed (FR-009) |
| model_reload_count | INTEGER not null default 0; reloads after pause retention expired |
| failure_category | TEXT nullable in the category set below; non-null iff `state IN ('failed','interrupted')` |
| failure_detail | TEXT nullable, ≤ 512 bytes, content-free (codes, stage names) |
| segment_count | INTEGER not null default 0, ≥ 0; rows in `transcript_segments` for this meeting |
| text_bytes | INTEGER not null default 0, ≥ 0; Σ of the three text columns over those rows |
| updated_at | INTEGER not null |
| revision | INTEGER not null default 0, ≥ 0; bumped on every write; the UI passes it to Retry/Transcribe |

Indexes: partial `meeting_transcriptions_active ON meeting_transcriptions(state) WHERE state IN ('pending','live','finalizing')` for reconciliation and the launch resume queue.

**Failure category set** (`TranscriptFailureCategory`, persisted raw values): `model_unavailable`, `model_provisioning`, `model_load_failure`, `audio_decode_failure`, `analysis_stream_failure`, `runtime_failure`, `finalization_interrupted`, `persistence_failure`, `persistence_capacity`. `work_list_capacity` and `vocabulary_unavailable` are `failure_detail` values under `finalization_interrupted` and `runtime_failure` respectively.

**Analysis Stream Descriptor** (JSON, versioned, ≤ 16,384 bytes):

```json
{"version":"mixed_mono_16k_v1","sampleRate":16000,"channels":1,"mixRule":"mean_0.5",
 "source":"decoded_tracks","contributingTracks":["mic","system"],
 "stretches":[{"sequence":1,"lengthMs":1834200,"tracks":"both"},{"sequence":2,"lengthMs":611050,"tracks":"mic"}]}
```

`source` is `live_pcm_tee` for the live pass and `decoded_tracks` for a final pass. `stretches` lists, in order, each stretch a pass covered with its analysis-stream length and contributing tracks; it is the source for `stretch_base_ms` in the wall-clock derivation. Feature 004 bounds a meeting to a practical number of stretches; the descriptor caps the list at 200 entries and a longer meeting records `"stretchesTruncated":true` with the remaining bases derivable from `meeting_segments.duration_ms`.

### Transcript lifecycle

States and the persisted transition table (`TranscriptLifecycle`, applied inside the store's write transaction; every pair not listed is rejected and mutates nothing):

| From | To | Trigger |
| --- | --- | --- |
| not_requested | pending | Transcribe action; row `live_requested` stays 0 |
| not_requested | live | never (live only starts with the meeting) |
| pending | live | meeting start with transcription requested: row is created as `pending` and moves to `live` once the lease is held and the first window is planned |
| pending | finalizing | Transcribe/Retry admitted and the lease acquired |
| pending | interrupted | launch reconciliation after the meeting becomes terminal (`finalization_interrupted`) |
| pending | failed | lease or snapshot failure before any work, or reconciliation of a failed meeting |
| live | finalizing | meeting stopped and live work drained |
| live | failed | runtime, persistence or capacity failure during live; recording continues |
| live | interrupted | launch reconciliation found it (`finalization_interrupted`) |
| finalizing | final | pass completed, provisional segments replaced |
| finalizing | failed | any failure category during the pass, or reconciliation of a failed meeting |
| finalizing | interrupted | allowed lifecycle transition for interrupted work; failed meetings reconcile to `failed` |
| final | finalizing | Retry (explicit re-transcription, FR-012) |
| failed | finalizing | Retry with source audio present |
| interrupted | finalizing | Retry, or automatic resume for an interrupted finalization |

`not_requested`, `final`, `failed` and `interrupted` are stable; `pending`, `live` and `finalizing` are active and reconciled at launch. Every transition is written before it is published, using the same write-then-publish pattern as `MeetingStore.transition`. No transition here touches `meetings.state`.

## Transcript segment

Table `transcript_segments`. One row per timestamped unit. Provisional rows belong to the live pass; final rows to a final pass. Both kinds coexist while a final pass runs; the completing transaction deletes the provisional rows.

| Column | Type and rule |
| --- | --- |
| id | TEXT primary key, UUID |
| meeting_id | TEXT not null, references `meetings(id)` `ON DELETE CASCADE` |
| pass_id | TEXT not null, UUID of the producing pass |
| finality | TEXT in `('provisional','final')` |
| ordinal | INTEGER not null, ≥ 0; position within its pass, increasing with `start_ms`; unique `(meeting_id, pass_id, ordinal)` |
| stretch_sequence | INTEGER not null, ≥ 1; the Feature 004 segment sequence the audio came from |
| start_ms | INTEGER not null, ≥ 0; recorded-audio timeline |
| end_ms | INTEGER not null, > `start_ms` (check) |
| window_index | INTEGER not null, ≥ 0; recognition window within the stretch |
| timing_basis | TEXT in `('word','window')` |
| raw_text | TEXT not null, ≤ 4,096 bytes; exact received bytes for the segment's words |
| assembled_text | TEXT not null, ≤ 4,096 bytes |
| normalized_text | TEXT not null, ≤ 4,096 bytes |
| engine | TEXT not null |
| model_id | TEXT not null |
| model_revision | TEXT not null |
| pipeline_version | TEXT not null, ≤ 256 bytes |
| analysis_tracks | TEXT in `('mic','system','both')`; which tracks contributed to this segment's audio |
| speaker | TEXT not null default `'unassigned'`, check `speaker = 'unassigned'` (widened by Feature 006) |
| created_at | INTEGER not null |

Indexes: `transcript_segments_page ON transcript_segments(meeting_id, finality, ordinal)` for keyset paging; `transcript_segments_pass ON transcript_segments(pass_id)` for pass deletion.

Validation at insert (store-side, before the transaction): `start_ms < end_ms`; `end_ms ≤ covered length of the stretch so far`; the three texts within their byte caps; `ordinal` equals the pass's next ordinal; the per-meeting and global capacity counters stay within limits after the batch (otherwise the whole batch is refused with `persistence_capacity` and nothing is written). A final row is never updated after insert (FR-009); a pass that restarts deletes its rows by `pass_id` first.

## Live gap

Table `transcript_live_gaps`. Intervals of the recorded-audio timeline the live path did not analyze.

| Column | Type and rule |
| --- | --- |
| id | TEXT primary key, UUID |
| meeting_id | TEXT not null, references `meetings(id)` `ON DELETE CASCADE` |
| pass_id | TEXT not null; the live pass |
| stretch_sequence | INTEGER not null, ≥ 1 |
| start_ms | INTEGER not null, ≥ 0 |
| end_ms | INTEGER not null, > `start_ms` |
| reason | TEXT in `('backpressure','suspended','tap_overflow','pause_drain','stop_drain','model_reload')` |
| covered_by_final | INTEGER 0/1, set by the completing final pass |
| created_at | INTEGER not null |

At most 10,000 gap rows per meeting; further gaps are merged into the last row (extending `end_ms`) and counted in `failure_detail`-free instrumentation. Gaps are deleted with the provisional segments when a final pass completes, after their count and total milliseconds are recorded in the pass's instrumentation and `covered_by_final` has been reported.

## Transcript usage

Table `transcript_usage`, one row (`id = 1`), maintained inside every segment-writing and deleting transaction:

| Column | Rule |
| --- | --- |
| id | INTEGER primary key, check `id = 1` |
| text_bytes | INTEGER ≥ 0; Σ `text_bytes` over all `meeting_transcriptions` |
| segment_rows | INTEGER ≥ 0 |
| schema_version | INTEGER, check `= 1` |

Limits (declared, [research.md](research.md), "Storage"): per meeting 20,000 segments and 16 MiB text; global 48 MiB text. The dictation `history_usage` row is not read or written by any transcript path.

A trigger-free design is kept: the store updates the counters in the same statement batch, and `MeetingStore.deleteConfirmed` gains one extra statement in its existing transaction that subtracts the meeting's `text_bytes` and `segment_count` from `transcript_usage` before the cascade.

## Vocabulary snapshot

Not a table. `VocabularySnapshot` (existing: `revision`, `hash`, entries) held in memory for one pass and recorded on the transcription row as `vocabulary_revision`/`vocabulary_hash`.

## Transcript recovery outcome

Not a new table. `TranscriptReconciler` calls `recover(row:to:outcome:)` to commit the state change and one `meeting_recovery_outcomes` row per reconciled transcription with `summary` prefixed `transcript:` and the found and resulting transcript states, reusing Feature 004's outcome display. Per-launch bound: 100 active rows. `run()` returns `Summary`; `Summary.resume` contains unchanged finalizing rows eligible for automatic resume. Still-active meetings are deferred.

## In-memory value types

| Type | Purpose | Bound |
| --- | --- | --- |
| `TranscriptStatus` | The one observable value `MeetingTranscriptionCoordinator` publishes: `meetingID`, `state`, `liveState`, `lagSeconds`, `provisionalCount`, `finalCount`, `gapCount`, `failure`, `progress` (0…1 during finalizing), `metadata` (engine, model, planner, vocabulary revision) | one struct |
| `LiveWindow` | planner output: `stretchSequence`, `windowIndex`, `startSample`, `sampleCount`, `isTail` | counters only |
| `AnalysisStreamDescriptor` | as above | ≤ 16,384 bytes serialized, ≤ 200 stretch entries |
| `TranscriptSegmentDraft` | segment before persistence | text ≤ 3 × 4,096 bytes |
| `TranscriptPage` | 200 segments | ≤ 200 rows; ≤ 2 pages resident |
| `FinalizationWorkItem` | one stretch: sequence, per-track relative path and duration, base offset | ≤ 10,000 stretches per pass; derived work items paged 100 at a time from `MeetingDetail` metadata |

## Wall-clock derivation

Pure function `wallClock(startMs:) -> Int64?` over `MeetingDetail`: find the stretch `n` with `stretch_base_ms[n] ≤ startMs < stretch_base_ms[n+1]` (bases from the pass's recorded stretch lengths, stored with the descriptor's `stretches` and each stretch's `covered_ms` in `analysis_descriptor_json`), return `meeting_segments.started_at` of that stretch's microphone segment (system if absent) `+ (startMs − stretch_base_ms[n])`. Returns nil when the stretch row is missing (interrupted meeting without recovered files).
