# Tasks: iOS dictation foundation

**Input**: [plan.md](plan.md), [spec.md](spec.md), [research.md](research.md), [data-model.md](data-model.md), [contracts/keyboard-handoff.md](contracts/keyboard-handoff.md), [contracts/localflowcore-package.md](contracts/localflowcore-package.md), [quickstart.md](quickstart.md)

Tests are included: constitution principle 12 requires them, and the plan and contracts list them. Paths are relative to the repo root.

- Register new Mac files with `python3 scripts/register-xcode-sources.py <path>` (paths relative to `apps/macos`). iOS files use the same script with `--project apps/ios/LocalFlowPhone.xcodeproj` once T030 adds that flag.
- Scope every `xcodebuild test` run with `-only-testing:` (the full Mac suite beeps). `make check` is the only full run.
- Device acceptance goes in `specs/016-ios-dictation-foundation/acceptance/` with date, iOS version, git SHA and conditions. A task that needs the iPhone is not done until a device run is recorded; mocks and simulator builds do not count.

## Order at a glance

The spec lists US6 sixth, but the plan builds it first: every phone story needs the package. The phases below follow the plan's build order, not the spec's numbering.

1. Phase 1: spike on the device (blocks everything)
2. Phase 2: ADR
3. Phase 3: US6, the Mac extraction, landed and verified alone
4. Phase 4: phone foundation (blocks US1–US5)
5. Phases 5–9: US1, US2, US3, US4, US5
6. Phase 10: acceptance, resource report, docs

---

## Phase 1: Setup — signing and handoff spike (blocks everything)

**Purpose**: prove on the iPhone 16 Pro that a free team can sign an app plus keyboard sharing one App Group, before any feature code exists. The spike uses the final bundle IDs so no App ID is wasted (research R10).

- [X] T001 Create `apps/ios/Config/Signing.local.xcconfig.example` with `DEVELOPMENT_TEAM =` and `LOCALFLOW_BUNDLE_PREFIX =` placeholders and a comment that both are set once and never changed (research R10). Add `apps/ios/Config/Signing.local.xcconfig` to `.gitignore`.
- [X] T002 Create `apps/ios/LocalFlowPhone.xcodeproj` in Xcode with two targets:
  - `LocalFlowPhone` (iOS 26.0, iPhone only, Swift 6 language mode), bundle ID `$(LOCALFLOW_BUNDLE_PREFIX).LocalFlow`.
  - `LocalFlowKeyboard` (custom keyboard extension embedded in the app), bundle ID `$(LOCALFLOW_BUNDLE_PREFIX).LocalFlow.Keyboard`.
  - Both include `Config/Signing.local.xcconfig` and share the App Group `group.$(LOCALFLOW_BUNDLE_PREFIX).LocalFlow`.
  - `apps/ios/App/Info.plist`: `UIBackgroundModes = [audio]`, URL scheme `localflow`, `NSMicrophoneUsageDescription`.
  - `apps/ios/Keyboard/Info.plist`: `RequestsOpenAccess = YES`, `PrimaryLanguage = en-US`.
  - A `LocalFlowPhoneTests` unit-test target hosted by the app.
  - Done: generated once (see research R14 outcome). Info.plists are `apps/ios/Config/App-Info.plist` and `Keyboard-Info.plist`; the group ID comes from `LOCALFLOW_APP_GROUP` in `Config/Base.xcconfig`, which `#include?`s the local signing file. Simulator builds exclude x86_64 because FluidAudio's text-processing library is arm64 only.
- [ ] T003 Write throwaway spike code in `apps/ios/Spike/SpikeAppView.swift` and `apps/ios/Spike/SpikeKeyboardViewController.swift` (add the spike files in Xcode by hand; the script flag arrives in T030):
  - The keyboard writes `ping.json` to `<group>/Handoff/` and rings a Darwin notification. The app answers with `pong.json` and a second notification. The keyboard shows the round-trip time.
  - An "Open app" key walks the responder chain to `UIApplication` and calls `open(_:options:completionHandler:)` with `localflow://session/start` (research R6).
  - The app starts an `AVAudioEngine` input tap with `.playAndRecord` and `[.mixWithOthers, .allowBluetoothHFP, .defaultToSpeaker]` and keeps it running in the background (research R7).
  - The keyboard shows its own `phys_footprint` (`task_info` `TASK_VM_INFO`).
  - Not built separately. The US1 build carries everything the spike checks (ping/pong round trip, opening the app from the keyboard, the background engine, `peak_footprint_bytes` in `keyboard-status.json`), so T004 runs quickstart §2 against the real app and keyboard. T005 has nothing to delete.
- [ ] T004 Run quickstart §2 on the iPhone 16 Pro and record in `specs/016-ios-dictation-foundation/acceptance/spike.md`:
  - App Group round trip works on the free team (yes/no).
  - Doorbell round-trip time (median of 10).
  - The app opens from the keyboard.
  - The app still answers after 2 minutes in the background with the engine running.
  - Whether the orange indicator shows, and whether music keeps playing with `.mixWithOthers`.
  - Keyboard footprint at rest with a SwiftUI hosting controller.
  - Decision: if the group fails, choose the R4 fallback. If `.mixWithOthers` kills background input, drop it (R7). If SwiftUI is above 30 MB at rest, the keyboard uses UIKit (R11). Update research.md with the outcome before continuing.
- [ ] T005 Delete `apps/ios/Spike/` and its target membership once T004 is recorded. Keep the project, targets, entitlements and signing config.

**Checkpoint**: spike passed and recorded, or the plan was updated with the chosen fallback.

---

## Phase 2: ADR

- [X] T006 Write `docs/adr/0029-ios-companion-and-shared-core.md`: an iOS companion app, the local package `packages/LocalFlowCore` with the targets `LocalFlowSpeech` and `LocalFlowCore`, why this amends ADR 0001's warning about early packages, and the rejected alternatives (shared file references, one target) from plan "Complexity tracking". Add it to `docs/adr/README.md`. Update the scope line in `AGENTS.md` ("Keep this one native macOS app…") to name the iOS companion and the shared package, so agents do not treat the phone app as out of scope.

---

## Phase 3: User Story 6 — The Mac app keeps working exactly as before (Priority: P1)

**Goal**: the portable code lives once in `packages/LocalFlowCore`; the Mac app and `flowd-speech` link it and behave exactly as before.

**Independent test**: `make check` passes with a test count at least equal to the baseline; the frozen migration and Mac paths tests pass; the manual Mac pass in quickstart §3 shows no change.

Land this phase as its own commit series (plan build order step 3) and merge it before Phase 4 starts.

- [X] T007 [US6] Run `make check` on the current `main` state and save the output and the Mac test count to `specs/016-ios-dictation-foundation/acceptance/mac-baseline.md`.
- [X] T008 [US6] Add the pinning tests before anything moves, in `apps/macos/LocalFlowTests/MacCompatibilityTests.swift`:
  - The migration identifiers from `HistoryMigrations.migrator()` equal a frozen list of the 16 current names, `history-v1` through `dictionary-usage-v16`, in order.
  - The database, temporary audio, pending audio and model URLs from `AppIdentity` for the everyday and Dev builds equal hard-coded expected strings.
  - They must pass on today's code.
- [X] T009 [US6] Create `packages/LocalFlowCore/Package.swift`:
  - `swift-tools-version: 6.0`, platforms `.macOS(.v14)` and `.iOS(.v26)`.
  - Dependencies `GRDB.swift` `exact: "7.10.0"` and `FluidAudio` `exact: "0.15.7"`.
  - Library products and targets `LocalFlowSpeech` (depends on FluidAudio) and `LocalFlowCore` (depends on `LocalFlowSpeech` and GRDB).
  - Test target `LocalFlowCoreTests` depending on both.
  - Add an `XCLocalSwiftPackageReference` to `../../packages/LocalFlowCore` in `apps/macos/LocalFlow.xcodeproj/project.pbxproj`. Link `LocalFlowSpeech` and `LocalFlowCore` to the `LocalFlow` target and `LocalFlowSpeech` only to `flowd-speech`. Keep the existing GRDB and FluidAudio package references for code that stays in the app.
  - Commit: "build(core): add LocalFlowCore package".
- [X] T010 [US6] `git mv` the `LocalFlowSpeech` set into `packages/LocalFlowCore/Sources/LocalFlowSpeech/`:
  - From `apps/macos/LocalFlow/Core/`: `SpeechBoundaries.swift`, `ModelWorkloadBoundaries.swift`.
  - From `Core/Transcription/`: `FluidAudioEngine.swift`, `VocabularyBoost.swift`, `MeetingLanguage.swift`, `TranscriptNormalizer.swift`, `ChunkPlanner.swift`, `TranscriptAssembler.swift`, `TranscriptionProvenance.swift`, `WindowedTranscriber.swift`.
  - From `Core/Models/`: `ModelLifecycleCoordinator.swift`, `ModelDescriptor.swift`, `ModelProvisioner.swift`.
  - From `Core/Corrections/`: `DictionaryChange.swift`.
  - From `Core/Audio/`: `AudioSpool.swift`.
  - Remove their file references from both targets in `apps/macos/LocalFlow.xcodeproj/project.pbxproj`.
  - Add `public` only to declarations used across the module boundary. No other edits.
  - `VocabularyBoostSpelling.swift` (NSSpellChecker) and `SpeechWorker/WorkerSpelling.swift` stay where they are and keep supplying the `(String) -> Bool` English-word check.
  - Add `import LocalFlowSpeech` to Mac and worker files that need it.
  - Commit: "refactor(core): move speech sources into LocalFlowSpeech".
- [X] T011 [US6] Change `AudioSpool` in `packages/LocalFlowCore/Sources/LocalFlowSpeech/AudioSpool.swift` so `maximumBytes` is an init parameter, `AudioSpool(rootDirectory:sessionID:maximumBytes: Int = 16 * 1_048_576)`. Existing Mac call sites pass nothing. Add `packages/LocalFlowCore/Tests/LocalFlowCoreTests/AudioSpoolCapacityTests.swift`: the default is 16 MiB, `19_200_000` stops at exactly that byte count, and writes past the cap are refused the same way the old static cap refused them.
- [X] T012 [US6] `git mv` the `LocalFlowCore` set into `packages/LocalFlowCore/Sources/LocalFlowCore/`:
  - From `apps/macos/LocalFlow/Core/Storage/`: `TranscriptionStore.swift`, `TranscriptionEntry.swift`, `HistoryMigrations.swift`, `VocabularyStore.swift`, `DictionaryUsageStore.swift`, `TermSuggestionStore.swift`.
  - The `Core/Corrections/` files these stores need (start from `CorrectionCandidate.swift`, `CorrectionCandidateHistory.swift`, `CorrectionCandidateScorer.swift`, `CorrectionStopwords.swift`, `TermSuggestions.swift`, `UsageClassifier.swift`, and move only what the compiler requires).
  - The value types the migrator and stores reference, moved as whole files only when the file has no Mac-only code; otherwise split the type into its own file first with `git mv` plus a minimal cut. Candidates: `Core/Rewrite/RewriteAttempt.swift`, the failure-reason enum in `Core/Remote/RemoteProtocol.swift`, the app context record, and the meeting state enums in `Core/Meetings/MeetingModels.swift` and `Core/Meetings/MeetingLifecycle.swift`.
  - Remove the references from the Mac project, add `public` and `import LocalFlowCore` where needed.
  - Record the final moved file list in `specs/016-ios-dictation-foundation/acceptance/extraction.md`.
  - Commit: "refactor(core): move storage and Dictionary into LocalFlowCore".
- [X] T013 [US6] Create `packages/LocalFlowCore/Sources/LocalFlowCore/LocalFlowPaths.swift`: `public struct LocalFlowPaths { database, temporaryAudio, pendingAudio, models: URL }` plus `init(applicationSupport: URL)` for iOS. Add `LocalFlowPaths.mac(identity:)` in `apps/macos/LocalFlow/App/AppIdentity.swift`, built from the same expressions `AppIdentity` uses today. Route the moved stores' path parameters through it. The T008 paths test must still pass unchanged.
- [X] T014 [P] [US6] Add `packages/LocalFlowCore/Tests/LocalFlowCoreTests/LocalFlowPathsTests.swift`: `init(applicationSupport:)` puts `history.sqlite` at `LocalFlow/history.sqlite` and models under `LocalFlow/Models`.
- [X] T015 [US6] Update the Mac tests for the move: add `@testable import LocalFlowSpeech` and/or `@testable import LocalFlowCore` to every file in `apps/macos/LocalFlowTests/` that uses a moved type. No test deleted, no assertion changed. If `@testable` does not reach package internals in Debug (research R1), make the members the tests use `public` instead and note it in `acceptance/extraction.md`.
- [X] T016 [P] [US6] Create `scripts/check-core-imports.sh` enforcing the package contract rules 1–3:
  - No `import` of AppKit, UIKit, SwiftUI, Carbon, ApplicationServices, ScreenCaptureKit, ServiceManagement or Cocoa in `packages/LocalFlowCore/Sources`.
  - No `import GRDB` in `packages/LocalFlowCore/Sources/LocalFlowSpeech`.
  - No `Process`, `NSWorkspace`, `homeDirectoryForCurrentUser` or `CGPreflight` in package sources.
  - No `#if os(` in package sources (rule 4).
- [X] T017 [P] [US6] Update `scripts/check-speech-worker-imports.sh` and `scripts/check-transcript-imports.sh` so they also scan `packages/LocalFlowCore/Sources/LocalFlowSpeech` (the worker's sources now come partly from the package, not only from its pbxproj sources phase).
- [X] T018 [US6] In `scripts/test.sh`, run `scripts/check-core-imports.sh` and `swift test --package-path packages/LocalFlowCore`.
- [ ] T019 [US6] Run `make check` and compare with `acceptance/mac-baseline.md`: all pass, test count ≥ baseline. Then run quickstart §3 by hand (`make run`, a TextEdit dictation, a rewrite, "Zabbix" dictated, a 1-minute meeting, existing History and meetings still present). Record both in `acceptance/mac-unchanged.md`.

**Checkpoint**: the extraction is merged, and the Mac is verified unchanged (SC-008).

---

## Phase 4: Phone foundation (blocks US1–US5)

**Purpose**: the pieces every phone story needs: project wiring, design tokens, handoff codec, storage, model provisioning, capture and the transcription pipeline.

### Build and design

- [X] T020 Add the local package reference `../../packages/LocalFlowCore` to `apps/ios/LocalFlowPhone.xcodeproj` and link `LocalFlowSpeech` and `LocalFlowCore` to `LocalFlowPhone` only. Bundle `apps/macos/LocalFlow/Resources/Models/parakeet-v3.json` and `parakeet-ctc-110m.json` into the app by file reference, not by copy.
- [X] T030 Add a `--project` argument to `scripts/register-xcode-sources.py`, defaulting to the Mac project, with the iOS target and phase IDs for `LocalFlowPhone`, `LocalFlowKeyboard` and `LocalFlowPhoneTests`. (Kept its ID; it runs here so T021–T029 can register their files.)
  - Not needed: the iOS project uses synchronized folders (research R14 outcome).
- [X] T021 [P] Create `apps/ios/Shared/Sotto/SottoTokens.swift`, compiled into both targets: the same hex values, radii and font names as `apps/macos/LocalFlow/UI/Appearance.swift`, built on `UIColor(dynamicProvider:)` for light and dark (research R13).
- [X] T022 [P] Create `apps/ios/Shared/Sotto/SottoFonts.swift`, which registers `Figtree.ttf`, `EBGaramond.ttf` and `EBGaramond-Italic.ttf` from the bundle with `CTFontManagerRegisterFontsForURL`. Add the three fonts from `apps/macos/LocalFlow/Resources/Fonts` to both targets by file reference.
- [X] T023 [P] Create `apps/ios/Shared/Sotto/CapsuleView.swift` and `apps/ios/Shared/Sotto/WaveformViews.swift`: the dark capsule, the scrolling bar waveform for recording and the rolling wave for working, following `apps/macos/LocalFlow/Features/Dictation/DictationIndicator.swift`. The waveform takes an array of levels as input and knows nothing about files.
- [X] T024 [P] Create `scripts/check-sotto-tokens.py`: extract the hex colour literals from `apps/macos/LocalFlow/UI/Appearance.swift` and `apps/ios/Shared/Sotto/SottoTokens.swift` and exit non-zero if the sets differ.
- [X] T025 [P] Create `scripts/check-keyboard-imports.sh`: fail if any file in `apps/ios/Keyboard` or `apps/ios/Shared` (compiled into the keyboard) imports `Network`, `FluidAudio`, `GRDB`, `LocalFlowCore` or `LocalFlowSpeech`, or mentions `URLSession`.

### Handoff codec (contract: keyboard-handoff.md)

- [X] T026 [P] Create `apps/ios/Shared/Handoff/HandoffModels.swift` (Foundation only): `Codable` types for `session.json`, `request.json`, `result.json`, `delivery.json` and `keyboard-status.json` with snake_case keys and `v: 1`, exactly as in the contract:
  - `SessionFile.state` ∈ `starting`, `ready`, `recording`, `finishing`, `ended`; `end_reason` set only when `ended`; `last_request_id` and `last_outcome` ∈ `empty`, `busy`, `no_session`, `failed` or null.
  - `RequestFile.kind` ∈ `start`, `stop`, `cancel`.
  - `ResultFile` always carries `text` (`outcome` is always `text`).
  - `DeliveryFile.delivery` ∈ `inserted`, `offered`.
  - `LevelsFile`: fixed 128 bytes, a UInt32 write index then 31 UInt32 slots, each a Float32 bit pattern in 0–1.
- [X] T027 [P] Create `apps/ios/Shared/Handoff/HandoffStore.swift`: resolves `<group container>/Handoff/`, creates it with protection `completeUntilFirstUserAuthentication` and excluded from backup, writes whole files with `Data.write(options: .atomic)`, and returns nil for a file that is missing, unparseable, or has `v != 1`.
- [X] T028 [P] Create `apps/ios/Shared/Handoff/Doorbell.swift`: posts and observes the six Darwin notification names from the contract (`app.localflow.handoff.request`, `.delivery`, `.ping`, `.pong`, `.session`, `.result`) through `CFNotificationCenterGetDarwinNotifyCenter`, delivering callbacks on the main actor.
- [X] T029 Add `apps/ios/LocalFlowPhoneTests/HandoffCodecTests.swift`: a round trip for every file type, rejection of unknown `v`, the levels file stays 128 bytes and wraps its index, and an atomic write is never read half-written (write in a loop from one task while reading in another).

### Tooling

- [X] T031 Add an `ios` target to `Makefile` that builds the `LocalFlowPhone` scheme for an iOS simulator with `CODE_SIGNING_ALLOWED=NO`. In `scripts/test.sh`, run `scripts/check-sotto-tokens.py`, `scripts/check-keyboard-imports.sh`, and `xcodebuild build test` on a simulator with `-only-testing:LocalFlowPhoneTests`.

### Storage

- [X] T032 Create `apps/ios/App/Storage/PhoneMigrations.swift`: takes `HistoryMigrations.migrator()` and registers `phone-dictations-v1` after it, creating `phone_dictations(transcription_id TEXT PRIMARY KEY REFERENCES transcriptions(id) ON DELETE CASCADE, source TEXT NOT NULL CHECK(source IN ('keyboard','app')), duration_ms INTEGER NOT NULL CHECK(duration_ms BETWEEN 0 AND 300000), delivery TEXT NOT NULL CHECK(delivery IN ('inserted','offered','saved_only')), end_detail TEXT CHECK(end_detail IS NULL OR end_detail IN ('limit_reached','interrupted','recovered_after_termination')), session_id TEXT)`, plus a CHECK or trigger that `source = 'app'` implies `delivery = 'saved_only'`.
- [X] T033 Create `apps/ios/App/Storage/PhoneDictationStore.swift` on top of the shared `TranscriptionStore` database:
  - `save(dictation:)` inserts the `transcriptions` row (`created_at` in ms at stop, `delivery_state = not_inserted` for both sources (never `attempting`, which the shared store's launch repair would turn into `uncertain` + `needs_review`), `quality`/`stop_reason` per data-model.md, `target_bundle_id` NULL, `recovery_state` `resolved` or `needs_review`) and the `phone_dictations` row in one transaction. Empty text is not saved.
  - `markDelivery(dictationID:_:)` sets `phone_dictations.delivery` and `transcriptions.delivery_state` together: `inserted` ↔ `confirmed`, `offered`/`saved_only` ↔ `not_inserted`.
  - `delete(id:)` deletes the `transcriptions` row, relying on the cascade.
  - `list()` newest first, joining the phone row.
  - A write failure throws; callers log `history_write_failed` with no text (FR-023).
- [X] T034 Create `apps/ios/App/PhoneServices.swift`: builds `LocalFlowPaths(applicationSupport:)` from the app container, opens `TranscriptionStore` with the phone migrator (WAL, `synchronous=FULL`, 0600, 128 MB page cap, file protection `completeUntilFirstUserAuthentication`), and creates the single `ModelLifecycleCoordinator`, `VocabularyStore` and `PhoneDictationStore`, plus a `KeepReady` holder counter (`session`, `dictateScreen`) that drives `setKeepLoaded`, `loadIfIdle` and `unloadIfIdle` as the plan's model ownership section describes.
- [X] T035 Add `apps/ios/LocalFlowPhoneTests/PhoneMigrationTests.swift`:
  - A fresh database has the 16 shared migrations followed by `phone-dictations-v1`.
  - A database that already has `phone-dictations-v1` still applies a fake later shared migration registered before it (research R5).
  - The CHECK constraints reject out-of-range `duration_ms` and unknown `delivery` values.
  - Deleting a transcription removes its phone row.
  - `markDelivery` writes both columns in one transaction.
  - `source = app` with `delivery = inserted` is rejected.
  - A keyboard row saved and never acknowledged is still `not_inserted` and `resolved` after the store is closed and reopened (the launch repair does not touch it).

### Models

- [X] T036 Create `apps/ios/App/Models/ResumableModelDownloadTransport.swift` conforming to the shared `ModelProvisioner` transport protocol: one background `URLSession` download per file, one file in flight, resume data kept on error or network loss and used on the next attempt, staging under `Models/.staging/<name>` (research R8).
  - A foreground `URLSession` with resume data kept on disk, not a background session: a download pauses while the app is suspended (`ponytail:` note in the file).
- [X] T037 Create `apps/ios/App/Models/PhoneModelState.swift`: the state machine `absent`, `downloading(progress)`, `paused`, `verifying`, `ready`, `damaged` from data-model.md §2, driven by `ModelProvisioner`. At launch it re-reads the manifest and fingerprints (no full hash) and moves to `damaged` if they fail. Promoted directories are marked `isExcludedFromBackup`. The boost model is optional: without it the state is still `ready` and V002 is skipped.
- [X] T038 Add `apps/ios/LocalFlowPhoneTests/ModelProvisioningTests.swift` with a fake transport: an interrupted download resumes from its resume data; a partial staging directory is never promoted; a hash mismatch yields `damaged` and deletes staging; a launch fingerprint failure yields `damaged` and leaves the database untouched.

### Capture and pipeline

- [X] T039 Create `apps/ios/App/Session/AudioCapturing.swift`: the capture protocol (`startEngine`, `beginDictation(spool:)`, `endDictation() -> EndReason`, `stopEngine`, interruption and level callbacks) and a `FakeAudioCapture` in `apps/ios/LocalFlowPhoneTests/Fakes/FakeAudioCapture.swift`.
- [X] T040 Create `apps/ios/App/Session/PhoneAudioCapture.swift`, conforming to `AudioCapturing`:
  - `AVAudioSession` `.playAndRecord`, mode `.default`, options per the T004 decision.
  - One `AVAudioEngine` input tap for the session's lifetime, never stopped between dictations.
  - Between dictations, buffers are dropped on the audio thread without copying (FR-013).
  - While recording, convert to 16 kHz mono Float32 and push 1,600-sample chunks through a ring of capacity 1 s (16,000 samples) into an `AudioSpool` created with `maximumBytes: 19_200_000`. Ring overflow ends the dictation with `overflow`; the spool limit ends it with `duration_limit`.
  - Levels are published at about 20 Hz while recording.
  - `stopEngine` calls `setActive(false, options: .notifyOthersOnDeactivation)`.
- [X] T041 Create `apps/ios/App/Transcription/TextCheckerSpelling.swift`: `(String) -> Bool` backed by `UITextChecker` with language `en_US`, the iOS counterpart of `VocabularyBoostSpelling` (research R2, R16).
- [X] T042 Create `apps/ios/App/Transcription/PhoneDictationPipeline.swift`: takes a closed spool, runs the shared `WindowedTranscriber` with `TranscriptNormalizer` and `VocabularyBoost` by acquiring one lease per dictation with `ModelLifecycleCoordinator.acquire(session:boost:)` using the `VocabularySnapshot` current at stop, and calling `finish` when done (never touching FluidAudio managers directly), and returns normalized text plus `quality`/`stop_reason`. Wrap model load and transcription in `os_signpost` intervals. Delete the spool after completion, cancellation and failure.
- [X] T043 Create `apps/ios/App/Storage/OrphanSpoolRecovery.swift`: at launch, find a spool left in `TemporaryAudio/`. If the model is `ready`, transcribe it and save with `recovery_state = needs_review` and `end_detail = recovered_after_termination`, then delete it. If the model is not ready, keep the orphan and recover it when `PhoneModelState` next becomes `ready`; show "1 unrecovered recording" with Delete in the Settings speech model section (T066). If transcription fails, delete it and log one content-free line. There is at most one orphan.
- [X] T044 Add `apps/ios/LocalFlowPhoneTests/PipelineTests.swift` with `FakeAudioCapture` and a fake speech engine: ring overflow ends with `overflow` and still transcribes captured audio; the 19.2 MB limit ends with `duration_limit`; silence gives empty text and no History row; the spool is deleted on success, cancel and failure; an orphan spool is recovered and marked `needs_review`, and a failing orphan is deleted; an orphan found while the model is absent is kept, then recovered when the fake model state becomes `ready`, and Delete removes it.

### App shell

- [X] T045 Create `apps/ios/App/LocalFlowPhoneApp.swift` and `apps/ios/App/RootView.swift`: build `PhoneServices`, register fonts, run `OrphanSpoolRecovery` and the model launch check, and show a tab view with Dictate, History, Dictionary and Settings using Sotto tokens. Each tab is an empty placeholder until its story fills it. Create `apps/ios/App/Features/Settings/SettingsView.swift` as an empty `Form` that later stories add sections to.

**Checkpoint**: `make ios` and `make check` pass; the pipeline turns a spool into a saved History row in tests.

---

## Phase 5: User Story 1 — Dictate into any app from the LocalFlow keyboard (Priority: P1) 🎯 MVP

**Goal**: the first capsule tap opens LocalFlow and starts a listening session; after swiping back, each tap dictates straight into the focused field until the idle timeout.

**Independent test**: with the model provisioned and the keyboard enabled, start a session from the keyboard, return to Notes, dictate three sentences in three taps, and check each lands at the cursor (quickstart §5).

### Tests for User Story 1

- [X] T046 [P] [US1] Add `apps/ios/LocalFlowPhoneTests/SessionControllerTests.swift` with `FakeAudioCapture` and a test clock, covering every transition in data-model.md §3:
  - `starting` → `ended` on mic denied, engine failure and missing model.
  - `ready` → `recording` → `finishing` → `ready` with `idle_deadline = now + timeout`; with `afterOne`, `finishing` → `ended`.
  - A start while not `ready` reports `busy`, and with no session `no_session`, through `session.json`'s `last_outcome`.
  - A stop with a non-matching request ID is ignored.
  - A request older than 10 s, or with a mismatched `session_id`, is ignored; the newest request wins.
  - The idle deadline ends the session within 1 s of the deadline on a 1 s tick.
  - An interruption while recording finishes the captured audio, then ends with `interrupted`.
  - A memory warning drops keep-ready and unloads only when not recording.
  - `ended` stops the engine, drops the session's keep-ready hold and unloads the model unless the Dictate screen still holds it.
  - Each dictation acquires and finishes its own lease; a Dictionary edit between two dictations in one session changes the second one's boost terms.
  - An `origin = app` session ends after its dictation with `end_reason = afterOneDictation`, even when the idle timeout is 1 h.
  - Opening the URL while a session is `starting`, `recording` or `finishing` keeps it; an `origin = app` session opened this way becomes `origin = keyboard` and returns to `ready` after its dictation.
- [X] T047 [P] [US1] Add `apps/ios/LocalFlowPhoneTests/InsertionPolicyTests.swift`: every combination of visible × request match × document match from the contract's insertion rules; a non-text `last_outcome` for the pending request shows its message and leaves an existing offer in place; Undo is offered only while `documentContextBeforeInput` ends with the inserted text, for at most 10 s, and until the next text change; nil context hides Undo; a result not acknowledged `inserted` is offered on next appearance.
- [X] T048 [P] [US1] Add `apps/ios/LocalFlowPhoneTests/HandoffServerTests.swift`: a start request leads to `session.json` saying `recording`; stop produces History save → `result.json` → `result` bell in that order; `delivery.json` with `inserted` updates History and deletes `result.json`; a result is deleted once it is 10 minutes old, checked at session end, at launch and on becoming active; an empty or busy reply updates `session.json` and leaves `result.json` untouched; `levels.bin` is written only while recording.
- [X] T089 [P] [US1] Add `apps/ios/LocalFlowPhoneTests/KeyboardSessionModelTests.swift` (compile `apps/ios/Keyboard/KeyboardSessionModel.swift` into the test target, as with T055) with a fake handoff store, fake doorbell and test clock: no `pong` within 500 ms, or a missing or `ended` `session.json`, gives `none`; `recording` is shown only after `session.json` says so; a pending request with no result after 15 s shows the "LocalFlow stopped" message; a matching `last_outcome` shows its message and a non-matching one is ignored; a result older than 10 minutes is not offered; without Full Access nothing is written to the group. (New ID; added after analysis.)

### Implementation for User Story 1

- [X] T049 [US1] Create `apps/ios/App/Session/IdleTimer.swift`: a 1 s repeating tick against an injectable clock, reporting when `idle_deadline` has passed. Idle timeouts `afterOne`, `5m` (default), `15m` and `1h`, read from `UserDefaults` key `session.idleTimeout`.
- [X] T050 [US1] Create `apps/ios/App/Session/SessionController.swift` (main actor): owns at most one `PhoneSession` (`id`, `origin`, `startedAt`, `idleDeadline`, `state`, `endReason`, `currentDictation`) and `ActiveDictation` (`id`, `requestID`, `source`, `startedAt`, `spool`), implementing data-model.md §3 over `AudioCapturing`, `PhoneDictationPipeline`, `PhoneDictationStore` and the coordinator. The session adds a `keepReady` hold on `ready` and drops it at end; on `didReceiveMemoryWarningNotification` when not recording it drops all holds and unloads. Each dictation acquires and finishes its own lease. It supports `origin = app` sessions that end after one dictation. Interruptions finish transcription inside `beginBackgroundTask`. It logs only IDs, states and durations.
- [X] T051 [US1] Create `apps/ios/App/Session/HandoffServer.swift`: observes `request`, `delivery` and `ping`, and re-reads the files whenever the app becomes active. It maps requests onto `SessionController`, writes `session.json` on every state change (and removes it on a clean launch with no session), answers `ping` with `pong`, and writes `levels.bin` at about 20 Hz while recording. On stop it follows the contract sequence: History save (`saved_only`, `not_inserted`) → `result.json` → `result` bell. A failed History write still publishes the result (FR-023). It applies `delivery.json` through `PhoneDictationStore.markDelivery`, deletes `result.json` on `inserted`, and deletes a result 10 minutes after creation, checked at session end, at launch and on becoming active. Add `os_signpost` for request → result.
- [X] T052 [US1] Handle `localflow://session/start?request=<uuid>` in `apps/ios/App/LocalFlowPhoneApp.swift`: if a session exists in any state other than `ended`, keep it (an `origin = app` session becomes `origin = keyboard`); otherwise start one in the foreground. In both cases show the session screen. The `request` parameter never starts a dictation.
- [X] T053 [US1] Create `apps/ios/App/Features/Session/SessionView.swift`: "LocalFlow is listening", the swipe-back hint ("Swipe right on the bottom bar, or tap ◀ in the top-left corner, to go back"), the idle deadline counting down, and an End session button that ends it at once (FR-012). A banner on `RootView` shows whether a session is running.
- [X] T054 [US1] Add an "End listening after" picker (after one dictation, 5 minutes, 15 minutes, 1 hour) to `apps/ios/App/Features/Settings/SettingsView.swift`, bound to `session.idleTimeout`.
- [X] T055 [US1] Create `apps/ios/Keyboard/InsertionPolicy.swift` (pure, Foundation only, also compiled into `LocalFlowPhoneTests`): `decide(visible:pendingRequestID:resultRequestID:documentIDAtStart:documentIDNow:) -> insert | offer | show(message)` and `canUndo(inserted:insertedAt:now:contextBefore:textChangedSince:)`.
  - Done in `apps/ios/Shared/KeyboardLogic/InsertionPolicy.swift`. `Shared` is compiled into the app as well, so the tests reach it with `@testable import LocalFlow` instead of compiling keyboard files into the test target. `decide` returns insert or offer; `message(for:)` covers the non-text outcomes.
- [X] T056 [US1] Create `apps/ios/Keyboard/KeyboardSessionModel.swift`: the keyboard state from data-model.md §4 (`sessionView` ∈ `unknown`, `none`, `ready`, `recording`, `working`, `ended(reason)`, `pendingRequest`, `lastInsertion`, `offered`). It pings on appear and treats no `pong` within 500 ms, or a missing or `ended` `session.json`, as `none`. On tap it stores `documentIdentifier`, writes `request.json` and rings. It shows `recording` only once `session.json` says so. A pending request with no result after 15 s shows "LocalFlow stopped. Open it to recover the last dictation." It applies `InsertionPolicy` to results, writes `delivery.json` and rings `delivery`. It reads `last_outcome` from `session.json` for its pending request. It never offers a result more than 10 minutes old.
  - Done in `apps/ios/Shared/KeyboardLogic/KeyboardSessionModel.swift`, for the same reason as T055. The 15 s "LocalFlow stopped" timer starts at the stop tap, because a recording can be longer than 15 s.
- [X] T057 [US1] Create `apps/ios/Keyboard/KeyboardViewController.swift`: a `UIInputViewController` with one hosting controller for its lifetime, torn down in `viewDidDisappear`. The "Start LocalFlow" tap opens `localflow://session/start?request=<uuid>` through the responder chain to `UIApplication.open(_:options:completionHandler:)`. It writes `keyboard-status.json` (`has_full_access`, `last_seen`, `peak_footprint_bytes` from `TASK_VM_INFO` `phys_footprint`) on appear and disappear. If the spike chose UIKit (T004), build the view in UIKit instead of SwiftUI.
- [X] T058 [US1] Create `apps/ios/Keyboard/KeyboardView.swift` with Sotto tokens:
  - The mic capsule in its live, recording (scrolling bar waveform from `levels.bin` via `CADisplayLink`, only while recording), working (rolling wave) and done states, and "Start LocalFlow" when there is no session.
  - Delete, return, space, next keyboard (`advanceToNextInputMode`), and basic punctuation keys (FR-007).
  - Undo while `InsertionPolicy.canUndo`, deleting `inserted.count` grapheme clusters with `deleteBackward()`.
  - "Insert last dictation" when an offer is pending.
  - Short messages for "Didn't catch that", "Dictation failed", and "Limit reached" (when `limit_reached` is true).
- [ ] T059 [US1] Run quickstart §5 on the iPhone 16 Pro (SC-001 10 runs of 15 s, SC-002 20 dictations in a row, SC-009 indicator off within 10 s of the deadline, Undo) and record the results in `specs/016-ios-dictation-foundation/acceptance/keyboard.md`.

**Checkpoint**: keyboard dictation works end to end on the device.

---

## Phase 6: User Story 2 — Set up once, then dictate offline (Priority: P1)

**Goal**: a four-step setup the owner can leave and resume; after it, dictation works in Airplane Mode.

**Independent test**: install on a clean phone, complete setup, turn on Airplane Mode, force-quit the app, and dictate from the keyboard (quickstart §4).

- [ ] T060 [P] [US2] Add `apps/ios/LocalFlowPhoneTests/SetupChecklistTests.swift`: the step states are derived from `setup.completedSteps`, `keyboard-status.json` (missing → "not detected yet"; `has_full_access` false → Full Access missing), microphone authorization and `PhoneModelState`; they survive a relaunch; and the space check refuses when available capacity is below the descriptors' total plus 10%.
- [ ] T061 [US2] Create `apps/ios/App/Features/Setup/SetupChecklistModel.swift`: steps `keyboard`, `fullAccess`, `microphone`, `model`, `firstDictation` stored in `UserDefaults` key `setup.completedSteps`. `keyboard` and `fullAccess` are re-checked at launch from `keyboard-status.json`.
- [ ] T062 [US2] Create `apps/ios/App/Models/ModelSetupViewModel.swift`: checks `volumeAvailableCapacityForImportantUsage` against the descriptors' total size plus 10% and says how much space is needed; starts, pauses and resumes the download through `PhoneModelState` with visible progress; offers a new download when the state is `damaged`.
- [ ] T063 [US2] Create `apps/ios/App/Features/Setup/SetupView.swift`: four steps in the order "Add the keyboard and allow Full Access" (with the plain explanation that Full Access is used only to share state with the app and to open it, and that the keyboard sends nothing to the network), "Allow the microphone", "Download the speech model" (progress, space needed) and "Try a first dictation". Deep links go to Settings where possible. Setup shows on launch until all steps are done and can be reopened from Settings.
- [ ] T064 [US2] Show missing prerequisites in the keyboard, in `apps/ios/Keyboard/KeyboardView.swift`: without Full Access, a message saying what is missing and how to turn it on, with no writes to the group; a `failed` result caused by a missing model or a denied microphone shows a hint to open LocalFlow (FR-009).
- [ ] T065 [US2] Handle a denied microphone in the app: in `apps/ios/App/Session/SessionController.swift`, end the session with `permissionDenied`, and show an explanation with a link to Settings in `apps/ios/App/Features/Session/SessionView.swift` and on the Dictate screen.
- [ ] T066 [US2] Add a Speech model section to `apps/ios/App/Features/Settings/SettingsView.swift`: state, size on disk, revision, and Delete (confirmation, drops keep-ready and unloads the model, removes the promoted directories, state becomes `absent`; History and Dictionary untouched). While an orphan spool waits for the model (T043), show "1 unrecovered recording" with its own Delete.
- [ ] T067 [US2] Run quickstart §4 on the device (setup timed excluding download, SC-007; download interrupted and resumed; Airplane Mode plus force-quit then keyboard dictation, SC-005; Full Access off; microphone denied) and record the results in `specs/016-ios-dictation-foundation/acceptance/setup-offline.md`.

**Checkpoint**: a clean install reaches offline dictation through setup alone.

---

## Phase 7: User Story 3 — Dictate a note in the app and find past dictations (Priority: P2)

**Goal**: a Dictate button that saves notes, and a History tab listing every dictation.

**Independent test**: dictate two notes in the app and one through the keyboard; all three are in History and each can be copied and deleted.

- [ ] T068 [P] [US3] Add `apps/ios/LocalFlowPhoneTests/DictateViewModelTests.swift` with `FakeAudioCapture` and a test clock: a dictation saves a note with `source = app`, `delivery = saved_only`; keep-ready is held while the screen is visible and the model unloads 30 s after it disappears (coordinator cooldown, test clock); with no session running a dictation starts an `origin = app` session that ends afterwards and turns the engine off; the 5-minute limit stops and keeps the text; a dictation cannot start while a keyboard session is recording (returns busy).
- [ ] T069 [US3] Create `apps/ios/App/Features/Dictate/DictateViewModel.swift`: runs an in-app dictation through `SessionController`: it uses a `ready` session if one exists, otherwise starts an `origin = app` one-shot session, with a fresh request ID and `source = app` (sharing the one-at-a-time rule). It holds `keepReady` (`dictateScreen`) while visible and drops it on disappear.
- [ ] T070 [US3] Create `apps/ios/App/Features/Dictate/DictateView.swift`: a large Dictate button using the capsule and waveform views, the last note's text with a one-tap Copy, and the limit and "didn't catch that" messages.
- [ ] T071 [P] [US3] Create `apps/ios/App/Features/History/HistoryViewModel.swift` over `PhoneDictationStore.list()` and `delete(id:)`, newest first, showing time, source, delivery, target app when not NULL, and a "needs review" mark for recovered entries.
- [ ] T072 [US3] Create `apps/ios/App/Features/History/HistoryView.swift`: the list, with Copy, Share (`ShareLink`) and Delete (swipe and context menu) per entry.
- [ ] T073 [US3] Add `apps/ios/LocalFlowPhoneTests/HistoryViewModelTests.swift`: ordering, keyboard and app entries both listed, and delete removes the `transcriptions` and `phone_dictations` rows.

**Checkpoint**: in-app notes and History work without the keyboard.

---

## Phase 8: User Story 4 — The Dictionary spells names the way the owner does (Priority: P2)

**Goal**: add, edit, disable and delete Dictionary entries and aliases on the phone, with the Mac's rules applied to the next dictation.

**Independent test**: add "Zabbix" and "Homarr" (with an alias), dictate a fixed sentence containing them, and check the spellings (quickstart §7).

- [ ] T074 [P] [US4] Add `apps/ios/LocalFlowPhoneTests/PhoneDictionaryTests.swift`: through the shared `VocabularyStore` on the phone database, a canonical term and an alias are applied by `TranscriptNormalizer` exactly as on the Mac (reuse the expected strings of one Mac `TranscriptNormalizerTests` case); editing or disabling an entry bumps `vocabulary_state.revision` and the next snapshot reflects it; the Mac limits (≤ 512 entries, ≤ 4,608 keys) return the Mac errors; saves use the `.editor` origin so usage rows stay unused.
- [ ] T075 [US4] Create `apps/ios/App/Features/Dictionary/DictionaryViewModel.swift` over `VocabularyStore`: list, add, edit, enable/disable and delete, using the Mac validation messages.
- [ ] T076 [US4] Create `apps/ios/App/Features/Dictionary/DictionaryListView.swift` and `apps/ios/App/Features/Dictionary/DictionaryEditorView.swift`: canonical spelling, aliases, enabled toggle, delete, in Sotto style.
- [ ] T077 [US4] Run quickstart §7 on the device and record the result in `specs/016-ios-dictation-foundation/acceptance/dictionary.md`.

**Checkpoint**: Dictionary edits change the next phone dictation.

---

## Phase 9: User Story 5 — Weekly reinstall keeps everything (Priority: P2)

**Goal**: reinstalling from Xcode, including after the 7-day expiry, keeps History, the Dictionary, settings and the model.

**Independent test**: record data, reinstall the same build over itself, and check everything remains with no new setup (quickstart §9).

- [ ] T078 [US5] Audit the storage locations and fix any that fall outside the containers a reinstall keeps: the database and models under the app's `Application Support/LocalFlow`, settings in `UserDefaults.standard`, handoff files in the App Group, nothing in `Caches` or `tmp` that must survive. Write the list, and the rule that `DEVELOPMENT_TEAM` and `LOCALFLOW_BUNDLE_PREFIX` must never change, to `apps/ios/README.md` together with the weekly reinstall steps.
- [ ] T079 [US5] Make the setup checklist in `apps/ios/App/Features/Setup/SetupChecklistModel.swift` treat an already provisioned model, granted microphone and detected keyboard as done after a reinstall, so no step is asked for again unless iOS reset it.
- [ ] T080 [US5] Run quickstart §9 three times, plus once after letting the profile expire, and record the counts in `specs/016-ios-dictation-foundation/acceptance/reinstall.md` (SC-006).

**Checkpoint**: three reinstall cycles lose nothing.

---

## Phase 10: Polish, acceptance and resource report

- [ ] T081 [P] Create `apps/ios/App/Features/Settings/DiagnosticsView.swift` (visible when `diagnostics.enabled` is true, toggled in Settings): the app's current `phys_footprint`, the coordinator snapshot (`loaded`, `leased`, `state`) and the keep-ready holders, the keyboard's last `peak_footprint_bytes` from `keyboard-status.json`, and timestamps for the last stop → result → delivery. In Debug builds only, add a "Transcribe fixture" action that runs `PhoneDictationPipeline` on audio files copied into the app's Documents through Xcode file sharing and writes the text next to them.
- [ ] T082 [P] Add a Mac-side fixture transcription command for SC-003 at `scripts/transcribe-dictation-fixtures.sh`: it fetches the fixtures from `fixtures/audio/manifest.json` with `scripts/download-speech-fixtures.py` and transcribes them through the Mac production dictation path, writing one text file per fixture. Document the command in quickstart §8.
- [ ] T083 Run quickstart §6 on the device (every robustness case plus 50 keyboard dictations across Messages, Notes, Safari, Mail and WhatsApp) and record each case's outcome (inserted, offered or saved) and the keyboard peak in `specs/016-ios-dictation-foundation/acceptance/robustness.md` (SC-004, SC-010).
- [ ] T084 Run quickstart §8 and record per-fixture diffs and explanations in `specs/016-ios-dictation-foundation/acceptance/parity.md` (SC-003). The fixture set includes `sk-01…10`, `en-01…10` and `mixed-01…10`; report each group separately so FR-018 (English and Slovak without choosing a language) is checked explicitly.
- [ ] T085 Measure quickstart §10 with Instruments and the diagnostics screen, and write `docs/performance/ios-dictation.md` with hardware, iOS version, build SHA and model revision: footprint idle, in a ready session, while recording, with the model loaded; cold and warm model load; transcription time for 15 s and 60 s; keyboard peak; and footprint after the model is released. Only measured numbers.
- [ ] T086 [P] Update `docs/architecture/overview.md`, `docs/architecture/storage.md` and `docs/architecture/model-lifecycle.md` for the package, the phone database with `phone-dictations-v1`, and the phone’s per-dictation lease and keep-ready rules.
- [ ] T087 [P] Add `docs/licenses/parakeet-ctc-110m-model-card.md` for the CTC 110M boost model, and extend the scope of `THIRD_PARTY_NOTICES.md` to the iOS app (Figtree, EB Garamond, GRDB, FluidAudio, Parakeet v3).
- [ ] T088 Run `make check` and `make ios` and confirm the Mac test count is still at least the baseline in `acceptance/mac-baseline.md`.

---

## Dependencies and execution order

### Phases

- **Phase 1 (spike)**: none. Blocks everything; a failed spike changes the plan before anything else.
- **Phase 2 (ADR)**: after Phase 1.
- **Phase 3 (US6)**: after Phase 2. Merged before Phase 4.
- **Phase 4 (phone foundation)**: after Phase 3. Blocks US1–US5.
- **US1 (Phase 5)** and **US3 (Phase 7)**: after Phase 4, independent of each other.
- **US2 (Phase 6)**: after Phase 4. T064 edits `KeyboardView.swift` from T058, and T065 edits `SessionController.swift` and `SessionView.swift` from T050 and T053, so do US2 after US1 or coordinate those three files.
- **US4 (Phase 8)**: after Phase 4. Its device check (T077) needs some dictation path, US1 or US3.
- **US5 (Phase 9)**: after US2 (T079 edits the setup model).
- **Phase 10**: after the stories it measures. T081 comes before T083–T085.

### Within phases

- T008 before T010–T013: the pinning tests must pass before the move and after.
- T010 → T011 → T012 → T013 → T015 are sequential (same project file and moving closure). T014, T016 and T017 can run beside them.
- T020 → T030, then T021–T029.
- Handoff T026–T028 in parallel, then T029.
- T032 → T033 → T034 → T035; T036 → T037 → T038; T039 → T040; T041 → T042 → T043 → T044.
- Tests written in each story phase come before the implementation and fail first.
- `SettingsView.swift` is edited by T045, T054, T066 and T081 in turn, never in parallel.

## Parallel examples

```text
# Phase 4, once T020 lands:
T021 SottoTokens.swift   T022 SottoFonts.swift   T023 CapsuleView/WaveformViews
T024 check-sotto-tokens.py   T025 check-keyboard-imports.sh
T026 HandoffModels.swift   T027 HandoffStore.swift   T028 Doorbell.swift

# US1 tests together:
T046 SessionControllerTests   T047 InsertionPolicyTests   T048 HandoffServerTests   T089 KeyboardSessionModelTests

# After Phase 4, two people:
A: US1 (T046–T059, T089)   B: US3 (T068–T073), then US4 (T074–T077)
```

## Implementation strategy

**MVP**: Phases 1–5. The spike, the verified Mac extraction, the phone foundation and US1 give keyboard dictation on the device. Provision the model for the MVP from the foundation's `PhoneModelState` with a temporary Download button in Settings; US2 replaces that with the setup flow.

Then deliver in order:

1. US2 (setup and offline)
2. US3 (notes and History)
3. US4 (Dictionary)
4. US5 (reinstall)
5. Phase 10 acceptance and the resource report

Stop at each checkpoint and record the device run before moving on. Resource acceptance (T085) is part of feature acceptance, so the feature is not done without it.

## LocalFlow required task coverage

- **Lifecycle and cancellation**: T046 (session transitions, interruption, memory warning), T089 (keyboard session view, ping timeout, stalled request), T068 (keep-ready cooldown), T044 (spool cleanup on cancel and failure).
- **Bounded pipeline overload**: T044 (ring overflow, 19.2 MB limit), T046 (busy, newest request wins, stale requests), T048 (single result file, 10-minute cleanup), T029 (fixed-size level file).
- **Offline and recovery**: T043/T044 (orphan spool), T038 (resumable download, damaged model), T067 (Airplane Mode), T080 (reinstall), T083 (interruptions).
- **Local instrumentation**: signposts in T042 and T051, diagnostics in T081, keyboard peak in T057.
- **Repeatable resource acceptance**: T085, following quickstart §10. None of T059, T067, T077, T080 or T083–T085 is marked done from simulator runs or mocks.

## Implementation report: MVP (Phases 1–5), 2026-10-01

**Changed**

- The Mac extraction into `packages/LocalFlowCore` is done and verified (commits c24b788 and 14e289f; details in `acceptance/extraction.md`).
- The package gained three API changes for the phone:
  - a `TranscriptionStore.commit(reservation:envelope:alsoWrite:)` overload (the two-argument form forwards to it);
  - a public `HistoryMigrations`;
  - a public `ProvisioningProgress.advance`.
- The phone foundation: `apps/ios/LocalFlowPhone.xcodeproj` with the app, keyboard and tests targets, `apps/ios/Config` xcconfigs, and the shared Handoff, Sotto and KeyboardLogic sources.
- US1:
  - app side: session controller, audio capture, handoff server, pipeline, orphan spool recovery and phone storage;
  - keyboard: capsule, chips, Undo, and a DEBUG ping readout used for the T004 round-trip measurement.
- Model provisioning is temporary: until US2 exists, Settings has a "Download speech model" button.
- The spike (T003) was folded into the real targets instead of a throwaway `Spike/` folder, so T005 has nothing to delete. It stays open until T004 is recorded.
- New checks run in `make check`:
  - `scripts/check-sotto-tokens.py` (phone and Mac token hex values match);
  - `scripts/check-keyboard-imports.sh` (the keyboard links neither package product);
  - iOS simulator tests.

**Verified**

- `make check` exits 0.
- Mac XCTest: 1700 passed, 30 skipped, 0 failed.
- iOS simulator XCTest: 59 passed, 0 failed.
- Both new check scripts fail when a violation is planted.

**Left**

- T004: the spike run on the iPhone 16 Pro (quickstart §2), then ADR 0029 → Accepted, then T005.
- T019: the manual Mac pass (quickstart §3).
- T059: keyboard acceptance on the device (quickstart §5).
- Device builds need `LOCALFLOW_BUNDLE_PREFIX` and `DEVELOPMENT_TEAM` in `apps/ios/Config/Signing.local.xcconfig` (gitignored). This has not been set yet.
- No device measurements have been collected.
