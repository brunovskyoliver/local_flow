# Implementation plan: server-assisted dictation rewriting

**Branch**: `main` | **Feature identifier**: `003-server-rewriting` | **Date**: 2026-09-17 | **Spec**: [spec.md](spec.md)

The setup script reports the feature identifier in its `BRANCH` field. The actual Git branch remains `main`, matching the specification. `.specify/feature.json` selects Feature 003.

## Summary

After the faithful transcript is committed, an eligible dictation enters a new `rewriting` state, sends the transcript to the user's own server through a versioned NDJSON-over-HTTP protocol, validates the single `result` event, and inserts either the rewritten text or, on any failure, timeout or cancellation, the faithful transcript through the existing `insertOnce` path. Attempts persist in a new cascading table in the existing SQLite database, each with its five-span latency record, the backend/model/prompt/shield identity that produced it, and a delivered marker; the transcription records which text and which attempt were actually inserted. Settings live in UserDefaults with the secret in Keychain; off-loopback plain HTTP needs an explicit per-origin insecure override on top of the credential (FR-016a). The rewrite coordinator is always wired and every attempt is admitted against an immutable settings snapshot, so Settings changes apply to the next dictation without relaunch; an attempt row exists only after admission, and pre-admission refusals persist nothing. The Go server gains the protocol's two endpoints with one OpenAI-compatible backend adapter that always streams from the backend with bounded accumulation and shields pattern-matchable protected entities with placeholders before prompting, so the feature can be run and measured against the owner's MTPLX host (`mtplx-qwen35-9b-optimized-speed` initially). SC-011 is a measured release gate with its own acceptance file: short-bucket median ≤ 1.5 s and ordinary-bucket p95 ≤ 3.0 s are binding, short-bucket median ≤ 1.0 s is the optimization target reported beside the gate. The background-upgrade interaction was evaluated and rejected for this release; the seam and a four-step revisit path are in [research.md](research.md).

This is a design plan. Latency, quality and memory figures are acceptance inputs to measure during implementation, not results.

## Technical context

| Item | Decision |
| --- | --- |
| Language/version | Swift 6 language mode, macOS 14.0 target; Go 1.23 standard library; Python 3 development-only scripts |
| Dependencies | Existing GRDB 7.10.0, FluidAudio 0.15.7, SwiftUI/AppKit, Foundation `URLSession`, CryptoKit, Security; no added client or server dependency |
| Storage | Existing private SQLite database, migration `rewrite-v4`, `rewrite_attempts` table with cascade, `transcriptions.rewrite_state` column; Keychain generic password for the credential |
| Wire | LocalFlow rewrite protocol v1: `GET /v1/rewrite/health`, `POST /v1/rewrite` → `application/x-ndjson`; shared schemas under `protocol/` |
| Testing | XCTest with `FakeRewriteTransport`, in-memory credential store and the existing fake store; Go `httptest` server and fake backend; deterministic Python checker tests; opt-in live corpus runner |
| Platform/type | One native macOS app plus the separate Go `flowd` process; inference stays in a third process the server calls |
| Performance | SC-011 is a release gate on the reference setup with a warm model: short bucket median ≤ 1.5 s (binding) with ≤ 1.0 s as the optimization target reported as achieved/not achieved; ordinary bucket p95 ≤ 3.0 s (binding); buckets defined once in [contracts/rewrite-quality.md](contracts/rewrite-quality.md). Five client spans plus three server spans per attempt, grouped by bucket and backend/model/prompt/shield identity; unmeasured below 5 samples; a miss names the dominant span. Any attempt reaches a terminal state within the configured timeout + 500 ms (SC-004) |
| Constraints | Offline dictation unchanged when disabled; 20 s default timeout in 5–60 s; input ≤ 20,000 scalars/65,536 bytes; response ≤ min(4× input, 64 KiB) on the client and the same bound enforced per fragment while the server streams from the backend; 10 admitted attempts per dictation; 1 in flight per dictation, 2 overall; every local limit is a pre-admission refusal (no row, no request, faithful insertion in the live flow); off-loopback `http://` blocked without the per-origin insecure override; no client LLM |
| Scope | Client rewrite path, settings, history detail, protocol contract and schemas, thin server endpoints with one adapter, corpus and checker; no meeting, context, translation or cloud work |

No unresolved design clarification remains. Bypass gesture, background upgrade and its revisit path, latency measurement, backend streaming and bounded accumulation, protected-entity shielding, concurrency-cap behavior, the admission rule for attempt persistence, insecure override, runtime wiring, identity fields, chunking, transport and ATS decisions are recorded in [research.md](research.md). The analysis reconciliation of 2026-09-17 is summarized in the specification's "Design reconciliation" clarification entry.

## Constitution check

Pre-research gate: pass. No exception is proposed.

| Principles | Design and post-design result |
| --- | --- |
| 1, 14: native client and scope | Pass. Swift/SwiftUI additions inside existing targets; no web view, no client runtime, no new package. Server work is the minimum needed to exercise the contract; operations packaging stays in a server specification. |
| 2, 6: bounded memory and incremental work | Pass by design. Every limit is normative in [contracts/client-rewrite.md](contracts/client-rewrite.md): input, response body, result text, stream line, attempts, in-flight count, timeouts. The response is read line by line with byte counting before parsing; the server streams from the backend with a first-token timeout and checks `min(4 × input, 65,536)` before appending each fragment, cancelling the backend on overflow ([contracts/rewrite-protocol.md](contracts/rewrite-protocol.md), bounded accumulation); at the in-flight cap the client refuses before admission and inserts the faithful text; no request queue exists anywhere. Idle client RSS delta is a measured gate (SC-009); server RSS is measured separately (T082). |
| 3: model lifecycle | Pass. No heavy model is created in the client. `ModelLifecycleCoordinator` is untouched; the rewrite runs after `lifecycle.finish(lease)` has been called, so ASR release timing is unchanged. The server never loads weights. |
| 4, 5: offline and privacy | Pass. Disabled by default; with rewriting disabled the always-wired coordinator makes zero transport calls (guard-transport test), and the nil dependency reproduces the existing flow in the regression suites. Requests carry only the permitted fields. Credential in Keychain, masked; logs and metrics content-free with a test asserting it. Ephemeral `URLSession` keeps transcript bytes out of caches. Plain HTTP off-loopback is blocked until the user turns on a per-origin insecure override, and then still needs a credential and shows a persistent warning that authentication does not encrypt the transcript; this is now the specification's rule (FR-016a). |
| 7, 9: persistence and recovery | Pass. One migration, one table, cascade delete, quota counted in the same transaction, startup `pending → interrupted` fix-up, full input snapshot with hash per attempt. A row exists only for an admitted attempt; refusals persist nothing. The faithful transcript is committed before any request and never modified. |
| 8: server isolation | Pass. Go standard library, one process, backend behind an adapter, no weights, bounded streamed accumulation. Idle/ordinary server RSS targets are measured in T082 with the backend excluded; unmeasured until then. |
| 10: speaker correctness | Not exercised. |
| 11: structured output | Pass. Versioned protocol; client validates schema version, request id, mode, type, size, identity fields and absence of placeholder glyphs before use; behavior never depends on parsing model prose. The server constrains the model (streamed, schema/grammar where supported, placeholders for protected entities) and validates restoration before emitting `result`. |
| 12: testability | Pass. Transport, credential and attempt-store protocols with doubles; tests for lifecycle, cancellation, capacity, staleness, failure categories, deletion, restart and preservation of the faithful text. |
| 13: observability | Pass by design. Per-attempt five-span latency, server spans, byte counts, ordinal, outcomes and the backend/model/prompt/shield identity go to `ResourceRecorder` and the attempt row; pre-admission refusals emit a counter. Every evidence file opens with the evidence identity block from [contracts/rewrite-quality.md](contracts/rewrite-quality.md) (hardware, macOS, app build/commit, flowd build/commit, backend, model, prompt/shield versions, warm state, network). Two figures without matching identity blocks are not compared. |

Post-design gate: pass. No ADR is required for this design. Two decisions deserve an ADR at implementation time so they are discoverable outside this feature: the rewrite protocol v1 shape (`docs/adr/0013-rewrite-protocol-v1.md`) and the rejection of background upgrade with its revisit conditions (`docs/adr/0014-no-background-text-replacement.md`). Neither amends a principle.

## Project structure

```text
specs/003-server-rewriting/
  spec.md
  plan.md
  research.md
  data-model.md
  quickstart.md
  contracts/
    rewrite-protocol.md
    client-rewrite.md
    rewrite-quality.md
  acceptance/                          # implementation: baseline, connection-test, dictation-flows, quality-summary, review, latency, memory, server-memory, privacy, fr-022-traceability
  tasks.md                             # next workflow; not generated by planning
protocol/
  openapi.yaml                         # add the two paths
  schemas/rewrite-request.schema.json  # new
  schemas/rewrite-event.schema.json    # new
server/
  cmd/flowd/main.go                    # `rewrite` subcommand and flags (--shield, --debug-delay, --protocol-versions)
  internal/rewrite/                    # new: handler, protocol types, validation, limits, timing
  internal/rewrite/backend/            # new: streaming OpenAI-compatible adapter, fake backend for tests
  internal/rewrite/prompts/            # new: versioned per-mode templates
  internal/rewrite/shield/             # new: versioned detector set, placeholder substitution and restoration
apps/macos/LocalFlow/
  Info.plist                           # NSAppTransportSecurity
  Core/DictationBoundaries.swift       # RewriteRequesting, RewriteTransporting, RewriteCredentialStoring
  Core/Rewrite/                        # new
    RewriteProtocol.swift              # request/event types, validation, failure categories
    RewriteClient.swift                # URLSession transport, bounded NDJSON reader
    RewriteSettings.swift              # snapshot, loopback and warning rules
    RewriteCredentialStore.swift       # Keychain
    RewriteAttempt.swift               # persisted attempt model, latency spans, identity
    RewriteDeliveryPolicy.swift        # waitThenInsert (shipped), insertThenReplace (declared, blocked)
    RewriteLatency.swift               # five-instant capture, buckets, report grouping
  Core/Storage/
    HistoryMigrations.swift            # rewrite-v4
    TranscriptionStore.swift           # attempt CRUD, quota, startup fix-up, deletion counts
    TranscriptionEntry.swift           # rewriteState
  Core/Observability/ResourceRecorder.swift  # rewrite metrics
  Features/Dictation/
    DictationCoordinator.swift         # rewriting state, bypass flag, fallback insertion
    DictationSession.swift             # .rewriting
    IndicatorPanel.swift / DictationIndicator.swift  # rewriting state, action notice
    ShortcutController.swift           # Shift-on-release bypass
  Features/Rewrite/
    RewriteCoordinator.swift           # new: policy, ordering, staleness, retry, cancel
  Features/Settings/
    AppPreferences.swift               # rewrite preferences
    SettingsView.swift / SettingsViewModel.swift  # controls, warning, connection test
  Features/Transcriptions/
    HistoryView.swift / HistoryViewModel.swift    # badge, attempts loading
    TranscriptionDetailView.swift      # rewrite section
    ExplicitInsertionCoordinator.swift # insert a chosen text
apps/macos/LocalFlowTests/
  Support/BoundaryFakes.swift          # FakeRewriteTransport, in-memory credentials, store methods
  RewriteProtocolTests.swift, RewriteClientTests.swift, RewriteCoordinatorTests.swift,
  RewriteStoreTests.swift, RewriteSettingsTests.swift, RewriteHistoryTests.swift  # new
fixtures/rewrite/corpus-v1.json        # new
scripts/rewrite_quality_lib.py         # new: shared checker, detectors, buckets, identity validation
scripts/rewrite-quality.py             # new, development-only runner
scripts/test-rewrite-quality.py        # new, in make check
```

New files are proposed locations. Keep all database writes under the existing `TranscriptionStore` actor. Reuse `insertOnce`, `ExplicitInsertionCoordinator`, `IndicatorPanel` notices and `ResourceRecorder` rather than adding parallel mechanisms.

## Delivery sequence

1. Protocol first: JSON schemas, OpenAPI paths, Swift protocol types with validation, Go types with validation, and tests on both sides for every rejection in [contracts/rewrite-protocol.md](contracts/rewrite-protocol.md). No network yet.
2. Storage: migration, attempt CRUD with quota and ordinal rules, startup fix-up, deletion, legacy reads, and the fake store. Tests for restart, cascade and capacity.
3. Client transport and coordinator: `RewriteClient` with the bounded reader and five-instant capture, `RewriteCoordinator` with the admission sequence (pre-admission refusals persist nothing), ordering, staleness, cancellation and limits, `RewriteDeliveryPolicy` with the blocked case, and the fake transport covering every FR-022 scenario, including 20 sequential and 5 overlapping dictations and the cap-hit case.
4. Dictation integration: always-wired coordinator with per-attempt settings snapshot, `rewriting` state, bypass gesture, fallback insertion, delivered-source recording, indicator notice and cancel; run the Feature 001/002 suites with the dependency nil and with a guard transport to prove SC-001, plus the no-relaunch toggle test.
5. Settings and credential: preferences, Keychain store, validation rules, per-origin insecure override with its warning and immediate revocation, connection test with the eight categories and identity display against the fake transport.
6. History: badge, detail section with delivered-versus-current labels, attempts list with identity and spans, retry with mode picker (never auto-inserting), cancel, explicit insertion of a chosen text updating the delivered record, deletion.
7. Server: `flowd rewrite` handler, limits, concurrency, health with cached backend probe and identity fields, streaming OpenAI-compatible adapter with first-token timeout, per-fragment output bound with backend cancellation, and schema-constrained output where supported, versioned prompts, shield detector set with round-trip tests, fake backend tests including a runaway backend, `--shield`, `--debug-delay` and `--protocol-versions` for acceptance doubles.
8. Quality and acceptance: corpus with protected entities and semantic facts, checker and detector tests with mutation fixtures, live runner with identity gating, shield on/off comparison, owner review, `acceptance/latency.md` against the SC-011 gates and optimization target, 20-cycle client memory runs with and without rewriting, `flowd` memory runs with the backend excluded, FR-022 traceability audit; write the two ADRs. Continue to analyze/implement through the repository workflow.

## LocalFlow constitution gates

Bounds and overflow: all limits and their refusal paths are normative in [contracts/client-rewrite.md](contracts/client-rewrite.md) and [contracts/rewrite-protocol.md](contracts/rewrite-protocol.md). No queue, no automatic retry, no eviction; local refusals happen before admission and are immediate, counted and unpersisted, including the two-in-flight cap, which inserts the faithful transcript at once rather than waiting or cancelling running attempts. On the server, streamed backend output is bounded per fragment and the backend is cancelled on overflow.

Lifecycle owner and release: no model is owned by the client for this feature. The rewrite starts after the ASR lease is finished, so existing cooldown and release evidence stays valid; the 20-cycle protocol is re-run with rewriting enabled to confirm.

Offline and privacy: disabled by default; zero transport calls when disabled, in Exact mode, or when bypassed, proven by a guard transport against the always-wired coordinator. Request fields are enumerated and closed. Keychain for the secret; the settings snapshot carries credential presence only. Content-free logs and metrics with a test. Plain HTTP off-loopback is blocked until the per-origin insecure override is on, then requires a credential and shows a persistent warning that authentication does not encrypt the transcript; the override is recorded on each attempt sent under it and revoking it disables the endpoint at once.

Recovery and persistence: faithful transcript committed before any request; attempts cascade with the dictation; `pending` becomes `failed(interrupted)` on restart; both texts remain recoverable through the existing explicit insertion and copy paths when insertion fails.

Dependencies and licenses: none added. The reference model's license is the owner's record when chosen; the client does not depend on it.

Memory acceptance: idle client RSS with rewriting enabled within max(5 MB, 5%) of the disabled baseline and within the 150 MB target, under the Feature 001 protocol; no inference runtime mapped in the client (T078). Server: `flowd rewrite` idle RSS, RSS during an ordinary request and settled RSS after repeated requests are measured with the backend excluded and compared against the 100 MB idle / 250 MB processing targets from [memory-budget.md](../../docs/performance/memory-budget.md) and constitution principle 8 (T082); both remain unmeasured until recorded.

Latency acceptance: SC-011 is a gate with `acceptance/latency.md` as its evidence: per bucket, the binding gate (short median ≤ 1.5 s, ordinary p95 ≤ 3.0 s), the short-bucket optimization target (≤ 1.0 s) reported as achieved or not achieved, measured median/p95 per span, the evidence identity block, and the dominant span for a miss. Figures under 5 samples are unmeasured. A missed gate is reported as failed with the span named; it never relaxes the gate or moves to a footnote. The configured timeout is never quoted as latency.

Reproducibility: every attempt row, corpus result, review record and latency or memory report carries the evidence identity block from [contracts/rewrite-quality.md](contracts/rewrite-quality.md): Mac hardware, macOS version, LocalFlow app version/build/commit, flowd version/commit, backend, model identity/tag, prompt version per mode, shield version, protocol version, warm/cold state, network topology. Results without it are not recorded; results with different blocks are not compared.

## Validation and requirement coverage

| Requirements | Primary validation |
| --- | --- |
| FR-001, FR-012, FR-016 (runtime wiring); SC-001 | Feature 001/002 suites with nil dependency and with the always-wired coordinator on a guard transport; bypass and Exact-mode tests asserting no transport call; toggle-on-without-relaunch and toggle-during-pending tests |
| FR-002, FR-005, FR-023; SC-005, SC-006 | Corpus runner with shield on/off comparison, deterministic protected-entity checker and semantic mutation detector tests with mutation fixtures, reviewer records with hashes and identity block |
| FR-003, FR-013, FR-010; SC-002, SC-007 | Coordinator tests: eligibility, fallback insertion per category, notice content, both texts recoverable |
| FR-004, FR-006, FR-018; SC-010 | Protocol type tests (closed request fields, every validation rule), log/metric content assertions |
| FR-007, FR-007a, FR-008, FR-009; SC-003, SC-004 | Admission sequence (each pre-admission refusal leaves zero rows and consumes no ordinal, from dictation and from history), immediate cap refusal, timeout within +500 ms, cancellation timing, staleness, 20 sequential plus 5 overlapping dictations with mixed outcomes |
| FR-011, FR-014, FR-015; SC-008 | Store tests: snapshot and hash per attempt, identity and span columns, delivered source and attempt, ordinal ordering, restart fix-up, cascade delete with `SET NULL` on the delivered reference, legacy rows; history retry never inserts |
| FR-016, FR-016a, FR-017 | Settings tests: validation, loopback rule, insecure override per origin, its reset and immediate revocation, warning text, credential never in defaults or snapshot, eight connection test categories, identity display |
| FR-019, FR-020; SC-009 | No inference symbol in the client target; 20-cycle memory runs with and without rewriting; `vmmap` check; `flowd rewrite` RSS with the backend excluded (T082) |
| FR-021 | Indicator, notice and detail view tests; accessibility announcements; faithful Insert in detail as the "use faithful transcript instead" action |
| FR-022 | Traceability audit: one named test per scenario, reusing the story-phase tests; deterministic under three local repeated runs |
| SC-011 | `acceptance/latency.md` from runner `summary.json` and in-app spans on the reference setup: gate and optimization verdicts per bucket, evidence identity block, dominant span on a miss, unmeasured below threshold |
| Server bounded accumulation (constitution 2, 6) | Go adapter test with a runaway fake backend: cancellation at the bound, no partial `result`, `output_too_large` to the client, content-free logs |

Run `make check` after repository changes. It establishes deterministic and scaffolding validity only; see [quickstart.md](quickstart.md) for live and acceptance steps.

## Complexity tracking

No constitution violations. The only added moving part outside the client is the thin server endpoint pair, which principle 8 already prescribes as the home for backend adapters.

## Correction filter implementation plan (2026-09-17)

Use a pure `CorrectionCandidateScoring` protocol and immutable candidate/context/assessment values under `Core/Corrections`. Inject the scorer into `CorrectionLearner`. Read existing vocabulary once, assess the already-detected span, then admit only autoLearn to the unchanged conflict and save path. No watcher or vocabulary repository redesign.

Hard exclusions precede scoring: invalid bounds, protected literals, formatting-only edits, common targets and function words. A compact English/Slovak function-word set plus a small everyday-word suppression set is deliberately incomplete. Unknown lowercase natural-language edits remain ignored without canonical evidence. Replacement case, letters/digits or hyphen shape provides name/technical evidence. Two-row normalized Levenshtein uses at most 256 UTF-8 bytes per side. Shape alone cannot qualify: require similarity >= 0.45 or canonical evidence. Score starts at 1, adds 3 for shape, 3 for a canonical orthographic match, 2 for similarity >= 0.625, and 2 for a prior identical observation. Scores >= 6 auto-learn; remaining eligible candidates suggest; hard exclusions ignore with score 0. Thresholds are implementation details, not product guarantees.

History stores at most 128 SHA-256 candidate-pair digests with counts saturating at 3, ordered by last observation. Evict least recently observed at capacity. Counts represent separate settled insertion watches, not polling reads. No clock, background task, persistence or datastore is added. Suggestions keep only assessment enums and digest history, not source/replacement text. Existing canonical or alias conflicts still reject insertion, including a new alias targeting an existing entry; extending existing entries would require different Undo semantics and is deferred.

Constitution check: pass, no exception/ADR required. Native Swift/Foundation/CryptoKit only; no model ownership changes, runtime dependency, server work or network calls. Input, edit-distance working memory, dictionary metadata and history are bounded. No transcript logging or new ResourceRecorder channel. Existing transactional vocabulary persistence and failure handling remain authoritative; session history disappears on restart. Resource latency/RSS acceptance is unmeasured, not inferred from tests.

Analysis: the filter belongs after detection and before mutation; no conflict with the existing 90-second/1–3-word boundary. Suggestion UI is explicitly deferred by the requested scope. Existing ordinary-capitalization Undo fixture changes to a lexical example, with rejection coverage added for the old case.
