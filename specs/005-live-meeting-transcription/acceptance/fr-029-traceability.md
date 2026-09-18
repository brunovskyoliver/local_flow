# FR-029 deterministic coverage

The tests below use fake recognition and temporary databases/audio files. They do not establish speech accuracy, latency or production resource acceptance.

## Scenarios

| Scenario | Named test |
| --- | --- |
| enabled start | `MeetingTranscriptionCoordinatorTests/testStartReturnsTapsWithoutWaitingForModelAndPublishesCommittedIdentity` |
| disabled start | `MeetingTranscriptionCoordinatorTests/testDisabledMeetingNeverLoadsOrStartsAnalysis` |
| provisional creation | `MeetingTranscriptionCoordinatorTests/testSyntheticPCMProducesCommittedProvisionalTextAndFreshStretch` |
| final creation | `MeetingFinalizerTests/testDecodeFillsOneProductionWindowAtATimeAndPersistsPerStretch` |
| pause and resume | `MeetingTranscriptionCoordinatorTests/testPauseRetainsLeaseThenExpiresAndResumePreservesTimeline` |
| stop with pending work; live gap recovery | `MeetingTranscriptionCoordinatorTests/testStopDrainsThenCompleteStartsFinalizationWithoutUserAction` |
| slow recognition and bounded backpressure | `MeetingTranscriptionCoordinatorTests/testThirtyMinutesAtThreeTimesSlowdownStaysBoundedAndRecordsGaps` |
| model load failure | `MeetingTranscriptionCoordinatorTests/testAcquisitionFailuresMapToModelCategoriesAndLeaveNoTapOrLease` |
| runtime failure preserves earlier rows | `MeetingTranscriptionCoordinatorTests/testNthWindowFailureKeepsEarlierRowsDetachesTapsAndFinishesLease` |
| database failure | `MeetingTranscriptionCoordinatorTests/testFourConsecutiveBatchFailuresAndCapacityMapToPersistenceCategories` |
| retry; failed live source integrity | `MeetingTranscriptionCoordinatorTests/testRetryAfterLiveFailureProducesFinalThroughTheFinalizer` |
| vocabulary stability; live source integrity | `MeetingTranscriptionCoordinatorTests/testVocabularyEditsStayOutOfLivePassAndFinalizationTakesANewSnapshot` |
| metrics and runtime logs exclude content | `TranscriptInstrumentationTests/testLiveStopFailedFinalizationAndRetryKeepMetricsAndLogsContentFree` |
| paging | `TranscriptPagerTests/testPagingKeepsAtMostFourHundredResidentAndEvictsDeterministically` |
| timestamps and pauses | `WallClockDerivationTests/testPauseOffsetsMicrophonePreferenceSystemFallbackAndTruncation` |
| raw audio across final, failed and retried passes | `MeetingFinalizerTests/testTrackFilesAreByteIdenticalAcrossFinalFailedAndRetriedPasses` |
| live deletion detaches and joins | `MeetingTranscriptionCoordinatorTests/testDeletingLiveSessionJoinsRecognitionAndClosesEveryTap` |
| restart during live | `TranscriptRestartTests/testRestartDuringLiveKeepsCommittedTextAndAdmitsRetry` |
| restart during finalization | `TranscriptRestartTests/testFreshCoordinatorResumesInterruptedFinalizerWithoutRepeatingCommittedWindows` |
| deletion cascades and preserves other meetings | `MeetingDeletionTests/testTranscriptCascadeAdjustsUsageAndPreservesOtherMeetingFilesAndRows` |
| deletion joins finalization before removing files | `TranscriptRestartTests/testDeletionJoinsFinalizerAndReleasesLeaseBeforeRemovingAudio` |
| recording continues after transcription failure | `MeetingCoordinatorTests/testLiveRuntimeFailureLeavesRecordingAndBothTracksRunning` |

## Repeated runs

Runs use the Debug build produced by `make check`, with `xcodebuild
test-without-building`, the same project/scheme/arm64 destination/derived-data
arguments as `scripts/test.sh`, and explicit `-only-testing:LocalFlowTests/…`
selectors for these suites:

`TranscriptLifecycleTests`, `TranscriptStoreTests`, `MeetingAnalysisTapTests`,
`AnalysisQueueTests`, `AnalysisStreamMixerTests`, `LiveChunkPlannerTests`,
`MeetingWindowAssemblerTests`, `TranscriptSegmenterTests`, `LiveRecognizerTests`,
`WallClockDerivationTests`, `MeetingTranscriptionCoordinatorTests`,
`MeetingFinalizerTests`, `TranscriptReconcilerTests`, `TranscriptRestartTests`,
`TranscriptPagerTests`, `TranscriptInstrumentationTests`, `MeetingDeletionTests`.
Two `MeetingCoordinatorTests` cases also run: the disabled-start integration and
runtime-failure capture-continuation tests named above/in the regression report.

On 2026-09-18 all three runs passed. Their 108 test identifiers and outcomes
were compared and are identical.

| Run | Passed | Failed | Skipped | Local result bundle |
| --- | --- | --- | --- | --- |
| 1 | 108 | 0 | 0 | `build/phase14-repeat-1.xcresult` |
| 2 | 108 | 0 | 0 | `build/phase14-repeat-2.xcresult` |
| 3 | 108 | 0 | 0 | `build/phase14-repeat-3.xcresult` |

Machine/build: arm64 MacBook Pro, macOS 26.6.2 (25G83), Debug,
`CODE_SIGNING_ALLOWED=NO`. JSON summaries and test inventories are beside each
bundle (`build/phase14-repeat-1-summary.json`, `build/phase14-repeat-1-tests.json`,
and corresponding run 2/3 files). These local build artifacts are ignored by Git.
The full regression run separately passed 715 tests with thirteen opt-in skips;
see [regression.md](regression.md).

## Success criteria

| Criterion | Evidence |
| --- | --- |
| SC-001 live latency | [Pending measured latency](live-latency.md) |
| SC-002 disabled mode | Deterministic disabled-start test above; [hardware check pending](long-run-memory.md) |
| SC-003 memory; SC-004 overload | Deterministic queue bounds; [long and slow runs pending](long-run-memory.md) |
| SC-005 timeline | Pause and wall-clock tests above; [manual checks](baseline.md) |
| SC-006 finalization speed | [Measured planning throughput](throughput.md); [production duration pending](long-run-memory.md) |
| SC-007 recovery | Deterministic recovery tests; [force-quit acceptance pending](recovery.md) |
| SC-008 paging | Deterministic pager bound; first-page UI timing pending |
| SC-009 accuracy parity | [Pending real-model fixture comparison](accuracy-parity.md) |
| SC-010 privacy | Instrumentation test above; [real-run log search pending](privacy.md) |
| SC-011 regressions | [Repository regression results](regression.md) |
| SC-012 deletion | Deterministic deletion tests; [manual checks](baseline.md) |
