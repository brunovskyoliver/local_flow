# Throughput spike

`MeetingThroughputTests.swift` is compiled in `LocalFlowTests` so it can import
`ModelLifecycleCoordinator` with `@testable`. This replaces the plan's suggested
UI-test placement: the UI-test runner cannot directly access internal app types.
No new target, runtime owner, UI automation or transcript store is introduced.
The app's existing XCTest startup guard suppresses normal application startup.

The model measurement skips unless `LOCALFLOW_MEETING_THROUGHPUT=1`.
The synthetic decoder check runs without a model. `make check` therefore does
not perform hardware acceptance. Release test runs use `ENABLE_TESTABILITY=YES`
without enabling `DEBUG` in the app.

## Prepare and run

From the repository root:

```sh
python3 scripts/download-speech-fixtures.py --download
python3 specs/005-live-meeting-transcription/acceptance/spike/prepare-fixture.py
# Use a new local model copy so the running app can keep its provisioning lock.
cp -cR "$HOME/Library/Application Support/LocalFlow/Models/parakeet-v3" \
  "$PWD/build/005-throughput-model"
specs/005-live-meeting-transcription/acceptance/spike/run.sh \
  "$PWD/build/quality-public-long-v1/long-1404b1e776253caea6df.wav" \
  "$PWD/build/005-throughput-fixtures/synthetic-meeting-600s.aac" \
  "$PWD/build/005-throughput-model" \
  "$PWD/build/005-throughput-run"
```

The output directory must be new. Six runs execute sequentially, each with a
fresh test-host process and a new lifecycle coordinator. The model is verified
from disk, then loaded through the lifecycle factory, used under one lease,
finished and explicitly unloaded. No download is performed during recognition.

The fixture generator uses the pinned online FLEURS corpus already described
in `fixtures/audio/README.md`. Reuse of verified downloads is intentional.
The output manifest records all turns, source hashes, transformations and AAC
hash. Audio and raw Xcode logs remain under ignored `build/`; public numeric
receipts can be copied into acceptance evidence. Recognition text is discarded.

## Measurement definitions

- Decode: `AVAudioFile` requests at most 4,096 source frames; channel average
  to mono; `AVAudioConverter` with `primeMethod = .none` to Float32 16 kHz.
  Source formats are restricted to 1–2 channels at 16–192 kHz.
- Storage: one input block, one mono block, one converted block, one
  239,360-sample recognition window. Flush converter EOF and transcribe any tail.
  No audio allocation grows with recording duration.
- Audio seconds: samples actually submitted divided by 16,000.
- Recognition seconds: sum of wall-clock durations around lifecycle `transcribe`.
  RTF excludes model verification, load, decode and release.
- Model load: lifecycle acquisition duration after on-disk verification.
- Decode/recognition wall time: decode loop through explicit runtime release;
  reported separately from inference RTF and not a production finalization time.
- RSS: current process resident bytes, sampled every 20 ms throughout model
  load, decode, inference and release. Peak is a sampled maximum, not an exact
  allocation peak. Before is after file/model verification and before load;
  after is immediately after explicit release, not a settled-memory measure.
- Decision: take the slowest of the six observed RTFs. Keep 96,000-sample live
  windows at RTF ≤ 0.25, otherwise use 64,000. Round the 1.5× finalization
  multiplier upward to the next 0.01 RTF. This precision makes "rounded up"
  explicit without rounding a small fraction up to a whole audio duration.

This isolates single-stream decode and recognition throughput. It does not
measure the future two-track mixer, segmentation, persistence, live latency,
long-run memory slope, echo, overlapping speech, recovery or accuracy.
