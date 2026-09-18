# Chunk-geometry experiment (Feature 002, before production assembler integration)

Verified 2026-09-17. The frozen T013/T014 corpus, references, scorer rules, acceptance thresholds,
model weights and every decoding parameter unrelated to chunk geometry are unchanged. No
normalization, vocabulary, server or alternate-engine work was started. This experiment does not
adopt any strategy; it measures them.

## Method

`ChunkPlanner` (new, pure, production target) emits chunk geometry from an injected bounded
silence probe. `QualityChunkExperiment` (evaluation only) drives recognition chunk by chunk from
the existing `AudioSpool`, records unchanged SDK evidence per chunk with its real sample start,
and assembles with the unchanged `TranscriptAssembler` evidence rules. Audio is never fully
resident: at most one chunk (239,360 float samples, about 957 KB) plus one bounded silence search
region. One ASR model instance is used sequentially; the silence probe is the FluidAudio Silero
VAD behind the same audio abstraction, loaded from a provisioned directory with no download.

`TranscriptAssembler` changed in exactly one way: `overlapping` no longer requires the 207,360
sample stride, because a strategy may produce any forward overlap. No evidence rule was weakened.

### Window-budget arithmetic (binding constraint)

The assembler admits 14 windows and 180 s. A silence cut is contiguous, so its stride is the chunk
length itself, and the worst case is fourteen minimum-length contiguous chunks:
`ceil(2,880,000 / 14) = 205,715` samples (12.857 s). That is `ChunkPlanner.minimumStride`, the
floor of every silence search band and the cap on overlap
(`239,360 - 205,715 = 33,645` samples, 2.103 s). The first experiment pass used 203,127, which is
correct only for purely overlapped geometry and can emit a fifteenth window; it was corrected and
the affected strategies re-run. Overlap therefore cannot exceed 2.103 s without changing the
bounded-state contract, so "longer overlap" has 0.103 s of headroom, not a free parameter.

## Strategies

| Strategy | Max input | Overlap | Silence search band | Probe rule | Fallback |
| --- | --- | --- | --- | --- | --- |
| `control` | 239,360 | 32,000 | none | none | overlapped fixed window |
| `longer-overlap` | 239,360 | 33,645 | none | none | overlapped fixed window |
| `vad-overlap-fallback` | 239,360 | 32,000 | [205,715, 239,360] samples | threshold 0.5 | overlapped fixed window |
| `vad-hybrid` | 239,360 | 0 | [205,715, 239,360] samples | threshold 0.5 | contiguous fixed cut |
| `vad-min` | 239,360 | 0 | [205,715, 239,360] samples | minimum | contiguous fixed cut |
| `vad-min-refined` | 239,360 | 0 | [205,715, 239,360] samples | minimum + 32 ms energy refine | contiguous fixed cut |
| `contiguous-fixed` | 239,360 | 0 | none | none | n/a |

All strategies keep the 4,800 sample padding minimum and the 239,360 sample model input.
`vad-min` needs no threshold: it cuts at the centre of the quietest 256 ms VAD frame in the band.

## Category results

Cells are assembled WER% / CER% / incomplete count. Raw-stage WER is not comparable across
strategies because the raw stage is the LF concatenation of received windows including overlap,
so it mechanically grows with overlap and vanishes with contiguous cuts; only `assembled` is
compared against frozen T014.

| Category | n | T014 | `control` | `longer-overlap` | `vad-overlap-fallback` | `vad-hybrid` | `vad-min` | `vad-min-refined` | `contiguous-fixed` |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| legacy_en | 10 | 7.66 / 2.57 / 0 | 7.66 / 2.57 / 0 | 7.66 / 2.57 / 0 | 7.66 / 2.57 / 0 | 7.66 / 2.57 / 0 | 7.66 / 2.57 / 0 | 7.66 / 2.57 / 0 | 7.66 / 2.57 / 0 |
| legacy_sk | 10 | 10.58 / 3.06 / 0 | 10.58 / 3.06 / 0 | 10.58 / 3.06 / 0 | 10.58 / 3.06 / 0 | 11.11 / 3.92 / 0 | 10.58 / 3.06 / 0 | 11.11 / 3.92 / 0 | 11.11 / 3.92 / 0 |
| legacy_synthetic_stress | 10 | 23.87 / 12.45 / 6 | 23.87 / 12.45 / 6 | 24.37 / 13.81 / 8 | 22.36 / 12.50 / 2 | 26.13 / 16.05 / 0 | 19.85 / 11.96 / 0 | 26.38 / 16.68 / 0 | 32.91 / 20.87 / 0 |
| public_en_general | 20 | 6.24 / 2.45 / 1 | 6.24 / 2.45 / 1 | 6.24 / 2.45 / 1 | 6.24 / 2.45 / 1 | 6.24 / 2.45 / 0 | 6.24 / 2.45 / 0 | 6.24 / 2.45 / 0 | 6.24 / 2.45 / 0 |
| public_entity_numeric | 10 | 12.50 / 4.98 / 2 | 12.50 / 4.98 / 2 | 13.00 / 5.08 / 2 | 12.50 / 4.98 / 2 | 12.50 / 4.98 / 0 | 12.50 / 4.98 / 0 | 12.50 / 4.98 / 0 | 12.50 / 4.98 / 0 |
| public_sk_accented_en | 10 | 26.11 / 18.47 / 1 | 26.11 / 18.28 / 1 | 26.11 / 18.47 / 1 | 26.11 / 18.47 / 0 | 26.11 / 18.47 / 0 | 26.11 / 18.47 / 0 | 26.11 / 18.47 / 0 | 26.11 / 17.82 / 0 |
| public_sk_general | 20 | 10.84 / 3.04 / 2 | 13.79 / 6.73 / 4 | 14.29 / 6.82 / 4 | 13.79 / 6.73 / 4 | 11.82 / 3.69 / 0 | 11.82 / 3.69 / 0 | 11.58 / 3.43 / 0 | 11.82 / 3.69 / 0 |
| public_sk_longer | 10 | 15.41 / 4.55 / 2 | 22.43 / 11.27 / 6 | 24.05 / 11.32 / 6 | 21.08 / 10.14 / 5 | 19.46 / 6.18 / 0 | 18.11 / 5.73 / 0 | 19.46 / 6.18 / 0 | 20.00 / 6.58 / 0 |
| public_technology | 10 | 13.25 / 3.46 / 1 | 13.25 / 3.46 / 1 | 15.26 / 5.26 / 2 | 14.86 / 5.46 / 0 | 15.26 / 6.09 / 0 | 14.86 / 5.60 / 0 | 15.26 / 6.09 / 0 | 13.65 / 4.08 / 0 |

### Delta versus frozen T014 (WER percentage points / incomplete count)

The adoption gate is at most +1 pp WER and no increase in incomplete results.

| Category | `control` | `longer-overlap` | `vad-overlap-fallback` | `vad-hybrid` | `vad-min` | `vad-min-refined` | `contiguous-fixed` |
| --- | --- | --- | --- | --- | --- | --- | --- |
| legacy_en | +0.000 / +0 | +0.000 / +0 | +0.000 / +0 | +0.000 / +0 | +0.000 / +0 | +0.000 / +0 | +0.000 / +0 |
| legacy_sk | +0.000 / +0 | +0.000 / +0 | +0.000 / +0 | +0.529 / +0 | +0.000 / +0 | +0.529 / +0 | +0.529 / +0 |
| legacy_synthetic_stress | +0.000 / +0 | +0.503 / +2 **fail** | -1.508 / -4 | +2.261 / -6 **fail** | -4.020 / -6 | +2.513 / -6 **fail** | +9.045 / -6 **fail** |
| public_en_general | +0.000 / +0 | +0.000 / +0 | +0.000 / +0 | +0.000 / -1 | +0.000 / -1 | +0.000 / -1 | +0.000 / -1 |
| public_entity_numeric | +0.000 / +0 | +0.500 / +0 | +0.000 / +0 | +0.000 / -2 | +0.000 / -2 | +0.000 / -2 | +0.000 / -2 |
| public_sk_accented_en | +0.000 / +0 | +0.000 / +0 | +0.000 / -1 | +0.000 / -1 | +0.000 / -1 | +0.000 / -1 | +0.000 / -1 |
| public_sk_general | +2.956 / +2 **fail** | +3.448 / +2 **fail** | +2.956 / +2 **fail** | +0.985 / -2 | +0.985 / -2 | +0.739 / -2 | +0.985 / -2 |
| public_sk_longer | +7.027 / +4 **fail** | +8.649 / +4 **fail** | +5.676 / +3 **fail** | +4.054 / -2 **fail** | +2.703 / -2 **fail** | +4.054 / -2 **fail** | +4.595 / -2 **fail** |
| public_technology | +0.000 / +0 | +2.008 / +1 **fail** | +1.606 / -1 **fail** | +2.008 / -1 **fail** | +1.606 / -1 **fail** | +2.008 / -1 **fail** | +0.402 / -1 |

## Seam, chunk and cost instrumentation

| Strategy | Multi-chunk fixtures | Silence cuts | Fallback cuts | Adjacent seams | Proven seams | Ambiguous seams | `conflicting_edge_token` | Total incomplete | Recognition s | Wall s |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| `control` | 33 | 0 | 33 | 0 | 12 | 21 | 3 | 21 | 18.7 | 66.3 |
| `longer-overlap` | 33 | 0 | 33 | 0 | 9 | 24 | 4 | 24 | 19.0 | 67.1 |
| `vad-overlap-fallback` | 33 | 7 | 26 | 7 | 12 | 14 | 3 | 14 | 18.4 | 64.2 |
| `vad-hybrid` | 33 | 7 | 26 | 33 | 0 | 0 | 0 | 0 | 18.9 | 68.6 |
| `vad-min` | 33 | 15 | 18 | 33 | 0 | 0 | 0 | 0 | 18.0 | 64.3 |
| `vad-min-refined` | 33 | 14 | 19 | 33 | 0 | 0 | 0 | 0 | 17.9 | 63.4 |
| `contiguous-fixed` | 33 | 0 | 33 | 33 | 0 | 0 | 0 | 0 | 18.4 | 65.4 |

`chunks/fixture` is 1 for 77 fixtures and 2 for 33 in every strategy, so all signal comes from
33 seams. Wall time includes model load and, where used, VAD load and probing; the spread across
strategies is within run-to-run noise (63.4 s to 68.6 s for 110 fixtures, about 30 minutes of audio).

## T021 audit

| Strategy | Lexical words discarded | Discards whose own onset evidence exceeded 160 ms | Pre-anchor discards | Max onset delta |
| --- | --- | --- | --- | --- |
| `control` | 44 | 2 | 6 | 0.240 s |
| `longer-overlap` | 42 | 2 | 8 | 0.217 s |
| `vad-overlap-fallback` | 44 | 2 | 6 | 0.240 s |
| `vad-hybrid` | 0 | 0 | 0 | 0.000 s |
| `vad-min` | 0 | 0 | 0 | 0.000 s |
| `vad-min-refined` | 0 | 0 | 0 | 0.000 s |
| `contiguous-fixed` | 0 | 0 | 0 | 0.000 s |

Under every overlapped strategy two lexical discards per run still sit outside the 160 ms onset
bound, and four to eight more are discarded before the anchor on overlap geometry alone. Under
contiguous geometry (`vad-min`, `vad-hybrid`, `contiguous-fixed`) the assembler discards nothing at
all, so the T021 question becomes vacuous rather than answered.

## Determinism

`vad-min`, `vad-min-refined` and `vad-hybrid` were each run twice: results and chunk plans are
byte-identical apart from the measured wall-clock `recognition_seconds`. `control`,
`longer-overlap` and `vad-contiguous` were run twice in the first sweep with the same outcome.
Adding the VAD model did not introduce nondeterminism.

## Artifacts

| Artifact | SHA-256 |
| --- | --- |
| `build/chunk-experiment/control-a/run.json` | `0ba5eb25371fba7bac93e25b40b3a3d89cb2f5991add115d13adfa89c13dedec` |
| `build/chunk-experiment/longer-overlap-legal-a/run.json` | `34afddd3dbef9eabfb63bedd9ad5d1c3a2983e18daac16fbd3b4eb3fd15dbab7` |
| `build/chunk-experiment/vad-overlap-fallback-a/run.json` | `b9d83be7fb4fc5981d8fe3320072f04cc14e7aa275dc15df9a9220bbb411125d` |
| `build/chunk-experiment/vad-hybrid-a/run.json` | `28c1ce4297ec22ca6493de89f0e2192bd3396202161a21cb13ee0eca229615d0` |
| `build/chunk-experiment/vad-min-a/run.json` | `28ea74719bac7c6c541774668234ced5da22671a7331d5b69511f1241d2e4987` |
| `build/chunk-experiment/vad-min-refined-a/run.json` | `4f5b16f7f4c7ff89b9463b4de3548ea73ec14b64a6c3d53820b0785ab20e1795` |
| `build/chunk-experiment/contiguous-fixed-a/run.json` | `d80b775896555f03e7b8664cabaa956ba41a28eee30b705a051d64c5604955f1` |

Per-fixture chunk plans, boundary sample positions, seams and transcripts stay private under
`build/chunk-experiment/` at 0700/0600 and are never committed.


## The ten residual regressions under `vad-min`

| Fixture | T014 WER | `control` WER | `vad-min` WER | delta vs T014 | boundary chosen |
| --- | --- | --- | --- | --- | --- |
| public-2593798def1560acc0ec | 29.730% | 37.838% | 35.135% | +5.405 pp | fixed |
| public-310901c029e510694e92 | 13.793% | 24.138% | 6.897% | -6.896 pp | silence |
| public-341276fe1fa916363fe4 | 18.750% | 34.375% | 18.750% | +0.000 pp | silence |
| public-459b0793fd4172167be8 | 6.452% | 9.677% | 9.677% | +3.226 pp | fixed |
| public-90e5a5d52f792aef4aeb | 0.000% | 14.815% | 3.704% | +3.704 pp | fixed |
| public-91a044c289031ef8f287 | 3.030% | 15.152% | 9.091% | +6.061 pp | silence |
| public-9fa17bc0c27492eb4afc | 12.821% | 23.077% | 20.513% | +7.692 pp | silence |
| public-b7f670c0f934200878cd | 10.811% | 29.730% | 29.730% | +18.919 pp | fixed |
| public-bde1eb90538548bed426 | 6.452% | 16.129% | 6.452% | +0.000 pp | fixed |
| public-c74642aa4621413af5eb | 12.821% | 23.077% | 15.385% | +2.564 pp | fixed |

`vad-min` returns 3 of the ten to T014 level or better and reduces the error on five more.
Across the whole corpus it improves 6 fixtures, regresses 13 and leaves 91 unchanged versus T014,
with zero incomplete results against T014's 15.

## Findings

1. Chunk geometry, not the assembler, is the source of the ambiguous seams. Making silence-aligned
   or simply contiguous cuts removes the overlap region entirely, so the assembler takes the
   `adjacent` branch: 33 of 33 seams, zero `uncertain_join`, zero `conflicting_edge_token`, zero
   incomplete results, and nothing discarded anywhere.
2. Longer overlap does not help and cannot help much. The 14-window/180 s contract caps overlap at
   2.103 s, 0.103 s above today's value, and the measured effect of using that headroom is
   negative in six of nine categories.
3. Silence placement matters more than silence certainty. Thresholded probes fire on only 5 to 17
   of 33 boundaries; taking the quietest 256 ms frame in the band (`vad-min`) needs no threshold,
   fires wherever the band allows and scores best. Refining inside that frame by energy
   (`vad-min-refined`) is worse, so the extra machinery is rejected.
4. Contiguous geometry alone is not enough: `contiguous-fixed` shows what happens when cuts ignore
   the audio (+9.045 pp on concatenated stress fixtures). The VAD is doing real work.
5. Two categories still fail the adoption gate under the best strategy: `public_sk_longer`
   (+2.703 pp) and `public_technology` (+1.606 pp). Both now have *fewer* incomplete results than
   T014, so the failure is WER only, and it comes from words split at the 18 boundaries where the
   band contained no real pause, not from any discarded text.

## Recommendation

`vad-min` is the preferred strategy: maximum model input 239,360 samples, contiguous chunks, no
overlap, silence search band [205,715, 239,360] samples, cut at the centre of the quietest 256 ms
VAD frame, deterministic contiguous fallback when the band yields no frame. It is not the lowest
WER in every category, but it is the only strategy that removes ambiguous seams and incomplete
results without any unproven deletion, and it is within noise on cost.

It is **not yet adoptable**. Before integration:

- the Silero VAD model must be added to the pinned offline model descriptor and `ModelProvisioner`;
  this experiment loaded it from a previously cached FluidAudio directory, which is not a
  provisioning story;
- `public_sk_longer` and `public_technology` still exceed the one-point regression allowance and
  need an owner decision or a further boundary-placement improvement;
- the corpus has no fixture longer than about 17 s, so every multi-chunk case here is two chunks.
  The 14-window budget, the fallback path and long-recording memory behaviour are argued
  analytically and unit-tested, not measured on real long-form audio.


### Fixtures the geometry change newly regresses

`vad-min` is better in aggregate and strictly better on incomplete counts, but it is not a
fixture-level Pareto improvement. These fixtures were at T014 parity under `control` and regress
under `vad-min` because a contiguous cut split a word where the band held no pause.

| Fixture | Category | T014 WER | `control` WER | `vad-min` WER | boundary |
| --- | --- | --- | --- | --- | --- |
| mixed-01 | legacy_synthetic_stress | 22.857% | 22.857% | 25.714% | silence |
| mixed-02 | legacy_synthetic_stress | 19.608% | 19.608% | 25.490% | fixed |
| mixed-04 | legacy_synthetic_stress | 51.219% | 51.219% | 56.098% | fixed |
| public-024bd863c978b0515fc2 | public_technology | 21.053% | 21.053% | 23.684% | fixed |
| public-da85b5ebc08e9db2f3ec | public_technology | 2.500% | 2.500% | 12.500% | silence |
| public-eeb45b3bb681bff560d5 | public_sk_longer | 9.375% | 9.375% | 12.500% | fixed |

And the fixtures it improves over T014:

| Fixture | Category | T014 WER | `vad-min` WER |
| --- | --- | --- | --- |
| mixed-03 | legacy_synthetic_stress | 29.630% | 11.111% |
| mixed-09 | legacy_synthetic_stress | 41.463% | 24.390% |
| mixed-10 | legacy_synthetic_stress | 25.581% | 13.954% |
| public-310901c029e510694e92 | public_sk_longer | 13.793% | 6.897% |
| public-72ddc97c46a3b64192b5 | public_sk_longer | 18.605% | 13.954% |
| public-c707a345644294aec8a3 | public_technology | 13.514% | 10.811% |

One more placement data point: `legacy_sk` is at exact T014 parity under `vad-min` but +0.529 pp
under `vad-hybrid`, `vad-min-refined` and `contiguous-fixed`. Same contiguous geometry, different
cut placement, one fixture moved. Where the cut lands matters more than how confident the probe is
that it is silence.

### Planner bound

`ChunkPlanner` refuses a fifteenth chunk rather than letting a probe silently truncate a recording
at the assembler capacity, and `validate()` asserts `14 * (minimumStride + 1) >= 2,880,000`
(2,880,024). `testPlannerRefusesAFifteenthChunk` and `testSilenceOnlyGeometryStillFitsFourteenWindows`
drive an adversarial probe that always returns the earliest admissible cut.

`ChunkPlanner.swift` ships in the production target but is called only from evaluation code today.
The dictation path still uses the unchanged `WindowedTranscriber` geometry.

