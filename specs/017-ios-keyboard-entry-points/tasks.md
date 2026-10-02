# Tasks: full dictation keyboard and system entry points

**Scope change (2026-10-01)**: the owner rejected the typing prototype and chose a dictation-only keyboard (research R7). Phase 4 (US1) and the `lexicon.json` work are removed; task IDs are kept.

**Input**: [plan.md](plan.md), [spec.md](spec.md), [research.md](research.md), [data-model.md](data-model.md), [contracts/keyboard-handoff-v1-additions.md](contracts/keyboard-handoff-v1-additions.md), [contracts/system-entry-points.md](contracts/system-entry-points.md), [quickstart.md](quickstart.md)

Tests are included: constitution principle 12 requires them, and both contracts list them. Paths are relative to the repo root.

- `apps/ios/LocalFlowPhone.xcodeproj` uses synchronized folders. A new file under `apps/ios/App`, `apps/ios/Keyboard`, `apps/ios/Shared` or `apps/ios/LocalFlowPhoneTests` joins its targets with no project edit. The new `apps/ios/Intents` and `apps/ios/Widgets` folders need their own synchronized groups (T001, T050).
- `LocalFlowPhoneTests` is hosted by the app, so pure files in `apps/ios/Shared/KeyboardLogic/` are testable there. UIKit-only keyboard code stays in `apps/ios/Keyboard/`.
- Scope `xcodebuild test` runs with `-only-testing:LocalFlowPhoneTests/<Class>`. `make check` is the full run.
- Device acceptance goes in `specs/017-ios-keyboard-entry-points/acceptance/` with date, iOS version, git SHA and conditions. A task that needs the iPhone is not done until a device run is recorded. Mocks and simulator builds do not count. Owner-attested results without figures are written down as owner-attested.

## Order at a glance

The plan builds in two milestones. Milestone A (US2–US4) is accepted on the device before milestone B (US5–US6) starts. If the spike shows US6 cannot work even with the R1 fallback, milestone B leaves this feature (spec assumption) and A ships alone.

1. Phase 1: spike on the device (blocks everything)
2. Phase 2: ADR 0030 and build boundaries
3. Phase 3: handoff and session foundation (blocks US2–US4)
4. Phases 5–7: US2, US3, US4 (Phase 4, US1, removed)
5. Phase 8: milestone A gate (keyboard footprint, SC-003)
6. Phase 9: milestone B foundation (blocks US5–US6)
7. Phases 10–11: US5, US6
8. Phase 12: resource report and docs

---

## Phase 1: Setup — spike (blocks everything)

**Purpose**: settle research R1 (cold-start control), R4 (clipboard while locked) and R7 (fast typing with SwiftUI keys) on the iPhone 16 Pro before the code that depends on them.

- [X] T001 Add the `LocalFlowWidgets` widget extension target to `apps/ios/LocalFlowPhone.xcodeproj/project.pbxproj`, embedded in `LocalFlowPhone`:
  - iOS 26.0, iPhone only, Swift 6 language mode, bundle ID `$(LOCALFLOW_BUNDLE_PREFIX).LocalFlow.Widgets`, team from `Config/Signing.local.xcconfig` via `Config/Base.xcconfig` like the other two targets.
  - New `apps/ios/Config/Widgets-Info.plist` (`NSExtensionPointIdentifier = com.apple.widgetkit-extension`, `UIAppFonts` with the two bundled Sotto fonts) and `apps/ios/Config/LocalFlowWidgets.entitlements` with the existing App Group `$(LOCALFLOW_APP_GROUP)`.
  - Synchronized groups: `apps/ios/Widgets` and `apps/ios/Intents` into the widget target; `apps/ios/Intents` also into `LocalFlowPhone`. From `apps/ios/Shared` the widget compiles only `Sotto/` (membership exceptions). The widget links neither `LocalFlowCore` nor `LocalFlowSpeech`.
  - Add `NSSupportsLiveActivities = YES` to `apps/ios/Config/App-Info.plist`.
  - Register the new App ID on team 944A459UC3 once (research R12; the owner approved this in the spec's signing assumption). `make ios` still builds all three targets without signing.
- [X] T002 Write throwaway spike code for R1 and R4 in `apps/ios/Intents/SpikeToggleIntent.swift`, `apps/ios/Widgets/SpikeControl.swift` and `apps/ios/App/System/SpikeIntentHandler.swift`: an `AudioRecordingIntent` that requests a minimal Live Activity, starts or stops the existing `SessionController` dictation, and writes a fixed string to `UIPasteboard.general` from the background; a `ControlWidgetButton` that runs it.
- [X] T003 Write a throwaway SwiftUI key-grid prototype for R7 in `apps/ios/Keyboard/SpikeKeyGrid.swift`: the letter layout as plain views with one `DragGesture(minimumDistance: 0)` per key, firing on touch-up, wired into `apps/ios/Keyboard/KeyboardView.swift` behind a Debug flag.
- [X] T004 Run quickstart §2 on the iPhone 16 Pro and record in `specs/017-ios-keyboard-entry-points/acceptance/spike.md`:
  - R1: for (a) locked Lock Screen, (b) Control Center over Safari, (c) Action Button with LocalFlow killed: did recording start, did a Live Activity appear, did LocalFlow come forward, any error text. Repeat each with a keyboard session already running.
  - R4: clipboard write from the background and with the phone locked.
  - R7: 2 minutes of fast two-thumb typing in Notes; lost or doubled keys; keyboard footprint at rest from Settings › Diagnostics.
  - Decision per item: R1 fallback (`openAppWhenRun` for the no-session case only), R4 fallback (pending clipboard write until unlock), R7 fallback (UIKit key grid only). Write each outcome into `specs/017-ios-keyboard-entry-points/research.md` under R1, R4 and R7.
  - Done 2026-10-01 (acceptance/spike.md runs 1–3): R1 background cold start works with `LiveActivityIntent` added and the launch model check awaited, no fallback; R4 fallback taken (background writes dropped); R7 prototype rejected, owner chose a dictation-only keyboard. The press-during-a-keyboard-session row moved to T071.
- [X] T005 Delete `apps/ios/Intents/SpikeToggleIntent.swift`, `apps/ios/Widgets/SpikeControl.swift`, `apps/ios/App/System/SpikeIntentHandler.swift` and `apps/ios/Keyboard/SpikeKeyGrid.swift` the Debug flag in `apps/ios/Keyboard/KeyboardView.swift` and the Debug `isMultipleTouchEnabled` line in `apps/ios/Keyboard/KeyboardViewController.swift`, and the spike registration in `apps/ios/App/LocalFlowPhoneApp.swift`. Add a minimal `apps/ios/Widgets/LocalFlowWidgets.swift` (`@main WidgetBundle`, empty until T058) so the widget target still builds. Keep the widget target, its plist (with `LocalFlowAppGroup`), entitlements and the App ID.

**Checkpoint**: spike recorded and the fallbacks written into research.md. If R1 rules out US6 entirely, mark Phases 9–11 as moved to a new feature before going on.

---

## Phase 2: ADR and build boundaries

- [X] T006 Write `docs/adr/0030-ios-system-entry-points.md`: the third iOS target `LocalFlowWidgets`, the `Intents/` folder compiled into the app and the widget, intents running in the app process through `@Dependency`, background recording limited to visible, user-started recordings (App Review 2.5.4, FR-030), and the rejected alternatives from plan "Complexity tracking". Add it to `docs/adr/README.md`.
- [X] T007 [P] Update the scope paragraph in `AGENTS.md` to name the `LocalFlowWidgets` extension (control and Live Activity) among the iOS targets.
- [X] T008 [P] Extend `scripts/check-keyboard-imports.sh` (research R11): also scan `apps/ios/Widgets` and `apps/ios/Intents` for `Network`, `FluidAudio`, `GRDB`, `LocalFlowCore`, `LocalFlowSpeech`, `URLSession`, `AVFAudio` and `AVFoundation`; fail if `apps/ios/Keyboard` or `apps/ios/Shared` imports `ActivityKit` or `AppIntents`; and fail if `AVFAudio` or `AVFoundation` appears in `apps/ios/Keyboard`. Skip directories that do not exist yet. Update the header comment to name Feature 017.
- [x] T009 [P] Correct the "Live Activity duration limit" edge case in `specs/017-ios-keyboard-entry-points/spec.md` per research R3: the activity returns when LocalFlow next comes forward or the control is used, not at the next keyboard recording. Done during analyze (2026-10-01).

---

## Phase 3: Foundational — handoff additions and session fields (blocks US2–US4)

**Purpose**: the version 1 additions from [contracts/keyboard-handoff-v1-additions.md](contracts/keyboard-handoff-v1-additions.md) and the session fields every keyboard story reads.

**⚠️ CRITICAL**: no keyboard story can start until this phase is complete.

- [X] T010 [P] Add codec tests to `apps/ios/LocalFlowPhoneTests/HandoffCodecTests.swift`: `idle_timeout = "never"`; `recording_started_at` (ms since epoch), `input_name` and `dictation_source` (`keyboard`, `app`, `control`) round-trip; a `session.json` with every new field missing decodes; every 016 file fixture still decodes; `request.json` with `kind = "end"`. They fail until T011.
- [X] T011 Extend `apps/ios/Shared/Handoff/HandoffModels.swift`: `IdleTimeout`'s wire value gains `never`; `SessionFile` gains optional `recordingStartedAt` (`recording_started_at`, ms), `inputName` (`input_name`) and `dictationSource` (`dictation_source`); the request kind gains `end`. `v` stays 1. If `IdleTimeout` lives only in the app, add the wire enum here and map it in `apps/ios/App/Session/IdleTimer.swift`.
- [X] T012 Add `case never` (raw value `never`) to `IdleTimeout` in `apps/ios/App/Session/IdleTimer.swift`: `seconds` becomes `TimeInterval?` and is nil for `never`; title "Never"; `allCases` order After one dictation, 5 minutes, 15 minutes, 1 hour, Never; default stays `5m` (FR-023, research R6). Fix the call sites in `apps/ios/App/Session/SessionController.swift` so a nil timeout stores no `idleDeadline` and `tick()` ignores a nil deadline.
- [X] T013 [P] Add to `apps/ios/LocalFlowPhoneTests/SessionControllerTests.swift`: a `never` session has no deadline in `ready`, survives `tick()` at any test-clock time and still ends on `end(.userEnded)`; `recordingStartedAt` is set on `recording` and cleared otherwise; `inputName` comes from the fake capture's route and is cleared outside `recording`.
- [X] T014 Add `recordingStartedAt: Date?` and `inputName: String?` to `PhoneSession` in `apps/ios/App/Session/SessionController.swift` (data-model §2). Read the input name from `AVAudioSession.sharedInstance().currentRoute.inputs.first?.portName` when recording starts and on `routeChangeNotification`, through a new `inputName` property on `AudioCapturing` in `apps/ios/App/Session/AudioCapturing.swift` (with `apps/ios/App/Session/PhoneAudioCapture.swift` and `apps/ios/LocalFlowPhoneTests/Fakes/FakeAudioCapture.swift` updated).
- [X] T015 [P] Add to `apps/ios/LocalFlowPhoneTests/HandoffServerTests.swift`: `end` with a matching `session_id` ends the session with `userEnded` and discards a recording in progress; `end` with a stale `session_id` is ignored; `cancel` writes no `result.json`; `session.json` carries `idle_timeout = never` with a null `idle_deadline`, and `recording_started_at`, `input_name`, `dictation_source` only while recording or finishing.
- [X] T016 Extend `apps/ios/App/Session/HandoffServer.swift`: write the new `session.json` fields from T014 and the dictation's source; handle `kind = end` by calling `SessionController.end(.userEnded)` when `session_id` matches.

**Checkpoint**: `make check` passes; the keyboard can read every field the stories below need.

Done 2026-10-01: tests written first and seen failing (compile errors on the missing API), then T011, T012, T014, T016; the three classes pass (38 tests) and `make check` passes. `idle_timeout` stays a string on the wire (`IdleTimeout.rawValue`), so no second enum was added. `AudioCapturing` also gained `onRouteChange` so the controller can refresh `inputName`. The 016 fixtures are the contract examples, inlined in `HandoffCodecTests`. No device run was needed for this phase.

---

## Phase 4: User Story 1 — Type everything with the LocalFlow keyboard (removed)

Removed on 2026-10-01 (research R7, spec scope change). T017–T027 are dropped: no layouts, typing model, autocorrect, suggestions or key grid. The fixed keyboard height from T025 moves to T039.

---

## Phase 5: User Story 2 — Reach every action from the top bar (Priority: P1)

**Goal**: ☰ drawer (Settings, End session), a large round mic, the session status, and Undo plus Insert last dictation after an insertion.

**Independent test**: without a session tap the mic, swipe back, check the countdown, dictate, Undo, Insert last dictation, then end the session from the drawer (quickstart §4.1, §4.2, §4.9).

### Tests for User Story 2

- [X] T028 [P] [US2] Add `apps/ios/LocalFlowPhoneTests/BarStatusTests.swift` with a fixed clock: `Listening · 4:12` counting down to `idle_deadline` (m:ss, never negative); `Listening · no timeout` for `never`; `Listening · after this dictation` for `afterOne`; nothing without a session; "LocalFlow is recording elsewhere" when `dictation_source = control` and there is no pending request.
- [X] T029 [P] [US2] Add to `apps/ios/LocalFlowPhoneTests/KeyboardSessionModelTests.swift`: End session writes `request.json` with `kind = end` and the current `session_id`; `lastInserted` holds the text of the most recent inserted or offered keyboard result (never a control result) and Insert last dictation inserts it; Undo removes exactly the inserted text under the 016 `InsertionPolicy.canUndo` rules.

### Implementation for User Story 2

- [X] T030 [P] [US2] Create `apps/ios/Shared/KeyboardLogic/BarStatus.swift`: a pure function from `sessionView`, `idleTimeout`, `idleDeadline`, `dictationSource` and now to the bar string in FR-014.
- [X] T031 [US2] Extend `apps/ios/Shared/KeyboardLogic/KeyboardSessionModel.swift`: read `idle_timeout` and `idle_deadline` from `session.json`; add `endSession()` that writes `request.json` with `kind = end` and rings `request`; add `lastInserted` (memory only, dropped with the process) and `insertLast()`.
- [X] T032 [P] [US2] Create `apps/ios/Keyboard/DrawerView.swift` (SwiftUI, Sotto tokens): Settings (opens `localflow://settings`), End session (shown only while a session runs).
- [X] T033 [US2] Replace the 016 capsule in `apps/ios/Keyboard/KeyboardView.swift` with the top bar, above the 016 key row: ☰ on the left opening `DrawerView`, a large round mic on the right, the `BarStatus` string between them redrawn by `TimelineView(.periodic(by: 1))`, and Undo and "Insert last dictation" after an insertion. No style or rewrite control (FR-016). With no session the mic opens `localflow://session/start?request=<uuid>` as in 016; without Full Access the mic and status say Full Access is needed and link to it, as in 016.
- [X] T034 [US2] Open `localflow://settings` from `apps/ios/Keyboard/KeyboardViewController.swift` through the existing 016 responder-chain open path (no private API), and handle it in `apps/ios/App/LocalFlowPhoneApp.swift` by showing Settings and starting nothing.

**Checkpoint**: every action is reachable from the bar; End session works from the keyboard.

---

## Phase 6: User Story 3 — Dictating takes over the keyboard (Priority: P1)

**Goal**: the listening view replaces bar and keys at the same height, with ✕, ✓, a large 15-bar waveform, elapsed time and input name; rolling wave while transcribing; notices for not running, Full Access, nothing heard and errors.

**Independent test**: in a running session dictate three times into Notes: ✓, ✕, and one run to the 5-minute limit (quickstart §4.3–§4.8).

### Tests for User Story 3

- [X] T035 [P] [US3] Add to `apps/ios/LocalFlowPhoneTests/KeyboardSessionModelTests.swift` with a test clock: `surface` is `listening` straight after the mic tap; if `session.json` is not `recording` with this request's `dictation_id` within 2 s the surface becomes `notice(.notRunning)`; a `busy` outcome shows "LocalFlow is recording elsewhere" and returns to `keys`; ✕ writes `cancel`, returns to `keys` at once and inserts nothing when a late result arrives; the surface is `transcribing` from ✓ until `result.json`, a no-text `last_outcome`, or the 15 s timeout; `nothingHeard` and `failed` return to `keys` after 4 s or a tap; disappearing with a pending, unstopped request writes `stop`; the elapsed time and the "Stops at 5:00 · m:ss left" warning from 4:30 come from `recording_started_at`.

### Implementation for User Story 3

- [X] T036 [US3] Extend `apps/ios/Shared/KeyboardLogic/KeyboardSessionModel.swift`: `surface` (`keys`, `listening(startedAt, inputName)`, `transcribing`, `notice(Notice)`), `Notice` (`notRunning`, `fullAccess`, `nothingHeard`, `failed(hint)`), `startSentAt` and the 2 s not-running check, `cancel()` writing `request.json` `kind = cancel`, and `stopOnDisappear()` (data-model §4, contract "Dictation in the listening view").
- [X] T037 [P] [US3] Add a large 15-bar waveform to `apps/ios/Shared/Sotto/WaveformViews.swift`: the last 15 of the 31 `levels.bin` slots, drawn like the Mac's `DictationIndicator`, at about 3× the capsule size; reuse `RollingWave` for transcribing. Sotto tokens only.
- [X] T038 [US3] Create `apps/ios/Keyboard/ListeningView.swift` per FR-017 and `reference/wispr-listening.png`: round ✕ top left, round ✓ top right, an empty slot left of ✓ reserved for Feature 018, the large waveform centred, "Listening · 0:03" from `recording_started_at` via `TimelineView(.periodic(by: 1))` (from 4:30 "Stops at 5:00 · 0:24 left"), the input name under it, and the globe key bottom left when `needsInputModeSwitchKey`. The same rect shows the rolling wave while transcribing and each `Notice` with its way forward (Start LocalFlow, Open Full Access settings, dismiss).
- [X] T039 [US3] Switch `apps/ios/Keyboard/KeyboardView.swift` between the bar plus keys and `ListeningView` on `surface`, without changing the keyboard height: set one fixed height (top bar 48 pt plus the key row, enough for the listening view) with a height constraint at priority 999 on the input view in `apps/ios/Keyboard/KeyboardViewController.swift` (research R10).
- [X] T040 [US3] In `apps/ios/Keyboard/KeyboardViewController.swift` call `stopOnDisappear()` from `viewWillDisappear` so a dismissed keyboard never leaves a recording without a visible owner; the result then follows the 016 insertion rules and is offered as Insert last dictation (FR-026).

**Checkpoint**: keyboard dictation works end to end in the new layout.

---

## Phase 7: User Story 4 — A session that never times out (Priority: P1)

**Goal**: "Never" in Settings, and clear wording in the app and keyboard that the mic stays available with End session one tap away.

**Independent test**: choose Never, start a session, use other apps for two hours, dictate from the keyboard, end the session from the drawer (quickstart §5).

- [X] T041 [US4] Show Never in the "End listening after" picker in `apps/ios/App/Features/Settings/SettingsView.swift` (it follows `IdleTimeout.allCases` from T012), with a one-line note that the microphone stays available until the session is ended.
- [X] T042 [US4] Update `apps/ios/App/Features/Session/SessionView.swift`: for a `never` session show "This session won't end on its own" instead of the countdown, and make End session the prominent action (FR-025).
- [ ] T043 [US4] Run quickstart §4 and §5 on the iPhone 16 Pro (top bar, listening view, ✕, 5-minute limit, not running, nothing heard, dismiss while recording, drawer, SC-004 50 dictations, SC-005 20 in a row with no trip to LocalFlow, SC-006 two-hour Never session, SC-007 end from the drawer) and record in `specs/017-ios-keyboard-entry-points/acceptance/keyboard-dictation.md` and `specs/017-ios-keyboard-entry-points/acceptance/never-session.md`.

**Checkpoint**: Stories 1–4 are a complete release.

Done 2026-10-01 (T028–T042): tests written first and seen failing on the missing API; 31 tests in `BarStatusTests`, `KeyboardSessionModelTests` and `InsertionPolicyTests` pass, and `make check` passes. One unrelated macOS test (`MeetingTrackWorkerTests.testThirtyMinutesWithUndrainedTapMatchesRecordingOnly`) failed once under load and passed alone and on the rerun. Notes:

- Undo and Insert last dictation sit in the strip under the bar, not in the bar itself: the bar is too narrow on a 402 pt screen for ☰, the status, both chips and the mic.
- The keyboard cannot know the app's `dictation_id` for its start, so the 2 s not-running check passes when `session.json` reaches `recording` or `finishing` at all. `busy` and `no_session` outcomes cover the other cases.
- The Full Access notice has no link: opening any URL from the keyboard needs Full Access (016 research R6), so it gives the Settings path in text.
- `BarStatus.swift` is excluded from the widget target, like the other `Shared/KeyboardLogic` files.
- The fixed height is 260 pt; T043 should check it on the device.
- First device try (2026-10-01): the keyboard said "Dictation failed. Open LocalFlow to see why." and the app showed nothing. Cause, reproduced in `SessionControllerTests.testDictationStoppedWhileTheModelLoadsWaitsForIt`: a dictation that stops while keep-ready is still loading the model got `busy` from `acquire` and failed. Probably also spike run 3's unexplained `failed`. `PhoneDictationPipeline` now waits for the load (`ModelLifecycleCoordinator.waitUntilAvailable`, made public) and retries. The app also logs the error and keeps `SessionController.lastFailure`, which shows on the session screen and in the banner. `make check` passes.
- Open: T043 (device run of quickstart §4 and §5).

---

## Phase 8: Milestone A gate — keyboard footprint (SC-003)

- [X] T044 Record the keyboard's footprint per surface: `apps/ios/Keyboard/KeyboardViewController.swift` writes optional `footprint_rest_bytes` and `footprint_listening_bytes` (peak `phys_footprint` while each surface is shown) to `keyboard-status.json`; add the fields to `apps/ios/Shared/Handoff/HandoffModels.swift` with a codec test in `apps/ios/LocalFlowPhoneTests/HandoffCodecTests.swift`; show them in `apps/ios/App/Features/Settings/DiagnosticsView.swift`.
- [X] T045 Measure on the iPhone 16 Pro the keyboard footprint at rest and with the listening view up (each under 40 MB, SC-003), and record build, iOS version and conditions in `specs/017-ios-keyboard-entry-points/acceptance/keyboard-footprint.md`. Milestone B does not start until this and T043 are recorded.

Done 2026-10-02 (T044): the keyboard samples `phys_footprint` once a second while visible and keeps the highest value per surface for the life of its process. Every surface except the keys (listening, transcribing, notices) counts as "listening". It rewrites `keyboard-status.json` whenever either peak rises. Diagnostics shows "Peak at rest" and "Peak while listening". `testKeyboardStatusCarriesTheSurfaceFootprintsAndReadsOlderFiles` passes, and so does `make check`. Limit: with a 1 s sample, a spike shorter than a second can be missed; the process-wide "Peak" row still catches it. Open: T045 and T043 on the device.

Done 2026-10-02 (T045): 14.1 MB at rest and 13.1 MB while listening, recorded in `acceptance/keyboard-footprint.md`. The same device run led to three changes: the key row and the ☰ drawer were removed (owner, `5236f42`, spec scope note 2026-10-02); the keyboard now keeps waiting past 15 s while LocalFlow answers a ping, because the first model load after an install takes 37–50 s (`0d97f27`); and the transcribing view says so after the first 15 s (`bfa799e`).

Owner decision 2026-10-02: Milestone B (Phase 9 onward) starts with T043 still open. The owner runs the SC-004/SC-005 50-dictation count, the SC-006 two-hour Never session and the error cases in everyday use and reports them later.


---

## Phase 9: Milestone B foundation — storage and intent plumbing (blocks US5–US6)

**⚠️ CRITICAL**: skip Phases 9–11 if T004 moved milestone B to its own feature.

- [ ] T046 [P] Add to `apps/ios/LocalFlowPhoneTests/PhoneMigrationTests.swift`: the frozen migration list ends with `phone-dictations-v2`; v2 keeps every v1 row and value; after v2 `source = 'control'` with `delivery IN ('copied','saved_only')` is accepted, `source = 'control'` with `inserted` or `offered` is rejected, and `source = 'app'` still requires `saved_only`.
- [ ] T047 Add migration `phone-dictations-v2` to `apps/ios/App/Storage/PhoneMigrations.swift`, registered after `phone-dictations-v1`, in one transaction: create `phone_dictations_new` with `source` ∈ `keyboard`, `app`, `control`, `delivery` ∈ `inserted`, `offered`, `saved_only`, `copied`, and the table check "`source = 'app'` ⇒ `delivery = 'saved_only'`; `source = 'control'` ⇒ `delivery IN ('copied','saved_only')`"; copy every row; drop the old table; rename the new one; recreate its indexes.
- [ ] T048 Extend `apps/ios/App/Storage/PhoneDictationStore.swift`: `source = control`; `markCopied(dictationID)` that sets `delivery = copied` and `transcriptions.delivery_state = not_inserted` (the phone never writes `attempting`); `newestTranscript()` for Copy after a relaunch.
- [ ] T049 Add `IntentHandler` dependency plumbing: create `apps/ios/Intents/IntentHandler.swift` with `protocol IntentHandler: Sendable { func toggleDictation() async throws -> ToggleOutcome; func endSession() async; func copyLast() async throws }`, `ToggleOutcome` (`.started`, `.stopped`) and `LocalFlowIntentError` (`CustomLocalizedStringResourceConvertible`) with the six cases and texts from contracts/system-entry-points.md "Errors shown to the owner".
- [ ] T050 [P] Create `apps/ios/Intents/DictationActivityAttributes.swift` (ActivityKit) per data-model §3: attributes `sessionStartedAt: Date`, `kind` (`session`, `control`); content state `phase` (`idle`, `recording`, `transcribing`, `result`, `failed`), `deadline: Date?` ("nil for `never`, while recording, and for `control`"), `noTimeout: Bool`, `recordingStartedAt: Date?`, `preview: String?` ("first 120 characters of the last transcript, `result` phase only"), `message: String?`. Content state stays under 1 KB.
- [ ] T051 [P] Create the test fakes `apps/ios/LocalFlowPhoneTests/Fakes/FakeActivityRequester.swift`, `apps/ios/LocalFlowPhoneTests/Fakes/FakePasteboard.swift` and `apps/ios/LocalFlowPhoneTests/Fakes/FakeNotificationCenter.swift`, matching the protocols `ActivityRequesting`, `Pasteboard` and `ResultNotifying` declared in `apps/ios/App/System/SystemProtocols.swift` (create it: start/update/end activity and `areActivitiesEnabled`; `setString`; authorization status and `add(request)`).
- [ ] T052 Add `SessionController.lastResult` (dictation ID and text of the most recent result from any source, memory only) to `apps/ios/App/Session/SessionController.swift`.

**Checkpoint**: the store accepts control dictations; intents, attributes and fakes compile in the app and the widget.

---

## Phase 10: User Story 5 — See and control the session from the Lock Screen and Dynamic Island (Priority: P2)

**Goal**: a Live Activity for every session with elapsed time, time remaining or "no timeout", phase, Stop and Copy.

**Independent test**: start a session, lock, check the Lock Screen; dictate and watch Recording → Transcribing → Ready; Copy and paste; Stop (quickstart §6).

### Tests for User Story 5

- [ ] T053 [P] [US5] Add `apps/ios/LocalFlowPhoneTests/ActivityControllerTests.swift` with `FakeActivityRequester`: a session start requests one activity with `kind = session`; any existing LocalFlow activity is ended before a new request (at most one); phase changes produce exactly one update each (no per-second updates); `deadline` is nil and `noTimeout` true for `never`; the activity ends `.immediate` when the session ends; a session still starts when `areActivitiesEnabled` is false.
- [ ] T054 [P] [US5] Add `apps/ios/LocalFlowPhoneTests/PhoneIntentHandlerTests.swift` (first part): `endSession()` ends a running session and is a no-op without one; `copyLast()` writes `lastResult` to `FakePasteboard`, falls back to `newestTranscript()` after a relaunch, and throws `nothingToCopy` with neither.

### Implementation for User Story 5

- [ ] T055 [US5] Create `apps/ios/App/System/ActivityController.swift`: observes `SessionController.onChange`; requests, updates and ends the activity per research R3 through `ActivityRequesting` (production implementation over `Activity<DictationActivityAttributes>` in the same file); ends any existing activity before requesting; logs only phases and IDs. A keyboard session starts its activity when the session starts in the foreground.
- [ ] T056 [US5] Create `apps/ios/Intents/SessionIntents.swift`: `EndSessionIntent` ("End LocalFlow session") and `CopyLastDictationIntent` ("Copy last LocalFlow dictation"), both `LiveActivityIntent`, resolving `@Dependency var handler: IntentHandler` and throwing `LocalFlowIntentError.unavailable` when none is registered. Copy runs with the app in the background, where the spike saw clipboard writes dropped (R4): check on the device, and if the write is dropped, hold it as the pending write and bring LocalFlow forward to apply it.
- [ ] T057 [US5] Create `apps/ios/App/System/PhoneIntentHandler.swift` implementing `endSession()` (`SessionController.end(.userEnded)`) and `copyLast()` (writes the full transcript through `Pasteboard`; a `control` row is marked `copied` in US6). Register it with `AppDependencyManager.shared.add` in `apps/ios/App/PhoneServices.swift` at launch, and own `ActivityController` there.
- [ ] T058 [P] [US5] Create `apps/ios/Widgets/LocalFlowWidgets.swift` (`@main WidgetBundle`) and `apps/ios/Widgets/DictationLiveActivity.swift` per contracts/system-entry-points.md "Live Activity": Lock Screen/banner (phase label Ready · Recording · Transcribing · Copied, elapsed session time, remaining time or "No timeout", Stop; in `result` the preview and Copy), Dynamic Island compact, minimal and expanded. Timers via `Text(timerInterval:countsDown:)`. Stop runs `EndSessionIntent` for a session activity. Copy runs `CopyLastDictationIntent`. Sotto colours and fonts from `apps/ios/Shared/Sotto`.
- [ ] T059 [US5] Add a Live Activities hint to `apps/ios/App/Features/Settings/SettingsView.swift`: when `ActivityAuthorizationInfo().areActivitiesEnabled` is false, say sessions still work but the control cannot record, with a link to LocalFlow's system settings.
- [ ] T060 [US5] Run quickstart §6 on the iPhone 16 Pro (SC-007 Stop from the Live Activity, indicator off within 10 s) and record in `specs/017-ios-keyboard-entry-points/acceptance/live-activity.md`.

**Checkpoint**: sessions are visible and stoppable outside the keyboard.

---

## Phase 11: User Story 6 — Dictate without the keyboard (Priority: P2)

**Goal**: press the control, Action Button or "Dictate a LocalFlow note" to start, press again to stop; the text goes to History and the clipboard with Copy in the Live Activity and an optional notification.

**Independent test**: assign the control to the Action Button; from the locked Lock Screen record 15 s, stop, unlock, check History and the clipboard (quickstart §7).

### Tests for User Story 6

- [ ] T061 [P] [US6] Add to `apps/ios/LocalFlowPhoneTests/PhoneIntentHandlerTests.swift` with all three fakes: toggle with no session starts an `origin = control` session and a `source = control` dictation and requests a `kind = control` activity before recording; toggle with a `ready` session starts a `control` dictation in it without changing its origin; toggle during a keyboard recording stops it and the result goes to `result.json` with `source = keyboard`; toggle during a control recording stops it; toggle refused with `liveActivitiesOff` when activities are off and nothing records (FR-030); `modelMissing` and `microphoneDenied` refuse and post a notification only when allowed; a finished control dictation is saved `saved_only`, written to the pasteboard, then marked `copied`, and stays `saved_only` when the write fails; the control activity ends in `result` with the preview cut to 120 characters and dismissal after 5 minutes; a pending save before first unlock makes the next toggle throw `pendingSave`, keeps the dictation's spool until the retried save succeeds, and leaves an orphan for 016 recovery when the process ends first; a keyboard start during a control recording gets `busy` (FR-032).

### Implementation for User Story 6

- [ ] T062 [US6] Extend `apps/ios/App/Session/SessionController.swift`: `origin = control` (one-shot, ends after its dictation like `app`); `ActiveDictation.source = control`; route a finished control dictation to a new `onControlResult` callback instead of `result.json`; `PendingSave` (at most one, app memory) when the History write fails before first unlock, retried on `protectedDataDidBecomeAvailable` and `didBecomeActive`; delete the spool only after the History save succeeds (move the cleanup out of `PhoneDictationPipeline.run`'s `defer` into the caller for this path) so a process death leaves an orphan that `OrphanSpoolRecovery` re-transcribes; the 5-minute limit and interruptions behave as for keyboard dictations.
- [ ] T063 [US6] Create `apps/ios/Intents/ToggleDictationIntent.swift`: `AudioRecordingIntent` **and** `LiveActivityIntent` (without the second, `perform()` runs in the widget extension; spike run 1), title "Dictate a LocalFlow note", resolving `IntentHandler`, returning the dialog "Recording", "Stopped" or the error text. No `openAppWhenRun`: the spike kept the background cold start (R1).
- [ ] T064 [US6] Implement `toggleDictation()` in `apps/ios/App/System/PhoneIntentHandler.swift` per research R1's state table, awaiting the launch model check on a cold start (spike run 2) and then checking activities, model, microphone permission and `PendingSave`; log the transcription failure detail (spike run 3 had one unexplained `failed`); on `onControlResult` save to History, write the clipboard through `Pasteboard` and `markCopied`, update the activity to `result`, and post the notification. Per T004 the R4 fallback is taken: hold one pending clipboard write (newest wins) and apply it when the app becomes active (background writes are dropped even when unlocked), with the activity saying the text is copied when LocalFlow opens. Record the stop → result time for Diagnostics.
- [ ] T065 [P] [US6] Create `apps/ios/Widgets/DictationControl.swift`: `ControlWidget` kind `app.localflow.control.dictate`, `ControlWidgetButton(action: ToggleDictationIntent())`, label "LocalFlow", symbol `mic.fill`; add it to `apps/ios/Widgets/LocalFlowWidgets.swift`. In `apps/ios/Widgets/DictationLiveActivity.swift`, Stop runs `ToggleDictationIntent` while a control recording runs.
- [ ] T066 [US6] Create `apps/ios/App/System/ResultNotifier.swift`: category `dictation.result` with a background `copy` action ("Copy"); title "LocalFlow note", body the first 120 characters, thread `localflow.dictation`; posted only when `notifications.dictationResults` is on and permission is granted; the `copy` action reads the full transcript by dictation ID from History and writes it through `Pasteboard`; per R4 a background action cannot write the clipboard, so make it a foreground action (it opens LocalFlow) or verify on the device first. Set it as the `UNUserNotificationCenter` delegate in `apps/ios/App/PhoneServices.swift`.
- [ ] T067 [US6] Add a "Notify when a note is ready" toggle to `apps/ios/App/Features/Settings/SettingsView.swift`, bound to `notifications.dictationResults` (Bool, default false); turning it on asks for notification permission in the foreground (research R5).
- [ ] T068 [US6] Add `LocalFlowShortcuts: AppShortcutsProvider` to `apps/ios/App/LocalFlowPhoneApp.swift`: `ToggleDictationIntent` with "Dictate a \(.applicationName) note", "Start \(.applicationName)", "Stop \(.applicationName)"; `EndSessionIntent` with "End \(.applicationName) session".
- [ ] T069 [US6] In the keyboard, read `dictation_source` in `apps/ios/Shared/KeyboardLogic/KeyboardSessionModel.swift`: with no pending request and `control`, show "LocalFlow is recording elsewhere" in the bar and keep the mic disabled until `ready` (contract `session.json`).
- [ ] T070 [US6] Show the control's stop → result time in `apps/ios/App/Features/Settings/DiagnosticsView.swift` (plan principle 13).
- [ ] T071 [US6] Run quickstart §7 on the iPhone 16 Pro (SC-008 ten Action Button runs from the locked Lock Screen, including with LocalFlow killed, SC-009 Live Activity visible each time, Siri and Shortcuts, control during a keyboard dictation and during a `ready` keyboard session (not covered by the spike), notification Copy while locked, Live Activities off, model deleted, before first unlock) and record in `specs/017-ios-keyboard-entry-points/acceptance/control.md`.

**Checkpoint**: all six stories accepted on the device.

---

## Phase 12: Polish, resource report and docs

- [ ] T072 [P] Update `docs/architecture/overview.md` with the third iOS target, the `Intents/` folder and the intent → app process path.
- [ ] T073 [P] Update `apps/ios/README.md`: the `Widgets/` and `Intents/` folders, and the setting `notifications.dictationResults` in the "What lives where" table.
- [ ] T074 [P] Add the widget extension to the scope of `THIRD_PARTY_NOTICES.md` (it bundles the same two fonts).
- [ ] T075 Run quickstart §8 on the iPhone 16 Pro and add to `docs/performance/ios-dictation.md`: the keyboard footprints from T045, the app footprint in a `Never` session idle and while recording, the footprint after a memory warning in a `Never` session (model released), the control's stop → result times from T071, and the widget extension footprint or "not measured". Nothing goes in that was not measured.
- [ ] T076 Run `make check` and `make ios` (`Makefile`); confirm the import check covers Widgets and Intents, the Sotto token check passes, and the migration list ends with `phone-dictations-v2` (SC-011).

---

## Dependencies and execution order

### Phases

- **Phase 1 (spike)**: blocks everything. T001 → T002, T003 → T004 → T005.
- **Phase 2 (ADR)**: after Phase 1. T007, T008 in parallel after or alongside T006 (T009 done during analyze).
- **Phase 3 (foundation)**: after Phase 2. T011 before T016; T012 before T014.
- **US1 (Phase 4)**: removed.
- **US2 (Phase 5)**: after Phase 3.
- **US3 (Phase 6)**: after US2 for the same file; T036 and T031 both edit `KeyboardSessionModel.swift`.
- **US4 (Phase 7)**: after Phase 3 for T041–T042 (app-only files); T043 needs US2 and US3 on the device.
- **Phase 8**: after US2–US4. Gates milestone B.
- **Phase 9**: after Phase 8.
- **US5 (Phase 10)**: after Phase 9.
- **US6 (Phase 11)**: after Phase 9 and after US5 for `PhoneIntentHandler.swift`, `LocalFlowWidgets.swift` and `DictationLiveActivity.swift`.
- **Phase 12**: after the stories that ship.

### Within each story

Tests first and failing, then pure models, then views and controller wiring, then the device run.

### Parallel opportunities

- Phase 2: T007, T008.
- Phase 3: T010, T013, T015 (three test files).
- US2: T028, T029 (tests); T030 and T032.
- US3: T037 alongside T036.
- US4: T041 and T042 can run alongside US2–US3 (app-only files).
- Phase 9: T046, T050, T051.
- US5: T053, T054; T058 alongside T055–T057.
- US6: T065 alongside T062–T064.
- Phase 12: T072, T073, T074.

## Implementation strategy

### MVP

Phases 1–5: the spike, the ADR, the foundation and US2. The top bar with End session and the session status is useful on its own, with 016's dictation still working through the mic.

### Incremental delivery

1. US2 and US3 → keyboard dictation in the new layout.
3. US4 → Never. Milestone A complete after T043 and T045; it can ship here.
4. Phase 9 and US5 → Live Activity.
5. US6 → the control, Shortcuts and notifications.
6. Phase 12 → resource report.

## LocalFlow required coverage

- Lifecycle and cancellation: T013, T015, T035 (cancel, stop on disappear, not running), T061 (toggle in every state, one recording at a time).
- Bounded queues and overload: one Live Activity (T053), one pending save and one pending clipboard write (T061, T064), 5-minute cap (T035, T061).
- Offline and recovery: the keyboard makes no network request (import check T008); pending save before first unlock (T061, T062); orphan spool recovery from 016 covers control dictations.
- Instrumentation: per-surface keyboard footprint (T044), control stop → result time (T070).
- Hardware acceptance: T004, T043, T045, T060, T071, T075. None is marked done from mocks or simulator builds.
