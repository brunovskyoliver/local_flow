# 01: Parakeet Ultra as an optional pinned dictation model

Source: `~/agent-runs/2026-10-22-localflow-audit/asr-models.md`, "Migration proposal within the current architecture".

Status: implemented on branch `worktree-agent-ac7bf2de8e5aacb72`. Not merged. No quality or resource comparison has been run.

## What changed

### 1. FluidAudio 0.15.7 → 0.17.7 (commit `build(speech): upgrade FluidAudio…`)

- `packages/LocalFlowCore/Package.swift`, both `Package.resolved` files and the Mac project's package reference now pin 0.17.7 (commit `503b4bd1bbf7220882de39fe8ae6716aae4132da`). Traits stay `[]`.
- No API changes were needed: `AsrModels(encoder:preprocessor:decoder:joint:configuration:vocabulary:version:)`, `AsrManager.transcribe(_:decoderState:language:)`, `CtcModels.loadDirect`, `CtcTokenizer.load(from:)` and the offline diarizer loaders compile unchanged.
- The v3, CTC booster, VAD and diarization manifests are byte-identical. `ModelProvisioner` compares the installed manifest with the bundled one exactly, so editing `sdkCompatibility` would have forced every Mac, iPhone and server to download 483 MB again. The manifest field now means "the release these files were pinned against". The release that actually ran is `FluidAudioSDK.version` (new, `LocalFlowSpeech/FluidAudioSDK.swift`). Transcript provenance (`sdk_version`) and the speech worker's `ready` frame (`sdk`) record that value. Before this change both recorded the manifest's `0.15.7`.
- Logging: 0.17.7 adds `AppLogger.minimumLevel` and `AppLogger.mirrorsToConsole`. FluidAudio's info and debug lines can include recognized text and Dictionary terms. In Debug builds the SDK also mirrors every level to stderr by default. `FluidAudioSDK.configureLogging()` sets the level to `.warning` and turns mirroring off. The engine, diarizer and voice-embedder factories call it before loading anything. The speech worker still redirects fd 2 to /dev/null as before.
- NeMo: with `traits: []`, the `NemoTextProcessing` binary is not linked (no NeMo symbols or framework in the built app). SwiftPM still downloads its 87 MB archive while resolving. The app gains FluidAudio's 1 MB `FluidAudio_FluidAudio.bundle`, which holds TTS G2P resources LocalFlow does not use.
- `docs/licenses/FluidAudio-0.15.7.txt` was renamed to `FluidAudio-0.17.7.txt` (the license text is identical). `THIRD_PARTY_NOTICES.md` and `apps/macos/README.md` were updated.

### 2. Ultra descriptor and factory branch (commit `feat(speech): pin Parakeet Ultra CoreML…`)

- `apps/macos/LocalFlow/Resources/Models/parakeet-ultra.json` pins `FluidInference/parakeet-ultra-coreml` at revision `95eaa59a39d4394f047a4dc5cce480388a60d1b6`, `sdkCompatibility` `0.17.7`, license `cc-by-4.0`. It lists 18 files totalling 632,162,964 bytes: the four `.mlmodelc` directories (Ultra's Decoder, Encoder and Joint have no `metadata.json`) plus `parakeet_vocab.json`. The README, `config.json`, `.gitattributes` and the duplicate `parakeet_v3_vocab.json` are left out. LFS SHA-256 values come from `GET /api/models/FluidInference/parakeet-ultra-coreml/tree/<rev>?recursive=true&expand=true`. The six small non-LFS files were downloaded, checked against their Git blob IDs, then hashed. `parakeet_vocab.json` is byte-identical to v3's.
- `SpeechModelChoice` (`LocalFlowSpeech`) names the two pins (model ID, revision, manifest SDK pin). `FluidAudioEngineFactory.makeRuntime()` accepts a descriptor only if it matches one of them exactly. It then loads the same files with the same `.all` compute units, `parallelChunkConcurrency: 1`, 239,360-sample window and 4,800-sample padding, the same script filter, and FluidAudio's `.v3` or `.ultra` tag; both tags take the v3-family decode path. It still loads only from verified local URLs and never uses `downloadAndLoad`.
- The CTC booster stays on for Ultra. It rescores the recognizer's token timings against its own CTC 110M pass, and Ultra keeps v3's tokenizer and token timing format. Caveat: `VocabularyBoostPolicy`'s confidence rules were tuned on v3, and Ultra's token confidences have not been compared with v3's.
- `SpeechModelSelection` (`LocalFlowCore`) holds the installed models and the current choice. `select(_:lifecycle:)` verifies the target's installed files and switches inside `ModelLifecycleCoordinator.installModel`. That call releases the resident runtime first and throws `busy` while any lease is held, so only one ASR model is ever resident.
- `TranscriptionPipelineIdentity(following:)` plus `SpeechModelIdentitySource` let every transcriber built at launch (dictation, pending retries, live meeting previews) record the selected model's ID, revision, manifest hash and artifact hashes. The source only changes inside the install gate, so a lease's provenance always names the model that lease loaded.
- Opt-in tests in `RuntimeCompatibilityTests` take `TEST_RUNNER_LOCALFLOW_SPEECH_DESCRIPTOR=parakeet-ultra`. `testOptInPinnedRuntimeLoadsDecodesAndReleases` also accepts `TEST_RUNNER_LOCALFLOW_BOOST_MODEL_ROOT`.

### 3. Mac Settings (commit `feat(macos): choose Parakeet v3 or Ultra…`)

- Settings › Models: the first row is now titled with the model in use. Below it is the other model. For Parakeet Ultra the row reads "Optional dictation model · CC BY 4.0 · Not installed · 632 MB" with **Download…**. The confirmation dialog states the size, that the files come from Hugging Face and are checked against pinned hashes, the attribution and license, and that dictation keeps the current model until the user switches. A progress bar and **Cancel** show while it downloads. Once installed the row offers **Use for dictation**. After switching, the same row offers Parakeet v3 ("Default dictation model") as the rollback.
- Switching (`AppServices.useSpeechModel`) is refused while a dictation is busy, has unsaved audio, or a model command or install is running. A live meeting holds a lease, so the lifecycle refuses the switch then too. After a switch, "Keep Parakeet loaded" reloads the new model.
- The alternative model downloads outside the lifecycle install gate, so dictation keeps working during the download. Nothing loads those files until a switch, and the provisioner refuses verification while it is writing them.
- If the chosen model fails verification at launch (deleted or damaged) and v3 verifies, the app switches back to v3 and says so in the status line.
- Preference key `speechModel` (`parakeet-v3` / `parakeet-ultra`). Unknown values read as v3.
- `THIRD_PARTY_NOTICES.md` has an "Optional Parakeet Ultra speech model" section. The pinned model card is kept at `docs/licenses/parakeet-ultra-model-card.md` (Git blob `a166d3e4…`, which matches the repository at the pinned revision).
- Server: the LocalFlow Server worker (`flowd-speech`) still serves Parakeet v3 only. Its `ready` frame already sent model ID, revision and manifest hash; it now also sends the linked SDK version. The iPhone app stays on v3.

## How it was verified

- `swift test --package-path packages/LocalFlowCore`: 14 tests, 0 failures. Eight are new (`SpeechModelSelectionTests`): both bundled manifests validate and select their own choice; the Ultra manifest has the v3 layout and the identical vocabulary; only exact pins are accepted; the stored preference defaults to v3; the factory accepts both pins and fails only on missing files, while a wrong SDK pin stops at the pin check; switching releases the resident model and refuses while a lease is held; provenance follows the switch, including rollback; a switch to an uninstalled model leaves the current one in place.
- `xcodebuild … -scheme LocalFlow test` (full Mac suite): 1,896 passed, 0 failed, 32 skipped (opt-in hardware and model tests). Three new tests in `SettingsTests` cover the preference default and persistence, the bundled manifests in the app bundle, and the alternative-model row text.
- `-scheme LocalFlowServer test` passed. The `flowd-speech` target builds. The iOS app and its tests compile for the generic iOS Simulator (`build` and `build-for-testing`); no simulator was booted.
- `go test ./internal/speech/... ./internal/remote/...` passed. `swift format lint --strict` over the `make check` paths, `check-core-imports.sh`, `check-speech-worker-imports.sh` and `plutil -lint` on the project all pass.
- Real-weight load checks (opt-in `testOptInPinnedRuntimeLoadsDecodesAndReleases`, synthetic silence only, CTC booster loaded with one Dictionary term):
  - v3 from the installed `~/Library/Application Support/LocalFlow/Models/parakeet-v3` under 0.17.7, with and without the booster: passed.
  - Ultra: the 18 files were downloaded to `$TMPDIR` from the pinned revision. `ModelProvisioner.install` verified every size and SHA-256 in the new manifest, then the runtime loaded through the direct local path, decoded 160 and 239,360 silent samples, released, and handled the reload/cancel race: passed.
  - These runs say nothing about recognition quality, memory or energy. The one-off load times in the attachments (about 20 s for Ultra, 25 s for v3, cold, Debug build) are single observations that include first Core ML compilation, not measurements.
- Not run: `make check` as a whole (the parent runs it after merging), the iPhone simulator tests, the app UI by hand, and any benchmark.

## What is left

- Quality A/B before anyone treats Ultra as better. The steps are below; nothing here has been run.
- Resource acceptance: Ultra's encoder is int8 at 594 MB against v3's 445 MB. Its working set, load and release time and energy on the M5 are unmeasured (constitution principles 2 and 13).
- Booster calibration on Ultra: compare hint acceptance on the Feature 013 held-out terms, using `VocabularyBoostBenchmarkHarness` with the Ultra descriptor. If it regresses, disable the booster for Ultra in `FluidAudioEngineFactory`.
- Meeting finalization still uses Whisper Turbo; Ultra only reaches dictation and live previews. Server and iPhone selection were out of scope.
- The SDK upgrade changes code paths for v3 too. Its effect on v3 transcripts should be checked with the same baseline script (v3 on this branch vs v3 on `main`) before Ultra is compared.
- Each `swift package resolve` now downloads the unused 87 MB NeMo archive. It is not linked into the app.

## How to run the A/B with `scripts/quality-gates.py`

Use the frozen public corpus (`scripts/acquire-quality-corpus.py`) or the private held-out corpus. Keep the hardware, power state and build the same for every run, and don't run anything else heavy meanwhile. Paths below are examples. A model root must not sit under `/var` (the provisioner rejects symlinks); use `/private/var/...` or a folder in your home directory.

```sh
# 0. Provision Ultra once: Settings › Models › Parakeet Ultra › Download…
#    It installs to ~/Library/Application Support/LocalFlow/Models/parakeet-ultra.
V3="$HOME/Library/Application Support/LocalFlow/Models/parakeet-v3"
ULTRA="$HOME/Library/Application Support/LocalFlow/Models/parakeet-ultra"

# 1. SDK-only change first: v3 on main vs v3 on this branch (same corpus, same machine).
scripts/evaluate-quality-baseline.sh "$CORPUS" ~/agent-runs/<date>-ultra-ab/v3-branch "$V3"

# 2. Ultra, same script; the test reads the descriptor name from the environment.
TEST_RUNNER_LOCALFLOW_SPEECH_DESCRIPTOR=parakeet-ultra \
  scripts/evaluate-quality-baseline.sh "$CORPUS" ~/agent-runs/<date>-ultra-ab/ultra "$ULTRA"

# 3. Score Ultra against the v3 baseline through the acceptance gates (quality-gates.py).
python3 scripts/transcription-quality.py score "$CORPUS/manifest.json" \
  ~/agent-runs/<date>-ultra-ab/ultra/run-a ~/agent-runs/<date>-ultra-ab/ultra/scores/gates.json \
  --baseline ~/agent-runs/<date>-ultra-ab/v3-branch/run-a \
  --reviews <ultra reviews> --baseline-reviews <v3 reviews>
```

The production-geometry variant works the same way:
`TEST_RUNNER_LOCALFLOW_SPEECH_DESCRIPTOR=parakeet-ultra scripts/evaluate-production-pipeline.sh SHORT LONG OUT "$ULTRA"`.
Following the audit, review every clip that got worse and every meaning, name or number change before changing the default. Don't rely on the WER tolerance alone.
