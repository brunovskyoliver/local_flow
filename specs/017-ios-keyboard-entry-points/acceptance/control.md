# Control, Action Button and Shortcuts (T071, quickstart §7, US6, SC-008, SC-009)

Status: **passed, owner-attested (2026-10-02).** No figures were recorded.

| Item | Value |
| --- | --- |
| Date | 2026-10-02 |
| Device | iPhone 16 Pro (iPhone17,1) |
| iOS | 27.0.1 (as in the spike; not re-read for this run) |
| Build | Debug, signed for team 944A459UC3, from `91beb4f` up to `7c62bfd` as fixes landed, installed with `xcrun devicectl device install app` |

Steps given to the owner: quickstart §7, with the control on the Action Button, in Control Center and on the Lock Screen, notifications on, and Diagnostics on for the "Control stop → result" time.

Owner reports, in order:

- The control records and stops from the Action Button; text reaches History, the clipboard (once LocalFlow is active, research R4), the result card and the notification. Diagnostics showed "Control stop → result" 0.18 s for one dictation (screenshot, 16:01).
- The expanded Dynamic Island was laid out wrong. Fixed over several rounds: regions with fixed-width timers, then one centred row while recording (mic and recording time, tap to stop) and while transcribing. The owner rejected a waveform, static and live.
- A dictation failed with `alreadyInUse` after a reinstall mid-recording: orphan recovery held the spool lock through the first model load. Fixed (recovery spools under `TemporaryAudio/Recovery/`).
- A second Action Button note left the first note's result card on the Lock Screen. Fixed (`7c62bfd`).
- Final report: "Everything seems fine." Owner-attested.

Not captured:

- SC-008: the ten-run count and the stop → result time per run. Only the single 0.18 s reading above exists, and it is not tied to a locked-phone 15 s run.
- SC-009: whether the Live Activity was visible in each of ten runs.
- Which of steps 4–9 were run: Siri and Shortcuts, the control during a keyboard recording and during a `ready` keyboard session, notification Copy while locked, Live Activities off, model deleted, before first unlock.
- Whether background clipboard writes were dropped (result card "Saved") or took ("Copied") in each run.
