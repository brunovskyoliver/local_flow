# Extraction record (T010–T015)

Date: 2026-10-01. Branch `016-ios-dictation-foundation`.

## LocalFlowSpeech (commit 5f493b2, spool change 27e229e)

Moved with `git mv` from `apps/macos/LocalFlow/Core/…`:

- `SpeechBoundaries.swift`, `ModelWorkloadBoundaries.swift`
- `FluidAudioEngine.swift`, `VocabularyBoost.swift`, `MeetingLanguage.swift`
- `ModelLifecycleCoordinator.swift`, `ModelDescriptor.swift`, `ModelProvisioner.swift`
- `DictionaryChange.swift`, `AudioSpool.swift`, `ChunkPlanner.swift`, `TranscriptAssembler.swift`

`flowd-speech` links the `LocalFlowSpeech` product. `nm` on the Debug worker binary finds no GRDB symbols.

## LocalFlowCore (T012)

Moved whole with `git mv`:

- Storage: `TranscriptionStore`, `TranscriptionEntry`, `HistoryMigrations`, `VocabularyStore`, `DictionaryUsageStore`, `TermSuggestionStore`
- Corrections: `CorrectionCandidate`, `CorrectionCandidateHistory`, `CorrectionCandidateScorer`, `CorrectionStopwords`, `TermSuggestions`, `UsageClassifier`
- Transcription: `TranscriptNormalizer`, `TranscriptionProvenance`, `WindowedTranscriber`, `TranscriptionPipelineIdentity`
- `Rewrite/RewriteAttempt.swift`, `Context/AppCategory.swift`, `Context/AppContextSnapshot.swift`

Value types cut from a Mac file into their own package file (the Mac file keeps everything else):

| New package file | Types | Cut from |
| --- | --- | --- |
| `MeetingStates.swift` | `MeetingState`, `MeetingFailureReason` | `Meetings/MeetingLifecycle.swift` |
| `DiarizationStates.swift` | `DiarizationFailureCategory` | `Diarization/DiarizationRun.swift` |
| `IdentificationStates.swift` | `IdentificationTrigger`, `IdentificationFailureCategory`, `IdentityState`, `IdentityOrigin`, `SampleConsent`, `CandidateTier` | Identification files |
| `AnalysisStates.swift` | `AnalysisRunState`, `AnalysisTrigger`, `AnalysisFailureCategory`, `AnalysisLanguage`, `AnalysisItemKind`, `OverlayField` | `Intelligence/AnalysisRun.swift`, `IntelligenceBoundaries.swift` |
| `TranscriptionEnvelope.swift` | `TranscriptionEnvelope` | `DictationBoundaries.swift` |
| `RemoteModels.swift` | `RemoteFailureReason`, `RemoteModelIdentity` | `Remote/RemoteProtocol.swift` |
| `RewriteModels.swift` | `RewriteMode`, `RewriteBounds`, `RewriteFailureCategory`, `RewriteResult`, `RewriteFailure` | `Rewrite/RewriteProtocol.swift` |

Mac-only pieces cut out of moved files, into new Mac files:

- `Core/Context/ContextSettings.swift`: `ContextSettings` and `AppCategory.ownBundleID` (reads `AppIdentity`).
- `Core/Context/AppContextSnapshotBuilder.swift`: `AppContextSnapshot.make(_:styleHints:)` (uses the Mac term extractor).

## Deviations from the package contract

- `TranscriptNormalizer`, `TranscriptionProvenance`, `WindowedTranscriber` and `TranscriptionPipelineIdentity` are in `LocalFlowCore`, not `LocalFlowSpeech`. They need `VocabularySnapshot`, which lives in the GRDB file `VocabularyStore.swift`. The worker never used them, so it still links no GRDB.
- The storage closure is wider than the plan's list: the migrator builds CHECK constraints from the meeting, diarization, identification and analysis enums, and `TranscriptionStore` stores rewrite attempts, context rows and remote failure reasons. Only those value types moved; the runtimes stay in the Mac app.
- The English-word seam is `englishWords: @MainActor @Sendable (Set<String>) -> Set<String>` on `FluidAudioEngineFactory`, not `(String) -> Bool`. It batches like the Mac's `VocabularyBoostPolicy.englishWords(in:)`. The Mac app and the worker each add a convenience init that passes it.
- `AudioSpool` accepts a root-owned symlink in the path (`/var`, `/tmp`). Every iOS container path starts with `/var`, which is a root-owned link to `/private/var`, and the old check refused it. Links owned by anyone else are still refused.

## Access

- The package sources now contain 719 `public` modifiers (the moved Mac files had none), plus explicit `public init`s where a memberwise init crosses the module boundary. No signature changed otherwise.
- Structs that became public and are stored in `Sendable` Mac types got an explicit `Sendable` (`RecognitionAdmission`), because public structs lose implicit `Sendable`.
- Research R1 holds: Mac tests reach package internals with `@testable import LocalFlowSpeech` / `@testable import LocalFlowCore` in Debug. No member was made public for tests only.

## Verification

- Mac app Debug build, `build-for-testing` and the `flowd-speech` target build pass.
- `swift build` and `swift test` in `packages/LocalFlowCore` pass (3 spool tests).
- Scoped Mac tests (23 classes: all stores, migrations, `MacCompatibilityTests`, Dictionary, normalizer, windowed transcription, context, corrections): 324 run, 10 skipped, 0 failures.
- The full suite runs in T019 (`acceptance/mac-unchanged.md`).
