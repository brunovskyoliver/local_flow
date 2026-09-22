# Implementation plan: meeting intelligence

**Branch**: `main` | **Feature identifier**: `011-meeting-intelligence` | **Date**: 2026-09-20 | **Spec**: [spec.md](spec.md)

The command was invoked as `$speckit-plan 011`. `.specify/feature.json` selects this directory and the setup script reports the identifier in its `BRANCH` field. The Git branch stays `main`, as for 007–010.

## Summary

After a meeting's final transcript is adopted, `MeetingIntelligenceCoordinator` queues an analysis run (automatically by default, or from Generate Summary). `MeetingAnalyzer` computes a name-free evidence version, reads segments in pages, detects the dominant language, and plans one `full` request or a sequence of `chunk` requests plus bounded `synthesis` requests. Each request carries only the FR-029 payload — participants with their spec 010 certainty and only permitted names, final segments with stable ids, note paragraphs with ordinals — to the user's existing flowd server, which gains a second, background-priority service (`/v1/analysis/*`) beside rewriting. flowd builds the versioned prompts, calls the same backend adapter with a real JSON schema, bounds output, validates structure and source-id existence, and yields to dictation rewrites by cancelling an in-flight generation the client then retries.

Every result is validated again on the Mac: schema version, meeting id, source references against this meeting's segments and note paragraphs, the named-owner rule from spec 010 certainty, due-date states, protected literals against the referenced evidence, lexical support, and caps. Items that fail literal or support checks are dropped and counted; a mutated summary or too many drops fails the run. Adoption is one transaction that supersedes the previous run, deletes its content, inserts the new content, re-matches user overlays by source overlap, and prunes run rows. The Summary tab renders from structured rows, resolves participant owners from the live speaker record, computes reading time locally, offers View source, inline edits stored as overlays, statuses, Copy, Regenerate, and a stale banner when the evidence version no longer matches.

Nothing here writes transcript text, audio, notes, speaker assignments, known speakers or voice samples. No model runs on the Mac. Only the structured text described in the contract leaves it, and only to the configured server.

## Language quality follow-up (2026-09-21)

Keep the configured 4B inference model. Resolve summary language in this order: explicit meeting choice; fixed language in the final pass identity when there is no override; existing bounded text detection. Only existing `sk` and `en` output choices override detection; Automatic and Czech retain the existing detection fallback. Do not consult today's global setting when summarizing an older pass. Use this same resolution for admission, staleness and the pre-adoption evidence check. Check current pass identity before adoption as well. A changed resolved language is already part of the evidence hash.

Enforce response language equality on the server and client for full, chunk and synthesis stages. This validates declared metadata, not the actual prose language. Prompt version 3 requires exact language metadata, preserves technical terms in Slovak, avoids guessing through ASR ambiguity, and retains uncertainty and task/owner/deadline associations during synthesis. Bound text sampling to valid UTF-8 prefixes without replacement characters or budget expansion.

Constitution check: no new dependency, model, schema enum, table, process or outgoing evidence field. Existing queue, sample, request, response and retry limits remain. Rejected results preserve accepted summaries. No architecture exception. Tests cover language precedence, stale/adoption races, response mismatch and UTF-8 limits. Live quality and latency remain unmeasured until the existing acceptance runs are performed.

## Technical context

| Item | Decision |
| --- | --- |
| Language/version | Client: Swift 6 language mode, macOS 14.0 target, SwiftUI/AppKit, `NaturalLanguage` for language detection, `CryptoKit` for the evidence hash. Server: Go 1.23, standard library only |
| Dependencies | None new. GRDB 7.10 (existing), URLSession, the existing flowd backend adapter promoted to `server/internal/backend` ([research R3](research.md#r3-backend-adapter-promote-rewritebackend-to-a-shared-package-with-a-real-json-schema)) |
| Storage | `history.sqlite`, migration `intelligence-v9`: `analysis_runs`, `meeting_analysis`, `analysis_summaries`, `analysis_topics`, `analysis_items`, `analysis_sources`, `analysis_overlays` ([data-model.md](data-model.md)). No blobs, no files |
| Protocol | `GET /v1/analysis/health`, `POST /v1/analysis/meeting`, NDJSON events, result `schema_version 1` ([contracts/analysis-protocol.md](contracts/analysis-protocol.md)); JSON Schemas under `protocol/schemas/`; the provisional `meeting.schema.json` and `summary.schema.json` are replaced |
| Testing | XCTest with `FakeAnalysisTransport`, `FakeAnalysisStore`, `FakeEvidenceReader`, fixture meetings and scripted responses under `fixtures/intelligence/`; Go `httptest` with the fake backend; `scripts/analysis-quality.py` for the evaluation set (offline replay in `make check`, live mode for acceptance) |
| Platform/type | One native macOS app plus the existing Go server; no new permission, no new process |
| Performance | SC-008: ~30-minute meeting ≤ 30 s warm on the reference server; SC-007: four-hour fixture completes, every request within budget, ≤ 1 in flight; SC-009: spec 003 rewrite gates hold during a long run; SC-010: idle client RSS unchanged, bounded working set for a four-hour request build. All measured in Phase 8, none assumed |
| Constraints | Every queue, page, chunk, buffer, table and cap is bounded ([contracts/client-analysis.md](contracts/client-analysis.md) "Bounds summary"; protocol "Server bounds and flags"). One run at a time; one request in flight by default. Content-free logs and metrics on both sides. Evidence, spec 010 tables and notes are read-only for this feature |
| Scope | Eligibility, automatic and manual runs, queue, cancel, retry, restart per FR-007a, staged pipeline, client and server validation, identity rule, protected literals, lexical support, adoption with overlays, stale detection, Summary tab with edits, statuses, View source, Copy, Settings toggle, health/connection test, priority gate, instrumentation, evaluation set. Not built: Ask Meeting, semantic search, exports beyond Copy, task integrations, per-note exclusion, separate summary-language override, model-judged verification, analysis history browsing |

Provisional values frozen in Phase 8: chunk budget 24,576 B, chunks ≤ 64, partials per synthesis 16 with reduce depth 2, output tokens 2,048/3,072, per-request backend timeout 120 s, run timeout 60 s + 90 s × requests within [120 s, 30 min], queue wait 30 s, preemption retries 3, dropped-item share 1/3, sources per item 10, section caps 20/40/60/40/40/40, run rows per meeting 20, overlays per meeting 500, context estimate 3 bytes per token against 32,768 tokens. The spec's clarification session left nothing open; its remaining assumptions are settled in [research.md](research.md) (R5 to R15).

## Constitution check

Pre-research gate: pass. Post-design gate: pass. No exception is proposed and no ADR is required: the feature adds a workload to the server that constitution 8 already describes, uses the structured-output rule constitution 11 already demands, and adds no client runtime. A design note for the server's second service and the preemption gate goes into `docs/architecture/server.md` rather than an ADR.

| Principles | Result |
| --- | --- |
| 1, 14: native client and scope | Pass. Swift/SwiftUI, Apple `NaturalLanguage` and `CryptoKit`; no package, no client model, no web view. One transport protocol with one implementation and one double. No job platform, no vector store, no export framework. Thin slice on 003–010 |
| 2, 6: bounded memory and streaming | Pass by design. Segments are read in 200-row pages; one chunk's text (≤ 24 KiB) plus one page is the largest duplicated text; the NDJSON reader caps lines and totals; partial results are bounded by caps × 64; the server holds one request body and one fixed-capacity output buffer and retains nothing. Queue 100 ids, one run, one request in flight. SC-010 needs measurement, pending |
| 3: model lifecycle | Not exercised on the client: no `ModelLifecycleCoordinator` lease, no runtime, no factory. The coordinator is a network job scheduler and must not touch the lifecycle owner (asserted by the import check and a coordinator test) |
| 4, 5: offline and privacy | Pass. Meetings, transcripts, notes and speakers never depend on the server; a failed run is a run row. The request contains only the FR-029 payload; Possible-match candidate names and Unknown speakers' names are excluded at construction and re-checked on the result; known speakers, samples, other meetings and vocabulary never leave. The credential stays in Keychain (reused from spec 003). Logs and metrics carry counts, sizes, categories and durations only; the debug request dump is a debug-build-only file the tester opens deliberately |
| 7, 9: persistence and recovery | Pass. One migration of new tables with cascades and CHECKs. Every run transition is written before it is published. Adoption, overlay writes and deletion are single transactions. Failed, cancelled, timed-out and interrupted runs own no content. Launch reconciliation touches rows only and restarts at most one automatic run per meeting per launch. Meeting deletion cancels and joins, then cascades |
| 8: server isolation | Pass. flowd stays Go, loads no weights, keeps the backend behind the adapter, and stays stateless per request. Analysis has its own admission slot and a rewrite-first gate; rewrite paths and limits are unchanged. Idle server RSS unaffected (nothing allocated until a request); working RSS during a four-hour run is measured in Phase 8 |
| 10: speaker attribution | Pass. Diarization and identification stay untouched; the request encodes certainty and origin; the client refuses to name any owner the rule forbids; mentioned names are never linked automatically; owner edits never write to spec 010 tables (FR-035 test) |
| 11: structured LLM output | Pass. Versioned JSON Schemas shared by both sides; the server validates before sending; the client validates before storing; rendering reads rows, never prose structure; unsupported versions are rejected; hidden reasoning is stripped or fails |
| 12: testability | Pass. Transport, store, evidence reader and clock have doubles; the Go handler has a fake backend. Tests cover every run transition, cancellation, late responses, each capacity, each failure category, restart rules, the identity table, literal and support drops, evidence-version vectors, overlay matching, deletion cascades, and byte-identity of evidence and the previous analysis |
| 13: observability | Pass by design. Content-free phases and metrics ([client-analysis.md](contracts/client-analysis.md) "Metrics"); server log line per request; acceptance files identify hardware, build, server, backend, model, prompt and policy versions |

## Project structure

```text
specs/011-meeting-intelligence/
  spec.md  plan.md  research.md  data-model.md  quickstart.md
  contracts/analysis-protocol.md  contracts/client-analysis.md  contracts/ui.md
  acceptance/                  # implementation: throughput, priority, memory, quality, recovery, regression
  tasks.md                     # next workflow; not generated by planning
protocol/
  schemas/analysis-request.schema.json, analysis-result.schema.json, analysis-event.schema.json   # new
  schemas/meeting.schema.json, summary.schema.json                                                 # removed (superseded)
  openapi.yaml, README.md                                                                          # two paths, analysis section
server/
  cmd/flowd/main.go                              # `serve` subcommand (rewrite alias), analysis flags, mux over both handlers
  internal/backend/                              # moved from internal/rewrite/backend; Input gains ResponseSchema, MaxOutputTokens
  internal/rewrite/                              # import path update only
  internal/analysis/                             # new
    protocol.go, protocol_test.go                # request/result/event types, decode with limits, validation
    handler.go, handler_test.go                  # health, meeting endpoint, slot, rewrite-first gate, preemption, repair attempt
    priority.go, priority_test.go                # shared gate between rewrite and analysis handlers
    limits.go
    prompts/prompts.go, prompts_test.go          # full, chunk, synthesis templates with versions; result schema for constrained decoding
    schema.go                                    # embedded analysis-result.schema.json + structural validator
apps/macos/LocalFlow/
  Core/IntelligenceBoundaries.swift              # new: AnalysisTransporting, AnalysisStoring, MeetingEvidenceReading, IntelligenceObserving, read models
  Core/Intelligence/                             # new
    AnalysisProtocol.swift                       # wire types, bounded decode, caps, event stream
    AnalysisClient.swift                         # URLSession transport over the rewrite endpoint and credential
    AnalysisPolicy.swift                         # policy_v1 values, permitted-certainty set, versions
    AnalysisRun.swift                            # states, triggers, failure categories, RunIdentity
    EvidenceVersion.swift                        # evidence_v1
    MeetingEvidenceReader.swift                  # read-only adapter over Transcript/Speaker/Identity/Meeting stores; note paragraphs
    LanguagePolicy.swift                         # NLLanguageRecognizer sampling
    AnalysisChunkPlanner.swift                   # chunking_v2
    ProtectedLiteralDetector.swift               # classes, stem rule, stoplist
    DueDateResolver.swift                        # relative phrase table, vague terms, resolution against started_at
    AnalysisValidator.swift                      # meeting, sources, identity, due, literals, support, share, duplicates
    OverlayMatcher.swift                         # overlay_match_v1
    MeetingAnalyzer.swift                        # run executor: eligibility, health, plan, stages, retries, adoption
    IntelligenceReconciler.swift                 # launch reconciliation, FR-007a restart selection
    ReadingTime.swift, AnalysisReport.swift      # local reading time; Copy text
  Core/Storage/
    HistoryMigrations.swift                      # intelligence-v9
    AnalysisStore.swift                          # new actor on the shared DatabaseQueue
    MeetingStore.swift                           # insert meeting_analysis with the meeting
  Core/Observability/ResourceRecorder.swift      # analysis phases and metrics
  App/AppServices.swift                          # coordinator, reconciler after identification, transcription hook, delete chain, background pill
  Features/Settings/AppPreferences.swift, SettingsView.swift   # meetingSummariesAutomatic, connection test note
  Features/Intelligence/                         # new
    MeetingIntelligenceCoordinator.swift         # queue, triggers, cancel, retry, resume, status, stale refresh
    SummaryModel.swift                           # read model assembly, owner resolution, edits, statuses, copy, navigation
    SummaryTabView.swift                         # states, sections, owner chips, previous edits sheet
  Features/Meetings/MeetingDetailView.swift      # Summary tab wiring, View source scroll, tab title
  Features/Meetings/MeetingNotesEditor.swift     # reveal(paragraph:hash:)
  Features/Transcripts/TranscriptPager.swift     # reveal(segmentID:), highlightedSegmentID
  Features/Transcripts/MeetingTranscriptionCoordinator.swift   # publish meetingTranscriptDidFinalize to intelligence
  Features/Speakers/SpeakerDiarizationCoordinator.swift, SpeakerIdentificationCoordinator.swift, AssignSpeakersModel.swift   # evidenceDidChange after writes
apps/macos/LocalFlowTests/
  Support/IntelligenceFakes.swift                # FakeAnalysisTransport, FakeAnalysisStore, FakeEvidenceReader, fixture loader
  AnalysisProtocolTests, AnalysisValidatorTests, ProtectedLiteralDetectorTests, DueDateResolverTests,
  EvidenceVersionTests, AnalysisChunkPlannerTests, LanguagePolicyTests, OverlayMatcherTests,
  AnalysisStoreTests, MeetingAnalyzerTests, MeetingIntelligenceCoordinatorTests, IntelligenceReconcilerTests,
  SummaryModelTests, AnalysisReportTests;
  extended MeetingDeletionTests, ResourceRecorderTests, SettingsTests, NativePresentationTests, RewriteClientTests (health unchanged)
fixtures/intelligence/                           # fixture meetings and scripted responses (research R17)
scripts/analysis-quality.py, test-analysis-quality.py, check-intelligence-imports.sh
docs/architecture/server.md, storage.md          # analysis service, priority gate, tables
```

Register every added source file in the Xcode project. Reuse `RewriteEndpoint`, `RewriteSettings`, `RewriteCredentialStore`, `RewriteClient.makeConfiguration`, `RewriteConnectionCategory.preflight`, `ResourceRecorder`, `TranscriptPager`, `SpeakerPalette`, `NotetakerStyle`, the meeting notice path and the confirmed-deletion chain. Do not duplicate them. `MeetingFinalizer`, `MeetingDiarizer`, `MeetingIdentifier`, the stores of 004–010 and the recording path are not modified beyond the two observer notifications named above.

## Delivery sequence

1. **Protocol and schemas.** Write the three JSON Schemas and the OpenAPI paths; remove the provisional schemas; update `protocol/README.md`. Swift `AnalysisProtocol` and Go `analysis/protocol.go` with tests for every rejection (unknown field, cap, length, enum, version, mismatch).
2. **Server.** Move the backend package; add `ResponseSchema`/`MaxOutputTokens`; rewrite tests unchanged. Add prompts, schema validator, handler with slot, rewrite-first gate, preemption and repair attempt; `serve` subcommand and flags; `httptest` coverage for each error code, the gate, preemption, output caps, source-id check, log content.
3. **Storage.** `intelligence-v9`, `AnalysisStore` with every operation, capacity refusals, atomic adoption, superseded-content deletion, overlay re-matching, pruning, cascades; `MeetingStore` insert; deletion matrix.
4. **Pure logic.** `EvidenceVersion` vectors, `AnalysisChunkPlanner`, `LanguagePolicy`, `ProtectedLiteralDetector`, `DueDateResolver`, `AnalysisValidator`, `OverlayMatcher`, `ReadingTime`, `AnalysisReport`, all table-driven against `fixtures/intelligence/`.
5. **Run pipeline.** `MeetingEvidenceReader`, `AnalysisClient`, `MeetingAnalyzer` with the fake transport: full and staged runs, every failure category with byte-identity of evidence and the previous analysis, cancellation, late response, preemption retry, evidence change mid-run, timeouts.
6. **Scheduling and recovery.** `MeetingIntelligenceCoordinator`, the finalize trigger, the setting, `IntelligenceReconciler` with the FR-007a matrix, delete hook, `AppPreferences`, background pill.
7. **UI.** `SummaryModel`, `SummaryTabView`, owner chips with accessibility values, edits and statuses, Previous edits, Copy, View source in pager and notes editor, Settings toggle, connection-test note. View-model tests and native captures.
8. **Instrumentation and acceptance.** Recorder metrics and the content-free test; `docs/architecture/*`; `scripts/analysis-quality.py`; then the reference-machine runs recorded in `acceptance/` (throughput, priority, memory, quality, recovery, regression). Freeze the provisional values. Continue through tasks, analyze and implement.

## LocalFlow constitution gates

**Bounds and overflow.** The client bounds summary and the server flag table are normative. Overflows: queue full → refused with notice; more than 64 chunks or oversized notes → `too_long`/`too_large` before any request; server slot taken → 429 and one client re-queue; response over 96 KiB → `oversized_response`; items over caps → `over_cap`, nothing adopted; overlays over 500 or run rows at capacity → `persistence_capacity`. Nothing is dropped silently; every drop is a counted category.

**Lifecycle owner and release.** No model on the client. The transport session is ephemeral and invalidated when no run is active for 60 s, as rewrite does. The server allocates per request and retains nothing.

**Offline and privacy.** Generation needs the server; everything else in the meeting does not. The request builder is the only code that serializes evidence, it has a test asserting the exact key set of the payload, and a second test asserting that no Possible-match candidate name, Unknown name, known-speaker list, embedding or other-meeting id can appear for the fixture meetings. Credentials via Keychain. Logs and metrics content-free on both sides.

**Recovery and persistence.** Every transition is persisted before it is published. Adoption, overlay writes and deletion are single transactions. Launch reconciliation marks pending/running rows interrupted and returns FR-007a restarts; queued-but-unpersisted state does not exist because admission writes the row. Meeting deletion cancels and joins the active run, drops the id from the queue and cascades.

**Dependencies and licences.** No new package, model, manifest or licence on either side.

**Memory acceptance.** Reference machine: idle RSS with the feature unused; client RSS sampled every 10 s while building, sending and validating the four-hour fixture; server RSS (excluding the backend) during the same run; recorded in `acceptance/memory.md` with hardware, OS, build, flowd version, backend, model and policy values. Unmeasured until recorded.

**Test strategy.** Deterministic XCTest and Go tests with doubles cover every requirement below; the scripted evaluation set runs in `make check`; the live backend is used only in acceptance. The Feature 001–010 suites with the setting off and no run started are the FR-051/SC-015 regression gate.

## Validation and requirement coverage

| Requirements | Primary validation |
| --- | --- |
| FR-001, FR-002, FR-007a; US1 scenario 3 | `MeetingAnalyzerTests` eligibility (no request sent), coordinator trigger and setting tests, `IntelligenceReconcilerTests` restart matrix |
| FR-003, FR-004, FR-005, FR-011a; SC-011 | `AnalysisStoreTests` transitions, run-row fields, supersede-and-delete, prune; byte-identity assertions in `MeetingAnalyzerTests` |
| FR-006, FR-007, FR-008, FR-011 | Cancel, retry, timeout and late-response tests in analyzer and coordinator suites |
| FR-009 | Analyzer test: no call into transcription, diarization or identification (fakes record calls) |
| FR-010, FR-024, FR-024a, FR-027, FR-028; SC-001, SC-003, SC-004 | `AnalysisValidatorTests`, `ProtectedLiteralDetectorTests`, `AnalysisProtocolTests`; Go `protocol_test`/`handler_test`; offline evaluation set |
| FR-012 to FR-015, FR-014a; SC-002 | Request-builder key-set and exclusion tests; validator identity table; three-certainty fixture; mentioned-name suggestion test |
| FR-016 to FR-022; SC-005, SC-006 | `DueDateResolverTests`; prompt tests (rules present, versions reported); evaluation set with human review recorded in `acceptance/quality.md` |
| FR-023, FR-025, FR-026 | Validator minimum-reference rule; `SummaryModelTests` note attribution; pager/notes reveal tests |
| FR-029, FR-049 | Payload key-set test; import check script; no networking outside `AnalysisClient` in `Core/Intelligence` |
| FR-030, FR-031, FR-031a; SC-012 | `EvidenceVersionTests` vectors; coordinator stale refresh; `SummaryModelTests` rename-only relabel |
| FR-032 to FR-035 | `AnalysisStoreTests` overlays; `OverlayMatcherTests`; `SummaryModelTests` edit paths; spec 010 tables unchanged assertion |
| FR-036; SC-014 | `LanguagePolicyTests`; language fixtures in the evaluation set |
| FR-037 to FR-041; SC-013 | `SummaryModelTests` (section order, hidden empties, reading time), `AnalysisReportTests` (no ids/states), native captures, accessibility values |
| FR-042, FR-043, FR-046, FR-047 | Go handler tests; no inference symbols in the client (import check) |
| FR-044, FR-045; SC-007 | `AnalysisChunkPlannerTests` (whole segments, budgets, 64-cap, reduce depth); analyzer in-flight assertion; four-hour fixture in `acceptance/throughput.md` |
| FR-048; SC-009 | `priority_test.go` (gate and preemption); `acceptance/priority.md` |
| FR-050 | `ResourceRecorderTests` content-free extension; server log test |
| FR-051; SC-015 | Full existing suites with the setting off; `acceptance/regression.md` |
| FR-052 | `MeetingDeletionTests` zero rows across the seven tables |
| SC-008, SC-010 | `acceptance/throughput.md`, `acceptance/memory.md` |

## Risks

- **Small models and structured extraction.** A 4B–9B model may over-extract or mis-resolve dates even with the conservative prompt. Mitigation: constrained decoding where supported, client-side date re-resolution, lexical support and literal checks, human review on the evaluation set (SC-006); if the miss/false rate fails, the prompt version bumps and the evaluation reruns before release.
- **Preemption cost.** Each rewrite during a long run discards one chunk generation. Mitigation: retries are bounded and counted; chunk budgets are configurable; the gate can be turned off for batching backends. Measured in `acceptance/priority.md`.
- **Proper-noun false drops in Slovak.** The stem rule may still drop items with short inflected names. Mitigation: counted per run, visible in the evaluation report; the stoplist and stem length are policy values.
- **Context length unknown for the served model.** `--analysis-context-tokens` defaults to 32k; a smaller real context surfaces as `backend_error`/truncation. Mitigation: health advertises limits; acceptance sets the flag from the measured model; the client lowers its budget to the server's.
- **Notes paragraph drift.** A note edit invalidates note references by design (stale). Mitigation: View source verifies the hash and explains.
- **Rewrite protocol regression** from moving the backend package. Mitigation: the move is import-path-only; the rewrite Go tests and the Swift rewrite suites are the gate.

## Complexity tracking

No constitution violations to justify.
