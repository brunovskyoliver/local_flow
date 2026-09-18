# Validation guide

How to prove Feature 005 works end to end. Deterministic checks run in `make check`; throughput, latency, memory, force-quit and long-run acceptance are separate evidence recorded under `acceptance/` and stay "unmeasured" until written. Contracts are in [contracts/](contracts/) and the storage shape in [data-model.md](data-model.md).

## Prerequisites

- Apple Silicon macOS 14+ with Xcode and the pinned packages. The deterministic suites need no model, server or network.
- For hardware acceptance: the reference M5 MacBook Pro 32 GB from [memory-budget.md](../../docs/performance/memory-budget.md), a signed build, the Parakeet v3 model provisioned through Settings, microphone and Screen & System Audio Recording permissions granted, Wi-Fi off, the Go server stopped, `sqlite3`, `scripts/memory-report.sh`, and `LOCALFLOW_RESOURCE_RECORDING=1`.
- Meeting-style fixtures: the Feature 002 fixtures (English, Slovak, technical, long continuous, mixed stress, pauses) plus two consented two-person recordings of ≥ 10 minutes played through the system output; keep them outside git per `fixtures/audio/README.md`.

## Repository checks (offline)

```sh
make check
.specify/scripts/bash/check-prerequisites.sh --json --require-spec
```

Expected: format, scripts, Go and every XCTest suite pass, including the new transcript suites listed in [contracts/transcription-lifecycle.md](contracts/transcription-lifecycle.md), "Deterministic tests", the planner, mixer, queue, segmenter and store contract tests, and the Feature 001–004 suites unchanged (FR-028, SC-011).

## Throughput measurement (first implementation task; SC-001, SC-006)

Phase 2 completed on 2026-09-18. Six real-model runs measured maximum recognition RTF **0.0062642444**. The selected live planner is **`live_contiguous_96000_v1`** and the SC-006 finalization gate is **≤ 0.01× audio duration** (`ceil(max(RTF) × 1.5 × 100) / 100`). See [throughput.md](acceptance/throughput.md) and the [reproduction harness](acceptance/spike/README.md). The user authorized a synthetic meeting fixture built from online speech; its results establish throughput only. Production finalization and live latency remain unmeasured.

To repeat the measurement:

1. Build the finalizer's decode-and-recognize loop against the real engine (no UI) and run it over the Feature 002 long-continuous fixture and one 10-minute meeting-style fixture, three runs each, on the reference machine.
2. Record per run: audio seconds, recognition seconds, real-time factor, model load duration, RSS before/peak/after, hardware, macOS, build, model revision.
3. File `acceptance/throughput.md`. Decide: RTF ≤ 0.25 keeps `live_contiguous_96000_v1`; above it selects `live_contiguous_64000_v1`. Set the SC-006 finalization gate as `maximum measured RTF × 1.5`, rounded upward to the next 0.01 RTF, and write it into the plan's validation table and this file.

## Live transcript while recording (US1, US3, SC-001)

1. Settings > Meetings: "Transcribe meetings while recording" on. Open Meetings, Start with the Transcribe toggle on, speak and play a fixture. Expected within ~10 s: the Transcript section shows "Transcribing" and provisional segments with `mm:ss` timestamps while the state badge stays Recording and `ls Meetings/<id>` shows both `.part` files growing.
2. Scroll up in the live transcript; new segments must not move the view; scroll to the bottom; auto-follow resumes.
3. Latency: with the recorder on, speak twenty short phrases with 5 s silence between them over a 60-minute run (mix with fixture playback). `transcriptLiveLatency` samples give the distribution; report median and p95 in `acceptance/live-latency.md` with the planner version. Gate: median ≤ 5 s, p95 ≤ 10 s.
4. Backpressure: launch with `--debug-slow-recognition 3` (debug builds only; sleeps 3× the audio duration per window through the injected clock), record 5 minutes. Expected: state moves to "Catching up", then "Degraded", `transcript_live_gaps` rows with reason `backpressure` appear, `transcriptAnalysisQueueDepth` never exceeds 480,000, the recording continues, and after Stop the final transcript covers the gap intervals (`covered_by_final = 1` before the rows are removed; check the completion log line's counts).

## Transcription off (US2, SC-002)

Start with the Transcribe toggle off. Record, pause, resume, stop. Expected: `select state from meeting_transcriptions where meeting_id = '<id>'` prints `not_requested`; the recorder shows no `modelLoading` phase during the meeting; the detail view offers Transcribe; playback and notes behave as in Feature 004.

## Stop, finalize, timestamps (US4, US5, SC-005)

1. Record with a timed 30 s pause, then Stop. Expected: transcript badge "Finalizing n %", then "Final"; every `transcript_segments` row has `start_ms < end_ms`, `end_ms ≤ covered_ms`; no row spans the pause (check `stretch_sequence` changes exactly where the pause was); `replaced_provisional_count` equals the provisional count seen before stop.
2. Close the detail view and the window during finalization; reopen: the state is still updating and reaches Final.
3. Click a timestamp: playback of the microphone track seeks near that time.
4. Copy a range of segments and paste into a text editor: normalized text only, one segment per line.

## Failure separation (US6, SC-007)

1. Uninstall the model in Settings. Start a meeting with transcription on. Expected: recording continues; transcript state `failed` with "The speech model is not installed…"; both tracks complete normally. Reinstall the model, choose Retry: state `final`.
2. Debug build, `--debug-fail-recognition 5`: the fifth window throws. Expected: earlier provisional segments kept, state `failed` (`runtime_failure`), recording continues to a normal stop, Retry produces `final`.
3. Debug build, `--debug-fail-persistence`: batch writes fail. Expected: `persistence_failure`, recording continues, Retry later succeeds.

## Restart safety (US5, US10, SC-007)

1. Record 3 minutes with transcription, `kill -9 $(pgrep LocalFlow)`, relaunch. Expected: meeting `interrupted` (Feature 004), transcript `interrupted`, provisional segments visible, Retry offered; no model load at launch (recorder shows none until Retry).
2. Record 10 minutes, Stop, and `kill -9` while "Finalizing". Relaunch. Expected: launch is not blocked; a notice mentions a transcript resuming; `progress_sequence`/`progress_sample` are non-null before the resume; the pass completes; segments before the progress point are byte-identical to before the kill (compare a `sqlite3 .dump` of those rows). Record in `acceptance/recovery.md`.

## Transcribe an untranscribed meeting (US9)

Open a Feature 004 meeting recorded before this feature (or one with transcription off), choose Transcribe. Expected: `final` with coverage equal to the recorded duration within 1 s; for an interrupted meeting with partial audio, coverage equals the recovered duration and the descriptor lists the recovered stretches.

## Notes independence (US8)

Type notes during a transcribed meeting; save the notes text before Stop; after finalization diff the notes column: byte-identical; grep the segment texts for a unique note phrase: no match.

## Deletion (US10, SC-012)

Delete a transcribed meeting. Expected: zero rows in `meeting_transcriptions`, `transcript_segments`, `transcript_live_gaps` for that id; `transcript_usage` decreased by the meeting's counters; another meeting's segment rows and files unchanged (checksum before and after).

## Paging (US7, SC-008)

Debug build, `--debug-seed-transcript 12000` on an existing completed meeting inserts 12,000 synthetic final segments. Open the meeting: the first page renders within 1 s (measure with the recorder's `persistenceDuration`-style timing added for the first page query), scrolling loads pages, and the pager's resident count (logged as a count) never exceeds 400.

## Memory and duration independence (SC-003, SC-004, SC-006)

1. Baseline: a 60-minute recording-only run per Feature 004's procedure.
2. Live run: ≥ 60 minutes with transcription on, fixture playback and speech, one pause/resume, notes edits; `scripts/memory-report.sh` every 10 s. Report starting, settled, peak and post-finalization RSS, fitted slope over the settled window (gate < 1 MB per 10 min), `transcriptAnalysisQueueDepth` maximum (gate ≤ 480,000), skipped-interval count, latency distribution, finalization duration, real-time factor, coverage, file and database growth; identify hardware, macOS, build, model, planner version and conditions. File `acceptance/long-run-memory.md`.
3. Slow run: the same for 20 minutes with `--debug-slow-recognition 3`; gates: bounds held, full-length tracks, final coverage 100 % of speech intervals.

## Accuracy parity (SC-009)

Run the Feature 002 quality evaluation fixtures through the finalization path (fixture audio copied into a synthetic meeting's stretch files) and compare WER against the production dictation results in `specs/002-transcription-quality/acceptance/quality-results.md`. Gate: within 1 absolute percentage point per fixture set; report the mixed-language limitation as before. File `acceptance/accuracy-parity.md`.

## Privacy (SC-010)

After the runs above: `grep -r` the recorder files and `log show --predicate 'subsystem == "org.localflow.LocalFlow"' --last 2h` for three unique phrases spoken and one note phrase. Expected: no match. File `acceptance/privacy.md`.

## Regression gate (SC-011)

Run the Feature 001–004 suites and the Feature 004 quickstart start/stop scenario with transcription off. Expected: unchanged results.
