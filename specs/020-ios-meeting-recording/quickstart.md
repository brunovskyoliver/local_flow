# Quickstart: validating Feature 020

## Automated (no device)

```sh
make check
```

Covers: package tests for the moved code, Go tests for the handoff additions (`go test ./internal/remote/ -run Handoff`), protocol fixtures, the Mac test suite (handoff partial runs, import of a foreign meeting), the iOS unit tests on the simulator (recorder with a fake engine, upload driver against a fake channel, summarizer, mic-ownership guard, migrations), and the import-rule scripts.

Targeted runs:

```sh
cd server && go test -count=1 ./internal/remote/ -run 'Handoff'
swift test --package-path packages/LocalFlowCore
xcodebuild -project apps/macos/LocalFlow.xcodeproj -scheme LocalFlow test -only-testing:LocalFlowTests/MeetingHandoffTests -only-testing:LocalFlowTests/MeetingFinalizerTests
xcodebuild -project apps/ios/LocalFlowPhone.xcodeproj -scheme LocalFlowPhone -destination "platform=iOS Simulator,name=iPhone 17" CODE_SIGNING_ALLOWED=NO test -only-testing:LocalFlowPhoneTests
```

## Simulator walk-through

1. Build and run LocalFlow on the simulator, open Meetings, Record meeting for 1 minute, Stop. The meeting is listed with its duration and plays back.
2. Settings › Server shows Not signed in; the meeting shows Waiting for server (not signed in). Enrollment cannot complete in the simulator (no Secure Enclave).

## Device and server (owner)

Prerequisites: the phone has Tailscale on; the Mac mini runs the flowd and `flowd-meeting` builds from this branch; the phone's Google client ID is in the phone's Info.plist and in flowd's `--google-client-id`.

1. Settings › Server: enter `https://mac-mini.tailf15b6.ts.net`, confirm the fingerprint, Sign in with Google; approve the device on the server; state reads Approved.
2. Record 10 minutes with two speakers, phone locked; stop from the Live Activity. Within a few minutes the meeting reads Ready with transcript, Speaker 1/2 and a summary. The server's handoff dir for the meeting holds it until the Mac imports it.
3. Record 30 minutes with the server reachable; watch "Transcribed up to" advance; after Stop, time until Ready (SC-003 target 3 minutes).
4. Airplane mode for 5 minutes mid-meeting; the recording has no gap; the server catches up.
5. Open the Mac app as the same user: the phone meeting appears "From iPhone", plays, shows the transcript; the server copy is gone.
6. Revoke the device on the server: the next upload stops with Revoked; recordings stay.
7. Take a phone call mid-meeting with the phone locked; after hanging up, recording resumes in the same meeting with the gap marked.
8. Kill the app while recording; reopen: the meeting is recovered (at most 10 s lost).
9. Record 60 minutes locked; record memory overhead and battery use in `acceptance/measurements.md`.
