# Controlled processing comparisons and mixed-language status

Date: 2026-09-17. Scope: T042. All runs use the pinned Parakeet v3 model (`7dd20fe6…edfe`), FluidAudio 0.15.7, automatic language with no hint, Apple M5, macOS 26.6.2 (25G83), AC power, working tree at `4680c54` with uncommitted Feature 002 changes. Frozen manifests: short `10b9873c…988b` (110 fixtures), long-form `53b0a220…5f97` (25 fixtures). Speech content is never quoted here; fixture IDs, counts, sample offsets and hashes only.

## One factor at a time

The comparisons below already existed or were run for this task. Each changes one processing factor against a stated reference while the model, audio, language setting and scorer stay fixed.

| Comparison | Factor changed | Reference | Candidate | Where |
| --- | --- | --- | --- | --- |
| Assembly replay | join algorithm only (saved raw windows replayed, no inference) | T014 historical splice | anchored overlap assembler | [assembly.md](assembly.md) |
| Window geometry | overlap 32,000 → 0 (stride 207,360 → 239,360) | T014 historical run | `contiguous-fixed` | [chunk-planner-final.md](chunk-planner-final.md) |
| Boundary placement | contiguous fixed → VAD-chosen cut in a bounded region | `contiguous-fixed` | `vad-min`, `vad-preferred` | [chunk-planner-final.md](chunk-planner-final.md) |
| Normalization stage | formatting N001–N006 with the empty vocabulary added after assembly | `contiguous-fixed` | `production` (this task) | below |
| Decoder | none | — | — | not varied: the pinned SDK exposes one decode path; the empty-tail diagnosis probed CPU-only and one-frame-advance decoding on one interval and found no output change ([empty-tail-diagnosis.md](empty-tail-diagnosis.md)) |

The original default (overlap 32,000, historical splice) was preserved as the immutable T014 evidence and is still the reference for regressions.

## Production pipeline run

`scripts/evaluate-production-pipeline.sh` ran the production stage chain twice per corpus. Run hashes: short a `cb57ea9f…14ef`, short b `f5efef88…dd3f`; long a `2b79ffa9…746d`, long b `4a75a029…31d7c`. Score-report hashes are in [quality-results.md](quality-results.md).

- Determinism: 0 of 110 and 0 of 25 fixtures changed any stage hash or status between passes; every run rescored byte-identically.
- Against `contiguous-fixed` (run `ee2a8408…30dc4` short, `e405e808…d209a` long): assembled text identical on all 135 fixtures, so the normalization factor is isolated cleanly.
- Normalization effect on the corpora: **0 of 135** normalized outputs differ from their assembled input. N001–N004 found nothing to change in Parakeet output that is already NFC, LF-only, single-spaced and comma-spaced. 0 completion reasons, 0 unexpected replacements. Normalization time: median 0.15 ms, maximum 0.31 ms (short); median 1.05 ms, maximum 2.31 ms (long).
- Seams: 143 short and 183 long chunks, maximum 12 per fixture, 0 assembler lexical discards, 0 uncertain seams, 0 conflicting edge tokens, 0 incomplete results.

### Category scores, normalized stage (WER / CER)

| Category | n | T014 historical | Production | Δ WER points |
| --- | ---: | ---: | ---: | ---: |
| legacy_en | 10 | 0.076555 / 0.025717 | 0.076555 / 0.025717 | +0.000 |
| legacy_sk | 10 | 0.105820 / 0.030622 | 0.111111 / 0.039234 | +0.529 |
| public_en_general | 20 | 0.062361 / 0.024492 | 0.062361 / 0.024492 | +0.000 |
| public_sk_general | 20 | 0.108374 / 0.030433 | 0.118227 / 0.036862 | +0.985 |
| public_technology | 10 | 0.132530 / 0.034578 | 0.136546 / 0.040802 | +0.402 |
| public_entity_numeric | 10 | 0.125000 / 0.049812 | 0.125000 / 0.049812 | +0.000 |
| public_sk_accented_en | 10 | 0.261062 / 0.184701 | 0.261062 / 0.178172 | +0.000 |
| public_sk_longer | 10 | 0.154054 / 0.045537 | 0.200000 / 0.065825 | +4.595 |
| legacy_synthetic_stress (synthetic) | 10 | 0.238693 / 0.124514 | 0.329146 / 0.208658 | +9.045 |
| public_sk_60_90 (long-form) | 10 | — | 0.152408 / 0.072314 | — |
| public_sk_120_180 (long-form) | 10 | — | 0.181882 / 0.089055 | — |
| public_en_60_180 (long-form) | 5 | — | 0.063625 / 0.042601 | — |

Per fixture against T014 (short corpus): 1 improved, 19 regressed, 90 unchanged; largest regression +0.371429 absolute WER (`mixed-01`), largest improvement −0.023256.

## Gates

| Gate | Result | Basis |
| --- | --- | --- |
| English original set WER ≤15% | **met**: 7.66% | legacy_en, 10 fixtures, 209 reference words |
| Slovak original set WER ≤15% | **met**: 11.11% | legacy_sk, 10 fixtures |
| ≤1 point regression vs. reproduced baseline, English | **met**: +0.000 | legacy_en and public_en_general |
| ≤1 point regression vs. reproduced baseline, Slovak | **not met**: public_sk_longer +4.595; legacy_sk +0.529 and public_sk_general +0.985 are within the point | production vs T014 |
| Inherited mixed-language ≤15% target | **not met and not measurable on authentic speech**: no authentic mixed fixtures exist; synthetic stress is 32.91% and does not count | [coverage-gaps.md](coverage-gaps.md) |

The `quality-gates.py` module reports the two original-set checks as `null` because it looks for categories named `original_english`/`original_slovak` while the frozen manifest names them `legacy_en`/`legacy_sk`. The values above were computed from the same score report by category; the gate module was not changed for this task so the frozen scoring path stays identical to T014.

## Where the regressions are

All 19 regressed short fixtures have two windows; none of the 77 single-window fixtures changed. The regression is concentrated in the terminal chunk:

- 16 of 19 regressed fixtures return fewer words from the production tail window than the historical tail window, which starts 32,000 samples earlier and therefore carries 2 s of preceding context.
- 13 of the 33 two-window fixtures return an **empty** production tail. In 9 of those the historical tail returned 2–14 words (`mixed-01` 14, `mixed-04` 7, `public-eeb45b3b…` 6, `sk-02` 6, `public-6643d06c…` 4, `public-310901c0…` 4, `public-bde1eb90…` 3, `mixed-07` 2, `public-a6de23ba…` 2); in 4 both were empty.
- `mixed-01` alone accounts for the largest delta: its 91,040-sample (5.69 s) tail decoded to nothing, versus 14 words from the 123,040-sample historical tail; deletions went from 5 to 19 of 35 reference words.
- Regressed tails have a median length of 62,240 samples; unchanged two-window tails a median of 14,080 samples (the very short tails were often empty under both geometries).

This is the mechanism already isolated in [empty-tail-diagnosis.md](empty-tail-diagnosis.md): the joint model predicts blank for the entire isolated tail, before any assembly or filtering. It is a recognition-context effect of contiguous windowing, not a join failure; the assembler discarded nothing. The historical overlap masked it by re-decoding the last 2 s of the previous window together with the tail.

### Switch-local omissions

The synthetic mixed fixtures place the language switch (250 ms silence between the two source clips) at 96,160–232,480 samples, which is **inside the first window** for every one of the ten; the nearest switch sits 6,880 samples before the 239,360 boundary (`mixed-05`). So none of the synthetic regressions is at a switch: they are the same tail-window omissions as the monolingual Slovak regressions. Eight of ten synthetic fixtures regressed (+2.1 to +37.1 points), two are unchanged (`mixed-07`, `mixed-08`). Per-seam: 10 seams, 0 uncertain, 0 discards, 0 conflicting edges. No claim about authentic within-speaker switching follows from this; there are no such fixtures.

## Uncertainty

- The corpus is small: 10–20 fixtures per category, 30–50 reference words each, so single-fixture events move a category by several points (one 5-word loss in a 37-word fixture is 13.5 points on that fixture).
- No human meaning review exists for any stage; WER counts deletions of function words and of content words alike.
- The evaluation harness reproduces the production geometry, assembler and normalizer stage by stage but is not the app's `WindowedTranscriber.transcribeProduction` path; the coordinator tests assert that path uses the same window plan (13 windows for 180 s) and the same assembler/normalizer versions.
- Read/parliamentary speech does not represent personal microphone dictation, which the owner reports works better in practice ([owner-priorities.md](owner-priorities.md)). That report is not a measurement.
