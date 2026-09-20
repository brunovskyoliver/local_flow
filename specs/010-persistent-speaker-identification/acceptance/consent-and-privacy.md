# Consent and privacy (SC-005, SC-006)

Status: Partially measured (deterministic checks recorded; real-app network capture pending)

## SC-005 — nothing is stored without Remember

`EnrollmentJobTests.testNotNowWritesNoKnownSpeakerSampleAssignmentOrRun` names a speaker in
the sheet, chooses Not now and saves. `SELECT count(*)` over `known_speakers`,
`voice_samples`, `identity_assignments` and `identification_runs` is 0 for each; the name
is meeting metadata on `meeting_speakers`. `testRememberCreatesTheProfileAndIdentityRowBeforeAnyLeaseAndStoresSamplesWithConsent`
then proves Remember gives 1 known speaker, ≥ 1 sample with `consent = 'remember'`, the
source meeting and cluster, and one `confirmed / new_profile_created` row.

## SC-006 — corrections never feed the rejected profile

`EnrollmentJobTests.testACorrectionNeverAddsToTheRejectedSpeakerEvenWithTheToggleOn` and
`IdentityStoreTests.testConfirmationAndCorrectionRecordWhatWasRejectedAndSurviveReruns`:
after a correction away from Tomáš, `rejected_candidates` holds the pair, an
`also_remember` request for Tomáš stores zero rows (`rejectedSource`), and a rerun keeps
the manual row. `testConfirmWithTheToggleOnAddsSamplesWithAlsoRememberConsent` and
`AssignSpeakersIdentityModelTests.testConfirmDraftsUserConfirmationAndOnlyTheToggleRequestsSamples`
prove the toggle is off by default and that Confirm alone requests no sample.
`MeetingIdentifierTests` prove automatic runs never call `addSamples`.

## Offline and content-free

- `scripts/check-identification-imports.sh` (part of `make check`) fails on any
  networking symbol under `Core/Identification`, the boundaries, the store or the
  Speakers features; `RuntimeCompatibilityTests.testIdentificationSourcesReferenceNoNetworkingSymbols`
  repeats the check in XCTest.
- `RuntimeCompatibilityTests.testEmbedderRefusesToLoadWhenOfflineModeIsOff` and
  `testMissingEmbedderFilesFailAsModelUnavailableWithoutDownloading`: the embedder
  loads only with `ModelHub.offlineMode` on and never fetches into the model directory.
- `ResourceRecorderTests.testIdentificationMetricsAreContentFreeAndKeyedOnlyByCategory`:
  no name, vector, time range, transcript text or meeting id enters a metric line.
- `TranscriptStoreTests.testExportAndCopyPathsReadNoIdentityVectorsOrScores`: the 006
  page (export) path reads none of the identity tables; the labeled page never reads
  `voice_samples` or `match_candidates`.

## Pending on the signed app

Quickstart scenarios 1 and 3 with Wi-Fi off and the Go server stopped, a `nettop`
capture, and a `strings`/SQL search of logs and exports for names and vectors have not
been run yet. Until they are, this file does not claim the network capture.
