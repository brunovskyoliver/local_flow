# Long-run memory acceptance

Status: pending. No T087–T090 or T094 hardware result was collected by this documentation update. [Phase 2 throughput](throughput.md) is a separate short test-host measurement.

## Baseline

T087 requires a 60-minute recording-only run on the reference M5, sampled every ten seconds with `scripts/memory-report.sh`. Record hardware, OS, build, model, power conditions and the raw sample path.

## Live run

T088 requires at least 60 minutes using the production app with resource recording, speech/fixture playback, a pause/resume and notes edits. Report starting, settled, peak and post-finalization RSS, settled slope, queue maximum, skipped intervals, finalization duration/RTF, coverage, audio growth and database growth. Gates: slope < 1 decimal MB per ten minutes; queue ≤ 480,000 samples; finalization ≤ 0.01× audio duration. Report model load separately. No values are available yet.

## Slow run

T090 requires twenty minutes with `--debug-slow-recognition 3`, full-length track verification and final speech coverage. Synthetic backpressure tests do not establish real capture duration or RSS.

## Transcription off

T094 requires a full hardware meeting with transcription off and resource recording enabled: zero model-loading phases and comparison with Feature 004 capture figures. Deterministic zero-lease tests are separate evidence.

Use [quickstart.md](../quickstart.md) for the procedure. Each run needs the signed app, model assets, microphone/system-capture access, a consented fixture and uninterrupted reference-machine time.
