# Validation guide

The v2 acquisition, runner and scorer are implemented. The standalone assembler and frozen-window replay are implemented. Production integration, normalization, vocabulary and full-feature acceptance remain separate work.

Phase 4 now includes bounded production window admission, immutable quality-detail types, atomic full-envelope storage and tested coordinator recovery support. Ordinary dictation still uses historical assembly and saves without quality detail until T024's adoption gate is resolved. See [Phase 4 implementation evidence](acceptance/phase4-persistence.md).

## Prerequisites

Use Apple Silicon macOS with Xcode, the existing pinned packages and Go/Python development tools. Real resource acceptance requires Apple M5 under the [memory protocol](../../docs/performance/memory-budget.md). Provision the pinned Parakeet model explicitly before going offline. Use a signed installed app with microphone/Accessibility permissions for end-to-end acceptance.

Retain the original 30 fixtures unchanged as a legacy subset. Reconstruct the 80-clip public corpus using [fixture-acquisition.md](acceptance/fixture-acquisition.md). Common Voice is optional when authorized archives/access become available. Authentic within-speaker switching is a separate coverage gap and does not block T013/T014. Human meaning review and resource acceptance remain separate.

## Repository checks, available now

From the repository root:

```sh
make check
.specify/scripts/bash/check-prerequisites.sh --json --require-spec
```

Expected: format/schema/Go/Python/deterministic XCTest checks pass and planning artifacts are discovered. Opt-in model/speech tests may skip without explicit inputs. These checks do not establish speech quality, microphone behavior or memory acceptance.

## Reproduce the unchanged baseline before pipeline edits

With existing local assets and recordings, create a new private output directory. Do not overwrite prior acceptance evidence:

```sh
mkdir -m 700 build/quality-002-baseline
TEST_RUNNER_LOCALFLOW_MODEL_PROBE_ROOT="$PWD/build/model-downloads/parakeet-v3-7dd20fe6b1797d35f5e3307e8b1732d9a178edfe" \
TEST_RUNNER_LOCALFLOW_SPEECH_FIXTURE_ROOT="$PWD/build/speech-fixtures" \
TEST_RUNNER_LOCALFLOW_SPEECH_MANIFEST="$PWD/fixtures/audio/manifest.json" \
TEST_RUNNER_LOCALFLOW_ACCURACY_OUTPUT="$PWD/build/quality-002-baseline/results.json" \
xcodebuild -quiet -project apps/macos/LocalFlow.xcodeproj \
  -scheme LocalFlow -configuration Debug \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath build/DerivedData \
  CODE_SIGNING_ALLOWED=NO \
  -only-testing:LocalFlowTests/RuntimeCompatibilityTests/testOptInSpeechFixtures test
python3 scripts/dictation-accuracy.py fixtures/audio/manifest.json \
  build/quality-002-baseline/results.json build/quality-002-baseline/report.json
```

Repeat with a separate directory and compare exact text, window and completeness hashes for all 30 IDs. Record build, model, manifest and settings. Historical rates are observations to reproduce, not expected passing acceptance. Do not download missing recordings/models as part of offline transcription.

## V2 public baseline evaluation

Acquire and freeze `build/quality-public-v2/manifest.json` under the [evaluation contract](contracts/quality-evaluation.md). Use the new test and a nonexistent private run directory:

```sh
TEST_RUNNER_LOCALFLOW_MODEL_PROBE_ROOT="$PWD/build/model-downloads/parakeet-v3-7dd20fe6b1797d35f5e3307e8b1732d9a178edfe" \
TEST_RUNNER_LOCALFLOW_SPEECH_FIXTURE_ROOT="$PWD/build/quality-public-v2" \
TEST_RUNNER_LOCALFLOW_SPEECH_MANIFEST="$PWD/build/quality-public-v2/manifest.json" \
TEST_RUNNER_LOCALFLOW_QUALITY_OUTPUT="$PWD/build/quality-public-baseline-a" \
xcodebuild -quiet -project apps/macos/LocalFlow.xcodeproj \
  -scheme LocalFlow -configuration Debug \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath build/DerivedData \
  CODE_SIGNING_ALLOWED=NO \
  -only-testing:LocalFlowTests/RuntimeCompatibilityTests/testOptInQualityFixtures test
mkdir -p build/quality-public-scores && chmod 700 build/quality-public-scores
python3 scripts/transcription-quality.py score build/quality-public-v2/manifest.json \
  build/quality-public-baseline-a build/quality-public-scores/score-a.json
python3 scripts/transcription-quality.py score build/quality-public-v2/manifest.json \
  build/quality-public-baseline-a build/quality-public-scores/score-b.json
cmp build/quality-public-scores/score-a.json build/quality-public-scores/score-b.json
```

Expected: byte-identical score reports; every selected fixture accounted for, including failed/not-run; stages, categories, counts and unknown measurements explicit. Repeat recognition in a new run directory and use `compare` to report differences. Create `review-template`, obtain actual reviewer verdicts for exact hashes, then score with `--reviews` and `--require-acceptance`. An unreviewed or incomplete corpus must fail acceptance even if numerical WER improves.

Use controlled assembly replay and one-factor recognition experiments to distinguish omissions inside windows from boundary losses. Keep synthetic mixed results separate from authentic switching. Re-score the unchanged baseline with v2 rules before comparing it to v2 candidates.

## Deterministic and offline scenarios, after implementation

Run `make check` after adding the new suites to the existing check script. Tests must exercise the [pipeline bounds](contracts/transcription-pipeline.md), [normalization cases](contracts/normalization-vocabulary.md) and [storage model](data-model.md), including:

1. Replay reviewed joins with repetitions, missing evidence and language switches. Supported overlap appears once; ambiguous spans remain recoverable/incomplete and never auto-insert.
2. Normalize each positive/negative case twice. Outputs are identical on the second pass, identifiers/numbers/diacritics survive, and only approved lexical mappings change text.
3. Add/edit/disable/delete vocabulary, restart and edit during dictation. Revisions remain stable for the active session; conflicts/limits preserve existing entries.
4. Save a full result, restart and compare exact stage bytes/hashes. Open legacy history. Confirmed Delete removes detail; retry with mismatched provenance is rejected.
5. Inject capacity exhaustion, disk failure, model/permission failure, cancellation and restart after interrupted insertion. Preserve completed text, report incomplete/unsaved accurately, clean ordinary audio and retain existing insertion guards.

Disable network and stop the Go server. Run real dictation with provisioned assets, inspect raw/normalized history, search/copy and explicitly insert reviewed results. Record signed-app microphone and delivery outcomes separately from fixture replay.

## Hardware and engine decision

Run the existing `scripts/dictation-benchmark.sh` according to its usage and the memory protocol with the signed app initially stopped. Use `scripts/memory-report.sh PID [samples]` for bounded supplemental RSS samples. Collect all 20 cycles, capture-only overhead, model load/release, stage times, queue peaks and maximum-vocabulary/180-second workloads. Include default cooldown, rapid reuse, keep-loaded and manual release. Compare baseline/new pipeline on matching hardware/build conditions.

Publish `specs/002-transcription-quality/acceptance/quality-decision.md` during implementation with run hashes, per-fixture/group results, reviewer hashes, limitations and retain/replace/fallback disposition. If adoption is proposed, demonstrate every SC-007 gate, including three resource/timing repeats and sequential failed/cancelled handover. Report the inherited mixed <=15% target separately; a retention decision does not pass it. Never fill missing measurements with estimates.

## Replay the frozen corpus through the assembler

```sh
scripts/replay-quality-assembly.sh build/quality-public-v2 \
  build/quality-public-v2-baseline/run-a build/quality-assembly-new-output
```

Use a new output directory. The command loads no model, preserves the frozen raw evidence, runs the Swift assembler twice and scores each run twice. Results expose raw and assembled separately; normalization stays unavailable. See [assembly evidence](acceptance/assembly.md) for category deltas, every regression and reproduction hashes. Production dictation integration remains with the result-envelope/storage tasks.

## Phase 5 formatting and selected history detail

Run the deterministic checks with `make check`. For the focused suite:

```bash
xcodebuild -quiet -project apps/macos/LocalFlow.xcodeproj -scheme LocalFlow \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO \
  -only-testing:LocalFlowTests/TranscriptNormalizerTests \
  -only-testing:LocalFlowTests/HistoryViewModelTests \
  -only-testing:LocalFlowTests/HistoryQueryTests test
```

History's Details action displays the selected saved envelope. New ordinary dictation now runs contiguous assembly and empty-vocabulary normalization and saves all stages; earlier rows retain the legacy explanation. Use `make run` to build and launch the signed development app. See [production integration](acceptance/production-integration.md) for a short practical check and the remaining acceptance work.

## Phase 7: production pipeline corpus run and instrumentation

Run the production stages (fixed contiguous windows, `TranscriptAssembler`, empty-vocabulary `TranscriptNormalizer`) over both frozen corpora, twice each, and score every run twice. Nothing is downloaded; the model root must already be provisioned.

```sh
scripts/evaluate-production-pipeline.sh build/quality-public-v2 build/quality-public-long-v1 \
  build/production-acceptance \
  build/model-downloads/parakeet-v3-7dd20fe6b1797d35f5e3307e8b1732d9a178edfe
python3 scripts/summarize-production-pipeline.py --manifest build/quality-public-v2/manifest.json \
  --production-a build/production-acceptance/production-short-a \
  --production-b build/production-acceptance/production-short-b \
  --production-score build/production-acceptance/scores/production-short-a-score1.json \
  --production-score-b build/production-acceptance/scores/production-short-b-score1.json \
  --contiguous-score build/chunk-acceptance/final-v2/scores/contiguous-fixed-short-a.json \
  --historical-score build/quality-public-scores/score-a-1.json \
  --output build/production-acceptance/summary-short.json
```

The summary prints counts, rates and hashes only. Results are in [mixed-language.md](acceptance/mixed-language.md), [quality-results.md](acceptance/quality-results.md) and [quality-decision.md](acceptance/quality-decision.md).

Stage timings, text/metadata sizes, queue peaks and model load/release now reach the local recorder when the app runs with `LOCALFLOW_RESOURCE_RECORDING=1`; `scripts/dictation-benchmark.sh` rows carry the same figures. Units and the unexecuted M5 run plan are in [resources.md](acceptance/resources.md); the signed-app offline checklist is in [offline-recovery.md](acceptance/offline-recovery.md).
