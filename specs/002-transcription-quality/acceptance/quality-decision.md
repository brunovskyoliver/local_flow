# Quality decision

Date: 2026-09-17. Scope: T047. Disposition: **retain** Parakeet v3 / FluidAudio 0.15.7 as the only engine, with the fixed contiguous production pipeline as integrated by T024/T029. No replacement and no fallback are recommended. This document is reviewed by the owner when they accept it; until then it is the implementer's proposed decision.

## Reproduction

```sh
scripts/evaluate-production-pipeline.sh build/quality-public-v2 build/quality-public-long-v1 \
  build/production-acceptance build/model-downloads/parakeet-v3-7dd20fe6b1797d35f5e3307e8b1732d9a178edfe
python3 scripts/transcription-quality.py compare build/quality-public-v2/manifest.json \
  build/quality-public-v2-baseline/run-a build/production-acceptance/production-short-a \
  build/production-acceptance/scores/compare-historical-vs-production-short.json
python3 scripts/transcription-quality.py score --baseline build/quality-public-v2-baseline/run-a \
  --repeat build/production-acceptance/production-short-b build/quality-public-v2/manifest.json \
  build/production-acceptance/production-short-a build/production-acceptance/scores/production-short-gated.json
```

Run hashes: production short `cb57ea9f…14ef` / `f5efef88…dd3f`, long `2b79ffa9…746d` / `4a75a029…31d7c`; T014 historical `29cd6f5d…82be`; contiguous-fixed `ee2a8408…30dc4` / `e405e808…d209a`. Compare report `c0865ee5…0cb5`; gated report `d13d3362…ad35`. Full hashes are in [quality-results.md](quality-results.md).

## Absolute counts

Short corpus, normalized stage, production vs T014 historical (substitutions / deletions / insertions over reference words):

| Category | Fixtures | Ref. words | T014 S/D/I | Production S/D/I | WER T014 → production |
| --- | ---: | ---: | --- | --- | --- |
| legacy_en | 10 | 209 | 8/5/3 | 8/5/3 | 0.076555 → 0.076555 |
| legacy_sk | 10 | 189 | 14/3/3 | 14/4/3 | 0.105820 → 0.111111 |
| public_en_general | 20 | 449 | 21/3/4 | 21/3/4 | 0.062361 → 0.062361 |
| public_sk_general | 20 | 406 | 36/3/5 | 38/3/7 | 0.108374 → 0.118227 |
| public_technology | 10 | 249 | 28/3/2 | 27/5/2 | 0.132530 → 0.136546 |
| public_entity_numeric | 10 | 200 | 21/1/3 | 21/1/3 | 0.125000 → 0.125000 |
| public_sk_accented_en | 10 | 226 | 24/17/18 | 25/16/18 | 0.261062 → 0.261062 |
| public_sk_longer | 10 | 370 | 39/11/7 | 50/14/10 | 0.154054 → 0.200000 |
| legacy_synthetic_stress | 10 | 398 | 49/39/7 | 55/72/4 | 0.238693 → 0.329146 |

Per fixture: 90 unchanged, 19 worse, 1 better. Every changed fixture has two windows; the loss is in the terminal chunk (13 empty production tails among 33 two-window fixtures, 9 of them non-empty under the historical overlap). Long-form (25 fixtures, 183 chunks): 0.154495 overall WER, 0 incomplete, 0 seam discards; no historical comparison exists for this corpus. Details and per-fixture lists: [mixed-language.md](mixed-language.md).

## Gates

### SC-003 mixed-language closure

Path (a), ≥20% relative authentic mixed WER improvement, is **not available**: there is no authentic mixed set. Path (b), a reviewed decision report, is this document. It localizes the failures (terminal-chunk blank decoding under contiguous windows, not seams, not switches), records the controlled comparisons (assembly replay, window geometry, boundary placement, normalization; decoder not variable) and justifies retaining the engine below. The **inherited mixed-language ≤15% target is not met**: it cannot be measured on authentic speech, and the synthetic stress subset (32.9%) does not count toward it. A decision report never passes that target.

### SC-007 adoption gates

A candidate engine was evaluated after the original decision. The complete result is in [whisper-benchmark.md](whisper-benchmark.md). Whisper does not satisfy an adoption bar: its few short-category improvements are accompanied by large long-form and mixed-language regressions, higher engine and combined RSS, and materially higher latency. The run was one pass per mode, so it is not three-repeat SC-007 adoption evidence. No replacement or fallback is proposed.

### Regression gates that remain failed

`public_sk_longer` regresses 4.595 points against T014 and `legacy_synthetic_stress` 9.045 points. These stay recorded as failed; they are not relabeled and no threshold is widened. The owner's priority revision defers them as release gates for this increment; it does not pass them.

## Why retain

1. The regressions are attributable to one mechanism that the current engine exhibits under one geometry, and the same engine under the historical overlap does not show it. The fix, if pursued, is a bounded change to how the tail window is presented to the decoder (for example decoding the final chunk with preceding context and keeping only the new span with proof, or a VAD-guided tail boundary as `vad-min` showed on long-form). That is a planner/assembler question, not an engine question, and the owner has asked that no new parameter search start now.
2. The retained pipeline satisfies the non-negotiable invariants the owner set: exact sample coverage, zero lexical discards, no unproven deletions, raw evidence saved, deterministic output across two runs, bounded memory and time. English is unchanged across every category. Slovak general speech is within one point.
3. An alternative engine would need provisioning, licensing, ownership tests, a target category and three resource repeats before it could even be compared, and the target category that motivates a fallback (authentic switching) has no fixtures.

## Uncertainty and limitations

- Ten-fixture categories: one fixture with a lost tail moves a category by up to 4–5 points. `public_sk_longer`'s 4.6-point loss is 17 additional errors across 10 fixtures, concentrated in 7.
- No human meaning verdicts. WER does not distinguish a dropped filler from a dropped negation.
- The evaluation harness mirrors the production stages rather than executing `WindowedTranscriber.transcribeProduction`; coordinator tests pin the same geometry and stage versions.
- Read/parliamentary corpora vs. personal dictation; the owner's practical experience is reported as better but unmeasured.
- Resource acceptance ([resources.md](resources.md)) and signed-app offline acceptance ([offline-recovery.md](offline-recovery.md)) are not run; this decision does not depend on them but full feature acceptance does.

## Recommended next bounded work, outside this increment

Only if the owner reopens accuracy work: a single controlled experiment on terminal-chunk decoding context, scored on the same frozen corpora against `cb57ea9f…14ef`, with the zero-discard invariant kept. No engine change.
