# Offline quality evaluation contract v2

These are development interfaces. They introduce no app server API or Python runtime dependency in the client. The original 30-fixture v1 manifest and scorer remain unchanged for historical comparisons.

## Inputs and artifact layout

A new v2 manifest contains schema/set version and hash, ordered fixture IDs, relative audio path and SHA-256, exact reference and SHA-256, mono 16 kHz sample count/duration, language/category labels, authentic/synthetic classification, source/rights/consent basis and derivations. Record switch sample intervals, technical-term occurrences and reviewed per-window reference spans where available. Mark tuning versus acceptance explicitly. Freeze manifest bytes before comparisons; additions/exclusions create a new set version.

A run directory contains `run.json` (configuration/status/ordered ledger), `results/<fixture-id>.json` (stage evidence), `reviews.json` (optional exact-hash human review), and separately generated score reports. IDs are unique safe ASCII names, <=128 bytes, without separators or `..`. Audio paths must resolve inside the selected fixture root. All artifacts are versioned and validated; invalid headers/duplicate IDs fail preflight before inference.

`run.json` records run UUID, manifest/config hashes, build/dirty state, hardware/OS/power conditions, model/dependency identity and checksum, language/window settings, stage versions, vocabulary revision/hash and resource protocol. Each selected fixture has a status and optional result hash. One model and fixture are active at a time. Lifecycle ownership is identical to the application.

Each result records raw admitted windows, raw coverage/rejection status, assembled and normalized text and exact hashes, completeness/failure codes, per-seam outcome, stage timings, peak queues and measured resources with units. Missing measurements are null with a reason. Raw concatenation is a deterministic view joining received window texts with LF; it includes processing overlap and is not described as pure acoustic WER. Use reviewed window reference spans to localize recognition versus assembly defects.

## Capacity and durability

| Item | Limit and behavior |
| --- | --- |
| Manifest | 4,194,304 bytes, 256 fixtures; reject invalid/over-limit input before inference |
| Fixture | <=16,777,216 file bytes and <=2,880,000 samples; read/hash incrementally in <=1,048,576-byte chunks, decode audio in existing 1,600-frame blocks |
| Evaluation window trace | <=32 windows for explicit controlled experiments; production stays <=14. Each trace window <=65,536 text bytes, <=16,384 tokens and <=65,536 token-text bytes |
| Per-fixture artifact | <=16,777,216 serialized bytes; one bounded serialization buffer, fail trace capacity explicitly |
| Run output | <=4,294,967,296 bytes including temp files, ledger, reviews and reports; preflight allocation budget sums all selected maximums plus overhead and rejects a selection that cannot fit |
| Ledger / review file | <=4,194,304 bytes each; at most 256 ledger rows and 768 stage reviews; explanation <=4,096 bytes |
| Scoring scratch | One fixture file; <=16,384 tokens and <=65,536 Unicode scalars per scored representation; two edit-distance rows with deterministic S/D/I tuples |
| Aggregate state | <=256 fixture summaries, <=32 categories, <=4,194,304-byte report; no corpus audio/text array |

Create directories as 0700 and files as 0600. Write/fsync bounded temporary files and atomically rename within the run directory; synchronize directory metadata for crash recovery. Never overwrite a completed run or a human review. No audio in traces. Do not print reference/output/vocabulary text in console logs or XCTest attachments.

Persist a pending ledger before inference and one result before advancing. A decode failure produces a failed result and continues when safe. Fatal failure marks remaining IDs `not_run`; crash recovery converts running/pending IDs to interrupted/not_run and reconciles durable result hashes. If storage failure prevents finalization, an unfinished ledger remains invalid for acceptance; the scorer still enumerates all manifest IDs as missing/not_run. No partial batch may present itself as complete.

Evaluation-only traces may preserve more raw evidence than production history; report production envelope limits separately and apply them to product outcomes. A trace or score limit is an explicit failure, not silent clipping. Corpus processing never holds multiple runtimes or recordings in memory.

## Scoring rules `quality-score-v2`

NFC compose, lowercase using the pinned Python/Unicode version, and collapse Unicode whitespace. Strip only outer ASCII sentence punctuation `. , ! ? ; : " ( ) [ ] { }` from whitespace-delimited tokens with no digits and no URL/email/path/underscore/backtick syntax. Preserve internal punctuation, apostrophes, signs and punctuation-only tokens. Examples: `Hello,` → `hello`; `číslo` retains the accent; `1.5`, `1,5`, `v1.2`, `don't`, `foo_bar` and URL tokens remain distinct. Record tokenizer tests/version before evaluating candidates. Product normalization never changes reference scoring rules.

WER uses unit-cost token Levenshtein counts S/D/I divided by reference token count. CER uses Unicode scalars of the same scoring-normalized representation with whitespace removed. Equal-cost paths use match, substitution, deletion, insertion precedence. Aggregate integer error/reference counts, not fixture percentages. Emit integer counts plus rates in a fixed precision; stable output ordering and no generated timestamps in score reports make rescoring byte-identical.

For a nonempty reference and empty hypothesis, count every reference unit as deletion. Failed/not-run fixtures remain in denominators and score recovered stage output or empty output; also count their failure state. Empty reference has null per-fixture rate, explicit insertion counts and hallucination state. Its insertions enter group error totals, with zero reference units. Entirely empty-reference groups have null rates. Invalid/over-limit scoring input has an explicit score failure and conservative empty-hypothesis counts for nonempty references; do not present those counts as a completed score. Any such failure blocks acceptance.

Report raw concatenation, assembled and normalized stages separately. Compare original English, original Slovak, synthetic mixed, authentic mixed, technical and long-form groups explicitly; a fixture appears once per group even when labels overlap. Report v1 historical scores and freshly reproduced v2 scores side by side; never compare a v1 baseline rate to a v2 candidate rate.

Technical accuracy uses annotated held-out occurrences and deterministic sequence alignment, with exact canonical case/diacritics for replacement tests. Report correct/total and unexpected replacements in negative cases. Meaning review requires reviewer identity/date, stage, verdict and exact output/reference hashes. Missing or stale review is unreviewed. Never infer meaning preservation from low WER.

## Proposed implementation CLI

These commands are to be implemented, not available at planning time:

```text
python3 scripts/transcription-quality.py score MANIFEST RUN_DIR REPORT [--reviews FILE] [--require-acceptance]
python3 scripts/transcription-quality.py compare MANIFEST BASELINE_RUN CANDIDATE_RUN REPORT
python3 scripts/transcription-quality.py review-template MANIFEST RUN_DIR NEW_FILE
```

`score` rejects schema/hash mismatches, accounts for every ID and returns nonzero with `--require-acceptance` if any required gate is unmet. `compare` requires the same frozen manifest/scoring version, reports all stage/status/hash differences and category deltas, and checks declared changed factors. `review-template` creates a new private file with blank verdicts; it never overwrites a review. Acceptance pass requires all spec gates, not just numeric WER.

The new opt-in XCTest entry is planned as `RuntimeCompatibilityTests/testOptInQualityFixtures`, using existing model/fixture environment variables plus `LOCALFLOW_QUALITY_OUTPUT` for a new run directory. Use the `TEST_RUNNER_` prefix when passing variables through xcodebuild. Original `testOptInSpeechFixtures` remains reproducible.

## Decision gate

A reviewed report must choose retain, replace, or conditional fallback, with reproducible inputs, limits and mixed-language disposition. SC-003 permits a documented retention decision after controlled investigation, but this never passes the inherited mixed <=15% accuracy target by assertion. State that target separately.

SC-007 adoption requires >=20% relative WER improvement in the declared target group or >=20% lower measured peak transcription memory or median time, same fixtures/conditions, at least three resource/timing repetitions, <=1 absolute percentage point WER regression in every language category, no increased completeness/meaning failures, and all inherited resource gates. Measure a fallback's full first-engine/trigger/release/second-engine path. No automatic fallback is part of the initial production design. Missing authentic fixtures, reviews or hardware evidence leaves acceptance open.

The implemented gate evidence format and additional `score` options are defined in
[acceptance evidence v1](acceptance-evidence.md). Unavailable evidence stays unverified;
measured failures and supplied passing evidence are evaluated separately.

## Public corpus provenance and baseline scope

New public fixtures include a bounded `provenance` object (<=16,384 serialized bytes) with required nonempty `dataset`, `version` and `source_clip_id`. It also records source URLs/split, source audio hash, metadata or shard hash, reference field and conversion identity where applicable. Legacy fixtures carry their original manifest hash and source/component identities. Score summaries preserve this object; run manifest hashes bind it to exact results. Extra source fields remain backward-compatible with v2 readers.

Report `public_sk_general`, `public_en_general`, `public_technology`, `public_entity_numeric`, `public_sk_longer`, `public_sk_accented_en`, `legacy_sk`, `legacy_en` and `legacy_synthetic_stress` separately. T013/T014 public-baseline closure does not require the authentic within-speaker switching gap to close. Full feature, meaning, engine adoption and resource acceptance still have their own gates. `--require-acceptance` remains the full-feature gate, not a public-baseline shortcut.
