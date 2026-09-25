# Implementation plan: application context for dictation

**Branch**: `analysis-notes-pipeline` | **Feature identifier**: `012-app-context-awareness` | **Date**: 2026-09-24 | **Spec**: [spec.md](spec.md)

The setup script reports `012-app-context-awareness` in its `BRANCH` field. The Git branch stays `analysis-notes-pipeline`, as the specification records. `.specify/feature.json` selects Feature 012.

## Summary

When the dictation shortcut is pressed, the coordinator already captures the focused element as a `CapturedTarget`. Feature 012 starts a bounded, detached context read from that same element at that moment: app name and category, field kind, window title, up to 1,000 characters before the cursor, 300 after, 2,000 selected, and at most 40 candidate terms extracted from those parts. The read has a 250 ms hard deadline and runs alongside recording, so recording never waits for it. The result is awaited only after recognition.

Two consumers use the snapshot:

1. `ContextSpeller`, a pure local pass that runs after preferred spellings and before the entry is sealed. It replaces a 1–3 word span only when its folded form matches a candidate term exactly, or matches a capitalized name within a small edit distance. Common words, dictionary terms, protected literals and ambiguous matches are never changed. It works offline, with rewriting off.
2. The rewrite request, only when a second opt-in toggle is on and the server advertises protocol version 2. A v2 request carries the snapshot in a separate, typed `context` object. flowd renders it into the system message as delimited reference material with fixed rules. The client rejects any result that copies four or more consecutive words from the context that the speaker did not say, or that introduces a protected literal found only in the context. A rejected result is a new persisted failure category, `context_copied`, and the faithful transcript is inserted under the Feature 003 fallback.

One migration adds `dictation_contexts`, which holds one row per dictation made after the migration: outcome, snapshot JSON as sent, pre-spelling text and spelling changes, with cascade delete. The same migration rebuilds `rewrite_attempts` to accept protocol version 2, the new category and a context hash. Settings live in `AppPreferences`: two toggles (both off), exclusions, category overrides and the P3 style toggle. History detail shows the stored snapshot with source labels, the outcome reason and each spelling change. Speech recognition and meetings are unchanged.

This is a design plan. Capture latency, rewrite latency, quality and memory figures are acceptance inputs to measure, not results.

## Technical context

| Item | Decision |
| --- | --- |
| Language/version | Swift 6 language mode, macOS 14.0 target; Go 1.23 standard library; Python 3 development-only scripts |
| Dependencies | Existing GRDB 7.10.0, ApplicationServices (AX), AppKit `NSWorkspace`, Foundation, CryptoKit. No new client or server dependency |
| Storage | Existing SQLite database, migration `app-context-v11`: new `dictation_contexts` table (cascade), `rewrite_attempts` rebuilt to widen checks and add `context_hash`. Preferences in `UserDefaults` via `AppPreferences` |
| Wire | Rewrite protocol v2 = v1 + required `context` object; v1 unchanged and still sent whenever context is not sent. `protocol_versions` in health drives the choice. Schemas under `protocol/` |
| Testing | XCTest: `FakeAppContextReader`, pure `ContextTermExtractor`/`ContextSpeller`/`ContextCopyGuard` tests, coordinator tests with the existing fakes, store migration/cascade tests. Go: protocol v2 decode tests, prompt tests, handler tests with the fake backend. Python: deterministic context checker in `make check`, live A/B runner outside it |
| Platform/type | One native macOS app plus the separate Go `flowd` process |
| Performance | SC-005: capture p95 ≤ 150 ms on the owner's Mac in the listed apps; hard deadline 250 ms; recording start unaffected (capture is concurrent). SC-006: Feature 003 SC-011 gates hold with context. Both measured, never inferred |
| Constraints | Per-part bounds and 8,192-byte serialized snapshot limit ([contracts/context-snapshot.md](contracts/context-snapshot.md)); ≤ 40 terms of ≤ 64 bytes; one snapshot per dictation; no cache or queue; no recognizer prompting; no OCR, clipboard, URL bar or other windows |
| Scope | Dictation only: capture, local context spelling, rewrite v2, settings, history, evaluation corpus. No meeting, recognizer biasing or tree-walking for names outside the focused field |

No design clarification is open. Research decisions are in [research.md](research.md).

## Constitution check

Pre-research gate: pass. Post-design gate: pass. No principle exception. One ADR is required by the specification because the design replaces Feature 003 FR-004 and extends ADR 0013: `docs/adr/0023-rewrite-protocol-v2-reference-context.md`.

| Principles | Result |
| --- | --- |
| 1, 14: native client, scope | Pass. AX and AppKit only, inside existing targets. No new package. Server change is one optional request field and one prompt block. P3 style is a flag on the same field, not a new mechanism |
| 2, 6: bounds | Pass. Every part, the term list, the serialized snapshot, the capture time and the copy-check work are bounded (see contracts). One detached read per dictation, no queue or cache. The protocol-version cache holds one entry, keyed by endpoint origin, and is replaced when the endpoint changes |
| 3: model lifecycle | Pass. No model involved. `ModelLifecycleCoordinator` untouched; recognition input unchanged |
| 4: local-first | Pass. Context spelling is offline. With the server unreachable, Feature 003 fallback is unchanged |
| 5: privacy | Pass with consent. Both toggles are off by default. Settings states what is read, what is never read and where it goes (FR-001). Excluded apps, LocalFlow itself and secure fields are never read. Snapshot text is never logged or put in metrics (asserted by test). It goes only to the configured rewrite server under Feature 003 transport rules and is deleted with its dictation. Constitution defaults for recognition and recordings are unchanged |
| 7, 9: persistence | Pass. One migration, one table with cascade. The `rewrite_attempts` rebuild uses GRDB's default deferred foreign-key check. The faithful and pre-spelling texts are committed before any request. A context-read failure never blocks the commit |
| 8: server isolation | Pass. Go standard library, no weights. The context is bounded before prompting |
| 11: structured output | Pass. Versioned v2 request schema, closed field set on both sides, client validation of the result plus the copy guard before insertion |
| 12: testability | Pass. `AppContextReading` protocol with a fake. The extractor, speller and copy guard are pure functions. Tests cover the deadline, exclusions, cascade, retry reuse, v1 fallback and content-free logs |
| 13: observability | Pass. Capture duration, outcome, part byte counts and term count go to `ResourceRecorder`; text does not. Evaluation evidence reuses the Feature 003 identity block plus context prompt version |

## Project structure

```text
specs/012-app-context-awareness/
  spec.md, plan.md, research.md, data-model.md, quickstart.md
  contracts/
    context-snapshot.md        # capture rules, bounds, exclusions, outcome codes
    rewrite-protocol-v2.md     # v2 request delta, negotiation, server prompt rules
    context-quality.md         # corpus format, metrics, gates, copy guard threshold
  acceptance/                  # implementation: capture-latency, evaluation, privacy, memory
  tasks.md                     # next workflow step
docs/adr/0023-rewrite-protocol-v2-reference-context.md   # new
protocol/
  openapi.yaml                           # document v2 body variant
  schemas/rewrite-request.schema.json    # oneOf v1 | v2
  schemas/rewrite-context.schema.json    # new
server/internal/rewrite/
  protocol.go                  # accept schema_version 2 with context; health protocol_versions [1,2]
  context.go                   # new: bounds check, rendering of the reference block
  prompts/prompts.go           # versioned context rules block
apps/macos/LocalFlow/
  Core/Context/                # new
    AppContextSnapshot.swift   # value types, bounds, outcome, canonical JSON + hash
    AppContextReader.swift     # AppContextReading + SystemAppContextReader (AX, deadline)
    AppCategory.swift          # built-in bundle-id map, default exclusions
    ContextTermExtractor.swift # candidate terms from snapshot parts
    ContextSpeller.swift       # local spelling pass + change records
    ContextCopyGuard.swift     # FR-012 check
  Core/Rewrite/RewriteProtocol.swift     # v2 request encoding, context_copied category
  Core/Rewrite/RewriteClient.swift       # health-based version cache
  Core/Storage/HistoryMigrations.swift   # app-context-v11
  Core/Storage/TranscriptionStore.swift  # context row CRUD in the commit transaction
  Features/Dictation/DictationCoordinator.swift  # start read after target, speller, pass snapshot
  Features/Rewrite/RewriteCoordinator.swift      # carry snapshot, copy guard, retry reuse
  Features/Settings/AppPreferences.swift, SettingsView.swift, SettingsViewModel.swift
  Features/Transcriptions/TranscriptionDetailView.swift  # context section
apps/macos/LocalFlowTests/
  AppContextReaderTests.swift, ContextSpellerTests.swift, ContextCopyGuardTests.swift,
  AppContextStoreTests.swift, DictationContextFlowTests.swift   # new
fixtures/context/corpus-v1.json          # new
scripts/context_quality_lib.py, scripts/context-quality.py, scripts/test-context-quality.py  # new
```

New Swift files are registered with `scripts/register-xcode-sources.py`. All database writes stay in the `TranscriptionStore` actor.

## Delivery sequence

1. **Values and pure logic (Story 1, no AX yet)**: snapshot types with bounds and canonical JSON, category map and exclusions, term extractor, speller, copy guard. Unit tests include the deterministic names subset from the corpus with context on and off (SC-001, rewriting-off half).
2. **Storage**: `app-context-v11` with `dictation_contexts`, the `rewrite_attempts` rebuild and legacy-row reads. The context row is written in the same transaction as the entry commit. Tests cover cascade, rebuild row preservation and the restart path.
3. **Capture**: `SystemAppContextReader` with the AX messaging timeout, the 250 ms deadline, secure-field, placeholder and URL-bar exclusions and outcome codes. The coordinator starts the read right after `captureTarget()` and awaits it after recognition. Tests use the fake reader for slow, empty, denied and excluded cases, and assert that recording start is independent of read duration.
4. **Local spelling in the pipeline**: apply after `normalizedForDelivery`, re-seal the quality detail with the spelled text (a `resealed(normalizedText:)` helper, because `addingCompletionReasons` returns early with no reasons), and record the pre-spelling text and changes. Feature 001/002 suites run with context off and must be unchanged (Story 1, scenario 3).
5. **Settings and history (Story 3)**: toggles with the disclosure text, exclusion editor (running apps plus manual bundle ID), history context section, outcome labels. Deletion test.
6. **Protocol v2 (Story 2)**: schemas, Go decode/validation/prompt block, health `protocol_versions: [1,2]`. Client v2 encoding, the per-origin version cache from health, the v1 path when unsupported (outcome `server_unsupported`), the copy guard in the result path, `context_copied` fallback, and retry reuse of the stored snapshot.
7. **Evaluation and acceptance**: corpus, deterministic checker in `make check`, live A/B runner, `acceptance/evaluation.md` against SC-001–SC-004, `acceptance/capture-latency.md` (SC-005), a rewrite latency rerun (SC-006), privacy and memory records, ADR 0023.
8. **Style by category (Story 4, P3)**: only after step 7 evidence. Set `style_hints` in the snapshot, add the server's category formatting rules, add overrides in Settings, and evaluate category items separately.

## LocalFlow constitution gates

**Bounds and overflow.** Normative limits live in [contracts/context-snapshot.md](contracts/context-snapshot.md). When a part is over its bound, it is cut at a grapheme boundary nearest the cursor. When the serialized snapshot is over 8,192 bytes, parts are dropped in a fixed order (after, before, selected, title) until it fits. When the deadline is hit, the parts read so far are used with outcome `timed_out`. Nothing is queued or retried.

**Lifecycle.** No model. The read task belongs to the dictation `run` and is cancelled with it.

**Offline and privacy.** Both toggles are off by default. The rewrite toggle requires the context toggle and rewriting. Guard tests assert zero AX context reads when the feature is off, and zero `context` field when the rewrite toggle is off or the server lacks v2. Log and metric tests assert that no snapshot text appears.

**Recovery and persistence.** The context row commits atomically with the entry. The snapshot is immutable after commit. Retries read it; they never recapture. If the context write fails, the whole commit fails exactly as today: the existing unsaved-text recovery applies, and retry-save rewrites both.

**Dependencies and licenses.** None added. The Wispr Flow and Superwhisper behavior used in research comes from public documentation only; no code was copied.

**Memory.** The snapshot is at most about 16 KiB in flight. Idle and recording RSS targets are unchanged and are re-measured with context on, using the Feature 001 protocol. Unmeasured until recorded.

**Reproducibility.** Evaluation evidence carries the Feature 003 identity block plus `context_prompt_version`, `speller_version` and corpus version.

## Validation and requirement coverage

| Requirements | Primary validation |
| --- | --- |
| FR-001, FR-017; Story 3.1 | Preference defaults test. Toggle-without-relaunch test. Guard reader asserts zero reads when off |
| FR-002, FR-005; SC-005 | Fake reader with delays of 0/200/600 ms: recording state reached independently, `timed_out` recorded at 250 ms. Focus-change-after-press test. `acceptance/capture-latency.md` for real apps |
| FR-003, FR-004, FR-006 | Reader tests on the snapshot builder: secure subrole, placeholder equality, browser toolbar field, excluded bundle, own bundle, permission denied. Extractor tests for numeric, amount, email, URL and IP exclusion |
| FR-007, FR-008, FR-009; SC-001 (rewrite off) | Speller unit tests (folded exact, near-name, common word untouched, dictionary precedence, ambiguity, word order, protected spans). Deterministic names subset on/off. Store test for pre-spelling text and changes |
| FR-010, FR-011, FR-013 | Go and Swift schema tests (closed fields, bounds, version). Prompt test asserting the context block rules and delimiter escaping. The Feature 003 suites run with context on and a fake transport |
| FR-012; SC-002, SC-003 | Copy guard unit tests with threshold fixtures. Coordinator test: copied result → `context_copied` → faithful insert. Live corpus adversarial subset |
| FR-014 | History retry test: the stored snapshot is sent byte-identical (hash match) with no reader call |
| FR-015, FR-016; SC-007 | Every coordinator path writes an outcome row. Cascade deletion test. Content-free log/metric test. History detail view model test |
| FR-018 (P3) | Category map and override tests. Server prompt test. Category corpus items |
| FR-019, FR-020; SC-004, SC-006 | `test-context-quality.py` in `make check`. `acceptance/evaluation.md` and the latency rerun on the reference setup. The Settings label stays "Experimental" until the evaluation file records a pass |

Run `make check` after changes. It proves deterministic behavior only; live capture, evaluation and resource steps are in [quickstart.md](quickstart.md).

## Complexity tracking

No constitution violations. The `rewrite_attempts` rebuild is the one non-additive schema change. It is needed because SQLite cannot widen a `CHECK` constraint in place, and it keeps the stored protocol version honest.
