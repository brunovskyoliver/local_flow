# Tasks: Meeting Recording on iPhone, Processed by the Server

**Input**: Design documents from `specs/020-ios-meeting-recording/`

**Prerequisites**: plan.md, spec.md, research.md, data-model.md, contracts/

**Tests**: Required by constitution principle 12 (lifecycle, cancellation, limits, recovery). Test tasks are listed per story.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: can run in parallel (different files, no dependency on an unfinished task)
- **[Story]**: US1–US6 from spec.md

---

## Phase 1: Setup

**Purpose**: decisions, schema and wire contract that every later phase builds on.

- [X] T001 Write `docs/adr/0034-phone-meetings.md` (phone records and owns its meetings; server copy kept until the Mac imports it, at most 7 days; amends ADR 0006 and ADR 0033 retention; constitution check) and add it to `docs/adr/README.md`
- [X] T002 Add migration `phone-meetings-v19` to `packages/LocalFlowCore/Sources/LocalFlowCore/HistoryMigrations.swift`: rebuild `meeting_segments` with `rotated` in both reason CHECKs (rows, indexes, foreign keys preserved) and add `meetings.origin` (`local`/`iphone`) per data-model.md
- [X] T003 Update the frozen migration list in `apps/macos/LocalFlowTests/MacCompatibilityTests.swift` and add a migration test in `packages/LocalFlowCore/Tests/LocalFlowCoreTests/` that upgrades a v18 database with segment rows and checks they survive and `rotated` is accepted
- [X] T004 [P] Extend `protocol/schemas/remote-message.schema.json` per contracts/handoff-v2.md (`release`, `partial`, `copy`, `name` on `get`, `rows.sqlite`, list entry fields `transcribed_ms`, `mine`, `copy`, `released`) and add the valid/invalid fixtures under `fixtures/remote/messages/`

---

## Phase 2: Foundational (move the Mac client code into LocalFlowCore)

**Purpose**: the phone needs the channel, enrollment, meeting store, handoff and summary code the Mac already has (research R1). Each move: `git mv` into `packages/LocalFlowCore/Sources/LocalFlowCore/<Folder>/`, `public` API, explicit `public init`, remove the file from the `flowd-meeting` sources phase and the Mac target where the package now provides it, `import LocalFlowCore` in Mac callers. `scripts/check-core-imports.sh`, the Mac tests and the `flowd-meeting` build must pass after each task.

**⚠️ CRITICAL**: no user story work starts until this phase is green. Commit in two steps: T005–T008 (meetings and transcripts), then T009–T014 (remote and summary).

- [X] T005 Split `apps/macos/LocalFlow/Core/MeetingBoundaries.swift`: move the portable types (`ADTSFrame`, `MeetingCaptureFailure`, `MeetingEncoding`, `SegmentHandle`, `SegmentWriting`, `MeetingSourceFormat`, `MeetingClock`, `MeetingTransitionEffect`, `MeetingCursor`, `DeletionOutcome`, `MeetingStoring`) to `LocalFlowCore/Meetings/MeetingBoundaries.swift`; `SystemMeetingClock` uses `clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)`; `MeetingStartOptions.init(preferences:)` stays in the app
- [X] T006 Move `MeetingModels.swift`, `MeetingLifecycle.swift`, `FileSegmentWriter.swift` (with `MeetingStorageRoot`), `ADTSValidator.swift`, `MeetingTrackEncoder.swift` from `apps/macos/LocalFlow/Core/Meetings/` to `LocalFlowCore/Meetings/`; make `MeetingErrorMessage` wording a parameter or keep Mac texts in an app extension
- [X] T007 Move `MeetingStore.swift` and `MeetingReconciler.swift` to `LocalFlowCore/Meetings/`; the reconciler takes an optional `ResourceRecording` protocol instead of the concrete `ResourceRecorder`
- [X] T008 Move the transcript layer to `LocalFlowCore/Transcripts/`: `TranscriptStore`, `TranscriptModels`, `TranscriptLifecycle`, `TranscriptBoundaries`, and the value types it reads from `DiarizationRun.swift` and `IdentificationBoundaries.swift`; cut the speaker label text out of `Features/Speakers/SpeakerPalette.swift` into a package helper, and `IdentityStore.identities(meetingID:db:)` into a static SQL helper in the package
- [X] T009 Move the remote channel to `LocalFlowCore/Remote/`: `RemoteBoundaries`, `RemoteProtocol`, `RemoteChannel`, `RemoteCapabilities` (with `voiceModel` left in a Mac extension), `RemoteChannelPool` plus `RemoteRewriteChannels` and a cut-out `RemoteDictationResult`, the `RemoteMeetingJobs` part of `RemoteMeetingRuntimes`; add the new handoff fields and `release` to `RemoteHandoffRequest`/`RemoteHandoffReply` (contracts/handoff-v2.md) with decoder tests in `apps/macos/LocalFlowTests/RemoteProtocolTests.swift`
- [X] T010 Move `RemoteCredentialStore` with `service` and Keychain accessibility as required init parameters (Mac passes its current values) per research R7
- [X] T011 Move `RemoteEnrollment` (`SecureEnclaveDeviceKeys`, `SystemIdentitySignIn`, `URLSessionIdentityFetcher`): replace `AppPreferences` with a `RemoteEnrollmentSettings` protocol that `AppPreferences` conforms to, presentation anchor as `@MainActor () -> ASPresentationAnchor`, Google client ID passed in by the caller, no downcast to the concrete credential store
- [X] T012 Move `MeetingHandoff.swift` to `LocalFlowCore/Remote/`
- [X] T013 Move the summary path to `LocalFlowCore/Intelligence/`: `AnalysisStore`, `IntelligenceBoundaries`, `AnalysisProtocol`, `AnalysisValidator`, `AnalysisPolicy`, `AnalysisRun`, `EvidenceVersion`, `OverlayMatcher`, `DueDateResolver`, `ProtectedLiteralDetector`, `LanguagePolicy`, `AnalysisChunkPlanner`, a minimal portable `RewriteEndpoint`, and the channel half of `RemoteAnalysisTransport` (`RoutingAnalysisTransport` stays on the Mac)
- [X] T014 Add one line to `docs/adr/0029-ios-companion-and-shared-core.md` listing the moved groups, and run `make check` (Mac tests, package tests, flowd-meeting build) green

**Checkpoint**: Mac app, its tests and `flowd-meeting` behave exactly as before; the phone links the moved code.

---

## Phase 3: User Story 1 - Record a meeting on my iPhone (P1) 🎯 MVP

**Goal**: record a meeting with the phone locked, safely on disk, recoverable, listed and playable. No server.

**Independent Test**: airplane mode, record 20 minutes mostly locked, stop from the Live Activity, check the list entry and full playback.

### Tests for User Story 1

- [X] T015 [P] [US1] `apps/ios/LocalFlowPhoneTests/MeetingRecorderTests.swift`: with a fake engine feeding PCM, segments rotate at 360 s with `rotated` reasons, heartbeat progress every 5 s, interruption began/ended closes with `pause`, writes a `meeting_pauses` row, and reopens with `resume`, route change rotates with `device_changed`, storage floor stops and saves
- [X] T016 [P] [US1] `apps/ios/LocalFlowPhoneTests/PhoneMeetingCoordinatorTests.swift`: create → preparing (tracks and transcription row inserted) → recording → finalizing → completed; 4-hour cap; start refused while a dictation is finishing; starting ends a ready dictation session; `SessionController.open` refused while a meeting records
- [X] T017 [P] [US1] `apps/ios/LocalFlowPhoneTests/MeetingRecoveryTests.swift`: a `.part` file and `recording` row left by a crash are recovered to `interrupted` with the audio up to the last valid ADTS frame

### Implementation for User Story 1

- [X] T018 [US1] `apps/ios/App/Meetings/MeetingRecorder.swift`: `AVAudioSession` + `AVAudioEngine` tap → serial queue → `MeetingTrackEncoder` → `FileSegmentWriter`, behind a `MeetingAudioEngine` protocol for tests; rotation, heartbeat, interruptions (with `meeting_pauses` rows so gaps are recorded, FR-005), route changes per research R2; Meetings folder created `.completeUntilFirstUserAuthentication` and excluded from backup
- [X] T019 [US1] `apps/ios/App/Meetings/PhoneMeetingCoordinator.swift`: owns one meeting through `MeetingStore` (origin `iphone`, mic track, transcription row), start/stop/cap, storage warnings at 1 GB and stop at 200 MB, recovery on launch through `MeetingReconciler`
- [X] T020 [US1] Microphone ownership in `apps/ios/App/Session/SessionController.swift`: guard in `open` while a meeting records; coordinator ends a ready session with `.userEnded` before recording (research R9)
- [X] T021 [P] [US1] `apps/ios/Intents/MeetingActivityAttributes.swift` and `apps/ios/Intents/MeetingIntents.swift` (`StopMeetingIntent: LiveActivityIntent`, `MeetingIntentHandlers.current` slot), respecting `scripts/check-keyboard-imports.sh`
- [X] T022 [P] [US1] `apps/ios/Widgets/MeetingLiveActivity.swift` (Lock Screen and Dynamic Island: elapsed time, transcribed-up-to line, Stop) and register it in `apps/ios/Widgets/LocalFlowWidgets.swift`
- [X] T023 [US1] `apps/ios/App/Meetings/MeetingActivityController.swift`: requests the activity before recording starts (no activity, no recording), updates and ends it; with a requester protocol and `apps/ios/LocalFlowPhoneTests/Fakes/FakeMeetingActivityRequester.swift`
- [X] T024 [US1] Meetings tab: `apps/ios/App/Features/Meetings/MeetingsView.swift`, `MeetingsViewModel.swift`, `RecordingView.swift` (elapsed, level, input name, Stop), basic playback of a whole meeting; `Tab.meetings` in `apps/ios/App/RootView.swift`; wiring in `PhoneApp`/`PhoneServices`; `localflow://meetings`
- [X] T025 [US1] Microphone usage text in `apps/ios/Config/App-Info.plist` mentions meetings and the owner's server

**Checkpoint**: US1 works offline on the simulator and device.

---

## Phase 4: User Story 4 - Sign this iPhone in to my server (P1)

**Goal**: enrollment with Google, approval state, consent switch, sign-out.

**Independent Test**: fresh install, sign in, approve on the server, state Approved; revoke, next request shows Revoked.

### Tests for User Story 4

- [X] T026 [P] [US4] `apps/ios/LocalFlowPhoneTests/PhoneServerConnectionTests.swift`: with fake identity fetcher, device keys and transport: fingerprint confirm before sign-in, pending/approved/rejected/revoked states, a changed server identity blocks sending until re-confirmed, nothing opened while not approved or switch off, sign-out deletes credentials

### Implementation for User Story 4

- [X] T027 [US4] `apps/ios/App/Server/PhoneServerConnection.swift`: `RemoteEnrollmentSettings` conformance on UserDefaults, `RemoteCredentialStore` with `AfterFirstUnlockThisDeviceOnly`, enrollment, the channel pool opener (purpose `.session`), device name from `UIDevice`, consent version, "Process meetings on this server" and "Copy meetings to my Mac" settings
- [X] T028 [US4] `apps/ios/App/Features/Settings/ServerSettingsView.swift` per contracts/phone-ui.md, linked from `SettingsView.swift`
- [X] T029 [US4] `LocalFlowGoogleClientID` key in `apps/ios/Config/App-Info.plist` read from a build setting in `apps/ios/Config/Base.xcconfig` (default `569511417357-6130aocbp9ggo4g5meuifjjhbsr7aavj.apps.googleusercontent.com`, the phone's own Google iOS client; Google sign-in hidden when empty), and the reverse-client-ID URL scheme

**Checkpoint**: an approved phone holds credentials and opens a channel.

---

## Phase 5: User Story 2 - The server processes the meeting and the result comes back (P1)

**Goal**: upload after Stop, server processing, merge, summary, release.

**Independent Test**: record 10 minutes, stop, leave the app; transcript, speakers and summary arrive; server copy released.

### Tests for User Story 2

- [X] T030 [P] [US2] `apps/ios/LocalFlowPhoneTests/MeetingUploaderTests.swift` against a fake handoff channel: waits with the right detail when not approved/unreachable/limit/outdated; resumes from the server offset; never resends a confirmed segment; one meeting at a time, oldest first; backoff; merge failure leaves nothing partial; release after merge; failed → Retry; a meeting the server lists as `missing` after upload (retention expired) is uploaded again
- [X] T031 [P] [US2] `apps/ios/LocalFlowPhoneTests/MeetingSummarizerTests.swift`: builds an `AnalysisRequest` from merged rows, rejects an invalid result, adopts a valid one
- [X] T032 [P] [US2] `apps/ios/LocalFlowPhoneTests/PhoneMigrationTests.swift`: `phone-meetings-v1` after the shared migrations

### Implementation for User Story 2

- [X] T033 [US2] `phone-meetings-v1` (`phone_meeting_uploads`) in `apps/ios/App/Storage/PhoneMigrations.swift` per data-model.md
- [X] T034 [US2] `apps/ios/App/Meetings/MeetingUploader.swift`: the queue driver around the moved `MeetingHandoff` (export, segments, bundle, `start`, poll `list`, `get`, merge, `release` with `copy`), stages in `phone_meeting_uploads`, backoff `min(600, 30 << min(attempts, 5))` s, eligibility from enrollment state, switch and `handoff` capability; `missing` after upload triggers a fresh upload
- [X] T035 [US2] `apps/ios/App/Meetings/MeetingSummarizer.swift` per research R4, run after merge
- [X] T036 [US2] Background execution in `apps/ios/App/Meetings/MeetingUploader.swift` and `PhoneApp`: `BGContinuedProcessingTask` on in-app Stop, `beginBackgroundTask` on Live Activity Stop, run the queue on launch and every foreground; `BGTaskSchedulerPermittedIdentifiers` in `apps/ios/Config/App-Info.plist` (research R6)
- [X] T037 [US2] Meeting list rows and a simple detail screen show stage, progress, failure with Retry, and the finished transcript with speaker labels and the summary (`apps/ios/App/Features/Meetings/MeetingDetailView.swift`)

**Checkpoint**: MVP complete (phases 1–5).

---

## Phase 6: User Story 3 - Transcription starts while the meeting is still running (P2)

**Goal**: partial server runs on finished segments during recording.

**Independent Test**: 30-minute meeting with the server reachable; "Transcribed up to" advances; result within 3 minutes of Stop; 5 minutes offline mid-meeting with no gap.

### Tests for User Story 3

- [X] T038 [P] [US3] `server/internal/remote/handoff_test.go`: `start partial` from `receiving` only, runner passes `--partial`, state returns to `receiving`, `partial_failed` detail, `rows.sqlite` put at offset 0 truncates, `transcribed_ms` in list, cached hash cleared on requeue, puts refused while queued/processing
- [X] T039 [P] [US3] `apps/macos/LocalFlowTests/MeetingFinalizerTests.swift`: `run(partial:)` on a recording meeting transcribes finished segments, stops at the first unfinished or missing file, does not complete; a later partial run and the final run resume with no gaps or duplicates and match a single full run
- [X] T040 [P] [US3] `apps/ios/LocalFlowPhoneTests/MeetingUploaderTests.swift` (live cases): during recording, finished segments go up in order, then `rows.sqlite`, then `start partial`; waits while the server is busy; catches up after a disconnect; recording never blocks

### Implementation for User Story 3

- [X] T041 [US3] Server: `partial`, `rows.sqlite`, `transcribed_ms` in `server/internal/remote/protocol.go` and `server/internal/remote/handoff.go` per contracts/handoff-v2.md
- [X] T042 [US3] `MeetingFinalizer.run(partial:)` in `apps/macos/LocalFlow/Core/Transcripts/MeetingFinalizer.swift` per research R3, with a `ponytail:` comment on the O(n²) decode ceiling
- [X] T043 [US3] `apps/macos/MeetingProcessor/main.swift`: `rows.sqlite` import, `--partial` mode, `transcribed_ms` file
- [X] T044 [US3] Phone live driver in `apps/ios/App/Meetings/MeetingUploader.swift`: per finished segment upload, rows, partial start; `transcribed_ms` shown on the recording screen and the Live Activity

**Checkpoint**: head start works; after-Stop path unchanged when offline.

---

## Phase 7: User Story 5 - Read, search and manage meetings on the phone (P2)

**Goal**: full detail screen and management.

**Independent Test**: open a processed meeting, play from a line, rename a speaker, share, delete (files and server copy gone).

- [X] T045 [P] [US5] `apps/ios/LocalFlowPhoneTests/MeetingDetailViewModelTests.swift`: play-from-line offset across segments, speaker rename persists, delete removes files, rows and sends `delete` for a server copy
- [X] T046 [US5] `apps/ios/App/Features/Meetings/MeetingDetailView.swift` and `MeetingDetailViewModel.swift`: summary on top, transcript lines, tap to play from the line across segments, rename meeting and speakers, Copy and Share as plain text, Delete with confirmation
- [X] T047 [US5] Meeting deletion in `apps/ios/App/Meetings/PhoneMeetingCoordinator.swift` (files, rows, upload row, server `delete` when a copy exists or queued for the next connection)

---

## Phase 8: User Story 6 - My phone meetings also show up on my Mac (P3)

**Goal**: the Mac imports finished phone meetings once.

**Independent Test**: process a phone meeting, open the Mac as the same user, the meeting appears from iPhone with audio and transcript; server copy deleted; Mac offline 8 days → expired on the phone.

### Tests for User Story 6

- [ ] T048 [P] [US6] `server/internal/remote/handoff_test.go`: `device` recorded at first put, `mine` per caller, `copy` marker, `release` keeps with copy and deletes without, `get` with `name` serves an AAC, isolation between users unchanged
- [ ] T049 [P] [US6] `apps/macos/LocalFlowTests/MeetingHandoffImportTests.swift`: import of a foreign `done` meeting with `released` set inserts input and output rows and files in one transaction with `origin='iphone'`, skips own, unreleased and already-imported meetings, failed checksum leaves the Mac unchanged, deletes the server copy after import
- [ ] T050 [P] [US6] `apps/ios/LocalFlowPhoneTests/MeetingUploaderTests.swift` (Mac copy cases): `waiting → delivered`, `waiting → expired`, Send to Mac again re-uploads

### Implementation for User Story 6

- [ ] T051 [US6] Server: `device`, `copy`, `released`, `mine`, `release`, `get` by name in `server/internal/remote/protocol.go` and `handoff.go`
- [ ] T052 [US6] `apps/macos/LocalFlow/Core/Remote/MeetingHandoff+Import.swift` (imports only `mine == false`, `copy`, `released`, `done` entries) and a call from the Mac's existing server-wait loop; then `meetingDidReturnFromServer(id:labeled:)` so identification and the summary run
- [ ] T053 [US6] Mac list shows "From iPhone" for `origin='iphone'` meetings (`apps/macos/LocalFlow/Features/` meeting list row)
- [ ] T054 [US6] Phone Mac-copy state and Send to Mac again in `MeetingUploader.swift` and the meeting views

---

## Phase 9: Polish & Cross-Cutting Concerns

- [ ] T055 [P] `apps/ios/README.md`: Meetings, Server settings, "what lives where" rows, Google client ID setup, Tailscale requirement
- [ ] T056 [P] `docs/distribution/release-notes.md` and the server deployment note: redeploy `flowd` and `flowd-meeting` together (migration v19), add the phone's Google client ID to `--google-client-id`
- [ ] T057 [P] `specs/020-ios-meeting-recording/acceptance/measurements.md` template for SC-001–SC-009 (hardware, build, conditions, numbers to be filled on device)
- [ ] T058 Run `make check`; fix lint and import-rule failures

---

## Dependencies & Execution Order

- Phase 1 → Phase 2 → stories. T002 before T003; T004 independent.
- US1 (phase 3) needs phase 2 (meeting store, encoder, writer).
- US4 (phase 4) needs phase 2 (enrollment, channel) only; can run alongside US1.
- US2 (phase 5) needs US1 and US4.
- US3 (phase 6) needs US2.
- US5 (phase 7) needs US2 (results to show); deletion part needs only US1.
- US6 (phase 8) needs US2; server part T051 can start after phase 1.
- Polish last.

## Parallel Opportunities

- T004 with T001–T003.
- In phase 3: T015, T016, T017 together; T021 and T022 together.
- US1 and US4 in parallel after phase 2.
- In phase 6: T038, T039, T040 together; T041 (Go) alongside T042/T043 (Swift).
- In phase 8: T048, T049, T050 together.

## Implementation Strategy

MVP = phases 1–5: the phone records, signs in, and gets a processed meeting back after Stop. Then US3 (head start), US5 (detail and management), US6 (Mac copy). Each phase ends with `make check` green and one commit.

Device-only acceptance (enrollment on hardware, background behaviour, measurements) is recorded in `acceptance/` by the owner; it is not claimed by the simulator runs.
