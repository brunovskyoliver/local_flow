# Implementation plan: iOS dictation foundation

**Branch**: `016-ios-dictation-foundation` | **Date**: 2026-09-30 | **Spec**: [spec.md](spec.md)

## Summary

This feature moves the Mac's portable speech, transcript, Dictionary and storage code into a local Swift package, `packages/LocalFlowCore`, which has two targets:

- `LocalFlowSpeech`: no GRDB, for the `flowd-speech` worker.
- `LocalFlowCore`: storage and Dictionary.

The Mac behaves exactly as before ([package contract](contracts/localflowcore-package.md)).

On top of the package it builds an iPhone app, `apps/ios`, made of two parts:

- **The containing app.** It runs Parakeet v3 and the CTC boost model through the same pinned FluidAudio build as the Mac, and keeps History and the Dictionary in its own `history.sqlite` (the shared schema plus one phone-only table). It also holds a background audio session that the keyboard drives.
- **A keyboard extension.** It links neither package target. It starts and stops dictations through a few JSON files in the App Group, with Darwin notifications as doorbells ([handoff contract](contracts/keyboard-handoff.md)). It inserts text only into the field it started in.

The first tap opens the app through the responder chain. The owner returns to the host app by hand.

Work runs in this order:

1. Free-team signing and handoff spike.
2. Mac extraction, landed and verified on its own.
3. The phone app and keyboard.
4. Device acceptance and the resource report.

## Technical context

| Item | Decision |
| --- | --- |
| Language | Swift 6.0 (language mode 6), same as the Mac |
| Targets | Mac app and `flowd-speech` (macOS 14 build setting, unchanged); `LocalFlowPhone` app and `LocalFlowKeyboard` extension, iOS 26.0, iPhone only |
| Dependencies | GRDB 7.10.0 and FluidAudio 0.15.7 (existing pins, now declared by the package). No new third-party dependency |
| Apple frameworks (iOS) | SwiftUI, UIKit (keyboard controller, `UITextChecker`), AVFAudio, CoreML (via FluidAudio), Foundation `URLSession` (background downloads), os (logging, signposts) |
| Storage | App container `Application Support/LocalFlow/history.sqlite`: shared migrator plus the phone-only `phone-dictations-v1` ([data-model.md](data-model.md)). Models are in `Application Support/LocalFlow/Models`. Handoff files are in the App Group |
| Testing | Existing Mac XCTest suite, which stays in place. `swift test` for `LocalFlowCoreTests`. `LocalFlowPhoneTests` on an iOS simulator. Manual device acceptance per [quickstart.md](quickstart.md) |
| Performance goals | SC-001: text within 1.5 s of stop for 15 s of audio, 9 of 10 runs. The session ends within 10 s of the idle deadline |
| Constraints | Free team: 7-day expiry, 2 App IDs used of 10 per 7 days, 3 apps per device, no increased-memory entitlement, one App Group. Keyboard budget 40 MB `phys_footprint` peak (reported limit about 60 MB). Offline after provisioning. No private API to return to the host |
| Scale | One device, one user. One dictation at a time, at most 5 minutes. History and Dictionary limits as on the Mac |
| Unknowns | None left open. Items that depend on the device are verified by the spike, and the fallbacks are listed in [research.md](research.md) R4, R7 and R11 |

## Constitution check

Gate before Phase 0: **pass, with one ADR required** (ADR 0029). The constitution permits an iOS client: principle 1 requires Swift, SwiftUI and Apple frameworks, and uses "AppKit where needed" as an allowance, not a platform limit. ADR 0001, though, describes one macOS app and warns against early packages. That decision is being changed, so it needs an ADR, not an exception.

| Principle | Result |
| --- | --- |
| 1 Native lightweight client | Pass. Swift, SwiftUI and UIKit only. No web views, client LLMs or runtimes |
| 2 Memory efficiency | Pass. Every queue has a bound (table below). Models are lazy, kept ready only while a session or the Dictate screen needs them, and released at session end or on a memory warning. The Mac targets (150 MB idle, 100 MB recording) are Mac targets; phone numbers are measured and recorded, not assigned |
| 3 Explicit model lifecycle | Pass. The shared `ModelLifecycleCoordinator` is the only owner on the phone. Each dictation holds one lease; the session and the Dictate screen only keep the model ready. No feature touches FluidAudio managers. Diarization and embeddings are never requested |
| 4 Local-first | Pass. No network after provisioning. No remote mode on the phone in this feature |
| 5 Privacy by architecture | Pass. Audio stays in a private spool and is deleted after use. Transcript text crosses to the keyboard only through `result.json` in the App Group, with file protection, and is deleted after acknowledgement. The keyboard has no network code (enforced by `make check` over `apps/ios/Keyboard` and `apps/ios/Shared`). Logs carry IDs, states and durations only. Full Access is explained in setup |
| 6 Streaming over accumulation | Pass. Capture streams into a bounded spool of 19.2 MB (5 min). The spool is cleaned after completion, cancellation and failure, and recovered or deleted at launch |
| 7 Simple persistence | Pass. GRDB with explicit migrations. The shared schema is reused unchanged, and the phone adds only `phone_dictations`, which this feature needs. No media in the database |
| 8 Server isolation | Not affected |
| 9 Recoverability | Pass. WAL with `synchronous=FULL`. An orphaned spool after the app is killed is transcribed on next launch and marked for review. Handoff writes are atomic |
| 10 Speaker attribution | Not affected |
| 11 Structured LLM output | Not affected (no LLM) |
| 12 Testability | Pass. Pure handoff codec and state machine, insertion decision table, session controller behind a capture protocol with a fake and a test clock, provisioner with a fake transport |
| 13 Local observability | Pass. `os_signpost` around model load, transcription and handoff round trip. A Debug diagnostics screen reads the app's `phys_footprint` and the keyboard's reported peak. The report goes to `docs/performance/ios-dictation.md` with hardware, build and model |
| 14 Scope discipline | Pass. One package, not a platform. No XcodeGen or Tuist. No new dependency. Rewriting, Action Button, sync and meetings are left out. The package is split into two targets only to keep the worker's existing GRDB ban |
| 15 Authenticated server access | Not affected |

Re-check after Phase 1 design: **unchanged, pass.** The design adds no exception beyond ADR 0029.

## Project structure

### Documentation

```text
specs/016-ios-dictation-foundation/
├── spec.md, plan.md, research.md, data-model.md, quickstart.md
├── contracts/keyboard-handoff.md
├── contracts/localflowcore-package.md
├── checklists/requirements.md
└── acceptance/            device runs (created during acceptance)
docs/adr/0029-ios-companion-and-shared-core.md     new
docs/architecture/overview.md, storage.md, model-lifecycle.md   updated for the package and phone
docs/performance/ios-dictation.md                   new, measured numbers only
```

### Source

```text
packages/LocalFlowCore/
├── Package.swift
├── Sources/LocalFlowSpeech/      moved from apps/macos/LocalFlow/Core/{,Transcription,Models,Corrections,Audio}
├── Sources/LocalFlowCore/        moved from Core/Storage, Core/Corrections, plus LocalFlowPaths (new)
└── Tests/LocalFlowCoreTests/     new tests only

apps/macos/                       project references the local package; moved files removed from targets
├── LocalFlow/App/AppIdentity.swift       builds LocalFlowPaths.mac(...)
├── LocalFlow/Core/Transcription/VocabularyBoostSpelling.swift   stays (NSSpellChecker)
├── SpeechWorker/                 links LocalFlowSpeech
└── LocalFlowTests/               adds @testable imports of the package modules; no test removed

apps/ios/
├── LocalFlowPhone.xcodeproj
├── Config/Signing.local.xcconfig.example   (Signing.local.xcconfig gitignored)
├── Shared/Handoff/               codec, file store, doorbells (Foundation only; both targets)
├── Shared/Sotto/                 SottoTokens, fonts registration, capsule and waveform views
├── App/
│   ├── LocalFlowPhoneApp.swift, PhoneServices.swift         wiring
│   ├── Session/                  SessionController, PhoneAudioCapture, IdleTimer, HandoffServer
│   ├── Transcription/            PhoneDictationPipeline (WindowedTranscriber + normalizer + boost), TextCheckerSpelling
│   ├── Models/                   ResumableModelDownloadTransport, ModelSetupViewModel
│   ├── Storage/                  PhoneMigrations (phone-dictations-v1), PhoneDictationStore, OrphanSpoolRecovery
│   ├── Features/Setup/           four-step checklist
│   ├── Features/Dictate/         in-app notes
│   ├── Features/History/         list, copy, share, delete
│   ├── Features/Dictionary/      list and editor
│   ├── Features/Session/         "LocalFlow is listening" + swipe-back hint, end session
│   ├── Features/Settings/        idle timeout, model delete, diagnostics
│   └── Info.plist                UIBackgroundModes=audio, URL scheme localflow, NSMicrophoneUsageDescription
├── Keyboard/
│   ├── KeyboardViewController.swift     UIInputViewController host
│   ├── KeyboardView.swift               capsule, keys, states, Insert last dictation
│   ├── InsertionPolicy.swift            decision table and Undo rule (pure)
│   └── Info.plist                       RequestsOpenAccess=YES, PrimaryLanguage en-US
└── LocalFlowPhoneTests/

scripts/
├── check-core-imports.sh         new
├── check-sotto-tokens.py         new
├── check-keyboard-imports.sh     new
├── register-xcode-sources.py     gains --project for the iOS project
├── check-*-imports.sh            paths updated after the move
└── test.sh                       runs the new checks, swift test, iOS build and tests
Makefile                          adds `ios`
```

**Structure decision**: one package with two targets, the Mac project unchanged except for the package reference and file membership, and a new iOS project with an app and a keyboard. Code shared only by the two iOS targets (handoff, tokens) stays in `apps/ios/Shared`, compiled into both, because the keyboard must not link the package.

## Build order

1. **Spike** (blocks everything else). A minimal app and keyboard with the final bundle IDs, signed by the free team. It must show the App Group round trip, the Darwin doorbells, opening the app from the keyboard, the background audio session staying alive, and the keyboard's footprint at rest. Record the results in `acceptance/spike.md`. On failure, pick the fallback from research R4, R7 or R11 before continuing.
2. **ADR 0029.**
3. **Extraction**, in separate commits:
   1. Create the package, pin the dependencies, and add the local package reference to the Mac project.
   2. `git mv` the `LocalFlowSpeech` set and add `public`. Link it from the app and worker.
   3. `git mv` the `LocalFlowCore` set, and add `LocalFlowPaths` and the spool capacity parameter.
   4. Update the import checks and tests.
   5. Run `make check` and the manual Mac pass.

   The extraction merges before phone work starts.
4. **Phone foundation.** iOS project, signing config, Sotto tokens and fonts, `PhoneServices` wiring, storage and phone migration, model provisioning with the resumable transport.
5. **In-app dictation (US3).** Capture, pipeline, History. This proves the pipeline on the phone before the keyboard adds handoff complexity.
6. **Session and keyboard (US1, US2).** Session controller, handoff server, keyboard UI, insertion policy, setup checklist.
7. **Dictionary UI (US4)** and **reinstall checks (US5).**
8. **Acceptance and resource report.**

## Bounds and overload behaviour

| Pipeline part | Capacity | Overload policy |
| --- | --- | --- |
| Audio tap → spool ring | 1 s of 16 kHz mono | End the dictation with `overflow`; transcribe what was captured |
| Spool | 19.2 MB (5 min) | Stop at the limit with `duration_limit` and insert the text (FR-014) |
| Dictations | 1 at a time | A start while not `ready` returns `busy` |
| Handoff request, result, delivery | 1 file each | Newest wins; the result is always also in History |
| Level file | 128 bytes | Circular |
| Model download | 2 descriptors, 1 file in flight | Pause on error; resume data kept |
| Orphan spools | 1 | Recovered or deleted at launch |
| History and Dictionary | Mac store limits | Mac errors; delivery unaffected (FR-023) |

## Model ownership and release

- `ModelLifecycleCoordinator`, created once in `PhoneServices`, is the only owner. Loading is single-flight. Each dictation acquires its own lease with `acquire(session:boost:)`, carrying the Dictionary snapshot current at stop, and calls `finish` when transcription ends. No lease outlives a dictation.
- Keeping the model resident is separate from the lease. `PhoneServices.keepReady` counts holders (`session`, `dictateScreen`) and calls `setKeepLoaded(true)` plus `loadIfIdle()` when the first holder arrives.
- When the last holder leaves:
  - session end: `setKeepLoaded(false)`, then `unloadIfIdle()` (released at once)
  - Dictate screen gone: `setKeepLoaded(false)`; the coordinator's existing 30 s cooldown releases it
  - memory warning when not recording: both holders dropped, then `unloadIfIdle()`
- Release evidence: diagnostics show the coordinator snapshot (`loaded`, `leased`, `state`), and footprint drops after release. Both are recorded in the resource report.

## Privacy

- Nothing leaves the phone after the model download. The download goes to the pinned Hugging Face revisions over HTTPS and sends no user data.
- The keyboard makes no network requests (import check). Full Access is used only for the App Group and opening the app, and setup says so in plain words.
- The only text outside the app container is `result.json` in the group. It is deleted when the keyboard acknowledges it as inserted, and otherwise expires 10 minutes after creation. The app deletes an expired result at session end, at launch and on becoming active, so an unacknowledged result can outlive 10 minutes only while the app is not running.
- Logs are content-free.

## Recovery and persistence

- History is written before the result is published.
- A failed write still publishes the text (FR-023).
- An app killed while recording leaves a spool, which is recovered on next launch.
- A keyboard dismissed before the result arrives gets the text offered on its next appearance.
- Reinstalling keeps both containers (research R10). Damaged model files are detected at launch and re-downloaded without touching the database.

## Dependencies and licences

- No new third-party dependency. GRDB 7.10.0 (MIT) and FluidAudio 0.15.7 (Apache-2.0) are already reviewed in `docs/licenses/`.
- Parakeet v3 (CC-BY-4.0) is recorded in `docs/licenses/parakeet-v3-model-card.md`. The CTC 110M boost model has no licence file in `docs/licenses/` yet; ADR 0027 pinned it, and this feature adds its model card before shipping it to a second platform.
- Figtree and EB Garamond (OFL 1.1, in `apps/macos/LocalFlow/Resources/Fonts` with their licence texts) are already in `THIRD_PARTY_NOTICES.md`. Bundling them in the iOS app is covered by OFL; add the iOS app to the notice's scope.

## Validation

- **Automated:**
  - `make check` (Mac suite, package tests, iOS simulator build and tests, import and token checks)
  - the frozen migration list test
  - the Mac paths test
- **Device:** [quickstart.md](quickstart.md) sections 2–10, recorded in `acceptance/`.
- **Resource acceptance:** part of feature acceptance. The phone numbers and keyboard peak go in `docs/performance/ios-dictation.md`, and nothing is reported as achieved without a measured run.

## Complexity tracking

| Item | Why needed | Simpler alternative rejected because |
| --- | --- | --- |
| Local package with two targets (ADR 0029 amends ADR 0001) | Code must exist once for macOS and iOS (FR-001), and the worker must not link GRDB | Shared file references across two projects: no compile-time boundary, and iOS edits could break the Mac silently. One target: forces GRDB onto the worker |
| Phone-only migration registered after the shared migrator | Source, duration and offered/saved-only need a home without changing the Mac database (US6 AS2) | Adding columns to the shared migrator changes the Mac database; a separate phone schema forks storage |
