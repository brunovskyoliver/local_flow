# Calibration (thresholds, FR-012)

Status: Unmeasured

The calibration corpus described in `fixtures/audio/README.md` (≥ 8 consenting speakers,
≥ 3 recordings each on different days or devices, `manifest.json`, one `turns.json` per
recording) does not exist on this machine yet, so `IdentificationCalibrationHarness`
skipped. `IdentificationThresholds` still carries the provisional values (τ_high 0.72,
τ_medium 0.55, δ 0.10, support 2, minimum query speech 6 s) under
`tiers_v1@wespeaker_resnet34lm_256/1ed7a662`.

To run: build the corpus, then

```sh
TEST_RUNNER_LOCALFLOW_CALIBRATION_ROOT=/path/to/corpus \
TEST_RUNNER_LOCALFLOW_DIARIZATION_MODEL_SOURCE=build/model-downloads/speaker-diarization-coreml-1ed7a662fdc7109e36d822db793ee6eebdaf8594 \
TEST_RUNNER_LOCALFLOW_CALIBRATION_OUTPUT=specs/010-persistent-speaker-identification/acceptance/calibration.md \
xcodebuild -project apps/macos/LocalFlow.xcodeproj -scheme LocalFlow -destination "platform=macOS,arch=arm64" \
  -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO test -only-testing:LocalFlowTests/IdentificationCalibrationHarness
```

The harness writes the same-person and different-person distributions, false-accept and
miss rates at candidate thresholds, margin sensitivity and score spread by region length,
with hardware, macOS, build, model revision and policy version, in this file's shape.
T014 then freezes the chosen values in `IdentificationThresholds.swift` and T091 bumps
the policy versions if any value changed.
