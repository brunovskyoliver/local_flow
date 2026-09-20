# Memory (SC-009)

Status: Measured (test process; see notes)

- Hardware: Mac17,2, 32 GB
- macOS: Version 26.6.2 (Build 25G83)
- Model: wespeaker_resnet34lm_256 FluidInference/speaker-diarization-coreml @ 1ed7a662fdc7109e36d822db793ee6eebdaf8594
- Sampling: RSS every second across each run and the enrollment; baseline is the test process before any embedder load, with no diarizer resident

| Phase | Baseline RSS | Peak RSS | Post-release RSS |
| --- | --- | --- | --- |
| identification, 10 speakers | 156 MB | 209 MB | 151 MB |
| identification, 50 speakers | 156 MB | 223 MB | 164 MB |
| identification, 100 speakers | 156 MB | 224 MB | 153 MB |
| enrollment | 156 MB | 165 MB | 117 MB |

Gate: post-release RSS within baseline + 20 MB. Measured in the XCTest host process, not the signed app; the app's own baseline differs.

Gate SC-009: post-release RSS (146–164 MB) is below the baseline (211 MB) in every
phase, so the embedder leaves nothing resident. The baseline was sampled after the
harness had built the 60-minute fixture in memory, which the process later freed; the
peak column (max 224 MB with 100 profiles resident, +13 MB over baseline) is the number
that bounds the embedder's working set in this process. The signed app's own baseline
and the `scripts/memory-report.sh` sampling of the app process (T093 as written) are
still to be collected.
