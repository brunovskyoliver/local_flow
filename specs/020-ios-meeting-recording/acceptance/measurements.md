# Feature 020 measurements (SC-001 to SC-009)

Filled in by the owner on device. Simulator runs do not count for any row: the Simulator has no Secure Enclave, no real lock screen and no phone calls. Steps are in `../quickstart.md`, "Device and server".

## Setup

| Item | Value |
| --- | --- |
| Date | |
| iPhone model, storage, iOS version | |
| Phone build (commit, Debug or Release) | |
| Mac (model, macOS) and LocalFlow build | |
| Server (Mac mini model, macOS) | |
| flowd and `flowd-meeting` commit | |
| How the phone reaches the server (Wi-Fi, cellular; Tailscale on) | |
| Battery at start, Low Power Mode, other apps open | |
| Speakers, room, microphone (built-in or headset) | |

## Results

| SC | What is measured | Target | How | Result | Pass |
| --- | --- | --- | --- | --- | --- |
| SC-001 | 60-minute meeting with the phone locked: gaps other than marked pauses; plays back for its full length | no unmarked gap, full length | quickstart step 9; compare recorded duration with wall clock, scrub the whole meeting | | |
| SC-002 | Audio lost after a forced quit mid-recording | at most 10 s | quickstart step 8; note the wall-clock time of the kill and the end of the recovered audio | | |
| SC-003 | Stop to Ready for a 30-minute meeting, server reachable throughout | 3 min (target) | quickstart step 3; stopwatch from Stop to "Ready" | | |
| SC-004 | Server unreachable at Stop: time from the server becoming reachable to Ready, app running, no taps | 5 min | stop with Tailscale off, turn it on, stopwatch to "Ready" | | |
| SC-005 | Segments sent twice after an interrupted upload | at most 1 already-confirmed segment | airplane mode during Uploading, then off; count `put` lines for the meeting in `flowd.log` | | |
| SC-006 | Memory while recording, above the app's idle use | at most 100 MB | Xcode memory gauge or Instruments Allocations: idle on the Meetings tab, then after 10 and 60 minutes of recording | | |
| SC-007 | Server copy after the phone stored its result, Mac copy off | none | `ls "$DATA/handoff/<user-id>/"` after Ready | | |
| SC-008 | Audio or text leaving the phone before approval with the switch on | none | record with the device pending and with "Process meetings on this server" off; `flowd.log` shows no handoff for the device | | |
| SC-009 | Phone meeting processed while the Mac is offline: time from the Mac connecting to the meeting in its list; audio and transcript identical; Mac writes its own summary | 5 min | quickstart step 5; compare segment count, duration and transcript lines; check the summary after identification | | |

## Also record

| Item | Value |
| --- | --- |
| Battery used by the 60-minute locked recording (%) | |
| Phone storage per hour of meeting (MB) | |
| Phone call mid-meeting: pause marked, recording resumed in the same meeting (quickstart step 7) | |
| Revoked device: next upload stops with "this iPhone was revoked", recordings stay (quickstart step 6) | |

## Notes

Anything that differed from the steps, retries, and log excerpts (state, sizes and durations only).
