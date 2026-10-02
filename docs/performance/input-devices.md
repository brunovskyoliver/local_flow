# Input devices: connect time and delivery delay

Feature 019 picks the first connected microphone from a ranked list. Two starting values in the code depend on how fast a device delivers audio:

| Value | Where | Starting value |
| --- | --- | --- |
| Connect limit: how long a started device may stay silent before the next entry is tried | `DictationCoordinator.connectLimit` | 3 s |
| Release tail cap: the longest capture keeps running after key release | `DictationCoordinator.releaseTail(maxDelay:)`, `AudioCaptureService.maximumTail` | 500 ms |

The tail itself is `0` at or under 50 ms of delivery delay, otherwise the session's maximum delay plus 25 ms, capped at 500 ms. It is measured per dictation, so the numbers below only check that the starting values fit.

## Measured iPhone Microphone numbers (SC-005)

Unmeasured. These come from quickstart §4 step 6 on real hardware, at least 5 cold starts (iPhone idle 5 minutes) and 5 warm starts (used under 30 s ago).

| Start | n | Connect p50 | Connect p95 | Delay p50 | Delay p95 | Mac / macOS | iPhone / iOS |
| --- | --- | --- | --- | --- | --- | --- | --- |
| Cold | 0 | unmeasured | unmeasured | unmeasured | unmeasured | | |
| Warm | 0 | unmeasured | unmeasured | unmeasured | unmeasured | | |

## Where the numbers come from

- Each dictation logs one line in the `input-device` category: `input kind=… rank=… fallbacks=… connect_ms=… delay_max_ms=… tail_ms=… name=<private>`.
- `inputDevices.timings.v1` in `UserDefaults` keeps, per device, the last 16 connect times and session-maximum delays.
- `ResourceRecorder` records `inputConnectDuration`, `inputDeliveryDelay`, `inputTailDuration` and `inputFallbackCount`, labelled by device kind.
- The spike harness `InputDeviceProbeHarness` (quickstart §2) prints time to first buffer, time to first non-zero buffer and per-buffer delay for every input.

## Decision rule

If the measured delay p95 is above 450 ms or the connect p95 above 2.5 s, the 500 ms cap or the 3 s limit is too tight. Raise it with the owner before acceptance; changing either value is the owner's call.
