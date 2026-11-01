# Feature 026: hardware acceptance

Items that need real hardware, a signed install or the owner's screen and microphone. None of them has been run.

| # | Item | Source | Expected | Result |
| --- | --- | --- | --- | --- |
| 1 | `flow-speech-win provision` over HTTPS from Hugging Face, including its redirect, on a machine that lets it connect | T004 | All four files verified, `state=verified` | not run |
| 2 | `flow-speech-win serve` on x64 Windows with the installer's DLLs: `LoadLibraryExW`, `onnxruntime.dll` found beside it without `onnxruntime_providers_shared.dll`, a recognition | T004, FR-008 | `ready`, then correct text on a 16 kHz clip | not run |
| 3 | Installer contents on Windows: worker and DLLs in `{app}`, no console window when the worker starts | T005 | Worker spawned by `localflow.exe`, no window | not run |
| 4 | Mac: hold and release Right Control, then a chord, with the tap running in the bundled app; Escape during a hold | T007 | One press and one release per hold; the chord's key doesn't reach the focused app with Accessibility on; Escape cancels | not run |
| 5 | Mac: recorder tap: captures a chord, consumes keys, ends at 30 s, on switching app, and on the second press | T007, ONB-369, ONB-370, SET-155, SET-156 | No key reaches another app while it runs; nothing saved on a stop | not run |
| 6 | Mac: tap health: revoke Input Monitoring and Accessibility during a hold, secure input (password field), sleep and wake, tap timeout from a stalled thread | T007, SET-164 | The hold cancels; a timeout keeps it and re-enables the tap; sleep cancels on wake, not before | not run |
| 7 | Mac: first-run prompts for Input Monitoring, Accessibility and Microphone in the signed app; the microphone wait doesn't hang the app past a minute | T009, SHELL-117, SHELL-118, SHELL-141, SHELL-142 | Each dialog appears once; state refreshes within a poll; granting reinstalls the tap | not run |
| 8 | Windows: `WH_KEYBOARD_LL` with Right Control and with a chord, including AltGr layouts and a slow machine, for longer than the 30 s hook refresh | T008 | Press and release fire; no duplicate after a refresh; typing stays responsive | not run |
| 9 | Windows: lost hook: force a hook timeout, and a key-up during a UAC prompt | T008 | The next refresh restores keys; the poll releases a hold within about 200 ms | not run |
