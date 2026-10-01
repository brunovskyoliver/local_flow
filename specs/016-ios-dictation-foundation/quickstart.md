# Quickstart: validating the iOS dictation foundation

This guide shows how to check that Feature 016 works. It covers the automated checks and the manual acceptance runs on the iPhone 16 Pro. Record results from the device in `specs/016-ios-dictation-foundation/acceptance/`, with the date, iOS version, build (git SHA) and conditions. Don't write down a number that wasn't measured.

## Prerequisites

- Xcode with the iOS 26 SDK. A free Apple ID signed in under Xcode → Settings → Accounts.
- `apps/ios/Config/Signing.local.xcconfig`, copied from `Signing.local.xcconfig.example`, containing `DEVELOPMENT_TEAM` and `LOCALFLOW_BUNDLE_PREFIX`. Set these once and never change them ([research R10](research.md)).
- The iPhone 16 Pro in Developer Mode, connected by cable. No more than one other sideloaded app on it, because the free tier allows 3.
- On the Mac: the baseline `make check` output saved before the extraction starts.

## 1. Automated checks

```sh
make check          # Mac suite + package tests + iOS simulator build/tests + import and token checks
make ios            # iOS app + keyboard build for the simulator, unsigned
```

Expected:

- Everything passes.
- The Mac test count is at least the baseline.
- `check-core-imports.sh`, the keyboard import check and `check-sotto-tokens.py` report nothing.
- The frozen migration list test and the Mac paths test pass.

## 2. Signing and handoff spike (runs first, before feature work)

1. Build the spike app and keyboard to the phone from Xcode with the free team.
2. Add the keyboard in Settings → General → Keyboard → Keyboards, and turn on Full Access.
3. In Notes, switch to the keyboard and tap the test button. The app should receive the doorbell and write a reply, and the keyboard should show it.
4. Tap "Open app". The app should open from the keyboard.
5. Start a background audio session in the app, return to Notes, wait 2 minutes, and ping again. The app should still answer.

Pass: all five steps work. Write down the doorbell round-trip time, whether the orange indicator shows, whether music keeps playing with `.mixWithOthers`, and the keyboard's footprint at rest. If the App Group step fails, stop and pick a fallback from [research R4](research.md).

## 3. Mac unchanged (US6, SC-008)

1. `make check` passes (above).
2. `make run`, then do one dictation into TextEdit, one rewrite, a Dictionary term ("Zabbix") dictated, and a 1-minute meeting.
3. The results should match behaviour before the change, and existing History, Dictionary and meetings should still be there.

## 4. Setup and offline (US2, SC-005, SC-007)

1. Delete the app from the phone, then run it from Xcode.
2. Time the setup, excluding the model download. The checklist should show 4 steps and survive leaving and returning.
3. Start the model download. Halfway through, turn on Airplane Mode, wait, then turn it off. The download should resume without restarting from zero.
4. Turn on Airplane Mode again, force-quit the app, open the keyboard in Notes, start a session and dictate. The text should be inserted.
5. With Full Access off, the keyboard should say what's missing. With the microphone denied, the app should explain how to allow it.

## 5. Keyboard dictation (US1, SC-001, SC-002, SC-009)

1. In Messages, tap the keyboard capsule. LocalFlow should open with the swipe-back hint. Swipe back.
2. Dictate a prepared 15-second passage 10 times. Measure the time from the stop tap to the text appearing, using screen recording at 60 fps or the diagnostics timestamps. Pass: at least 9 of 10 runs are under 1.5 s.
3. Do 20 dictations in a row within the idle period. None should need a trip to the app.
4. Stop dictating and wait out the idle timeout. The orange indicator should disappear no more than 10 s after the deadline. The next tap should reopen the app.
5. Tap Undo right after an insertion. Exactly that text should be removed.

## 6. Robustness (edge cases, SC-004, SC-010)

For each case, the text should end up inserted, offered as "Insert last dictation", or saved in History.

| Case | How |
| --- | --- |
| Field change | Start a dictation, then tap a different field before stopping |
| Keyboard dismissed | Stop the dictation, then dismiss the keyboard immediately |
| Phone call | Call the phone from another device while recording |
| Siri | Invoke Siri while recording |
| Lock | Lock the phone while recording |
| Limit | Speak for more than 5 minutes |
| Silence | Tap, stay silent, tap |
| App killed | While recording, kill the app from Xcode. Reopen it, and the orphaned recording should appear in History marked for review |
| Low Power Mode | Turn it on, then dictate |

Over 50 keyboard dictations in mixed apps (Messages, Notes, Safari, Mail, WhatsApp), the keyboard must never drop back to the system keyboard. Afterwards, read the keyboard's peak footprint from the app's diagnostics screen.

## 7. Dictionary (US4)

1. Add "Zabbix" and "Homarr" (with an alias) on the phone.
2. Dictate "I restarted Zabbix and Homarr this morning." Both should be spelled canonically.
3. Disable "Homarr" and dictate again. It should no longer be forced.

## 8. Mac and phone parity (SC-003)

1. Fetch the dictation fixtures listed in `fixtures/audio/manifest.json` with `scripts/download-speech-fixtures.py`, and transcribe them on the Mac through the production dictation path:

   ```sh
   ./scripts/transcribe-dictation-fixtures.sh            # writes build/speech-fixtures/transcripts/mac/<id>.txt
   ./scripts/transcribe-dictation-fixtures.sh OUTPUT_DIR # or one text file per fixture in OUTPUT_DIR
   ```

   The script hash-checks or downloads the fixtures into `build/speech-fixtures`, then runs `RuntimeCompatibilityTests/testOptInSpeechFixtures` with `LOCALFLOW_SPEECH_PROFILE=production`: the production `WindowedTranscriber`, `TranscriptAssembler` and `normalizedForDelivery` with an empty Dictionary, so the booster has no terms. The model comes from the installed app (`~/Library/Application Support/LocalFlow/Models/parakeet-v3`); set `LOCALFLOW_MODEL_ROOT` to use another copy. `results.json` beside the text files keeps the incomplete flag and the raw windows.
2. Transcribe the same set on the phone using the diagnostics "Transcribe fixture" action. It is available in Debug builds only, and the files are copied in through Xcode's device file sharing.
3. Diff the text per fixture, and explain any difference in `acceptance/parity.md`. Report the sk, en and mixed groups separately (FR-018).

## 9. Reinstall (US5, SC-006)

Three times:

1. Record the counts of History entries, Dictionary entries, settings and model files.
2. Run the app from Xcode over the existing install.
3. The counts should be unchanged, with no new setup prompts apart from any iOS requires.

Once, let the 7-day profile expire, confirm the app won't launch, then reinstall and check the counts.

## 10. Resource report

Measure on the phone with Instruments (Allocations and VM Tracker) and the in-app diagnostics:

- app footprint when idle
- in a ready session
- while recording
- with the model loaded
- the model load time, cold and warm
- the transcription time for 15 s and 60 s of audio
- the keyboard's peak

Write these to `docs/performance/ios-dictation.md` with the hardware, iOS version, build and model revision.
