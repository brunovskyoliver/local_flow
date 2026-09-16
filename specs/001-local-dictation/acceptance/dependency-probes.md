# Dependency probes

Recorded 2026-09-16 on Apple Silicon macOS 26.6.2 with Xcode 26.4.1
(17E202), Swift 6.3.1. The application targets macOS 14; no macOS 14 host
was available for execution.

## Completed

- Xcode resolved FluidAudio 0.15.7 at
  `41540ea237350afe5117a082b5c28eda642d0612` with `traits = ()`.
  The resolved graph excludes NeMo. GRDB.swift 7.10.0 resolves at
  `36e30a6f1ef10e4194f6af0cff90888526f0c115`.
- The native adapter compiles against the pinned public `AsrModels` initializer,
  `AsrManager`, explicit v3 decoder state, nil language and asynchronous cleanup.
- LocalFlow opens explicit local CoreML URLs. It does not call FluidAudio's
  download-capable model convenience loaders.
- Synthetic lifecycle tests cover exclusive ownership, stale leases and joining
  cancelled preparation. These do not measure CoreML cancellation or release.
- An incomplete manifest fails before runtime construction.

## Model decision and outstanding gate

Use the pinned quantized `Encoder.mlmodelc`, as approved by the user. The
previous FP16 label was incorrect. Keep source revision
`7dd20fe6b1797d35f5e3307e8b1732d9a178edfe`; do not substitute another encoder.
The dependency's quantization enum is not a claim that all encoder weights use
uniform eight-bit precision.

Repository metadata lists 21 selected files totaling 483,105,645 bytes. LFS
SHA-256 values are recorded where available. Nine ordinary Git files still need
SHA-256 calculation from local bytes. Their pinned Git blob identities are
recorded to verify provenance before completing the manifest. It deliberately
remains `complete: false` and cannot be installed.

No model files or speech fixtures were downloaded. The user will supply them
later. Run `python3 scripts/complete-model-manifest.py /absolute/model/root`
with the pinned local files, then rebuild the app and explicitly import that
folder. This tool makes no network requests.

**Unrun:** real CoreML construction, macOS 14 execution, automatic Slovak/
English/mixed recognition, timestamp/seam accuracy, runtime cancellation and
cleanup, offline network observation, model RSS and latency. Compilation and
synthetic tests do not satisfy T003 or authorize claiming runtime acceptance.

## Subsequent authorized model download

The user subsequently authorized downloads. All 21 pinned files (483,105,645
bytes) were downloaded to `build/model-downloads/parakeet-v3-7dd20fe6b1797d35f5e3307e8b1732d9a178edfe/`.
Each file passed its pinned LFS SHA-256 or Git blob check. The manifest now
contains every SHA-256 and is marked complete. This supersedes the missing-model
and incomplete-manifest status above. The pinned model card is retained under
`docs/licenses/`. Model loading, speech accuracy and hardware checks remain
unrun; consented speech recordings have not been supplied.

## Local runtime probe after assets became available (2026-09-16)

The downloaded 21-file quantized model set was independently imported and hashed
through ModelProvisioner into a temporary private installation, then loaded by
ModelLifecycleCoordinator through the actual FluidAudio adapter. The temporary
installation was removed afterward; downloaded source files were unchanged.

The opt-in RuntimeCompatibilityTests run passed **2 tests, 0 failures, 0 skips**.
It exercised local AsrModels construction, language:nil decoding of 160-sample
(padded) and 239,360-sample generated-silence windows, bounded result/timestamp
validation, ordinary finish/release, reload and a cancellation/decoding race.
The race joins the admitted operation but does not establish that cancellation
landed during an uninterruptible CoreML instruction. No real speech was used.

Result: `build/DerivedData/Logs/Test/Test-LocalFlow-2026.09.16_14-42-58-+0200.xcresult`.
The retained attachment is under `build/acceptance-us1/runtime-attachments/`.
Host: Apple M5 MacBook Pro, macOS 26.6.2 (25G83), Debug arm64/macOS 14 deployment
target, Xcode 26.4.1 / Swift 6.3.1, FluidAudio 0.15.7, pinned model revision
`7dd20fe6b1797d35f5e3307e8b1732d9a178edfe`. Observed first load was 14.115 seconds;
the combined two-window decode and ordinary release took 1.376 seconds. These
single Debug observations include local compilation/cache conditions and are not
resource-budget or latency acceptance measurements.

Pinned SDK source review found that AsrManager.cleanup() clears its model
references but starts an unstructured Task for the internal sharedMLArrayCache.
That cache has no public completion barrier. Awaiting the actor method therefore
does not establish completion of cache clearing or settled RSS. Its initializer
also schedules cache prewarming and progress setup. The cache prewarms five
arrays for each of three fixed shapes; the progress emitter uses an unbounded
stream internally, but our <=239,360-sample calls take the short-window path and
do not emit accumulating long-audio progress. No dependency source or pin was
changed. Full asynchronous cache-release evidence remains an open T003/T023 gate.

Reproduce explicitly from the repository root:

```sh
TEST_RUNNER_LOCALFLOW_MODEL_PROBE_ROOT="$PWD/build/model-downloads/parakeet-v3-7dd20fe6b1797d35f5e3307e8b1732d9a178edfe" \
xcodebuild -quiet -project apps/macos/LocalFlow.xcodeproj \
  -scheme LocalFlow -configuration Debug \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath build/DerivedData \
  CODE_SIGNING_ALLOWED=NO -only-testing:LocalFlowTests/RuntimeCompatibilityTests test
```

Ordinary `make check` passed **113 tests, 0 failures, 1 explicit opt-in skip**.
It does not load models. No consent/license/reference speech fixtures were found
in `fixtures/` or `build/model-downloads/`; their location was requested from the
user. Language accuracy, speech seams, real microphone insertion, macOS 14
execution, observed offline traffic and M5 resource acceptance remain unrun.

## Licensed speech-fixture follow-up (2026-09-16)

The user authorized downloading the remaining fixtures. Twenty natural FLEURS
recordings (ten Slovak, ten English) and their reference/license metadata are now
available in `build/speech-fixtures/`; ten synthetic mixed stress clips were
prepared from those recordings. This supersedes earlier missing-fixture statements.
All thirty ran through the actual local adapter. WER was 10.58% Slovak, 7.18%
English and 23.87% synthetic mixed, with six mixed results marked incomplete.
Meaning review, authentic mixed fixtures and live microphone checks remain open.
See [accuracy evidence](accuracy.md) for per-fixture scores, provenance and commands.

## Supported platform correction (2026-09-16)

The owner confirmed that macOS 14 is not a targeted device: this development
machine and macOS 26 or later are. The macOS 14 execution item recorded above as
unrun is therefore withdrawn as an acceptance requirement, not passed. Every
measurement and host record above stands exactly as it was taken, including the
macOS 14 deployment target in force at the time. Remaining T003/T023 gates are
unchanged: real language and seam behavior, and the SDK's asynchronous cache
clear. See ADR 0001's amendment.
## Owner acceptance, 2026-09-16

The owner exercised the signed development build on the Apple M5 MacBook Pro,
macOS 26.6.2 (25G83), and reported the results below. Recorded as given; the
measurements and probe results above are unchanged.

- Real Slovak and English recognition works through the app's own adapter, with
  the language behavior described in the accuracy record.
- The asynchronous SDK cache-clear finding above is unchanged: the pinned
  `AsrManager.cleanup()` still has no public completion barrier. Ordinary use
  cannot observe that; it remains a source-level limitation of the pinned SDK,
  now recorded rather than pending.
