# Implementation baseline: application context for dictation

Recorded on 2026-09-24 at the start of implementation, before any Feature 012 code existed. This file states the starting point only. No capture latency, rewrite latency, quality or memory figure exists yet. Each is recorded later in its own acceptance file (`capture-latency.md`, `evaluation.md`, `rewrite-latency.md`, `memory.md`).

## Starting point

| Item | Value |
| --- | --- |
| Branch | `analysis-notes-pipeline` (the Git branch does not match the feature identifier; `.specify/feature.json` selects the feature) |
| Starting commit | `035438bcf1fe663cc2602f397eec1aaf81229cde` (`LocalFlow: summary server settings and client analysis updates`) |
| Working tree | Dirty: 25 paths differ from the starting commit (22 modified, 3 untracked). The modified files are uncommitted UI work (fonts, `Appearance.swift`, meeting, history, dictionary, onboarding and settings views, `project.pbxproj`, `CorrectionLearner`) plus `THIRD_PARTY_NOTICES.md` and `docs/adr/README.md`. The untracked paths are `apps/macos/LocalFlow/Resources/Fonts/`, `docs/adr/0023-rewrite-protocol-v2-reference-context.md` and `specs/012-app-context-awareness/`. No Feature 012 source file was present. Feature 012 also edits three of the already-modified files: `project.pbxproj`, `SettingsView.swift` and `TranscriptionDetailView.swift`. |
| Feature selection | `.specify/feature.json` → `specs/012-app-context-awareness` |

## Toolchain and dependency pins

| Item | Value |
| --- | --- |
| macOS (development machine) | 27.0 on `Mac17,2` |
| Xcode | 26.4.1 (build 17E202) |
| Go | 1.23.4 darwin/arm64 (`server/go.mod`: `go 1.23.0`) |
| GRDB.swift | 7.10.0 (exact version in `project.pbxproj`) |
| Reference flowd backend | MTPLX through flowd's OpenAI-compatible adapter (Feature 003, `acceptance/phase-9.md` and `phase-10.md`) |
| Reference model | Last served model recorded in Feature 003: `youssofal-qwen3.5-4b-mtplx-optimized-speed` (`phase-10.md`). The model for the Feature 012 evaluation is recorded in `evaluation.md` when the live run happens. |

No client or server dependency is added by this feature.

## `make check` before any Feature 012 change

Run on the dirty tree above. Every step before XCTest passed. XCTest: 1,346 passed, 23 skipped, 3 failed. The three failures are opt-in model tests that ran on this machine and failed on local model inputs, not on dictation code:

- `RuntimeCompatibilityTests/testOptInPinnedRuntimeLoadsDecodesAndReleases()`: caught error "unavailable"
- `WhisperBenchmarkTests/testOptInWhisperLargeV3TurboFrozenCorpusBenchmark()`: caught error "storage"
- `WhisperBenchmarkTests/testOptInWhisperNativeFrozenCorpusBenchmark()`: caught error "storage"

Later runs are compared against this set.

## Constitution scope check

Checked against `.specify/memory/constitution.md` 1.0.0 before writing code:

- Principles 1 and 14: all client additions are Swift files in the existing `LocalFlow` and `LocalFlowTests` targets, using AX, AppKit, Foundation and CryptoKit. No package, web view or client runtime.
- Principles 2 and 6: every snapshot part, the term list, the serialized snapshot (8,192 bytes), the spelling change list (64) and the capture time (250 ms deadline, 100 ms per AX call) are bounded. One read per dictation; no queue or cache.
- Principle 3: `ModelLifecycleCoordinator` and recognition input are untouched.
- Principles 4 and 5: context capture and the rewrite context toggle are both off by default. Context spelling is offline. Snapshot text, titles, terms and bundle IDs never enter logs or metrics.
- Principles 7 and 9: one migration (`app-context-v11`), one cascading table, the `rewrite_attempts` rebuild under GRDB's deferred foreign-key check, and the context row committed in the entry's transaction so the unsaved-text recovery covers it.
- Principles 11, 12, 13: the snapshot has a versioned, closed shape; `AppContextReading` has a fake; capture duration, outcome, part sizes and term count are recorded as numbers only.

No exception is requested. ADR 0023 already exists and covers the protocol v2 change delivered in Phase 5.

## After Phases 1–4 (T001–T031)

`make check` on 2026-09-24: every pre-XCTest step passed, including `swift format lint --strict`. XCTest: 1,410 passed, 23 skipped, 3 failed. The failures are the same three opt-in tests as the baseline (`RuntimeCompatibilityTests/testOptInPinnedRuntimeLoadsDecodesAndReleases` "unavailable", `WhisperBenchmarkTests/testOptInWhisperLargeV3TurboFrozenCorpusBenchmark` and `testOptInWhisperNativeFrozenCorpusBenchmark` "storage"). No capture latency, memory or hardware measurements were collected; fake readers and a scripted AX source do not count as measurements.

## After Phases 5–8 (T032–T058)

Checks on 2026-09-24, working tree based on `035438bcf1fe663cc2602f397eec1aaf81229cde`:

- Every `make check` step before XCTest passed: `swift format lint --strict`, shell syntax, the three import checks, `validate-foundation.py`, the six Python test scripts including the new `test-context-quality.py`, `plutil -lint`, `gofmt`, `go test ./...` and `go vet ./...`.
- XCTest was not run as one unscoped suite, because the full suite beeps on this machine. Instead, 31 suites covering the changed code ran with `-only-testing`: all context, rewrite, storage, history, settings, preferences, dictation coordinator, protected literal, quality evaluation and resource recorder suites. Result: 462 executed, 1 skipped (the opt-in spelled-corpus export), 0 failures. The full-suite comparison with the three known opt-in failures above is still to be run.
- The quickstart walkthrough was not performed; it needs the signed app (see `privacy.md`, `capture-latency.md`, `memory.md`).
- Live evaluation: [evaluation.md](evaluation.md). SC-001 and SC-002 pass, SC-003 passes pending owner review, SC-004 fails, and Story 4 formatting fails. The context rewrite and style toggles keep their Experimental labels.
