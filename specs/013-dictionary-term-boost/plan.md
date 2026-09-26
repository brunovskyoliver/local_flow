# Implementation plan: Dictionary term boosting and suggestions

**Feature identifier**: `013-dictionary-term-boost` | **Date**: 2026-09-26 | **Spec**: [spec.md](spec.md) | **ADR**: [0027](../../docs/adr/0027-dictionary-term-boosting.md)

## Summary

`VocabularyBoostTerms` (the enabled canonical spellings of the session's Dictionary snapshot) is attached to the model lease. `FluidAudioRuntime.transcribe(_:boost:)` runs the CTC spotter alongside the TDT decode, rescored with FluidAudio's public API, and returns `VocabularyBoostHint`s that passed `VocabularyBoostPolicy`. `WindowedTranscriber` applies hints to the assembled text before `TranscriptNormalizer` as rule `V002`. The Dictionary view lists `TermSuggestion`s mined by `TermSuggestionMiner` from `TermSuggestionStore`.

## Technical context

| Item | Decision |
| --- | --- |
| Dependencies | Existing FluidAudio 0.15.7, CoreML, NaturalLanguage, AppKit `NSSpellChecker`, GRDB. No new package |
| Model | `parakeet-ctc-110m.json` descriptor, capability `keyword_spotting`, 102,802,455 bytes, verified by `ModelProvisioner` |
| Storage | Migration `term-suggestions-v14`: `term_suggestions(canonical, alias, sightings, dismissed, last_seen)`, at most 500 rows |
| Performance | SC-003 measured, see [research.md](research.md) R3 |
| Testing | `VocabularyBoostTests`, `TermSuggestionTests`, `CorrectionLearnerTests`; opt-in `VocabularyBoostBenchmarkHarness` outside `make check` |

## Constitution check

Pass, with ADR 0027 recording that dictation recognition now uses a second local model.

| Principle | Result |
| --- | --- |
| Native client, no new runtime | Pass: Swift and CoreML only |
| Offline after provisioning | Pass: optional model, pinned and verified |
| Privacy | Pass: no text or terms in logs; benchmark audio and results stay in `build/` |
| Bounded memory | Pass: one extra encoder pass per window; 256 terms; 500 suggestion rows; 1,000 recent contexts scanned |
| Simple persistence | Pass: one GRDB migration |
| Model lifecycle | Pass: booster owned by the Parakeet runtime lease |
| Meetings separate | Pass: unchanged |

## Bounds and failure behaviour

Booster missing or failing to load: dictation without it, logged once. Spotter failure for a window: that window gets no hints. Suggestion read failure: the list is hidden, the Dictionary works.
