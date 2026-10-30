# Tasks: Meeting-first onboarding

Write each test before its code. `[P]` means a different file with no dependency.

## Phase 1: Foundation

- [X] T000 Fix the existing `swift format` line-length failures that stop `make check` (separate commit)
- [ ] T001 Add `AppPreferences.Purpose` persisted under `setup.purpose`, missing meaning `both`, with a test, in `Features/Settings/AppPreferences.swift`
- [ ] T002 Add `systemAudio`, `speakerModelInstalled`, `readyForMeetings` and `meetingModelsReady` to `SettingsViewModel.Snapshot` and fill them in `AppServices.settingsSnapshot`
- [ ] T003 Add `Step.purpose` and path-table routing to `OnboardingCoordinator`; update existing `OnboardingTests` for the new step

## Phase 2: User Story 1, meeting notes on a server (MVP)

- [ ] T004 [US1] Test: meetings + remote goes aiDetails, permissions, personalize, complete; starts no downloads; sets `serverOnly`; finish opens Notetaker; a pending approval can continue as an approved one can (US1 scenario 2)
- [ ] T005 [US1] Purpose step and purpose-aware AI step and introduction copy in `OnboardingView` (FR-001, FR-002, FR-003)
- [ ] T006 [US1] Meeting-only consent variant in `RemoteDictationView` and `remotePrivacy` (FR-012), with a test that the variant is chosen by purpose; the variant says later dictation goes to this server; retention notice shows on every server path, including Both
- [ ] T007 [US1] Meeting permission rows using `MeetingPermissions` and appearance-only `personalize`; the system audio row also shows for Both (FR-005, FR-006, US3)
- [ ] T008 [US1] Guard `configureShortcut` on the purpose, with a test that a `meetings` purpose installs no shortcut (FR-005)
- [ ] T009 [US1] Hide keyboard permissions in Settings for `meetings`, and land on Notetaker on launch (FR-005, FR-007)
- [ ] T010 [US1] Test and code: Back from a remote path to a different choice clears `serverOnly` and remote, and so does restarting an unfinished onboarding after a quit (FR-011)
- [ ] T011 [US1] Test: a recording made with `serverOnly` and no reachable server is saved and waits, using the existing meeting test doubles (FR-009, SC-004)

## Phase 3: User Story 2, meeting notes on this Mac

- [ ] T012 [US2] Test and code: meetings + local or off requires `meetingModelsReady` at the downloads step and starts meeting models automatically (FR-013)
- [ ] T013 [US2] Required meeting row with Retry, including a coordinator retry that clears `meetingsRequested`
- [ ] T014 [US2] Skip copy on the AI step for meetings: summaries won't be available (FR-013)

## Phase 4: User Story 3, dictation or both

- [ ] T015 [US3] Test: dictation path equals today's path plus the purpose step (SC-002)
- [ ] T016 [US3] Test and code: both + local or off starts meeting models automatically; both + remote does not, and keeps `serverOnly` off (FR-014)
- [ ] T017 [US3] Test: an install with finished onboarding and no stored purpose keeps its page and shortcut (SC-003)

## Phase 5: User Story 4, adding dictation later

- [ ] T018 [US4] Test and code: Set up dictation row sets the purpose to `both`, installs the shortcut, and shows the permission section (FR-010)

## Phase 6: Acceptance

- [ ] T019 Update `docs/architecture/overview.md` and the onboarding section of `apps/macos/README.md` if it describes the flow
- [ ] T020 Build and run `LocalFlow Dev` on a clean profile; walk all paths the Mac can run; record results in `acceptance/onboarding.md`; run the AeroSpace tiling check; on the server path confirm zero model bytes (no dev model source available, since debug builds auto-install one) and record that no model loads
- [ ] T021 Run `make check`; record any failures not caused by this feature
