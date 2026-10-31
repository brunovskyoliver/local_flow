# Hardware acceptance: Feature 027

Owner items. Nothing here has been run. Automated tests use fakes, loopback and the Simulator, and they don't stand in for any of it. Fill in the result, date, build and machine as each item is done. Use a signed build and a throwaway label where you can, and revoke the test devices afterwards.

| # | Item | Source | Expected | Result |
| --- | --- | --- | --- | --- |
| 1 | From a created token to a working client, timed | SC-001 | Under 1 minute, with no sign-in or manual fingerprint comparison | not run |
| 2 | Server mode on: real launchd start | T031, R8 | Agents load, flowd reports healthy, addresses and fingerprint appear | not run |
| 3 | Server mode off: real launchd stop | T031, R8 | Agents gone, nothing deleted, still off after logging out and in | not run |
| 4 | After turn off, Restart in LocalFlow Server and a run of `install-remote-server.sh` | Spec US3, T033, T034 | Each brings the server back | not run |
| 5 | Adopt the existing server, then Open to the network, on a test Mac | T026 | Plist and `--google-client-id` kept; a failed start restores the old plist within 60 s | not run |
| 6 | macOS Firewall prompt for flowd on a signed build | T031, ADR 0037 | Prompt appears, and a refusal leads to the Settings hint | not run |
| 7 | Local Network prompt on a signed Mac build | T031, R9 | Prompt appears; note what the app says after a refusal | not run |
| 8 | Local Network prompt on a real iPhone, allowed and then refused | R9 | Prompt appears; note what the app says after a refusal | not run |
| 9 | A server-mode Mac restarted with auto-login on, then off | T031, R8 | On: serves after restart. Off: doesn't serve until someone logs in | not run |
| 10 | Pair a real iPhone over LAN (`ws://` to an RFC 1918 literal) | R9 | Pairs and dictates or sends a meeting; not-TLS notice shown | not run |
| 11 | Pair a real iPhone over a Tailscale `100.64.0.0/10` literal and a `fd7a:115c:a1e0::/48` literal | R9 | Pairs, or the blocked class goes in the spec as https-only on iOS | not run |
| 12 | Pair a real iPhone over a `*.ts.net` name | R9 | Pairs under the `ts.net` exception | not run |
| 13 | Pair a real iPhone through a real reverse proxy with `https://` | T031, SC-002 | Pairs; no token in the proxy's access log | not run |
| 14 | Pair a second Mac over LAN, Tailscale and a real reverse proxy | T031 | Pairs on each; moving between routes with Change Address needs no new pairing | not run |
| 15 | A QR code from the Mac sheet and from LocalFlow Server, scanned by a real iPhone in light and dark | R2 | Opens the pairing sheet filled in; nothing connects before Pair | not run |
| 16 | Revoke a real device during a live session | SC-005 | Channel closes within 1 second | not run |
| 17 | Latency on each route: LAN, Tailscale, reverse proxy | T031 | Record Check connection times and dictation time to result | not run |
| 18 | RSS of client and server on one Mac, idle and during dictation | T031, ADR 0037 | Record both; the memory cost is unmeasured | not run |

`flowd-meeting` isn't bundled, so phone meeting handoff on an app-created server is expected to be unavailable. Items 10 to 13 should test meetings only against a server installed by script.
