# Whisper large-v3-turbo benchmark

Date: 2026-09-17. Decision: **retain Parakeet v3**. Whisper large-v3-turbo was evaluated as an opt-in alternative and was not adopted or wired into the shipped engine path.

## Scope and controls

- Frozen short manifest: `10b9873c6b3f05fcb1b22a96a014a08c7a7f60566e8176ad2b799a1adbbd988b` (110 fixtures).
- Frozen long manifest: `53b0a220bc53b7fba807e7667ca64488274cb42f77e187ffd749047399a75f97` (25 fixtures).
- Hardware: Apple M5 32 GB, `Mac17,2`, 34,359,738,368 bytes, macOS 26.6.2 build 25G83, AC power.
- Whisper model SHA-256: `1fc70f774d38eb169993ac391eea357ef47c88757ef72ee5943879b7e8e2bc69`.
- Whisper helper: pinned whisper.cpp `371b5a7561823ab2bb32142d2751e35e7534727b`; Silero VAD SHA-256 `2aa269b785eeb53a82983a20501ddf7c1d9c48e33ab63a41391ac6c9f7fb698`.
- Modes: automatic detection, explicit `sk`, and explicit `en`.
- Pipeline held constant: contiguous 239,360-sample windows with zero overlap, `TranscriptAssembler` `anchored_overlap_v3`, `TranscriptNormalizer` `formatting-n001-n006-vocabulary-v001-v1`, empty vocabulary snapshot, and unchanged persistence boundary. The benchmark writes private evaluation artifacts only.

The run was one sequential pass per engine and language mode. This is sufficient to reject adoption because the regressions are large, but it is not three-repeat SC-007 adoption evidence.

## Normalized WER

Percentages are WER from `scripts/transcription-quality.py score`; lower is better. `Mixed` is the ten bilingual synthetic stress fixtures. `Long-form` is the 25-fixture long-form category.

| Corpus slice | Parakeet | Whisper auto | Whisper sk | Whisper en |
| --- | ---: | ---: | ---: | ---: |
| English general | 6.236% | 6.013% | 6.013% | 6.013% |
| English 60–180 s | 6.363% | 22.209% | 84.754% | 12.725% |
| Slovak general | 11.823% | 11.823% | 11.823% | 74.877% |
| Slovak longer | 20.000% | 83.243% | 25.135% | 114.595% |
| Slovak 60–90 s | 15.241% | 66.355% | 32.063% | 97.700% |
| Slovak 120–180 s | 18.188% | 60.139% | 29.896% | 96.864% |
| Technical | 13.655% | 11.647% | 11.647% | 66.667% |
| Mixed sk/en stress | 32.915% | 41.457% | 43.970% | 52.261% |
| Long-form | 15.450% | 55.634% | 39.458% | 83.333% |

Whisper auto improves short technical WER by 14.7% relative and mixed-language WER does not improve. Its long-form WER is 260% higher than Parakeet. Explicit hints do not provide a safe general strategy: `sk` remains poor on English, and `en` remains poor on Slovak.

## Resource and latency measurements

Latency is the mean per-fixture value. Recognition is the model call; wall includes the bounded fixture processing around it. RSS is the measured peak from the benchmark receipt. Whisper has a separate helper process, so both helper-only and combined helper-plus-test-host peaks are recorded.

| Mode | Load | Engine RSS | Combined RSS | Short recognition / wall | Long recognition / wall |
| --- | ---: | ---: | ---: | ---: | ---: |
| Parakeet | 70.526 s | 1.609 GiB | 1.609 GiB | 0.166 / 0.383 s | 0.989 / 1.147 s |
| Whisper auto | 0.410 s | 1.849 GiB | 2.097 GiB | 1.366 / 1.836 s | 8.842 / 9.361 s |
| Whisper sk | 0.415 s | 1.850 GiB | 2.078 GiB | 0.849 / 1.311 s | 5.967 / 6.497 s |
| Whisper en | 0.425 s | 1.850 GiB | 2.078 GiB | 0.768 / 1.215 s | 4.772 / 5.296 s |

Whisper loads much faster because the helper can open its GGML model quickly, but its model RSS is about 15% higher than Parakeet. Including the separate helper and XCTest host, its peak is about 29–30% higher. Recognition latency is 4.6–8.2 times higher on short fixtures and 4.8–8.9 times higher on long fixtures, depending on the hint.

## Decision

Parakeet remains the only production transcription engine. Whisper does not demonstrate a meaningful quality improvement at acceptable resource and latency cost, and no fallback or persistence, vocabulary, normalizer, assembler, server, or wire-schema change is justified. The private run artifacts are under `build/whisper-benchmark-20260917-run7/` and are not part of the source or model distribution.
