# Recovery

Status: Unmeasured on the signed app (deterministic coverage recorded below)

The real-app walkthrough (force-quit during a run and during a past search, relaunch,
confirm `interrupted`, prior assignments intact, remaining queue dropped, Rerun
available) has not been performed on the reference machine yet. It needs the signed
build with fixture meetings A, B and C; see `quickstart.md` "Hardware acceptance".

What `make check` proves today, on the same code paths the walkthrough exercises:

- `IdentificationReconcilerTests.testRunningIsInterruptedWithItsCandidatesGonePendingResumesAndAssignmentsStay`:
  a `running` run becomes `interrupted` at launch, its `match_candidates` are deleted,
  `identity_assignments` are byte-identical before and after, the accepted run stays
  accepted, a `pending` run is handed back to the queue, and no audio file is opened.
- `IdentificationReconcilerTests.testAtMostAHundredRowsPerLaunchOldestFirst`: the launch
  bound.
- `SpeakerIdentificationCoordinatorTests.testCancelPastSearchDropsTheQueueAndItIsMemoryOnly`:
  the past-search queue is memory-only; a fresh coordinator starts with an empty queue
  and only `pending` runs resume.
- `MeetingIdentifierTests.testEveryFailureCategoryLeavesEverythingIdenticalAndDeletesOnlyItsCandidates`:
  every failure category leaves transcript, turns, audio rows, samples and previous
  assignments byte-identical; Retry admits a new run.
