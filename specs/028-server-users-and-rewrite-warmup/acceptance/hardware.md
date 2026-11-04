# Hardware acceptance: Feature 028

Owner items. Nothing here has been run. Automated tests use fakes, a temp home, loopback, an in-process listener and the Simulator, and they don't stand in for any of it. Fill in the result, date, build and machine as each item is done. Use a development identity or a test Mac where you can, and revoke the test devices afterwards.

The rewrite cold-start owner run (T017, SC-001 and SC-002) is tracked in [rewrite-cold-start.md](rewrite-cold-start.md).

## User Story 2: set up this Mac as the server

| # | Item | Source | Expected | Result |
| --- | --- | --- | --- | --- |
| 1 | Fresh Apple Silicon Mac with no LocalFlow data, end to end: the server path in the Rust app's onboarding, pair a second device with the first token, dictate, rewrite, send a phone meeting | T034, quickstart §3.6 | Each step works on the new server | not run |
| 2 | Owner time for item 1, not counting download time | SC-003 | Under 5 minutes from first launch to a running server with a pairing token | not run |
| 3 | macOS Firewall prompt for flowd on a signed build, when opening to the network | T034, spec edge cases | Prompt appears; a refusal ends in the 60-second rollback with the reason shown | not run |
| 4 | Phone meeting handoff to a server set up from the Rust app (`flowd-meeting` bundled) | T034, FR-008 | The meeting is processed on the server and reaches the phone | not run |
| 5 | Server RSS, idle and during ordinary processing, excluding model worker processes | T034, principle 8 | Idle at or under 100 MB, processing at or under 250 MB; record both | not run |

## User Story 3: see and manage users and their devices

| # | Item | Source | Expected | Result |
| --- | --- | --- | --- | --- |
| 6 | App RSS with the Users page open, compared with idle | T049, quickstart §4.8 | Within 10 MB of the idle figure; record both | not run |
| 7 | Revoke a real device from the Users page while it is connected | T049, SC-005 | Its connections close within 2 s | not run |

## User Story 4: pair my own devices with each other

| # | Item | Source | Expected | Result |
| --- | --- | --- | --- | --- |
| 8 | Add a real iPhone to a Mac's account over the LAN with "Add another device", comparing the code on both screens | T064, SC-006, quickstart §5.7 | Under 1 minute, with no step on the server Mac | not run |
| 9 | After item 8, send a phone meeting from that iPhone | T064, quickstart §5.7 | The meeting reaches the Mac | not run |
