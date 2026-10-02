# 0030: iOS system entry points in a widget extension

## Status

Accepted, 2026-10-01. Extends ADR 0029. The cold-start and clipboard spike ran on the iPhone 16 Pro, iOS 27.0.1 (Feature 017, `specs/017-ios-keyboard-entry-points/acceptance/spike.md`).

## Context

ADR 0029 gave the iOS companion two targets: the `LocalFlowPhone` app and the `LocalFlowKeyboard` extension. Feature 017 lets the owner dictate without a text field, from Control Center, the Lock Screen, the Action Button or a Shortcut, and shows the session in a Live Activity on the Lock Screen and in the Dynamic Island. iOS takes controls and Live Activity views only from a WidgetKit extension, so neither the app nor the keyboard can supply them.

A control button and a Live Activity button name an App Intent type, and that type has to be the same one the app handles. The speech stack (`LocalFlowSpeech`, `LocalFlowCore`, FluidAudio, GRDB) must stay in the app, as it does for the keyboard.

App Review guideline 2.5.4 allows background audio only for a feature the user can see. LocalFlow already records in the background under `UIBackgroundModes=audio` during a keyboard session (Feature 016).

## Decision

- **A third iOS target, `LocalFlowWidgets`**, a WidgetKit extension embedded in `LocalFlowPhone`. Bundle ID `$(LOCALFLOW_BUNDLE_PREFIX).LocalFlow.Widgets` on the existing team, entitlement for the existing App Group. It holds the dictation control and the Live Activity views. It links neither `LocalFlowCore` nor `LocalFlowSpeech` and runs no audio.
- **Intent types live in `apps/ios/Intents/`, compiled into both the app and the widget.** Both targets then see one type, which the system routes to the app. `perform()` calls an `IntentHandler` protocol through a static slot, `IntentHandlers.current`, which only the app sets, at launch (`PhoneApp`). If the widget ever ran `perform()`, the slot would be nil and the intent would return an error without recording. `@Dependency` (`AppDependencyManager`) was the first plan, but it traps when nothing is registered, which is exactly the widget's case; the spike used the static slot on the device.
- **Every intent that must reach the app adopts `LiveActivityIntent`.** The dictation toggle adopts both `AudioRecordingIntent` and `LiveActivityIntent`. In spike run 1 the toggle conformed to `AudioRecordingIntent` alone, and on iOS 27.0.1 every press ran `perform()` in the widget extension, with the app killed and with a session running. Adding `LiveActivityIntent` moved `perform()` into the app process (runs 2 and 3).
- **A cold start records in the background, with no `openAppWhenRun` fallback.** A press with LocalFlow killed launches it in the background, the Live Activity request succeeds there, and recording starts (spike run 3, two of two). The handler awaits the launch model check before it opens the session; without that wait the first cold press ended with `modelUnavailable` (run 2). The intent does not declare that it opens the app.
- **Background recording is only ever a visible recording the owner started** (FR-030). The intent starts or updates the Live Activity before recording begins and keeps it for the whole recording. If Live Activities are off or the request fails, the intent throws a user-facing error and records nothing. Recordings stop at 5 minutes.
- **Background clipboard writes are dropped, so the app holds one pending write.** In runs 2 and 3 every `UIPasteboard` write with the app in the background was lost (`changeCount` unchanged), locked or not; writes while the app was inactive or active worked. After a control dictation the app keeps the newest transcript as a pending write and applies it when LocalFlow becomes active. The text is in History either way, and the Live Activity says the text is copied when LocalFlow opens.
- **The widget compiles only `apps/ios/Shared/Sotto/` from `Shared`.** The `Shared` synchronized group excludes the other files one by one in the project's membership exceptions for `LocalFlowWidgets`; folder-level exceptions were ignored by Xcode. A new file in `Shared` outside `Sotto/` therefore joins the widget until it is added to that list.
- **`scripts/check-keyboard-imports.sh` enforces the boundary in `make check`:** no `Network`, `FluidAudio`, `GRDB`, `LocalFlowCore`, `LocalFlowSpeech`, `URLSession`, `AVFAudio` or `AVFoundation` in `apps/ios/Widgets` or `apps/ios/Intents`; no `ActivityKit` or `AppIntents` in `apps/ios/Keyboard` or `apps/ios/Shared`; no `AVFAudio` or `AVFoundation` in `apps/ios/Keyboard`.

## Consequences

- The iOS project has three targets. `AGENTS.md` names the widget extension.
- A new App ID is registered on the company team for the widget. `Signing.local.xcconfig` is unchanged.
- The app declares `NSSupportsLiveActivities`.
- The control path works with the app killed, but one of two cold-start recordings in run 3 failed in transcription for a reason the spike did not capture. The real handler logs the failure detail, and the SC-008 rate (9 of 10) is measured on the device later in the feature.
- A Copy button in the Live Activity or a notification also runs with the app in the background, so it cannot write the clipboard directly either. It has to bring LocalFlow forward or rely on the pending write.
- A control press during a running keyboard session was not exercised in the spike.

## Alternatives considered

- **Controls and Live Activity views in the app or the keyboard.** Not possible: iOS loads them only from a WidgetKit extension.
- **One copy of each intent type per target.** Two distinct types that the system cannot route to the app.
- **Moving `SessionController` into a framework shared with the widget.** Puts the speech stack in an extension for no benefit.
- **`AudioRecordingIntent` alone.** Ran in the widget extension on iOS 27.0.1 (spike run 1).
- **Opening LocalFlow on a cold press (`openAppWhenRun`).** Not needed: the background path worked, and opening the app would break "start without bringing LocalFlow to the front".
- **A push-to-start Live Activity.** Needs a server and APNs.
- **Two separate Start and Stop intents.** The Action Button holds one action, and the spec asks for press to start, press to stop.
- **Writing the clipboard from the background.** The writes were dropped on the device.
