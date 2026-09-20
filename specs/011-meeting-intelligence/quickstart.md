# Quickstart: validating meeting intelligence

How to prove Feature 011 works end to end. Contracts: [analysis-protocol.md](contracts/analysis-protocol.md), [client-analysis.md](contracts/client-analysis.md), [ui.md](contracts/ui.md). Schema: [data-model.md](data-model.md).

## Prerequisites

- Features 003–010 working: a self-hosted flowd with its OpenAI-compatible backend (MTPLX on the reference machine), meeting capture, final transcription, diarization and identification on.
- Xcode with the LocalFlow scheme; Go 1.23 for the server.
- Reference machine for measurements: the M5 Mac used in spec 003/010 acceptance.

## Deterministic checks (no hardware, no server)

```sh
make check
```

runs, among the existing suites, the new XCTest files (`AnalysisProtocolTests`, `AnalysisValidatorTests`, `ProtectedLiteralDetectorTests`, `EvidenceVersionTests`, `AnalysisChunkPlannerTests`, `LanguagePolicyTests`, `OverlayMatcherTests`, `AnalysisStoreTests`, `MeetingAnalyzerTests`, `MeetingIntelligenceCoordinatorTests`, `IntelligenceReconcilerTests`, `SummaryModelTests`, `AnalysisReportTests`), the Go tests under `server/internal/analysis/...`, `scripts/check-intelligence-imports.sh`, and `scripts/test-analysis-quality.py` (the offline replay of `fixtures/intelligence/` against scripted responses).

Expected: green, and the analysis-quality report shows SC-001 to SC-006, SC-013 and SC-014 counts at zero violations on the scripted set.

## Run the server with analysis

```sh
cd server && go run ./cmd/flowd serve --backend http://127.0.0.1:8000/v1 --model <served model id>
curl -s http://127.0.0.1:8080/v1/analysis/health | jq .
```

Expected: `service: "localflow-analysis"`, `backend.state: "ready"`, `limits` and `caps` present. `flowd rewrite` still works and serves both services.

## Scenario 1 — generate for the fixture meeting (US1, US2, US3, US4)

1. Seed the deployment fixture: `LOCALFLOW_DEBUG_SEED_INTELLIGENCE=deployment` (debug option, mirrors the diarization seed) creates a finished meeting with Oliver (Confirmed), Martin (meeting-local name), Peter (meeting-local name) and one Possible-match speaker.
2. Open the meeting, Summary tab, Generate Summary.
3. Expected: pending → running with stage text → the summary mentions the Monday deployment; Decisions holds "Deployment moves to Monday"; Action items hold backup (Martin), notify customer (Peter), testing before Friday (Oliver Brunovský); the Possible-match speaker's candidate name is absent from the UI and from the server log's request (check with `--analysis-dump-requests` in a debug build, which writes the request body to a private temp file for inspection only).
4. View source on each item lands on the right transcript segment or note paragraph.
5. Transcript, notes and speaker labels are unchanged (compare `sqlite3 history.sqlite "SELECT sum(length(normalized_text)) FROM transcript_segments"` and the `speaker_assignments` row count before and after).

## Scenario 2 — validation failures (US2, US5, US6)

Run `scripts/analysis-quality.py --mode scripted --case <name>` against the app's debug hook, or the equivalent XCTest, for: fabricated segment id, cross-meeting id, mutated IP in an item, mutated price in a decision, mutated digit in the summary, over-cap decisions, unsupported schema version, wrong meeting id, malformed JSON. Expected per [client-analysis.md](contracts/client-analysis.md): the first two and the last four fail the run with the named category; the two item mutations drop the items and succeed; the summary mutation fails `protected_literal`; in every failing case the previous accepted analysis is byte-identical.

## Scenario 3 — server down, retry, cancel (US6)

1. Stop flowd; Generate Summary → "Your server could not be reached.", Retry offered, meeting fully usable.
2. Start flowd without the backend → "The server's language model is not running."
3. `flowd serve --debug-delay 200s` and a 120 s run timeout → "The summary took too long and was stopped."
4. Start a run, Cancel during running → state cancelled, previous analysis still shown; the server log shows `code=cancelled`.

## Scenario 4 — stale and regenerate (US7)

1. With an accepted analysis, rename a speaker (display name only) → owner chip updates, no stale banner.
2. Reassign one segment to another speaker, or confirm an identity, or edit notes → banner appears within the session.
3. Regenerate with flowd stopped → banner stays, content unchanged.
4. Regenerate with flowd up → banner clears; `analysis_runs` shows the old run `superseded` and no content rows for it.

## Scenario 5 — edits and overlays (US11)

Edit an owner, a due date, the summary; mark an item completed. Regenerate. Expected: matching items keep the edits with the "Edited" tag; an edit whose item vanished appears under Previous edits; `known_speakers`, `voice_samples`, `identity_assignments` row counts and `updated_at` values unchanged.

## Scenario 6 — long meeting and priority (US9, US10)

1. Seed the synthetic four-hour meeting (`LOCALFLOW_DEBUG_SEED_INTELLIGENCE=fourhour`).
2. Generate; watch the stage text count chunks. Expected: the last-five-minute decision is present with a valid source; the server log shows every request's `input_bytes` ≤ the budget and at most one analysis request at a time.
3. While it runs, dictate with rewriting on, 20 short and 20 ordinary phrases (the spec 003 latency script). Expected: rewrite latency within the spec 003 gates; the analysis run shows `preemption_count` > 0 and still completes.
4. Record results in `acceptance/throughput.md` and `acceptance/priority.md` with hardware, OS, build, flowd version, backend, model, flags.

## Scenario 7 — languages (US12)

Seed the Slovak, English and mixed fixtures; generate each. Expected: prose language matches; "deployment", "backup", "M6" and the listed terms appear verbatim in the mixed result; each request body carries `language_policy.output`.

## Scenario 8 — restart (FR-007a)

1. Turn automatic summaries on; finish a meeting; quit the app while the run is running.
2. Relaunch. Expected: the run row is `interrupted`; a new `restart` run is queued once; if it fails, the meeting shows Generate Summary and no further restart happens this launch.
3. Repeat with a manual run: after relaunch it stays interrupted with Retry.

## Scenario 9 — regression (FR-051, SC-015)

With automatic summaries off and no run ever started, run the full XCTest suite and the spec 003 latency script. Expected: identical results to the pre-feature baseline; idle RSS within noise (`scripts/memory-report.sh`).

## Acceptance files to produce

`acceptance/throughput.md` (SC-007, SC-008), `acceptance/priority.md` (SC-009), `acceptance/memory.md` (SC-010 client and server RSS), `acceptance/quality.md` (SC-001 to SC-006, SC-013, SC-014 on the live backend), `acceptance/recovery.md` (SC-011, SC-012, FR-007a), `acceptance/regression.md` (SC-015). Each names hardware, OS, build, flowd version, backend, model, prompt versions, policy values and date. Unmeasured gates stay marked unmeasured.
