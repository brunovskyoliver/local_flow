---

description: "Task list for Feature 019, input device priority"
---

# Tasks: input device priority

**Input**: design documents in `specs/019-input-device-priority/`

**Prerequisites**: [plan.md](plan.md), [spec.md](spec.md), [research.md](research.md), [data-model.md](data-model.md), [contracts/](contracts/), [quickstart.md](quickstart.md)

**Tests**: included. The plan names the test files, the capture contract lists required resolver and coordinator cases, and constitution principle 12 requires lifecycle, cancellation, bound and recovery tests. Write each story's tests first and check that they fail.

**Organization**: grouped by user story so each story can be built and checked on its own.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: can run in parallel (different files, no dependency on an unfinished task)
- **[Story]**: US1–US4 from spec.md

## Conventions for every task

- macOS app paths are under `apps/macos/`. Shared history code is under `packages/LocalFlowCore/Sources/LocalFlowCore/`.
- The Xcode project does not pick up new files by itself. Register every new Swift file with `scripts/register-xcode-sources.py <path relative to apps/macos>`; files under `LocalFlowTests/` go to the test target automatically.
- Run tests scoped with `-only-testing` (quickstart §1). The full suite beeps.
- Hardware acceptance is recorded only from real device runs in `specs/019-input-device-priority/acceptance/`, never from fakes or a build that only compiles.

---

## Phase 1: Setup and hardware spike

**Purpose**: confirm the six hardware facts (research S1–S6) before writing capture code that depends on them.

- [X] T001 Create `specs/019-input-device-priority/acceptance/` with a `README.md` stating that each run records date, Mac model, macOS build, iPhone model and iOS build, and LocalFlow build (quickstart preamble)
- [X] T002 Write `apps/macos/LocalFlowTests/InputDeviceProbeHarness.swift`: an XCTest case that returns at once unless `LOCALFLOW_INPUT_PROBE=1`. When enabled it lists every Core Audio device with an input stream (UID, model UID, name, transport type as a four-char code, alive flag, `AppleClamshellState` from `IOPMrootDomain`), then for each input binds a fresh `AVAudioEngine` input node through `kAudioOutputUnitProperty_CurrentDevice` (global scope, element 0) before `prepare()`, records for 5 s and prints the input format, time to first buffer, time to first buffer with a non-zero sample, and per-buffer delivery delay (host time at callback minus `AVAudioTime.hostTime`, plus buffer duration). It prints timings and metadata only, never audio. Register it with `scripts/register-xcode-sources.py`
- [ ] T003 Run the spike from quickstart §2 on the target Mac (S1 iPhone transport type, S2 binding records from the chosen device while the default is another, S3 clamshell visibility, S4 cold and warm iPhone first-buffer behaviour 5× each, S5 whether `AVAudioEngineConfigurationChange` fires on a pinned engine when only the default changes, S6 iPhone format). Save the output as `specs/019-input-device-priority/acceptance/spike-<date>.md`
- [ ] T004 Record the fallback each spike result calls for at the end of `specs/019-input-device-priority/acceptance/spike-<date>.md`: S1 Continuity marker match or none, S2 explicit audio-unit creation or none, S3 IOKit clamshell read or none, S4 zero-buffer rule confirmed, S5 same-device restart needed or not, S6 meeting fallback limit for the help text. If S2 fails with its fallback too, stop here and return to the owner (plan build order step 1)

**Checkpoint**: spike recorded and fallbacks chosen. Capture work can start.

---

## Phase 2: Foundational (blocking prerequisites)

**Purpose**: device model, catalog, store, resolver, capture binding, migration and wiring that every story uses. No user-visible change yet: with only `[systemDefault]` stored, dictation runs today's path.

**⚠️ No user story work starts until this phase is done.**

### Tests for the foundation (write first, check they fail)

- [X] T005 [P] Write `apps/macos/LocalFlowTests/InputDeviceResolverTests.swift` with the contract's required resolver cases: ranked USB available → first candidate is USB even when the default is another device; USB missing → MacBook mic first and the USB entry unchanged; clamshell flag set → built-in skipped; only System default available → one candidate with nil device ID; nothing available → empty; UID changed with a unique name/kind/model match → matched and UID updated; two ambiguous matches → neither matched (M1–M3). Add cases for the availability rule "`systemDefault`: the snapshot has a default input" and "matched a `ConnectedInput` that is alive". Add capacity cases (constitution 12) for the pure snapshot builder from T010: 65 input devices → 64 kept in input order and the dropped flag set; devices without an input stream excluded before the cap; `generation` increases on each build; and for the newest-1 change buffer: three yields with no reader → the reader gets only the last. Register the file
- [X] T006 [P] Write `apps/macos/LocalFlowTests/InputDevicePriorityStoreTests.swift` using a suite-scoped `UserDefaults`: missing key, unreadable JSON and unknown version each read as `[systemDefault]` (V4, FR-016) and unreadable data is not overwritten on read; a decoded list without `systemDefault` gets it appended at the end (V1); a later duplicate `uid` is dropped on decode (V2); `add` throws `.full` at 32 entries (V3) and `.duplicate` on the same uid; `remove` of the `systemDefault` entry throws `.systemDefaultIsFixed` (V5); `move(fromOffsets:toOffset:)` persists the order; `reconcile(with:)` updates `name` and `lastSeenAt` on matched entries and saves the new `uid` after an M3 match. Also cover the timing profile store: at most 32 profiles with least-recently-used eviction, `recentConnectMs` and `recentDelayMs` keep the last 16 values. Register the file
- [X] T007 [P] Write `apps/macos/LocalFlowTests/InputDeviceMigrationTests.swift`: after `input-device-v18`, existing `transcriptions` and `meeting_segments` rows keep NULL in the new columns; inserting `input_device_name` of length 0 or 129 fails the CHECK; inserting an `input_device_kind` outside `('builtIn','usb','bluetooth','iPhone','virtual','other','systemDefault')` fails the CHECK; the same NULL and CHECK cases hold for the two new `pending_remote_dictations` columns. Register the file
- [X] T008 [P] Extend `apps/macos/LocalFlowTests/AudioCaptureTests.swift`: `start(input: .systemDefault)` keeps every existing case passing unchanged; `start(input: .device(id))` with an injected `bindInput` that throws → `deviceLost` and the spool stays at zero bytes; `stop(tail: nil)` behaves exactly like today's `stop`; `stop(tail:)` stays idempotent per session

### Implementation for the foundation

- [X] T009 [P] Create `apps/macos/LocalFlow/Core/Audio/InputDevicePriority.swift` with `InputDeviceKind` (`builtIn`, `usb`, `bluetooth`, `iPhone`, `virtual`, `other`, `systemDefault`; raw values are these strings), `RankedInputEntry` (`id: UUID`; `kind`; `uid: String?` "Nil only for `systemDefault`. 1–256 bytes"; `modelUID: String?` "≤ 256 bytes"; `name: String` "1–128 characters. 'System default' for that entry"; `lastSeenAt: Date?` "Nil for `systemDefault`"), `InputCandidate` (entry plus `AudioDeviceID?`, nil for `systemDefault`), matching rules M1–M3 as a pure function, and `InputDeviceResolver.candidates(entries:snapshot:)` returning available entries in rank order. An entry is available when it is `systemDefault` and the snapshot has a default input, or it matched an alive `ConnectedInput` and is not the built-in input while the clamshell flag is set. Map transport types per research R1 (`BuiltIn` → builtIn, `USB` → usb, `Bluetooth`/`BluetoothLE` → bluetooth, `ContinuityCaptureWired`/`ContinuityCaptureWireless` → iPhone, `Virtual`/`Aggregate` → virtual, else other), plus the S1 fallback from T004 if one was chosen. Register the file
- [X] T010 [P] Create `apps/macos/LocalFlow/Core/Audio/InputDeviceCatalog.swift` with `ConnectedInput` (`deviceID`, `uid`, `modelUID`, `name`, `kind`, `isAlive`), `InputDeviceSnapshot` (≤ 64 inputs, default input `AudioDeviceID?`, clamshell flag, `generation` increased on every rebuild), the `InputDeviceCataloging` protocol (`snapshot()` reads memory only, `changes()` is an `AsyncStream` buffering newest 1, `name(of:)`), and `CoreAudioInputCatalog`: listeners on `kAudioHardwarePropertyDevices` and `kAudioHardwarePropertyDefaultInputDevice` on a private serial queue, registered once at start and removed at quit; each event rebuilds the snapshot from devices with at least one input stream; inputs past 64 are ignored and logged once per launch. Put the bounded part in a pure `InputDeviceSnapshot.build(devices:defaultInput:clamshell:generation:)` that takes already-read device records and returns the snapshot plus a dropped flag, and put the newest-1 buffering in a small type shared with `FakeInputCatalog`, so T005 can test both without hardware. Add the IOKit `AppleClamshellState` read only if T004 chose it, read at key-down and on `NSWorkspace` screen notifications. Register the file
- [X] T011 [P] Create `apps/macos/LocalFlow/Core/Audio/InputDeviceTimings.swift` with `DeviceTimingProfile` (`uid`; `kind`; `uses` "≥ 0"; `connectTimeouts` "≥ 0"; `recentConnectMs` "Last 16 values, oldest dropped, each 0–3000"; `recentDelayMs` "Last 16 session-maximum delivery delays, each 0–2000"; `lastUsedAt`) and a store on `UserDefaults` key `inputDevices.timings.v1`, JSON, at most 32 profiles with least-recently-used eviction. Register the file
- [X] T012 Add `InputDevicePriorityStoring` and the live `UserDefaultsInputDevicePriorityStore` to `apps/macos/LocalFlow/Core/Audio/InputDevicePriority.swift`: `@MainActor`, key `inputDevices.priority.v1`, stored form `{ "version": 1, "entries": [RankedInputEntry] }`, validation V1–V5 from data-model.md, `move`, `add` (`.full` at 32, `.duplicate` on same uid), `remove` (`.systemDefaultIsFixed`), `reconcile(with:)` (M1–M3, saves only on change). Unreadable data is logged once and overwritten on the next edit, not on read (depends on T009)
- [X] T013 Add `FakeInputCatalog` (settable snapshot, manual `changes()` yield) and an in-memory `FakeInputDevicePriorityStore` to `apps/macos/LocalFlowTests/Support/BoundaryFakes.swift` (depends on T009, T010, T012)
- [X] T014 Change `AudioCapturing` in `apps/macos/LocalFlow/Core/DictationBoundaries.swift` to the contract shape: add `InputBinding` (`.systemDefault`, `.device(AudioDeviceID)`), `CaptureStarted { boundDevice }`, `start(sessionID:spool:input:) -> CaptureStarted`, `stop(sessionID:tail:)`, and `audioFlowingSince: UInt64?` and `maxDeliveryDelay: Duration` on `AudioCaptureSnapshot`. Update every conformer and call site (`DictationCoordinator.swift`, `LocalFlowTests/Support/BoundaryFakes.swift`, `UnsavedResultTests.swift`, `ResourceLifecycleTests.swift`, `DictationCoordinatorTests.swift`) so existing callers pass `.systemDefault` and `tail: nil`
- [X] T015 Implement the binding in `apps/macos/LocalFlow/Core/Audio/AudioCaptureService.swift`: for `.device(id)` set `kAudioOutputUnitProperty_CurrentDevice` on `engine.inputNode.audioUnit` (global scope, element 0) before `prepare()`, then read the input format; make the call through an injectable `bindInput: @Sendable (AVAudioEngine, AudioDeviceID) throws -> Void` init parameter whose default sets the property, so T008 can force a failure; apply the S2 fallback from T004 if needed; a failure to set the device or start the engine throws `deviceLost`. `.systemDefault` sets nothing and runs exactly today's code. Return the bound device in `CaptureStarted`. Implement `stop(tail:)` with `nil` meaning today's stop (depends on T014)
- [X] T016 [P] Append migration `input-device-v18` to `packages/LocalFlowCore/Sources/LocalFlowCore/HistoryMigrations.swift` after `one-server-v17`, in one transaction, with exactly the SQL in data-model.md: `transcriptions.input_device_name TEXT CHECK (input_device_name IS NULL OR length(input_device_name) BETWEEN 1 AND 128)`, `transcriptions.input_device_kind TEXT CHECK (input_device_kind IS NULL OR input_device_kind IN ('builtIn','usb','bluetooth','iPhone','virtual','other','systemDefault'))`, `meeting_segments.input_device_name TEXT CHECK (input_device_name IS NULL OR length(input_device_name) BETWEEN 1 AND 128)`, and the same `input_device_name` and `input_device_kind` columns and CHECKs on `pending_remote_dictations`
- [X] T017 Add `input-device-v18` as the last entry of the frozen migration list in `apps/macos/LocalFlowTests/MacCompatibilityTests.swift` (depends on T016)
- [X] T018 Add the `input-device` `Logger` category under `org.localflow.LocalFlow` in `apps/macos/LocalFlow/Core/Audio/InputDeviceCatalog.swift`, and four `ResourceRecorder` metrics in `apps/macos/LocalFlow/Core/Observability/ResourceRecorder.swift`: `inputConnectDuration`, `inputDeliveryDelay`, `inputTailDuration`, `inputFallbackCount`, each labelled with the device kind only (R11) (depends on T010, which creates the catalog file)
- [X] T019 Create one `CoreAudioInputCatalog`, one `UserDefaultsInputDevicePriorityStore` and one timing store in `apps/macos/LocalFlow/App/AppServices.swift`; start the catalog listeners at app start, stop them at quit, and run `store.reconcile(with:)` on each `changes()` snapshot. Inject catalog and store into `DictationCoordinator` (meetings are wired in US4) (depends on T010–T012)
- [X] T020 Run `InputDeviceResolverTests`, `InputDevicePriorityStoreTests`, `InputDeviceMigrationTests`, `AudioCaptureTests` and `MacCompatibilityTests` with `-only-testing`; all pass and the existing `AudioCaptureTests` cases are unchanged

**Checkpoint**: device model, store, catalog and capture binding work. Dictation still records from the macOS default.

---

## Phase 3: User Story 1 — rank my microphones and let LocalFlow pick (P1) 🎯 MVP

**Goal**: the user ranks inputs in Settings › Microphones and each dictation records from the first connected entry, falling back down the list with no user action.

**Independent test**: with two inputs connected, rank them, dictate and confirm the higher one was used. Disconnect it, dictate, confirm the second was used. Reconnect, confirm the next dictation goes back.

### Tests for User Story 1 (write first, check they fail)

- [X] T021 [P] [US1] Add coordinator cases to `apps/macos/LocalFlowTests/DictationCoordinatorTests.swift` using `FakeInputCatalog`, `FakeInputDevicePriorityStore` and the fake capture: no candidates → state goes `preparing → failed`, status "No microphone available", capture never started, no spool left behind; first candidate is `.device(id)` for a ranked USB mic while the fake default is another device; USB missing → `.device` of the MacBook mic; only System default → `start(input: .systemDefault)`; permission denied → today's permission message, never "No microphone available"; a candidate whose `start` throws is skipped at once and the next candidate starts on the same zero-byte spool
- [X] T022 [US1] Add an FR-013 regression case to `apps/macos/LocalFlowTests/DictationCoordinatorTests.swift`: device lost after audio flowed → `stopReason = .deviceLoss`, captured audio transcribed, saved and inserted; fix any `incomplete` branch in `DictationCoordinator.swift` that blocks insertion if the test finds one (R8) (same file as T021: run after it)
- [X] T023 [P] [US1] Write `apps/macos/LocalFlowTests/MicrophonesViewModelTests.swift`: rows follow store order; unavailable entries show "Not connected"; two rows with the same name get the detail "· <last 4 UID characters>"; every Bluetooth row carries the FR-014 note; the System default row shows "Currently: <name>" or "Currently: none" and has no remove action; "Add microphone" lists connected inputs not in the list and is disabled with "All connected microphones are listed" when empty and "The list is full" at 32; Move up / Move down change the order. Register the file

### Implementation for User Story 1

- [X] T024 [US1] In `apps/macos/LocalFlow/Features/Dictation/DictationCoordinator.swift`, at key-down read `catalog.snapshot()` and `store.entries`, call `InputDeviceResolver.candidates`, and start capture on the first candidate with `.device(id)` or `.systemDefault`. Empty candidates → `failed` with "No microphone available" before capture starts. A candidate whose `start` throws is skipped and the next one starts on the same spool; each entry is tried at most once per key-hold. Permission is checked before resolving, so a denied permission keeps today's message (depends on T019)
- [X] T025 [P] [US1] Create `apps/macos/LocalFlow/Features/Settings/MicrophonesViewModel.swift`: builds rows from the store and the latest catalog snapshot (name, kind label "Built-in"/"USB"/"Bluetooth"/"iPhone"/"Virtual"/"Other", duplicate-name detail, "Not connected", Bluetooth note "Uses call-quality audio and lowers playback quality while recording.", System default "Currently: <name>"), the add menu items and their disabled reasons, and move/add/remove actions that call the store. Refreshes on `catalog.changes()`. Register the file
- [X] T026 [US1] Create `apps/macos/LocalFlow/Features/Settings/MicrophonesSection.swift` per contracts/microphones-settings.md: header "Microphones", line "LocalFlow records from the first microphone on this list that is connected.", a `List` with `onMove`, dimmed unavailable rows that stay movable and removable, a remove button on every row except System default (no confirmation), the "Add microphone" menu, and accessibility text "<name>, <kind>, <rank> of <count>[, not connected]" with "Move up" and "Move down" actions. Register the file (depends on T025)
- [X] T027 [US1] Add the Microphones section after General in `apps/macos/LocalFlow/Features/Settings/SettingsView.swift`, with a scroll anchor that `MainWindowRouter` can target (depends on T026)
- [X] T028 [US1] Add a "Microphones…" button to the "No microphone available" failure in `apps/macos/LocalFlow/Features/Dictation/IndicatorPanel.swift` that opens the main window on Settings and scrolls to the Microphones section through `apps/macos/LocalFlow/App/MainWindowRouter.swift` (depends on T027)
- [X] T029 [US1] Run `DictationCoordinatorTests`, `MicrophonesViewModelTests` and `InputDeviceResolverTests` with `-only-testing`; all pass
- [ ] T030 [US1] Device run quickstart §3 (ranking, fallback, reconnect, clamshell, no microphone) on the target Mac and record it in `specs/019-input-device-priority/acceptance/us1-<date>.md`. The caption and History checks in §3 steps 2 and 4 wait for US3

**Checkpoint**: US1 works on its own. Ranking and fallback are live; an untouched list behaves as before.

---

## Phase 4: User Story 2 — dictate into my iPhone when the Mac's microphone isn't usable (P1)

**Goal**: the iPhone Microphone gets a visible connecting state, a 3 s connect limit with fallback in the same key-hold, and a release tail sized to the measured delivery delay, so first and last words survive.

**Independent test**: Mac closed, iPhone nearby and eligible, iPhone ranked first. Hold the key, wait for listening, say a sentence starting and ending with distinctive words, release right after the last one; both words appear. Repeat 20 times.

### Tests for User Story 2 (write first, check they fail)

- [X] T031 [P] [US2] Add ring and gate cases to `apps/macos/LocalFlowTests/AudioCaptureTests.swift` with synthetic ring pushes: all-zero buffers are not spooled and leave `audioFlowingSince` nil; the first buffer with a non-zero sample sets `audioFlowingSince` once and later buffers do not change it; the 180 s / 2,880,000-sample budget counts from `audioFlowingSince`; `maxDeliveryDelay` keeps the session maximum; `cancel` before audio flows leaves the spool at zero bytes; a failure latched during the tail wins over `keyRelease`; cancel never waits for a tail
- [X] T032 [P] [US2] Add the contract's connecting and tail cases to `apps/macos/LocalFlowTests/DictationCoordinatorTests.swift`: first candidate flows at once → `connecting` lasts at most one poll, then `recording`; first candidate silent for 3 s → it is cancelled and the second starts on the same spool in the same key-hold; all candidates silent → `failed` with "<last tried name> didn't respond", nothing inserted and the spool removed; the Mac sleeps during `connecting` → capture cancelled, today's sleep failure, spool removed, nothing inserted; key released during `connecting` → `cancelling → idle`, capture cancelled, nothing inserted, no error beyond the too-short handling; max delay 30 ms at release → `stop(tail: nil)`; 320 ms → `stop(tail: .milliseconds(345))`; 900 ms → `stop(tail: .milliseconds(500))`; a connect-limit fallback keeps the model lease and does not reacquire it

### Implementation for User Story 2

- [X] T033 [P] [US2] Add two producer-side atomics to `apps/macos/LocalFlow/Core/Audio/AudioCaptureRing.h` and `apps/macos/LocalFlow/Core/Audio/AudioCaptureRing.c`: first non-zero push host time (set once) and maximum delivery delay. No locks and no allocation on the producer side
- [X] T034 [US2] In `apps/macos/LocalFlow/Core/Audio/AudioCaptureService.swift`, compute per-buffer delivery delay in the tap block (host time at callback minus `AVAudioTime.hostTime`, plus buffer duration) and push it with the zero/non-zero flag to the ring; drop buffers before the first non-zero one in the normalizer instead of spooling them; start the 180 s / 2,880,000-sample budget at `audioFlowingSince`; expose both values in `AudioCaptureSnapshot`; make `stop(tail:)` keep capturing for `tail` before the existing drain (depends on T033)
- [ ] T035 [US2] Apply the S5 result from T004 in `apps/macos/LocalFlow/Core/Audio/AudioCaptureService.swift`: if a configuration change fires on a pinned engine when only the default changes, read `kAudioDevicePropertyDeviceIsAlive` for the pinned device; alive and same format → restart the engine once on the same device into the same spool; otherwise `deviceLost`. Dictations on `.systemDefault` keep today's `deviceLost` on a default change. Add a test case to `apps/macos/LocalFlowTests/AudioCaptureTests.swift` if the restart path is added (depends on T034)
- [X] T036 [US2] Add `case connecting` to `DictationSession.State` in `apps/macos/LocalFlow/Features/Dictation/DictationSession.swift` between `preparing` and `recording`, with transitions per data-model.md (connecting → recording, connecting → connecting on next candidate, connecting → cancelling, connecting → failed), and handle it in every `switch` on state, including `apps/macos/LocalFlow/Features/Dictation/ControlMailbox.swift` and accessibility text
- [X] T037 [US2] Implement the candidate loop in `apps/macos/LocalFlow/Features/Dictation/DictationCoordinator.swift`: after `start`, set state `connecting` and poll the snapshot until `audioFlowingSince` is set, then `recording`; after 3 s with no flowing audio, cancel that capture, keep the same empty spool and start the next candidate; each entry tried once per key-hold; none left → `failed` with "<name> didn't respond". Key release during `connecting` follows the existing cancel path (spool removed, lease cooled, prefetch joined). The existing sleep failure path also applies during `connecting` and removes the spool. At release compute `tail = 0 if maxDelay ≤ 50 ms, else min(maxDelay + 25 ms, 500 ms)` and call `stop(tail:)`, passing nil for 0. A fallback restarts only capture, never the model lease (depends on T034, T036)
- [X] T038 [US2] Record per dictation in the timing store (`uses`, `connectTimeouts`, connect ms clamped 0–3000, session-max delay ms clamped 0–2000, `lastUsedAt`), emit the `ResourceRecorder` input metrics, and log one line at stop in category `input-device`: `input kind=<kind> rank=<n> fallbacks=<n> connect_ms=<n> delay_max_ms=<n> tail_ms=<n> name=<private>` with the name as `privacy: .private`, in `apps/macos/LocalFlow/Features/Dictation/DictationCoordinator.swift` (depends on T011, T018, T037)
- [X] T039 [US2] Show the connecting pill in `apps/macos/LocalFlow/Features/Dictation/DictationIndicator.swift`: low bars with a slow pulse during `connecting`, today's waveform from `recording`; the listening state never shows before audio flows (FR-008)
- [X] T040 [US2] Add a "Microphones…" button to the "<name> didn't respond" failure in `apps/macos/LocalFlow/Features/Dictation/IndicatorPanel.swift`, reusing the T028 route
- [X] T041 [US2] Add the iPhone help line to `apps/macos/LocalFlow/Features/Settings/MicrophonesSection.swift`: "To use your iPhone, sign in to the same Apple Account on both devices, turn on Continuity Camera on the iPhone, and keep it nearby, locked and in landscape." with an "Apple's requirements ›" link that opens Apple's Continuity Camera support page in the browser. Append the S6 meeting format limit from T004 if the spike found one
- [X] T042 [US2] Run `AudioCaptureTests` and `DictationCoordinatorTests` with `-only-testing`; all pass
- [ ] T043 [US2] Device run quickstart §4 (20 Alpha/Omega dictations for SC-003, 10 ineligible-iPhone dictations for SC-004, release during connecting) and record it in `specs/019-input-device-priority/acceptance/us2-<date>.md`. The checks that the indicator names the device used and shows the switch (spec US2 scenarios 4 and 5) wait for the US3 caption and are run in T053
- [ ] T044 [US2] Export at least 5 cold and 5 warm iPhone connect times and delivery delays (SC-005) into `specs/019-input-device-priority/acceptance/iphone-timing-<date>.md` with hardware and OS versions. If delay p95 is above 450 ms or connect p95 above 2.5 s, raise it with the owner before acceptance

**Checkpoint**: US1 and US2 work. The iPhone path connects, falls back and keeps first and last words.

---

## Phase 5: User Story 3 — see which microphone is listening (P2)

**Goal**: the indicator names the device in use, a fallback says so once per change in the available set, and History records the device per dictation.

**Independent test**: dictate once on each of two ranked devices; the caption and History name the right device each time. Remove the first device and dictate twice; the fallback notice appears once.

### Tests for User Story 3 (write first, check they fail)

- [X] T045 [P] [US3] Add the contract's notice and record cases to `apps/macos/LocalFlowTests/DictationCoordinatorTests.swift`: fallback twice with the same available set → notice shown once; fallback after the available set changed → shown again; the saved history row has the used device's name and kind; a System default dictation stores the name of the device the engine bound (from `CaptureStarted.boundDevice` through `catalog.name(of:)`) with kind `systemDefault`
- [X] T046 [P] [US3] Add cases to `apps/macos/LocalFlowTests/InputDeviceMigrationTests.swift` for `TranscriptionStore`: an entry saved with `inputDevice` reads back with the same name and kind; a pre-migration row reads `inputDevice == nil`; a pending remote dictation (Feature 014) queued with a device, read back after reopening the database, keeps the device fields through `PendingRemoteRetrier` into the final row; a pending row queued before the migration completes with `inputDevice == nil`

### Implementation for User Story 3

- [X] T047 [P] [US3] Add `inputDevice: (name: String, kind: InputDeviceKind)?` (or an equivalent `Sendable` struct) to `packages/LocalFlowCore/Sources/LocalFlowCore/TranscriptionEntry.swift`. `InputDeviceKind` raw values must match the CHECK list; if the enum lives in the app target, mirror the raw string in LocalFlowCore and convert at the boundary
- [X] T048 [US3] Read and write `transcriptions.input_device_name` and `transcriptions.input_device_kind` in `packages/LocalFlowCore/Sources/LocalFlowCore/TranscriptionStore.swift`, (depends on T016, T047)
- [X] T048a [US3] Add the device name and kind to `enqueue` and `Item` in `apps/macos/LocalFlow/Core/Storage/PendingRemoteDictationStore.swift` (write and read `pending_remote_dictations.input_device_name` and `input_device_kind`), pass them from `DictationCoordinator.swift` when a dictation is queued for remote retry, and set `inputDevice` on the `TranscriptionEntry` built in `apps/macos/LocalFlow/Core/Remote/PendingRemoteRetrier.swift`. Update `PendingRemoteDictationStoreTests.swift` and `PendingRemoteRetrierTests.swift` call sites (depends on T016, T047, T049)
- [X] T049 [US3] Add the input device to the session in `apps/macos/LocalFlow/Features/Dictation/DictationSession.swift` and in `apps/macos/LocalFlow/Features/Dictation/DictationCoordinator.swift`: set it when a candidate starts, mark it as a fallback when an entry ranked above it was unavailable or failed in this key-hold, keep `lastAnnouncedAvailableSet: Int?` (hash of sorted available UIDs) in memory and raise the "Using <name>" notice only when the hash differs, and pass the device name and kind into the saved history entry (depends on T037, T048)
- [X] T050 [US3] Add the caption capsule under the pill in `apps/macos/LocalFlow/Features/Dictation/IndicatorPanel.swift` and `apps/macos/LocalFlow/Features/Dictation/DictationIndicator.swift` using `PillStyle` and the existing notice transitions: "Connecting to <name>…" during `connecting`, "<name>" during `recording`, "Using <name>" for 3 s then "<name>" after a fallback; never takes focus, never modal. VoiceOver: the pill label gains ", <name>" while connecting or recording (depends on T049)
- [X] T051 [P] [US3] Show "Microphone: <name>" in each dictation's detail in `apps/macos/LocalFlow/Features/Transcriptions/HistoryView.swift`, and "Microphone: Not recorded" when `inputDevice` is nil (depends on T047)
- [X] T052 [US3] Run `DictationCoordinatorTests`, `InputDeviceMigrationTests`, `PendingRemoteDictationStoreTests` and `PendingRemoteRetrierTests` with `-only-testing`; all pass
- [ ] T053 [US3] Device run quickstart §5, plus §3 steps 2 and 4 deferred from T030 and the US2 scenario 4 and 5 caption checks deferred from T043, and record them in `specs/019-input-device-priority/acceptance/us3-<date>.md`

**Checkpoint**: US1–US3 work. The user can see which microphone each dictation used.

---

## Phase 6: User Story 4 — meetings use the same list (P3)

**Goal**: a meeting's microphone track starts on the first available ranked entry, and on device loss restarts once on the next available entry, keeping earlier audio and showing a divider.

**Independent test**: rank two inputs, start a meeting, confirm the first is used. Unplug it mid-meeting; recording continues on the second with "Microphone changed to <name>" in the transcript and no loss of earlier audio.

### Tests for User Story 4 (write first, check they fail)

- [X] T054 [P] [US4] Add cases to `apps/macos/LocalFlowTests/MeetingCoordinatorTests.swift` with a fake engine factory: `probeFormat` and `start` bind to the first candidate; on a configuration change the single restart goes to the first candidate that is not the failed device and whose format matches the ring's channel count and sample rate; format mismatch, a second change or no candidate → `deviceLost`; a higher-ranked device appearing never restarts; `rollSegment` writes `currentDeviceName()` into the new microphone segment's `input_device_name` and system-audio segments keep NULL. The existing device-change cases keep passing with a resolver that returns `[systemDefault]`

### Implementation for User Story 4

- [X] T055 [US4] Change `apps/macos/LocalFlow/Core/Meetings/MicrophoneMeetingSource.swift` to take `resolve: @escaping @Sendable () -> [InputCandidate]` and `deviceName: @escaping @Sendable (AudioDeviceID) -> String?`; bind the engine input to the first candidate at `probeFormat` and `start` (same `kAudioOutputUnitProperty_CurrentDevice` call as T015); on `AVAudioEngineConfigurationChange` keep the one-restart rule but restart on the next candidate that is not the failed device and matches the ring format; ignore higher-ranked devices that reconnect; log one `input-device` line per switch with kind, rank, fallbacks, connect_ms, delay_max_ms and the private name
- [X] T056 [US4] Add `currentDeviceName() async -> String?` to the microphone source protocol in `apps/macos/LocalFlow/Core/MeetingBoundaries.swift` and implement it in `MicrophoneMeetingSource.swift` (depends on T055)
- [X] T057 [US4] Write `input_device_name` for microphone-track segments on segment open in `apps/macos/LocalFlow/Core/Storage/MeetingStore.swift`, and pass `currentDeviceName()` from `rollSegment` and the first segment in `apps/macos/LocalFlow/Features/Meetings/MeetingCoordinator.swift` (depends on T016, T056)
- [X] T058 [US4] Inject the shared catalog and store into `MicrophoneMeetingSource` in `apps/macos/LocalFlow/App/AppServices.swift`, with `resolve` calling `InputDeviceResolver.candidates` on the current snapshot and entries (depends on T019, T055)
- [X] T059 [US4] Show a "Microphone changed to <name>" divider at each microphone segment with `open_reason = device_changed`, at the segment's start offset, in the meeting transcript view in `apps/macos/LocalFlow/Features/Meetings/MeetingDetailView.swift` (and `ActiveMeetingView.swift` if it renders the live transcript) (depends on T057)
- [X] T060 [US4] Run `MeetingCoordinatorTests` with `-only-testing`; all pass
- [ ] T061 [US4] Device run quickstart §6 (USB start, unplug after 1 minute, no switch-back) and record it in `specs/019-input-device-priority/acceptance/us4-<date>.md`

**Checkpoint**: all four stories work.

---

## Phase 7: Polish and cross-cutting concerns

- [ ] T062 Run `make check` and the full targeted list from quickstart §1 with `-only-testing`; fix any failure
- [ ] T063 Device run quickstart §7 (upgrade from a pre-feature `main` build, 20 dictations, only "System default" listed, no `connecting` step, tail 0 in every `input-device` line) and record it in `specs/019-input-device-priority/acceptance/upgrade-<date>.md` (SC-007, FR-016)
- [ ] T064 Resource report per quickstart §8: SC-001 (50 dictations on a wired or built-in mic vs 50 on the pre-feature build, median key-down → `recording`, pass at ≤ 50 ms slower) and SC-006 (recording overhead for built-in, USB and iPhone during a 60 s dictation against the 100 MB budget). Write `specs/019-input-device-priority/acceptance/resources-<date>.md` with hardware, build and conditions; unmeasured values stay marked unmeasured
- [ ] T065 [P] Create `docs/performance/input-devices.md` with the measured iPhone connect and delivery delay numbers from T044, cold and warm, with hardware and OS versions; if they argue for a different 3 s limit or 500 ms cap, note it for the owner's decision
- [X] T066 [P] Confirm no network code was added for this feature (FR-017): search the diff for `URLSession`, `NWConnection`, `Network` imports and sockets in the new and changed files, and record the result in `specs/019-input-device-priority/acceptance/resources-<date>.md`
- [X] T067 [P] Confirm logs carry no audio or transcript text and device names are `privacy: .private` in `apps/macos/LocalFlow/Features/Dictation/DictationCoordinator.swift`, `apps/macos/LocalFlow/Core/Meetings/MicrophoneMeetingSource.swift` and `apps/macos/LocalFlow/Core/Audio/InputDeviceCatalog.swift`
- [X] T068 If T004 chose the IOKit clamshell read, confirm IOKit linkage in `apps/macos/LocalFlow.xcodeproj/project.pbxproj`; `THIRD_PARTY_NOTICES.md` stays unchanged either way

---

## Dependencies and execution order

### Phase dependencies

- **Phase 1 (spike)**: none. T003–T004 need the target Mac, USB mic, Bluetooth headset and iPhone. Gates T015 and everything after it in capture.
- **Phase 2 (foundation)**: T005–T013 and T016–T018 can start alongside the spike (T018 after T010); T015 waits for T004. Blocks all stories.
- **US1 (Phase 3)**: after Phase 2.
- **US2 (Phase 4)**: after Phase 2. T037 builds on the US1 candidate loop (T024), so in practice US2 follows US1.
- **US3 (Phase 5)**: after Phase 2. T049 builds on the US2 candidate loop (T037) for fallback marking; the history part (T047, T048, T048a, T051) can start right after Phase 2.
- **US4 (Phase 6)**: after Phase 2 only. Independent of US1–US3 in code; it shares the catalog, store, resolver and migration.
- **Polish (Phase 7)**: after the stories in scope are done.

### Story dependencies

- **US1 (P1)**: foundation only.
- **US2 (P1)**: foundation plus US1's coordinator change (T024).
- **US3 (P2)**: foundation; caption and notice need US2's `connecting` state and loop.
- **US4 (P3)**: foundation only.

### Within each story

- Tests first, failing.
- Models and stores before the coordinator, coordinator before UI.
- Automated run, then the device run.

### Parallel opportunities

- Phase 1 T002 alongside Phase 2 T005–T011 and T016.
- Phase 2: T005, T006, T007, T008 together; T009, T010, T011, T016 together; T018 after T010.
- US1: T021 and T023 together, then T022; T025 alongside T024.
- US2: T031, T032, T033 together.
- US3: T045, T046, T047 together; T048 after T047; T048a after T049; T051 alongside T049–T050.
- US4 can run alongside US2 and US3 once Phase 2 is done, since it touches meeting files only.
- Polish: T065, T066, T067 together.

---

## Parallel example: foundation

```text
Task: "Write InputDeviceResolverTests.swift (T005)"
Task: "Write InputDevicePriorityStoreTests.swift (T006)"
Task: "Write InputDeviceMigrationTests.swift (T007)"
Task: "Extend AudioCaptureTests.swift for InputBinding and stop(tail:) (T008)"

Task: "Create InputDevicePriority.swift (T009)"
Task: "Create InputDeviceCatalog.swift (T010)"
Task: "Create InputDeviceTimings.swift (T011)"
Task: "Append input-device-v18 to HistoryMigrations.swift (T016)"
```

## Parallel example: User Story 1

```text
Task: "Coordinator resolver cases in DictationCoordinatorTests.swift (T021)"
Task: "MicrophonesViewModelTests.swift (T023)"
```

T022 edits the same file as T021, so it runs after T021 rather than in this batch.

## Parallel example: User Story 2

```text
Task: "Ring and first-audio gate cases in AudioCaptureTests.swift (T031)"
Task: "Connecting and tail cases in DictationCoordinatorTests.swift (T032)"
Task: "Two atomics in AudioCaptureRing.c/.h (T033)"
```

---

## Implementation strategy

### MVP (User Story 1)

1. Phase 1: run the spike and pick fallbacks.
2. Phase 2: foundation.
3. Phase 3: US1.
4. Stop and check quickstart §3. Ranking and fallback work for wired, built-in and Bluetooth inputs and the clamshell case. An iPhone ranked first works only if it delivers audio at once; there is no connect limit yet.

### Incremental delivery

1. Foundation → no visible change, upgrade behaviour identical.
2. US1 → ranked list and fallback (MVP).
3. US2 → iPhone connecting state, connect limit and tail. This is the case that started the feature, so ship US1 and US2 together if possible.
4. US3 → device caption, fallback notice, History.
5. US4 → meetings on the same list.
6. Polish → upgrade check, resource report, measured iPhone numbers.

---

## Notes

- [P] tasks touch different files and have no unfinished dependency.
- Commit after each task or logical group.
- The 3 s connect limit and 500 ms tail cap are starting values. T044 and T065 measure them; changing them is the owner's call.
- Do not tick T003, T030, T043, T044, T053, T061, T063 or T064 from fakes or a compile-only build.

---

## Implementation report, 2026-10-02

### What changed

- **Foundation**: `InputDevicePriority.swift` (entries, matching M1–M3, resolver, store with V1–V5, a lock-protected copy for off-main readers), `InputDeviceCatalog.swift` (Core Audio listeners, pure 64-cap snapshot builder, newest-1 broadcaster, `input-device` logger), `InputDeviceTimings.swift` (32 profiles, LRU, last 16 values). `InputDeviceKind` and `DictationInputDevice` live in LocalFlowCore next to `TranscriptionEntry.inputDevice`.
- **Capture**: `AudioCapturing.start(sessionID:spool:input:) -> CaptureStarted` and `stop(sessionID:tail:)`. `AudioCaptureService` binds `.device` through an injectable binder before `prepare()`, drops leading all-zero buffers, starts the 180 s budget at first audio, records per-buffer delivery delay in two new ring atomics, and runs the release tail with the poll still live.
- **Dictation**: `DictationSession.State.connecting`; the coordinator resolves candidates after the permission check, tries each once on the same empty spool with a 3 s connect limit, computes the tail, logs one `input-device` line, records timings and four new `ResourceRecorder` metrics, and saves the device on the history row and on pending remote retries.
- **FR-013 behaviour change**: a capture-reported `deviceLost` now inserts the captured text automatically. Before, it was saved for review and copied to the clipboard. `testFullEnvelopeRemainsReviewOnlyForDurationAndCaptureFailures` no longer lists `deviceLost`. Mailbox-driven device-loss stops stay review-only.
- **UI**: Settings › Microphones (list with drag and Move up/down actions, Add menu, iPhone help line and link), a connecting pulse, a caption under the pill ("Connecting to …", "<name>", "Using <name>" for 3 s), a "Microphones…" failure notice that opens Settings scrolled to the section, and "Microphone: <name>" in the dictation details.
- **Meetings**: `MicrophoneMeetingSource` sits behind a `MicrophoneEngine` seam, binds the first candidate, restarts once (same device while it is available, otherwise the next one with a matching format), and never switches back to a device that reappears. Microphone segments store `input_device_name`, and the transcript shows "Microphone changed to <name>" dividers.
- **Migration** `input-device-v18`: added exactly as in data-model.md and appended to the frozen list.

### Decisions taken without the spike (T003/T004 not run)

- **S1**: no Continuity name/model marker fallback; only the `ccwd`/`ccwl` transport types map to iPhone.
- **S2**: no explicit audio-unit fallback.
- **S3**: the IOKit `AppleClamshellState` read is in, read at each `snapshot()` and on screen notifications. This is defensive, and redundant if macOS already drops the lid-closed mic. IOKit links through Swift autolinking; `project.pbxproj` and `THIRD_PARTY_NOTICES.md` are unchanged (T068).
- **S5**: the same-device restart for a pinned dictation engine is implemented (T035). It has no unit test because it needs a real engine, so T035 stays open until the spike confirms it.
- **S6**: no meeting format limit was added to the help text (T041). Add it if the spike finds one.

### Verification

- App and test target build (`build-for-testing`).
- The quickstart §1 list, run with `-only-testing` (resolver, store, capture, coordinator, meeting coordinator, migration, view model, pending store, retrier, compatibility, probe harness): 208 tests, 0 failures. The probe harness skips without `TEST_RUNNER_LOCALFLOW_INPUT_PROBE=1`.
- 43 more suites that touch the changed code: 629 tests, 0 failures.
- `swift format lint --strict` on every changed file, `scripts/check-core-imports.sh` and `swift build` of LocalFlowCore are clean.
- `make check` was not run, at the owner's request (T062).

### What is left

- T003/T004: run the spike on the target Mac (quickstart §2, now with the `TEST_RUNNER_` prefix) and confirm or change the S1–S6 decisions above.
- T030, T043, T044, T053, T061, T063, T064: device runs and the resource report.
- T065: `docs/performance/input-devices.md` exists with every value marked unmeasured; fill it in from T044.
- T062: `make check`.
