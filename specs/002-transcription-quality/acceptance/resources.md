# Resource and timing acceptance

Date: 2026-09-18. Scope: T041 instrumentation and T046 measurement. Thresholds come from [docs/performance/memory-budget.md](../../../docs/performance/memory-budget.md); nothing here widens them.

## T041: instrumentation

### What is recorded

`ResourceRecorder` samples are one JSON line each, at most 1,024 bytes, in two rotating 5 MiB files under the app's private `Measurements` directory (0700/0600). Every sample carries the schema version, monotonic nanoseconds, phase, optional cycle/session UUID, build and model identity. Feature 002 adds three optional fields:

| Field | Type | Present when |
| --- | --- | --- |
| `metric` | enum | the sample is a labeled processing measurement |
| `payloadBytes` | UInt64 ≤ 262,144 | `metric` is a byte size |
| `itemCount` | UInt32 ≤ 512 | `metric` is a count |

Durations continue to use the existing `durationNanoseconds` field. A `metric` value fixes which one of the three value fields may be present; any other combination, an unlabeled byte/count value or a value above its ceiling is rejected at the producer and counted as loss, which invalidates the export (`complete: false`). This keeps the recorder unable to carry text: there is no string field a caller can set.

| Metric | Kind | Unit | Source |
| --- | --- | --- | --- |
| `recognitionDuration` | duration | ns | provenance `stageDurations["recognition"]` |
| `assemblyDuration` | duration | ns | provenance `stageDurations["assembly"]` |
| `normalizationDuration` | duration | ns | provenance `stageDurations["normalization"]` |
| `persistenceDuration` | duration | ns | `store.commit` wall time in the coordinator |
| `endToEndDuration` | duration | ns | coordinator admission to terminal transition (coordinator hook); benchmark `begin()` to `!busy` (benchmark row) |
| `modelLoadDuration` | duration | ns | lifecycle `preparing` phase |
| `modelReleaseDuration` | duration | ns | lifecycle `releasing` phase |
| `rawTextBytes` | bytes | UTF-8 bytes | sum over admitted raw windows |
| `assembledTextBytes` | bytes | UTF-8 bytes | assembled stage |
| `normalizedTextBytes` | bytes | UTF-8 bytes | delivered/saved text |
| `metadataBytes` | bytes | serialized bytes | `TranscriptionQualityDetail` payload (0 when no detail) |
| `windowCount` | count | windows | admitted raw windows (≤14) |
| `completionReasonCount` | count | reasons | bounded completion reasons (≤64) |
| `appliedRuleCount` | count | rule IDs | deduplicated N/V rule IDs (≤32) |
| `appliedEntryCount` | count | entry IDs | deduplicated vocabulary entry IDs (≤512); the IDs themselves never leave the detail |

Queue peaks: the benchmark row records the control mailbox high-water/capacity and, when the capture adapter exposes a ring, the raw audio queue high-water/capacity under `queueSource: audioRaw`. Absent rings are omitted, not zero.

### Where it comes from

`DictationCoordinator` builds one content-free `ProcessingMetrics` per session that reached recognition, after the terminal transition, and publishes it through `processingMeasured` and `lastProcessingMetrics`. `AppServices` forwards it to the recorder when `LOCALFLOW_RESOURCE_RECORDING=1`. Stage timings that the pipeline did not record (for example a session with no detail) are omitted from the recorder rather than written as zero; `ProcessingMetrics` keeps them as `nil`.

`DictationBenchmark.CycleRow` now carries `endToEndNanoseconds` and the session's `processing` figures, matched by session ID so a stale record from an earlier cycle cannot populate a later row. Capture-only cycles have no processing figures.

### Unchanged protocol

`scripts/dictation-benchmark.sh` still runs the Feature 001 20-cycle protocol against the installed signed app: 30 s settle, 10 baseline samples at 1 s, 20 cycles of 5 s hold, 30 s cooldown, up to 10 s release, 10 settled samples, plus a rapid-reuse series inside the last cooldown and an optional capture-only comparison. The RSS CSV from `scripts/memory-report.sh` is `ps` RSS in KiB; the benchmark JSON and the recorder use bytes. Report values in decimal MB (1,000,000 bytes).

### Conditions to record with every run

Hardware model, macOS version/build, app `CFBundleVersion`, model revision, power source, whether the network was disabled, whether the Go server was stopped, cycle count, hold seconds and capture-only flag. The script writes these to `conditions-<stamp>.txt` beside the result. Add the working-tree state (commit and dirty flag) by hand; the app cannot read Git.

### Deterministic checks

`ResourceRecorderTests.testProcessingMetricsAreLabeledBoundedAndContentFree` rejects unlabeled and mis-typed values, rejects values above the ceilings, and checks that a recorded `ProcessingMetrics` plus a model-load line produce exactly eleven labeled samples with no text-bearing field. `ResourceLifecycleTests.testBenchmarkRecordsEveryCycleWithMeasuredValues` checks that every benchmark row has end-to-end timing above its recording time and full stage/size figures from the fake runtime.

## T046: Apple M5 measurement

Status: **measured, acceptance incomplete.** The current signed app completed the default and capture-only 20-cycle protocols. Both runs exported all 20 normal rows plus two rapid-reuse rows with zero lost or overwritten recorder samples. The settled-memory gates are red for investigation. The baseline app did not produce a usable comparison report: its final cycle timed out waiting for `.unloaded` within the protocol's 10-second release window. Keep-loaded/manual-release and maximum-vocabulary/180-second runs were not performed.

The runs were made on `Mac17,2`, macOS `26.6.2 (25G83)`, app version `1`, on AC power, with the app initially quit and the model provisioned. The working tree was dirty at `4680c54d526750fbbc73d06b35ae09003d808d5a`; the current-app rows include the worktree changes. Network isolation was **not** enabled and the local Go rewrite server was running, although rewriting was not enabled by these benchmark settings. These are engineering measurements, not offline-acceptance evidence.

The recorder had one measurement-only correction before the runs: ordinary writer-lock contention was no longer counted as a lost sample. `record` still only enqueues bounded lines and the writer remains responsible for disk I/O. The smoke run and both full current-app runs then completed with zero recorder loss.

### Measured runs

| Run | Command | Purpose |
| --- | --- | --- |
| Run | Artifact | Result |
| --- | --- | --- |
| New pipeline, default | `build/benchmark/new-default-20260918-0722/benchmark-20260918T052046Z.json` | 20 normal + 2 rapid rows; recorder complete, 0 lost, 0 overwritten |
| New pipeline, capture-only | `build/benchmark/new-capture-only-20260918-0722/benchmark-20260918T053717Z.json` | 20 normal + 2 rapid rows; recorder complete, 0 lost, 0 overwritten |
| Baseline pipeline | `build/benchmark/baseline-default-20260918-0830/benchmark-20260918T061328Z.json` | failed at `releaseTimedOut(cycle: 20)`; no baseline rows used |
| Keep-loaded / manual release | not run | remains open; requires a manual session with `"Keep model ready"` and explicit release |
| Maximum vocabulary, 180 s | not run | remains open; requires 512 enabled entries and one 180-second dictation |

The default run's normal-row medians were: baseline 574.046 MB, settled 664.986 MB, early cycles 1–5 664.682 MB, late cycles 16–20 717.865 MB, late-minus-early +53.182 MB, fitted settled slope +3.197 MB/cycle, maximum settled 721.945 MB, and maximum recording peak 757.760 MB. Median end-to-end time was 5.589 s; median model load, transcription and release times were 0.400 s, 0.127 s and 30.173 s. Queue peaks were audio 2/32 and control 1/32. All 20 rows carried processing metrics and none was marked incomplete.

The capture-only run's normal-row medians were: baseline 573.997 MB, settled 623.149 MB, early cycles 1–5 618.791 MB, late cycles 16–20 672.465 MB, late-minus-early +53.674 MB, fitted settled slope +2.643 MB/cycle, maximum settled 675.758 MB, and maximum recording peak 673.890 MB. Median end-to-end time was 5.465 s; median model load and release times were 0.404 s and 30.195 s. Its settled median was 49.152 MB above its raw baseline; its maximum recording peak was 99.893 MB above baseline. These values do not isolate a model working set, so they do not by themselves close the capture-overhead gate.

The external RSS samplers recorded 907 samples for the default run (574.030–759.054 MB, median 695.583 MB) and 909 for capture-only (573.915–677.511 MB, median 623.313 MB). The failed baseline sampler recorded 884 samples (122.159–705.036 MB, median 658.825 MB), but its incomplete lifecycle means those samples are diagnostic only.

### Gates to fill from measured rows

| Gate | Threshold | Result |
| --- | --- | --- |
| Unloaded idle RSS | ≤150 MB | raw current baseline 574.046 MB; target exceeded, model component not isolated |
| Capture overhead excluding model working set | ≤100 MB | row median delta 49.152 MB and peak recording delta 99.893 MB; external peak delta 103.514 MB, so not a clean pass |
| Each settled median vs. baseline | within max(20 MB, 10% baseline) | not evaluable; baseline app failed before exporting rows |
| Fitted settled slope | >0.5 MB/cycle flags investigation | **flagged**: default +3.197 MB/cycle; capture-only +2.643 MB/cycle |
| Late minus early median (cycles 16–20 vs 1–5) | >10 MB flags investigation | **flagged**: default +53.182 MB; capture-only +53.674 MB |
| Model working set | measured, no invented cap | raw peaks recorded; no separate model working-set cap claimed |

Related isolated measurements that do exist: the VAD capability probe on this M5 (1,063,425 artifact bytes, 0.176 s load, 2,375,680 B retained increment beside an active ASR lease) and the evaluation-harness process peaks in [chunk-planner-final.md](chunk-planner-final.md). Neither is a signed-app 20-cycle run and neither is used to fill a gate above.
