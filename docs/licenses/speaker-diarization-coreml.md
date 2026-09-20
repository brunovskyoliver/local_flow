# Speaker diarization model licence review

Reviewed 2026-09-18 for Feature 007 (task T003).

## Pinned artifact

- Repository: `FluidInference/speaker-diarization-coreml`
- Revision: `1ed7a662fdc7109e36d822db793ee6eebdaf8594`
- Manifest: [`speaker-diarization-offline.json`](../../apps/macos/LocalFlow/Resources/Models/speaker-diarization-offline.json)
- Files used (offline variant only): `Segmentation.mlmodelc`, `FBank.mlmodelc`,
  `Embedding.mlmodelc`, `PldaRho.mlmodelc` and `plda-parameters.json`. 21 files,
  21,599,417 bytes. The other folders in the repository (`PLDA.mlmodelc`,
  `pyannote_segmentation.mlmodelc`, the `wespeaker*.mlmodelc` variants, `mlpackages/`,
  plots) are not listed in the manifest and are never installed.
- Every file was downloaded explicitly and checked against its pinned LFS SHA-256
  or Git blob SHA-1 with `scripts/complete-model-manifest.py`. The manifest records
  a SHA-256 for each file. The assets were not modified and are not bundled in the app.
- Pinned model card: [speaker-diarization-coreml-model-card.md](speaker-diarization-coreml-model-card.md).
  The upstream `README.md` has SHA-256
  `ff38be81e25e4b6eccf3aa584ccd7d6c9970f7af9b51ff7ba34bea1a38602c8d`; the copy differs only in
  its relative `plots/` image links, which point at the pinned revision instead.

## Components and licences

| Component | Upstream | Licence |
| --- | --- | --- |
| CoreML conversion (all four models and the PLDA JSON) | FluidInference, `speaker-diarization-coreml` at the pinned revision | CC-BY-4.0 (model card YAML) |
| Powerset segmentation (`Segmentation.mlmodelc`) | pyannote `speaker-diarization-community-1`, revision `3533c8cf8e369892e6b79ff1bf80f7b0286a54ee` | CC-BY-4.0 (Hugging Face repository tag) |
| WeSpeaker ResNet34 embedding (`FBank.mlmodelc`, `Embedding.mlmodelc`) | pyannote `wespeaker-voxceleb-resnet34-LM`, revision `837717ddb9ff5507820346191109dc79c958d614`, part of community-1 | CC-BY-4.0 (Hugging Face repository tag) |
| PLDA transform (`PldaRho.mlmodelc`, `plda-parameters.json`) | pyannote `speaker-diarization-community-1` PLDA, same revision | CC-BY-4.0 (Hugging Face repository tag) |

The model card says the FluidAudio SDK is Apache-2.0 and the parent pyannote model is
CC-BY-4.0. Unlike the Parakeet card, it has no conflicting licence section.

## Obligations

CC BY 4.0 requires attribution, a link to the licence and a note of changes. LocalFlow
does not modify or redistribute the assets: the user installs them from the pinned
revision. If a build ever bundles them, the About or notices screen must credit
pyannote (Hervé Bredin et al.), WeSpeaker (Wang et al., ICASSP 2023) and FluidInference,
and link to <https://creativecommons.org/licenses/by/4.0/>.

The pyannote community-1 repository is gated on Hugging Face (users accept its
conditions before downloading). LocalFlow downloads only the FluidInference conversion,
which is not gated. The licence tag above was read from the public repository metadata.

## Result

No licence blocks shipping the pinned offline assets as a user-installed model with
attribution. The manifest is complete.
