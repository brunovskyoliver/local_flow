# Implementation plan: full dictation keyboard and system entry points

**Branch**: `017-ios-keyboard-entry-points` | **Date**: 2026-10-01 | **Spec**: [spec.md](spec.md)

## Summary

The 016 keyboard is a dictation capsule. This feature gives it a top bar and a full-keyboard listening view, and adds ways to dictate without a keyboard. **Scope change (2026-10-01)**: the owner rejected the typing prototype and chose a dictation-only keyboard (research R7). User Story 1 is removed; typing stays with the Apple keyboard.

**Milestone A (US2–US4, P1)** changes the keyboard and the session only:

- A top bar with ☰ drawer, status and a large mic.
- A listening view that replaces the bar and the 016 key row at a fixed keyboard height.
- A `never` idle timeout.

The handoff contract stays at version 1 with additive fields ([contract](contracts/keyboard-handoff-v1-additions.md)).

**Milestone B (US5–US6, P2)** adds a widget extension with a Live Activity and a control, plus three App Intents that run in the app process ([contract](contracts/system-entry-points.md)). The spike (research R1, R2, R4) showed the control works from a cold start in the background once the intent also adopts `LiveActivityIntent`, and that clipboard writes from the background are dropped.

## Technical context

| Item | Decision |
| --- | --- |
| Language | Swift 6.0, language mode 6 |
| Targets | `LocalFlowPhone` app, `LocalFlowKeyboard` extension, new `LocalFlowWidgets` extension (WidgetKit: control and Live Activity). iOS 26.0, iPhone only |
| Dependencies | None new. GRDB 7.10.0 and FluidAudio 0.15.7 stay app-only |
| Apple frameworks | Keyboard: SwiftUI, UIKit (`UIInputViewController`). App adds ActivityKit, AppIntents, UserNotifications. Widgets: SwiftUI, WidgetKit, ActivityKit, AppIntents |
| Storage | Migration `phone-dictations-v2` (adds `control` and `copied`). New setting `notifications.dictationResults` ([data-model.md](data-model.md)) |
| Testing | `LocalFlowPhoneTests` on the simulator: handoff additions, intent handler with fake activity, pasteboard and notification centres. Device acceptance per [quickstart.md](quickstart.md) |
| Performance goals | SC-008 text within 3 s of the second press in 9 of 10; end session indicator off within 10 s |
| Constraints | Keyboard under 40 MB at rest and listening. No microphone, speech, storage or network code in the keyboard or the widget extension. No private API to open or return to apps. 5-minute recording cap. Live Activity limit about 8 h |
| Scale | One owner, one device, one recording at a time |
| Unknowns | None unresolved in the design. The device-dependent ones are spike items with written fallbacks: R1 cold-start control, R4 clipboard while locked, R7 key handling under fast typing |

## Constitution check

Gate before Phase 0: **pass, with one ADR required (ADR 0030)**. A third iOS target and a background recording entry point change the source boundaries that ADR 0029 and `AGENTS.md` describe (app plus keyboard). This is a change to an ADR-recorded decision, not an exception to a principle.

| Principle | Result |
| --- | --- |
| 1 Native lightweight client | Pass. SwiftUI, UIKit, WidgetKit, ActivityKit, AppIntents. No web views or bundled language models |
| 2 Memory efficiency | Pass. Every new buffer has a bound (table below). Keyboard numbers are measured (SC-003), not assumed. A `Never` session keeps the 016 keep-ready rules, including dropping the model on memory warning |
| 3 Explicit model lifecycle | Pass. Control dictations go through the same `SessionController` and `ModelLifecycleCoordinator` lease as keyboard ones. Intents, the widget and the Live Activity never touch models |
| 4 Local-first | Pass. Dictation and the control work offline. No push, no server |
| 5 Privacy by architecture | Pass. Nothing typed in the key row is logged or written. Secure fields keep nothing. Transcript text outside the app container: `result.json` (016 rules), the Live Activity preview and the notification body (120 characters, on device). `lexicon.json` holds Dictionary terms only. Logs carry IDs, states and durations |
| 6 Streaming over accumulation | Pass. Capture unchanged; the 19.2 MB spool and 5-minute cap apply to control dictations too |
| 7 Simple persistence | Pass. One GRDB migration with a table rebuild, needed for the new check values. No new store |
| 8 Server isolation | Not affected |
| 9 Recoverability | Pass. Spool recovery from 016 covers control dictations. A save that fails before first unlock is held (one) and retried. Every text ends in History, the keyboard, the clipboard or a pending save (SC-010) |
| 10 Speaker attribution | Not affected |
| 11 Structured LLM output | Not affected |
| 12 Testability | Pass. Pure `Autocorrector` behind `SpellChecking`. Layout and shift as value types. `IntentHandler`, activity requester, pasteboard and notification centre behind protocols with fakes |
| 13 Local observability | Pass. Diagnostics adds keyboard footprint per surface (rest, listening) from `keyboard-status.json` and the control's stop→result time. Report in `docs/performance/ios-dictation.md` |
| 14 Scope discipline | Pass. No KeyboardKit, no swipe typing, no language model, no style pill, no sync. The control is a button, not a toggle. One widget extension for both the control and the Live Activity |
| 15 Authenticated server access | Not affected |

**App Review 2.5.4**: background audio stays a visible, user-started recording feature. Every session starts from an owner action, the mic indicator is on throughout, and a control recording always has a Live Activity (FR-030). ADR 0030 records this.

Re-check after Phase 1 design: **unchanged, pass.** The design needs ADR 0030 and nothing else.

## Project structure

### Documentation

```text
specs/017-ios-keyboard-entry-points/
├── spec.md, plan.md, research.md, data-model.md, quickstart.md
├── contracts/keyboard-handoff-v1-additions.md
├── contracts/system-entry-points.md
├── reference/wispr-listening.png
├── checklists/requirements.md
└── acceptance/                       device runs (created during acceptance)
docs/adr/0030-ios-system-entry-points.md          new
docs/architecture/overview.md                      updated: third iOS target
docs/performance/ios-dictation.md                  keyboard surfaces, Never session, control timing
AGENTS.md                                          names the widget extension among the iOS targets
```

### Source

```text
apps/ios/
├── Shared/                               app + keyboard (Foundation/SwiftUI only)
│   ├── Handoff/HandoffModels.swift       session fields, `end`, `never`, LexiconFile
│   ├── KeyboardLogic/
│   │   ├── KeyboardSessionModel.swift    surface, cancel, end, not-running check, stop on disappear
│   │   └── BarStatus.swift               new: "Listening · m:ss" strings
│   └── Sotto/WaveformViews.swift         adds a large 15-bar waveform; also compiled into Widgets
├── Keyboard/
│   ├── KeyboardViewController.swift      traits, fixed height, stop on disappear, settings URL
│   ├── KeyboardView.swift                top bar + 016 key row, or listening view
│   ├── ListeningView.swift               new
│   ├── DrawerView.swift                  new
├── Intents/                              new; app + widgets
│   ├── DictationIntents.swift            Toggle, EndSession, CopyLast; IntentHandler; errors
│   └── DictationActivityAttributes.swift
├── Widgets/                              new target LocalFlowWidgets
│   ├── LocalFlowWidgets.swift            WidgetBundle
│   ├── DictationControl.swift
│   └── DictationLiveActivity.swift
├── App/
│   ├── Session/SessionController.swift   control origin/source, never, recordingStartedAt, inputName, lastResult
│   ├── Session/IdleTimer.swift           IdleTimeout.never
│   ├── Session/HandoffServer.swift       `end`, new session fields
│   ├── Storage/PhoneMigrations.swift     phone-dictations-v2
│   ├── Storage/PhoneDictationStore.swift control, copied, pending save
│   ├── System/                           new: PhoneIntentHandler, ActivityController, ResultNotifier, Pasteboard
│   ├── Features/Session/SessionView.swift  Never wording, prominent End session
│   ├── Features/Settings/SettingsView.swift Never, notifications toggle, Live Activities hint
│   └── LocalFlowPhoneApp.swift           `localflow://settings`, AppShortcutsProvider, dependency registration
├── Config/
│   ├── Widgets-Info.plist, LocalFlowWidgets.entitlements   new
│   └── App-Info.plist                    NSSupportsLiveActivities
└── LocalFlowPhoneTests/                  new tests per the contracts

scripts/check-keyboard-imports.sh         covers Widgets and Intents; bans ActivityKit/AppIntents in Keyboard and Shared
```

**Structure decision**: keep the three-folder rule from 016 and add two folders: `Intents/` (types shared by the app and the widget) and `Widgets/` (the extension). Code shared by the app and keyboard stays in `Shared/`. The keyboard logic grows as pure files in `Shared/KeyboardLogic/` so the app's test target covers it, and UIKit-only pieces stay in `Keyboard/`.

## Build order

1. **Spike** ([quickstart §2](quickstart.md)). Register the widget App ID, then build a minimal control running `ToggleDictationIntent`, a clipboard write test and a key-grid prototype. Record the results and choose the fallbacks from research R1, R4 and R7.
2. **ADR 0030** and the `AGENTS.md` line.
3. **Milestone A**
   1. Handoff additions, `never`, and the session fields (app and codec tests).
   3. Top bar, drawer and listening view; the not-running, cancel and stop-on-disappear paths.
   4. Session screen and Settings for Never.
   5. Device acceptance §3–§5 and the keyboard footprint readings.
4. **Milestone B**
   1. Migration v2 and the store changes.
   2. Intents and handler with fakes.
   3. Widget target, Live Activity and control.
   4. Notifications and Shortcuts.
   5. Device acceptance §6–§7.
5. **Resource report** (quickstart §8).

If the spike shows that US6 cannot work as specified even with the fallback, milestone B leaves this feature (spec assumption) and milestone A ships alone.

## Bounds and overload behaviour

| Part | Capacity | Overload policy |
| --- | --- | --- |
| Recordings | 1 across keyboard, app and control | Keyboard start → `busy`; control press → stops the current one |
| Recording length | 5 min, warning from 4:30 | Stop and deliver (016 `duration_limit`) |
| Suggestions | 3 | Rest dropped |
| Live Activities | 1 | Older ended before a new request |
| Live Activity updates | One per phase change | No per-second updates; timers drawn by the system |
| Pending clipboard write | 1 | Newest wins |
| Pending History save | 1 | Next control dictation refused until saved |
| Not-running check | 2 s after start | "LocalFlow isn't running" notice |
| Result wait | 15 s after stop (016) | "LocalFlow stopped" message; text recovered by the app |

## Model ownership and release

No change from 016. Control dictations acquire and finish a lease like keyboard ones. A `control` session holds `keepReady(.session)` only while it lasts and releases it at once when it ends. A `Never` session holds it until the owner ends it or a memory warning drops it while not recording; the next dictation then reloads the model and waits for it. Release evidence: the diagnostics snapshot and the footprint after a memory warning in a `Never` session, recorded in the resource report.

## Privacy

- Nothing typed in the key row is logged, written or sent. Secure fields keep nothing.
- The keyboard and the widget extension make no network requests, by the import check.
- Transcript text appears outside the app container only in:
  - `result.json` (016 rules)
  - the Live Activity preview: 120 characters, ended with the activity or 5 minutes after a control result
  - the optional notification body: 120 characters
  - the clipboard, only after a control dictation or a Copy tap, which the owner chose

## Recovery and persistence

- History is written before any delivery, as in 016. A save that fails before the first unlock is held, retried, and blocks a second control dictation until it succeeds. Its spool is kept until then, so a process death leaves an orphan that 016 recovery re-transcribes (principle 9).
- An app killed during a control recording leaves a spool that 016 recovers on next launch; the Live Activity ends with the process and nothing claims a session is alive (spec edge case).
- A keyboard dismissed while recording sends `stop`; the result is offered next time.
- Migration v2 runs in one transaction and keeps every row.

## Dependencies and licences

No new third-party code. Apple frameworks only. Fonts and their OFL notices are already bundled; the widget extension bundles the same two font files, and `THIRD_PARTY_NOTICES.md` gains the widget extension in its scope.

## Validation

- **Automated**: `make check`, including the import and token checks, the frozen migration list, and the new unit tests in both contracts.
- **Device**: [quickstart.md](quickstart.md) §2–§7, recorded in `acceptance/`.
- **Resources**: quickstart §8. Keyboard SC-003 readings are acceptance criteria, measured on the iPhone 16 Pro.

## Complexity tracking

| Item | Why needed | Simpler alternative rejected because |
| --- | --- | --- |
| Third iOS target `LocalFlowWidgets` (ADR 0030) | Controls and Live Activities can only be supplied by a WidgetKit extension (US5, US6) | Putting them in the app or keyboard is not possible on iOS |
| `Intents/` folder compiled into two targets | The control and Live Activity buttons must name the intent type, and the intent must run in the app | One copy per target gives two distinct types that the system cannot route to the app |
| `phone-dictations-v2` table rebuild | New `source` and `delivery` values are blocked by `CHECK` constraints | Dropping the constraints loses validation; a second table splits one fact in two |
