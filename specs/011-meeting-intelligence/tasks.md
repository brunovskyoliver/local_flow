---

description: "Task list for Feature 011 — meeting intelligence"
---

# Tasks: Meeting intelligence

**Input**: Design documents from `/specs/011-meeting-intelligence/`

**Prerequisites**: plan.md, spec.md, research.md, data-model.md, contracts/analysis-protocol.md, contracts/client-analysis.md, contracts/ui.md, quickstart.md

**Tests**: Included. The plan's test strategy names the XCTest suites and Go tests `make check` must run, and constitution principle 12 requires doubles and lifecycle coverage at every external boundary. Write each story's tests first and confirm they fail before implementing.

**Organization**: Tasks are grouped by user story so each story can be implemented and tested on its own. The twelve stories keep the spec's order: US1–US5 (P1), US6–US10 (P2), US11–US12 (P3).

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependency on an unfinished task)
- **[Story]**: The user story the task serves (US1–US12)
- Paths are relative to the repository root. App sources live under `apps/macos/LocalFlow/`, tests under `apps/macos/LocalFlowTests/`, the server under `server/`
- Every new Swift file must be registered in `apps/macos/LocalFlow.xcodeproj/project.pbxproj` in the same task that creates it (`scripts/register-xcode-sources.py`)

## Provisional values

Chunk budget 24,576 B, `full` when total segment bytes ≤ 24,576 B, chunks per run ≤ 64, partials per synthesis 16 with reduce depth 2, output tokens 2,048 chunk / 3,072 full and synthesis, per-request backend timeout 120 s with 15 s first token, run timeout 60 s + 90 s × requests within [120 s, 30 min], server queue wait 30 s, preemption retries 3 per stage, dropped-item share > 1/3 fails the run, sources per item 10, section caps topics 20 / decisions 40 / action items 60 / next steps 40 / open questions 40 / risks 40 (partial caps half), run rows per meeting 20, overlays per meeting 500, queue capacity 100, evidence page 200 segments, language sample 32 KiB, context estimate 3 bytes per token against 32,768 tokens. Implement each as a named constant in `AnalysisPolicy` (client) or `limits.go` (server) that feeds the `policy_v1`, `chunking_v1` or `overlay_match_v1` version string. T113 freezes them from the acceptance runs. No task may claim a measured value before its acceptance file records it.

## Vocabulary guard

"Analysis" in this feature means meeting intelligence. The existing audio types `AnalysisQueue`, `AnalysisStreamMixer` and `AnalysisTracks` (Feature 004/005 audio analysis) are unrelated and must not be reused or extended. Evidence (segments, speaker assignments, identity state, notes) is read-only for every task below; no task may add a write method to `MeetingEvidenceReader` or touch `known_speakers`, `voice_samples` or `identity_assignments`. Participant owner names are never stored on an analysis row; they resolve from the speaker record at render time (FR-031a).

---

## Phase 1: Setup (shared infrastructure)

**Purpose**: Acceptance scaffolding, the fixture corpus every suite replays, and the import guard.

- [x] T001 Create `specs/011-meeting-intelligence/acceptance/` with `throughput.md`, `priority.md`, `memory.md`, `quality.md`, `recovery.md` and `regression.md`, each containing only a heading and the status line "Unmeasured"
- [x] T002 [P] Create `fixtures/intelligence/` per research R17: a `README.md` describing the fixture format (meeting JSON with `id`, `title`, `started_at`, `time_zone`, participants with `speaker_id`/certainty/origin/name/candidate-name-kept-local, segments with ids and `normalized_text`, notes text) and the scripted-response format (one NDJSON stream per stage); fixture meetings `deployment.json` (Oliver Confirmed, Martin and Peter meeting-local names, one Possible-match speaker with candidate "Tomáš Juríček", the four deployment lines and the note "Customer specifically requested Monday"), `certainty-confirmed.json`, `certainty-possible.json`, `certainty-unknown.json` (same line "I'll call the customer"), `due-dates.json` (meeting dated 2026-09-20 with "We will deploy on Monday", "We could maybe deploy Monday", "I'll send it tomorrow", "I'll send it soon", "Someone needs to send the report"), `slovak.json`, `english.json`, `mixed.json` (with "deployment", "backup", "M6"), and a generator note for `fourhour.json` (synthetic, ~200 KB of segments, unique decision in the last five minutes); scripted responses `deployment-valid`, `fabricated-segment`, `cross-meeting-segment`, `mutated-ip-item`, `mutated-price-decision`, `mutated-digit-summary`, `over-cap-decisions`, `unsupported-version`, `wrong-meeting`, `malformed-json`, `named-possible-owner`, `mentioned-owner`
- [x] T003 [P] Create `scripts/check-intelligence-imports.sh` (fails if `apps/macos/LocalFlow/Core/Intelligence`, `apps/macos/LocalFlow/Core/IntelligenceBoundaries.swift`, `apps/macos/LocalFlow/Core/Storage/AnalysisStore.swift` or `apps/macos/LocalFlow/Features/Intelligence` reference `FluidAudio`, `whisper`, `WhisperKit`, `ModelLifecycleCoordinator` or a model factory, and if any file other than `Core/Intelligence/AnalysisClient.swift` in those directories references `URLSession`, `URLRequest`, `import Network` or `NWConnection`), modelled on `scripts/check-identification-imports.sh`, and add it to `scripts/test.sh` beside the identification check

---

## Phase 2: Foundational (blocking prerequisites)

**Purpose**: Wire contract on both sides, the promoted backend adapter, the server service, storage, evidence reading, the evidence version, language detection, the transport, the validator skeleton and overlay matching. Every user story depends on this phase.

**⚠️ CRITICAL**: No user story work can begin until this phase is complete.

### Protocol and schemas (delivery step 1)

- [x] T004 Write `protocol/schemas/analysis-request.schema.json`, `protocol/schemas/analysis-result.schema.json` and `protocol/schemas/analysis-event.schema.json` exactly as in `contracts/analysis-protocol.md` (`additionalProperties: false` everywhere; `schema_version` const 1; `priority` enum `background`; `stage` enum `full`/`chunk`/`synthesis`; `chunk.index` 0-based < `count` ≤ 64; `meeting.title` ≤ 256 bytes; `time_zone` ≤ 64 bytes; `language_policy.output` enum `sk`/`en`/`mixed`; participants 0…64 with `certainty` enum `confirmed`/`recognized`/`possible`/`unknown`/`local_name`/`local_user`, `name` 1…80 bytes, `origin` ≤ 32 bytes; segments 1…4,096 with `text` 1…4,096 bytes; notes 0…256 with id pattern `note:<n>` and `text` 1…8,192 bytes; partials 1…16; result caps topics 20 / decisions 40 / action items 60 / next steps 40 / open questions 40 / risks 40 and partial caps half; `summary.text` 1…4,000; `topic.title` 1…200, `summary` ≤ 2,000, `bullets` ≤ 12 × ≤ 500; item `text` 1…1,000; `sources` 0…10 for summary and topics, 1…10 for items; `owner.kind` enum with conditional `speaker_id`/`name`; `ownership_state` enum; `due.state` enum with `date` pattern `YYYY-MM-DD` only for explicit states and `original` 1…80 + `source` required unless `absent`; `evidence_class` enum absent on next steps); delete `protocol/schemas/meeting.schema.json` and `protocol/schemas/summary.schema.json` and remove every reference to them
- [x] T005 [P] Add `GET /v1/analysis/health` and `POST /v1/analysis/meeting` to `protocol/openapi.yaml` (request body, NDJSON response, the error-code table with HTTP statuses, the 262,144-byte body limit and 98,304-byte result-line limit) and an "Analysis service" section to `protocol/README.md` (event vocabulary, error codes, server bounds and flags, compatibility rules: 404 → `server_unavailable`, `result_schema_version ≠ 1` refuses, additive fields minor, everything else bumps `schema_version`)

### Client boundaries, run types and wire types

- [x] T006 Create `apps/macos/LocalFlow/Core/IntelligenceBoundaries.swift` exactly as in `contracts/client-analysis.md`: `AnalysisTransporting` (`analyze(request:endpoint:timeout:) -> AsyncThrowingStream<AnalysisTransportItem, Error>` with `.firstByte`, `.event(AnalysisEvent)`, `.completed(bytes)`; `health(endpoint:)`; `invalidate()`), `AnalysisStoring` (every method listed in the contract), `MeetingEvidenceReading` (`segmentPage`, `participants`, `notes`, `transcription`, `meeting`; no write methods), `IntelligenceObserving` (`meetingTranscriptDidFinalize`, `meetingWillDelete`, `evidenceDidChange`), and the value types `EvidenceSegment`, `EvidenceParticipant` (certainty, origin, `knownSpeakerID?`, permitted `name?`, candidate name never present), `NoteParagraph` (ordinal ≥ 1, text, 64-hex hash), `MeetingAnalysisPointer`, `StoredAnalysis`, `ValidatedAnalysis`, `ValidationCounts`, `RunIdentity`, `OverlayTarget`, `OverlayField` (`summary_text`, `task_text`, `decision_text`, `next_step_text`, `owner`, `due_date`, `status`), `OverlayValue`, `OverlaySnapshot`, `AnalysisOverlay`, and the read models `AnalysisStatus` (`notRequested`, `pending`, `running`, `succeeded`, `failed`, `cancelled`, `timedOut`, `interrupted`; `progress`, `failure`, `stale`, `hasAccepted`, `queuedPosition?`), `MeetingAnalysisReadModel`, `ActionItemReadModel`, `OwnerLabel` (`.participant(name, colorIndex, certaintyCase)`, `.mentioned(name, suggestion: KnownSpeakerRef?)`, `.unresolved(label)`), `SourceRef` (`.segment(UUID)`, `.note(ordinal, hash)`). Every value `Sendable`; no networking or model import
- [x] T007 [P] Create `apps/macos/LocalFlow/Core/Intelligence/AnalysisRun.swift` with run states (`pending`, `running`, `succeeded`, `failed`, `cancelled`, `timed_out`, `interrupted`, `superseded`), triggers (`automatic`, `manual`, `retry`, `regenerate`, `restart`), the failure categories `not_eligible`, `server_unreachable`, `authentication_failed`, `server_unavailable`, `backend_unavailable`, `backend_busy`, `backend_timeout`, `unsupported_version`, `malformed_response`, `oversized_response`, `meeting_mismatch`, `source_validation`, `protected_literal`, `unsupported_content`, `over_cap`, `too_long`, `timeout`, `persistence_failure`, `persistence_capacity`, `interrupted`, the transition table from data-model.md (`pending → running → succeeded | failed | timed_out | cancelled`; `pending → cancelled`; `pending | running → interrupted`; `succeeded → superseded`), `RunIdentity` (server version, protocol version 1, schema version 1, backend kind/model, prompt versions string `chunk=…,synthesis=…,full=…`, pipeline version `chunking_v1/overlay_match_v1/policy_v1`), and the server error-code → category mapping from the protocol contract; and `apps/macos/LocalFlow/Core/Intelligence/AnalysisPolicy.swift` holding every provisional value above as a named constant, the permitted-certainty set `{confirmed, recognized, local_name, local_user}`, the vague-term list, the `policy_v1` version string and a `request_config_json` encoder (≤ 2,048 bytes)
- [x] T008 [P] Create `apps/macos/LocalFlow/Core/Intelligence/AnalysisProtocol.swift`: `AnalysisRequest` (exact key set from the contract, `Encodable` with no optional keys emitted when absent), `AnalysisHealth`, `AnalysisEvent` (`accepted`, `progress`, `result`, `error` with `code`), `AnalysisResult` and its nested types, and a bounded decoder that enforces one line ≤ 98,304 bytes, unknown-field rejection, closed enums, byte lengths, per-section caps (partial caps when `partial == true`), duplicate source ids within one list, and yields `malformed_response`, `unsupported_version` or `over_cap`
- [x] T009 [P] Create `apps/macos/LocalFlowTests/AnalysisProtocolTests.swift`: the contract's request and result examples round-trip; every rejection (unknown field, over-cap section, over-length text, invalid enum, `schema_version` 2, `date` present with `absent`, duplicate source id, oversized line) yields the named category; the encoded request's key set equals exactly `schema_version, request_id, run_id, priority, stage, chunk?, meeting{id,title,started_at,duration_ms,time_zone,language_policy}, participants[speaker_id,certainty,origin,known_speaker_id?,name?], segments[id,start_ms,end_ms,speaker_id,text], notes[id,text], partials` and nothing else
- [x] T010 [P] Create `apps/macos/LocalFlowTests/Support/IntelligenceFakes.swift`: `FakeAnalysisTransport` (scripted stream per `stage` and attempt, delays, error injection by code, records every request and its byte size, observes cancellation, scripted `health`, counts `invalidate`), `FakeAnalysisStore` (in-memory rows honouring the transition table and capacities), `FakeEvidenceReader` (paged segments, participants, note paragraphs, transcription state; records every call so FR-009 can assert no transcription/diarization/identification call), a controllable clock, and a loader for `fixtures/intelligence/` meetings and scripted responses

### Server (delivery step 2)

- [x] T011 `git mv server/internal/rewrite/backend server/internal/backend`, update every import path, extend `backend.Input` with `ResponseSchema map[string]any` and `MaxOutputTokens int`, keep the rewrite handler passing `{"type":"string"}`, and confirm `go test ./...` under `server/` passes with no rewrite test changed
- [x] T012 Create `server/internal/analysis/protocol.go` and `server/internal/analysis/protocol_test.go`: request, result, event and health types; decoding with a 262,144-byte body limit, `DisallowUnknownFields`, and every field rule from the contract table (uniqueness of `speaker_id` and segment ids, `speaker_id` ∈ participants, `end_ms ≥ start_ms`, note ids `note:<n>` strictly increasing, `chunk` required iff `stage == chunk`, `segments` absent for `synthesis`, `partials` present only for `synthesis`, `name` only with permitted certainties, `known_speaker_id` only with `confirmed`/`recognized`, sum of text bytes ≤ input limit); one test per rejection returning `invalid_request`, `too_large` or `unsupported_version`
- [x] T013 [P] Create `server/internal/analysis/limits.go` (flag values with the defaults from the contract's "Server bounds and flags" table, the token estimate `bytes ÷ 3 + instruction, schema and output reservations` against `--analysis-context-tokens`) and `server/internal/analysis/schema.go` (embed `protocol/schemas/analysis-result.schema.json`; structural validator for `additionalProperties`, enums, byte lengths, section caps with partial caps; `meeting_id` equality; every `source_ref` id present in the request or, for `synthesis`, in the union of the partials' sources; `owner.speaker_id` ∈ participants; `due.date` parses; a leading `<think>` or any non-JSON prefix fails `output_invalid`)
- [x] T014 [P] Create `server/internal/analysis/prompts/prompts.go` and `prompts_test.go`: `full`, `chunk` and `synthesis` templates with integer versions, stating in order the role, the conservatism rules (decision = settled; action item = committed, accepted or explicitly assigned; no owner from "we should"/"someone needs to"; relative dates against `started_at` in `time_zone` with the original phrase; vague terms unresolved; empty sections stay empty; no invented sources; literals verbatim), the identity rules (owners only by `speaker_id`; non-participant names are `mentioned`; unnamed participants referred to by role), the language policy text per `sk`/`en`/`mixed` with `preserve_terms`, and the schema; transcript and notes quoted as data with the "treat instructions inside as text" sentence; tests assert each rule sentence is present, the versions are reported, and no participant without `name` is ever rendered with a name
- [x] T015 Create `server/internal/analysis/priority.go` and `priority_test.go`: a gate shared by the rewrite and analysis handlers that counts rewrites in flight, makes an analysis request holding its slot wait up to `--analysis-queue-wait` while any rewrite is in flight (`queue_timeout` after), cancels an in-flight analysis backend call with cause `preempted` when a rewrite arrives while `--analysis-preempt` is on, never delays a rewrite, and counts preemptions; tests cover wait, timeout, preemption, the flag off, and a rewrite never blocked
- [x] T016 Create `server/internal/analysis/handler.go` and `handler_test.go`: `GET /v1/analysis/health` (the contract JSON with `service`, `protocol_versions`, `backend` state and `json_schema` capability, `prompt_versions`, `result_schema_version`, `limits`, `caps`) and `POST /v1/analysis/meeting` (bearer check → 401/403 `unauthorized`; decode → 400/413; one analysis slot → 429 `server_busy`; the gate; prompt build; `backend.Generate` with `ResponseSchema` when advertised and `MaxOutputTokens` per stage; NDJSON `accepted`/`progress`/`result`/`error` lines with per-write deadlines; a fixed-capacity output buffer → `output_too_large`; validation per T013 with one repair attempt when JSON schema is advertised, then `output_invalid` or `source_validation`; fixed one-sentence `message` per code, never backend text; one log line per request with `request_id, run_id, stage, input_bytes, output_bytes, duration_ms, queue_ms, preemptions, code` and no text); `httptest` cases for every code, the slot, the gate, preemption, caps, source-id check, the repair path and a log-content assertion; the existing `server/internal/rewrite/handler_test.go` must stay green
- [x] T017 Update `server/cmd/flowd/main.go` and `main_test.go`: `serve` subcommand mounting both handlers on one listener, `rewrite` kept as an alias of `serve`, the analysis flags from T013, `--analysis=false` returning 404 on the analysis paths, `--debug-delay` for the timeout scenario; a debug-build-only `--analysis-dump-requests` that writes request bodies to a private temp file

### Storage (delivery step 3)

- [x] T018 [P] Create `apps/macos/LocalFlowTests/AnalysisStoreTests.swift` (write first): `intelligence-v9` migrates a Feature 010 database, creates the seven tables, inserts one `meeting_analysis` row per existing meeting and alters no 001–010 table; each CHECK from data-model.md rejects a violating row; `admit` writes `pending` and refuses a second `pending`/`running` run per meeting; `start`, `fail`, `timeOut`, `cancel`, `interrupt`, `recordRequest` follow the transition table and `completed_at`/`failure_category` rules; `adopt` in one transaction marks the previous accepted run `superseded`, deletes its summary/topics/items/sources, inserts the new content, re-points `accepted_run_id`, `current_run_id` and `accepted_evidence_version`, re-matches overlays through the injected matcher, and prunes run rows beyond 20 oldest-non-accepted-first; a write for a run whose state is not `running` or that is no longer `current_run_id` is refused; overlays beyond 500 fail `persistence_capacity`; `setOverlay` upserts on `(item_id, field)` and one summary overlay per meeting; `removeOverlay` deletes; a failed or cancelled run owns no content rows; the previous accepted content is byte-identical after a failed adoption
- [x] T019 Register migration `intelligence-v9` in `apps/macos/LocalFlow/Core/Storage/HistoryMigrations.swift` creating `analysis_runs`, `meeting_analysis`, `analysis_summaries`, `analysis_topics`, `analysis_items`, `analysis_sources` and `analysis_overlays` exactly as in data-model.md, including: `state` "`pending`, `running`, `succeeded`, `failed`, `cancelled`, `timed_out`, `interrupted`, `superseded`"; `trigger` "`automatic`, `manual`, `retry`, `regenerate`, `restart`"; `evidence_version` "64 lowercase hex"; `server_version` "≤ 64"; `protocol_version` "= 1"; `schema_version` "= 1"; `backend_kind, backend_model` "≤ 128 each"; `prompt_versions` "≤ 128"; `pipeline_version` "≤ 64"; `language_policy` "`sk`, `en`, `mixed`"; `request_config_json` "≤ 2,048"; `failure_category` "`(failure_category IS NOT NULL) = (state IN ('failed','timed_out','interrupted'))`"; `failure_detail` "≤ 512, content-free code"; the counters "INTEGER ≥ 0"; index `(meeting_id, created_at)` and the unique partial index `(meeting_id) WHERE state IN ('pending','running')`; `meeting_analysis` with `accepted_run_id`/`current_run_id` "FK `analysis_runs` set null", `accepted_evidence_version` "64 hex or NULL", `auto_restarted_at`; `analysis_summaries.text` "1…4,000 bytes", `language`, `whole_meeting` "0/1"; `analysis_topics.ordinal` "≥ 0, unique per run", `title` "1…200 bytes", `summary` "≤ 2,000 bytes", `bullets_json`; `analysis_items.kind` "`decision`, `action_item`, `next_step`, `open_question`, `risk`", `ordinal` "≥ 0, unique per (run, kind)", `text` "1…1,000 bytes", `evidence_class` "NULL, `explicit`, `implied`", `topic_id` "FK set null", `owner_kind` "NULL unless `kind='action_item'`; then `participant`, `mentioned`, `none`", `owner_speaker_id` "FK `meeting_speakers` set null", `owner_known_speaker_id` "FK `known_speakers` set null; only with `participant`", `owner_name` "1…80 bytes only when `owner_kind='mentioned'`; NULL otherwise", `owner_certainty` "`confirmed`, `recognized`, `local_name`, `local_user` with `participant`; NULL otherwise", `ownership_state` "`explicit`, `supported`, `unresolved`; `mentioned` ⇒ at most `supported`; `none` ⇒ `unresolved`", `due_state`, `due_date` "`YYYY-MM-DD` only when `due_state` is one of the two explicit states", `due_original` "≤ 80 bytes; required unless `absent`", `due_source_segment_id, due_source_note_ordinal` "at most one set; required unless `absent`", the CHECK "action-item columns are NULL when `kind <> 'action_item'`" and index `(run_id, kind, ordinal)`; `analysis_sources` with `target_kind` "`summary`, `topic`, `item`", `source_kind` "`segment`, `note`", `segment_id` "FK `transcript_segments` cascade; set iff `segment`", `note_ordinal` "≥ 1; set iff `note`", `note_hash` "64 hex; set iff `note`", PK `(target_kind, target_id, ordinal)`; `analysis_overlays` with `item_id` "FK `analysis_items` set null", `target_kind` "`summary`, `item`", `field` "`summary_text`, `task_text`, `decision_text`, `next_step_text`, `owner`, `due_date`, `status`", `user_value` "≤ 4,000 bytes", `ai_value_snapshot` "≤ 4,000 bytes", `item_text_snapshot` "≤ 1,000 bytes", `source_key` "≤ 1,024 bytes", `orphaned_at`, UNIQUE "`(item_id, field)` where `item_id IS NOT NULL`"; every cascade from `meetings` and `analysis_runs` as specified. Insert one `meeting_analysis` row per existing meeting
- [x] T020 Create `apps/macos/LocalFlow/Core/Storage/AnalysisStore.swift`, an actor on the shared `DatabaseQueue` implementing `AnalysisStoring` with every method of the contract, the 10-per-target source cap enforced before insert, the 500-overlay and 20-run-row capacities, the late-write refusal, and `adopt` as one transaction taking an injected overlay-matching function; make T018 pass
- [x] T021 Insert the `meeting_analysis` row in the same transaction that creates a meeting in `apps/macos/LocalFlow/Core/Storage/MeetingStore.swift`, with a case in `apps/macos/LocalFlowTests/MeetingStoreTests.swift`
- [x] T022 Extend `apps/macos/LocalFlowTests/MeetingDeletionTests.swift`: after deleting a meeting with an accepted analysis, overlays (matched and orphaned) and several run rows, all seven tables hold zero rows for that meeting and other meetings' rows are untouched (FR-052)

### Evidence, pure logic and transport

- [x] T023 [P] Create `apps/macos/LocalFlowTests/EvidenceVersionTests.swift`: fixed test vectors for `evidence_v1` (the same fixture always hashes the same 64 hex); a display-name-only rename keeps the hash; a manual reassignment, a merge through `merged_into`, an identity confirmation, a Recognized → Confirmed change, linking the local profile, a note paragraph edit, a note added, a note removed, a chunk-budget change and a language-policy change each change it; field aliasing across length prefixes is impossible (two evidence sets differing only in where a boundary falls hash differently)
- [x] T024 Create `apps/macos/LocalFlow/Core/Intelligence/EvidenceVersion.swift`: SHA-256 (`CryptoKit`) over the length-prefixed canonical stream from research R8 in that order (constant `evidence_v1`, meeting id, final `pass_id`, per final segment id + `normalized_text` + effective speaker root or `unknown`/`ambiguous`, per remote display root identity state + `known_speaker_id`, local root profile-linked flag, note paragraphs, language policy, `schema_version`, `chunking_version`, chunk budget bytes, cap-set version), computed from paged reads of ≤ 200 segments; make T023 pass
- [x] T025 Create `apps/macos/LocalFlow/Core/Intelligence/MeetingEvidenceReader.swift`: a read-only adapter over `TranscriptStore`, `SpeakerStore`, `IdentityStore` and `MeetingStore` implementing `MeetingEvidenceReading`; `segmentPage` returns final segments in ordinal pages of ≤ 200 with the effective speaker root (manual assignment over automatic, mapped through `merged_into`); `participants` applies the research R9 table (`confirmed` → name from profile; `recognized` → name from profile; `possible` → `local_name` with the typed 007 name else `possible` with no name and no candidate; `unknown`/`rejected_unknown`/no row → `local_name` if typed else `unknown`; the local root → `local_user` with the local profile name if any) and never returns a Possible-match candidate name; `notes` splits `meeting_notes.text` into paragraphs at blank lines, trims, drops empties, numbers from 1 and hashes each (SHA-256, 64 hex); it has no write method by construction
- [x] T026 [P] Create `apps/macos/LocalFlowTests/LanguagePolicyTests.swift`: the Slovak, English and mixed fixtures yield `sk`, `en`, `mixed`; a minority language at ≥ 20 % of sampled characters yields `mixed`; an unsupported language yields `mixed`; the sample never exceeds 32 KiB on the four-hour fixture and is spread across the meeting
- [x] T027 Create `apps/macos/LocalFlow/Core/Intelligence/LanguagePolicy.swift`: `detect` samples ≤ 32 KiB of final segment text spread across the meeting, runs `NLLanguageRecognizer` per sampled segment, and returns `sk`/`en`/`mixed` per research R10 plus the request value `{"output": …, "preserve_terms": true}`; make T026 pass
- [x] T028 [P] Create `apps/macos/LocalFlowTests/OverlayMatcherTests.swift`: table-driven `overlay_match_v1` cases — best source-set Jaccard ≥ 0.5 wins, ties broken by token Jaccard of normalized text, fallback to text similarity ≥ 0.8, otherwise orphaned with `orphaned_at`; each new item receives at most one overlay per field; the summary overlay always carries over; status overlays follow the same rule; a dismissed item whose match reappears stays dismissed
- [x] T029 Create `apps/macos/LocalFlow/Core/Intelligence/OverlayMatcher.swift`: pure `match(existing:newItems:)` over value types per research R13; make T028 pass; inject it into `AnalysisStore.adopt`
- [x] T030 Create `apps/macos/LocalFlow/Core/Intelligence/AnalysisClient.swift`: `URLSession` transport implementing `AnalysisTransporting` over `RewriteEndpoint`, `RewriteSettings` and `RewriteCredentialStore` (bearer from Keychain), `RewriteClient.makeConfiguration`, an ephemeral session invalidated after 60 s without an active run, an NDJSON reader that stops after 98,304 bytes with `oversized_response` and caps each line, the per-request timeout, URL-task cancellation on `Task` cancellation, `health` mapping 404 or `service != "localflow-analysis"` to `server_unavailable` with the fixed message and `result_schema_version ≠ 1` to `unsupported_version`; extend `apps/macos/LocalFlowTests/RewriteClientTests.swift` with the analysis health mappings and an assertion that every rewrite health case is unchanged
- [x] T031 Create `apps/macos/LocalFlow/Core/Intelligence/AnalysisValidator.swift` with the pipeline skeleton `validate(result, against: evidence, policy:) -> (ValidatedAnalysis, ValidationCounts)` running the steps in the contract's order (meeting, sources, identity, due dates, protected literals, support, share, duplicates, partial merge) with the meeting-id step, the duplicate rule (next steps identical to an action-item text after normalization are dropped uncounted) and the partial-merge rule (identical source sets and normalized text collapse to one) implemented now and the other steps as named stubs that pass everything through; create `apps/macos/LocalFlowTests/AnalysisValidatorTests.swift` covering `meeting_mismatch`, the duplicate rule and the merge rule

**Checkpoint**: Both sides speak the contract, the server serves health and a `full` request against the fake backend, rows persist and cascade, evidence reads and hashes deterministically. Story work can begin.

---

## Phase 3: User Story 1 - Generate a structured summary for a finished meeting (Priority: P1) 🎯 MVP

**Goal**: Generate Summary on a finalized meeting runs a `full` request through the server and shows a Summary tab with the sections that have content; evidence is untouched; automatic generation follows the on-by-default setting.

**Independent Test**: With `FakeAnalysisTransport` scripted with `deployment-valid`, the deployment fixture yields a summary mentioning the Monday deployment, one decision, three action items owned by Martin, Peter and Oliver Brunovský, and the transcript, notes and assignments are byte-identical; an unfinished transcript sends nothing.

### Tests for User Story 1

- [ ] T032 [P] [US1] Create `apps/macos/LocalFlowTests/MeetingAnalyzerTests.swift` with the core cases: a non-final transcript fails `not_eligible` and the transport records zero requests; the deployment fixture with `deployment-valid` runs `pending → running → succeeded`, stores the summary, one decision and three action items with the expected owners, and records the run identity fields (server, protocol 1, schema 1, backend, prompt versions, pipeline version, language policy, `request_config_json`); the fake evidence reader records no transcription, diarization or identification call (FR-009); the evidence rows and every 001–010 table are byte-identical before and after; the request carries the FR-029 key set and the meeting's `language_policy`
- [ ] T033 [P] [US1] Create `apps/macos/LocalFlowTests/MeetingIntelligenceCoordinatorTests.swift` with the trigger cases: `meetingTranscriptDidFinalize` enqueues an `automatic` run when `meetingSummariesAutomatic` is on and nothing when off; `requestRun(manual)` works with the setting off; a non-final meeting is refused with a `not_eligible` notice and no row; admission writes the `pending` row before `status` publishes `pending`; status values are published only after the store write succeeded; the 101st meeting id is refused with the "Summary queue is full" notice
- [ ] T034 [P] [US1] Create `apps/macos/LocalFlowTests/SummaryModelTests.swift` with the rendering cases: the stored deployment analysis loads into a read model with the summary, one decision and three action items whose participant owners resolve from the speaker record (name and color index) and never from a stored name; sections without content are absent; the not-eligible reason strings; the AI-generated label is part of the header state
- [ ] T035 [P] [US1] Extend `apps/macos/LocalFlowTests/AppPreferencesTests.swift`: `meetingSummariesAutomatic` defaults to on, persists, and does not change any existing preference's default

### Implementation for User Story 1

- [ ] T036 [US1] Create `apps/macos/LocalFlow/Core/Intelligence/MeetingAnalyzer.swift`: the run executor for the `full` path per `contracts/client-analysis.md` — eligibility (`transcription.state == .final` with `passID`, else `not_eligible` without a request), `RewriteConnectionCategory.preflight` mapping to `server_unreachable`/`authentication_failed`/`server_unavailable`, evidence version at admission, `health` with `result_schema_version` check and `limits`/`caps` minima, `LanguagePolicy.detect`, one request built from paged reads, stream consumption with progress publishing, `AnalysisProtocol` decode, `AnalysisValidator`, evidence recompute before adoption (`source_validation` with detail `evidence_changed` on drift), `store.adopt`, metrics counts on the run row; the staged path, retries and timeouts come in later stories; make T032 pass
- [ ] T037 [US1] Create `apps/macos/LocalFlow/Features/Intelligence/MeetingIntelligenceCoordinator.swift` (`@MainActor`, `@Observable`, modelled on `SpeakerIdentificationCoordinator`): deduplicated queue of meeting ids with capacity 100 and refusal notice, one running run, `admit` writes `pending` before publishing, triggers `automatic`/`manual`, `observe(meetingID) -> AnalysisStatus`, `noticePublished`, `IntelligenceObserving.meetingTranscriptDidFinalize` gated by `AppPreferences.meetingSummariesAutomatic`; make T033 pass
- [ ] T038 [P] [US1] Add `meetingSummariesAutomatic` (default on) to `apps/macos/LocalFlow/Features/Settings/AppPreferences.swift` and the "Summarize meetings automatically" toggle with the caption "Uses the server configured under Rewriting. Transcript text, confirmed speaker names and your notes are sent; audio never leaves this Mac." under Settings › Meetings in `apps/macos/LocalFlow/Features/Settings/SettingsView.swift`; extend `apps/macos/LocalFlowTests/SettingsTests.swift` for the toggle; make T035 pass
- [ ] T039 [P] [US1] Publish `meetingTranscriptDidFinalize(id:)` to the intelligence observer from `apps/macos/LocalFlow/Features/Transcripts/MeetingTranscriptionCoordinator.swift` when a final pass is adopted, with a case in `apps/macos/LocalFlowTests/MeetingTranscriptionCoordinatorTests.swift` asserting the call and that nothing else in the finalize path changed
- [ ] T040 [US1] Wire the feature in `apps/macos/LocalFlow/App/AppServices.swift`: build `AnalysisStore`, `MeetingEvidenceReader`, `AnalysisClient`, `MeetingAnalyzer` and `MeetingIntelligenceCoordinator`, register the coordinator as the intelligence observer of the transcription coordinator, and add a `--debug-seed-intelligence <deployment|fourhour|slovak|english|mixed>` debug option beside `--debug-seed-diarization` that seeds the fixture meeting (final transcript, speakers with the fixture certainties, notes) without touching the network
- [ ] T041 [US1] Create `apps/macos/LocalFlow/Features/Intelligence/SummaryModel.swift`: loads `StoredAnalysis` into `MeetingAnalysisReadModel`, resolves participant owners from `SpeakerStore.speakerSummaries` and `IdentityStore.identities` at load (name, color index via `SpeakerPalette`, certainty case), exposes the header state (not eligible with reason / eligible / pending / running / failed / succeeded), `generate()` and `cancel()` through the coordinator, and hides empty sections; make T034 pass
- [ ] T042 [US1] Create `apps/macos/LocalFlow/Features/Intelligence/SummaryTabView.swift` per `contracts/ui.md` "States": `SUMMARY` header row with Generate Summary, "No summary yet" with the reason or the eligible copy, pending/running rows with stage text and Cancel, the succeeded body (summary paragraphs, topic sections, Action items, Next steps, Decisions, Open questions, Risks / blockers — hidden when empty), the "Generated <date> · AI-generated" header and the footer "AI-generated. Check against the transcript before acting on it.", styled with `NotetakerStyle`/`SottoPalette`, with accessibility identifiers `meeting.summary`, `meeting.summary.generate`, `meeting.summary.cancel`, `meeting.summary.actionItems`, `meeting.summary.item.<kind>.<ordinal>`; the previous accepted analysis stays visible during pending/running
- [ ] T043 [US1] Replace the placeholder in `apps/macos/LocalFlow/Features/Meetings/MeetingDetailView.swift`: `NoteDetailTab.summary` titled "Summary", the tab body hosting `SummaryTabView` with a `SummaryModel` per meeting, the transcript and notes tabs unchanged; add a Summary tab capture to `apps/macos/LocalFlowTests/NativePresentationTests.swift` (empty, running, succeeded)

**Checkpoint**: Generate Summary works end to end against the fake transport and a live flowd; quickstart scenario 1 steps 1–3 and 5 pass.

---

## Phase 4: User Story 2 - Every item points back to evidence (Priority: P1)

**Goal**: Source references are validated against this meeting's segments and note paragraphs; View source lands on the segment or note; fabricated or foreign references fail the run.

**Independent Test**: `fabricated-segment` and `cross-meeting-segment` scripted responses fail with `source_validation` and the prior accepted analysis is byte-identical; View source on the note-backed decision scrolls My thoughts to paragraph 1 without attributing it to a speaker.

### Tests for User Story 2

- [ ] T044 [P] [US2] Extend `apps/macos/LocalFlowTests/AnalysisValidatorTests.swift` with the source step: a segment id absent from the final pass, a segment id from another fixture meeting, a note ordinal beyond the paragraph count, a note ordinal whose hash differs, more than 10 references on one target, and a decision/action item/next step/question/risk with zero references each fail `source_validation`; a summary with zero references or `whole_meeting: true` passes; a note-typed reference keeps `source_kind = note`
- [ ] T045 [P] [US2] Extend `apps/macos/LocalFlowTests/MeetingAnalyzerTests.swift`: with `fabricated-segment` and `cross-meeting-segment` the run fails `source_validation`, no content row is written, and a previously accepted analysis is byte-identical
- [ ] T046 [P] [US2] Extend `apps/macos/LocalFlowTests/TranscriptPagerTests.swift` (`reveal(segmentID:)` loads the page holding the ordinal when needed and publishes `highlightedSegmentID`; an unknown id publishes nothing) and `apps/macos/LocalFlowTests/MeetingNotesEditorTests.swift` (`reveal(paragraph:hash:)` selects the paragraph range when the hash matches and reports "This note has changed" when it does not)
- [ ] T047 [P] [US2] Extend `apps/macos/LocalFlowTests/SummaryModelTests.swift`: `openSource(for:)` on an item with a segment reference requests the Transcript tab and that segment id; on a note reference requests My thoughts and the ordinal/hash; a note-only item renders no speaker attribution

### Implementation for User Story 2

- [ ] T048 [US2] Implement the source step in `apps/macos/LocalFlow/Core/Intelligence/AnalysisValidator.swift` (segment ids ∈ the final pass read through `MeetingEvidenceReading`, note ordinals ∈ current paragraphs with matching hash, ≤ 10 per target, ≥ 1 for the five item kinds, summary and topics may be broad or whole-meeting) failing the run with `source_validation`; make T044 and T045 pass
- [ ] T049 [P] [US2] Add `reveal(segmentID:)` and `highlightedSegmentID` to `apps/macos/LocalFlow/Features/Transcripts/TranscriptPager.swift` and `reveal(paragraph:hash:)` with the "This note has changed" notice to `apps/macos/LocalFlow/Features/Meetings/MeetingNotesEditor.swift`; make T046 pass
- [ ] T050 [US2] Add `openSource(for:)` and note attribution rules to `apps/macos/LocalFlow/Features/Intelligence/SummaryModel.swift`, the trailing View source control (`arrow.up.right.square`) per item row in `apps/macos/LocalFlow/Features/Intelligence/SummaryTabView.swift`, and in `apps/macos/LocalFlow/Features/Meetings/MeetingDetailView.swift` the tab switch plus `ScrollViewReader` scroll to the segment or paragraph with a 2-second highlight; make T047 pass

**Checkpoint**: Quickstart scenario 1 step 4 and scenario 2's fabricated and cross-meeting cases pass.

---

## Phase 5: User Story 3 - Uncertain speakers never become confirmed owners (Priority: P1)

**Goal**: The request encodes spec 010 certainty and only permitted names; the client re-applies the named-owner rule to every result; mentioned names are free text with a local, non-binding suggestion.

**Independent Test**: The three certainty fixtures with `FakeAnalysisTransport` yield owner "Oliver Brunovský" (explicit), "Speaker N"/unresolved, and unresolved; "Tomáš Juríček" appears in no request body and no item; `named-possible-owner` is downgraded and counted.

### Tests for User Story 3

- [ ] T051 [P] [US3] Extend `apps/macos/LocalFlowTests/MeetingAnalyzerTests.swift` with the exclusion test: for every fixture meeting, the encoded request contains no Possible-match candidate name, no name for any `unknown` participant, no `known_speakers` list, no embedding, no vocabulary and no other meeting's id; a `local_name` participant on a Possible-match root carries the typed name only
- [ ] T052 [P] [US3] Extend `apps/macos/LocalFlowTests/AnalysisValidatorTests.swift` with the identity table: `participant` owners with certainty `confirmed`, `recognized`, `local_name`, `local_user` keep the owner with the certainty case; `possible` and `unknown` become `none`/`unresolved` and count `identity_downgrade`; a `mentioned` owner equal (case- and diacritic-insensitive) to a Possible-match candidate name becomes `none` and counts; a `mentioned` owner with `ownership_state == explicit` becomes `supported`; a `mentioned` name not matching any candidate is stored verbatim; the run never fails on this step
- [ ] T053 [P] [US3] Create `apps/macos/LocalFlowTests/MeetingEvidenceReaderTests.swift`: the research R9 mapping for every spec 010 state (`confirmed`, `recognized`, `possible` typed and untyped, `unknown`, `rejected_unknown`, no row, the local root with and without a local profile), the paged segment read with effective roots through manual assignment and `merged_into`, note paragraph splitting and hashing, and a compile-time assertion that the type exposes no write method
- [ ] T054 [P] [US3] Extend `apps/macos/LocalFlowTests/SummaryModelTests.swift`: the owner chip `accessibilityValue` for `confirmed participant`, `recognized participant`, `meeting participant`, `you`, `mentioned name`, `owner unresolved`; a mentioned name that equals a known speaker's display name gets a local `suggestion` and one that does not gets none; accepting the suggestion writes an owner overlay `{"kind":"participant","speaker_id":…}` and changes no `known_speakers`, `voice_samples` or `identity_assignments` row (FR-035)

### Implementation for User Story 3

- [ ] T055 [US3] Implement the identity step in `apps/macos/LocalFlow/Core/Intelligence/AnalysisValidator.swift` using `AnalysisPolicy.permittedCertainties` and the participants from `MeetingEvidenceReading`, counting `identity_downgrade` and `unresolved_owner`; make T051, T052 and T053 pass (the reader mapping is T025; fix it where the tests show gaps)
- [ ] T056 [US3] Add the owner chip to `apps/macos/LocalFlow/Features/Intelligence/SummaryTabView.swift` per the `contracts/ui.md` table (color chip + name for participants, "You" for the local user, neutral outlined chip with the "mentioned" caption and the optional "might be <name>?" suggestion with Accept, dashed neutral chip with "Speaker N" or "Owner unresolved"; identifier `meeting.summary.owner`; `accessibilityValue` per case) and the suggestion computation (Mac-side, case- and diacritic-insensitive match against known speakers' display names, never sent to the server) plus `acceptSuggestion` as an overlay write in `apps/macos/LocalFlow/Features/Intelligence/SummaryModel.swift`; make T054 pass

**Checkpoint**: SC-002 holds on the fixture set: no Possible-match or Unknown speaker is ever named, on the wire or on screen.

---

## Phase 6: User Story 4 - Conservative decisions, action items and due dates (Priority: P1)

**Goal**: Due dates are re-resolved on the Mac from the original phrase against the meeting date; vague terms stay unresolved; unassigned items survive; empty Decisions is absent.

**Independent Test**: The due-date fixture through the validator yields exactly one decision, "tomorrow" → 2026-09-21 with state `explicit_relative_resolved`, "soon" → `unresolved` with no date, and an unassigned item for the report.

### Tests for User Story 4

- [ ] T057 [P] [US4] Create `apps/macos/LocalFlowTests/DueDateResolverTests.swift`: table-driven resolution against `started_at` 2026-09-20 in `Europe/Bratislava` for `tomorrow`/`zajtra` → 2026-09-21, `the day after tomorrow`/`pozajtra` → 2026-09-22, weekday names in both languages (next occurrence, `on Friday`/`v piatok`), `next week`/`budúci týždeň` → the following Monday, absolute forms (`25 September`, `25. septembra`, `2026-09-25`, `25.9.`) → the date; every vague term (`soon`, `later`, `eventually`, `at some point`, `next time`, `čoskoro`, `neskôr`, `niekedy`, `nabudúce`, `časom`) → `unresolved`; an unknown phrase → nil (leave the server's value when consistent); a time-zone edge (a late-evening meeting) resolves in the meeting's zone, not UTC
- [ ] T058 [P] [US4] Extend `apps/macos/LocalFlowTests/AnalysisValidatorTests.swift` with the due-date step: `explicit_*` without a parseable date or without a source → `unresolved` with the original kept; a `date` on `unresolved`/`absent` is cleared; a server date that disagrees with the client resolution of a known phrase → `unresolved` with the original kept; a vague term with a server date → `unresolved`; item-level only, the run never fails
- [ ] T059 [P] [US4] Extend `apps/macos/LocalFlowTests/MeetingAnalyzerTests.swift` and `SummaryModelTests.swift`: the due-date fixture with its scripted response stores one decision, the resolved and unresolved due states, an action item with `owner_kind = none` and `ownership_state = unresolved` for the report; a fixture without decisions renders no Decisions section; rendering shows `Due 21 Sep` with the original phrase in the tooltip, `Due: unclear ("soon")`, and nothing for `absent`

### Implementation for User Story 4

- [ ] T060 [US4] Create `apps/macos/LocalFlow/Core/Intelligence/DueDateResolver.swift`: the relative-phrase table for Slovak and English, the vague-term list from `AnalysisPolicy`, absolute-date parsing in both languages, resolution against `started_at` in the meeting's `time_zone` (falling back to the capture zone), returning `explicit_absolute`, `explicit_relative_resolved`, `unresolved` or nil; make T057 pass
- [ ] T061 [US4] Implement the due-date step in `apps/macos/LocalFlow/Core/Intelligence/AnalysisValidator.swift` with `DueDateResolver`; make T058 and T059 pass, including the due-date rendering in `apps/macos/LocalFlow/Features/Intelligence/SummaryTabView.swift`
- [ ] T062 [P] [US4] Extend `server/internal/analysis/prompts/prompts_test.go` with a golden test that each template contains the full conservatism block (settled decisions only, proposals excluded, "someone needs to" → no owner, vague terms unresolved, relative dates with original phrase, empty sections stay empty) and add the due-date and deployment fixtures as offline cases to the evaluation-set manifest in `fixtures/intelligence/README.md`

**Checkpoint**: SC-005 holds on the fixture set: zero due dates from vague terms; every relative date resolves to the expected calendar date.

---

## Phase 7: User Story 5 - Protected values are never altered (Priority: P1)

**Goal**: Literals in analysis text are checked verbatim against the referenced evidence; mutated items are dropped and counted; a mutated summary or too many drops fails the run and leaves the prior analysis intact.

**Independent Test**: `mutated-ip-item` and `mutated-price-decision` drop both items, succeed, and record `dropped_literal_count = 2`; `mutated-digit-summary` fails `protected_literal` with the prior accepted analysis byte-identical.

### Tests for User Story 5

- [ ] T063 [P] [US5] Create `apps/macos/LocalFlowTests/ProtectedLiteralDetectorTests.swift`: extraction of IPv4/IPv6, URLs and dotted hostnames, e-mails, numbers with currency or unit (`1 200 €`, `$40`, `3 GB`), numeric and month-name dates in both languages, times, version strings (`1.2.3`, `v2`), digit-bearing tokens (`M6`, `PRJ-114`, `qwen3.5`), proper nouns not at sentence start and not in the Slovak/English stoplist (function words, weekdays, months); verbatim matching for numeric, address and identifier classes; the stem rule (shared prefix ≥ max(4, length − 3), diacritics preserved) accepting `Martinovi` for `Martin` and `s Odoom` for `Odoo`; participant owner names excluded from the check; a mutated digit (`172.19.223.30` → `.20`) and a mutated price both fail
- [ ] T064 [P] [US5] Extend `apps/macos/LocalFlowTests/AnalysisValidatorTests.swift` with the literal, support and share steps: an item whose literal is absent from its referenced sources is dropped and counted `dropped_literal`; a topic likewise; the summary is checked against all evidence and a mutation fails the run `protected_literal`; an item with none of its ≥ 4-character content tokens (stem rule, stopwords removed) in its referenced sources is dropped and counted `dropped_unsupported`; `dropped / returned > 1/3` fails `unsupported_content`; dropped items are absent from `ValidatedAnalysis`
- [ ] T065 [P] [US5] Extend `apps/macos/LocalFlowTests/MeetingAnalyzerTests.swift`: `mutated-ip-item` + `mutated-price-decision` succeed with two fewer items and `dropped_literal_count = 2` on the run row; `mutated-digit-summary` fails `protected_literal`, writes no content row, and the previous accepted analysis and evidence are byte-identical; the dropped items appear nowhere in the stored rows

### Implementation for User Story 5

- [ ] T066 [US5] Create `apps/macos/LocalFlow/Core/Intelligence/ProtectedLiteralDetector.swift` per research R5 (detector set, stoplist as a policy value, stem rule, owner-name exclusion, `verify(text:against:) -> [Violation]`); make T063 pass
- [ ] T067 [US5] Implement the protected-literal, lexical-support (research R6) and share steps in `apps/macos/LocalFlow/Core/Intelligence/AnalysisValidator.swift`, feeding `ValidationCounts` (`droppedLiteral`, `droppedUnsupported`) into the run row through `MeetingAnalyzer`; make T064 and T065 pass

**Checkpoint**: All five P1 stories pass on the scripted set: SC-001 (no silent partial adoption), SC-003 and SC-004 hold.

---

## Phase 8: User Story 6 - Server down, meeting untouched; retry and cancel (Priority: P2)

**Goal**: Every server, backend and response failure becomes a categorized run row with no effect on evidence or the accepted analysis; cancel, retry and timeout work; interrupted runs are reconciled at launch and restart only under FR-007a.

**Independent Test**: With the transport scripted for unreachable, malformed and late responses, three failed runs carry distinct categories, evidence is byte-identical, Retry starts a new run, Cancel during running writes `cancelled` and a late result is discarded.

### Tests for User Story 6

- [ ] T068 [P] [US6] Extend `apps/macos/LocalFlowTests/MeetingAnalyzerTests.swift` with the failure matrix: connection refused → `server_unreachable`; 401 → `authentication_failed`; 404 or wrong `service` → `server_unavailable`; `backend_unavailable`; `backend_timeout`/`backend_first_token_timeout` → `backend_timeout`; `unsupported_version`; `malformed-json` → `malformed_response`; a stream over 98,304 bytes → `oversized_response`; `wrong-meeting` → `meeting_mismatch`; `over-cap-decisions` → `over_cap`; a store `capacity` error → `persistence_capacity`; for each, no content row, the accepted analysis and evidence byte-identical, `completed_at` and `failure_category` set; the run deadline `60 s + 90 s × requests` clamped to [120 s, 30 min] fires `timed_out` with the controllable clock; `retry` reuses the same evidence version when unchanged; cancellation mid-stream cancels the transport, writes `cancelled` and a result arriving afterwards writes nothing
- [ ] T069 [P] [US6] Extend `apps/macos/LocalFlowTests/MeetingIntelligenceCoordinatorTests.swift`: `cancel` removes a queued id or cancels the running task and publishes `cancelled` after the store write; `requestRun(retry)` on a failed/timed-out/interrupted meeting starts a new run without deleting the old row; `meetingWillDelete` cancels, joins and drops the id from the queue before returning; the failed status carries the category for the UI
- [ ] T070 [P] [US6] Create `apps/macos/LocalFlowTests/IntelligenceReconcilerTests.swift` with the FR-007a matrix: every `pending`/`running` row becomes `interrupted` at launch; a row restarts (trigger `restart`, through the queue) only when its trigger was `automatic`, the meeting has no accepted analysis and the setting is on; a manual, retry or regenerate run, a meeting with an accepted analysis, or the setting off leaves it waiting for Retry; at most one restart per meeting per launch (`auto_restarted_at`); a failed restart shows Generate Summary and does not restart again this launch

### Implementation for User Story 6

- [ ] T071 [US6] Complete failure handling in `apps/macos/LocalFlow/Core/Intelligence/MeetingAnalyzer.swift`: the error-code and transport-error → category mapping from `AnalysisRun`, the run deadline (research R11) with `timeOut`, `Task` cancellation → transport cancel → `store.cancel`, the late-response guard (compare `run_id`, `current_run_id` and `running`), `retry` semantics; make T068 pass
- [ ] T072 [US6] Add `cancel(meetingID:)`, `requestRun(trigger: .retry)`, `meetingWillDelete(id:)` (cancel and join, then let `meetings` cascade) and `resume(_ restarts:)` to `apps/macos/LocalFlow/Features/Intelligence/MeetingIntelligenceCoordinator.swift`; hook `meetingWillDelete` into the confirmed-deletion chain in `apps/macos/LocalFlow/App/AppServices.swift`; make T069 pass
- [ ] T073 [US6] Create `apps/macos/LocalFlow/Core/Intelligence/IntelligenceReconciler.swift` (marks rows interrupted, selects FR-007a restarts, stamps `auto_restarted_at`) and run it in `apps/macos/LocalFlow/App/AppServices.swift` after the identification reconciler, feeding the result to `coordinator.resume`; make T070 pass
- [ ] T074 [US6] Add the failed / timed out / interrupted / cancelled header states with the fixed messages from `contracts/ui.md` ("Your server could not be reached.", "The server rejected the credential.", "The server's language model is not running.", "The server is busy with dictation. Try again in a moment.", "The summary took too long and was stopped.", "The server sent a summary LocalFlow could not read.", "The summary did not pass LocalFlow's checks and was not saved.", "This meeting is too long to summarize with the current limits.", the existing storage messages) and the Retry control (`meeting.summary.retry`) to `apps/macos/LocalFlow/Features/Intelligence/SummaryTabView.swift` and `SummaryModel.swift`; a failed analysis is never shown as a failed meeting

**Checkpoint**: Quickstart scenarios 3 and 8 pass; SC-011's failed-run half holds.

---

## Phase 9: User Story 7 - Regenerate safely; stale analysis is labelled (Priority: P2)

**Goal**: Regenerate replaces the accepted analysis only after full validation and storage; evidence changes mark the analysis stale without regenerating; a rename-only change relabels owners and is not stale; older runs finishing late are discarded.

**Independent Test**: Generate, reassign one segment → stale banner with old content; regenerate with a failing transport → old content, still stale; regenerate successfully → banner clears, old run `superseded` with no content rows.

### Tests for User Story 7

- [ ] T075 [P] [US7] Extend `apps/macos/LocalFlowTests/MeetingAnalyzerTests.swift`: `regenerate` records no transcription/diarization/identification call and reuses current evidence; a failed, cancelled or timed-out regeneration leaves the accepted analysis byte-identical; a successful one supersedes the old run, deletes its content rows and records the new evidence version; when evidence changes between admission and adoption the run fails `source_validation` (`evidence_changed`); two runs for one meeting where the older finishes last → the older result is discarded and the newer state wins (FR-011)
- [ ] T076 [P] [US7] Extend `apps/macos/LocalFlowTests/MeetingIntelligenceCoordinatorTests.swift`: `evidenceDidChange(meetingID:)` recomputes the evidence version through one paged read and flips `status.stale` when it differs; a display-name-only rename leaves `stale == false`; staleness never enqueues a run
- [ ] T077 [P] [US7] Extend `apps/macos/LocalFlowTests/SummaryModelTests.swift`: renaming Speaker 2 to "Martin" updates the owner label at the next load without a stale flag and without rewriting item prose; a stale analysis stays readable with the banner text "Summary may be outdated — the transcript, speakers or notes changed after it was generated." and Regenerate offered
- [ ] T078 [P] [US7] Extend `apps/macos/LocalFlowTests/SpeakerDiarizationCoordinatorTests.swift`, `SpeakerIdentificationCoordinatorTests.swift`, `AssignSpeakersModelTests.swift` and `MeetingNotesEditorTests.swift`: each write path (manual assignment, merge, identity confirmation/rejection, note save) calls `evidenceDidChange` exactly once with the meeting id, and a rename-only call does not

### Implementation for User Story 7

- [ ] T079 [US7] Add the `regenerate` trigger, evidence recompute before adoption and the FR-011 newest-run guard to `apps/macos/LocalFlow/Core/Intelligence/MeetingAnalyzer.swift` and `apps/macos/LocalFlow/Features/Intelligence/MeetingIntelligenceCoordinator.swift`, plus `evidenceDidChange` → stale refresh in the coordinator; make T075 and T076 pass
- [ ] T080 [P] [US7] Publish `evidenceDidChange(meetingID:)` after writes in `apps/macos/LocalFlow/Features/Speakers/SpeakerDiarizationCoordinator.swift`, `apps/macos/LocalFlow/Features/Speakers/SpeakerIdentificationCoordinator.swift`, `apps/macos/LocalFlow/Features/Speakers/AssignSpeakersModel.swift` (assignment, merge, identity changes; not display-name renames) and the notes save path in `apps/macos/LocalFlow/Features/Meetings/MeetingNotesEditor.swift`, wired through `AppServices`; make T078 pass
- [ ] T081 [US7] Add the amber stale banner (`meeting.summary.stale`), Regenerate (`meeting.summary.regenerate`) and the owner relabel on `identityRevision`/speaker changes to `apps/macos/LocalFlow/Features/Intelligence/SummaryTabView.swift` and `SummaryModel.swift`; make T077 pass

**Checkpoint**: Quickstart scenario 4 passes; SC-011 and SC-012 hold in tests.

---

## Phase 10: User Story 8 - Read, copy and navigate the Summary tab (Priority: P2)

**Goal**: The Summary tab follows the notetaker layout with a locally computed reading time, fixed section order, distinct owner styling, and a Copy that yields a plain report without identifiers or state words.

**Independent Test**: Rendering the deployment analysis shows `1 MIN READ`, the section order summary → topics → Action items → Next steps → Decisions → Open questions → Risks / blockers with empty sections absent, and the copied text contains no UUID, state word or confidence value.

### Tests for User Story 8

- [ ] T082 [P] [US8] Create `apps/macos/LocalFlowTests/ReadingTimeTests.swift`: `ceil(words / 200)` over summary, topics and items with a minimum of 1; the value is computed from rendered text and no field of the wire result is consulted
- [ ] T083 [P] [US8] Create `apps/macos/LocalFlowTests/AnalysisReportTests.swift`: the report has the title and date, "Summary", topic headings with `- ` bullets, "Action items" as `- [ ] task — Owner (due 21 Sep)` / `- [x] …` for completed, dismissed items omitted, `(owner unresolved)` for unresolved and the bare name for mentioned owners, then "Next steps", "Decisions", "Open questions", "Risks / blockers" in that order with empty sections absent, one trailing line "Generated by LocalFlow from the meeting transcript and notes."; a regex sweep finds no UUID, no `explicit`/`supported`/`unresolved`/`confirmed`/`recognized`/`possible`, no `evidence_class` value, no `note:<n>` id and no schema key
- [ ] T084 [P] [US8] Extend `apps/macos/LocalFlowTests/SummaryModelTests.swift`: section order, hidden empties, `readingMinutes`, owner chip styles (color + name; dashed neutral; mentioned caption) so color is never the only cue, `copyText()` delegates to `AnalysisReport`; extend `apps/macos/LocalFlowTests/NativePresentationTests.swift` with succeeded and stale captures in light and dark appearance

### Implementation for User Story 8

- [ ] T085 [P] [US8] Create `apps/macos/LocalFlow/Core/Intelligence/ReadingTime.swift` and `apps/macos/LocalFlow/Core/Intelligence/AnalysisReport.swift` (pure functions over `MeetingAnalysisReadModel`); make T082 and T083 pass
- [ ] T086 [US8] Complete the succeeded layout in `apps/macos/LocalFlow/Features/Intelligence/SummaryTabView.swift` per `contracts/ui.md` "Layout": `1 MIN READ` (tracked caps, `monospacedDigit`, `meeting.summary.readingTime`), summary paragraphs, topic sections, Action items rows (status control placeholder, task, owner chip, due, sources), the four lists with View source, Copy (`meeting.summary.copy`) writing `SummaryModel.copyText()` to the pasteboard, the overflow menu; make T084 pass

**Checkpoint**: SC-013 holds; the tab matches the notetaker layout in captures.

---

## Phase 11: User Story 9 - Long meetings are analyzed in bounded stages (Priority: P2)

**Goal**: Meetings over one budget are chunked along whole segments, analyzed into partials, and synthesized in bounded groups; provenance resolves to original ids; the tail is never dropped; at most one request in flight.

**Independent Test**: The four-hour fixture with scripted chunk and synthesis responses completes with the last-five-minute decision and a valid source, every request ≤ 24,576 B of segment text, and the transport never observes two concurrent requests.

### Tests for User Story 9

- [ ] T087 [P] [US9] Create `apps/macos/LocalFlowTests/AnalysisChunkPlannerTests.swift`: a meeting ≤ 24,576 B plans one `full`; a segment never straddles a boundary; every chunk ≤ budget (a single segment over budget is its own chunk and is flagged); the server's smaller `limits.input_bytes` lowers the budget and a larger one never raises it; 65 chunks → `too_long` before any request; partials group by 16 with reduce depth ≤ 2 (17 partials → two groups then one synthesis; 64 → four then one); notes go only with `full` or the final `synthesis`; 257 note paragraphs or a paragraph > 8,192 B → `too_large` with the notes named
- [ ] T088 [P] [US9] Extend `apps/macos/LocalFlowTests/MeetingAnalyzerTests.swift`: the four-hour fixture runs `chunk × n` then `synthesis`, the final analysis contains the last-five-minute decision with its original segment id, no intermediate identifier appears in stored sources, every request's segment bytes ≤ budget, `chunk_count` and `request_count` are recorded before the first request and on completion, the transport's max concurrent requests is 1, progress publishes "Analyzing part 3 of 9" and "Combining"; a `chunk` result failing source validation fails the run; partial results in memory never exceed caps × 64; the request builder never holds more than one chunk plus one page of text (assert through the fake reader's page calls)

### Implementation for User Story 9

- [ ] T089 [US9] Create `apps/macos/LocalFlow/Core/Intelligence/AnalysisChunkPlanner.swift` (`chunking_v1`: budget from `AnalysisPolicy` lowered by health limits, whole-segment chunks, the 64 cap, reduce grouping, notes placement, notes size refusal); make T087 pass
- [ ] T090 [US9] Add the staged path to `apps/macos/LocalFlow/Core/Intelligence/MeetingAnalyzer.swift`: sequential chunk requests built one page window at a time, validated partials kept as bounded Swift values, synthesis requests carrying ≤ 16 partials with up to two reduce levels, stage progress text, `chunk_count` written before the first request, in-flight limit from policy (1, max 2); make T088 pass; the server side (`partials` union source check) is already covered by T013/T016 — add a synthesis `httptest` case to `server/internal/analysis/handler_test.go` if missing

**Checkpoint**: SC-007's deterministic half holds; the live four-hour run waits for Phase 15.

---

## Phase 12: User Story 10 - Dictation stays responsive while analysis runs (Priority: P2)

**Goal**: The client honours preemption and server-busy signals with bounded retries, runs are admitted through the visible queue, and the background pill shows analysis work.

**Independent Test**: With the transport scripted to answer `preempted` twice then succeed, the run completes with `preemption_count = 2`; scripted `preempted` four times fails `backend_busy`; three meetings requested at once show one running and two queued with positions.

### Tests for User Story 10

- [ ] T091 [P] [US10] Extend `apps/macos/LocalFlowTests/MeetingAnalyzerTests.swift`: `preempted` retries the same stage after 2 s × attempt (controllable clock) up to 3 times then fails `backend_busy`; retries and preemptions are counted on the run row; `server_busy` (429) surfaces to the coordinator as a re-queue request
- [ ] T092 [P] [US10] Extend `apps/macos/LocalFlowTests/MeetingIntelligenceCoordinatorTests.swift`: three requests → one `running`, two `pending` with `queuedPosition` 1 and 2; a `server_busy` run is re-queued once after 30 s and then fails `server_unavailable`; the background-work summary reports "Summarizing…" with the queued count while a run is active and the main window is not showing that meeting
- [ ] T093 [P] [US10] Extend `server/internal/analysis/priority_test.go` with an end-to-end `httptest` case through both handlers: a rewrite issued during an analysis generation is served without waiting and the analysis stream ends with `preempted`; with `--analysis-preempt=false` the rewrite waits behind the analysis; every request carries `priority: "background"` and the rewrite path never reads it

### Implementation for User Story 10

- [ ] T094 [US10] Implement preemption retries and the `server_busy` re-queue signal in `apps/macos/LocalFlow/Core/Intelligence/MeetingAnalyzer.swift` and the single re-queue with positions in `apps/macos/LocalFlow/Features/Intelligence/MeetingIntelligenceCoordinator.swift`; make T091 and T092 pass
- [ ] T095 [US10] Show "Queued (N ahead)" in `apps/macos/LocalFlow/Features/Intelligence/SummaryTabView.swift` and add the "Summarizing…" state to `observeBackgroundWork()` in `apps/macos/LocalFlow/App/AppServices.swift` (pill in `apps/macos/LocalFlow/Features/Dictation/IndicatorPanel.swift` if a new phrase is needed); make T093 pass on the server side

**Checkpoint**: Deterministic half of SC-009 done; the latency measurement waits for Phase 15.

---

## Phase 13: User Story 11 - Edit and correct the analysis (Priority: P3)

**Goal**: Summary, task, decision and next-step text, owner, due date and status are editable as overlays stored beside the AI value, visibly marked, carried across regeneration, and never written to spec 010 tables.

**Independent Test**: Set an unresolved owner to "Tomáš Juríček" and mark an item completed; the item shows the name with "Edited", the AI value is still stored, the transcript is unchanged, and no known-speaker or voice-sample row changed; regenerate and the edits follow the matched items, an unmatched one appears under Previous edits.

### Tests for User Story 11

- [ ] T096 [P] [US11] Extend `apps/macos/LocalFlowTests/SummaryModelTests.swift`: each editable field writes one overlay with `ai_value_snapshot`, `item_text_snapshot` and `source_key`; the read model reports `edits` per field and the effective value; "Show AI value" returns the snapshot; "Remove edit" deletes the overlay and reveals the AI value; status cycles open → completed and Dismiss/Reopen; a dismissed item is omitted from `copyText()` and completed items render `[x]`; the owner menu lists participants (Possible-match and Unknown speakers by their "Speaker N" label), "Someone else…" and "No owner"; after `adopt` with the re-matcher, matched overlays follow the new items and the unmatched one is listed under `previousEdits` with its snapshots; "Remove all edits" deletes every overlay for the meeting; `known_speakers`, `voice_samples` and `identity_assignments` row counts and `updated_at` values are unchanged after every edit (FR-035)

### Implementation for User Story 11

- [ ] T097 [US11] Add the edit, status, remove-edit, remove-all and previous-edits operations to `apps/macos/LocalFlow/Features/Intelligence/SummaryModel.swift` over `AnalysisStoring.setOverlay`/`removeOverlay`/`overlays`, with `capacity` surfacing as the persistence message; make T096 pass
- [ ] T098 [US11] Add the editing UI to `apps/macos/LocalFlow/Features/Intelligence/SummaryTabView.swift` per `contracts/ui.md` "Editing": inline `TextField`/`TextEditor` on double-click or the row's Edit menu with Save/Escape, the owner menu, the due-date picker with Clear, the status control, "Edited" tags with "Show AI value" and "Remove edit", the "Previous edits" sheet (`meeting.summary.previousEdits`) with per-row Delete, and "Remove all edits" in the overflow menu; extend `apps/macos/LocalFlowTests/NativePresentationTests.swift` with an edited-item capture

**Checkpoint**: Quickstart scenario 5 passes.

---

## Phase 14: User Story 12 - Slovak, English and mixed technical meetings (Priority: P3)

**Goal**: The request carries the detected language policy, prompts instruct the model accordingly, and the evaluation set checks prose language and verbatim technical terms.

**Independent Test**: The Slovak, English and mixed fixtures produce requests with `language_policy.output` `sk`, `en`, `mixed`, and the offline evaluation reports the mixed fixture's listed terms present verbatim in its scripted result.

### Tests for User Story 12

- [ ] T099 [P] [US12] Extend `apps/macos/LocalFlowTests/MeetingAnalyzerTests.swift`: the three language fixtures send `language_policy.output` of `sk`, `en`, `mixed` with `preserve_terms: true`, and the run row stores `language_policy`; extend `server/internal/analysis/prompts/prompts_test.go` so each policy value renders its own instruction block (Slovak prose, English prose, Slovak prose with English terms kept) and the preserve-terms sentence names product names, identifiers, URLs, code and values
- [ ] T100 [P] [US12] Add the term-preservation check to the evaluation set: `fixtures/intelligence/mixed.json` lists `expected_terms` ("deployment", "backup", "M6" and the others spoken), and `scripts/analysis-quality.py` (T103) reports SC-014 as the count of fixtures whose prose language differs from `expected_language` or whose `expected_terms` are missing from the result text

### Implementation for User Story 12

- [ ] T101 [US12] Wire `LanguagePolicy` output into the request builder and run row in `apps/macos/LocalFlow/Core/Intelligence/MeetingAnalyzer.swift` (if T036 left it partial) and finish the per-policy prompt blocks in `server/internal/analysis/prompts/prompts.go`; make T099 pass

**Checkpoint**: Quickstart scenario 7's deterministic half passes; live language quality is measured in Phase 15.

---

## Phase 15: Polish, instrumentation and acceptance

**Purpose**: Content-free metrics, documentation, the evaluation script, the connection-test note, the acceptance measurements on the reference machine, and freezing the provisional values.

- [ ] T102 [P] Add phases `analysisQueued`, `analysisRequesting`, `analysisValidating`, `analysisAdopting` and the metrics `analysisRunDuration`, `analysisStageDuration`, `analysisChunkCount`, `analysisRequestCount`, `analysisRetryCount`, `analysisPreemptionCount`, `analysisInputBytes`, `analysisOutputBytes`, `analysisItemCount`, `analysisDroppedLiteralCount`, `analysisDroppedUnsupportedCount`, `analysisIdentityDowngradeCount`, `analysisUnresolvedOwnerCount`, `analysisFailure` (category), `analysisStaleCount`, `analysisOverlayOrphanCount`, `analysisQueueDepth` to `apps/macos/LocalFlow/Core/Observability/ResourceRecorder.swift`, emit them from `MeetingAnalyzer` and the coordinator, and extend the content-free test in `apps/macos/LocalFlowTests/ResourceRecorderTests.swift` to assert no transcript, note, summary, item text or speaker name reaches the recorder
- [ ] T103 [P] Create `scripts/analysis-quality.py` and `scripts/test-analysis-quality.py` modelled on `scripts/rewrite-quality.py`: offline mode replays `fixtures/intelligence/` scripted responses through the same validation rules (a Python port of the source, identity, due-date, literal and share rules is out of scope — the script drives the app's debug hook or the XCTest-exported JSON instead) and reports SC-001 to SC-006, SC-013 and SC-014 counts; live mode posts fixture requests to a running flowd; add the offline test to `scripts/test.sh`
- [ ] T104 [P] Extend the connection test in `apps/macos/LocalFlow/Features/Settings/SettingsView.swift` and its model to call `AnalysisTransporting.health` after the rewrite health and report "Meeting analysis: available (model …)" or "This server does not offer meeting analysis"; extend `apps/macos/LocalFlowTests/SettingsTests.swift`
- [ ] T105 [P] Document the analysis service, the priority gate and preemption in `docs/architecture/server.md`, and the seven tables, adoption transaction, overlay matching and evidence version in `docs/architecture/storage.md`
- [ ] T106 Run `scripts/check-intelligence-imports.sh`, `scripts/register-xcode-sources.py --check` (or the equivalent pbxproj verification), `make check` and `go test ./...` under `server/`; confirm every new Swift file is registered and every 001–010 suite is unchanged
- [ ] T107 On the reference machine with the spec 003 flowd and MTPLX backend, run quickstart scenario 6 with the four-hour seed and scenario 1 with the deployment seed; record chunk count, per-request `input_bytes`, max in flight, wall time for the ~30-minute and four-hour meetings, hardware, OS, build, flowd version, backend, model, prompt versions and policy values in `specs/011-meeting-intelligence/acceptance/throughput.md` (SC-007, SC-008); confirm MTPLX constrained decoding with the object schema and the served model's context length, and set `--analysis-context-tokens` accordingly
- [ ] T108 During a four-hour analysis on the reference machine, run the spec 003 latency script (20 short, 20 ordinary phrases) with the preemption gate on and off; record short-bucket median, ordinary p95, `preemption_count` and completion in `specs/011-meeting-intelligence/acceptance/priority.md` (SC-009)
- [ ] T109 Record idle client RSS with the feature unused, client RSS sampled every 10 s while building, sending and validating the four-hour fixture, and flowd RSS excluding the backend during the same run, using `scripts/memory-report.sh`, in `specs/011-meeting-intelligence/acceptance/memory.md` (SC-010, constitution 2 and 8)
- [ ] T110 Run `scripts/analysis-quality.py --mode live` over the evaluation set against the reference backend, review decisions and action items by hand (missed explicit items, unsupported rate ≤ 1 in 10, proposals never decisions, language and term preservation), and record SC-001 to SC-006, SC-013 and SC-014 with the dropped-item counts and stoplist notes in `specs/011-meeting-intelligence/acceptance/quality.md`; bump the prompt version and rerun if SC-006 fails
- [ ] T111 Run quickstart scenarios 3, 4, 5 and 8 on the reference machine (server down, malformed backend, timeout, cancel, stale and regenerate, edits across regeneration, quit during automatic and manual runs) and record the byte-identity checks and restart behaviour in `specs/011-meeting-intelligence/acceptance/recovery.md` (SC-011, SC-012, FR-007a)
- [ ] T112 With automatic summaries off and no run started, run the full XCTest suite, the Go tests and the spec 003 latency script against the pre-feature baseline and record the comparison and idle RSS in `specs/011-meeting-intelligence/acceptance/regression.md` (FR-051, SC-015)
- [ ] T113 Freeze the provisional values from T107–T110 in `apps/macos/LocalFlow/Core/Intelligence/AnalysisPolicy.swift` and `server/internal/analysis/limits.go`, update the "Provisional values" line in `specs/011-meeting-intelligence/plan.md` and the research R11 table to say "measured", and note any stoplist or stem-length change from T110

---

## Dependencies and execution order

- **Phase 1 → Phase 2 → stories**: T001–T003 have no code dependency (T002 feeds every test suite). Within Phase 2: T004 → T005; T006 → (T007, T008, T010) → T009; T011 → T012 → (T013, T014, T015) → T016 → T017; T006 → T018 → T019 → T020 → (T021, T022); T006 → T023 → T024; T024 → T025; T026 → T027; T028 → T029 → (folds into T020's `adopt`); T008 → T030; T006 → T031. Phase 2 is complete when T031 passes.
- **US1 (Phase 3)** needs all of Phase 2. T032–T035 first; T036 needs T024, T025, T027, T030, T031; T037 needs T036; T038 and T039 are independent; T040 needs T037–T039; T041 needs T020; T042 needs T041; T043 needs T042.
- **US2 (Phase 4)** needs US1. T044–T047 first; T048 needs T031 and T025; T049 is independent; T050 needs T048, T049, T041.
- **US3 (Phase 5)** needs US1. T051–T054 first; T055 needs T048 (validator order) and T025; T056 needs T055, T041 and the overlay store (T020).
- **US4 (Phase 6)** needs US1. T057–T059 first; T060 independent; T061 needs T060 and T055; T062 independent.
- **US5 (Phase 7)** needs US2 (references must be valid before literals are checked). T063–T065 first; T066 independent; T067 needs T066, T061.
- **US6 (Phase 8)** needs US1. T068–T070 first; T071 needs T036; T072 needs T071; T073 needs T072; T074 needs T041.
- **US7 (Phase 9)** needs US1 and US6 (cancel/late-response guards). T075–T078 first; T079 needs T071, T072; T080 independent of T079; T081 needs T079.
- **US8 (Phase 10)** needs US1; T083's status cases need US11's overlays only for the `[x]`/dismissed lines — implement them against the overlay store from T020. T082–T084 first; T085 independent; T086 needs T085, T042.
- **US9 (Phase 11)** needs US1 and US2. T087–T088 first; T089 independent; T090 needs T089, T071.
- **US10 (Phase 12)** needs US6 and US9 (stages to preempt). T091–T093 first; T094 needs T090; T095 needs T037.
- **US11 (Phase 13)** needs US7 (adoption re-match) and US8 (layout). T096 first; T097 needs T029, T041; T098 needs T097, T086.
- **US12 (Phase 14)** needs US1. T099–T100 first; T101 needs T036, T014.
- **Phase 15** needs everything; T106 before any acceptance run; T107 → T108 → T109 on the same machine session; T110 needs T103; T113 needs T107–T110.

## Parallel execution examples

- **Phase 2**: T004 and T005 together; T007, T008, T010 beside T006; T013, T014 and T015 beside each other after T012; T018, T023, T026, T028 written while T019/T020 are implemented; T030 beside T025.
- **US1**: T032, T033, T034, T035 together; then T036 while T038 and T039 proceed; T041 → T042 → T043 after T037.
- **US2**: T044–T047 together; T049 beside T048.
- **US3**: T051–T054 together; T055 → T056.
- **US4**: T057–T059 together; T060 and T062 beside each other; T061 last.
- **US5**: T063–T065 together; T066 → T067.
- **US6**: T068–T070 together; T071 → T072 → T073 while T074 proceeds.
- **US7**: T075–T078 together; T080 beside T079; T081 last.
- **US8**: T082–T084 together; T085 → T086.
- **US9**: T087 and T088 together; T089 → T090.
- **US10**: T091–T093 together; T094 and T095 beside each other.
- **Phase 15**: T102, T103, T104, T105 together; T106 alone; T107–T112 on the reference machine; T113 last.

## Implementation strategy

1. **MVP = Phase 1 + Phase 2 + US1.** Generate Summary against a live flowd for the deployment fixture, with the automatic trigger and setting. This proves the contract, the server service, storage, evidence reading and the tab before any safeguard is layered on.
2. **Finish the P1 set in order: US2, US3, US4, US5.** Each adds one validator step and its UI consequence; after US5 the scripted evaluation set holds SC-001 to SC-005 with zero violations. Do not run the live quality review before US5.
3. **US6 and US7** make the feature safe to leave on by default: categorized failures, cancel, retry, restart, regenerate and staleness. **US8** then makes the output readable and copyable.
4. **US9 and US10** unlock multi-hour meetings without regressing dictation; **US11** and **US12** complete review-and-correct and language quality.
5. **Phase 15** records every measured number. No acceptance file leaves "Unmeasured" until its run is done on the reference machine, and no provisional value is called measured until T113.

## Format validation

Every task starts with `- [ ]`, has a sequential `T###` id (T001–T113), carries `[P]` only when it touches different files from every unfinished task it could run beside, carries a `[US#]` label only in Phases 3–14, and names at least one file path.

## LocalFlow required task coverage

Lifecycle and cancellation: T018, T032, T068, T069, T075. Bounded overload: T009, T012, T016, T018 (capacities), T033 (queue), T087, T088, T092. Offline and recovery: T068, T070, T073, T111. Local instrumentation: T102, T016 (server log line). Repeatable resource acceptance: T107–T112 on the reference machine; none may be marked complete from fakes or scaffolding builds.
