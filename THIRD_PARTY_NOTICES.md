# Third-party notices

Spec Kit files in `.specify/` and `.agents/skills/speckit-*` originate from [github/spec-kit](https://github.com/github/spec-kit), commit `1d5106f59e1b148ee23ab136638932dd790ff1b6`, under the MIT license. Preserve its license in `.specify/UPSTREAM-LICENSE`. Project templates and constitution have LocalFlow additions.

FluidAudio and GRDB are pinned dependencies as recorded below. No application source from VoiceInk has been copied. Model weights have separate licenses; record selected dependency versions, binary components, model provenance and licenses before distribution.

## Feature 001 pinned dependencies

FluidAudio 0.15.7, commit `41540ea237350afe5117a082b5c28eda642d0612`, is
resolved by Xcode with an empty trait list. The resolved graph excludes the
optional NeMo dependency. Preserve [Apache-2.0 license](docs/licenses/FluidAudio-0.15.7.txt)
and its bundled [fastcluster notice](docs/licenses/fastcluster.md).

GRDB.swift 7.10.0, commit `36e30a6f1ef10e4194f6af0cff90888526f0c115`, uses
the [MIT license](docs/licenses/GRDB-7.10.0.txt). These dependencies stay within
the native application target; no wrapper package or additional runtime is added.

The selected Parakeet v3 CoreML model revision is
`7dd20fe6b1797d35f5e3307e8b1732d9a178edfe`. Its repository declares CC-BY-4.0.
The selected assets were downloaded explicitly and verified against pinned LFS
SHA-256 or Git blob identities; every file now has a calculated SHA-256 in the
manifest. Weights remain outside version control and are not bundled in the app.
The CoreML conversion is provided by FluidInference, based on NVIDIA's
`nvidia/parakeet-tdt-0.6b-v3`. Preserve the [pinned model card](docs/licenses/parakeet-v3-model-card.md)
and [CC BY 4.0 attribution terms](https://creativecommons.org/licenses/by/4.0/).
The downloaded model assets were not modified.

Review note: the retained pinned model card's YAML declares `cc-by-4.0`,
while its final License section says Apache 2.0 and points to FluidAudio.
These are inconsistent labels. Dependency licenses are recorded above;
selected model artifact license interpretation remains an open T002 gate.

## Evaluation speech fixtures

Google FLEURS, revision `70bb2e84b976b7e960aa89f1c648e09c59f894dd`, is used for
local evaluation under CC BY 4.0. Attribution: Alexis Conneau et al., *FLEURS:
Few-shot Learning Evaluation of Universal Representations of Speech* (2022),
Google. Audio remains outside version control. The fixture manifest records
source members, references, hashes and PCM16 conversion; derived mixed stress
fixtures concatenate two recordings with 250 ms silence. Preserve the
[fixture attribution and provenance](fixtures/audio/README.md), the
[publisher source](https://huggingface.co/datasets/google/fleurs) and the
[license link](https://creativecommons.org/licenses/by/4.0/).

## Model-license closure review, 2026-09-16

The upstream [NVIDIA model repository](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3/tree/main)
also declares CC-BY-4.0. This supports retaining NVIDIA attribution and the
CC BY notice, but does not resolve the contradictory footer in the pinned
FluidInference conversion card. Keep both notices and the exact pinned card;
do not relabel the selected weights as Apache-only. T002 remains open pending
artifact-specific clarification from the publisher or a reviewed license decision.
No publisher message was sent and no weights were bundled or redistributed.

## Sotto native interface

The source snapshot in `third_party/sotto` comes from
[davis7dotsh/sotto](https://github.com/davis7dotsh/sotto), commit
`c1d5f0bbaff19a1559621943dff49ba89b4a96a0`, copyright (c) 2026 Davis, MIT.
LocalFlow adapts the sidebar from `SottoWindowView.swift` and the palette/sidebar
material from `SottoTheme.swift` in `LocalFlowApp.swift`. Preserve the full
[MIT notice](third_party/sotto/LICENSE), also bundled as `Sotto-LICENSE.txt`.

The snapshot retains upstream notices and scripts for reference. Its Swift
server, HTTP client, model helpers, package dependencies and submodule contents
are not linked into LocalFlow. No Sotto model weights were downloaded.
