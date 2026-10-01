# Research: iOS dictation foundation

Findings from reading the Mac code (2026-09-30) and from public sources on iOS 26 keyboard and audio behaviour. Confidence is noted where the source is thin. Items marked **verify on device** are checked by the signing and handoff spike, which is the first implementation task, before anything else is built.

## R1. Shape of the shared code

**Decision**: One local Swift package at `packages/LocalFlowCore` with two library targets:

- `LocalFlowSpeech`: the file set the `flowd-speech` worker already compiles (`SpeechBoundaries`, `ModelWorkloadBoundaries`, `FluidAudioEngine`, `VocabularyBoost`, `MeetingLanguage`, `ModelLifecycleCoordinator`, `ModelDescriptor`, `ModelProvisioner`, `DictionaryChange`) plus the pure transcript code the dictation path needs (`TranscriptNormalizer`, `ChunkPlanner`, `TranscriptAssembler`, `TranscriptionProvenance`, `WindowedTranscriber`, `AudioSpool`). Depends on FluidAudio only.
- `LocalFlowCore`: storage and Dictionary (`TranscriptionStore`, `TranscriptionEntry`, `HistoryMigrations`, `VocabularyStore`, `DictionaryUsageStore`, `TermSuggestionStore`, the rest of `Core/Corrections` that these need) and the pure value types they reference. Depends on `LocalFlowSpeech` and GRDB.

The Mac app links both. `flowd-speech` links only `LocalFlowSpeech`, which keeps today's rule that the worker has no GRDB, SwiftUI or AppKit. The iOS app links both. The keyboard extension links neither.

Files move with `git mv`; nothing is rewritten beyond `public` modifiers and the three seams in R2. The moved set is the smallest closure of AppKit-free files the iOS dictation path needs. Meeting runtimes, diarization, identification, intelligence, rewrite transport, remote transport, context reading and insertion stay in the Mac app.

**Rationale**: The owner asked for a package. The worker file set is already enforced AppKit-free by `scripts/check-speech-worker-imports.sh`, so it is a tested seam, not a guess. Two targets instead of one keep the worker's GRDB ban without adding a third package. ADR 0001 says to extract packages "only when a real boundary appears"; a second platform is that boundary, and ADR 0029 records it.

**Cost accepted**: about 100–150 declarations need `public`. Mac test files that use moved types add `@testable import LocalFlowSpeech` or `@testable import LocalFlowCore`. Xcode builds local package targets with testability in Debug, so internal members stay reachable from tests (**verify** in the extraction task; if `@testable` fails for package modules, the fallback is `public` on the members tests use, never weakening a test).

**Alternatives considered**:

- *Compile the same source files into the iOS target by file reference*, as `flowd-speech` does today. No `public` pass and zero Mac churn, but "exists once" would then depend on two projects listing the same paths, and nothing stops an iOS-only edit breaking the Mac. Rejected because the owner asked for a package and a package gives the iOS build a compile-time boundary.
- *One package target*: would force GRDB onto the worker. Rejected.
- *Split storage into a dictation-only schema for the phone*: see R5.

## R2. Seams the move needs

The move is mechanical except for three places where Mac-only APIs leak into otherwise portable code:

| Seam | Today | Change |
| --- | --- | --- |
| English spell check for V002 boost and term suggestions | `VocabularyBoostSpelling.swift` uses `NSSpellChecker` (AppKit); worker uses `dlopen` in `WorkerSpelling.swift` | Already a closure (`isEnglishWord: (String) -> Bool`) at the policy boundary. The Mac and worker keep their implementations. iOS supplies a `UITextChecker` implementation. |
| File locations | `App/AppIdentity.swift` builds paths from `homeDirectoryForCurrentUser` (not on iOS) | New `LocalFlowPaths` value in `LocalFlowCore` (database, temporary audio, pending audio, models). The Mac builds it from the same expressions as today; a test pins the Mac paths byte for byte. iOS builds it from the app container's Application Support. |
| Spool capacity | `AudioSpool.maximumBytes` is a static 16 MiB (about 262 s of 16 kHz Float32) | Becomes an init parameter defaulting to 16 MiB. The Mac passes nothing and keeps 16 MiB. iOS passes 19,200,000 bytes for FR-014's 5 minutes. |

`DictationBoundaries.swift` mixes portable protocols with Carbon/AX types. It stays in the Mac app; the iOS app gets its own small capture protocol (R7). Nothing in it is needed by the moved closure.

## R3. Mac safety (FR-002, SC-008)

**Decision**: The extraction is its own commit series, landed and verified on the Mac before any iOS code exists.

- `make check` before (baseline recorded) and after. Test count must be equal or higher; no test file deleted or assertion loosened.
- No migration added, renamed or reordered. `HistoryMigrations.migrator()` moves as is. A new test compares the migration identifier list with a frozen list of the 16 current names.
- Mac paths test (R2).
- `check-*-imports.sh` scripts updated to the new paths, and a new `scripts/check-core-imports.sh` forbids `AppKit`, `UIKit`, `SwiftUI`, `Carbon`, `ApplicationServices` and `ScreenCaptureKit` in `packages/LocalFlowCore/Sources`, and GRDB in `LocalFlowSpeech`.
- Manual Mac pass: dictation, rewrite, Dictionary boost, a short meeting.

## R4. Keyboard ↔ app channel

**Decision**: App Group container (one group, shared by app and keyboard) holding four small JSON files, with Darwin notifications as doorbells. See [contracts/keyboard-handoff.md](contracts/keyboard-handoff.md).

**Rationale**:

- Apple's capability table lists App Groups for the free tier. A 2026-09-28 report (xtool PR 284) confirms one group per app works on a free team, tested with an app and extension. No failure reports found. Confidence: high that it works, medium on limits. **Verify on device** in the spike.
- Darwin notifications (`CFNotificationCenterGetDarwinNotifyCenter`) carry only a name, so data goes in files and the notification only says "look". The backgrounded app is kept running by its audio session, so it receives them. Latency is unpublished; the spike measures keyboard tap → app callback.
- Writes are atomic (`Data.write(options: .atomic)`, which renames), so a reader never sees a half file. Each file has one writer. No SQLite in the group (R5).
- The keyboard needs Full Access to write the group container and to open the app. Without it, writes fail silently, so the keyboard checks `hasFullAccess` first (FR-009).

**Spike result (2026-10-01)**: the group works for keyboard ↔ app dictation on the device, on the paid team. No fallback.

**Fallback if the group fails on the free team**: the keyboard opens the app with a URL for every start and stop (unusable for SC-002), or keychain access groups as the data channel with Darwin doorbells. The spike decides; nothing else is built until it passes.

**Alternatives considered**: shared `UserDefaults(suiteName:)` (works but caches in each process and has no atomic multi-field write), pasteboard (visible to other apps, rejected on privacy), GRDB in the group (R5).

## R5. Phone storage

**Decision**: The phone's `history.sqlite` lives in the app's own container at `Application Support/LocalFlow/history.sqlite`, not in the App Group. Only the app opens it. It uses the same `HistoryMigrations.migrator()` as the Mac, so the phone schema equals the Mac schema (meeting tables exist and stay empty). Phone-only fields go in one table created by a phone-only migration, `phone-dictations-v1`, registered after the shared list only by the iOS app. The Mac never registers it, so the Mac database never gains it.

**Rationale**:

- iOS kills a suspended process that holds a SQLite lock in a shared container (`0xdead10cc`). Keeping the database app-private and keyboard-free removes that risk.
- One migrator means one schema, which keeps Feature 019 (sync) simple. Empty meeting tables cost a few pages. This reuses existing schema rather than adding speculative schema, so it fits principle 7.
- The `transcriptions` table already has `text`, `created_at`, `delivery_state`, `stop_reason`, `quality` and `target_bundle_id`. Only source (keyboard or app), duration and the offered/saved-only distinction are missing; they go in the phone table.
- Registering the phone migration last is safe with GRDB: applied identifiers are tracked by name, and a future shared migration registered before it still applies on the phone because GRDB runs any registered migration not yet applied. **Verify** with a test that registers a fake later shared migration before `phone-dictations-v1` on a phone database that already has it.
- File protection is `completeUntilFirstUserAuthentication`, so a dictation that finishes while the phone is locked can still be saved (edge case: locked phone).

**Alternatives considered**: a separate dictation-only schema for the phone (forks storage, breaks FR-001); adding the phone columns to the shared migrator (changes the Mac database, breaks US6 AS2).

## R6. Opening the app from the keyboard, and returning

**Decision**: The keyboard opens `localflow://session/start?request=<uuid>` by walking the responder chain to the `UIApplication` object and calling `open(_:options:completionHandler:)`. Return is manual: the app shows "Swipe right on the bottom bar, or tap ◀ in the top-left corner, to go back".

**Rationale**: `extensionContext.open` does not work for keyboards. An Apple DTS engineer has endorsed the responder-chain call; the deprecated `openURL:` logs "BUG IN CLIENT" since iOS 18. On iOS 26 it needs Full Access. DTS states no API exists to bring the host back, and iOS 26.4 made `hostBundleID` return nil, which is why Wispr Flow shows a swipe-back screen. OpenWhispr reads a private `_UIRemoteKeyboards` property to find the host; FR-010 rules that out.

The responder-chain call is not undocumented API: it calls the public `UIApplication.open` on an object the extension already has. FR-010 targets the return path, and nothing is used there.

**Consequence**: `target_bundle_id` is usually nil on the phone. FR-020 says "when iOS reports it", so nil is correct.

## R7. Audio session and background listening

**Decision**:

- `UIBackgroundModes = [audio]`. The session starts only while the app is in the foreground (the keyboard's first tap opens it).
- `AVAudioSession` category `.playAndRecord`, mode `.default`, options `[.mixWithOthers, .allowBluetoothHFP, .defaultToSpeaker]`, so music keeps playing while a session is open. **Verify** that `.mixWithOthers` keeps the app alive in the background with input running; if not, drop it and accept that other audio ducks during a session.
- One `AVAudioEngine` runs for the whole session with an input tap. Between dictations the tap drops each buffer on the audio thread without copying (FR-013). While recording, buffers are converted to 16 kHz mono Float32 and appended to the `AudioSpool` in 1,600-sample chunks through a bounded ring (capacity 1 s; overflow ends the dictation with `stop_reason = overflow`, as on the Mac).
- The engine is never stopped between dictations. Restarting input from the background fails (`CannotStartRecording`), and Apple confirms an app cannot start recording from the background.
- Session end: stop the engine, `setActive(false, options: .notifyOthersOnDeactivation)`, drop the session's keep-ready hold and unload the model. The orange indicator then goes away (SC-009).
- Interruption began (call, Siri): if recording, close the spool and transcribe what was captured under `beginBackgroundTask`; then end the session with reason `interrupted`. No automatic resume, because resuming input from the background is not allowed.

**Spike result (2026-10-01)**: dictation works with these options. The background, orange indicator and music checks were not run; they move to T059.

**Alternatives considered**: stopping the engine between dictations (cannot restart from background), a pre-roll ring buffer to avoid clipping the first word (conflicts with FR-013). If the spike shows the first word clipped because of doorbell latency, the fix is to start the keyboard's recording state only after the app confirms, not to keep audio.

## R8. Model provisioning on the phone

**Decision**: Same pinned models as the Mac: Parakeet TDT v3 at revision `7dd20fe…` and the CTC 110M boost model, through FluidAudio **0.15.7** (the version the Mac pins), described by the same `Resources/Models/*.json` descriptors and verified by the shared `ModelProvisioner` (SHA-256, sizes, manifest, promote). Only the transport differs:

- iOS gets `ResumableModelDownloadTransport`, which conforms to the provisioner's transport protocol and uses a background `URLSession` per file, keeps resume data on interruption, and resumes on the next attempt. The provisioner never promotes a partial staging directory, so a partial download is never used (US2 AS2).
- Before starting, the app checks `volumeAvailableCapacityForImportantUsage` against the descriptors' total size plus 10% and says how much space is needed.
- Models live in `Application Support/LocalFlow/Models/<name>` in the app container, marked `isExcludedFromBackup`. Reinstalling over the same bundle ID keeps them (R10).
- At launch the app re-reads the manifest and fingerprints (not a full hash) and offers a new download if they fail, without touching the database.

**Rationale**: Same SDK and model revision give the best chance of SC-003 (identical text). FluidAudio 0.15.7 supports iOS 17+. Newer FluidAudio builds (0.17.x, Parakeet Ultra/Redux) are out of scope; upgrading would change the Mac too.

**Measured elsewhere**: FluidAudio reports a cold v3 encoder compile of 3.4 s and warm of 162 ms on an iPhone 16 Pro Max, and about 66 MB peak for the TDT encoder (130 MB with the CTC encoder) on an iPhone 17 Pro. These are not our measurements; the phone numbers are collected by the measurement task and written to `docs/performance/ios-dictation.md`.

## R9. Model lifecycle on the phone

**Decision**: The shared `ModelLifecycleCoordinator` owns the runtime on the phone too. A lease covers one dictation: `acquire(session:boost:)` binds that dictation's Dictionary terms, and any other acquire is `busy` while it is held, so a session-long lease would freeze Dictionary edits (US4 AS3) and block the next dictation. Residency is kept separately: a listening session and the visible Dictate screen are holders of a phone-side keep-ready count that drives the coordinator's `setKeepLoaded` and `loadIfIdle`, so the first dictation pays only the warm path (SC-001). Session end calls `unloadIfIdle()`; leaving the Dictate screen lets the Mac's 30 s cooldown release the model. `UIApplication.didReceiveMemoryWarningNotification` drops the holds and unloads when not recording; the next dictation reloads. Diarization and embeddings are never requested on the phone.

## R10. Reinstall and expiry

**Decision**: Bundle IDs are fixed once in `apps/ios/Config/Signing.local.xcconfig` (gitignored, created from a checked-in `.example`): `$(LOCALFLOW_BUNDLE_PREFIX).LocalFlow`, `$(LOCALFLOW_BUNDLE_PREFIX).LocalFlow.Keyboard`, group `group.$(LOCALFLOW_BUNDLE_PREFIX).LocalFlow`. That is two App IDs and one group, well under the free limits (10 App IDs per 7 days, 3 apps per device).

Reinstalling from Xcode with the same team and bundle ID keeps both the app container and the group container. After the 7-day expiry the app will not launch but its data stays until the app is deleted. Changing team or bundle ID creates a new container, which is why the IDs are pinned and documented. Confidence: medium-high (general iOS behaviour, Apple forum 69248). SC-006 checks it over three cycles.

**Update (2026-10-01)**: signing moved to a paid team (`944A459UC3`). The free team still owns the `com.oliverbrunovsky` identifiers and its App Group, and Apple refuses a group already registered by another team, so the prefix is now `com.brunovsky`. The 7-day expiry and the free-team App ID limits no longer apply; SC-006 still checks that reinstalls keep both containers.

## R11. Keyboard memory and UI

**Decision**: The keyboard is a `UIInputViewController` hosting a SwiftUI view, with a hard budget of **40 MB `phys_footprint` peak**. The limit reported for iOS 26 is about 60 MB (medium confidence; older figures 30–50 MB). Rules:

- No FluidAudio, GRDB, `LocalFlowCore` or `LocalFlowSpeech` linked.
- Fonts are registered from the bundle (memory-mapped); no images beyond SF Symbols.
- The waveform reads a 128-byte level file (R4) with `CADisplayLink` only while recording.
- One hosting controller for the extension's lifetime, torn down in `viewDidDisappear` to avoid the ~3 MB per show/hide growth reported for retained views.
- The keyboard writes its own peak footprint into a diagnostics file on each dismissal, so SC-004 can be read from the app after 50 dictations.

If the spike measures SwiftUI above 30 MB at rest, the keyboard switches to UIKit before feature work. No numbers are claimed until measured.

**Spike result (2026-10-01)**: the footprint was not measured. The keyboard stays SwiftUI; T059 measures it (SC-004) and applies the 30 MB rule.

**Measured (2026-10-01, T059)**: keyboard peak 9.9 MB, last report 8.9 MB, with the SwiftUI keyboard at rest (`acceptance/keyboard.md`). Under 30 MB, so the keyboard stays SwiftUI. SC-004 (50 dictations) is still to run.

## R12. Insertion rules in the keyboard (FR-006, FR-007)

**Decision**:

- At record start the keyboard stores `textDocumentProxy.documentIdentifier` and a request ID.
- When the result arrives: insert only if the keyboard is visible, the identifier is unchanged, and the result's request ID matches. Otherwise mark it offered and show "Insert last dictation", which inserts wherever the cursor is when the owner taps it.
- Undo is available until the next text change or 10 s, whichever is first. It deletes `inserted.count` grapheme clusters with `deleteBackward()` only if `documentContextBeforeInput` ends with the inserted text; otherwise it hides Undo. Some apps return nil context (Gmail after paste has been reported); then Undo is hidden rather than guessing.
- Secure and phone-pad fields get the system keyboard; nothing to do.

## R13. Design tokens

**Decision**: The Mac palette lives in `UI/Appearance.swift` and is built from `NSColor`. The iOS app and keyboard get `apps/ios/Shared/Sotto/SottoTokens.swift` with the same hex values, radii and font names, built on `UIColor(dynamicProvider:)`. `scripts/check-sotto-tokens.py` extracts the hex literals from both files and fails `make check` if they differ. Figtree and EB Garamond are bundled from `apps/macos/LocalFlow/Resources/Fonts` (OFL, already in `THIRD_PARTY_NOTICES.md`). The capsule and waveform are reimplemented in SwiftUI for iOS following `Features/Dictation/DictationIndicator.swift`; that file imports only SwiftUI but depends on Mac feature types, so it is not moved.

**Alternative considered**: a third package target for tokens that the keyboard links. Rejected: a whole target for one file, and moving the Mac palette risks visible change for FR-002.

## R14. Project generation

**Decision**: `apps/ios/LocalFlowPhone.xcodeproj` is created once in Xcode and then maintained like the Mac project. `scripts/register-xcode-sources.py` gets a `--project` argument and the iOS phase IDs. No XcodeGen or Tuist, which would be a new tool dependency for one project.

**Outcome (implementation, 2026-10-01)**: the project was generated once with the XcodeGen already installed on the development Mac, and only the resulting `.xcodeproj` is committed. There is no spec file, and no script or `make` target calls XcodeGen, so it is not a dependency; the project is maintained in Xcode from here on. The project uses Xcode's synchronized folders (`App`, `Keyboard`, `Shared`, `LocalFlowPhoneTests`), so a new source file needs no registration and `register-xcode-sources.py` did not get a `--project` flag (T030). Info.plists and entitlements live in `apps/ios/Config/`, outside the synchronized folders.

## R15. Tests and checks

**Decision**:

- `swift test --package-path packages/LocalFlowCore` runs `LocalFlowCoreTests` on macOS. These cover only new portable code (paths, spool capacity parameter, phone migration ordering). Existing Mac tests stay where they are.
- `LocalFlowPhoneTests` (unit tests on an iOS simulator) cover the handoff codec and state machine, the session controller with a fake audio source and test clock, idle timeout, insertion decision and Undo rules, provisioning with a fake transport, orphaned spool recovery, and the phone migration.
- `make check` adds: `check-core-imports.sh`, `check-sotto-tokens.py`, a keyboard import check (no `URLSession`, `Network`, FluidAudio, GRDB, `LocalFlowCore` in `apps/ios/Keyboard`), `swift test` for the package, and `xcodebuild build test` for the iOS scheme on a simulator with `CODE_SIGNING_ALLOWED=NO`, scoped with `-only-testing:LocalFlowPhoneTests`.
- Device acceptance (SC-001…SC-010) is manual and recorded in `specs/016-ios-dictation-foundation/acceptance/`. No hardware numbers are claimed without a run.

## R16. English and Slovak

**Decision**: Nothing new. Parakeet v3 is multilingual and the Mac does not ask for a language during dictation; the phone uses the same `WindowedTranscriber` path. `UITextChecker` is used only for the V002 "all words are English" check, the same role `NSSpellChecker` plays on the Mac. Differences in its word list may change a few boost decisions; SC-003 records any per-fixture difference.
