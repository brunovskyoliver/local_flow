# Feature 004 baseline

Recorded at implementation start (T001). Every figure below that is not a pin or a
scope statement is **unmeasured** until a later acceptance task writes it.

## Starting point

| Item | Value |
| --- | --- |
| Starting commit | `d6b2217` ("feature 003") on `main` |
| Working tree at start | dirty: `specs/004-meeting-capture-foundation/spec.md` modified; `checklists/`, `contracts/`, `data-model.md`, `plan.md`, `quickstart.md`, `research.md`, `tasks.md` untracked (planning artefacts only; no source change) |
| Xcode | 26.4.1 (17E202) |
| macOS on the development machine | 26.6.2 (25G83) |
| Deployment target | macOS 14.0, Swift 6 language mode |
| GRDB | 7.10.0 (exact pin in `project.pbxproj`) |
| FluidAudio | 0.15.7 (unchanged; not referenced by this feature) |
| Development machine | `Mac17,2`, Apple M5, 32 GB (`hw.memsize` = 34359738368) |
| Reference machine (memory-budget.md) | Apple M5 MacBook Pro, 32 GB; the development machine above is the same class |

## Constitution scope check

- No model is created, loaded or referenced. `ModelLifecycleCoordinator`, `FluidAudioEngine` and `WhisperKit` symbols do not appear under `Core/Meetings/` or `Features/Meetings/` (checked by `MeetingInstrumentationTests`).
- No server or network path. `URLSession` and `RewriteClient` do not appear in the meeting sources.
- Permissions requested: microphone (`AVCaptureDevice`) and screen recording (`CGPreflightScreenCaptureAccess` / `CGRequestScreenCaptureAccess`) only, from the explicit Start action.
- Storage: existing `history.sqlite` through migration `meetings-v5`; media as files under `Meetings/<uuid>/`.

## Figures that do not exist yet

| Figure | Status |
| --- | --- |
| Start-to-recording time (SC-001) | unmeasured |
| 60-minute RSS slope and peak overhead (SC-003) | unmeasured |
| Per-track duration accuracy against `recorded_ms` (SC-004) | unmeasured |
| Recorded-duration arithmetic on hardware (SC-005) | unmeasured; deterministic test only |
| Storage-failure time-to-notice (SC-006) | unmeasured; deterministic test only |
| Force-quit / reboot recovery on hardware (SC-002) | unmeasured; deterministic reconciler tests only |
| Live two-source check (T040) | not run |
| Relocation check (T052) | not run |
| Deletion checksums and sleep case (T079) | not run |
| Regression runs (T082) | see "Regression runs" below once written |

## Live two-source check (T040)

Not run. Requires the development machine with microphone and Screen & System Audio
Recording granted to a signed build. Expected record: microphone file contains only
speech, system file only the played audio, no virtual audio device installed.

## Relocation check (T052)

Not run. Expected record: with `Meetings/` moved aside the detail view shows every
track as file missing; with it moved back the tracks play again without any row edit.

## SC-001 / SC-004 / second-Start refusal (T075)

Not run. Five Start-to-recording timings, per-track duration vs `recorded_ms` for each
completed meeting, and the second-Start refusal go here.

## Deletion checksums and sleep case (T079)

Not run.

## Regression runs (T082)

Recorded 2026-09-18 on the development machine (`Mac17,2`, macOS 26.6.2, Xcode 26.4.1),
Debug configuration, `make check` (Swift format lint, script syntax, Python validators, Go
`gofmt`/`test`/`vet`, `plutil -lint`, the full XCTest run, `check-prerequisites.sh`):

- Full suite with the feature present and no meeting active: **604 tests, 592 passed,
  0 failed, 12 skipped** (the skips are the pre-existing opt-in render/probe tests). Exit 0.
- Feature 001–003 suites run unchanged apart from two deliberate edits: `DictationCoordinator`
  gained an optional `admissionGuard`/`admissionRefused` pair that is nil unless a meeting is
  active (covered by `DictationCoordinatorTests.testMeetingGuardRefusesDictationAndAbsentGuardLeavesTheFlowUnchanged`),
  and `TranscriptionStoreTests.testSQLiteFullRollsBackSaveAndKeepsReservationForRetry` raised its
  SQLite page bound from 160 KiB to 224 KiB because migration `meetings-v5` adds schema pages
  (the test still proves one 64 KiB entry fits and a second does not).
- Three consecutive local runs of the fifteen meeting suites (`MeetingLifecycleTests`,
  `MeetingStoreTests`, `MeetingSampleRingTests`, `MeetingTrackEncoderTests`, `ADTSValidatorTests`,
  `FileSegmentWriterTests`, `MeetingTrackWorkerTests`, `MeetingPermissionsTests`,
  `MeetingCoordinatorTests`, `MeetingNotesEditorTests`, `MeetingReconcilerTests`,
  `MeetingLibraryTests`, `TrackPlaybackTests`, `MeetingDeletionTests`,
  `MeetingInstrumentationTests`): 110 tests each, 0 failures each (35.7 s, 36.2 s, 35.8 s).
  The suites run on `FakeMeetingClock`, `FakeMeetingAudioSource` and `FakeSegmentWriter`.
