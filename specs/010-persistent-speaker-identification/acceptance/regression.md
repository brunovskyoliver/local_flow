# Regression (SC-010)

Status: Measured (deterministic suites)

- Hardware: Mac17,2 (M5), 32 GB; macOS 26.6.2 (25G83); Debug build, unsigned test host
- Command: `make check` on 2026-09-20 after the last Feature 010 change
- Result: 1,039 XCTest cases, 1,018 passed, 0 failed, 21 skipped (the opt-in hardware,
  fixture and calibration harnesses), plus the repository scripts, lint, Go server tests
  and the new `scripts/check-identification-imports.sh`

How the setting-off gate is covered:

- The Feature 001–009 suites never touch `speakerIdentificationEnabled`; they construct
  the 007 sheet, pager and coordinators without an identity store, which is the
  setting-off shape (`AssignSpeakersModel(meetingID:store:)`, `TranscriptPager(meetingID:store:)`).
- `SettingsTests.testSpeakerIdentificationToggleDefaultsOnAndOffShortCircuitsEverything`
  and `AssignSpeakersIdentityModelTests.testWithTheSettingOffTheSheetIsThe007Sheet` prove
  that with the toggle off no identity block renders, no run is admitted, no enrollment
  starts and no identity store call is made.
- `SpeakerIdentificationCoordinatorTests.testTheGlobalSettingOffReturnsDisabledWithoutTouchingTheStore`
  covers the adoption trigger, the manual rerun and the past search.

Two pre-existing checks were adjusted to the schema this feature adds, not to its
behavior: `SpeakerStoreTests.testMigrationOnAFeature006DatabaseAddsOneRowPerMeetingAndNoIdentityTables`
now migrates up to `speakers-v7` (it asserts the 007 schema), and
`MeetingStoreTests.testPre004DatabaseOpensAndListsZeroMeetings` drops the v8 tables with
the rest. `TranscriptPagerPagingTests.testFinalizingReadsProvisionalThenFinalSwitchesAndReloads`
failed on the pre-feature tree as well (its fixture seeded provisional rows under the
final pass id, which the 009 pager previews); the fixture now seeds them under a
separate live pass.
