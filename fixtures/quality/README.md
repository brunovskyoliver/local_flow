# Private quality evidence

Use explicitly provisioned recordings under `build/speech-fixtures` (original corpus) or `build/quality-fixtures` (optional owner-supplied additions). Keep runs, score reports and human reviews under `build/quality-*` or `fixtures/quality/private/`. These locations are ignored. Directories must be 0700 and files 0600. Console output contains only fixed error codes/counts, never speech, references, paths supplied by fixtures, or reviewer explanations.

Evaluation audio retention is an explicit owner decision, separate from ordinary ephemeral dictation audio. Retain only recordings whose source, license or consent permits this evaluation and retention. Verify rights and exact references before freezing acceptance inputs; do not infer consent from possession. Delete private recordings, runs and reviews when their retention authorization ends. No uploads or implicit downloads are part of evaluation.

Only existing public metadata and clearly labeled authored contract examples belong in Git. Authored examples are deterministic test inputs, not recordings, consent or human meaning verdicts. The public corpus is reconstructed with `scripts/acquire-quality-corpus.py`; see [acquisition](../../specs/002-transcription-quality/acceptance/fixture-acquisition.md) and [rights](../../specs/002-transcription-quality/acceptance/dataset-rights.md). Commit its text-free `public-selection-lock.json`; keep audio and reference-bearing manifests local. New public clips, legacy monolingual clips and legacy synthetic stress tests have separate categories. Authentic within-speaker switching remains an explicit gap.

The v2 manifest's `manifest_sha256` in a run hashes the exact frozen manifest file bytes. The manifest itself has `schema_version` and `set_version`; it does not contain its own hash. Config hashes use sorted-key compact JSON. All stage hashes use exact UTF-8 bytes; raw concatenation uses LF between windows and includes overlap. Unknown stages are null with a reason, never copied from another stage.

## Authored cases

`assembly-cases.json` contains 27 deterministic source-window examples. Each window records
exact text, UTF-8 source spans, sample coverage and original window-relative word times.
`expected.raw_utf8_hex` pins exact admitted bytes independently of Unicode equivalence.
Expected assembled text, words, completeness reasons and automatic-insertion eligibility are
separate fields. Contiguous no-overlap cases describe adjacent source segments; they do not
change production window settings. Conflicting, missing or ambiguous evidence retains both
fragments, even when that leaves apparent duplicate words.

`normalization-cases.json` contains 45 deterministic formatting/vocabulary cases. N005 and
N006 remain identity, including repeated words and apparent SDK markers. Canonical entity
changes require the explicit vocabulary snapshot in that case. Numeric speech is not parsed.
The expansion case deliberately exceeds the output byte limit and expects unchanged input
with no committed IDs. Invalid snapshots are rejected before normalization; their expected
text records the unchanged input, not a successful normalization result.

`vocabulary-held-out.json` contains 14 held-out alias/case occurrences and 7 negative cases
against one ten-entry vocabulary. They were authored after V001 existed and are replayed by
`VocabularyNormalizationTests`; each case records the SHA-256 of its expected UTF-8 output so a
human review can cite exact bytes. They demonstrate spelling replacement, not recognition.

These are authored specifications reviewed against the existing contracts, not executions of
an assembler/normalizer or human meaning reviews. `human_meaning_verdict` stays null. T015,
T026 and T034 must replay the relevant cases against their later implementations. Schema
version 1 uses exact strings; JSON escapes are decoded before UTF-8 comparison. Times are
seconds relative to each window, and byte ranges are half-open. `tokens: null` means missing
timing, while `[]` means explicitly empty timing. No sorting or timing repair is implied.

## Private manifests and acceptance evidence

Keep WAVs, transcript sidecars, the generated manifest and reviews under
`fixtures/quality/private/`. The whole directory is ignored, including arbitrary extensions.
The older planned path `fixtures/quality/manifest.json` is also ignored because its references
can contain private text. Authored cases, the blank evidence template and the text-free public selection lock belong in Git.
No command here authorizes publishing or committing private evidence.

Copy `acceptance-evidence.template.json` into a private run directory to record collected
acceptance evidence. Its null fields are deliberately not passing evidence. See
[the evidence contract](../../specs/002-transcription-quality/contracts/acceptance-evidence.md)
for CLI usage, bindings and gate behavior.
