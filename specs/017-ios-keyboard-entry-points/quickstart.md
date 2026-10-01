# Quickstart: validating the full keyboard and system entry points

This guide covers the automated checks and the manual runs on the owner's iPhone 16 Pro (iOS 26). Record device results in `specs/017-ios-keyboard-entry-points/acceptance/` with the date, iOS version, build (git SHA) and conditions. Don't write down a number that wasn't measured. Where the owner reports a check as fine without figures, record it as owner-attested, as 016 did.

## Prerequisites

- Xcode with the iOS 26 SDK, signed in to team 944A459UC3.
- `apps/ios/Config/Signing.local.xcconfig` as in 016, unchanged.
- The new `…LocalFlow.Widgets` App ID registered (spike, research R12).
- LocalFlow installed over the 016 build, with the model downloaded, the keyboard added and Full Access on.

## 1. Automated checks

```sh
make check
make ios
```

Expected: everything passes, including the keyboard and widget import check (research R11), the Sotto token check, the frozen migration list with `phone-dictations-v2` last, and the new unit tests listed in both [contracts](contracts/).

## 2. Spike (before feature work)

Record in `acceptance/spike.md`:

1. **Cold start from a control** (research R1). Install a build whose control runs `ToggleDictationIntent`. Kill LocalFlow. Press the control from (a) the locked Lock Screen, (b) Control Center over Safari, (c) the Action Button. Note for each: did recording start, did a Live Activity appear, did LocalFlow come to the front, any error text. Repeat with a keyboard session already running.
2. **Clipboard from the background and while locked** (R4).
3. **Typing** (R7): the key grid prototype, 2 minutes of fast two-thumb typing in Notes. Lost or doubled keys? Keyboard footprint at rest from Settings › Diagnostics.

Pick the fallbacks the results call for before continuing, and write the choice into research.md.

## 3. Typing

Removed with User Story 1 (2026-10-01).

## 4. Top bar and listening view (US2, US3, SC-004, SC-005)

1. No session: tap the mic. LocalFlow opens and starts a session. Swipe back.
2. Bar shows `Listening · 4:59` counting down; after a dictation it restarts from the full timeout.
3. Dictate with ✓: listening view as in `reference/wispr-listening.png` (✕, ✓, centred 15 bars, `Listening · 0:03`, `iPhone Microphone`, globe); rolling wave; text inserted; keys return. Undo and Insert last dictation appear and work.
4. Dictate and tap ✕: nothing inserted.
5. Let a dictation run to 4:30: warning shown; at 5:00 text inserted.
6. Kill LocalFlow from the app switcher, return, tap the mic within 2 s: "LocalFlow isn't running" with Start LocalFlow.
7. Say nothing and stop: "Didn't catch that", keys back after 4 s.
8. Start dictating, then swipe the keyboard away: text appears as Insert last dictation next time and is in History.
9. ☰ › Settings opens LocalFlow on Settings; ☰ › End session ends the session and the orange mic indicator goes off within 10 s (SC-007).
10. SC-004: 50 keyboard dictations across Messages, Notes, Mail and Safari. Count any time the keyboard closes. Record the keyboard peak afterwards.
11. SC-005: within those runs, after one session start, record whether 20 consecutive dictations needed no trip to LocalFlow.

## 5. Never timeout (US4, SC-006)

1. Settings › End listening after › Never. Start a session. Bar: `Listening · no timeout`. App session screen: "won't end on its own" and End session.
2. Use other apps for 2 hours, locked part of the time. Dictate from the keyboard without opening LocalFlow. Record whether it worked, or whether the keyboard said LocalFlow was not running (iOS stopped it).
3. End from the keyboard drawer: two taps, mic indicator off within 10 s.

## 6. Live Activity (US5, SC-007)

1. Start a session; lock the phone. Lock Screen shows Ready, elapsed time, remaining time (or No timeout), Stop.
2. Unlock, dictate from the keyboard; watch the Dynamic Island go Recording → Transcribing → Ready.
3. Tap Copy, paste in Notes: the last transcript.
4. Tap Stop: session ends, indicator off within 10 s, the activity disappears.
5. Turn Live Activities off for LocalFlow; start a session: it still works.

## 7. Without the keyboard (US6, SC-008, SC-009)

1. Add the LocalFlow control to Control Center and the Lock Screen and assign it to the Action Button.
2. SC-008: 10 times, from the locked Lock Screen, press the Action Button, speak 15 s, press again. Time from the second press to the text in History (Diagnostics shows stop and result times) and on the clipboard. Pass: at most 3 s in at least 9 of 10.
3. SC-009: in those 10 runs, was a Live Activity visible from start to stop each time?
4. "Dictate a LocalFlow note" via Siri and via Shortcuts: same flow.
5. With a keyboard dictation recording, press the control: that dictation stops and is inserted; no second recording.
6. With notifications allowed: a notification with Copy appears; Copy works with the phone locked.
7. Turn Live Activities off and press the control: refused with the message, nothing recorded.
8. Delete the model (Settings) and press the control: refused, explained.
9. Restart the phone, don't unlock, press the control and dictate (if iOS allows the intent before first unlock): after unlock the text is in History.

## 8. Resource report

Measure on the device and add to `docs/performance/ios-dictation.md` with build, iOS version and conditions:

- Keyboard `phys_footprint` at rest and while the listening view is up (SC-003, under 40 MB each).
- App footprint during a `Never` session, idle and while recording.
- Widget extension footprint if Instruments can attach to it; otherwise say it was not measured.

Nothing goes in the report that was not measured.
