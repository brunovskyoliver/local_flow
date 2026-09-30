# Implementation plan: Adaptive Dictionary

**Branch**: `015-adaptive-dictionary` | **Date**: 2026-09-30 | **Spec**: [spec.md](spec.md)

## Summary

The V001 and V002 rules report which Dictionary key changed each dictation (`DictionaryChange`). The coordinator records those as *applied* when the dictation is committed, and passes them with the inserted text to the correction learner. When its observation ends, the learner classifies each change as kept, reverted or unclassified against its last intact read ([contract](contracts/usage-classification.md)). `DictionaryUsageStore` applies the retirement rules in the same transaction and returns newly retired keys, which are shown as a Restore notice. `VocabularySnapshot` skips retired keys and ranks boost terms by use. Sightings of corrections move to SQLite, and a first sighting only suggests.

## Technical context

| Item | Decision |
| --- | --- |
| Language | Swift 6.0, macOS 14+, existing app target. No server change |
| Dependencies | GRDB, CryptoKit (existing). No new package |
| Storage | Migration `dictionary-usage-v16`, four tables ([data-model.md](data-model.md)) in `history.sqlite` |
| New types | `DictionaryChange`, `DictionaryUsagePolicy`, `UsageClassifier` (pure), `DictionaryUsageStore` (actor), `CorrectionSightingStore` (actor), `DictionaryNotice` |
| Changed types | `TranscriptNormalizer`, `VocabularyBoostApplier`, `TranscriptionResult`, `VocabularySnapshot`, `VocabularyStore` (usage revision, key upsert on save), `VocabularyBoostTerms` (ranking, key), `CorrectionCandidateScorer` (first sighting), `CorrectionLearner` (sightings store, classification, reads kept), `DictationCoordinator` (two closures), `IndicatorPanel`/`LearnedNoticeView` (notice kinds), `DictionaryView`/`VocabularyViewModel` (usage, Restore) |
| Testing | XCTest: `UsageClassifierTests`, `DictionaryUsageTests` (store, rules, migration, bounds, privacy), additions to `CorrectionLearnerTests`, `VocabularyBoostTests`, `VocabularyStoreTests`, `TranscriptNormalizerTests` |
| Performance | V001/V002 bookkeeping is a set insert per change. Classification runs after insertion, off the dictation path: an LCS over at most ~700 × ~760 words, once per observation. Snapshot cache check adds one indexed read of `dictionary_usage_state` |
| Scale | ≤ 512 entries, ≤ 4,608 keys, 5,000 events, 512 sightings |

## Constitution check

Pass. No exception, so no ADR.

| Principle | Result |
| --- | --- |
| 1 Native client | Pass: Swift only, in existing boundaries (`Core/Corrections`, `Core/Storage`, `Features/Dictation`, `Features/Settings`) |
| 2 Memory | Pass: all tables and the classifier input are bounded (R12) |
| 4 Local-first | Pass: no network |
| 5 Privacy | Pass: ids, digests, counts and times only; logs carry outcomes and counts, never text (FR-017, SC-004 test) |
| 7 Simple persistence | Pass: one GRDB migration, transactions per classification; only schema this feature uses |
| 9 Recoverability | Pass: retirement never deletes Dictionary text; usage write failure never affects a dictation (FR-020) |
| 12 Testability | Pass: classifier and rules are pure and tested without Accessibility |
| 13 Observability | Pass: content-free log lines for retire, restore and classification counts |
| 14 Scope | Pass: Phase 1 only; sound matching and history mining are out |

Re-check after design: unchanged.

## Project structure

```text
specs/015-adaptive-dictionary/
├── spec.md, plan.md, research.md, data-model.md, quickstart.md
├── contracts/usage-classification.md
└── checklists/requirements.md

apps/macos/LocalFlow/
├── Core/Corrections/DictionaryChange.swift          new: change, outcome, policy
├── Core/Corrections/UsageClassifier.swift           new: pure contract implementation
├── Core/Corrections/CorrectionCandidateHistory.swift → CorrectionSightingStore (SQLite)
├── Core/Corrections/CorrectionCandidateScorer.swift  first-sighting rule
├── Core/Storage/DictionaryUsageStore.swift          new
├── Core/Storage/HistoryMigrations.swift              dictionary-usage-v16
├── Core/Storage/VocabularyStore.swift                usage revision, retired set, key upsert
├── Core/Transcription/TranscriptNormalizer.swift     report keys
├── Core/Transcription/VocabularyBoost.swift          report boost changes, ranking, key
├── Core/Transcription/WindowedTranscriber.swift      carry dictionaryChanges
├── Features/Dictation/CorrectionLearner.swift        keep reads, classify, sightings store
├── Features/Dictation/DictationCoordinator.swift     dictionaryApplied, changes to insertionConfirmed
├── Features/Dictation/{IndicatorPanel,DictationIndicator}.swift  notice kinds
├── Features/Settings/{DictionaryView,VocabularyViewModel}.swift  usage and Restore
└── App/AppServices.swift                             wiring
apps/macos/LocalFlowTests/                            tests listed above
```

New files are registered with `scripts/register-xcode-sources.py`.

## Bounds and failure behaviour

- Usage store errors are logged without content and swallowed; the dictation, insertion and learning continue (FR-020).
- If the usage tables cannot be read when the snapshot is built, the snapshot is built with no retired keys and the default ranking, and one error is logged. A broken usage table therefore never blocks dictation.
- Classification with no intact read writes `unclassified` and changes no state.
- The migration adds tables only; rollback would mean dropping them, and Dictionary entries are untouched.

## Complexity tracking

None.
