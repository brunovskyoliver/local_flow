# Long-run memory acceptance (SC-003, SC-010)

**Status: unmeasured.** Neither the 10–15 minute development run (T044) nor the 60-minute
reference run (T080) has been recorded. No unit test is presented as evidence; the
deterministic bound checks are `MeetingTrackWorkerTests.testThirtySimulatedMinutesKeepEveryStructureBounded`
and `MeetingSampleRingTests`.

## Development run (T044) — development run, not acceptance

Not run. Conditions to record: both sources, notes typed, one pause/resume,
`LOCALFLOW_RESOURCE_RECORDING=1`, `scripts/memory-report.sh <pid>` sampled every 10 s.

| Measure | Value |
| --- | --- |
| Hardware / macOS / build / commit | unmeasured |
| RSS series | unmeasured |
| Slope over the settled window | unmeasured |
| Peak | unmeasured |

## Reference run (T080) — 60 minutes on the reference M5 MacBook Pro

| Measure | Value | Gate |
| --- | --- | --- |
| Hardware / macOS / build / commit / codec settings / conditions | unmeasured | identified |
| Starting RSS | unmeasured | |
| Settled RSS | unmeasured | |
| Peak RSS | unmeasured | |
| Post-stop RSS | unmeasured | no capture object retained |
| Fitted slope over the settled window | unmeasured | < 1 MB per 10 min |
| Peak overhead above idle | unmeasured | ≤ 100 MB |
| Per-track file sizes | unmeasured | |
| Dropped frames | unmeasured | |
| Write errors | unmeasured | |
| Finalization duration | unmeasured | |
| Comparison with the T044 development run | unmeasured | |
| Model lifecycle instrumentation shows no load (SC-010) | unmeasured | no load |

Codec settings for the record: AAC-LC ADTS, 48 kHz, microphone mono 64 kbit/s, system
stereo 96 kbit/s (mono when the source is mono), 4,096-frame input blocks, 8-packet output
blocks, 5 s sync and heartbeat.
