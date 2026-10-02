# iOS companion

`LocalFlowPhone.xcodeproj` builds the LocalFlow iPhone app (iOS 26, Swift 6) and two
extensions embedded in it: the LocalFlow keyboard (Feature 016, ADR 0029) and the
`LocalFlowWidgets` WidgetKit extension with the dictation control and the Live Activity
(Feature 017, ADR 0030). The app links `packages/LocalFlowCore`; neither extension links a
package product or makes a network call (`scripts/check-keyboard-imports.sh`).

- `App/`: the containing app. Session, capture, pipeline, History, Dictionary, setup and Settings.
- `Keyboard/`: the `UIInputViewController` and its SwiftUI view.
- `Shared/`: compiled into the app and the keyboard. Handoff files and bells, keyboard logic,
  Sotto tokens. The widget compiles only `Shared/Sotto/`; every other file is excluded from it
  one by one in the project's membership exceptions.
- `Intents/`: compiled into the app and the widget. The App Intents (toggle dictation, end
  session, copy last), the `IntentHandler` protocol the app implements, and the Live Activity
  attributes.
- `Widgets/`: the `LocalFlowWidgets` extension. The control and the Live Activity views.
- `LocalFlowPhoneTests/`: unit tests on the simulator, run by `make check`.

`make ios` builds all three targets for the simulator without signing.

## Signing

Copy `Config/Signing.local.xcconfig.example` to `Config/Signing.local.xcconfig` (gitignored)
and set `DEVELOPMENT_TEAM` and `LOCALFLOW_BUNDLE_PREFIX` once.

**Never change either value afterwards.** The bundle IDs and the App Group are built from
them. A new team or prefix makes iOS treat the build as a different app: it gets a new,
empty container, so History, the Dictionary, the settings and the downloaded model are left
behind in the old one, and the free team allows only 10 new App IDs per 7 days (research R10).

## What lives where

Every location below survives installing the same build, or a newer one, over the existing
app, as long as the team and prefix are unchanged.

| Data | Location | Backed up |
| --- | --- | --- |
| History and Dictionary (`history.sqlite`, WAL) | app container, `Application Support/LocalFlow/` | yes |
| Speech and boost models | app container, `Application Support/LocalFlow/Models/<name>/` | no (excluded) |
| Download resume data | app container, `Application Support/LocalFlow/Models/.staging/` | yes |
| Recording spool, orphan waiting for recovery | app container, `Application Support/LocalFlow/TemporaryAudio/` | yes |
| Settings (`session.idleTimeout`, `setup.completedSteps`, `diagnostics.enabled`, `notifications.dictationResults`) | `UserDefaults.standard` of the app | yes |
| Handoff files (`session.json`, `result.json`, `keyboard-status.json`, …) | App Group container, `Handoff/` | no (excluded) |

Nothing that must survive is kept in `Caches` or `tmp`. The only `tmp` use is a finished
model file, which the download moves from `tmp` straight into the staging folder. Debug
builds also read fixture audio from `Documents` for the parity check (quickstart §8); those
files are copied in by hand and are not app data.

Deleting the app removes both containers. Only a reinstall over the existing app keeps them.

## Weekly reinstall (free team)

A free-team profile expires after 7 days, and the app then stops launching. To renew it:

1. Connect the iPhone and open `LocalFlowPhone.xcodeproj` with the same
   `Signing.local.xcconfig` as before.
2. Choose the `LocalFlowPhone` scheme and the phone, then Product › Run. Do not delete the
   app from the phone first.
3. Open LocalFlow. History, the Dictionary, the settings and the model should all be there,
   and setup should not open. iOS may ask for the microphone again if it reset the
   permission; the keyboard and Full Access stay as they were.

Quickstart §9 is the acceptance run for this (SC-006).
