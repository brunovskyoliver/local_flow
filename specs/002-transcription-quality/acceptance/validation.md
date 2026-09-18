# Public baseline validation

`make check` passed after both 110-fixture recognition runs. The private log is `build/quality-public-baseline-logs/make-check.log`. This includes Swift format lint, shell syntax, foundation validation, historical scoring tests, 25 v2 scoring tests, five acquisition tests, plist validation, Go checks and deterministic XCTest. `git diff --check` also passed.

Opt-in recognition was run separately twice with the already provisioned Parakeet model and frozen public manifest. Every result file matched exactly across runs. Both runs were scored twice with byte-identical output. Independent corpus reconstruction matched all 110 WAVs and the manifest. See [baseline.md](baseline.md) for hashes, category scores and the 15 incomplete outcomes retained in both runs.

This validates T013/T014 public-baseline completion. It does not close T048's later full-feature integration, human meaning review, genuine code-switching coverage, signed-app behavior or hardware/resource acceptance. Optional Common Voice access remains untested with real authorized inputs.

## Focused chunk-planner acceptance

`make check` passed again on 2026-09-17 after the long-form acquisition, separate VAD
capability/provisioning, evaluation-only planner changes, corrected terminal-fragment rule,
ADR/spec clarification and final evidence were complete. It ran 7 historical scorer tests, 25
current scorer tests, 12 acquisition tests, plist/project validation, Go checks and the full
deterministic XCTest suite. `git diff --check`, shell syntax checks and Python compilation also
passed. Real-model runs and the measured VAD probe remain opt-in evidence and are not executed
by `make check`; their results are in [chunk-planner-final.md](chunk-planner-final.md).

## Phase 4 persistence and recovery, 2026-09-17

T016–T020 and T022–T023 are complete; T024 remains open at the production assembly/provenance integration gate. [Phase 4 evidence](phase4-persistence.md) records the implemented bounds, transactional behavior, recovery tests and explicit production limitation. `make check` passes with 261 XCTest passes, 9 skips and no failures. No speech-quality, signed-app or resource acceptance is inferred from these checks.

## Phase 5 independent formatting and history detail, 2026-09-17

`make check` passes after T026–T028/T030–T031: **273 XCTest passed, 10 skipped, 0 failed**. Result bundle: `build/DerivedData/Logs/Test/Test-LocalFlow-2026.09.17_11-26-01-+0200.xcresult`. The run also passed Swift formatting, shell syntax, JSON/artifact/document-link checks, 7 historical scorer tests, 25 quality scorer tests, 12 acquisition tests, plist validation and Go tests/vet. `git diff --check` passes. Private output is in `build/phase5-check.log`.

The first tests failed on missing normalizer/selected-detail APIs. A later corruption-test setup was rejected by SQLite's existing CHECK constraint; the test now deliberately bypasses that constraint to simulate a damaged record and verify bounded read rejection. No production constraint was relaxed.

[Phase 5 evidence](normalization.md) records the independent implementation and limits. T029 remains blocked by T024's unresolved production gate; ordinary dictation still has no quality detail and does not run the new normalizer. T032 remains open for signed-app interaction and exact-hash human meaning reviews. Skipped opt-in tests establish no speech-quality, hardware or signed-app acceptance. No new inference experiments, model downloads, server/wire changes or architecture exceptions were introduced.

## Production pipeline integration, 2026-09-17

T024/T029 are implemented under the owner's revised priorities. `make check` passes: **280 XCTest passed, 10 skipped, 0 failed**, alongside Swift formatting, shell syntax, JSON/artifact/document-link checks, 7 historical scorer tests, 25 quality scorer tests, 12 acquisition tests, plist validation and Go tests/vet. Private log: `build/pipeline-check.log`. `git diff --check` and the final documentation validation pass.

[Production integration evidence](production-integration.md) records tests, fixed contiguous geometry, bounded whole-envelope recovery and the signed development launch. The signed executable was installed at `/Applications/LocalFlow.app`, verified and opened through the menu bar. T032 remains open for practical owner speech feedback and signed keyboard/accessibility acceptance. No new corpus comparison, measured resource acceptance or within-sentence switching test is claimed.

## Phase 7 cross-cutting acceptance, 2026-09-17

`make check` passes on the Phase 7 state: **323 XCTest passed, 10 skipped, 0 failed** (result bundle `build/DerivedData/Logs/Test/Test-LocalFlow-2026.09.17_15-19-07-+0200.xcresult`, private log `build/phase7-check.log`). The run also passed Swift formatting, shell syntax for every script including the new `evaluate-production-pipeline.sh`, foundation/document-link validation, 7 historical scorer tests, 25 quality scorer tests, 12 acquisition tests, plist validation and Go tests/vet. `git diff --check` passes. `scripts/test-transcription-quality.py` has been part of `scripts/test.sh` since the US1 increment; no change to the check script was needed.

New deterministic tests this phase: `ResourceRecorderTests.testProcessingMetricsAreLabeledBoundedAndContentFree` and the extended `ResourceLifecycleTests.testBenchmarkRecordsEveryCycleWithMeasuredValues`. The chunk-experiment harness gained an opt-in normalized stage (`LOCALFLOW_CHUNK_NORMALIZE=1`) that `make check` never exercises.

### Gate separation

| Gate | Kind | State |
| --- | --- | --- |
| Deterministic XCTest, scorer, acquisition, Go, formatting | `make check` | passed |
| Production pipeline on frozen corpora, two runs, double rescoring | opt-in real-model run, executed locally | done; results in [quality-results.md](quality-results.md) |
| Original-set English/Slovak ≤15% | corpus | met (7.66% / 11.11%) |
| ≤1-point regression vs. T014 | corpus | English met; Slovak **failed** on `public_sk_longer` (+4.595), recorded, not relabeled |
| Inherited mixed ≤15% | corpus | not measurable (no authentic fixtures); synthetic 32.9% does not count |
| Human meaning reviews | reviewer | **blocked**: none available; templates generated with exact hashes |
| Signed-app offline/recovery (T045, SC-008) | owner machine | **blocked**: not run; checklist in [offline-recovery.md](offline-recovery.md) |
| M5 20-cycle resource protocol (T046) | owner machine | **blocked**: not run; plan and units in [resources.md](resources.md) |
| Alternative engine (T043, SC-007) | decision | no experiment; retention recorded in [engine-experiments.md](engine-experiments.md) |
| Vocabulary held-out acceptance (T040) | owner/reviewer | still open from Phase 6 |
| Practical owner feedback (T032) | owner | still open from Phase 5 |

### Constitution recheck

Server code and wire schema are untouched in this feature (`git diff --stat -- server` is empty). Model provisioning still happens only through an explicit user-initiated import or pinned, hash-verified download; the new evaluation script takes a provisioned model root and validates corpus locks before running, and downloads nothing. No LLM rewriting stage exists anywhere in the pipeline: the only text transformations are the deterministic N001–N006/V001 rules with recorded IDs. No VoiceInk source is present in the repository. The recorder still has no string field a caller can populate, so the new metrics cannot carry speech or vocabulary content. No new architecture exception was needed.
