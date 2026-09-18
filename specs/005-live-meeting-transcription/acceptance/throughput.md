# Throughput evidence and planner decision

Measured 2026-09-18 on the reference MacBook Pro. All six real-model runs passed.
Numeric receipts and source-file hashes are in [throughput-evidence.json](throughput-evidence.json).
The executable procedure and measurement definitions are in [spike/README.md](spike/README.md).

## Conditions

- Mac17,2, Apple M5, 32 GiB RAM; macOS 26.6.2 (25G83); Xcode 26.4.1 (17E202).
- Starting commit `9e94833fac87032bed142e4b524c8362120a644b` plus the Feature 005 working tree
  captured by the evidence's SHA-256 source map. Release `-O`, `ENABLE_TESTABILITY=YES`,
  `CODE_SIGNING_ALLOWED=NO`; hosted XCTest without application startup or UI.
- FluidAudio 0.15.7 (`41540ea237350afe5117a082b5c28eda642d0612`), existing Parakeet v3
  model revision `7dd20fe6b1797d35f5e3307e8b1732d9a178edfe`; Core ML compute units `.all`.
  The installed model was APFS-cloned to ignored `build/005-throughput-model` to avoid
  contending with the running app's provisioning lock, then hash-verified before every run.
- Battery power (77% before the run sequence), sequential fresh test-host processes.
  The installed LocalFlow app and its idle Go rewrite server remained running; neither
  participated in this harness. Networking was not disabled. Recognition used local
  files only; this is throughput evidence, not an offline or isolated-machine acceptance run.
- One lease per run; 239,360-sample windows plus the final tail. Decode requests at most
  4,096 source frames, channel-averages to mono and resamples to 16 kHz. No transcript
  store, UI rendering, normalization or two-track mixing is included.

## Fixtures

Long-continuous: Feature 002 public long-form fixture `long-1404b1e776253caea6df`,
176.139 seconds of continuous Slovak source audio, mono 16 kHz WAV, 12 windows.
SHA-256 `a3b2a402498f7e26c5963722b76ee60336f0e2381099c188f14af1000629d141`.
Its source and selection provenance remain in `build/quality-public-long-v1/manifest.json`
and `fixtures/quality/public-long-form-selection-lock.json`.

Synthetic meeting: user-authorized artificial fixture assembled from the existing,
verified online Google FLEURS corpus. Fifty-six turns alternate English and Slovak
utterances, repeat the fixed 20-clip sequence, and insert short pauses before truncating
at 600 seconds. Encoded as dual-mono 48 kHz AAC-LC ADTS; decoding plus the converter's
filter tail submitted 600.022 seconds in 41 windows. The utterances are unrelated;
there is no real conversation, echo, overlap or independent microphone/system track.
It is used only for throughput, never accuracy or genuine-meeting acceptance.

FLEURS attribution: Alexis Conneau et al. (2022), Google,
[CC BY 4.0 dataset](https://huggingface.co/datasets/google/fleurs/blob/70bb2e84b976b7e960aa89f1c648e09c59f894dd/README.md).
All source hashes, turn positions, generation changes and output hashes are in
[synthetic-fixture.json](synthetic-fixture.json). Audio stays outside git.

## Measurements

Seconds and decimal MB (1 MB = 1,000,000 bytes). RTF is recognition seconds divided
by samples actually submitted / 16,000. RSS peak is sampled every 20 ms; after is
immediately after explicit model release, not a settled baseline.

| Fixture | Run | Audio s | Recognition s | RTF | Model load s | RSS before MB | RSS peak MB | RSS after MB |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| long-continuous | 1 | 176.139 | 1.099004 | 0.00623941 | 13.048707 | 578.67 | 2812.79 | 1179.40 |
| long-continuous | 2 | 176.139 | 1.103378 | 0.00626424 | 0.082191 | 578.75 | 663.98 | 627.98 |
| long-continuous | 3 | 176.139 | 1.087922 | 0.00617649 | 0.083529 | 578.72 | 664.01 | 628.02 |
| synthetic-meeting | 1 | 600.022 | 3.290476 | 0.00548393 | 0.082128 | 580.35 | 666.88 | 627.11 |
| synthetic-meeting | 2 | 600.022 | 3.331037 | 0.00555152 | 0.082199 | 580.40 | 668.30 | 630.77 |
| synthetic-meeting | 3 | 600.022 | 3.349438 | 0.00558219 | 0.088014 | 580.42 | 667.58 | 627.11 |

The first model load took 13.05 seconds and peaked at 2,812.79 MB RSS. Subsequent
fresh processes loaded the same model in 0.08–0.09 seconds and peaked at about
664–668 MB. Core ML caches were not cleared between runs; the first-load and
cached-load observations are retained separately. This does not establish a
model memory budget or an unloaded-client RSS result.

## Decision (T006)

Use the slowest of all six RTFs, **0.0062642444**. It is below 0.25, so retain
**`live_contiguous_96000_v1`** (96,000 samples, six seconds). The queue's
`catchingUpLagSamples` remains 96,000; the 64,000-sample variant remains an
alternative for contract tests, not the selected live configuration.

SC-006 multiplier = `ceil(max(RTF) × 1.5 × 100) / 100` = **0.01× audio duration**.
Rounding upward to 0.01 RTF is the explicit interpretation of "rounded up".
For 600 seconds of audio, the future finalization gate is six seconds. This
sets the gate; it does not assert the unbuilt production finalizer meets it.
Model load is measured separately from recognition RTF and must also be reported
in finalization acceptance rather than hidden in the recognition figure.

No live-latency, long-run memory-slope, production finalization, recovery or
accuracy figure has been collected by this phase. Those remain later tasks.
