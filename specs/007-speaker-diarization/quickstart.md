# Validation guide

This guide shows how to prove Feature 007 works end to end. The deterministic checks run in `make check`. Throughput, memory, accuracy, force-quit and privacy acceptance are separate evidence recorded under `acceptance/`, and each stays "unmeasured" until its file is written. The contracts are in [contracts/](contracts/), the storage shape is in [data-model.md](data-model.md), and the thresholds are in [research.md](research.md).

## Prerequisites

- Apple Silicon Mac with Xcode and the pinned packages. The deterministic suites need no model, server or network, and run on macOS 14 or later.
- For hardware acceptance:
  - the reference M5 MacBook Pro 32 GB on macOS 15 or later;
  - a signed build;
  - Parakeet v3 and the speaker labeling model provisioned through Settings;
  - Wi-Fi off and the Go server stopped;
  - `sqlite3`, `scripts/memory-report.sh` and `LOCALFLOW_RESOURCE_RECORDING=1`.
- Evaluation set (kept outside git per `fixtures/audio/README.md`):
  - synthetic meetings with RTTM ground truth: the local voice on the microphone track plus 1, 2 and 3 remote voices on the system track, including an overlap stretch, one-word interjections and a pause;
  - one speaker-playback (bleed) meeting;
  - rights-cleared conversational speech where suitable;
  - consented owner meetings of 30–60 minutes.

## Repository checks (offline)

```sh
make check
```

Expected: every suite passes, including the new ones:

- `SpeakerAlignerTests`: the dominant, ambiguous, unknown and overflow cases; repeat determinism; text and timing untouched.
- `WindowClusterReconcilerTests`: match, new, uncertain margin, capacity overflow, tie order.
- `CorrectionCarryOverTests`: reciprocal match, unsafe matches flagged for review, merge carry-over.
- `QuoteSelectorTests`: long quotes spread across thirds, short-only fallback, stable order.
- `SpeakerStoreTests`: migration on a Feature 006 database, atomic adoption, a failed run leaving the accepted run intact, cascade on meeting delete and on `discardPass`, capacity refusals, restart persistence of names, merges and corrections.
- `ModelLifecycleCoordinatorTests`: the workload switch releases ASR before the diarizer loads, ASR preempts diarization, a diarization lease has no cooldown, Keep model ready re-prepares ASR.
- `MeetingDiarizerTests` with `FakeDiarizationRuntime`: windows never cross stretches, recorded-timeline offsets, the microphone gets `numSpeakers = 1` unless in-room, every failure category leaves the transcript, notes, audio and accepted run byte-identical, cancellation joins.
- `SpeakerDiarizationCoordinatorTests`: automatic trigger on and off, queue deduplication and capacity, preemption requeue, deletion cancel.
- `DiarizationReconcilerTests`.
- `TranscriptPagerTests`: labeled pages, stale-pass fallback, `labelsRevision` reload.
- `AssignSpeakersModelTests`: cancel discards, save is one transaction, validation, duplicate-name merge offer.
- The content-free recorder test, extended.

All Feature 001–006 suites must pass unchanged (SC-009).

## Throughput and memory measurement (first implementation task; SC-004, SC-005)

1. Run `DiarizationThroughputHarness` against the real engine, with no UI, on the reference machine over:
   - the synthetic 10-minute fixtures;
   - a consented 60-minute meeting;
   - an 8-hour synthetic concatenation.
   Use window sizes of 10 and 20 minutes, three runs each.
2. Record per run:
   - audio seconds, diarization seconds and RTF;
   - model load duration and model RSS increase;
   - peak RSS, the RSS slope (10 s samples) and RSS after release;
   - the window count and speaker count;
   - hardware, macOS, build and model revision.
3. File `acceptance/throughput.md`. Freeze the window size, then set the SC-005 gates: RTF gate = the maximum measured RTF × 1.5, rounded up to the next 0.01, and the peak model memory gate = the maximum measured model RSS increase × 1.5, rounded up to the next 10 MB. Write both into the plan's validation table.
4. Evaluation: run alignment over the RTTM fixtures, sweep τ/δ and the alignment thresholds, and choose the values that keep wrong-speaker assignments under 5% of segments with the most speaker-labeled time. File `acceptance/accuracy.md` with correct-time share, wrong-speaker share, Unknown/Ambiguous share, and confusion, missed speech, false alarm and DER **only where RTTM exists** (SC-001, SC-002).

## Label a meeting (US1, US2)

1. Settings > Meetings: turn on "Label speakers automatically". Record a meeting with a fixture on the system output and speak into the microphone, then Stop.
2. Expected:
   - the transcript finalizes;
   - the Speakers status shows "Labeling speakers…", then the rows relabel as You / Speaker N;
   - the header shows the speaker count and duration;
   - the recorder shows `modelReleasing` (speech recognition) before `modelLoading(diarization)`, and never both loaded at once. Speech-recognition phases keep their Feature 001 names so earlier reports and `memory-report.sh` still parse; only diarizer phases carry the `(diarization)` suffix.
3. Byte-identity check: `shasum` the meeting's files, and `sqlite3 history.sqlite "select id, normalized_text, start_ms, end_ms from transcript_segments where meeting_id='<id>'" | shasum` before and after the run. Both must match.
4. Close the meeting window during the run: the run still completes.

## Name, merge and correct (US3–US5, US7)

1. Open Assign speakers. Check the quotes, type two names and press Save names. Every row, the header and Copy use the new names within 1 s. Relaunch the app: the names persist.
2. Reopen the sheet, change a name and press Cancel: nothing changes.
3. Merge Speaker 1 into Speaker 2: one label and a lower count. Check `select count(*) from speaker_turns where run_id=…`: unchanged. Undo the merge: both speakers return with their earlier names and colors.
4. Change one row to Unknown and another to New speaker, then relaunch: both persist, and `manual_kind` is set while `auto_kind` is unchanged.
5. Copy and compare with the expected `Name:\ntext` blocks.

## Failure, rerun and recovery (US6, SC-006)

- Debug builds provide `--debug-fail-diarization window=2`, `--debug-slow-diarization 3` and `--debug-seed-diarization`.
- **Failure mid-run**: the status shows the category and Retry; the transcript and previous labels are unchanged.
- **Force quit during a run** (`kill -9`): on relaunch the run is interrupted, the accepted labels stay, and Retry is offered.
- **Rerun on a named meeting**: the old labels stay until adoption. Names carry over where safe, and "Couldn't carry over" entries appear otherwise.
- **Dictation during a run**: dictation proceeds, the run returns to pending and completes afterwards, and `diarizationPreemption` is 1.
- **Re-transcribe (Feature 005)**: the source labels return, and a new automatic run starts.
- **Delete during a run**: the run is cancelled, and no rows with that meeting id remain in any diarization table.
- **Missing audio** (move the track files away): `audio_missing`, and the transcript is intact.
- **Model not installed**: `model_unavailable` with guidance, and no network request.

## Privacy (SC-008)

- With Little Snitch or `nettop` watching, run, name, merge and correct. Expected: no connections.
- `log show --predicate 'subsystem == "org.localflow.LocalFlow"' --last 1h` and the recorder CSV contain no names, quote text or transcript text. Grep for the test names you typed.
- After deleting the meeting, no diarization rows remain and no temporary audio exists (none is written).
