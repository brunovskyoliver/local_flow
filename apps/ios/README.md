# iOS companion

`LocalFlowPhone.xcodeproj` builds the LocalFlow iPhone app (iOS 26, Swift 6) and two
extensions embedded in it: the LocalFlow keyboard (Feature 016, ADR 0029) and the
`LocalFlowWidgets` WidgetKit extension with the dictation control and the Live Activity
(Feature 017, ADR 0030). The app links `packages/LocalFlowCore`; neither extension links a
package product or makes a network call (`scripts/check-keyboard-imports.sh`).

- `App/`: the containing app. Session, capture, pipeline, History, Dictionary, setup and Settings.
  Feature 020 adds `App/Meetings/` (recorder, uploader, summarizer, Live Activity),
  `App/Server/` (enrollment and the channel to the server) and the Meetings tab in
  `App/Features/Meetings/`.
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
| Meetings (`<UUID>/mic-NNNN.aac`, `.part` while recording) | app container, `Application Support/LocalFlow/Meetings/` | no (excluded) |
| Meeting rows, transcripts, summaries, upload state (`phone-meetings-v1`, `-v2`, shared `v19`) | `history.sqlite`, same file as History | yes |
| Upload bundles and downloaded results (`<UUID>/bundle.sqlite`, `rows.sqlite`, `result.sqlite`) | app container, `Application Support/LocalFlow/Handoff/`, deleted once merged | yes |
| Server settings (`server.address`, `server.state`, `server.notice`, `server.consentVersion`, `server.processMeetings`, `server.copyToMac`) | `UserDefaults.standard` of the app | yes |
| Server credentials (tokens, pinned server key) | Keychain, service `<bundle ID>.remote`, after first unlock, this device only | no |
| Device signing key | Secure Enclave | no |
| Settings (`session.idleTimeout`, `setup.completedSteps`, `diagnostics.enabled`, `notifications.dictationResults`) | `UserDefaults.standard` of the app | yes |
| Handoff files (`session.json`, `result.json`, `keyboard-status.json`, …) | App Group container, `Handoff/` | no (excluded) |

Nothing that must survive is kept in `Caches` or `tmp`. The only `tmp` use is a finished
model file, which the download moves from `tmp` straight into the staging folder. Debug
builds also read fixture audio from `Documents` for the parity check (quickstart §8); those
files are copied in by hand and are not app data.

Deleting the app removes both containers. Only a reinstall over the existing app keeps them.

## Meetings

The Meetings tab records the microphone for as long as the meeting lasts, also with the
phone locked; the Live Activity shows the time and has a Stop button. The recorder writes
AAC segments of 6 minutes and starts a new segment after a call or another app takes the
microphone, with the gap marked. After a forced quit, the meeting is recovered on the next
launch with at most the last 10 seconds lost. Recording, playback and the files need no
server.

The phone runs no meeting models. With a server set up, it uploads the segments while the
meeting is still running, and the server transcribes them as they arrive; the recording
screen and the Live Activity show "Transcribed up to". After Stop, the phone sends the rest,
waits for the result, merges the transcript and speaker labels, and asks the server for the
summary. The list shows each meeting's state: Waiting for server (with the reason),
Uploading, Processing, Ready or Failed. Without a server, or while it is unreachable, the
meeting stays on the phone and goes up once the server answers again.

A meeting's detail view plays from any transcript line, renames the meeting and its
speakers (Speaker 1, Speaker 2, ...; the phone has no voiceprints), copies or shares the
transcript and summary, and deletes the meeting.

With **Copy meetings to my Mac** on, the server keeps the result after the phone has it, and
a Mac signed in as the same user imports it within minutes of connecting (ADR 0034). The
detail view then shows Waiting for Mac, Sent to Mac, or Not delivered to Mac when the
server dropped it after 7 days; **Send to Mac again** uploads and processes the meeting a
second time. The two copies are independent after the import.

## Server settings

Settings › Server connects the phone to a LocalFlow server, the same one the Mac uses
(`docs/distribution/remote-server.md`):

1. Enter the server's `https://` address, for example
   `https://mac-mini.tailf15b6.ts.net`, and tap Check identity.
2. Compare the fingerprint with `flowd admin identity` on the server, then Confirm.
3. Sign in with Google. The server lists the phone as a pending device; approve it with
   `flowd admin approve device <id>` or in the LocalFlow Server app.
4. Turn on **Process meetings on this server**, and leave **Copy meetings to my Mac** on if
   the Mac should get a copy.

Nothing leaves the phone before the device is approved and the switch is on. Sign out
deletes the phone's credentials; the recordings stay.

### Tailscale

The Mac mini serves the channel on the tailnet only (Tailscale Serve), so the phone needs
the Tailscale app installed, signed in to the same tailnet and connected. Without it, the
server is unreachable and meetings wait on the phone with "Waiting for server
(unreachable)".

### Google client ID

Google sign-in uses the phone's own iOS OAuth client,
`569511417357-6130aocbp9ggo4g5meuifjjhbsr7aavj.apps.googleusercontent.com`. It is public.
`Config/Base.xcconfig` sets it in `LOCALFLOW_GOOGLE_CLIENT_ID` and its reversed form in
`LOCALFLOW_GOOGLE_URL_SCHEME`; the build puts them into the Info.plist
(`LocalFlowGoogleClientID` and the URL scheme). To use another client, override both in
`Config/Signing.local.xcconfig`. An empty client ID hides the Google button ("Google sign-in
isn't set up in this build").

The server accepts a token only from clients it knows, so the same ID must be in flowd's
`--google-client-id` list, comma-separated after the Mac's:

```sh
scripts/install-remote-server.sh --google-client-id "<Mac client ID>,569511417357-6130aocbp9ggo4g5meuifjjhbsr7aavj.apps.googleusercontent.com" ...
```

Enrollment needs the Secure Enclave, so it works only on a device, not in the Simulator.

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
