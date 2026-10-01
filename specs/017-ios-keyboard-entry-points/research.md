# Research: full dictation keyboard and system entry points

Each entry gives the decision, why, and what else was considered. Items marked **spike** depend on the device and are settled in build step 1 (plan.md) before the code that relies on them. Each one has a fallback written down here.

## R1. Starting a recording from the Action Button, Control Center or a Shortcut (spike)

**Decision**: One intent, `ToggleDictationIntent`, adopts `AudioRecordingIntent` and runs in the app process. It acts on the state it finds:

| State when pressed | Action | Brings LocalFlow forward? |
| --- | --- | --- |
| A dictation is recording (any source) | Stop it. A keyboard dictation finishes into the keyboard as usual (US6 AS6) | No |
| A session is `ready` (engine already running) | Start a `control` dictation in that session | No |
| No session | Start a one-shot `control` session and its dictation | **To be decided by the spike** (below) |

The intent starts or updates the Live Activity before recording begins. If `ActivityAuthorizationInfo().areActivitiesEnabled` is false, or the request fails, it throws a user-facing error and records nothing (FR-030).

**Spike question**: can the intent activate the audio session and start the engine while LocalFlow is not running or is suspended in the background? Apple's documentation says only that an `AudioRecordingIntent` must start a Live Activity and keep it for the whole recording. A 2026 developer-forum thread ([815725](https://developer.apple.com/forums/thread/815725)) reports "Live Activity start failed … Target is not foreground" from the Action Button and says recording cannot be started from a cold background state. The spike tests this on the iPhone 16 Pro (iOS 26) from three places: the locked Lock Screen, Control Center over another app, and the Action Button with LocalFlow killed.

**Fallback if the spike fails** (no session case only): the intent declares that it must open the app (`supportedModes = .foreground` / `openAppWhenRun`). LocalFlow comes forward on the session screen, starts the session and the recording, and starts the Live Activity in the foreground. The owner can lock the phone or go back, and the recording continues in the background as keyboard sessions already do. The second press stops it without bringing the app forward, because the engine is running by then. US6 AS1 ("without bringing LocalFlow to the front") then holds only while a session is running. The acceptance report and the spec are updated to say so; this is not hidden.

**Spike result (2026-10-01, iPhone 16 Pro, iOS 27.0.1, acceptance/spike.md runs 1–3)**: the background path works and the fallback is **not** used. A press with LocalFlow killed launches it in the background (`applicationState == .background`), the Live Activity request succeeds there, and the recording starts. Two changes follow:

- `ToggleDictationIntent` conforms to `LiveActivityIntent` as well as `AudioRecordingIntent`. With `AudioRecordingIntent` alone, every press ran `perform()` in the widget extension, including with a session running (run 1).
- On a cold launch the handler awaits the launch model check before `SessionController.open`. Without it the first press found the model not yet ready and ended the session with `modelUnavailable` (run 2).

Open: one of two cold-start recordings in run 3 ended `failed` in transcription, cause not captured. T071 measures SC-008 (9 of 10) and logs the failure detail. The press-during-a-keyboard-session row was not exercised.

**Rationale**: the running-session path needs no new platform permission. The engine already runs in the background under `UIBackgroundModes=audio` (proven in 016), so it is expected to work whichever way the spike goes. Only the cold start is uncertain.

**Alternatives**: a push-to-start Live Activity (needs a server and APNs; ruled out by principle 4 and scope). A `LiveActivityIntent` without `AudioRecordingIntent` (it gives no recording privilege). Two separate Start and Stop intents (the Action Button holds one action, and the spec asks for press to start, press to stop).

## R2. Where intents run, and keeping the widget extension free of speech code

**Decision**: Intent types are declared in `apps/ios/Intents/`, compiled into both the app and the widget extension, because the control and the Live Activity buttons must name the intent type. Their `perform()` calls an `IntentHandler` protocol obtained through `@Dependency` (`AppDependencyManager`). Only the app registers an implementation, in `PhoneServices`. The intents adopt `AudioRecordingIntent` or `LiveActivityIntent`, which the system runs in the app process. If the widget ever ran `perform()` itself, the dependency lookup would fail and the intent would return an error instead of doing anything.

**Spike correction (2026-10-01)**: the system does **not** run an `AudioRecordingIntent` in the app process just because the type is compiled into both targets. On iOS 27.0.1 it ran in the widget extension until the intent also conformed to `LiveActivityIntent`. Every intent in `Intents/` that must reach the app therefore adopts `LiveActivityIntent` (the toggle) or is already one (End session, Copy).

**Rationale**: the widget extension links neither package product and runs no audio, the same boundary as the keyboard. A new import check enforces it (R11).

**Alternatives**: duplicate intent types per target (they must be the same type for the system to route them). Moving `SessionController` into a framework shared with the widget (it would put the speech stack in an extension for no benefit).

## R3. Live Activity lifetime and updates

**Decision**:
- A keyboard session starts its Live Activity when the session starts. The keyboard URL opens the app in the foreground, so the request is allowed.
- A control-started recording starts it inside the intent (R1).
- The app updates the activity locally on state changes only: `idle`, `recording`, `transcribing`, `result`. Elapsed and remaining time use `Text(timerInterval:countsDown:)`, so the system draws the seconds and the app sends no update per second.
- The activity ends with the session (dismissal `.immediate`). A control-started dictation ends with a result card instead (dismissal `.after(now + 5 min)`).
- The content state is under 1 KB. The transcript preview is cut to 120 characters.
- **The 8-hour limit**: iOS ends an activity after 8 hours. A `Never` session continues without it (spec edge case). The app cannot start a new activity from the background except inside an intent (R1, R1 sources), so the activity returns the next time the app comes forward or a control recording starts. It does **not** return at the next keyboard recording, as the spec's edge case had assumed. Spec edge case to correct in analyze: "returns when LocalFlow next opens or the control is used."

**Alternatives**: updating once a second (wastes the update budget and battery). Push updates (needs a server).

## R4. Copy and the clipboard from the background (spike)

**Decision**: Copy in the Live Activity and in the notification runs `CopyLastDictationIntent` / a background notification action in the app process and writes `UIPasteboard.general.string`. After a control-started dictation the app writes the clipboard itself when the text is ready. Writing does not trigger the paste prompt; only reading does.

**Spike**: confirm the write succeeds while the app is in the background and while the phone is locked. **Fallback**: keep the text pending in memory (one entry) and write it on `protectedDataDidBecomeAvailable` or when the app becomes active; the Live Activity says "Copy after unlocking". The text is in History either way.

**Spike result (2026-10-01, acceptance/spike.md runs 2–3)**: the write is dropped whenever the app is in the background, locked or not (`changeCount` unchanged, `hasStrings` false). Writes while the app was `inactive` (Control Center over LocalFlow) or `active` succeeded. **Fallback taken**, narrowed: keep one pending write and apply it when the app becomes active (`protectedDataDidBecomeAvailable` alone is not enough). Inferred, not tested: the Live Activity's Copy and the notification's Copy action also run with the app in the background, so they most likely cannot write the clipboard directly either and need to bring LocalFlow forward (for example a `ForegroundContinuableIntent` or opening the app), which T056, T064 and T066 must account for. The spec's FR on automatic copy after a control dictation needs the same correction.

## R5. Notifications

**Decision**: one local notification per control-started dictation, category `dictation.result` with a background "Copy" action. Body: the first 120 characters. Permission is asked from a toggle in Settings (the system prompt shows only in the foreground), never from the intent. Without permission, the Live Activity card is the only offer, which FR-031 allows.

## R6. The "Never" timeout

**Decision**: `IdleTimeout.never` (raw value `never`). `seconds` becomes optional; `never` gives nil, so `setReady()` stores no deadline and `tick()` never ends the session. Nothing else in the session machine changes. The mic indicator stays on because the engine runs for the whole session, as in 016.

**Memory**: a `Never` session keeps the model ready all day. A memory warning while not recording already drops the keep-ready holds (016); the next dictation reloads the model. The app's footprint in a `Never` session is measured (SC-003 resource note), not assumed.

## R7. Keyboard UI technology and key handling

**Decision (2026-10-01, after the spike)**: the keyboard has no letter keys. The owner tried the SwiftUI key-grid prototype on the iPhone 16 Pro and rejected it: the layout was poorly structured, they mistyped often, touches were misrecognised and some letters seemed lost (owner-attested, acceptance/spike.md). Offered a UIKit key grid, a dictation-only keyboard or KeyboardKit, they chose dictation-only. User Story 1, R8 and R9 leave the feature. The keyboard stays SwiftUI: top bar, listening view and the 016 key row.

**Original plan**: SwiftUI keys as plain views with one `DragGesture(minimumDistance: 0)` each, with a UIKit key grid as the fallback. KeyboardKit was rejected under principle 14.

## R8. Autocorrect and suggestions

**Removed (2026-10-01)** with User Story 1 (R7). There is no autocorrect, no suggestion strip and no `lexicon.json`.

## R9. Layouts, field traits and the default layout

**Removed (2026-10-01)** with User Story 1 (R7). The 016 key row stays as it is.

## R10. Keyboard height and the listening view

**Decision**: one fixed height for the whole keyboard (top bar 48 pt plus the 016 key row, sized for the listening view), set with a height constraint at priority 999 on the input view, so swapping the keys for the listening view never resizes the keyboard or makes the host relayout. The listening view fills the same rect (FR-017): ✕ top left, ✓ top right, the empty slot left of ✓ reserved for 018, the 15-bar waveform centred at about 3× the capsule size, "Listening · 0:03" and the input name under it, and the globe key bottom left when `needsInputModeSwitchKey`.

- Waveform: the last 15 of the 31 `levels.bin` slots, drawn like the Mac's `DictationIndicator` (15 bars). `RollingWave` is reused for transcribing.
- Elapsed time: from the new `recording_started_at` in `session.json`, drawn by `TimelineView(.periodic(by: 1))`. From 4:30 the status line becomes "Stops at 5:00 · 0:24 left" (FR-021). The app already stops at 5:00 (`duration_limit`).
- Input name: the new `input_name` in `session.json`, from `AVAudioSession.currentRoute.inputs.first?.portName` ("iPhone Microphone", or the headset's name).
- A start with no answer: if `session.json` has not reached `recording` within 2 s of the start request, the area shows "LocalFlow isn't running" with Start LocalFlow (US3 AS5).
- Dismissing the keyboard while recording sends `stop` (spec edge case). The result then follows the 016 rules and is offered as "Insert last dictation".

## R11. Build boundaries and checks

**Decision**:
- The widget extension (`LocalFlowWidgets`) compiles `apps/ios/Widgets`, `apps/ios/Intents` and the Sotto files from `apps/ios/Shared/Sotto`. It does not link the package products.
- `scripts/check-keyboard-imports.sh` also covers `apps/ios/Widgets` and `apps/ios/Intents`, and bans `AVFAudio`/`AVFoundation` there as well.
- The keyboard must not compile `apps/ios/Intents` or `ActivityKit` code; the script also checks that `apps/ios/Shared` and `apps/ios/Keyboard` import neither `ActivityKit` nor `AppIntents`.
- Sotto token check unchanged.

## R12. Signing and the new App ID

**Decision**: bundle ID `$(LOCALFLOW_BUNDLE_PREFIX).LocalFlow.Widgets` on team 944A459UC3, entitlement for the existing App Group (the widget reads nothing from it in this feature, but the Live Activity's Copy fallback and future control state will). Registration happens once, in the spike, as the spec's signing assumption approved. `Signing.local.xcconfig` is unchanged; only the new target uses its values. The app gains `NSSupportsLiveActivities = YES`.

## R13. Handoff contract changes stay at version 1

**Decision**: the app and keyboard ship in one bundle, so they never run different contract versions. The changes are additive: optional fields in `session.json`, one new request kind (`end`), and one new idle-timeout value (`never`). The `lexicon.json` file planned here was dropped with User Story 1. Readers already ignore unknown keys. `v` stays 1. See [contracts/keyboard-handoff-v1-additions.md](contracts/keyboard-handoff-v1-additions.md).

## R14. Release split

**Decision**: one plan, two milestones. Milestone A (US1–US4, all P1) is a complete release on its own and is accepted on the device before milestone B (US5–US6) starts. If the spike in R1 fails badly enough that US6 needs rethinking, milestone B moves to its own feature as the spec allows, and A ships unchanged.
