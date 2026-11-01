# Feature 025: hardware acceptance

Items that need real hardware or a signed install. None of them has been run.

| # | Item | Source | Expected | Result |
|---|---|---|---|---|
| 1 | Mac: `device_key_create`, `device_key_public_key` and `device_key_sign` on a signed build with a real Secure Enclave | T004 | A 65-byte public key; flowd accepts the signature once converted to DER | not run |
| 2 | Mac cutover: with `KEYCHAIN_PREFIX` set to the bundle ID, a signed build reads the Swift app's `server-key`, `device-key`, tokens and rewrite credentials | T003, T004 | Same items and handle, no re-enrollment, no Keychain prompt with the same signing team | not run |
| 3 | Mac: an unsigned or ad hoc build's `device_key_create` | T004 | Succeeds or reports unavailable, never a software key or a prompt | not run |
| 4 | Windows: Credential Manager write, read, remove, and refusal over 2,560 bytes | T005 | Round trip; the item shows under Generic Credentials; the large write fails with nothing stored | not run |
| 5 | Windows: TPM key create, public key, sign, delete on a TPM 2.0 PC | T005 | A 72-byte blob that converts to X9.63; flowd accepts the DER signature; key can't be exported; gone after delete | not run |
| 6 | Windows: TPM missing or disabled | T005, spec edge case | `device_key_create` reports unavailable; no software fallback | not run |
| 7 | Mac and Windows: pair a real device key with a token against a real flowd, through the Settings sheet of a signed build | T010, T013 | Approved; the admin list shows the device's name; refresh works after 12 minutes and after sleep | not run |
| 8 | Opening a `localflow://pair` link in a browser, once the Rust app registers the scheme at the cutover | T013 | The sheet opens filled in, nothing spent. Pasting a link works today | not run |
| 9 | Google sign-in in a real browser with a registered Desktop client, built with `LOCALFLOW_GOOGLE_CLIENT_ID`, against a real flowd | T014, T015 | Browser opens, the page closes the loop, the account enrolls; closing the tab frees the buttons within 5 minutes | not run |
| 10 | Windows: Run key, disk space, high contrast, animation setting, microphone consent read and `ms-settings:` opening | T016 | Each follows the Windows setting; a Deny refuses Start and offers Settings | not run |
| 11 | Windows: input catalog with built-in, USB and Bluetooth microphones | T016 | Names and kinds correct; the default is marked | not run |
| 12 | Windows: record microphone and process loopback for 10 minutes on real hardware | T018, T019 | Two valid ADTS tracks play back; `dropped_frames` 0 on an idle machine | not run |
| 13 | Windows: this app's own sound stays out of the system track | T018, spike gate 6 | An own tone is absent from `system-0001.aac`, present in a control | not run |
| 14 | Windows: microphone and system alignment over a 2 hour capture, including a quiet system track | T018, R8 | Tracks stay within 100 ms, as the host clock sets; the spike's VM saw 4.65 s of drift without this. `duration_warning` stays 0 | not run |
| 15 | Windows: change the default microphone and unplug a Bluetooth headset mid-meeting | T018, T020 | A new segment with `device_changed` within about a second; no device left fails the track only | not run |
| 16 | Windows: turn off microphone access mid-meeting | T018 | Track ends `permission_revoked`, the system track goes on | not run |
| 17 | Windows: Microsoft AAC encoder on x64, arm64 and an N edition | T019 | Encoder runs at 96 kbit/s and output plays in another player. N edition without Media Feature Pack: Start ends `failed` with both tracks `encoder_failed`, nothing crashes | not run |
| 18 | Windows: quit during a recording; kill the process during one and reopen | T020 | Quit finalizes within 10 s; after a kill the next launch recovers the `.part` and marks the meeting interrupted | not run |
| 19 | Windows: Pause, Resume, Stop from the tray and from the note | T020 | State, sidebar and tray agree | not run |
| 20 | Windows: Windows build under 20348 | T018 | Start refuses with the reason; nothing is created | not run |
| 21 | Windows: system sleep during a recording | LIVE-041 | Not built: no sleep notice exists yet. Today the sources fail or resume on their own; expected behaviour is a pause with reason `system_sleep` | not run |
| 22 | Windows: run the CI installer on a clean x64 PC with no Visual C++ runtime, under a standard user | T025, T026 | No administrator prompt; the welcome page says the build is unsigned; the app opens from the Start menu | not run |
| 23 | Windows: Run-at-login task, upgrade with the app open, uninstall | T025 | The task and Settings use the same `LocalFlow` Run value; the upgrade closes the app; uninstall removes the Run value and keeps `%LOCALAPPDATA%\LocalFlow` | not run |
| 24 | Windows arm64: the same x64 installer under emulation | T025 | Installs and opens | not run |
