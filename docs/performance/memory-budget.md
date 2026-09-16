# Memory and resource acceptance

Feature 001 client thresholds are accepted requirements from its clarified specification. Server figures remain initial engineering targets. None are benchmark results. Use decimal MB (1,000,000 bytes); `ps` RSS is KiB and must be converted.

| Workload | Target |
|---|---|
| Unloaded client idle | <= 150 MB RSS |
| Recording infrastructure | <= 100 MB above idle, excluding ML |
| Idle Go server | <= 100 MB RSS |
| Ordinary Go request | <= 250 MB RSS, excluding inference process |
| ASR / diarization | Measure separately on Apple M5; no invented model RSS cap |

No full-meeting decode, unbounded queue/cache/AsyncStream, client LLM, Python/Node client runtime or Electron UI. Measure infrastructure with a fake/no-model sink as well as full inference so model costs are not subtracted by guesswork.

## Feature 001 benchmark protocol

On the M5 / 32 GB machine, record OS, hardware, release build commit, dependency/model version and checksum, power conditions and language fixture IDs. Close unrelated heavy tasks. Provision models first and disable network. For the 20-cycle memory run, use consented synthetic/non-sensitive recordings, ten Slovak and ten English utterances of 5-15 seconds. Accuracy acceptance separately requires ten Slovak, ten English and ten mixed-language fixtures, each mixed fixture containing a language switch, with aggregate normalized WER <=15% per set. Include additional window-seam fixtures. Keep fixtures outside git until license and consent are recorded.

1. Launch with models unloaded, wait 30 seconds, sample RSS each second for 10 seconds; use median as baseline.
2. Run 20 sequential dictations alternating languages through the same coordinator as the real app. Record idle, post-load, recording peak, post-unload RSS; model load/unload duration, transcription duration and peak queue depth for each cycle.
3. Each cycle waits through the 30-second cooldown and up to 10 seconds for release, then samples unloaded RSS for 10 seconds. No speech is captured until readiness is indicated.
4. Repeat a rapid series inside cooldown to test reuse and stale timers. Exercise cancellation, load failure, permission revocation, queue overflow and the duration cap. Add a capture-only comparison for overhead.
5. Report all 20 rows, unloaded RSS slope and the difference between median cycles 1-5 and 16-20. Flag a positive fitted slope above 0.5 MB/cycle or late-minus-early above 10 MB for investigation. These are accepted Feature 001 regression thresholds, not ML working-set caps.

Acceptance: idle target met; each settled unloaded median within max(20 MB, 10% of baseline) of baseline; no retained engine or queued audio; no unexplained positive growth flag; capture-only overhead target met. A failed target needs investigation and explicit spec/ADR review, not silent widening. These tolerances were accepted during Feature 001 clarification on 2026-09-16. Changes require explicit review after measurement.

`scripts/memory-report.sh PID [samples]` supplies a bounded RSS CSV sampler today. The feature must add coordinator phase events and the 20-cycle driver during implementation. No ASR benchmark has been run in initialization. Future meeting tests compare 20 minutes with two hours, including finalization, diarization and disk failures.
