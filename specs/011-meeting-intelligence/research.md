# Research: meeting intelligence

Phase 0 output for [plan.md](plan.md). Each entry resolves one unknown left by the spec ("set in planning") or one design choice with alternatives. Numeric defaults are provisional until the acceptance runs in Phase 8 of the plan record measured values; nothing here is represented as measured.

## R1. Where the work runs: client-orchestrated stages, stateless server requests

**Decision.** The Mac client owns the run: it decides eligibility, computes the evidence version, reads evidence in pages, plans chunks, issues one bounded request per stage to flowd, validates every response, and adopts the result in one transaction. flowd owns prompts, backend adaptation, output bounding, structural validation and the workload priority gate. Every server request is self-contained: a `full` request (the whole meeting fits one budget), a `chunk` request (one slice of the meeting), or a `synthesis` request (partial results in, final analysis out). The server keeps no per-run state and no intermediate artifacts.

**Rationale.** FR-042/043 put prompts and backend behind the server; FR-044/045 need chunking along whole transcript segments, per-request budgets and a bounded number of requests in flight, which the client can only guarantee if it issues the requests. Constitution 8 (idle server RSS 100 MB, no queue infrastructure) argues against server-side job state. The client already has the evidence, the segment identifiers and the speaker certainty; the server would otherwise need all of it plus a job table. US9's acceptance ("no single request exceeded the budget, never more than N in flight") is a client-side property.

**Alternatives.** Server-side job with polling: adds a job table, a second admission queue and recovery logic on the server for no functional gain; rejected by constitution 8 and 14. One giant request with server-side chunking: the server would hold the whole meeting text and every partial result in memory for minutes; rejected by constitution 2 and 6.

## R2. Protocol shape: a second NDJSON service on the same flowd listener

**Decision.** flowd gains `GET /v1/analysis/health` and `POST /v1/analysis/meeting`, served by a new `server/internal/analysis` package on the same listener as `/v1/rewrite`. `flowd serve` starts both services; `flowd rewrite` stays as an alias so existing launchd plists keep working. The response is `application/x-ndjson` with the same event vocabulary as rewrite (`accepted`, `progress`, `result`, `error`), so the client keeps one streaming reader pattern and the server one write path with per-write deadlines. The result line carries a versioned `analysis` object (`schema_version: 1`), server, protocol, prompt, pipeline and backend identity, and timing. Requests carry `priority: "background"` and a `stage`.

**Rationale.** Rewrite's NDJSON stream already solved keep-alive, progress, bounded lines and identity fields (spec 003 contract). Reusing it means no new transport concepts and one health/connection-test path. A separate path prefix keeps the rewrite protocol at version 1 byte-for-byte (FR-051).

**Alternatives.** Plain JSON response: a 60-second generation with no bytes on the wire trips proxies and gives no progress; rejected. gRPC or WebSockets: new dependency and client machinery for one endpoint; rejected by constitution 14.

## R3. Backend adapter: promote `rewrite/backend` to a shared package with a real JSON schema

**Decision.** Move `server/internal/rewrite/backend` to `server/internal/backend` (same package name, `git mv`), and extend `Input` with `ResponseSchema map[string]any` and `MaxOutputTokens int`. Rewrite keeps passing its `{"type":"string"}` schema; analysis passes the versioned analysis result schema when the probe advertises `capabilities.json_schema`, and otherwise relies on the prompt plus server-side validation. `Generate` gains no other behavior; the rewrite handler tests must pass unchanged.

**Rationale.** FR-042 forbids a second inference path; the existing adapter already handles streaming, output caps, first-token and total timeouts, cancellation causes and identity bounding. Constrained decoding against the real schema is the cheapest way to raise structural validity on a 4B–9B model; server-side validation stays mandatory either way (constitution 11).

**Alternatives.** Copy the adapter into the analysis package: two divergent copies of timeout and SSE parsing; rejected. Keep the adapter under `rewrite/` and import it from `analysis/`: works but names the dependency wrongly; the move is a rename with no behavior change.

## R4. Priority: separate admission slots, rewrite-first gate, cancel-and-retry preemption

**Decision.** flowd keeps its two rewrite slots untouched and adds one analysis slot (`--analysis-concurrency`, default 1). An analysis request holding the slot waits (bounded by `--analysis-queue-wait`, default 30 s) while any rewrite is in flight before calling the backend. If a rewrite arrives while an analysis backend call is running, the server cancels that backend call with cause `preempted`, sends `error {code: "preempted"}`, and the client retries the same stage after a short delay, at most `preemptionRetries` (default 3) times per stage before the run fails `backend_busy`. Preemptions are counted in metrics on both sides. The gate is a server flag (`--analysis-preempt`, default on) so it can be turned off for backends that batch requests well.

**Rationale.** The reference backend is MTPLX (MLX) which, like most single-model Apple Silicon servers, serializes generation; an in-flight chunk generation of 30–60 s would otherwise sit in front of every rewrite and break SC-009 (short-bucket median ≤ 1.5 s). Cancelling the backend request frees the backend within one token. The lost work is one chunk, and chunk requests are idempotent by construction (R1). This mirrors how speech workloads preempt diarization and identification on the client.

**Alternatives.** Rely on backend batching: unmeasured for MTPLX and wrong for llama.cpp's default single-slot; SC-009 would be luck. Smaller chunks only: reduces but does not bound the wait. Server-side queue that pauses between chunks: cannot interrupt a generation already started, so the worst case stays one full chunk.

## R5. Protected-literal validation on the client (and existence checks on both sides)

**Decision.** `ProtectedLiteralDetector` (Swift, `Core/Intelligence`) extracts protected literals from every analysis text with deterministic detectors: IPv4/IPv6 addresses, URLs and hostnames with a dot, e-mail addresses, numbers with currency or unit, dates (numeric and month-name forms, Slovak and English), times, version strings (`1.2.3`, `v2`), tokens containing a digit (`M6`, `PRJ-114`, `qwen3.5`), and proper nouns (capitalized tokens not at sentence start and not in a stoplist of Slovak/English function words, weekdays and months). Numeric, address and identifier classes must appear verbatim in the item's referenced sources (for the executive summary and topic summaries: anywhere in the meeting evidence). Proper nouns use a stem comparison (shared prefix ≥ max(4, length − 3) characters, diacritics preserved) so Slovak inflection ("Martinovi", "s Odoom") does not drop valid items. Participant owner names are excluded because they are rendered from the speaker record, not from model text. The server performs the cheap part independently: every `source_ref` id must exist in the request it just received, or the result fails `source_validation` before it is sent.

**Rationale.** FR-027 lists the classes; a regex set covers all of them except company/product names, for which capitalization is the only content-free signal available on device. A stem rule trades a small miss rate on very short inflected names for far fewer false drops in Slovak. Item-level drops are counted (FR-024a, FR-050) so the acceptance run can tune the stoplist.

**Alternatives.** Reuse the rewrite `shield` detectors server-side: they mark spans for placeholder substitution, not for verification against separate evidence, and the server does not hold the evidence for `synthesis` requests. A second model call to verify: doubles latency and is itself unverified; deferred.

## R6. "Unsupported by evidence" check: lexical support, no second model call

**Decision.** An item is judged unsupported when none of its content tokens (≥ 4 characters after lowercasing, stopwords removed, stem prefix as in R5) occurs in the concatenated text of its referenced sources. Unsupported items are dropped and counted like protected-literal failures (FR-024a). The check is deliberately lenient; its job is to catch items whose references are real but unrelated.

**Rationale.** FR-024a names the consequence but not the judge. A deterministic lexical rule is testable, content-free in metrics and cheap on a 4-hour meeting. Human review on the evaluation set (SC-006) remains the quality gate.

**Alternatives.** Model-judged verification: cost and circularity, deferred to a later feature. Embedding similarity: would need a client model; prohibited by constitution 1.

## R7. Manual-note identifiers: deterministic paragraphs of the notes document

**Decision.** `meeting_notes` is one text per meeting. The request splits it into paragraphs at blank lines (a lone line is its own paragraph), trims, drops empties, and identifies each as `note:<ordinal>` with `ordinal` starting at 1 in document order. Note references carry `kind: "note"` and the ordinal; the evidence version covers the paragraph list, so any note edit makes the analysis stale (FR-031). View source scrolls the My thoughts editor to the paragraph with that ordinal in the current text and highlights it; if the paragraph no longer exists the control says "This note has changed" and the stale banner already explains why.

**Rationale.** Spec 004 chose one document, not a list, and this feature must not change it (boundary). Ordinals are stable for the lifetime of one evidence version, which is exactly the lifetime of one accepted analysis. Storing a per-paragraph hash beside the ordinal lets View source verify the match.

**Alternatives.** Add a `note_paragraphs` table: alters spec 004 semantics and doubles the notes write path; rejected. Reference by character offset: breaks on the first edit and is unreadable in the transcript of the request.

## R8. Evidence version: SHA-256 over a canonical, name-free evidence stream

**Decision.** `EvidenceVersion.compute` hashes, in this order, with length prefixes so fields cannot alias: the constant `evidence_v1`; the meeting id; the final `pass_id`; for every final segment in ordinal order: id, `normalized_text`, the effective speaker root id or `unknown`/`ambiguous` (manual assignment wins over automatic, mapped through `merged_into`); for every remote display root in id order: identity state and `known_speaker_id` if any (never the display name); for the local root: whether a local profile is linked; every note paragraph in order (ordinal, text); and the request configuration: language policy, `schema_version`, `chunking_version`, chunk budget bytes, and the cap set version. The result is 64 lowercase hex characters stored on the run. Staleness is `stored != current`, computed on demand (Summary tab open, after any 007/010 write, after a notes save) by one paged read that never holds more than 200 segments.

**Rationale.** FR-030 lists exactly these inputs and excludes timestamps and display names; FR-031a follows from leaving names out. Segments are never edited in place today (`transcript_segments` final rows are immutable), so "segment text corrected" is covered by hashing `normalized_text` without any hook; a future editing feature inherits the rule.

**Alternatives.** Revision counters on each table: `meeting_speakers` renames bump revisions and would mark rename-only changes stale, which FR-031a forbids. Timestamps: forbidden by FR-030.

## R9. Speaker certainty in the request and the named-owner rule

**Decision.** Participants are the display roots of the accepted diarization run plus manual speaker rows, each with: `speaker_id` (meeting-local root id), `certainty` ∈ {`confirmed`, `recognized`, `possible`, `unknown`, `local_name`, `local_user`}, `origin` (010 `IdentityOrigin` raw value or `none`), `known_speaker_id` when the certainty is `confirmed` or `recognized`, and `name` only when naming is permitted. Mapping from spec 010 state to certainty: `confirmed` → `confirmed` (name = profile display name), `recognized` → `recognized` (name = profile display name), `possible` → `local_name` if the root has a typed 007 display name, otherwise `possible` with no name and no candidate; `unknown`, `rejected_unknown` or no row → `local_name` if typed, otherwise `unknown` with no name. The local ("You") root is `local_user`, with the local profile's name when spec 010 has one and no name otherwise; the prompt tells the model it is the meeting owner and the client renders it as "You". The client re-applies the same table to every owner in the response: an owner whose `speaker_id` is not in the permitted set (`confirmed`, `recognized`, `local_name`, `local_user`) becomes `none` and is counted `identityDowngrade`. A mentioned-name owner equal (case- and diacritic-insensitive) to any Possible-match candidate name of this meeting is also downgraded (FR-014a last sentence).

**Rationale.** FR-012 to FR-015 and the clarification on Recognized and typed names. A typed name on a Possible-match root is the user's own label, not the candidate's; sending it is safe and the candidate name still never leaves the Mac. The permitted set is a value in `AnalysisPolicy` and part of the evidence version, so a later change to the rule regenerates rather than reinterprets.

**Alternatives.** Sending the Possible-match candidate with a flag and trusting the prompt: forbidden by FR-013. Naming nobody but Confirmed: rejected in clarification.

## R10. Language policy: on-device dominant-language detection

**Decision.** The 2026-09-21 follow-up reuses the meeting-language selection introduced by Feature 009. Explicit Slovak or English wins; without a per-meeting override, use a fixed supported language recorded in the final pass identity. Otherwise `LanguagePolicy.detect` samples up to 32 KiB of final segment text spread across the meeting, runs `NLLanguageRecognizer` on each sampled segment, and yields `sk`, `en` or `mixed` (`mixed` when no supported language reaches 80% of sampled characters). Samples end at valid UTF-8 boundaries. Automatic and Czech choices keep text detection; this follow-up does not add Czech to the summary schema. The request carries `language_policy: {"output": "sk"|"en"|"mixed", "preserve_terms": true}`. `mixed` instructs Slovak prose with English technical terms kept.

**Rationale.** FR-036 requires an explicit policy. The transcript pass now records its selected language; using that evidence avoids a second guess driven by technical vocabulary. The same resolver handles admission, staleness and pre-adoption validation. Today's global setting must not reinterpret an older pass. `NaturalLanguage` remains the bounded, offline fallback.

**Alternatives.** Asking the model to choose or adding a separate summary-language setting is unnecessary. The existing meeting picker supplies the override. Declared response language is checked on both sides, while actual prose language and meaning still require live evaluation.

## R11. Chunking, budgets and stage bounds (provisional defaults)

**Decision.** `AnalysisChunkPlanner` (`chunking_v2`) walks final segments in ordinal order and closes a chunk when it reaches a balanced target (the remaining bytes over the fewest chunks that fit the budget, at least two) or when the next segment would exceed the budget, so no near-empty tail request remains; a segment never straddles a boundary (FR-044). Every chunk repeats the participant table and meeting header. Notes go only with the `synthesis` request, or with the single `full` request. Defaults (all configurable through `AnalysisPolicy`, overridden downward by the server's advertised limits):

| Bound | Default | Where enforced |
| --- | --- | --- |
| `full` request when total segment bytes ≤ | 12,288 B | client |
| chunk budget (segment text bytes) | 16,384 B (balanced, so typical chunks land lower) | client; server refuses `input_too_large` above `--analysis-input-bytes` (98,304). Sized so a dense-tokenizing language's prompt plus the output reservation fit the backend's real KV pool — advertised context is 32,768 but the paged pool runs 16–29k under memory pressure (2026-09-21: a 24 KB Slovak chunk needed ~21k prompt tokens and left no room to decode; 2026-09-22 measured on Qwen3.5 4B: Slovak with the request envelope runs ≈ 1.2 B/token — 12 KB ≈ 12.1k, 16 KB ≈ 15.2k, 20 KB ≈ 18.0k prompt tokens, system prompt 1.8k) |
| request body cap | 262,144 B | both (413 `too_large`) |
| chunks per run | 64 | client; beyond it the run fails `too_long` (a 4-hour meeting is ~17 chunks at ~200 KB of text) |
| partial results per synthesis request | 16, then a second reduce level (max 2 levels, 64 partials) | client |
| requests in flight per run | 1 (max 2) | client |
| runs across meetings | 1 running, queue capacity 100 | client coordinator |
| result line bytes | 98,304 B | both (`output_too_large`) |
| backend output tokens | 3,072 chunk, 10,240 synthesis/full | server `--analysis-output-tokens-chunk`/`--analysis-output-tokens`; chunk partials measured ~1–2k tokens (2026-09-22), the cap bounds a runaway decode; a `finish_reason=length` stream is validated like any output and fails `output_invalid` (2026-09-21) |
| per item source references | 10 | both |
| per section, final result | topics 20, decisions 40, action items 60, next steps 40, open questions 40, risks 40 | both |
| per section, partial result | half of the above | both |
| text lengths | summary 4,000 B; topic summary 2,000 B; item text 1,000 B; owner name 80 B; due original 80 B | both |
| dropped-item share that fails the run | > 1/3 of returned items | client |
| run timeout | 60 s + 300 s × (chunks + reduce requests), floor 120 s, ceiling 30 min | client |
| per-request backend timeout | 300 s total, 60 s first token (2026-09-21: a ~10k-token chunk took 9.8 s to its first token on a 4B model, sustained profile, with nothing else running) | server `--analysis-timeout`, `--analysis-first-token-timeout` |
| server queue wait for the rewrite-first gate | 30 s | server |
| preemption retries per stage | 3 | client |
| run records per meeting | 20 (oldest non-accepted pruned first) | store |

`--analysis-context-tokens` (default 32,768) lets the server model the backend context: it refuses a request whose estimated tokens (bytes ÷ 3 for Slovak, a conservative ratio) plus instructions, schema and output reservation exceed the context, with `input_too_large` (FR-046). Limits and versions are advertised in `/v1/analysis/health` so the client can shrink its budget without a release.

**Rationale.** The 4B–9B reference models handle ~6k input tokens per call with acceptable latency; larger chunks raise both latency and the preemption cost in R4. Two reduce levels cover 64 chunks × 16 without ever concatenating partial results beyond one budget. All numbers are placeholders until `acceptance/throughput.md` records the reference run (SC-007, SC-008).

**Alternatives.** Token-exact budgeting with a tokenizer on the client: adds a dependency for a bound the server enforces anyway. Overlapping chunks: better continuity but double-counted items; rejected in favor of synthesis-time deduplication by source overlap.

## R12. Storage: normalized tables in `history.sqlite`, migration `intelligence-v9`

**Decision.** Seven tables ([data-model.md](data-model.md)): `analysis_runs` (every attempt; content-free), `meeting_analysis` (one pointer row per meeting: accepted run, current run, evidence version, counters), `analysis_summaries` (one per accepted run), `analysis_topics`, `analysis_items` (decisions, action items, next steps, open questions, risks, distinguished by `kind`, with action-item columns constrained by CHECK), `analysis_sources` (item or summary → segment or note), `analysis_overlays` (user edits and statuses, matched or orphaned). Adoption deletes the previous accepted content and inserts the new content in one transaction; run rows persist. No JSON blob holds the analysis; a bounded `request_config_json` (≤ 2 KiB) on the run row records the policy for audit.

**Rationale.** Constitution 7 and the spec's assumption ("normalized tables preferred"). One `analysis_items` table with a `kind` column is normalized and keeps source references and overlays in one shape; separate tables per kind would repeat every column and every cascade.

**Alternatives.** One JSON document per analysis: rejected by the spec and by the need to edit and match individual items.

## R13. Overlay matching on regeneration (`overlay_match_v1`)

**Decision.** For each existing overlay (keyed by item kind, the sorted set of its item's source ids, and a normalized text snapshot), find candidate new items of the same kind; score = Jaccard overlap of source-id sets; take the best candidate with overlap ≥ 0.5, tie broken by normalized-text similarity (token Jaccard). If none, take the best candidate with text similarity ≥ 0.8. Otherwise the overlay becomes orphaned (`item_id NULL`, `orphaned_at` set) and appears under "Previous edits" with its AI snapshot and user value. Each new item receives at most one overlay per field. The summary overlay always carries over (there is exactly one summary). Status overlays follow the same rule as edits. Removing an overlay reveals the AI value; removing an orphaned overlay deletes it.

**Rationale.** FR-034 asks for source overlap first, text similarity second, and a visible list for the rest.

**Alternatives.** Item ids assigned by the model: not stable across runs. Position-based matching: meaningless after regeneration.

## R14. Run lifecycle, queue and restart

**Decision.** `MeetingIntelligenceCoordinator` (main actor, `@Observable`) mirrors `SpeakerIdentificationCoordinator`: one deduplicated queue of meeting ids (capacity 100, refusal notice when full), one run at a time, admission writes the `pending` row so the database and queue agree, `cancel` removes the queued id or cancels the active task and writes `cancelled`, and `meetingWillDelete` cancels and joins before the cascade. Triggers: `automatic` from `MeetingTranscriptionCoordinator` when a final pass is adopted and `AppPreferences.meetingSummariesAutomatic` is on; `manual` from Generate Summary; `retry`; `regenerate`; `restart` for FR-007a. `IntelligenceReconciler` runs at launch after the identification reconciler: every `pending`/`running` row becomes `interrupted`; rows whose trigger was `automatic`, whose meeting has no accepted analysis and while the setting is on are returned for `resume`, at most one per meeting per launch. A late response is discarded when the run is no longer `meeting_analysis.current_run_id` or its state is not `running` (FR-006, FR-011).

**Rationale.** The spec's FR-002 to FR-011 and FR-007a; the existing coordinators already prove the pattern under the constitution's recovery rules.

**Alternatives.** Persisting the queue order: the spec says queued runs become interrupted on restart; pending rows are the persisted form.

## R15. Summary tab rendering, reading time and copy

**Decision.** `SummaryModel` loads the accepted analysis into a read model whose participant owners are resolved at load and on every `identityRevision`/speaker-structure change from the current speaker record (name, color index, certainty case). Reading time is `ceil(words / 200)` minutes over the rendered text (summary, topics, items), minimum 1, computed on the Mac (FR-038). Copy builds a plain report: title, date, "Summary", topic headings with bullets, "Action items", "Next steps", "Decisions", "Open questions", "Risks / blockers", action items as `- [ ] task — owner (due date)` with `[x]` for completed and dismissed items omitted; no ids, states or confidence values. AI content sits under an "AI-generated summary" header row with a stale banner "Summary may be outdated" when the evidence version differs. Owners render with the speaker color chip plus name; unresolved owners render a neutral outlined chip with "Speaker N" or "Owner unresolved"; mentioned-name owners render a neutral chip with the name and no color or link; `accessibilityValue` exposes `confirmed`, `recognized`, `meeting name`, `mentioned name` or `unresolved` (FR-014, FR-014a, FR-039).

**Rationale.** FR-037 to FR-041 and US8; the layout reuses `NotetakerStyle` and the existing Summary placeholder in `MeetingDetailView`.

**Alternatives.** Rendering Markdown from the model's prose: forbidden by FR-028.

## R16. Reference-server behavior to confirm in acceptance

Not decisions; measurements the plan schedules (Phase 8):

- MTPLX constrained decoding with an object schema (the rewrite probe only proved a string schema).
- Backend context length for the served model, to set `--analysis-context-tokens`.
- Chunk latency at the default budget and output cap (SC-008).
- Rewrite latency with the preemption gate on and off (SC-009).
- Server RSS during a 4-hour-meeting run, excluding the backend (constitution 8).
- Client RSS while building and validating a 4-hour meeting (SC-010).

## R17. Evaluation set

**Decision.** `fixtures/intelligence/` holds fixture meetings as JSON (segments with ids, speaker certainties, notes) and scripted server responses, covering: the four-line deployment meeting; the three certainty variants of "I'll call the customer"; the due-date fixture (2026-09-20 meeting with "tomorrow", "soon", "someone needs to"); protected-literal mutations (IP in an item, price in a decision, digit in the summary); fabricated and cross-meeting references; over-cap item counts; a Slovak, an English and a mixed technical meeting; a synthetic four-hour meeting with a unique last-five-minute decision. `scripts/analysis-quality.py` replays them against a running flowd (live mode) or against the scripted responses (offline mode) and reports the SC-001 to SC-006, SC-013 and SC-014 counts. The XCTest suite uses the same fixtures with `FakeAnalysisTransport`.

**Rationale.** SC-001 to SC-006 need a fixed corpus; the rewrite quality script (`scripts/rewrite-quality.py`) is the pattern.
