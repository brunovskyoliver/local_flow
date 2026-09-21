# Storage

SQLite is authoritative for structured client data; GRDB.swift is the Swift wrapper. Use explicit migrations, transactions and foreign keys. WAL is appropriate for concurrent local reads but its sidecars must be included in backup reasoning. Media lives in app-private filesystem directories, never SQLite BLOBs. Credentials live in Keychain.

Feature 001 includes shortcut/appearance/setup preferences and bounded transcription history with independent delivery, recovery and completeness fields. Its schema and paging/search policy are defined in `specs/001-local-dictation/data-model.md`. History retains successful and partial text until confirmed explicit Delete; insertion and Dismiss recovery update status only. Admission reserves capacity before capture; full storage blocks capture without eviction. No database dependency or migration is installed during initialization. Preferences may use UserDefaults; durable recoverable text uses SQLite. Do not log transcript content. Explain text-history retention to users and provide confirmed deletion. Use 20-row pages, at most two resident pages and one selected row; search all retained text without loading the full history.

Future tables may include meetings, meeting_audio, transcript_segments, participants, speaker_profiles, speaker_embeddings, notes, action_items, decisions, summary_artifacts, sync_jobs and model_metadata. This is a vocabulary, not a migration backlog. Embeddings have their own versioned records with model, version, dimension, quality and creation time. Unknown identity is represented explicitly.

Use stable UUIDs, atomic manifest replacement, finalized media fragments and startup inspection for future recordings. Files and SQLite cannot share one transaction: record intermediate states and reconcile incomplete work. Test disk-full and crash boundaries.

Backup uses SQLite's online backup API or another proven consistent snapshot, plus content-addressed media manifests. Never copy an active SQLite main file alone. The client remains authoritative; resumable, idempotent archive transfer is Feature 009. Distributed conflict resolution and true synchronization are Feature 012 only if required.

## Rewrite attempts

Migration `rewrite-v4` adds `rewrite_attempts` and transcription fields for rewrite state and delivered source/attempt. The faithful transcript remains unchanged. Each admitted attempt keeps its input snapshot/hash, ordinal, terminal state, validated output/hash, identity and latency spans. The newest attempt mirrors its state onto the transcription in the same transaction. Current successful output and delivered output are tracked separately.

Admission transactionally checks ten attempts per dictation, one pending attempt per dictation and the shared 33,554,432-byte payload quota. It reserves input bytes plus min(4 × input bytes, 65,536) output bytes. Success adjusts to actual output size; other terminal states release the output reservation. Refusal creates no row and consumes no ordinal. Startup marks pending attempts failed/interrupted and reconciles quota. Confirmed transcription deletion cascades to attempts; delivered-attempt references use `ON DELETE SET NULL`.

Endpoint, mode and timeout preferences live in UserDefaults. Secrets live only in Keychain, keyed by endpoint origin. See [the data model](../../specs/003-server-rewriting/data-model.md) for fields and constraints.

## Meetings

Migration `meetings-v5` adds `meetings`, `meeting_tracks`, `meeting_segments`, `meeting_pauses`, `meeting_notes` and `meeting_recovery_outcomes` with `ON DELETE CASCADE` on every child, closed value sets for states, reasons, codec (`aac_lc`) and container (`adts`), a partial index on active states and a partial unique index on the one open pause per meeting. A `MeetingStore` actor shares the history `DatabaseQueue`; every transition is written before it is published and recomputes `recorded_ms`/`wall_clock_ms`. Media lives under `<Application Support>/LocalFlow/Meetings/<uuid>/` as `mic-NNNN.aac` / `system-NNNN.aac` (`.part` while open) with paths stored relative to that root; the database, not the file name, decides what a file is. Launch reconciliation (`MeetingReconciler`) ends every active-state row, validates and truncates open `.part` files to the last complete ADTS frame, closes open pauses at the row's `updated_at`, reconstructs orphan directories as `interrupted` meetings and records one outcome row per meeting; it deletes nothing and is bounded to 100 rows and 1,000 directory entries per launch. Confirmed deletion removes files first and the row last; a partial failure keeps the row and reports the remaining paths. See [the data model](../../specs/004-meeting-capture-foundation/data-model.md).

## Meeting transcripts (Feature 005)

Migration `transcripts-v6` adds `meeting_transcriptions`, `transcript_segments`, `transcript_live_gaps` and the singleton `transcript_usage` counter to the shared database. `TranscriptStore` owns writes. New meetings create their transcription row in the preparing transaction; reading a terminal pre-migration meeting lazily creates a `not_requested` row so Transcribe is available.

Each meeting permits 20,000 segments and 16 MiB across raw, assembled and normalized UTF-8 text; the global transcript text limit is 48 MiB. Each text column is capped at 4,096 bytes. Batches contain at most 50 segments and are refused atomically at capacity. Segment rows, per-meeting counts, global usage and finalization progress update together. These quotas count text payloads, not total SQLite file size. They are separate from dictation history usage.

Live and final pass rows can coexist. Completion deletes provisional rows and live gaps, updates coverage, and commits `final`. Identity mismatch during a resumed finalization uses `restartFinalPass` to remove earlier final rows, reset progress and recount usage in one transaction. Confirmed meeting deletion cancels and joins transcript work before files are removed; its database transaction subtracts usage and cascades transcript children. Partial filesystem deletion keeps the meeting row.

After meeting recovery, `TranscriptReconciler` reads at most 100 active transcription rows. Terminal meetings with pending/live transcripts become interrupted, or failed when the meeting failed. Finalizing rows for nonfailed terminal meetings remain finalizing and enter `Summary.resume`. Active meetings are deferred. Changed states and their `transcript:` recovery outcomes commit atomically through `recover(row:to:outcome:)`; failure rolls back both. Reconciliation neither opens audio nor acquires a model. Detailed contracts and columns are in the [Feature 005 data model](../../specs/005-live-meeting-transcription/data-model.md).

## Speaker diarization (Feature 007)

Migration `speakers-v7` adds `meeting_diarization` (one row per meeting, created for every existing meeting), `diarization_runs`, `meeting_speakers`, `speaker_turns`, `speaker_assignments` and `speaker_corrections`. There is no identity or embedding table; embeddings live in memory for one run only. `SpeakerStore` owns every write on the shared history `DatabaseQueue`. Each operation is one transaction except a window batch, which commits its turns 500 at a time.

A meeting has at most one `pending`/`running` run (partial unique index) and one accepted run. Adoption (`complete`) inserts the assignments, computes speech totals, colors and ordinals, carries names and corrections over from the previous accepted run, marks it `superseded`, deletes its turns and assignments and swaps the pointers, all in one transaction. Failure, interruption and preemption delete only the run's own rows; Cancel and meeting deletion remove the run row. The accepted run is never touched by a failed rerun.

Capacities: 64 clusters per track and run (later turns are stored with no speaker and counted as overflow), 100,000 turns per run, 20,000 turns per window and 10,000 corrections per meeting. A window past the turn cap fails the run as `persistence_capacity`; a save past the correction cap is refused with nothing written. `ON DELETE CASCADE` runs from `meetings` to every table and from `transcript_segments` to `speaker_assignments`, so meeting deletion and `discardPass` remove speaker rows with their parents. Names are metadata on `meeting_speakers`; merges set `merged_into` (depth 1); segment corrections set the `manual_*` columns beside the untouched automatic assignment. Manual "new speaker" rows have `run_id` NULL and survive reruns. See [the data model](../../specs/007-speaker-diarization/data-model.md).

## Speaker identities (Feature 010)

Migration `identities-v8` adds `known_speakers`, `voice_samples`, `meeting_identification`
(one row per meeting, created for every existing meeting and with each new one),
`identification_runs`, `identity_assignments`, `match_candidates` and
`rejected_candidates`; no 004–007 table changes. `IdentityStore` owns every write on the
shared history `DatabaseQueue`, one transaction per operation.

Vectors are 1,024-byte `BLOB`s (256 little-endian Float32, L2-normalized) in
`voice_samples`, each with its engine, model id, revision, manifest hash, dimension,
pipeline version, quality label and score, track, time range, source meeting and cluster
(`ON DELETE SET NULL`), the consent that created it (`remember`, `also_remember`,
`local_enroll`) and its creation date. A speaker holds at most 10 active and 10 retired
samples per model identity; `retire_qd_v1` retires the lowest quality-and-diversity
scores inside the insert transaction. Samples of another engine, model, revision or
dimension are stored but never compared.

A meeting has at most one `pending`/`running` identification run (partial unique index)
and one accepted run, admitted against the accepted diarization run. Adoption is one
transaction: `self` rows for decided roots are inserted or replaced only where the
existing row's origin is `automatic_match`, manual rows (`user_confirmation`,
`manual_profile_selection`, `new_profile_created`, `manual_correction`, `kept_unknown`)
are counted as preserved, a rejected pair is never re-suggested, the previous run is
`superseded` and its `match_candidates` deleted. Failure, interruption and preemption
delete only the run's own candidate rows; Cancel and meeting deletion remove the run row.
Launch reconciliation (`IdentificationReconciler`) marks `running` runs `interrupted` and
hands `pending` ones back to the queue without reading audio.

Deletion matrix: deleting a known speaker copies its name onto every `confirmed` or
`recognized` meeting speaker that lacks one, deletes its assignment, candidate, rejected
and sample rows, then the profile; transcript text, turns and audio are untouched.
Deleting a meeting cascades every identity table and nulls the provenance of its samples,
which stay active. Renaming a known speaker copies the new name to every linked
`confirmed`/`recognized` meeting speaker in batches of 500 inside one transaction; typed
names with no link are untouched. Merges write a `merged` scope row on the display root
(`MergedIdentityRule`); unmerge deletes it and never touches `self` rows. A diarization
rerun carries manual identity rows and rejected pairs along the safe name map and lists
the rest as review notices. See
[the data model](../../specs/010-persistent-speaker-identification/data-model.md).

## Meeting intelligence (Feature 011)

Migration `intelligence-v9` adds `analysis_runs`, `meeting_analysis`,
`analysis_summaries`, `analysis_topics`, `analysis_items`, `analysis_sources` and
`analysis_overlays`. `AnalysisStore` owns every write on the shared history
`DatabaseQueue`, one transaction per operation; analysis never writes to transcript,
notes, diarization, known-speaker, voice-sample or identity-assignment rows.

`meeting_analysis` is the per-meeting pointer row, created for every existing meeting
and with each new one: `accepted_run_id`, `current_run_id`, the accepted run's evidence
version and a revision counter. A meeting has at most one `pending`/`running` run
(partial unique index) and is queued at most 100 runs deep per the client contract.
Each `analysis_runs` row carries its trigger, evidence version, transcript pass id,
server/backend/prompt/pipeline identity, `language_policy`, the request configuration,
content-free counters (chunks, requests, retries, preemptions, bytes, items, dropped
literals and unsupported items, identity downgrades, unresolved owners) and, on
failure, a categorized `failure_category` plus a bounded `failure_detail` code —
never text.

Adoption is one transaction. It first checks `current_run_id` still names the adopting
run — a result that arrives after its run left `running` writes nothing and the run is
marked `superseded` instead of failing. It then swaps the accepted pointer, copies the
evidence version and inserts the summary, topics, items and `analysis_sources` rows
under the new `run_id`; the previous run's result rows are deleted with the pointer
swap. `CHECK` constraints keep the shape honest: only `action_item` rows may carry
owner and due fields, a `participant` owner requires `owner_speaker_id`, a `mentioned`
owner requires `owner_name`, `due_date` is present exactly for the two explicit due
states, and each source row is either a transcript segment (`ON DELETE CASCADE`) or a
note paragraph by ordinal and content hash.

User edits are overlays, not rewrites of the adopted result. `analysis_overlays` rows
target the summary (one per meeting, partial unique index) or an item field (one per
item and field), and snapshot the AI value, the item text and the source key at edit
time. On regeneration, `OverlayMatcher` re-attaches each overlay to the new result by
item id first, then source key, then text; an overlay that matches nothing is kept and
marked `orphaned_at` so it still shows under Previous edits. Deleting a meeting
cascades every analysis table; removing a meeting's transcript segments removes the
source rows that point at them.

The evidence version is a hash over the segments, notes and speaker assignments — the
inputs a summary depends on, with display names excluded. `evidenceDidChange`
recomputes it: a changed value marks the accepted run's analysis `stale` (readable,
bannered, regenerable), while a display-name-only rename leaves the version untouched.
See [the data model](../../specs/011-meeting-intelligence/data-model.md).
