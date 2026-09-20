# Throughput (SC-008)

Status: Measured (synthetic meeting built from licensed speech clips; see notes)

- Hardware: Mac17,2, 32 GB
- macOS: Version 26.6.2 (Build 25G83)
- Model: wespeaker_resnet34lm_256 FluidInference/speaker-diarization-coreml @ 1ed7a662fdc7109e36d822db793ee6eebdaf8594
- Policy: tiers_v1@wespeaker_resnet34lm_256/1ed7a662, embed_offline1spk_dw_v1+regions_v1
- Meeting: 60 min system track of FLEURS speech clips (one per root) inside the turns, silence elsewhere, 6 remote roots, 30 turns of 12 s

| Known speakers | Regions planned | Regions embedded | Regions rejected | Comparisons | Model load | Run (extraction + comparison + adoption) | Model release | Peak RSS | Post-release RSS |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 10 | 24 | 8 | 16 | 20 | 0.90 s | 27.62 s | 0.00 s | 209 MB | 151 MB |
| 50 | 24 | 8 | 16 | 100 | 0.06 s | 25.78 s | 0.00 s | 223 MB | 164 MB |
| 100 | 24 | 8 | 16 | 200 | 0.05 s | 26.85 s | 0.00 s | 224 MB | 153 MB |

Enrollment of one cluster (5 regions / 100 s limit): 27.43 s, outcome outcome(LocalFlow.EnrollmentOutcome.noUsableSample, knownSpeakerID: Optional(82302C37-9E16-441E-BB86-13818AE2C8F1))

Notes: the timings cover decoding the full system track once per run, embedding every accepted region, scoring against every profile and adopting. Library vectors are synthetic, so no accuracy conclusion can be drawn; a region is rejected when the segmentation model finds no speech in it.

Gate SC-008: every library size completed in under 60 s after diarization on the
reference machine (Mac17,2 = M5, 32 GB). About 26 s of each run is the single forward
decode of the 60-minute AAC system track; the 100-profile comparison itself is
negligible next to it. The "model release" column reads 0.00 s because the coordinator
reports the release duration under the workload that follows, not the embedder's; the
lifecycle test suite covers release ordering. 16 of the 24 query regions and all 5
enrollment regions were rejected by the segmentation model as no speech: the FLEURS
clips are 2–30 s utterances looped inside 12 s turns, and resampling a 16 kHz PCM16
clip to 48 kHz and back through AAC is not a natural recording. Real-meeting numbers
(T097 walkthrough) are still to be collected; this run measures the pipeline's cost,
not its accuracy.
