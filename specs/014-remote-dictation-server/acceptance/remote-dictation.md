# Remote dictation and fallback (T082), provisional run

Run on 2026-09-28. **Provisional:** the server ran on the owner's M5 (the same Mac as the client) behind a Cloudflare quick tunnel, not the Mac mini. T082 stays open until it is repeated there. Conditions are as in [enrollment.md](enrollment.md). A watcher script performed each server-side action 3 s after it saw the dictation's connection held for 1.5 s; the owner dictated about 20–45 s each time.

## Results

| Row | Expected | Observed | Result |
| --- | --- | --- | --- |
| Dictate 20 s, release | label "Server", rewrite follows, window 0 before the end | 6 dictations of 20–39 s, all `server`. Window 0 was recognized about 15 s in, while recording. Tail after release: 112–176 ms (server `release_ms`). Rewrite over the channel 940–1,472 ms | pass |
| Dictionary term, booster installed | same result as local | not run; covered by T093 (SC-005) | — |
| Stop flowd mid-dictation, local model installed | "Local after server failure (unreachable)" | flowd stopped 3 s in (log: `code=shutdown`); history `local_after_server_failure`, reason `unreachable`, 456 characters inserted. Rewrite went through the restarted server | pass |
| `--debug-busy` (debug build) | immediate local fallback, reason `busy` | server answered `busy` 612 ms after the channel opened; history `local_after_server_failure`, reason `busy`, 527 characters inserted | pass |
| No local model, server unreachable | "Waiting for server", retried, shown for review | not run | — |
| Revoke the device mid-dictation | ends within 1 s, local fallback, "Removed from the server" | not run; it ends this enrollment | — |
| Kill `flowd-speech` mid-dictation | local fallback `worker_unavailable`; worker restarted; next dictation on the server | worker killed 3 s in, before its first window was due. flowd restarted it in 1.0 s (`worker_restart_in_ms=1000`, ready 349 ms later). The dictation then completed on the server with all 3 windows: `server`, no fallback | differs; see below |

## Notes

- **Worker crash.** The expected fallback happens only when a window is due while the worker is down. Here the worker was back 1.3 s after the kill, long before window 0, so the crash was invisible to the user. The `worker_unavailable` fallback was not exercised on hardware; it is covered by the worker-supervision suite. A hardware check needs the kill timed during a window job, or the worker kept down.
- **Server restart while recording.** An earlier attempt killed flowd itself by mistake (the watcher matched flowd's `--speech-worker` argument). launchd restarted flowd within 1 s, and the client finished the dictation on a new channel from the audio it held (2 windows, 26 s): `server`, nothing lost.
- **Tail latency.** The server recognized the tail in 112–176 ms once warm. The first dictation after idle took 1,496 ms, which is close to the 1.5 s fallback threshold. That run's dictation was shorter than one window, and the worker had just become active. T093 must include a first-after-idle case.
- These are single runs on the M5 with three 4B models loaded; they are not SC-001 or SC-003 measurements.
