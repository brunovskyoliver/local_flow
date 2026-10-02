# Quickstart: validating input device priority

Run order: §1 automated checks, §2 spike (before the capture code is written), §3–§7 device runs, §8 resource report. Record each run in `specs/019-input-device-priority/acceptance/` with date, Mac model, macOS build, iPhone model and iOS build, and the LocalFlow build.

## Prerequisites

- Target Mac (M5) with a USB microphone, a Bluetooth headset, and an iPhone on the same Apple Account with Continuity Camera on (iOS Settings › General › AirPlay & Continuity).
- An external display, keyboard and mouse for clamshell runs.
- Microphone permission granted to LocalFlow.

## 1. Automated

```sh
make check
```

Targeted unit runs. Scope with `-only-testing`; the full suite beeps.

```sh
xcodebuild test -quiet -project apps/macos/LocalFlow.xcodeproj -scheme LocalFlow \
  -destination "platform=macOS,arch=arm64" -derivedDataPath build/DerivedData \
  -only-testing:LocalFlowTests/InputDeviceResolverTests \
  -only-testing:LocalFlowTests/InputDevicePriorityStoreTests \
  -only-testing:LocalFlowTests/AudioCaptureTests \
  -only-testing:LocalFlowTests/DictationCoordinatorTests \
  -only-testing:LocalFlowTests/MeetingCoordinatorTests \
  -only-testing:LocalFlowTests/InputDeviceMigrationTests \
  -only-testing:LocalFlowTests/MicrophonesViewModelTests \
  -only-testing:LocalFlowTests/PendingRemoteDictationStoreTests \
  -only-testing:LocalFlowTests/PendingRemoteRetrierTests \
  -only-testing:LocalFlowTests/MacCompatibilityTests
```

Expected: every case listed in [contracts/input-device-capture.md](contracts/input-device-capture.md) passes, existing `AudioCaptureTests` pass unchanged, `MacCompatibilityTests` sees `input-device-v18` last in the frozen migration list, and `InputDeviceMigrationTests` shows existing rows kept with NULL device fields.

## 2. Spike (research S1–S6)

Run `InputDeviceProbeHarness` (a test-target harness that skips unless `LOCALFLOW_INPUT_PROBE=1` reaches the test runner; `xcodebuild` forwards it only with the `TEST_RUNNER_` prefix). For each connected input it prints UID, model UID, name, transport type and alive flag, opens the device through `kAudioOutputUnitProperty_CurrentDevice`, and records the format, time to first buffer, time to first non-zero buffer and per-buffer delivery delay for 5 s.

```sh
TEST_RUNNER_LOCALFLOW_INPUT_PROBE=1 xcodebuild test -quiet -project apps/macos/LocalFlow.xcodeproj \
  -scheme LocalFlow -destination "platform=macOS,arch=arm64" \
  -derivedDataPath build/DerivedData -only-testing:LocalFlowTests/InputDeviceProbeHarness
```

| Spike | Check | Pass |
| --- | --- | --- |
| S1 | iPhone listed with a Continuity transport type | Transport `ccwl` or `ccwd`, or the fallback marker recorded |
| S2 | USB mic ranked, MacBook mic as macOS default, record 5 s | Probe level moves only when speaking into the USB mic |
| S3 | Close the lid (clamshell), rerun the listing | Built-in input absent, not alive, or `AppleClamshellState` true |
| S4 | iPhone cold (idle 5 min) and warm (used < 30 s ago), 5 each | Times recorded; note whether zero buffers come first |
| S5 | Record on a pinned USB mic, change the macOS default input | Note whether a configuration change fired |
| S6 | iPhone format | Sample rate and channels recorded |

Save the output as `acceptance/spike-<date>.md` and pick the research fallbacks it calls for before writing §R2–R7 code.

## 3. Ranking and fallback (US1, SC-002)

1. Settings › Microphones: add the USB mic and MacBook mic; order USB, MacBook, System default. Set the macOS default to the MacBook mic.
2. Dictate. Expected: the caption says the USB mic's name; History shows "Microphone: <USB name>".
3. Unplug the USB mic. Expected: its row stays first with "Not connected".
4. Dictate 20 times. Expected: all 20 use the MacBook mic; "Using MacBook Pro Microphone" appears on the first only.
5. Plug the USB mic back in and dictate. Expected: the USB mic is used.
6. Clamshell: close the lid with only System default and MacBook mic ranked below an absent USB mic. Expected: dictation uses the System default entry, not the closed MacBook mic.
7. Remove every device the list names and set no default (or disable inputs). Expected: "No microphone available" with a Microphones… button; nothing inserted.

## 4. iPhone Microphone (US2, SC-003, SC-004, SC-005)

1. Rank iPhone Microphone first. MacBook closed, iPhone locked, landscape, still, nearby.
2. Hold the key. Expected: "Connecting to iPhone Microphone…", then the waveform.
3. 20 dictations: start speaking after the waveform appears, say a sentence that begins with "Alpha" and ends with "Omega", release immediately after "Omega". Pass: at least 19 contain both words.
4. Make the iPhone ineligible (Continuity Camera off, or out of range). 10 dictations. Pass: each starts on the next device within 3.5 s of key-down, measured from the `input-device` log line.
5. Release during "Connecting…". Expected: nothing inserted, no error beyond the too-short notice.
6. Export cold and warm connect times and delivery delays from the timing profile and log (5 cold, 5 warm minimum) into `acceptance/iphone-timing-<date>.md`. If the measured delay p95 is above 450 ms or connect p95 above 2.5 s, raise it with the owner before acceptance (spec assumption on the 3 s and 500 ms values).

## 5. Indicator and history (US3)

Dictate once on each of two ranked devices. Expected: caption and History name the right device. Unplug the first and dictate twice. Expected: the fallback notice appears once.

## 6. Meetings (US4)

1. Rank USB first, MacBook second. Start a meeting. Expected: the mic track records from USB (check the segment's `input_device_name`).
2. Unplug USB after 1 minute, keep talking for 1 minute, stop. Expected: one `device_changed` segment, the transcript shows "Microphone changed to MacBook Pro Microphone", and the first minute is intact.
3. Start another meeting on the MacBook mic with USB unplugged, then plug USB in. Expected: no switch.

## 7. Upgrade (SC-007, FR-016)

On a build from `main` before this feature, make 20 dictations and note results and the `Capture stopped` timings. Install this build. Expected: Settings › Microphones shows only "System default"; 20 dictations give the same results, with no `connecting` step visible and tail 0 in every `input-device` line.

## 8. Resource report (SC-001, SC-006)

- SC-001: 50 dictations with a wired or built-in mic ranked first, and 50 on the pre-feature build. Compare median key-down → `recording` time from the dictation log. Pass: ≤ 50 ms slower.
- SC-006: recording overhead (constitution: 100 MB above idle, excluding ML working sets) for the built-in mic, the USB mic and the iPhone, read from the diagnostics snapshot during a 60 s dictation.

Write both to `acceptance/resources-<date>.md` with hardware, build and conditions. Unmeasured values stay marked unmeasured.
