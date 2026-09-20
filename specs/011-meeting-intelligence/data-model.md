# Data model: meeting intelligence

Migration `intelligence-v9` in `HistoryMigrations` adds seven tables to `history.sqlite`. No table from Features 001–010 is altered. Every meeting-scoped table cascades from `meetings`; analysis content cascades from `analysis_runs`; overlays cascade from `meetings` and null their item pointer when the item goes. Times are Unix milliseconds. Identifiers are UUID strings. Text lengths are byte lengths (`length(CAST(x AS BLOB))`).

## Entities

### AnalysisRun (`analysis_runs`)

One generation attempt for one meeting. Content-free: it never holds summary or item text (FR-004, FR-011a).

| Column | Type | Rule |
| --- | --- | --- |
| id | TEXT PK | |
| meeting_id | TEXT | FK `meetings` cascade |
| state | TEXT | `pending`, `running`, `succeeded`, `failed`, `cancelled`, `timed_out`, `interrupted`, `superseded` |
| trigger | TEXT | `automatic`, `manual`, `retry`, `regenerate`, `restart` |
| evidence_version | TEXT | 64 lowercase hex |
| transcript_pass_id | TEXT | the final pass the evidence came from |
| server_version | TEXT | ≤ 64, from `accepted`/`result` |
| protocol_version | INTEGER | = 1 |
| schema_version | INTEGER | = 1 (result schema) |
| backend_kind, backend_model | TEXT | ≤ 128 each |
| prompt_versions | TEXT | ≤ 128, `chunk=3,synthesis=2,full=3` form |
| pipeline_version | TEXT | ≤ 64, `chunking_v1/overlay_match_v1/policy_v1` |
| language_policy | TEXT | `sk`, `en`, `mixed` |
| request_config_json | TEXT | ≤ 2,048; the `AnalysisPolicy` values used |
| created_at, started_at, completed_at | INTEGER | `started_at` set on `running`; `completed_at` on any terminal state |
| failure_category | TEXT | see below; `(failure_category IS NOT NULL) = (state IN ('failed','timed_out','interrupted'))` |
| failure_detail | TEXT | ≤ 512, content-free code |
| chunk_count, request_count, retry_count, preemption_count | INTEGER ≥ 0 | |
| input_bytes, output_bytes | INTEGER ≥ 0 | sum over requests |
| item_count, dropped_literal_count, dropped_unsupported_count, identity_downgrade_count, unresolved_owner_count | INTEGER ≥ 0 | validation outcome |
| duration_ms | INTEGER ≥ 0 | |

Failure categories: `not_eligible`, `server_unreachable`, `authentication_failed`, `server_unavailable`, `backend_unavailable`, `backend_busy`, `backend_timeout`, `unsupported_version`, `malformed_response`, `oversized_response`, `meeting_mismatch`, `source_validation`, `protected_literal`, `unsupported_content`, `over_cap`, `too_long`, `timeout`, `persistence_failure`, `persistence_capacity`, `interrupted`.

Indexes: `(meeting_id, created_at)`; unique partial `(meeting_id) WHERE state IN ('pending','running')`.

Transitions: `pending → running → succeeded | failed | timed_out | cancelled`; `pending → cancelled`; `pending | running → interrupted` (launch reconciliation only); `succeeded → superseded` when a newer run is adopted. A run whose response arrives after it left `running` writes nothing.

### MeetingAnalysis (`meeting_analysis`)

One row per meeting, inserted with the meeting (like `meeting_identification`) and by the migration for existing meetings.

| Column | Rule |
| --- | --- |
| meeting_id | PK, FK cascade |
| accepted_run_id | FK `analysis_runs` set null; the run whose content is stored |
| current_run_id | FK set null; newest run; late responses compare against it |
| accepted_evidence_version | 64 hex or NULL; copy of the accepted run's value for the stale check |
| auto_restarted_at | NULL or the launch time of the last FR-007a restart |
| updated_at, revision | |

Stale is not a column: it is `accepted_evidence_version != EvidenceVersion.compute(meeting)` at read time.

### AnalysisSummary (`analysis_summaries`)

| Column | Rule |
| --- | --- |
| run_id | PK, FK `analysis_runs` cascade; exactly one row per accepted run |
| meeting_id | FK cascade |
| text | 1…4,000 bytes |
| language | `sk`, `en`, `mixed` |
| whole_meeting | 0/1; 1 when the model referenced the meeting as a whole |

### AnalysisTopic (`analysis_topics`)

| Column | Rule |
| --- | --- |
| id | PK |
| run_id, meeting_id | FK cascade |
| ordinal | ≥ 0, unique per run |
| title | 1…200 bytes |
| summary | ≤ 2,000 bytes |
| bullets_json | JSON array of ≤ 12 strings ≤ 500 bytes each; rendered as bullets, never parsed for structure |

### AnalysisItem (`analysis_items`)

Decisions, action items, next steps, open questions and risks share one shape plus action-item columns.

| Column | Rule |
| --- | --- |
| id | PK |
| run_id, meeting_id | FK cascade |
| kind | `decision`, `action_item`, `next_step`, `open_question`, `risk` |
| ordinal | ≥ 0, unique per (run, kind) |
| text | 1…1,000 bytes |
| evidence_class | NULL, `explicit`, `implied` (stored, not shown) |
| topic_id | NULL or FK `analysis_topics` set null |
| owner_kind | NULL unless `kind='action_item'`; then `participant`, `mentioned`, `none` |
| owner_speaker_id | FK `meeting_speakers` set null; `(owner_kind='participant') = (owner_speaker_id IS NOT NULL)` at insert (set-null later leaves an orphan the read model renders as unresolved) |
| owner_known_speaker_id | FK `known_speakers` set null; only with `participant` |
| owner_name | 1…80 bytes only when `owner_kind='mentioned'`; NULL otherwise (participant names resolve at render time, FR-031a) |
| owner_certainty | `confirmed`, `recognized`, `local_name`, `local_user` with `participant`; NULL otherwise |
| ownership_state | `explicit`, `supported`, `unresolved`; `mentioned` ⇒ at most `supported`; `none` ⇒ `unresolved` |
| due_state | `explicit_absolute`, `explicit_relative_resolved`, `unresolved`, `absent` |
| due_date | `YYYY-MM-DD` only when `due_state` is one of the two explicit states |
| due_original | ≤ 80 bytes; required unless `absent` |
| due_source_segment_id, due_source_note_ordinal | the reference for the due phrase; at most one set; required unless `absent` |
| CHECKs | action-item columns are NULL when `kind <> 'action_item'`; `due_date IS NULL` unless `due_state` explicit; `owner_name IS NULL` unless `mentioned` |

Index: `(run_id, kind, ordinal)`.

### AnalysisSource (`analysis_sources`)

Item, topic or summary → transcript segment or note paragraph.

| Column | Rule |
| --- | --- |
| run_id, meeting_id | FK cascade |
| target_kind | `summary`, `topic`, `item` |
| target_id | `run_id` for summary, else topic/item id |
| ordinal | ≥ 0 |
| source_kind | `segment`, `note` |
| segment_id | FK `transcript_segments` cascade; set iff `segment` |
| note_ordinal | ≥ 1; set iff `note` |
| note_hash | 64 hex; set iff `note` |
| PK | `(target_kind, target_id, ordinal)` |
| cap | ≤ 10 per target (`SourceReferenceCap`), enforced before insert |

When a referenced segment row disappears (a re-finalized transcript deletes its pass), the cascade removes the reference; the evidence version has changed anyway and the analysis reads stale.

### AnalysisOverlay (`analysis_overlays`)

A user edit or a local status, stored beside the AI value and carried across regenerations (FR-032 to FR-034).

| Column | Rule |
| --- | --- |
| id | PK |
| meeting_id | FK cascade |
| item_id | FK `analysis_items` set null; NULL means orphaned (or the summary) |
| target_kind | `summary`, `item` |
| item_kind | NULL for summary; else the item kind at edit time |
| field | `summary_text`, `task_text`, `decision_text`, `next_step_text`, `owner`, `due_date`, `status` |
| user_value | ≤ 4,000 bytes; text, or a JSON object for `owner` (`{"kind":"participant","speaker_id":…}` / `{"kind":"mentioned","name":…}` / `{"kind":"none"}`) and `due_date` (`{"date":"YYYY-MM-DD"}` or `{"date":null}`), or `open`/`completed`/`dismissed` for `status` |
| ai_value_snapshot | ≤ 4,000 bytes; the AI value at edit time, shown under Previous edits |
| item_text_snapshot | ≤ 1,000 bytes; matching input |
| source_key | ≤ 1,024 bytes; sorted source ids joined by `,`; matching input |
| created_at, updated_at | |
| orphaned_at | NULL while matched |
| UNIQUE | `(item_id, field)` where `item_id IS NOT NULL`; one summary overlay per meeting |
| cap | ≤ 500 overlays per meeting; the store refuses beyond it with `persistence_capacity` |

Owner edits to a participant require the participant to be nameable under FR-014 at edit time; the user may still choose any speaker (their own decision), which is stored as `{"kind":"participant","speaker_id":…}` and rendered from the speaker record. Nothing in this table references voice samples or writes to spec 010 tables (FR-035).

## Read models (Swift, `Core/IntelligenceBoundaries.swift`)

- `AnalysisStatus`: `meetingID`, `state` (`notRequested`, `pending`, `running`, `succeeded`, `failed`, `cancelled`, `timedOut`, `interrupted`), `progress` (stage label and fraction), `failure`, `stale`, `hasAccepted`, `queuedPosition?`.
- `MeetingAnalysisReadModel`: `summary` (text, edited flag, sources), `topics`, `nextSteps`, `decisions`, `openQuestions`, `risks`, `actionItems`, `previousEdits`, `readingMinutes`, `evidenceVersion`, `stale`, `generatedAt`, `backendModel`.
- `ActionItemReadModel`: `id`, `text` (effective), `aiText`, `owner: OwnerLabel` (`.participant(name, colorIndex, certaintyCase)`, `.mentioned(name, suggestion: KnownSpeakerRef?)`, `.unresolved(label)`), `ownershipState`, `dueDate`, `dueOriginal`, `dueState`, `status`, `sources`, `edits: Set<Field>`.
- `SourceRef`: `.segment(UUID)` or `.note(ordinal, hash)`.

Participant owner names and colors come from `SpeakerStore.speakerSummaries` and `IdentityStore.identities` at load time, never from this schema.

## Wire types (Swift `AnalysisProtocol.swift`, Go `analysis/protocol.go`)

Defined in [contracts/analysis-protocol.md](contracts/analysis-protocol.md). The stored schema and the wire schema differ on purpose: the wire result carries model-proposed owners by `speaker_id`; the store carries the validated owner with certainty; the wire result never carries user overlays.

## Retention and deletion

- Adoption (one transaction): mark the previous accepted run `superseded`; delete its summary, topics, items and sources; insert the new content; re-point `meeting_analysis`; re-match overlays (R13); prune run rows beyond 20 per meeting, oldest non-accepted first.
- Failed, cancelled, timed-out and interrupted runs own no content rows.
- Meeting deletion: the coordinator cancels and joins, then `meetings` cascades through every table here (FR-052).
- Nothing here is exported or backed up separately; it rides with `history.sqlite`.
