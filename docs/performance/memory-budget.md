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

## Feature 005 transcript bounds and evidence

[Phase 2 throughput evidence](../../specs/005-live-meeting-transcription/acceptance/throughput.md) contains six real-model runs on an Apple M5 with 32 GiB RAM. The first load peaked at 2,812.79 decimal MB process RSS; cached-load runs peaked at 663.98–668.30 MB. Pre-load test-host RSS was 578.67–580.42 MB, and immediate post-release RSS was 627.11–1,179.40 MB. These are measured process totals, not an isolated model working set or settled unloaded-client baseline. The harness omitted the transcript store, UI, normalization and two-track mixing. No independent recognition-only memory budget is established.

| Transcript allocation | Declared capacity / policy |
| --- | --- |
| Analysis tap per track | 32 × 4,096 frames × up to 8 channels; drop and count |
| Mixer staging per track | 16,000 Float32 samples; defer conversion at capacity |
| Analysis queue | 480,000 Float32 samples (1.92 MB payload); suspend at capacity |
| PCM holes | 64 merged ranges; refuse audio and extend the last hole |
| Recognition | One in-flight window; live 96,000 or final 239,360 Float32 samples |
| Assembler | Two window results |
| Provisional buffer / batch | 200 / 50 segments; fail visibly at capacity |
| Transcript pages / live view | Two pages of 200 / newest 200 segments |
| Gaps | 10,000 rows per meeting; merge at capacity |
| Finalization work | 10,000 stretches; derived work items in pages of 100 |
| Finalization queue / launch reconciliation | 100 meeting IDs / 100 active rows |
| Transcript storage | 20,000 rows and 16 MiB text per meeting; 48 MiB global text |

Capacities describe implementation limits, not measured RSS. Finalization pages work items from an already-loaded `MeetingDetail` and constructs its sequence index in memory; the 100-item page is not database metadata paging.

The measured maximum recognition RTF is 0.0062642444. It selected six-second live windows and sets the production finalization gate to 0.01× audio duration. It does not demonstrate that the production finalizer meets that gate.

T088 and T090 evidence belongs in [long-run-memory.md](../../specs/005-live-meeting-transcription/acceptance/long-run-memory.md). The 60-minute baseline/live comparison, fitted RSS slope below 1 MB per ten minutes, 20-minute slow-recognition run, transcription-off comparison and production finalization timing remain unmeasured. Hardware latency, restart, accuracy and privacy acceptance are also pending; deterministic tests cannot substitute for these measurements.
