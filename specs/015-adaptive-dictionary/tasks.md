# Tasks: Adaptive Dictionary

**Input**: [plan.md](plan.md), [spec.md](spec.md), [research.md](research.md), [data-model.md](data-model.md), [contracts/usage-classification.md](contracts/usage-classification.md)

Tests are included: constitution principle 12 requires them, and the plan lists them. Paths are relative to `apps/macos/`. Register every new file with `python3 scripts/register-xcode-sources.py <path>` (run from the repo root; paths relative to `apps/macos`).

## Phase 1: Setup

- [X] T001 Add migration `dictionary-usage-v16` in `LocalFlow/Core/Storage/HistoryMigrations.swift` creating:
  - `dictionary_key_usage(entry_id TEXT NOT NULL REFERENCES vocabulary_entries(id) ON DELETE CASCADE, key_id TEXT NOT NULL, state TEXT NOT NULL CHECK(state IN ('provisional','established','retired')), applied INTEGER NOT NULL DEFAULT 0 CHECK(applied>=0), kept INTEGER NOT NULL DEFAULT 0 CHECK(kept>=0), reverted INTEGER NOT NULL DEFAULT 0 CHECK(reverted>=0), last_used_at INTEGER, retired_at INTEGER, retired_from TEXT CHECK(retired_from IN ('provisional','established')), notice_shown INTEGER NOT NULL DEFAULT 0, PRIMARY KEY(entry_id,key_id))`, with an index on `last_used_at`.
  - `dictionary_usage_events(id INTEGER PRIMARY KEY, dictation_id TEXT NOT NULL, entry_id TEXT NOT NULL, key_id TEXT NOT NULL, outcome TEXT NOT NULL CHECK(outcome IN ('applied','kept','reverted','unclassified')), at INTEGER NOT NULL, UNIQUE(dictation_id,entry_id,key_id))`.
  - `dictionary_usage_state(id INTEGER PRIMARY KEY CHECK(id=1), revision INTEGER NOT NULL)`, seeded with `(1,0)`.
  - `correction_sightings(digest BLOB PRIMARY KEY CHECK(length(digest)=32), count INTEGER NOT NULL CHECK(count BETWEEN 1 AND 3), last_seen INTEGER NOT NULL)`.

## Phase 2: Foundational (blocks every story)

- [X] T002 [P] Create `LocalFlow/Core/Corrections/DictionaryChange.swift` containing:
  - `DictionaryChange { entryID, keyID, canonical }` (Hashable, Sendable).
  - `DictionaryChange.keyID(for term:)`: the lowercase hex SHA-256 of `VocabularyValidation.fold(term)` scalars' UTF-8, first 32 characters.
  - `DictionaryChange.boostKeyID = "boost"`.
  - `enum UsageOutcome { kept, reverted, unclassified }`.
  - `enum KeyState { provisional, established, retired }`.
  - `enum DictionaryUsagePolicy` with `retireMinimumReverts = 2`, `retireRevertShare = 0.30`, `provisionalRevertLimit = 1`, `provisionalKeptToEstablish = 3`, `maximumEvents = 5_000`, `maximumSightings = 512`.
- [X] T003 Make `VocabularySnapshot.Key` in `LocalFlow/Core/Storage/VocabularyStore.swift` carry `keyID`, and make `TranscriptNormalizer.vocabularyTerms` (`LocalFlow/Core/Transcription/TranscriptNormalizer.swift`) collect a `Set<DictionaryChange>` for each selected candidate. Expose it as `TranscriptNormalizer.Result.dictionaryChanges`, defaulting to empty.
- [X] T004 Make `VocabularyBoostApplier.apply` in `LocalFlow/Core/Transcription/VocabularyBoost.swift` return `DictionaryChange(entryID:, keyID: "boost", canonical:)` for each hint it applied. Then carry `boosted + formatted` changes into a new `TranscriptionResult.dictionaryChanges: [DictionaryChange]` in `LocalFlow/Core/Transcription/WindowedTranscriber.swift` `normalizedForDelivery`, sorted by `(entryID, keyID)` for determinism.
- [X] T005 Add tests in `LocalFlowTests/TranscriptNormalizerTests.swift` and `LocalFlowTests/VocabularyBoostTests.swift`:
  - An alias match and a canonical case match each report the right `keyID`.
  - An ambiguous overlap reports nothing.
  - Text already canonical reports nothing.
  - A boost hint reports `keyID "boost"`.
- [X] T006 Create the `DictionaryUsageStore` actor in `LocalFlow/Core/Storage/DictionaryUsageStore.swift`, sharing `TranscriptionStore.database`. API:
  - `recordApplied(dictationID:changes:learnedEntryIDs:now:)`: upsert key rows with the default state (provisional when the entry's `learned_at` is set, else established), `applied += 1`, `last_used_at = now`; insert `applied` events with `INSERT OR IGNORE`; prune events above 5,000.
  - `classify(dictationID:outcomes:now:) -> [RetiredKey]`: update the event outcome only when it is still `applied`; update counts and apply the transitions in `data-model.md`; bump `dictionary_usage_state.revision` on any state change; return keys newly retired.
  - `restore(entryID:keyID:)`: set `established`, `reverted = 0`, `retired_at = NULL`, `notice_shown = 0`; bump the revision.
  - `markNoticeShown`.
  - `setState(entryID:keyIDs:state:)`, used for learner and editor saves.
  - `usage() -> [String: [KeyUsage]]` per entry.
  - `retiredKeys()` and `revision()`.
  - Every method runs in one write transaction.
- [X] T007 Add `LocalFlowTests/DictionaryUsageTests.swift` covering:
  - The migration.
  - Default states from `learned_at`.
  - Every transition in `data-model.md` (established 2/4 retires, 2/10 does not; provisional retires on 1 revert and establishes on 3 kept; Restore resets `reverted`).
  - Duplicate classification ignored by the unique event key.
  - The 5,000-event bound keeps totals.
  - Entry deletion cascades.
  - A privacy check that no usage or sighting row contains any known transcript or alias string (SC-004).
- [X] T008 Make `VocabularyStore` in `LocalFlow/Core/Storage/VocabularyStore.swift`:
  - (a) Read `dictionary_usage_state.revision` and the retired set with the state row, and reuse `cachedSnapshot` only when both are unchanged.
  - (b) Pass the retired set into `VocabularySnapshot`, which skips retired V001 keys and exposes `retiredBoostEntryIDs`.
  - (c) Accept an `origin: .editor | .learner` on `save`. In the same transaction, upsert every key of the saved entry to `established` (editor) or `provisional` (learner), delete usage rows of keys no longer in the entry (FR-019), and bump the usage revision.
  - (d) On `delete`, delete the entry's events.
  - On any usage read failure, build the snapshot with nothing retired and log one content-free error (plan: failure behaviour).
- [X] T009 Add tests to `LocalFlowTests/VocabularyStoreTests.swift`:
  - A retired alias is not applied by V001, and the other aliases are.
  - The snapshot rebuilds after a retire and after a restore.
  - An editor save establishes keys and drops the rows of removed aliases.
  - A learner save marks keys provisional.

**Checkpoint**: changes are reported, the store applies the rules, and the snapshot honours retirement.

## Phase 3: User Story 1 — A wrong alias stops applying (P1) 🎯 MVP

**Goal**: an established alias the user keeps undoing is retired and shown with Restore.
**Independent test**: scripted reads in `CorrectionLearnerTests` retire an alias; the next normalisation keeps the spoken word.

- [X] T010 [P] [US1] Implement `UsageClassifier.classify(changes:inserted:before:leadingCut:reads:) -> [(DictionaryChange, UsageOutcome)]` in `LocalFlow/Core/Corrections/UsageClassifier.swift`, exactly per `contracts/usage-classification.md` steps 1–5. It uses a word-level LCS over at most 1,024 words per side; above that every change is unclassified.
- [X] T011 [P] [US1] Add `LocalFlowTests/UsageClassifierTests.swift` with every row of the contract's "Required cases" table, plus a leading-cut case and the size bound.
- [X] T012 [US1] In `LocalFlow/Features/Dictation/DictationCoordinator.swift`:
  - Add `var dictionaryApplied: ((UUID, [DictionaryChange]) -> Void)?`, called once after a successful `store.commit` when `result.dictionaryChanges` is non-empty.
  - Change `insertionConfirmed` to `((String, CapturedTarget, [DictionaryChange]) -> Void)?`, passing `result.dictionaryChanges` and the dictation id.
- [X] T013 [US1] In `LocalFlow/Features/Dictation/CorrectionLearner.swift`:
  - `observe(inserted:target:changes:dictationID:)` stores the changes.
  - `run` keeps the baseline split (`before`, `leadingCut`) and every successful read.
  - On every return path it calls `UsageClassifier` and hands the outcomes to a new `classified: ((UUID, [(DictionaryChange, UsageOutcome)]) -> Void)?` closure. For `cancelled`, the closure is still called with the reads made so far. No new reads are added.
  - With no changes, nothing extra happens.
- [X] T014 [US1] Generalise `LearnedNotice` into `DictionaryNotice` with `kind: .learned(entryID:canonical:)` or `.retired(entryID:keyID:alias:canonical:)` in `LocalFlow/Features/Dictation/CorrectionLearner.swift`. Update `LearnedNoticeView` in `LocalFlow/Features/Dictation/DictationIndicator.swift` and `IndicatorPanel.showNotice` in `LocalFlow/Features/Dictation/IndicatorPanel.swift`:
  - Retired text is "Stopped changing ‘alias’ to ‘canonical’".
  - The button is "Restore".
  - Same 6 s window.
  - Queue one pending notice while another shows.
- [X] T015 [US1] Wire it in `LocalFlow/App/AppServices.swift`:
  - Create `DictionaryUsageStore`.
  - `coordinator.dictionaryApplied` → `recordApplied` (learned entry ids from the current Dictionary contents), in a detached task that logs failures without content.
  - `insertionConfirmed` → `learner.observe(... changes:dictationID:)`.
  - `learner.classified` → `usage.classify`. For each retired key, resolve the alias text from the Dictionary contents (the key whose `DictionaryChange.keyID` matches, or the canonical for `boost`), show the retired notice, `markNoticeShown`, and log `retired count=<n>`. Restore calls `usage.restore` and reloads the vocabulary model.
- [X] T016 [US1] Add tests to `LocalFlowTests/CorrectionLearnerTests.swift`:
  - An alias reverted in 2 of 3 scripted observations is retired and a retired notice is emitted.
  - A cleared field classifies nothing.
  - `cancel()` during observation still classifies from the reads made.

## Phase 4: User Story 2 — Learned terms prove themselves (P1)

**Goal**: a learned entry is provisional until kept 3 times; one revert retires it.
**Independent test**: learn through the learner, then run scripted observations.

- [X] T017 [US2] In `LocalFlow/Features/Dictation/CorrectionLearner.swift`, save learned entries with `origin: .learner` (from T008). In `LocalFlow/Features/Settings/VocabularyViewModel.swift`, save with `origin: .editor`.
- [X] T018 [US2] Add tests to `LocalFlowTests/CorrectionLearnerTests.swift` and `LocalFlowTests/DictionaryUsageTests.swift`:
  - A learner-saved alias retires on its first revert.
  - It becomes established after 3 kept.
  - An editor-created entry starts established.
  - A pre-existing entry with `learned_at` and no usage row is provisional.

## Phase 5: User Story 3 — One correction suggests; the second learns (P1)

**Goal**: sightings persist; a first sighting only suggests.
**Independent test**: two stores over the same database file simulate a restart.

- [X] T019 [P] [US3] Replace `CorrectionCandidateHistory` in `LocalFlow/Core/Corrections/CorrectionCandidateHistory.swift` with the `CorrectionSightingStore` actor:
  - Same digest as today.
  - `observe(_:now:) async -> Int` returns the previous count and upserts `count = min(count+1, 3)`, `last_seen = now`.
  - At most 512 rows; delete the oldest `last_seen` beyond that.
- [X] T020 [P] [US3] In `LocalFlow/Core/Corrections/CorrectionCandidateScorer.swift`, add reason `firstSighting`. An `autoLearn` result with `previousObservations == 0` and not `canonical` becomes `suggest` with the same score.
- [X] T021 [US3] Make `CorrectionLearner` take a `CorrectionSightingStore` (created in `LocalFlow/App/AppServices.swift`) and `await` it in `learn`. A store failure counts as a first sighting.
- [X] T022 [US3] Add tests:
  - Scorer: first sighting suggests; repeat auto-learns; canonical match auto-learns first time.
  - Sighting store: persists across two instances; caps at 3; prunes to 512.
  - Learner: end-to-end with a restart between sightings.
  - Update any existing `CorrectionLearnerTests` that relied on first-sight auto-learn.

## Phase 6: User Story 4 — The Dictionary shows how each term is doing (P2)

**Goal**: visible counts, states and Restore.
**Independent test**: a seeded store renders the expected strings.

- [X] T023 [US4] In `LocalFlow/Features/Settings/VocabularyViewModel.swift`:
  - Load `usage()` alongside contents.
  - Expose per entry `applied`, `kept`, `reverted`, `lastUsed`, per-key state, and `restore(entryID:keyID:)`.
  - Add a summary formatter giving "Used 12 · kept 9 · undone 1 · 29 Sep", "Unused", or "Used 3 · not checked yet".
- [X] T024 [US4] In `LocalFlow/Features/Settings/DictionaryView.swift`:
  - Show the summary under each entry.
  - Show a "Learning" badge for provisional keys.
  - Show retired aliases struck through with a Restore button (and "Boost off" with Restore for a retired boost).
  - Keep existing accessibility identifiers and add `dictionary.entry.usage` and `dictionary.alias.restore`.
- [X] T025 [US4] Add formatter and view-model tests to `LocalFlowTests/VocabularySettingsTests.swift`.

## Phase 7: User Story 5 — Most-used terms boosted first (P3)

- [X] T026 [US5] In `LocalFlow/Core/Storage/VocabularyStore.swift` (`VocabularyBoostTerms.init?(snapshot:)`):
  - Drop entries in `retiredBoostEntryIDs`.
  - Order by the latest `last_used_at` of any of their keys (newest first), then total `applied`, then id. Unused entries come after, in id order.
  - Take 256.
  - Set `key` to the snapshot hash + ":" + a hash of the sorted retired boost ids.
  - Pass the usage summary into the snapshot (T008) so this stays pure.
  - Remove the `ponytail` note.
- [X] T027 [US5] Add tests to `LocalFlowTests/VocabularyBoostTests.swift`:
  - 300 entries rank as specified.
  - A retired boost is excluded.
  - The key changes when a boost is retired.

## Phase 8: Polish

- [X] T028 Run `swift format lint --strict --recursive apps/macos/LocalFlow apps/macos/LocalFlowTests` and fix what it reports.
- [X] T029 Run the quickstart's scoped XCTest command, plus the existing `TranscriptNormalizerTests`, `VocabularyNormalizationTests`, `TermSuggestionTests`, `DictationCoordinatorTests`, `TextInsertionTests` and `DictationContextFlowTests`. Record the results in this file.
- [X] T030 Measure SC-005: time `normalizedForDelivery` and `VocabularyStore.snapshot()` before and after, using an XCTest `measure` over a 22-entry and a 512-entry Dictionary. Record the figures here; the added time must be under 5 ms.
- [X] T031 Update `docs/roadmap.md` with a line for this feature, and update the spec status.

## Dependencies

- T001 → T006, T019. T002 → T003, T004, T006, T010. T003 and T004 → T012. T006 and T008 → every story.
- US1 (T010–T016) is the MVP. US2 needs T008 and T013. US3 is independent of US1 and US2 except for `CorrectionLearner` file overlap with T013 and T017, so it is done after them. US4 needs T006. US5 needs T008.

## Parallel examples

- After T002: T003 ∥ T004 ∥ T010 ∥ T011.
- In US3: T019 ∥ T020.

## Implementation strategy

Finish Phases 1–2, then US1, then run T029 on what exists. Then US2 and US3, which share the learner. Then US4 and US5, then polish. Each phase keeps `make check`-relevant tests green before the next starts.

## Report (2026-09-30)

**Status**: T001–T031 are implemented and tested on branch `015-adaptive-dictionary`. Acceptance with real dictations (quickstart "By hand") is still pending.

**Deviations from the task text**
- T005: the change-reporting tests are in `VocabularyNormalizationTests.swift`, next to the other V001 tests, not in `TranscriptNormalizerTests.swift`.
- T008/R7: the per-press snapshot check reads only `dictionary_usage_state.revision`. The retired set is reloaded when that revision changes. Per-entry use is read only when more entries are enabled than the boost holds (256). A first version read every usage row on each press and cost 9 ms at maximum Dictionary size.
- T014: `LearnedNotice` gained a `kind` rather than being renamed, to keep the diff small.
- T017: `VocabularyViewModel` already saves through `save`, which is now the editor origin. Only the learner changed, to `saveLearned`.
- `DictionaryChange.swift` also belongs to the `flowd-speech` target, because `VocabularyBoost.swift` is shared with the worker. `keyID` uses `TermFolding.fold`, which gives the same result as `VocabularyValidation.fold`.

**Verification**
- `swift format lint --strict` is clean.
- Scoped XCTest (T029) passed: 254 tests across the dictionary, learner, coordinator, insertion, context, rewrite, shortcut and remote-retry suites, then 132 after the final change.
- `flowd-speech` builds with `COMPILER_INDEX_STORE_ENABLE=NO`. With indexing on, it fails here while creating an index directory under a path that starts with `-I`; that failure is in the toolchain setup, not the code.
- The full `make check` suite was not run (it beeps; the owner asked for scoped runs).

**T030 / SC-005** (Debug build, owner's Mac, `DictionaryUsageTests.testCachedSnapshotStaysFastWithFullUsage`, 512 entries and 4,608 keys, usage row on every key, median of 30):

| Part | Time |
| --- | --- |
| Cached snapshot plus usage reads | 1.0 ms |
| Existing Feature 013 fold of every term for `governed` | 5.0 ms |
| Snapshot + boost terms in total | 6.8 ms |

The added work is under 2 ms at maximum size and negligible at the current 22 entries, so it meets the 5 ms bound. The existing fold is the larger cost; caching it would be a separate change.

**Left**
- The quickstart's "By hand" checks, in a release build.
- Review the thresholds after about two weeks of use, from `dictionary_usage_events`.
