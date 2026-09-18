# Data model

The production database remains the existing private GRDB/SQLite store. Text is UTF-8; byte limits refer to UTF-8 or serialized UTF-8 JSON bytes, not character counts. Version fields are explicit. No audio is stored in SQLite.

## Transcription and processing detail

`TranscriptionEntry` retains UUID, creation time, normalized `text`, delivery/recovery/quality/stop fields, target and optimistic revision. New quality detail is keyed by the same UUID with a foreign key and cascading deletion.

| Detail field | Meaning and validation |
| --- | --- |
| schema_version | `1` for the new quality detail schema |
| raw_windows | Ordered records with sequence, sample start/count, exact received text, text hash, optional original timing evidence and its validation status |
| assembled_text | Output before normalization, separate from raw window records |
| normalization_version / assembly_version | Stable algorithm IDs; changes never rewrite history |
| applied_rule_ids / applied_entry_ids | Deduplicated IDs that changed committed output; no transcript text in normal logs |
| vocabulary_revision / vocabulary_hash | Snapshot identity, including explicit empty snapshot; never inferred from current vocabulary |
| provenance | Engine/SDK identity, model revision and artifact/manifest checksums, build and dirty state, language hint or explicit none, input format/duration, window/overlap/padding settings, stage durations |
| completion_reasons | Bounded typed codes and relevant window indices; independent of delivery state |
| attempts / selected_attempt | One initial attempt; optional future sequential experiment/fallback at most two, each with identity/status/timing and selected result; no automatic fallback in this release plan |
| representation_hashes / content_hash | SHA-256 over exact stage bytes and a versioned deterministic serialization of immutable processing content |
| unavailable_metadata | Field name plus bounded reason code; unknown values must not masquerade as zero or empty success |

Raw text is the received text for each admitted window. A UI concatenation is only a labeled view of those records. Sequence/offset metadata distinguishes natural repetitions and overlap. Timing evidence is structured data, not a reconstruction of the raw string. Invalid or over-capacity engine output is rejected as a whole; retained prior windows remain exact, and the rejected window is recorded as unavailable with a reason. The app never claims complete raw coverage in that case.

Cap raw text across admitted windows at 65,536 bytes; assembled and normalized text at 65,536 bytes each. Structured metadata, including timing records, window framing, provenance and change IDs, totals at most 131,072 serialized bytes. The remaining reservation allowance covers bounded record framing. See the pipeline contract for independent token/object limits.

An empty speech result remains an explicit evaluation result. For ordinary history, preserve the existing nonempty text constraint; no words are invented to create a history row. If malformed evidence contains useful raw text but cannot be assembled, use an unchanged bounded recovered text view for review and mark incomplete.

## Migration and durability

Add a `quality-v2` migration after `history-v1`; never edit an already released migration. Create `transcription_quality`, `vocabulary_entries`, and one-row `vocabulary_state` tables. Quality detail uses TEXT columns/JSON for structured text; no media BLOBs. Validate schema, bounds and hashes before committing. The JSON field is local persistence, not a new server wire format.

Legacy rows have no detail record and display `Legacy: raw output and processing metadata unavailable`. Do not copy old text into a fabricated raw field. `text` continues to serve legacy reads, search, copy and insertion.

Save parent row, detail and usage counters atomically with synchronous durable writes. Retry with the same UUID succeeds only if immutable content hashes match, including raw, assembled, normalized and provenance bytes. Delivery/recovery revisions may evolve without changing the content hash. A mismatch is `conflictingContent`. A failed write retains one full bounded unsaved envelope and blocks new recording until existing recovery is resolved. Never report saved before commit.

Update admission, deletion, startup usage reconciliation, free-space checks and test fakes together. Keep 10,000 rows, 33,554,432 retained history payload bytes and 134,217,728 database bytes. Reserve 393,216 bytes before capture for one result. Count all retained stage strings and serialized metadata once; normalized text lives only in the parent. Migration derives accurate usage for legacy text without backfilling nonexistent provenance. Reject new capture when a full reservation will not fit. No automatic eviction.

Confirmed Delete removes detail and parent plus adjusts usage in one transaction; selected UI/recovery copies must be cleared. This is logical deletion under the existing history policy, not a claim of forensic erasure. Interrupted insertion still recovers as uncertain after restart. Existing ordinary spool cleanup remains unchanged; no promise is made that a process-killed unsaved in-memory result survives.

## Preferred vocabulary

| Entity | Fields and rules |
| --- | --- |
| VocabularyEntry | Stable UUID, canonical text, zero to eight aliases, enabled boolean; NFC, trim/spacing validation, <=256 bytes per canonical/alias and <=64 Unicode scalars |
| VocabularyState | Monotonic integer revision, deterministic content hash, schema version; increments on every successful semantic edit, enable/disable or deletion |
| VocabularySnapshot | Immutable revision/hash plus enabled entries assigned at dictation admission; transient, not a growing revision archive |

Maximum 512 stored entries, including disabled entries, and 1,048,576 serialized payload bytes. Reject empty/control-character/multiline terms, conflicting folded source keys, canonical targets that map to another entry, and invalid canonical formatting. See the matching contract for case folding and overlap. All validation is transactional. A rejected edit leaves data and revision unchanged.

A snapshot is read atomically before capture, then retained for that session despite edits. At most one active session snapshot and one editor/current view snapshot are resident. A vocabulary load failure blocks admission rather than silently changing semantics. Historical results retain revision/hash and applied IDs, not indefinite copies of deleted vocabulary. They remain inspectable without reprocessing.

## Evaluation entities

These are private versioned files, not production database tables. Their field/size requirements are in [quality-evaluation.md](contracts/quality-evaluation.md).

- `QualityFixture`: stable ID, exact reference/hash, audio path/hash, duration/sample format, source/rights and derivations, language/category/authenticity labels, switch intervals, expected technical occurrences, tuning/acceptance partition and frozen set revision.
- `EvaluationRun`: UUID, manifest/config/build/hardware identities, scoring version, start/end/status and ledger entry for every selected fixture.
- `FixtureResult`: explicit status, stage outputs/hashes, raw windows, seam diagnostics, resources/times, failures and attached exact-hash reviews.
- `MeaningReview`: reviewer, date, fixture/stage, reference hash, output hash, verdict and bounded explanation. Missing/stale reviews are unreviewed.
- `EngineDecision`: compared run hashes, target category, per-category counts/deltas, absolute resource figures and repetitions, limitations, retain/replace/fallback disposition and remaining gates.

## State transitions

Session: reserve history and snapshot vocabulary → acquire model → capture → recognize windows → assemble → normalize → durable save → existing guarded delivery. Any capacity, capture, model, cancellation or processing failure yields recovered incomplete text when available and uses the existing release/cleanup path. Duration limit remains review-only even if assembly succeeds.

Completeness is monotonic: once incomplete, later joins/formatting cannot clear it. Persistence, delivery and recovery remain independent states. A successful save is not a successful insertion.

Evaluation run: prepared → running → complete or aborted. Each selected fixture moves pending → running → completed/failed/cancelled; unfinished IDs become `not_run` on finalization or recovery. A crashed ledger remains explicitly interrupted, never implicitly complete.
