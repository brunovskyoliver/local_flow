# Data model: Dictionary term boosting and suggestions

## In memory

- `VocabularyBoostTerms`: up to 256 `{entryID, canonical}` from enabled entries sorted by ID, the snapshot hash as cache key, and the folded canonicals and aliases the Dictionary governs.
- `VocabularyBoostHint`: `{source, canonical, entryID}`; `source` is an exact space-separated span of the raw window text.
- `TranscriptionWindow.boostHints`, `TranscriptionResult.boostHints`.
- `TermSuggestion`: `{canonical, alias, sightings, source: correction | context}`.

## Stored

`term_suggestions` (migration `term-suggestions-v14`, `WITHOUT ROWID`):

| Column | Type | Rule |
| --- | --- | --- |
| canonical | TEXT | 1–256 bytes, primary key part |
| alias | TEXT | 0–256 bytes, primary key part; empty for a context term |
| sightings | INTEGER | ≥ 0; corrections seen |
| dismissed | INTEGER | 0 or 1 |
| last_seen | INTEGER | milliseconds since 1970; oldest rows pruned beyond 500 |

Context sightings are counted on read from `dictation_contexts`, so deleting a dictation removes its sightings. Quality detail records `V002` in `appliedRuleIDs` and the boosted entry IDs in `appliedEntryIDs`.
