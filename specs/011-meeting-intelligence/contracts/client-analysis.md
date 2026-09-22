# Client analysis pipeline contract

The Mac side of Feature 011: `Core/IntelligenceBoundaries.swift` (protocols and value types), `Core/Intelligence/` (pure logic and the run executor), `Core/Storage/AnalysisStore.swift`, and `Features/Intelligence/MeetingIntelligenceCoordinator.swift`. Nothing under `Core/Intelligence` imports FluidAudio, whisper or any model runtime (`scripts/check-intelligence-imports.sh`).

## Boundaries

```swift
protocol AnalysisTransporting: Sendable {
  func analyze(request: AnalysisRequest, endpoint: RewriteEndpoint, timeout: Duration)
    -> AsyncThrowingStream<AnalysisTransportItem, Error>   // firstByte, event(AnalysisEvent), completed(bytes)
  func health(endpoint: RewriteEndpoint) async throws -> AnalysisHealth
  func invalidate()
}

protocol AnalysisStoring: Sendable {
  func analysis(meetingID: UUID) async throws -> MeetingAnalysisPointer?
  func admit(meetingID: UUID, trigger: AnalysisTrigger, evidence: EvidenceVersion, passID: UUID, policy: AnalysisPolicy, now: Int64) async throws -> AnalysisRun
  func start(runID: UUID, now: Int64) async throws -> AnalysisRun
  func recordRequest(runID: UUID, inputBytes: Int, outputBytes: Int, retried: Bool, preempted: Bool) async throws
  /// One transaction: supersede, delete old content, insert, re-point, re-match overlays, prune.
  func adopt(runID: UUID, result: ValidatedAnalysis, counts: ValidationCounts, identity: RunIdentity, now: Int64) async throws -> AnalysisRun
  func fail(runID: UUID, category: AnalysisFailureCategory, detail: String?, now: Int64) async throws
  func timeOut(runID: UUID, now: Int64) async throws
  func cancel(runID: UUID, now: Int64) async throws
  func interrupt(runID: UUID, now: Int64) async throws
  func activeRuns(limit: Int) async throws -> [AnalysisRun]
  func latestRun(meetingID: UUID) async throws -> AnalysisRun?
  func markAutoRestarted(meetingID: UUID, now: Int64) async throws
  func readModel(meetingID: UUID) async throws -> StoredAnalysis?          // rows only; owner labels resolved by the view model
  func setOverlay(meetingID: UUID, target: OverlayTarget, field: OverlayField, value: OverlayValue, snapshot: OverlaySnapshot, now: Int64) async throws
  func removeOverlay(id: UUID) async throws
  func overlays(meetingID: UUID) async throws -> [AnalysisOverlay]
}

protocol MeetingEvidenceReading: Sendable {
  /// Final segments in ordinal pages of ≤ 200 with effective speaker roots.
  func segmentPage(meetingID: UUID, passID: UUID, after ordinal: Int?, limit: Int) async throws -> [EvidenceSegment]
  func participants(meetingID: UUID) async throws -> [EvidenceParticipant]   // roots + certainty per R9
  func notes(meetingID: UUID) async throws -> [NoteParagraph]
  func transcription(meetingID: UUID) async throws -> MeetingTranscription?
  func meeting(id: UUID) async throws -> Meeting?
}

@MainActor protocol IntelligenceObserving: AnyObject {
  func meetingTranscriptDidFinalize(id: UUID)   // automatic trigger
  func meetingWillDelete(id: UUID) async
  func evidenceDidChange(meetingID: UUID)       // 007/010 writes and note saves: refresh stale flag
}
```

`MeetingEvidenceReading` is implemented by a small adapter over `TranscriptStore`, `SpeakerStore`, `IdentityStore` and `MeetingStore` (read-only; it has no write methods by construction). The transport uses the rewrite endpoint and credential (one server in Settings).

## Run algorithm (`MeetingAnalyzer.run`)

1. **Eligibility.** `transcription.state == .final` with a `passID`; else fail `not_eligible` without a request. Preflight the endpoint like rewrite (`RewriteConnectionCategory.preflight`); a refusal fails `server_unavailable` / `authentication_failed` without a request.
2. **Evidence version.** `EvidenceVersion.compute` (research R8) over paged reads. Stored on the run at admission; recomputed before adoption and compared: if it changed during the run, the run fails `source_validation` with detail `evidence_changed` (the next Regenerate uses the new evidence).
3. **Health.** `GET /v1/analysis/health`; refuse on unsupported result schema; take `limits`/`caps` minima.
4. **Language policy.** Resolve the explicit meeting choice first, then a fixed language recorded in the final pass when no override exists, then `LanguagePolicy.detect` on a bounded, valid-UTF-8 sample (R10). Only `sk` and `en` override detection; Automatic and unsupported choices retain the existing detection path. Use the same resolution when checking staleness and immediately before adoption. Each response must declare the exact requested language, including chunk and synthesis results. A mismatch fails `malformed_response` on the client or `output_invalid` on the server. This is a metadata check, not proof of prose language.
5. **Plan.** `AnalysisChunkPlanner.plan(totalBytes:budget:)` decides `full` or `chunk × n` (+ reduce levels). The plan is written to the run row (`chunk_count`) before the first request.
6. **Requests.** Sequential by default (`inFlight = 1`). For each stage: build the request from one page window at a time (never more than one chunk of text in memory beyond the page buffer), send, read the stream with the per-request timeout, and keep the run deadline (R11). On `preempted`: sleep 2 s × attempt, retry the same stage up to 3 times; then fail `backend_busy`. On `server_busy`: the coordinator re-queues the run once after 30 s, then fails `server_unavailable`. Any other error fails the run with the mapped category; nothing partial is stored. Partial results are kept in memory as validated Swift values (bounded by caps × 64). A partial fails the run only on the source rules (FR-024); the literal and dropped-share rules (FR-024a) judge the adopted result, and topics count on both sides of the share.
7. **Validate** every result (below); a `chunk` result that fails source validation fails the run (no repair on the client).
8. **Synthesis.** `partials` ≤ 16 per request; more than 16 → reduce in groups of 16, at most two levels; more than 64 chunks → `too_long` before any request.
9. **Adopt.** Recompute the evidence version; `store.adopt` in one transaction; publish status; record metrics.

Cancellation: `Task.cancel` on the run task; the transport cancels the URL task; the store writes `cancelled`. A response arriving after cancellation or supersession compares `run_id` and state and is discarded.

## Validation (`AnalysisValidator.validate(result, against: evidence, policy:)`)

Runs on the client for every result, after the transport's structural decode (which already enforces schema, lengths, caps and enums and yields `malformed_response`, `unsupported_version` or `over_cap`):

| Step | Rule | Failure |
| --- | --- | --- |
| meeting | `meeting_id == meeting.id` | run fails `meeting_mismatch` |
| sources | every segment id ∈ this meeting's final pass; every note ordinal ∈ current paragraphs with matching hash; ≤ 10 per target; decisions, action items, next steps, questions, risks have ≥ 1 | run fails `source_validation` |
| identity | owner `participant` with `speaker_id` ∉ permitted set (R9) → `none`/`unresolved`, count `identity_downgrade`; `mentioned` name matching a Possible-match candidate name → `none`, count; `mentioned` with `ownership_state == explicit` → `supported` | never fails the run |
| due dates | `explicit_*` require a parseable date and a source; a `date` with `unresolved`/`absent` is cleared; relative dates are re-resolved on the client from `original` against `started_at` when the phrase is in the known table (`zajtra`, `tomorrow`, `pozajtra`, weekday names, `budúci týždeň`…) and a mismatch marks the item `unresolved` with the original kept; vague terms (`soon`, `later`, `eventually`, `at some point`, `next time`, `čoskoro`, `neskôr`, `niekedy`, `nabudúce`, `časom`) force `unresolved` | item-level |
| protected literals | `ProtectedLiteralDetector` per item against referenced sources; for the summary and each topic part (title, summary, bullet) against all evidence (R5) | item dropped, count `dropped_literal`; a summary sentence with a violation is removed; no sentence left → run fails `protected_literal` |
| support | lexical support (R6) per item | item dropped, count `dropped_unsupported` |
| share | `dropped / returned > 1/3` | run fails `unsupported_content` |
| duplicates | next steps identical (normalized) to an action item text are dropped without counting (FR-021) | |
| partial merge | in `synthesis` inputs the client forwards partials unchanged; in the final result, items whose source sets are identical and texts equal after normalization collapse to one | |

Dropped items are not stored, rendered, copied or forwarded.

## Evidence version (`EvidenceVersion`)

`evidence_v1` as in research R8. Test vectors live in `EvidenceVersionTests`: a rename-only change keeps the hash; a manual reassignment, a merge, an identity confirmation, a note edit and a chunk-budget change each change it.

## Overlay matching (`OverlayMatcher.match(existing:newItems:)`)

`overlay_match_v1` as in research R13. Pure function; input and output are value types; table-driven tests.

## Coordinator (`MeetingIntelligenceCoordinator`)

- `queueCapacity = 100`, one running run, `noticePublished` for refusals ("Summary queue is full", "Meeting summaries are turned off" is not used: manual generation works with the setting off).
- `meetingTranscriptDidFinalize(id)`: if `preferences.meetingSummariesAutomatic`, enqueue `automatic`; otherwise nothing.
- `requestRun(meetingID, trigger)`: `manual`, `retry`, `regenerate`; refuses with `not_eligible` notice when the transcript is not final.
- `cancel(meetingID)`, `meetingWillDelete(id)`, `resume(_ restarts: [UUID])`, `observe(meetingID)` → `status`, `evidenceDidChange(meetingID)` → refresh `status.stale`.
- Status values published only after the store write succeeded.
- Background pill: the existing `observeBackgroundWork` shows "Summarizing…" with the queued count while a run is active and the main window is not showing that meeting.

## Bounds summary

| Bound | Value |
| --- | --- |
| queue | 100 meeting ids, refused with notice |
| running runs | 1 |
| requests in flight per run | 1 (policy max 2) |
| evidence page | 200 segments |
| chunk text | 16,384 B, balanced across chunks (or server `limits.input_bytes` if smaller); sized so a dense-tokenizing language's prompt plus the output reservation fit the backend's real KV pool, which memory pressure can hold well under the advertised context |
| chunks per run | 64 |
| partials per synthesis | 16; reduce depth 2 |
| response line | 98,304 B |
| result items | per the protocol caps |
| overlays per meeting | 500 |
| run rows per meeting | 20 |
| run timeout | 120 s … 30 min (R11) |
| preemption retries | 3 per stage |
| language sample | 32 KiB |
| notes paragraphs | 256 × 8,192 B (longer notes fail `too_large` before any request, with a notice naming the notes) |

## Metrics (content-free, `ResourceRecorder`)

Phases `analysisQueued`, `analysisRequesting`, `analysisValidating`, `analysisAdopting`. Metrics: `analysisRunDuration`, `analysisStageDuration`, `analysisChunkCount`, `analysisRequestCount`, `analysisRetryCount`, `analysisPreemptionCount`, `analysisInputBytes`, `analysisOutputBytes`, `analysisItemCount`, `analysisDroppedLiteralCount`, `analysisDroppedUnsupportedCount`, `analysisIdentityDowngradeCount`, `analysisUnresolvedOwnerCount`, `analysisFailure` (category), `analysisStaleCount`, `analysisOverlayOrphanCount`, `analysisQueueDepth`. The recorder's content-free test extends to these.
