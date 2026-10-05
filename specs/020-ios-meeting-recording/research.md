# Research: Feature 020, meeting recording on iPhone

Facts below come from reading the code at `cb7e32b`. Line numbers are approximate.

## R1. Reuse the Mac client code by moving it into LocalFlowCore

**Decision**: Move the portable Mac sources the phone needs into `packages/LocalFlowCore/Sources/LocalFlowCore` with the ADR 0029 pattern (`git mv`, `public`, explicit `public init`, platform services passed in, no `#if os`). No new package target. Each moved file is dropped from the `flowd-meeting` sources phase, which imports the package instead.

What moves:

| Group | Files (Mac path under `apps/macos/LocalFlow/`) | Cut needed first |
| --- | --- | --- |
| Remote channel | `Core/RemoteBoundaries.swift`, `Core/Remote/RemoteProtocol.swift`, `RemoteChannel.swift`, `RemoteCapabilities.swift`, `RemoteChannelPool.swift`, `RemoteCredentialStore.swift`, the `RemoteMeetingJobs` part of `RemoteMeetingRuntimes.swift` | `RemoteCapabilities.voiceModel` stays in a Mac extension; cut `RemoteDictationResult` and `RemoteRewriteChannels` into their own files; `RemoteCredentialStore.service` and accessibility become init parameters |
| Enrollment | `RemoteEnrollment.swift` (`SecureEnclaveDeviceKeys`, `SystemIdentitySignIn`, `URLSessionIdentityFetcher`) | replace `AppPreferences` with a `RemoteEnrollmentSettings` protocol (origin, state, notice, consent version, `reset()`), presentation anchor becomes `@MainActor () -> ASPresentationAnchor`, Google client ID default moves to the call site, drop the `as? RemoteCredentialStore` downcast via a protocol requirement |
| Meeting capture | `Core/Meetings/MeetingModels.swift`, `MeetingLifecycle.swift`, `FileSegmentWriter.swift` (with `MeetingStorageRoot`), `ADTSValidator.swift`, `MeetingTrackEncoder.swift`, `MeetingReconciler.swift`, `MeetingStore.swift`, portable half of `Core/MeetingBoundaries.swift` | `SystemMeetingClock` uses `clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)` instead of `LFAudioCaptureNow()`; `MeetingStartOptions.init(preferences:)` stays in the app; `MeetingReconciler` takes `ResourceRecording?` as a protocol (or nil) |
| Handoff | `Core/Remote/MeetingHandoff.swift` | none |
| Transcript | `TranscriptStore.swift`, `TranscriptModels.swift`, `TranscriptLifecycle.swift`, `TranscriptBoundaries.swift`, the value types from `DiarizationRun.swift` and `IdentificationBoundaries.swift` it reads | cut the label-text function out of `SpeakerPalette` (AppKit) and the `IdentityStore.identities(meetingID:db:)` query into a static SQL helper |
| Summary | `AnalysisStore`, `IntelligenceBoundaries`, `AnalysisProtocol`, `AnalysisValidator` and helpers (`AnalysisPolicy`, `AnalysisRun`, `EvidenceVersion`, `OverlayMatcher`, `DueDateResolver`, `ProtectedLiteralDetector`, `LanguagePolicy`, `AnalysisChunkPlanner`), the channel half of `RemoteAnalysisTransport` | a minimal portable `RewriteEndpoint`; `RoutingAnalysisTransport` stays on the Mac |

**Rationale**: about 8–10k lines already work, have tests, and define the exact rows `flowd-meeting` expects. Reimplementing any of it on the phone would fork the meeting schema handling the server depends on.

**Alternatives considered**: a second package target (`LocalFlowRemote`): no dependency difference, so one more target is ceremony. Reimplementing a thin phone client: diverges from what `flowd-meeting` reads.

**Not moved**: `MicrophoneMeetingSource`, `MeetingTrackWorker`, `MeetingSampleRing` and the C ring (CoreAudio HAL, Mac only); `MeetingCoordinator`; `MeetingAnalyzer`, `SpeakerStore`, `IdentityStore` (3.2k lines the phone doesn't need without voiceprints).

## R2. Phone capture

**Decision**: a phone `MeetingRecorder` of about 150 lines: `AVAudioSession` `.playAndRecord` (`.allowBluetoothHFP`, `.defaultToSpeaker`, no `.mixWithOthers`), `AVAudioEngine` input tap, a serial queue feeding the moved `MeetingTrackEncoder` (48 kHz mono AAC-LC 64 kbit/s, ADTS) and `FileSegmentWriter`. Heartbeat every 5 s: `fsync` and `MeetingStore.progressSegment`. Segment rotation every 360 s (3 × the 120 s finalizer window, so window cuts don't move). Interruption `.began` closes the segment with `pause`, `.ended` reopens with `resume`; route change rotates with `device_changed`.

**Rationale**: the Mac source is CoreAudio HAL; the phone already has a working `AVAudioEngine` template in `PhoneAudioCapture.swift`. Rows written through `MeetingStore` are exactly what `flowd-meeting` expects.

**Schema**: rotation needs new reasons. Migration `phone-meetings-v19` in the shared `HistoryMigrations` rebuilds `meeting_segments` with `open_reason` gaining `rotated` and `close_reason` gaining `rotated`, and adds `meetings.origin TEXT NOT NULL DEFAULT 'local' CHECK (origin IN ('local','iphone'))`. Because `flowd-meeting` links the client migrations, the server must be redeployed with the new processor (ADR 0033 consequence). `MacCompatibilityTests` gets the new migration name.

## R3. Progressive handoff ("transcribe during the meeting")

Today: `start` is accepted once from `receiving`; the processor refuses non-terminal meetings (`MeetingFinalizer.swift:213`, `meetingActive`), and it writes into `bundle.sqlite`, which `put` can only append to.

**Decision**:

1. **Server** (`server/internal/remote/handoff.go`, `protocol.go`):
   - `start` gains `partial: true`. Accepted from `receiving` only. The runner runs the processor with `--partial`; afterwards the state returns to `receiving` (success) or stays `receiving` with detail `partial_failed` (failure). No new state values, so old Macs never see one (their decoder rejects unknown states and abandons the handoff).
   - New file name `rows.sqlite` in the name regex. A `put` of `rows.sqlite` at offset 0 truncates it first; it is replaceable while `receiving`.
   - `list` entries gain optional `transcribed_ms` (written by the processor to `<dir>/transcribed_ms` after a partial run) and, for R5, `mine` and `copy`.
   - Clear the cached result hash when a meeting is requeued.
2. **Processor** (`apps/macos/MeetingProcessor/main.swift`): before running, if `rows.sqlite` exists, `ATTACH` it and `INSERT OR REPLACE` the input tables (`meetings`, `meeting_tracks`, `meeting_segments`, `meeting_pauses`, `meeting_notes`), then delete it. With `--partial`: run `MeetingFinalizer.run(partial: true)`, skip diarization, skip the exit-66 `final` check, write `transcribed_ms`.
3. **Finalizer** (`MeetingFinalizer.run(partial:)`): skip the `isTerminal` guard; cut the work list at the first sequence where any track's segment is not `finalized` or its file is missing; after the loop force-flush progress and finish the lease without `complete()`. A later run with the same pass identity resumes (`admit` keeps the pass while the row is `finalizing`).
4. **Phone ordering**: upload each finished AAC with its SHA-256 first, then `rows.sqlite`, then `start partial`. The first `start partial` needs `bundle.sqlite` (uploaded once, at the first partial); later row changes always go through `rows.sqlite`. The final step is `rows.sqlite` with the terminal meeting row, then `start` without `partial`.
5. **Cadence**: request a partial run after each finished segment (every 6 minutes) when the server is reachable and the previous partial run is done. While the server state is `queued`/`processing`, `put` writes nothing, so the phone waits; the audio is safe on disk.

**Rationale**: smallest change that keeps the existing processor, finalizer resume and handoff runner. Dictation preemption (SIGSTOP) and per-user limits apply unchanged.

**Known ceiling**: each partial rerun decodes the earlier audio again (echo profile and skipped stretches), O(n²) decoding without inference. AAC decode is far faster than real time; acceptable for meetings up to 4 hours. Upgrade path: persist decoded stretch offsets in the bundle. Recorded as a `ponytail:` comment.

**Alternatives considered**: per-window `meeting_job transcribe` from the phone (needs the finalizer windowing on the phone; owner chose A); uploading during the meeting but transcribing only after stop (no head start on transcription).

## R4. Summary on the phone

The handoff never produces a summary; the client writes it after the merge through the `analysis` op (ADR 0033). **Decision**: a phone `MeetingSummarizer` of about 150 lines: read transcript segments with speaker labels and notes by SQL, build an `AnalysisRequest`, send it over the channel with the moved `RemoteAnalysisTransport` channel code, validate with `AnalysisValidator`, persist with `AnalysisStore.adopt`. Speakers stay "Speaker N" (no voiceprints on the phone). **Alternative rejected**: summary inside `flowd-meeting` (it has no LLM route and opens no listener).

## R5. Copy to the Mac

**Decision**:
- Server writes `<dir>/device` (the principal's device ID) at the first `put`, and `<dir>/copy` when a `put` or `start` carries `copy: true`. `list` entries add `mine` (stored device equals the caller's) and `copy`.
- New action `release`: the phone sends it after its merge. If `copy` is set, the server keeps the meeting (`done`) and writes `<dir>/released`; otherwise it deletes it as `delete` does. `delete` keeps its meaning (remove now).
- `get` accepts `name` (an AAC file name) so another device can download the audio.
- The Mac's `MeetingHandoff` gains an import step: `list` → entries with `mine == false`, `copy == true`, `released == true`, state `done` (the phone already has its result, so the Mac's `delete` cannot take it from the phone) → download `bundle.sqlite` and every AAC → insert input rows (with `meetings.origin = 'iphone'`) and outputs in one transaction, files under the Mac's meeting root → `delete` → `meetingDidReturnFromServer(id:labeled:)` so identification and the summary run on the Mac.
- Retention: the existing 7-day sweep on directory mtime covers "at most 7 days".
- Phone delivery state: after `release`, the phone polls `list`; still present means waiting for the Mac; gone within 7 days of release means delivered; gone later means expired (the sweep). **Send to Mac again** uploads and processes the meeting again with `copy: true`.

**Rationale**: no new storage, no new state values. The Mac's existing step only looks up its own meeting IDs, so older Macs ignore phone entries.

**ADR**: 0034 records the amendment to ADR 0006 (the recording device owns its meetings; the owner's Mac receives a one-time copy) and to ADR 0033 retention (kept until the Mac imports it, at most 7 days).

## R6. Background execution after Stop

- During recording the process runs (audio background mode), so the channel works. Confidence high.
- Stop in the app: submit a `BGContinuedProcessingTask` (iOS 26), identifier `$(PRODUCT_BUNDLE_IDENTIFIER).meeting-upload.<id>`, `BGTaskSchedulerPermittedIdentifiers` with the wildcard entry, progress = bytes uploaded then server percent. It must be submitted from the foreground in response to the tap, which holds.
- Stop from the Live Activity (app in background): `beginBackgroundTask` (about 30 s) for the last segment; anything left resumes at the next launch or foreground.
- On launch and on every foreground: run the upload queue (FR-022).
- Not a background `URLSession`: the protocol is the encrypted WebSocket channel.

## R7. Keychain while locked

`RemoteCredentialStore` uses `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`, which fails while the phone is locked, and a locked phone is the normal case during a meeting. **Decision**: accessibility is an init parameter; the phone passes `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, the Mac keeps its value. Service `<bundle id>.remote`, no access group (the keyboard does not need it).

## R8. Google sign-in on the phone

The Mac's PKCE flow with `ASWebAuthenticationSession` works on iOS unchanged. Google intends one iOS client per bundle ID, and the server accepts a comma-separated `--google-client-id` list. **Decision**: register a separate Google iOS OAuth client for the phone's bundle ID, put it in the phone's Info.plist as `LocalFlowGoogleClientID`, and append it to the server's `--google-client-id`. Trying the Mac's client first is possible (the flow is bound to the redirect scheme, not the bundle ID) but relies on unenforced behaviour. The Secure Enclave is missing in the Simulator; tests use the `RemoteDeviceKeys` fake.

## R9. Microphone ownership

`SessionController.end(.userEnded)` ends dictation and its Live Activity. It must not run while a dictation is `.finishing` (it would delete the spool the pipeline is reading), so Record meeting waits for `.ready`/`.ended` or is disabled while finishing. One guard in `SessionController.open` refuses dictation while a meeting records; it covers the keyboard URL, `HandoffServer.start` and `PhoneIntentHandler.toggleDictation`.

## R10. Live Activity

A separate `MeetingActivityAttributes` (elapsed time, phase recording/stopping, server progress line) in `Intents/`, `StopMeetingIntent: LiveActivityIntent` calling a `MeetingIntentHandlers.current` slot, `Widgets/MeetingLiveActivity.swift` added to the widget bundle. Requested in the foreground before recording starts (ADR 0030); if it cannot be shown, nothing is recorded. Ended by the system after 8 hours, which is above the 4-hour recording cap. `Widgets/` and `Intents/` keep the import rules (`check-keyboard-imports.sh`).

## R11. Storage and protection

Meetings live in `Application Support/LocalFlow/Meetings/<UUID>/mic-NNNN.aac`, with the folder created with `.completeUntilFirstUserAuthentication` (writable while locked) and excluded from backup (recordings can be large). The phone `phone-meetings-v1` migration (in `PhoneMigrations`) adds `phone_meeting_uploads` (see data-model.md). The default `TranscriptionStore.maximumDatabaseBytes` (128 MiB) is enough: transcripts add about 0.5–2 MB per hour.

## R12. Measurements

Recording memory overhead (SC-006), battery over a 60-minute locked recording, upload time and time to result (SC-003) are collected on the owner's iPhone against the Mac mini and recorded in `acceptance/`. Nothing is claimed before it is measured.
