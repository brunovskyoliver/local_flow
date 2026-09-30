# Research: Adaptive Dictionary

Each entry: decision, why, what else was considered. Code references are as of branch `015-adaptive-dictionary`.

## R1. What identifies an alias

**Decision**: A *key* is one term of an entry that V001 matches: the canonical spelling or one alias. It is identified by `(entry_id, key_id)`, where `key_id` is the lowercase hex SHA-256 of the key's folded scalars (`VocabularyValidation.fold`), truncated to 32 characters. The speech-level boost of an entry uses `key_id = "boost"`.

**Why**: V001 matches the canonical spelling too, not only aliases (`VocabularySnapshot` builds keys from `[canonical] + aliases`), so a case fix like "zabbix" → "Zabbix" is a change the user can undo. Deriving the id from the folded text means editing one alias resets only that alias (FR-019), and reordering aliases changes nothing. The digest keeps alias text out of usage rows (FR-017); the text itself already lives in `vocabulary_entries`.

**Alternatives**: Alias index (breaks on reorder and on any edit to the entry). Storing the alias text (duplicates text into a second table for no gain).

## R2. Where changes are recorded

**Decision**: `TranscriptNormalizer.vocabularyTerms` and `VocabularyBoostApplier.apply` each return the `(entry_id, key_id, canonical)` of every change they made. `TranscriptionResult` carries them as `dictionaryChanges`. The coordinator reports them once per committed dictation through a new `dictionaryApplied` closure, and passes them with the inserted text to `insertionConfirmed`.

**Why**: Both rules already know the entry; the normalizer knows the matched key, so adding the key costs one field. Recording at commit means "applied" is counted even when insertion falls back to the clipboard. Keeping the store write outside the coordinator keeps the dictation path free of a new dependency and off its critical path (FR-020).

**Alternatives**: Re-deriving changes by diffing raw and normalized text (fragile, and loses which key matched). Recording inside `TranscriptionProvenance` (it is sealed evidence with its own bounds; usage is mutable state).

## R3. Locating a change in the inserted text

**Decision**: After a confirmed insertion, each change is located by searching the inserted text for its canonical spelling as whole words (the same term-boundary rule V001 uses), case-sensitive. All occurrences are the change's *spans*, as word indexes into the inserted text. A change with no occurrence is unclassified (FR-004).

**Why**: Between V001 and insertion come context spelling and the LLM rewrite, which can move or change text. Searching the final text for the exact canonical is robust to movement and correctly gives up when the rewrite altered the term. Marking every occurrence is conservative: if the user undoes any of them, the change counts as reverted.

**Alternatives**: Carry character offsets through spelling and rewrite (the rewrite has no alignment; impossible to do reliably).

## R4. Kept or reverted

**Decision**: The correction learner keeps the last read in which the passage is *intact*. At the end of observation, whatever the stop reason, it aligns the inserted words with that read's words with a word-level longest common subsequence. The passage is intact when at least half of the inserted words align and the margin before the insertion is unchanged. For each located change:
- **Reverted**: any word of any of its spans is unaligned, and the nearest aligned words on both sides of that span (or the passage edge) are aligned in order. The edit is local.
- **Kept**: all of its span words aligned.

No read at all, or no intact read, leaves every change unclassified.

**Why**: The existing `CorrectionDetector` accepts exactly one contiguous edit of 1–3 words and stops the learner at the first one. That is right for learning but too narrow for attribution: a user may fix two things, or retype a longer phrase around the term. LCS over at most ~700 words (4,096 UTF-16 units) runs once per insertion, off the dictation path. The "intact" test stops a cleared field (message sent with Return) from reading as a revert of everything.

**Alternatives**: Reusing `CorrectionDetector` only (misses multi-edit fixes; a revert like "John" → "jon" is not term-shaped and returns early as `rejected`, which is fine for learning but must still be classified). Common prefix/suffix trimming (merges separate edits into one range and produces false reverts).

## R5. When classification runs

**Decision**: Classification happens in `CorrectionLearner.run` just before it returns, for every stop reason, including `learned`, `rejected`, `windowElapsed`, `focusChanged` and `cancelled` (a new dictation starts). The result is written by a detached task so that cancelling the observation does not cancel the write.

**Why**: The learner already stops at the first stable edit, when focus leaves, or when a new dictation begins. In every case the last intact read is the best available final state. No new reads are made (spec resource section).

**Alternatives**: Extending the window after `learned` (more reads; the learner stops for good reasons).

## R6. Retirement and provisional rules

**Decision**: `DictionaryUsagePolicy` holds the constants `retireMinimumReverts = 2`, `retireRevertShare = 0.30` (strictly more than), `provisionalRevertLimit = 1`, `provisionalKeptToEstablish = 3`. The rate is `reverted / (kept + reverted)`. Rules are evaluated inside the transaction that records a classification.

A key's initial state is *provisional* when its entry has `learned_at` set and the key has no usage row yet; otherwise *established*. Saving an entry from the Dictionary editor upserts every key of that entry as established (FR-007). Saving from the correction learner upserts its keys as provisional.

**Why**: Owner decisions. Deriving the default from `learned_at` makes the 12 existing learned entries provisional with no migration of data (spec edge case).

**Alternatives**: Bayesian or time-decayed scores (premature without data; Phase 2 can revisit with the event log).

## R7. How a retired key stops applying

**Decision**: `VocabularySnapshot` gains the set of retired `(entry_id, key_id)` and uses it to skip V001 keys and boost terms. The retired set and a `usage_revision` are read with the vocabulary state row. The cached snapshot is reused only when both the vocabulary state and the usage revision are unchanged. `VocabularyBoostTerms.key` becomes the snapshot hash plus a digest of the retired boost set, so the rescorer rebuilds when a boost is retired or restored.

A retired key is left out of `governed` too, so the boost no longer treats that span as owned by V001.

**Why**: The snapshot is loaded on every press, and its cache is keyed by the state row (`VocabularyStore.snapshot()`). Bumping the Dictionary's own `revision` for a retirement would make an open editor fail its next save with a revision conflict. A separate usage revision avoids that.

**Alternatives**: Toggling `enabled` or deleting the alias (violates FR-009 and loses the restore path).

## R8. Persistent sightings

**Decision**: Replace the in-memory `CorrectionCandidateHistory` with `CorrectionSightingStore` over a table of `(digest BLOB PRIMARY KEY, count, last_seen)`. The digest is computed as today (SHA-256 of the length-framed, NFC source and replacement). Counts are capped at 3 and there are at most 512 rows; the least recently seen rows are pruned on insert.

**Why**: FR-014. The digest scheme is already reviewed as content-free.

**Alternatives**: Storing in UserDefaults (unbounded plist writes; not transactional with the rest).

## R9. First sighting only suggests

**Decision**: In `CorrectionCandidateScorer`, a result that would be `autoLearn` becomes `suggest` when `previousObservations == 0` and the replacement is not an existing canonical. It gets a new reason, `firstSighting`. Scores are unchanged.

**Why**: FR-012 and FR-013 with the smallest change. A second sighting already adds +2 through `repeated`, so any candidate that scored 6 or more once scores 8 or more on its second sighting.

## R10. Boost ranking

**Decision**: When more than 256 entries are enabled, entries are ordered by most recent `last_used_at` of any of their keys (newest first), then by total applied count, then by id. Entries never used keep id order after all used ones. Entries whose boost is retired are excluded.

**Why**: FR-015. Recency protects terms the user is working with now; the count breaks ties. It is deterministic, so the rescorer key stays stable between presses.

## R11. The notice

**Decision**: Generalise `LearnedNotice` into `DictionaryNotice` with two kinds: `learned` (Undo) and `retired` (Restore, showing "Stopped changing ‘jon’ to ‘John’"). It uses the same panel, the same 6 s window and one notice at a time. A retirement that happens while another notice is showing waits until that notice ends. The retirement row records `notice_shown`, so a pending notice survives until shown once; if the app quits first, it is not shown and the Dictionary still marks the key.

**Why**: FR-010 and one familiar place for automatic Dictionary changes.

## R12. Bounds

**Decision**:
- Usage events: at most 5,000 rows, oldest pruned. Totals live in the per-key rows and are never recomputed from events (FR-018).
- Events are unique on `(dictation_id, entry_id, key_id)`, so a classification cannot be counted twice.
- Sightings: at most 512 rows.
- Usage rows: at most one per key, so no more than `VocabularySnapshot.maximumKeys` plus one boost row per entry.

**Why**: Constitution 2 and 6, and the spec resource section.
