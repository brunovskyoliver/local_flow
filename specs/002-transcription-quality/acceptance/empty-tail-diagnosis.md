# Empty-tail runtime diagnosis

Date: 2026-09-17. T024 remains open. The reopened investigation reproduces the exact failure and identifies its immediate mechanism: the pinned joint model selects blank throughout the tail decode. No safe production correction was established.

## Reproducer

The opt-in `RuntimeCompatibilityTests.testOptInEmptyTailRecognition` verifies the frozen manifest hash and fixture audio hash, reads only the bounded requested interval through AVAudioFile, provisions verified local weights and calls the production runtime through ModelLifecycleCoordinator. The tail is samples 207,763–263,040 of `public-da85b5ebc08e9db2f3ec`. Assertions contain no transcript text. The test requires nonempty recognition for this known speech-containing fixture only; it does not impose that rule on arbitrary silence.

Run from the repository root with a new output directory:

```sh
scripts/diagnose-empty-tail.sh \
  build/model-downloads/parakeet-v3-7dd20fe6b1797d35f5e3307e8b1732d9a178edfe \
  build/quality-public-v2 build/empty-tail-diagnosis/final-repro fresh
```

The command above was run after restoring the runtime and failed in 15 seconds inside XCTest. Use a new output directory when repeating it. Its failure was: `XCTAssertFalse failed - Frozen speech-containing tail returned empty recognition`. Use `sequential` instead of `fresh` to first decode samples 0–207,763. The initial sequential test took 16.6 seconds inside XCTest and failed specifically on the tail assertion. Repeated fresh runs also failed. Model verification/build/test startup adds overhead.

Removing the first decode retains the symptom, so a previous utterance and its state are unnecessary. This is a one-window runtime reproducer, with no planner, assembler, scoring or token-splicing dependency. The exact saved interval was preserved rather than searching for new geometry.

## Predictions and observations

The initial hypotheses were incorrect frame bounds, all-blank model decisions, or emitted tokens removed later. Temporary numeric-only instrumentation in the pinned SDK distinguished them. The checkout was clean before instrumentation and restored afterward. No transcript, token ID or audio sample was logged by these probes.

| Probe | Start / effective end frame | Joint decisions | Blank decisions | Emitted tokens |
| --- | --- | ---: | ---: | ---: |
| Original `.all` compute, fresh state | 0 / 44 | 26 | 26 | 0 |
| Force every blank advance to one frame | 0 / 44 | 44 | 44 | 0 |
| CPU-only, original duration advances | 0 / 44 | 20 | 20 | 0 |
| Original `.all`, probability probe | 0 / 44 | 26 | 26 | 0 |

The encoder reports 45 frames; the existing actual-audio bound admits 44. The decoder starts at zero and reaches that bound. It does not return early because of a carried time jump. Every emitted-token count is zero before token processing, ruling out subsequent text filtering or assembly as the cause of this empty result.

One-frame advances test whether predicted blank durations jump over detectable speech. All 44 frame decisions remain blank. CPU-only inference also remains empty, although its duration trajectory differs (20 decisions versus 26); this is not a claim of numerical equivalence across compute paths. The original-path joint probabilities are all finite, ranging from 0.4453125 to 1.0. This rules out non-finite joint probabilities for this run, not every possible internal numerical defect.

[Sanitized evidence](empty-tail-diagnosis.json) records counts, frame bounds, SDK revision and trace hashes. Local logs, numeric traces, diagnostic patch and original source backups are under ignored `build/empty-tail-diagnosis/`. The temporary SDK instrumentation, one-frame override and CPU-only application change were removed. The application runtime was restored byte-for-byte to its pre-investigation contents.

## Decision

This narrows "empty second decode" to reproducible blank predictions for the same isolated speech-containing audio. It does not establish why the acoustic encoder/joint model prefers blanks, or prove a model defect rather than context sensitivity. Frame entry, previous-call state, duration skipping and later deletion do not explain this reproducer. Changing padding, thresholds, geometry or selecting a different model without a justified correction would reopen a parameter search, not finish this diagnosis.

No production fix or T024 integration is justified by these results. The longer-Slovak gate remains independently unresolved. No acceptance threshold, reference, scorer, model artifact or production behavior was changed. No Phase 5 work started. The retained opt-in regression test provides a direct check for a future runtime/model correction, but nonempty output alone will not prove that the missing words are correct or satisfy corpus acceptance.

## Validation and constitution

Real-model inference was performed locally for this bounded diagnosis. It is separate from signed-app, hardware/resource and full-corpus acceptance; none of those gates is claimed here. The test uses the existing lifecycle owner, sequential bounded audio reads and local model provisioning. No architecture exception is needed. Existing worktree changes were preserved.

`make check` passed after restoring the runtime, including deterministic XCTest. The new inference test skips without its explicit environment variables; that pass does not erase its opt-in failure. `git diff --check` passed. The dependency checkout is clean and the application runtime matches the pre-investigation backup byte-for-byte.
