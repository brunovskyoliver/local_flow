# Research decisions

Research date: 2026-09-16. Evidence comes from the repository's pinned implementation, lockfile, acceptance records and checked-out dependency source. This plan does not claim new speech measurements or current suitability of an untested engine.

## Preserve the baseline before changing processing

**Decision:** Retain the pinned Parakeet runtime and historical v1 scorer. Add a v2 evaluation path that records stages and failures incrementally. Reproduce the original corpus before changing production behavior.

**Rationale:** [Feature 001 evidence](../001-local-dictation/acceptance/accuracy.md) reports 10.58% Slovak, 7.18% English and 23.87% synthetic mixed WER. Mixed-08 fails within a single window, while six other mixed recordings have uncertain joins. Assembly alone cannot explain all errors. `RuntimeCompatibilityTests.testOptInSpeechFixtures` currently caps the corpus at 30, accumulates results and aborts on exceptions. It needs a separate versioned runner to cover 002 without changing historical evidence.

**Alternatives considered:** Changing engine immediately lacks controlled evidence; treating synthetic concatenations as authentic switching misstates provenance; changing scoring rules in place breaks historical comparability.

## Separate immutable recognition from assembly

**Decision:** Capture received window text exactly, with sequence, sample offset and timing evidence before formatting or overlap removal. Keep original timing values separate from validated derived timings. The assembler consumes two adjacent windows and retains only a bounded overlap tail.

**Rationale:** `Core/Transcription/FluidAudioEngine.swift` currently converts token timings to words and clamps them; `WindowedTranscriber.swift` returns only assembled text. In pinned FluidAudio 0.15.7, `ASR/Parakeet/AsrTypes.swift` exposes `ASRResult.text` and optional token timings; unavailable evidence must remain unknown. The current assembler can remove unmatched incoming words based on the prior end time. An uncertain boundary must instead retain recovered text and block automatic insertion.

**Alternatives considered:** Text-only suffix matching deletes genuine repetitions. Wider timing tolerance can hide errors. Full-recording decode violates bounded processing. Reconstructing raw output from assembled words is not raw preservation.

## Use conservative, evidence-based joins

**Decision:** Deduplicate only a unique monotonic matching sequence in the physical overlap with consistent timing and valid text-span mappings. Keep the existing 160 ms tolerance initially; require reviewed counterexamples before changing it. Missing/conflicting evidence appends unmodified recovered spans, records ambiguity and makes completeness sticky-incomplete.

**Rationale:** Repetition and language changes are normal speech. Time agreement is necessary but a single ambiguous anchor is insufficient. Token-to-text mappings must not discard punctuation or unaligned content. [Pipeline contract](contracts/transcription-pipeline.md) specifies the admission bounds and failure rules.

**Alternatives considered:** A midpoint cut can omit words when timings drift. Sorting malformed tokens disguises invalid evidence. Replacing the old suffix wholesale loses words outside a proven duplicate span.

## Normalize conservatively and make vocabulary explicit

**Decision:** Use a small versioned rule table, canonical Unicode composition, bounded whitespace changes and one guarded punctuation-spacing rule. General capitalization and artifact deletion are identity operations initially. Capitalization changes come only from unambiguous preferred vocabulary.

**Rationale:** Neither the current boundary nor the specification provides safe metadata for deleting artifact-like text. URLs, decimals, code identifiers and spoken fillers must survive. A bounded fixed-point check handles vocabulary substitutions that create a new adjacent phrase; a result is committed only if it is stable. Nonconvergence returns the original assembled text and an explicit processing failure.

**Alternatives considered:** Sentence case, number formatting, fuzzy terms and LLM rewriting infer meaning. Single-pass replacement without a stability check does not guarantee idempotence. See [rule and matching contract](contracts/normalization-vocabulary.md).

## Extend the existing database transaction

**Decision:** Add a one-to-one quality detail record and vocabulary tables to the existing GRDB database. Keep `transcriptions.text` as the normalized search/delivery field. Legacy detail is absent, not invented. Save and delete the entire result in one transaction.

**Rationale:** `TranscriptionStore` currently counts/reserves only 65,536 text bytes and validates retry identity using text alone. It must reserve the complete envelope, count all representations and compare immutable content hashes on retries. Existing delivery-state revisions continue independently of immutable processing content.

**Alternatives considered:** Sidecar JSON for production history creates cross-file atomicity problems. Putting all detail in history pages inflates memory. Increasing history quota is unnecessary; a full store already blocks capture without eviction.

## Keep model ownership and dependencies unchanged

**Decision:** No new production engine or dependency is selected. Experiments use `TranscriptionRuntime` and the central `ModelLifecycleCoordinator`, with one loaded engine at a time. Model provisioning remains explicit. Engine-specific hints are disabled in the initial design.

**Rationale:** The existing runtime uses automatic language and sequential chunks. The specification allows retaining it with a reviewed explanation. Alternatives must meet SC-007, including three repeated resource/timing comparisons and the full sequential fallback path if applicable.

**Alternatives considered:** Parallel models violate default residency policy; a feature-owned evaluation runtime bypasses lifecycle evidence; an unevaluated fallback adds latency and failure modes without demonstrated benefit.

## Separate evaluation storage from ordinary audio retention

**Decision:** Private per-fixture result files, an atomic run ledger, one active fixture and bounded scoring scratch. Preserve original audio fixtures only under their explicit evaluation retention/provenance policy. Ordinary dictation spools are still deleted on success, failure, cancellation and restart.

**Rationale:** `scripts/dictation-accuracy.py` currently calculates WER only, rejects empty references and removes punctuation. A new scoring version must expose S/D/I, CER, stage differences, technical terms, failures and reviews without dropping fixtures or changing historical v1 scores.

**Alternatives considered:** One in-memory corpus result array scales with the corpus. Dropping failed decodes improves percentages dishonestly. Averaging per-fixture WER weights short recordings incorrectly.

## Resolved design questions and evidence still needed

All planning choices have concrete contracts: capacities, matching precedence, rules, diagnostic fields, migration and evaluation interfaces. No unresolved design question blocks task generation. Authentic mixed and longer licensed recordings, human reviews, real quality comparisons, signed microphone/delivery checks and hardware measurements remain implementation acceptance work. Their absence cannot be replaced by a passing `make check`.
