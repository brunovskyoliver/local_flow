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
| 10 | Mac: AUHAL capture through `mic_mac.rs` on the built-in mic and a USB or Bluetooth input, at 44.1 and 48 kHz, mono and multichannel; a real 16 kHz result in the transcript | T011 | Words recognized; no overflow; AUHAL accepts the interleaved float client format | not run |
| 11 | Mac: unplug the input, and change its sample rate, during a recording | T011 | Stop reason `device_loss`, text saved for review, spool gone | not run |
| 12 | Mac: close the lid during a recording, wake | T011 | Stop reason `sleep` from the clock gap, text saved for review | not run |
| 13 | Mac: revoke Microphone during a recording | T011 | Stop reason `permission_revoked`, words so far saved | not run |
| 14 | Mac: `MicrophonePriority` order with clamshell mode, a dead device and the system default; fallback when the first device fails to start | T011 | Next candidate used; pill "<name> didn't respond" only if none did | not run |
| 15 | Windows: dictation through `win/mic.rs` on the default device and a pinned ranked device; change the default while pinned, and unplug | T011 | Pinned stays; a followed default or an unplug stops with `device_loss` | not run |
| 16 | Windows: microphone consent revoked during a recording; PC sleeps during a recording | T011 | `permission_revoked`; a hotkey cancel at sleep (no clock gap is seen on Windows) | not run |
| 17 | Mac and Windows, end to end in the bundled app: hold, speak, release into a text field with the real worker; longer than one 15 s window; the 3-minute limit; Escape while transcribing | T010, T012 | One row per dictation, the text inserted once, no audio left in Temporary Audio | not run |
| 18 | Kill the speech worker during a recognize job in the running app | T010, T012 | "The speech engine stopped…", waiting dictation in History, retried later | not run |
| 19 | Launch the bundled app with a shortcut saved and with Input Monitoring off | T012 | Shortcut live at launch, or the setup status tells how to fix it | not run |
| 20 | Mac: dictate into TextEdit, Notes, Safari, Slack, VS Code and a Chromium app (first press in a new Electron app too); `AXManualAccessibility` builds the tree | T013 | Text typed once at the caret, outcome confirmed; a first-press miss in an Electron app is the known ceiling | not run |
| 21 | Mac: a password field in Safari and in System Settings | T013 | Nothing typed or read; session copies to the clipboard | not run |
| 22 | Mac: switch app, window or caret during delivery of a long dictation; an app that hangs AX | T013 | Stops at the next chunk with an uncertain outcome; no stall past the 0.25 s message limit per call | not run |
| 23 | Mac: Terminal, iTerm and Ghostty paste; clipboard with text, an image and several items is back a second later; a copy during that second stays | T013 | Paste lands, clipboard managers skip it, snapshot restored unless something wrote; `sudo` prompt refuses | not run |
| 24 | Mac: History review "Choose destination" through "Confirm insertion" against a real field; UI stays responsive during a long insert | T013, T015 | Status text per HIST-174, row delivery state matches | not run |
| 25 | Mac: Settings context sheet lists running regular apps by name with `running_apps` | T013 | Same list as the Swift app | not run |
| 26 | Windows: Notepad, Word, a browser and Windows Terminal: focus found by UI Automation, Ctrl-V by `SendInput`, plain-text clipboard restored; a `CF_BITMAP` clipboard is not put back (known ceiling) | T014 | Text once at the caret, outcome confirmed | not run |
| 27 | Windows: a browser password field | T014 | `CurrentIsPassword` refuses; text copied, nothing pasted | not run |
| 28 | Windows: a target run as administrator from a non-elevated `localflow.exe` (UIPI) | T014 | No target; text saved and copied, the pill says so; `SendInput` never runs | not run |
| 29 | Windows: clipboard history (Win+V) stays free of the dictated text after a paste | T014 | `ExcludeClipboardContentFromMonitorProcessing` honored | not run |
| 30 | Dictation on a real server over the LAN, windows and fallback at threshold with a real worker and microphone | T016 | Text matches, falls back at the threshold, no audio lost | not run |
| 31 | Live rewrite against a real backend, HTTP and channel, with a real key in the Keychain | T017 | Rewritten text inserted; a stopped backend inserts the original with the notice | not run |
| 32 | Sleep during a remote dictation on a real Mac, then wake and retry | T016, T018 | The audio waits in History and recovers for review | not run |
| 33 | Speech, meeting and booster install from the real manifest over HTTPS with the real `flowd-speech` next to the app; Downloads rows and Settings progress | T019 | Progress, Verifying, Done; launch after that shows the model verified | not run |
| 34 | On-device AI install on a packaged, signed Mac app once its bundle carries the MTPLX resources | T019 | Not yet implementable: today the Mac reports missing local AI files | not run |
| 35 | Mac: learn corrections on; fix a word in TextEdit and a browser field after dictating, twice; Undo and Restore bubbles | Learner | Suggestion first, then "Added to dictionary"; Undo removes it; a reverted learned word retires with Restore | not run |
