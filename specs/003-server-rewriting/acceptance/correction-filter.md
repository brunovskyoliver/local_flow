# Correction filter validation

2026-09-17, native arm64 macOS test run. `make check` passed after the final source changes.

- Swift format lint, shell syntax, foundation/Spec Kit/documentation validation and plist validation passed.
- Python regression suites passed: dictation accuracy 7, transcription quality 25, corpus acquisition 12, rewrite quality 6 (50 total).
- Go tests and vet passed for all five server packages.
- Feature 001/002/003 XCTest: 477 tests, 466 passed, 11 skipped, 0 failed.
- Result bundle: `build/DerivedData/Logs/Test/Test-LocalFlow-2026.09.17_21-14-23-+0200.xcresult`.
- Eleven new test methods in `CorrectionLearnerTests.swift` cover scoring tables, Unicode normalization, hard exclusions despite repetition/canonical evidence, history saturation/eviction, watcher filtering, repeated suggestions, capacity refusal, existing canonical/duplicate handling, passage bounds and disable during observation. Existing detection, conflict and Undo tests remain; Undo now uses Odoo instead of ordinary Hello capitalization.

## Convergence

CF01–CF05 are complete. Candidate assessment sits between settled detection and vocabulary mutation. The 90-second window, 1–3-word diff and two-read settling rule remain. Boundary punctuation trimming preserves literal markers so `/odoo` cannot become an apparent name. Suggestions remain internal with no write or UI. Existing canonical/alias conflicts and capacity refusals retain the existing rejected outcome. Auto-learn retains the notice and Undo.

Bounds: 256 bytes per candidate side, at most three tokens per side, at most 512 canonical terms inspected, 128 digest-only history entries, counts saturating at three. Last-seen order determines eviction. No correction text is logged, transmitted or persisted in candidate history. No ResourceRecorder correction channel existed, so no new telemetry channel was introduced.

Conservative limits: unknown lowercase spelling and morphology edits without canonical evidence are ignored. Proper-name detection is a casing/identifier heuristic, not a complete dictionary or semantic classifier. Common-word lists are intentionally small. Dotted technical names are rejected with other protected literals. A new alias for an existing canonical entry remains rejected by the existing conflict policy; this increment does not add entry-merging or change Undo semantics. Suggestions have no approval UI in this increment.

No architecture exception, dependency, datastore, network operation or model was introduced. Hardware acceptance, RSS and scoring-latency measurements were not collected and are not claimed by this validation.
