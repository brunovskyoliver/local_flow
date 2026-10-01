# Contract: system entry points (intents, control, Live Activity, notification)

This covers what LocalFlow exposes to iOS outside the keyboard: App Intents, one control, App Shortcuts, the Live Activity and its buttons, and the result notification.

## Targets and files

| Code | Compiled into | Imports allowed |
| --- | --- | --- |
| `apps/ios/Intents/` (intent types, `IntentHandler` protocol, `DictationActivityAttributes`) | app, widget extension | Foundation, AppIntents, ActivityKit |
| `apps/ios/Widgets/` (control, Live Activity views, widget bundle) | widget extension | SwiftUI, WidgetKit, AppIntents, ActivityKit |
| `apps/ios/App/System/` (handler implementation, activity and notification owners) | app | anything the app uses |

The keyboard compiles neither `Intents/` nor `Widgets/`. `make check` enforces this list (research R11).

## Intents

All intents run in the app process (research R2). `perform()` resolves `@Dependency var handler: IntentHandler`. If no handler is registered (the widget process), it throws `LocalFlowIntentError.unavailable`.

| Intent | Protocols | Title | Effect |
| --- | --- | --- | --- |
| `ToggleDictationIntent` | `AudioRecordingIntent`, `LiveActivityIntent` (spike: without it `perform()` runs in the widget extension) | "Dictate a LocalFlow note" | Start or stop as in research R1. Returns a dialog: "Recording", "Stopped", or the reason it could not start |
| `EndSessionIntent` | `LiveActivityIntent` | "End LocalFlow session" | `end(.userEnded)`. No-op without a session |
| `CopyLastDictationIntent` | `LiveActivityIntent` | "Copy last LocalFlow dictation" | Writes the last transcript to the clipboard (research R4; a background write was dropped in the spike, so this is checked on the device and falls back to the pending write applied when LocalFlow is active). Marks a `control` row `copied` |

`IntentHandler`:

```swift
protocol IntentHandler: Sendable {
  func toggleDictation() async throws -> ToggleOutcome   // .started, .stopped
  func endSession() async
  func copyLast() async throws
}
```

Errors shown to the owner (`LocalFlowIntentError`, `CustomLocalizedStringResourceConvertible`):

| Case | Text |
| --- | --- |
| `liveActivitiesOff` | "Turn on Live Activities for LocalFlow in Settings to record from here." |
| `modelMissing` | "LocalFlow needs its speech model. Open LocalFlow to download it." |
| `microphoneDenied` | "LocalFlow can't use the microphone. Open LocalFlow to allow it." |
| `pendingSave` | "Unlock your iPhone so LocalFlow can save the last dictation." |
| `nothingToCopy` | "There is no dictation to copy yet." |
| `unavailable` | "LocalFlow couldn't run this. Open LocalFlow and try again." |

A missing model or microphone permission also posts a notification when notifications are allowed (spec edge case).

## App Shortcuts

`LocalFlowShortcuts: AppShortcutsProvider` in the app:

- `ToggleDictationIntent`: "Dictate a \(.applicationName) note", "Start \(.applicationName)", "Stop \(.applicationName)"
- `EndSessionIntent`: "End \(.applicationName) session"

## Control

`DictationControl: ControlWidget`, kind `app.localflow.control.dictate`, a `ControlWidgetButton(action: ToggleDictationIntent())` with the label "LocalFlow" and the `mic.fill` symbol. It can be placed in Control Center and on the Lock Screen, and assigned to the Action Button.

ponytail: a button, not a toggle. The Live Activity shows whether it is recording. A toggle would need a value provider reading the App Group from the widget; add one if the owner wants the control itself to show the state.

## Live Activity

`DictationActivityAttributes` is defined in [data-model.md §3](../data-model.md).

| Presentation | Shows |
| --- | --- |
| Lock Screen / banner | Phase label (Ready · Recording · Transcribing · Copied), elapsed session time, remaining time or "No timeout", Stop; in `result`, the 120-character preview and Copy |
| Dynamic Island compact | leading: mic glyph tinted by phase; trailing: recording timer while recording, else remaining time or ∞ |
| Dynamic Island minimal | mic glyph tinted by phase |
| Dynamic Island expanded | as the Lock Screen |

Buttons: Stop → `EndSessionIntent` for a session activity, `ToggleDictationIntent` while a control recording runs. Copy → `CopyLastDictationIntent`.

Timers use `Text(timerInterval:countsDown:)`. Styling uses Sotto colours and fonts from `Shared/Sotto`; the system draws the glass.

Owner: `ActivityController` in `App/System/`, observing `SessionController.onChange`. It starts, updates and ends the activity as in research R3 and logs only phases and IDs.

## Notification

- Category `dictation.result`, action `copy` ("Copy", `.authenticationRequired` not set, runs in the background).
- Posted after a `control` dictation when `notifications.dictationResults` is on and permission is granted.
- Title "LocalFlow note", body the first 120 characters, thread `localflow.dictation`.
- The `copy` action writes the full transcript, read by dictation ID from History, to the clipboard. Per research R4 it is a foreground action unless the device shows a background write works.

## Tests

`LocalFlowPhoneTests` with a fake activity requester, a fake pasteboard and a fake notification centre:

- toggle with no session, with a ready session, during a keyboard recording, during a control recording
- toggle refused when Live Activities are off (nothing records, FR-030)
- one activity at a time; activity ends with the session; control result card dismissal set
- `copied` delivery written after a successful clipboard write and not after a failed one
- pending save before first unlock blocks a second control dictation
