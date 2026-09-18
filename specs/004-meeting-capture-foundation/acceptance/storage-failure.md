# Storage failure acceptance (SC-006, live half)

**Status: not run.** Deterministic half: `MeetingCoordinatorTests.testWriteFailureStopsCaptureWithinTheBoundAndKeepsWrittenAudio`
(latch detected by the 250 ms poll, `interrupted` with `storage_write_failed`, earlier
bytes kept, ring drops counted) and `MeetingTrackWorkerTests` (latch, no growth).

Procedure (quickstart.md "Storage failure"): `hdiutil create -size 20m …`, mount, run the
app with `LOCALFLOW_MEETING_ROOT=<mount>/Meetings`, record until the volume fills.

| Measure | Value |
| --- | --- |
| Hardware / macOS / build | unmeasured |
| Time from the failed write to the notice | unmeasured (gate: ≤ 5 s) |
| Final state and reason | unmeasured (expected `interrupted`, `storage_write_failed`) |
| Last complete file playable | unmeasured |
| RSS before failure / after the notice (delta) | unmeasured |
| Start on a volume with < 500 MB free refused with the exact text | not run |
| Start with 500 MB–2 GB free shows "Less than 2 GB free" | not run |
