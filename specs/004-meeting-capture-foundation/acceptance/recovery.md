# Recovery acceptance (SC-002, SC-007, SC-008)

**Status: not run.** These are reference-machine runs (owner-executed, signed build,
permissions grantable). Nothing here is established by the deterministic suites; the
deterministic evidence is `MeetingReconcilerTests`, `MeetingCoordinatorTests` and
`MeetingNotesEditorTests` (see `fr-028-traceability.md`).

Record per run: hardware, macOS, build/commit, what was done, the launch notice text, the
meeting's state and reason, the `meeting_recovery_outcomes` row, whether each track plays,
and whether the notes are intact.

## Force quit and reboot (T076, SC-002)

| Step (quickstart.md "Force quit and reboot recovery") | Outcome |
| --- | --- |
| 1. `kill -9` after 3 min of recording; relaunch | not run |
| 2. `kill -9` while paused | not run |
| 3. `kill -9` during finalizing (`--debug-slow-finalize`) | not run |
| 4. Reboot during a meeting | not run |
| 5. Corrupt an open `.part` (`head -c 3`); relaunch | not run |
| 6. Delete a row leaving its directory; relaunch | not run |
| 7. Launch with nothing active | not run |

SC-002 requires at least one real force-quit run with playable audio and intact notes.

## Source failure and permissions (T078, SC-008)

| Case | Outcome |
| --- | --- |
| USB microphone unplugged mid-meeting | not run |
| Screen & System Audio Recording denied at Start | not run |
| Microphone denied at Start | not run |
| Screen recording revoked mid-meeting | not run |
| Only the microphone and screen-recording prompts appeared | not confirmed |

## Notes (T078, SC-007)

| Case | Outcome |
| --- | --- |
| Type, stop, "Saved" within 2 s | not run |
| 30 s continuous typing: ≥ 3 saves in `meeting_notes.updated_at` | not run |
| Force quit while typing; notes present up to the last save | not run |
| Edit notes on a completed meeting offline; relaunch; audio checksums unchanged | not run |
