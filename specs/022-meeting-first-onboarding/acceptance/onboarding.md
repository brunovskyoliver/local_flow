# Acceptance: Meeting-first onboarding

Run on 2026-10-31 with a signed `LocalFlow Dev` build on a Mac with no dev data and no `build/model-downloads`, driven through accessibility actions. Screenshots: `~/agent-runs/2026-10-31-022-acceptance/`. The dev app and its data were removed afterwards.

## Observed

| Check | Result |
| --- | --- |
| Purpose step offers Both (Recommended), Dictation, Meeting notes | Pass |
| Meeting notes shows "Where should meetings run?" with what leaves the Mac | Pass |
| Your server shows the connection step, with Use this server disabled until sign-in | Pass |
| Consent sheet shows the meeting text | Pass |
| Back returns through location to purpose, and the step count follows the path | Pass |
| Skip for now reaches downloads, and Continue stays disabled until the speech, Whisper and speaker models are ready | Pass: real download, 2.2 GB on disk |
| Permissions step asks only for Microphone and System audio, and Continue is disabled without Microphone | Pass |
| Dictation and Both reach the optional AI step | Pass |
| Relaunch with `setup.purpose = meetings` and setup marked complete opens Notetaker, with no Input Monitoring row in Settings and a Set Up dictation row | Pass, but finished by writing defaults, not by walking setup |
| Set Up sets the purpose to `both`, saves Right Control, and shows the Input Monitoring and Accessibility rows | Pass. Those rows were not pressed, and no prompt was seen |

## AeroSpace

The dev window floats: `AXFullScreenButton` is null, the dialog heuristic is true and its parent is Workspace. The local rule covers only `org.localflow.LocalFlow`. A manual `aerospace layout tiling` moved it into a TilingContainer, and it was floated again. Automatic tiling and neighbouring frames were not checked. The production window title and scene are unchanged, but the production app was not tested.

## Not run

- **Allowing Microphone and System audio, and finishing setup through the UI.** These are macOS privacy prompts for you to answer.
- **Server enrollment, approval and the zero-byte server path (SC-001).** These need sign-in. Coordinator tests cover the path logic.
- **Recording a meeting while the server is offline (SC-004) in the live app.** The finalizer's waiting route has a unit test.
- **Both's automatic meeting download and the system audio row in the live app.**
- **Measured model memory on the server path.** No measurement was collected.

## Finding outside this feature's diff

Launching the app on a clean profile opened no window, and `open` on the running app didn't either. The window appeared only from the menu bar's Open LocalFlow, so a first-time user may not see onboarding. This feature did not change the scene or the reopen code. The installed release wasn't checked for the same behaviour.
