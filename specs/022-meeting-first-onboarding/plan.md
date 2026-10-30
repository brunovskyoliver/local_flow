# Implementation Plan: Meeting-first onboarding

**Branch**: `022-meeting-first-onboarding` | **Date**: 2026-10-30 | **Spec**: [spec.md](spec.md)

## Summary

Add a purpose step to the SwiftUI onboarding and let `OnboardingCoordinator` skip the steps a path doesn't need. The existing AI step already asks where things run (`AIMode` local, remote, off), so it is reused rather than adding a second "where" step. No server, wire or schema change.

## Technical Context

Swift 6, SwiftUI, `apps/macos/LocalFlow`. Stores the purpose in `UserDefaults` through `AppPreferences`, as other setup values are. Tests: XCTest in `apps/macos/LocalFlowTests/OnboardingTests.swift`. Target: macOS 26 on Apple Silicon.

## Constitution Check

- **4 Local-first**: recording stays local and work waits on the existing Feature 018 path. Local paths are unchanged.
- **5 Privacy**: nothing is sent before consent and approval. Meeting-only consent copy states what goes to the server and the ADR 0033 retention.
- **2, 3, 6**: no new queue or buffer, no new model owner. `serverOnly` already keeps models unloaded.
- **9 Recoverability**: quitting mid-setup restarts onboarding, as today.
- **12 Testability**: the path logic lives in the coordinator, with closures for side effects.
- **14 Scope**: one enum, one step, one preference. No exception required.

## Path table

Steps by purpose and `AIMode`. `introduction` and `purpose` come first in every path. The AI step's copy changes with the purpose.

| Purpose | Mode | Steps after the AI step | Downloads |
| --- | --- | --- | --- |
| meetings | remote | aiDetails (server), permissions, personalize, complete | None; `serverOnly = true` |
| meetings | local | aiDetails (model), downloads, permissions, personalize, complete | Speech, booster, speakers, Whisper required; local AI keeps downloading |
| meetings | off | downloads, permissions, personalize, complete | Same without local AI; Skip says no summaries |
| dictation | any | Today's flow | Today's; meeting row stays optional |
| both | local, off | Today's flow | Today's plus meeting models automatically |
| both | remote | Today's flow | Today's: speech fallback only, because the server handles meetings |

Finishing a meetings path needs no test: `personalize` finishes setup.

## Design

1. **`AppPreferences.Purpose`** (`dictation`, `meetings`, `both`), stored under `setup.purpose`. Missing means `both`.
2. **`OnboardingCoordinator`**: add `Step.purpose` after `introduction` and a `purpose` property written to preferences on leaving the step. `advance` and `back` follow the path table. New closures: `abandonServer` (undoes `serverOnly`, and turns remote off through `turnOffRemoteDictation()`), and `openNotetaker`.
3. **Readiness**: `Snapshot.readyForMeetings` is `storageAvailable && microphone == .granted`, and `Snapshot.meetingModelsReady` is `modelInstalled && speakerModelInstalled && meetingModelInstalled`. Add `systemAudio` and `speakerModelInstalled` to the snapshot.
4. **`OnboardingView`**: purpose step with `SelectableCard`, purpose-aware copy, meeting permission rows, an appearance-only `personalize`, required meeting row with Retry. Its existing shortcut default task runs only when the purpose isn't `meetings`.
5. **Shortcut**: while the purpose is `meetings`, `configureShortcut` installs nothing. The startup call and every other caller go through that one guard, so no Input Monitoring prompt or event tap can start. During onboarding, before a purpose is chosen, startup behaves as it does today, which does not prompt.
6. **Settings**: while the purpose is `meetings`, `permissionsSection` hides Input Monitoring and Accessibility, and a Set up dictation row appears. It sets the purpose to `both` and calls `configureShortcut`; the existing permission and model sections then appear.
7. **Landing page**: on launch and on finishing, `router.selection` is `.meetings` when the purpose is `meetings`.
8. **Consent copy**: `RemoteDictationModel` picks the text by purpose. The meeting-only variant says meeting audio, transcripts and summary text go to the server, that handed-off meetings stay there until merged and at most 7 days, and that recordings wait while the server can't be reached. The consent version stays 1 because this only applies to new consents on a path that didn't exist. It also says dictation goes to this server if it is set up later, so Set up dictation needs no second consent (finding H1). The other text is unchanged, so its "dictation stays local" sentence never reaches a server-only user. `remotePrivacy` in onboarding states the 7-day handoff retention on every server path, including Both, without changing the versioned text (finding H2).

## Decisions

- A download already started stays running after Back. Downloads outlive steps today, and a finished model is harmless. FR-011 covers settings and queued work that hasn't started.
- Screen Recording refused does not block finishing, and macOS may ask for a relaunch; the row's copy says so.
- Quitting mid-setup: when onboarding starts again with an unfinished setup, `serverOnly` set by an abandoned meeting path is cleared, along with remote, the same way Back does it.
- Both requests system audio on the permissions step; a refusal doesn't block.
- Existing users: `setupVersion` does not change, so nobody sees onboarding again.

## Bounds, failure and validation

No new bounded structures. Failure paths: meeting model failure shows Retry; server unreachable leaves recording unaffected. Validation: coordinator unit tests for every row of the path table, `make check` where it can run, and a run of `LocalFlow Dev` on a clean profile, including an AeroSpace tiling check because the first-run window content changes.

## Project Structure

```text
apps/macos/LocalFlow/Features/Settings/AppPreferences.swift
apps/macos/LocalFlow/Features/Settings/OnboardingCoordinator.swift
apps/macos/LocalFlow/Features/Settings/OnboardingView.swift
apps/macos/LocalFlow/Features/Settings/SettingsViewModel.swift
apps/macos/LocalFlow/Features/Settings/SettingsView.swift
apps/macos/LocalFlow/Features/Settings/RemoteDictationView.swift
apps/macos/LocalFlow/App/AppServices.swift
apps/macos/LocalFlow/App/LocalFlowApp.swift
apps/macos/LocalFlowTests/OnboardingTests.swift
```
