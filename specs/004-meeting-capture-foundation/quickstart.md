# Validation guide

How to prove Feature 004 works end to end. Deterministic checks run in `make check`; hardware, force-quit and long-run acceptance are separate evidence recorded under `acceptance/` and stay "unmeasured" until written. Contract details live in [contracts/](contracts/) and the storage shape in [data-model.md](data-model.md).

## Prerequisites

- Apple Silicon macOS 14+ with Xcode and the pinned packages; no server, no model and no network are needed for any step below.
- For hardware acceptance: the reference M5 MacBook Pro from [memory-budget.md](../../docs/performance/memory-budget.md), a signed build, microphone and Screen & System Audio Recording permissions grantable, `sqlite3` and `scripts/memory-report.sh`.

## Repository checks (offline)

```sh
make check
.specify/scripts/bash/check-prerequisites.sh --json --require-spec
```

Expected: Swift format, scripts, Go and the deterministic XCTest suites pass. The meeting suites cover, with `FakeMeetingAudioSource`, `FakeSegmentWriter` and the test clock: every lifecycle transition and every invalid pair; start → stop; start → pause → resume → stop; interruption while recording, paused and finalizing; system sleep (paused with reason, no automatic resume); microphone failure; system-audio failure; both failed; storage write failure with the buffer bound; each FR-013 reconciliation case; deletion of a recovered meeting; ring drop-and-count; ADTS validation and truncation; notes autosave timing; content-free instrumentation; and the Feature 001–003 suites unchanged (FR-028, SC-002, SC-011).

## Codec recoverability spike (FR-005, first implementation task)

Run the throwaway harness three times per writer (ADTS, fragmented MP4, plain M4A), killing with `kill -9` at 5, 20 and 55 s of a 60 s recording. Record per run: playable through `AVAudioFile` (yes/no), recoverable seconds, bytes lost, bytes on disk, RSS while writing. Save as `acceptance/codec-recoverability.md` with hardware, macOS, build and settings. Expected: ADTS playable in every run with under one frame lost; M4A unplayable; fMP4 playable with at most one fragment lost. Confirm the decision or switch to fMP4 before building the storage layer.

## Start, record, stop (US1, US2, US6, SC-001)

1. Open Meetings, choose Start Meeting with permissions already granted. Expected: the active view shows Recording, an elapsed timer and two green indicators within 3 s; `sqlite3 history.sqlite "select state from meetings order by created_at desc limit 1"` prints `recording` while `ls "~/Library/Application Support/LocalFlow/Meetings/<id>"` shows `mic-0001.aac.part` and `system-0001.aac.part` growing.
2. Speak and play a known audio file. Choose Start Meeting again from the menu bar: no second row appears.
3. Stop. Expected: `completed`, two `.aac` files, the library row shows the fallback title and duration; the detail lists both tracks with codec `aac_lc`/`adts`, 48000 Hz, channel counts, durations within 1%/2 s of the recorded duration (SC-004), byte sizes and one finalized segment each. Play each track: the microphone file contains only your voice, the system file only the played audio.
4. Move the `Meetings` folder aside, launch, confirm the tracks show "file missing"; move it back, relaunch and confirm they play (relative paths, story 6).

## Pause and resume (US4, SC-005)

Record, pause for a timed 30 s, resume, record, stop. Expected: one meeting, two segments per track, one pause row with `reason = 'user'` and both timestamps, and `recorded_ms = wall_clock_ms − pause_ms ± 1 s`. Put the Mac to sleep during recording, wake it: the meeting is paused with "Paused because the Mac went to sleep", stays paused, and resumes only when you choose Resume.

## Notes (US5, SC-007)

Type notes during a meeting; stop typing; within 2 s the editor shows Saved. Keep typing continuously for 30 s and confirm at least three saves in `meeting_notes.updated_at`. Force quit (`kill -9 $(pgrep LocalFlow)`) while typing, relaunch: notes present up to the last save and attached to the right meeting. Edit notes on a completed meeting; relaunch; the edit persists and the audio checksums are unchanged. Turn Wi-Fi off first for one of these runs.

## Force quit and reboot recovery (US9, SC-002)

1. Record for 3 minutes, `kill -9` the app, relaunch. Expected: launch is not blocked; a notice reports one meeting recovered; the meeting is `interrupted` with "LocalFlow did not exit cleanly"; the detail shows a recovery outcome row with bytes truncated; both tracks play; notes intact.
2. Repeat while paused: the open pause is closed at the last persisted time and excluded from the duration.
3. Repeat during finalizing where practical (`--debug-slow-finalize` build flag adds a 10 s sleep between the two tracks): the microphone track is finalized, the system track recovered, `finalization_stage = 'mic'`.
4. Reboot during a meeting: same outcome as 1 with reason `not_running_at_last_state`.
5. Corrupt an open `.part` file (`head -c 3 > file`), relaunch: the segment is `unrecoverable` with the file retained; the other track plays.
6. Delete a row directly (`sqlite3 … "delete from meetings where id='…'"`) leaving its directory, relaunch: an `interrupted` meeting with reason `record_missing` appears and its files play.
7. Launch with nothing active: no notice, dictation works.

Record at least one real force-quit run on the reference machine in `acceptance/recovery.md`.

## Storage failure (US10, SC-006)

Deterministic: the store test with `FakeSegmentWriter.failAfterBytes` asserts capture stops within 5 s of test-clock time, state `interrupted` with `storage_write_failed`, ring drops counted, no buffer growth. Live: record onto a small disk image (`hdiutil create -size 20m …`, point the storage root at it through the `LOCALFLOW_MEETING_ROOT` environment override) until it fills. Expected: a notice within 5 s, recording indicator gone, the meeting `interrupted`, the last complete file playable. Start Meeting on a volume with under 500 MB free: refused; between 500 MB and 2 GB: warned.

## Source failure and permissions (US11, US12, SC-008)

Unplug a USB microphone mid-meeting: the microphone track shows Failed with reason and time, the warning is prominent, system audio continues, the final record shows both outcomes. Deny Screen & System Audio Recording, choose Start: the specific permission and its settings path are shown, no meeting row is active. Same with the microphone denied. Revoke screen recording during a meeting: the system track becomes `permission_revoked` and the meeting continues on the microphone. Confirm only the microphone and screen-recording prompts ever appear.

## Deletion (US13, SC-009)

Record two meetings; note both directories' checksums (`shasum` over the files). Delete one with confirmation: its row, notes, tracks, segments, pauses, outcomes and directory are gone; the other's rows and checksums are unchanged. Dismiss the confirmation once: nothing changes. Make a file undeletable (`chflags uchg`), delete: the outcome reports the remaining path and the meeting shows "Deletion incomplete"; clear the flag and retry.

## Long-run memory acceptance (US3, SC-003)

Development run of 10–15 minutes, then the final 60-minute run on the reference machine with `LOCALFLOW_RESOURCE_RECORDING=1`, both sources active, notes edited, at least one pause/resume, no model loaded. Sample RSS with `scripts/memory-report.sh <pid>` every 10 s. Write `acceptance/long-run-memory.md` with hardware, macOS, build/commit, codec settings, conditions, the RSS series, starting/settled/peak/post-stop RSS, the fitted slope over the settled window (gate: < 1 MB per 10 minutes), peak overhead above idle (gate: ≤ 100 MB), per-track file sizes, dropped frames, write errors and finalization duration. Confirm the model lifecycle instrumentation reports no load (SC-010). Unmeasured values are written as unmeasured.

## Privacy check (FR-026, SC-012)

Run the long-run acceptance with log capture. Search the logs and the `Measurements/` records for the meeting title, any note sentence and any `.aac` path containing the title: zero matches expected. Confirm `meeting_notes.text` is the only place note text exists and that no table stores audio.
