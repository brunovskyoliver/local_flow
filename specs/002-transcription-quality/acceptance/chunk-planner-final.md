# Long-form chunk-planner acceptance

Date: 2026-09-17. This is evaluation-only evidence. No planner was connected to production,
and normalization was not started.

## Corpus and provenance

The long-form corpus contains 25 genuine continuous VoxPopuli source intervals:

| Category | Fixtures | Duration range |
| --- | ---: | ---: |
| Slovak 60–90 seconds | 10 | 60.260–84.832 s |
| Slovak 120–180 seconds | 10 | 121.040–176.139 s |
| English 60–180 seconds | 5 | 60.713–70.137 s |

It covers 15 source recordings from 2009, 2013 and 2018 and 14 publisher speaker IDs. Two
fixtures exceed 170 seconds. No fixture combines unrelated clips. Each lock entry carries the
pinned dataset and acquisition-code revisions, source recording ID, exact interval, ordered
transcript span IDs and alignment evidence, annotation hash, original-recording hash and
converted hash. The independently rebuilt manifests both hash to
`53b0a220bc53b7fba807e7667ca64488274cb42f77e187ffd749047399a75f97`.
Third-party audio remains under ignored `build/` paths.

## VAD provisioning and measured cost

VAD is a separate `voice_activity_detection` model capability, not an ASR language model.
The bundled descriptor pins `FluidInference/silero-vad-coreml` revision
`b419383c55c110e2c9271fa6ee0ea83d03c70d96` and every compiled artifact hash. The existing
`ModelProvisioner` installed a clean copy, and FluidAudio loaded it with offline mode forced;
the experiment did not read the pre-existing user cache and added no Python or app runtime.

Measured on Apple M5, macOS 26.6.2 (25G83):

| Measurement | Result |
| --- | ---: |
| VAD artifacts | 1,063,425 bytes |
| Offline load time | 0.176103 s |
| RSS with active ASR lease | 1,661,485,056 bytes |
| RSS with active ASR lease plus exercised VAD | 1,663,860,736 bytes |
| Retained VAD increment | 2,375,680 bytes |

The 2.38 MB increment is small relative to the active ASR working set and does not materially
change the current memory budget. This is a direct isolated measurement, unlike the noisier
process-wide peak RSS recorded during corpus runs.

## Strategies

- `contiguous-fixed`: exact nominal 239,360-sample contiguous windows.
- `vad-min`: the minimum-probability candidate in the existing 33,645-sample bounded region,
  with nominal fallback.
- `vad-preferred`: the nearest/last candidate in that region only when speech probability is
  at most 0.2; otherwise nominal fallback. A qualifying shift is also rejected when it would
  turn one legal final window into an extra terminal fragment. This focused correction was
  made after the first run exposed a 5,002-sample tail; only `vad-preferred` was rerun.

All strategies are contiguous: no overlap, no dropped samples, no lookahead outside the
bounded region, no window over 239,360 samples and no fifteenth window. Two passes produced
identical transcript outputs and identical plans after timing/RSS fields were excluded.

## Quality

Values are WER / CER. T014 is retained verbatim as historical evidence.

### Frozen 110-fixture short corpus

| Category | T014 historical | contiguous-fixed | vad-min | vad-preferred |
| --- | ---: | ---: | ---: | ---: |
| legacy_en | 0.076555 / 0.025717 | 0.076555 / 0.025717 | 0.076555 / 0.025717 | 0.076555 / 0.025717 |
| legacy_sk | 0.105820 / 0.030622 | 0.111111 / 0.039234 | 0.105820 / 0.030622 | 0.111111 / 0.039234 |
| legacy_synthetic_stress | 0.238693 / 0.124514 | 0.329146 / 0.208658 | 0.198492 / 0.119650 | 0.291457 / 0.182393 |
| public_en_general | 0.062361 / 0.024492 | 0.062361 / 0.024492 | 0.062361 / 0.024492 | 0.062361 / 0.024492 |
| public_entity_numeric | 0.125000 / 0.049812 | 0.125000 / 0.049812 | 0.125000 / 0.049812 | 0.125000 / 0.049812 |
| public_sk_accented_en | 0.261062 / 0.184701 | 0.261062 / 0.178172 | 0.261062 / 0.184701 | 0.261062 / 0.178172 |
| public_sk_general | 0.108374 / 0.030433 | 0.118227 / 0.036862 | 0.118227 / 0.036862 | 0.118227 / 0.036862 |
| public_sk_longer | 0.154054 / 0.045537 | 0.200000 / 0.065825 | 0.181081 / 0.057259 | 0.200000 / 0.065825 |
| public_technology | 0.132530 / 0.034578 | 0.136546 / 0.040802 | 0.148594 / 0.056017 | 0.136546 / 0.040802 |

Against contiguous-fixed, vad-min improved 11 fixtures, regressed one and left 98 unchanged;
the one regression was +0.100000 absolute WER. Vad-preferred improved three synthetic fixtures,
regressed none and left 107 unchanged. Against T014, however, vad-preferred still regressed
`public_sk_longer` by 4.595 percentage points WER and `public_sk_general` by 0.985 points.
Historical deletion does not fully explain this. The [bounded follow-up investigation](phase4-regression-investigation.md) corrects the earlier "no lexical discard" description: the five highlighted regressions had no time-only trim, but all used anchored splices that replaced earlier suffixes. Their changes occur both at chunk edges and several seconds into the continuation. `public_technology` is 0.402 points worse than T014; three historical technology splices replaced seven old suffix words and dropped one incoming prefix word. Those counts do not establish eight erroneous deletions or explain away the quality delta.

### Genuine long-form corpus

| Category | contiguous-fixed | vad-min | vad-preferred |
| --- | ---: | ---: | ---: |
| English 60–180 s | 0.063625 / 0.042601 | 0.051621 / 0.035039 | 0.057623 / 0.042601 |
| Slovak 60–90 s | 0.152408 / 0.072314 | 0.137311 / 0.057487 | 0.156722 / 0.070613 |
| Slovak 120–180 s | 0.181882 / 0.089055 | 0.153310 / 0.066090 | 0.173171 / 0.080346 |
| All long-form | 0.154495 / 0.077935 | 0.132313 / 0.059392 | 0.149784 / 0.072410 |

Against contiguous-fixed, vad-min improved 18 fixtures, regressed five and left two unchanged.
Vad-preferred improved seven, regressed eight and left ten unchanged. Its largest improvement
was -0.046667 absolute WER; its largest regression was +0.026707. Exact per-fixture deltas,
boundaries and boundary causes are preserved in the content-free
[`chunk-planner-final-evidence.json`](chunk-planner-final-evidence.json). The private raw runs
remain under `build/chunk-acceptance/final-v2`.

## Geometry and resource results

| Strategy/corpus | Chunks total | Max chunks | VAD cuts | Nominal fallbacks | Recognition | Wall | Peak RSS | Max audio buffer | Max planner buffer |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| fixed/short | 143 | 2 | 0 | 0 | 19.530 s | 68.122 s | 2,512,306,176 B | 239,360 samples | 0 |
| vad-min/short | 143 | 2 | 15 | 18 | 18.776 s | 67.316 s | 2,486,403,072 B | 239,360 | 33,645 |
| vad-preferred/short | 143 | 2 | 3 | 30 | 19.995 s | 69.605 s | 2,632,859,648 B | 239,360 | 33,645 |
| fixed/long | 183 | 12 | 0 | 0 | 27.460 s | 50.978 s | 2,998,288,384 B | 239,360 | 0 |
| vad-min/long | 186 | 13 | 68 | 93 | 28.703 s | 55.732 s | 3,106,652,160 B | 239,360 | 33,645 |
| vad-preferred/long | 183 | 12 | 23 | 135 | 25.214 s | 48.820 s | 2,395,504,640 B | 239,360 | 33,645 |

The corpus exercised 5, 6, 9, 10, 11, 12 and 13 chunks. Thirteen is the maximum actually
observed; the 14-window guard was tested at exactly 180 seconds but not forced by a public
fixture. The report therefore does not claim a measured 14-chunk public run.
The 239,360-sample Float32 audio buffer is 957,440 bytes; the 33,645-sample planner/VAD buffer
is 134,580 bytes.

For the 176.139-second, 2,818,224-sample fixture:

| Strategy | Chunks | Recognition | Wall | Peak RSS | WER / CER | VAD / fallback |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| contiguous-fixed | 12 | 1.709 s | 2.124 s | 2,998,288,384 B | 0.226667 / 0.143508 | 0 / 0 |
| vad-min | 12 | 1.896 s | 2.428 s | 3,106,652,160 B | 0.140000 / 0.075740 | 4 / 7 |
| vad-preferred | 12 | 1.627 s | 2.060 s | 2,395,504,640 B | 0.180000 / 0.103075 | 1 / 10 |

Its exact sample boundaries were:

- fixed: `0, 239360, 478720, 718080, 957440, 1196800, 1436160, 1675520,
  1914880, 2154240, 2393600, 2632960, 2818224`;
- vad-min: `0, 239360, 463507, 702867, 942227, 1170470, 1409830, 1642169,
  1881529, 2109772, 2349132, 2588492, 2818224`;
- vad-preferred: `0, 239360, 478720, 718080, 957440, 1169299, 1408659,
  1648019, 1887379, 2126739, 2366099, 2605459, 2818224`.

Across all 810 evaluated fixture passes, every strategy recorded zero incomplete results, zero
ambiguous seams, zero conflicting edges and zero assembler lexical discards. The contiguous
T021 invariant is therefore affirmatively satisfied; no vacuous overlap-discard timing claim is
made.

## Decision

No candidate is approved for production integration. Vad-min has the best aggregate long-form
quality, but its unconditional minimum rule regresses `public_technology` and one short fixture.
Vad-preferred retains the material `public_sk_longer` regression against T014 and is weaker
than vad-min on long-form quality. Its interface shape gives it no adoption priority.

Keep production unchanged. The [bounded follow-up investigation](phase4-regression-investigation.md) is now complete and found no defensible correction. T024 remains deferred; no further experiment cycle is authorized by this result. Production integration cannot proceed from this acceptance phase.
