# FR-028 traceability

Every FR-028 scenario maps to one named deterministic test; every success criterion maps
to its deterministic test and/or acceptance file. Suites live in `apps/macos/LocalFlowTests`.

## FR-028 scenarios

| Scenario | Test |
| --- | --- |
| Every allowed transition | `MeetingLifecycleTests.testEveryAllowedPairIsAccepted` |
| Every invalid pair (8×8 sweep) | `MeetingLifecycleTests.testEveryOtherPairIsRejectedWithoutSideEffects`; store-level `MeetingStoreTests.testTransitionAppliesSideEffectsInOneWriteAndRejectsInvalidPairsWithoutWriting` |
| start → stop | `MeetingCoordinatorTests.testStopFinalizesMicrophoneThenSystemWritesTotalsAndReleasesEverything` |
| start → pause → resume → stop | `MeetingCoordinatorTests.testPauseFinalizesSegmentsOpensPauseRowAndResumeOpensSequenceTwo` |
| Interruption while recording | `MeetingReconcilerTests.testRecordingRowBecomesInterruptedWithTruncatedRenamedSegments` |
| Interruption while paused | `MeetingReconcilerTests.testPausedRowClosesThePauseAtUpdatedAtAndExcludesIt` |
| Interruption while finalizing | `MeetingReconcilerTests.testFinalizingWithMicrophoneStageKeepsItAndRecoversSystem` |
| System sleep | `MeetingCoordinatorTests.testSystemSleepPausesWithReasonAndNeverResumesOnItsOwn` |
| Microphone failure | `MeetingCoordinatorTests.testOneSourceFailureMarksTheTrackAndTheMeetingContinues` |
| System-audio failure | `MeetingCoordinatorTests.testSystemStreamStoppedIsSymmetricAndBothRefusingToStartFails` |
| Storage write failure | `MeetingCoordinatorTests.testWriteFailureStopsCaptureWithinTheBoundAndKeepsWrittenAudio`; `MeetingTrackWorkerTests.testWriteFailureLatchesStopsPoppingAndRingDropsWhileOccupancyStaysAtCapacity` |
| FR-013: record without files (missing file) | `MeetingReconcilerTests.testMissingFileIsUnrecoverableWithFileMissing` |
| FR-013: files without record (orphan) | `MeetingReconcilerTests.testOrphanDirectoryBecomesInterruptedMeetingWithReconstructedTracks` |
| FR-013: stale metadata | `MeetingReconcilerTests.testStaleMetadataIsRevalidatedAndCorrected` |
| FR-013: one track finalized | `MeetingReconcilerTests.testFinalizingWithMicrophoneStageKeepsItAndRecoversSystem` |
| FR-013: active while not running | `MeetingReconcilerTests.testRecordingRowBecomesInterruptedWithTruncatedRenamedSegments` |
| FR-013: open pause | `MeetingReconcilerTests.testPausedRowClosesThePauseAtUpdatedAtAndExcludesIt` |
| FR-013: zero complete frames | `MeetingReconcilerTests.testZeroCompleteFramesStaysPartAndUnrecoverableWithFileKept` |
| FR-013: `created` never `preparing` | `MeetingReconcilerTests.testCreatedRowThatNeverPreparedBecomesFailedAndUnblocksCreate` |
| Deletion of a recovered meeting | `MeetingDeletionTests.testConfirmedDeletionRemovesFilesThenRowAndLeavesTheOtherMeetingUntouched` |
| Buffer capacity and overflow | `MeetingSampleRingTests.testOverflowDropsWholePushCountsFramesAndKeepsAdmitting`; `MeetingTrackWorkerTests.testThirtySimulatedMinutesKeepEveryStructureBounded` |
| Note autosave | `MeetingNotesEditorTests.testOneEditThenTwoSecondsIdleSavesExactlyOnce`, `testContinuousEditingForcesASaveEveryTenSeconds`, `testFailedSaveKeepsDirtyShowsNoticeAndRetriesLater` |

## Success criteria

| SC | Deterministic test | Acceptance file |
| --- | --- | --- |
| SC-001 start ≤ 3 s | `MeetingCoordinatorTests.testStartRunsInContractOrderPersistsBeforeCaptureAndPublishesRecording` (order and metrics only) | `baseline.md` (T075, not run) |
| SC-002 force-quit recovery | `MeetingReconcilerTests` (all) | `recovery.md` (T076, not run) |
| SC-003 memory | `MeetingTrackWorkerTests.testThirtySimulatedMinutesKeepEveryStructureBounded` (bounds only) | `long-run-memory.md` (T044/T080, unmeasured) |
| SC-004 track duration | `MeetingStoreTests.testDurationWarningUsesMaxOnePercentOrTwoSecondsAtStop` | `baseline.md` (T075, not run) |
| SC-005 recorded duration | `MeetingCoordinatorTests.testPauseFinalizesSegmentsOpensPauseRowAndResumeOpensSequenceTwo` | `baseline.md` (T079 sleep case, not run) |
| SC-006 storage failure ≤ 5 s | `MeetingCoordinatorTests.testWriteFailureStopsCaptureWithinTheBoundAndKeepsWrittenAudio` | `storage-failure.md` (T077, not run) |
| SC-007 notes | `MeetingNotesEditorTests` | `recovery.md` (T078, not run) |
| SC-008 permissions | `MeetingPermissionsTests`; `MeetingCoordinatorTests.testPermissionRefusalsAndRevocationDuringAMeeting` | `recovery.md` (T078, not run) |
| SC-009 deletion | `MeetingDeletionTests` | `baseline.md` (T079, not run) |
| SC-010 no model/network | `MeetingInstrumentationTests.testMeetingSourcesReferenceNoNetworkOrModelSymbol` | `long-run-memory.md` (T080, unmeasured) |
| SC-011 Feature 001–003 unchanged | `DictationCoordinatorTests.testMeetingGuardRefusesDictationAndAbsentGuardLeavesTheFlowUnchanged`; full suites in `make check` | `baseline.md` (T082) |
| SC-012 content-free | `MeetingInstrumentationTests.testFullRunEmitsEveryMeetingMetricContentFree`; `ResourceRecorderTests.testMeetingMetricsAreContentFreeAndKeyedOnlyByClosedSets` | `privacy.md` (T081, not run) |

Determinism: the meeting suites run on a fake clock (`FakeMeetingClock`), fake sources and a
fake writer; three consecutive local runs are recorded in `baseline.md` under "Regression runs".
