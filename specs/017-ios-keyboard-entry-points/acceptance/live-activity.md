# Live Activity (T060, quickstart §6, US5, SC-007)

Status: **passed, owner-attested (2026-10-02).** No figures were recorded.

| Item | Value |
| --- | --- |
| Date | 2026-10-02 |
| Device | iPhone 16 Pro (iPhone17,1) |
| iOS | 27.0.1 (as in the spike; not re-read for this run) |
| Build | Debug, signed for team 944A459UC3, `5e583ab` plus the uncommitted Phase 9–10 changes, installed with `xcrun devicectl device install app` |

Steps given to the owner:

1. Start a session, lock: Ready, elapsed time, "Ends in m:ss" or "No timeout", Stop.
2. Dictate from the keyboard: Dynamic Island Recording → Transcribing → Ready; expanded view.
3. Copy from the locked Lock Screen, paste in Notes.
4. Stop: session ends, activity gone, mic indicator off within 10 s (SC-007).
5. Live Activities off: a session still works; Settings shows the hint.
6. Optional: swipe the activity away, open LocalFlow, the activity returns.

Owner report: "that's all working super." Owner-attested, no figures.

Not captured:

- The SC-007 time from Stop to the mic indicator going off. The owner reported a pass but gave no time.
- Whether Copy wrote the clipboard from the background or brought LocalFlow forward (the R4 fallback). Both paths end with the text on the clipboard, so the report does not tell them apart.
- Whether the optional step 6 was run.
