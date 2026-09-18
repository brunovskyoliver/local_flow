# Feature Specification: Feature 002 — Transcription Quality and Normalization

**Feature Branch**: `main` (existing branch; no branch-creation hook configured)

**Created**: 2026-09-16

**Status**: Draft, validated for planning

**Input**: Improve local transcription fidelity through repeatable evaluation, investigation of Slovak/English code-switching, bounded transcript assembly, conservative deterministic normalization, preferred vocabulary and traceable processing metadata. Preserve offline operation and Feature 001 memory guarantees. Engine changes require measured evidence. LLM rewriting, server communication, meeting recording and diarization are excluded.

## Current owner priorities, 2026-09-17

The owner reports better results in manual dictation than on the downloaded Slovak recordings and does not consider those recordings representative enough to block implementation. Ordinary Slovak and English dictation is the current priority. Within-sentence language switching is deferred. [Owner priority revision](acceptance/owner-priorities.md) supersedes earlier corpus-based integration holds without changing historical scores or declaring their targets passed. Deterministic assembly, exact raw preservation, bounded resources, recovery and guarded insertion remain mandatory.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Measure transcription quality and diagnose mixed speech (Priority: P1)

As a maintainer, I can reproduce recognition results for English, Slovak, authentic mixed Slovak/English speech, technical terms and longer dictations. I can distinguish recognition errors from assembly errors and normalization changes before deciding whether to retain or change the local engine.

**Why this priority**: Repeatable evidence helps separate recognition errors from processing defects. Ordinary Slovak and English use takes priority; within-sentence switching remains a deferred improvement.

**Independent Test**: Run the pinned baseline against a versioned fixture collection offline, rescore the saved results, and compare a candidate against the same fixtures and settings.

**Acceptance Scenarios**:

1. **Given** the fixed Feature 001 corpus and provisioned baseline model, **When** evaluation runs, **Then** every fixture appears in the report, including failures, omissions and incomplete results, with raw, assembled and normalized outputs distinguished.
2. **Given** authentic mixed-language recordings and separate synthetic mixed stress recordings, **When** quality is scored, **Then** the report keeps their results separate and identifies errors within decoded windows versus errors introduced at joins.
3. **Given** identical saved outputs, references and scoring rules, **When** scoring is repeated, **Then** all counts and scores are identical. Repeated recognition runs report any output differences rather than assuming reproducibility.
4. **Given** a proposed engine or fallback, **When** its suitability is reviewed, **Then** a decision records per-group quality, completeness, latency, memory, lifecycle behavior and tradeoffs against the current implementation. Missing evidence cannot authorize replacement.

### User Story 2 - Receive complete text across processing boundaries (Priority: P1)

As a person dictating, I receive each spoken passage once and in order, including when speech crosses processing windows or changes language near a boundary. If the system cannot establish a complete result, I can review the recovered text without it being inserted automatically.

**Why this priority**: Duplicated or silently missing words can change meaning even when individual windows recognize speech correctly.

**Independent Test**: Supply known window outputs with overlap, timing uncertainty, genuine repetitions and missing segments. Compare the assembled text and completeness state with reviewed expected results, independently of recognition quality.

**Acceptance Scenarios**:

1. **Given** overlapping windows containing the same spoken passage, **When** assembly finishes, **Then** that passage occurs once while intentional repeated speech remains intact.
2. **Given** speech spanning multiple windows, including a language switch, **When** the result is assembled, **Then** supported words remain in order and no text is invented to bridge a gap.
3. **Given** missing or conflicting boundary evidence, **When** a join cannot be established safely, **Then** recovered text is retained with an incomplete status and diagnostic reason, and automatic insertion is blocked.
4. **Given** cancellation, capacity exhaustion or a failed later window, **When** processing ends, **Then** completed text remains recoverable under Feature 001 recovery rules and the result never masquerades as complete.

### User Story 3 - Receive clean text without rewritten meaning (Priority: P1)

As a person dictating, I receive consistently formatted text while retaining access to what the recognizer actually produced. Formatting must preserve Slovak diacritics, English terms, numbers and deliberate repetitions.

**Why this priority**: Readability improvements are useful only when users can trust that wording and meaning were preserved.

**Independent Test**: Apply normalization twice to reviewed text examples covering both languages, mixed speech, punctuation, identifiers and ambiguous artifacts. Compare exact outputs and inspect the unchanged raw result.

**Acceptance Scenarios**:

1. **Given** whitespace, canonically equivalent Unicode or unambiguous punctuation-spacing defects, **When** normalization runs, **Then** the reviewed formatting is produced without changing words, numbers or diacritics.
2. **Given** ambiguous punctuation, a technical identifier, an acronym or a word that resembles an engine artifact, **When** normalization runs, **Then** uncertain content is preserved rather than guessed or deleted.
3. **Given** an already normalized result and the same rule and vocabulary versions, **When** normalization runs again, **Then** the output is identical.
4. **Given** a saved transcription, **When** the user inspects its details after restart, **Then** raw and normalized text are distinguishable and processing provenance is available. Normal copy and insertion use the normalized result and retain existing completeness and delivery safeguards.

### User Story 4 - Manage preferred spellings locally (Priority: P2)

As a person using names, products, technical terms and acronyms, I can manage preferred spellings and explicit aliases locally so recurring terms appear consistently without broad or speculative word replacement.

**Why this priority**: Personal terminology needs explicit user control and must not become a hidden rewriting system.

**Independent Test**: Add, edit, disable and delete entries; restart; dictate or supply matching and nonmatching examples; compare outputs with vocabulary enabled and disabled.

**Acceptance Scenarios**:

1. **Given** a preferred spelling and an explicit alias, **When** an unambiguous whole-term alias occurs, **Then** the preferred spelling is applied without replacing substrings of other words.
2. **Given** an ambiguous alias, a conflicting entry or overlapping matches, **When** the entry is saved or the text processed, **Then** the conflict is explained or the ambiguous text left unchanged; precedence never silently chooses a meaning.
3. **Given** an entry that has been changed, disabled or deleted, **When** a new dictation starts, **Then** it uses the current vocabulary. Prior saved results remain unchanged and identify the vocabulary revision used originally.
4. **Given** the vocabulary capacity limit or invalid input, **When** the user attempts to save an entry, **Then** a clear validation message appears and existing entries are preserved.

### Edge Cases

- Silence, empty output, unsupported speech and recognition failure must not produce invented words or be omitted from evaluation.
- A language switch, pause, partial word or punctuation mark exactly at a processing boundary must be represented in boundary tests.
- Repeated words such as "no no" and repeated phrases must not be treated as duplicate overlap solely because their text matches.
- Missing, overlapping, out-of-order or inconsistent segment timing must not silently establish completeness.
- Slovak combining accents, mixed capitalization, acronyms, decimals, versions, URLs and code-like identifiers must survive conservative normalization.
- An artifact-like string spoken literally must remain unless engine metadata or an explicit user mapping establishes a safe transformation.
- Vocabulary edits during dictation must not change the revision already assigned to that dictation.
- Maximum-duration speech, transcript expansion, huge engine output, full history storage, disk failure and restart after interruption must preserve bounds and recovered text.
- A missing alternative model, failed handover or cancelled fallback must preserve the first result and never leave two heavy models loaded by default.
- Existing history without provenance must remain readable and be marked as legacy/unknown rather than assigned fabricated metadata.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: Provide a versioned, repeatable offline evaluation suite covering English, Slovak, technical vocabulary, entities/numbers, longer Slovak and Slovak-accented English, with authentic within-speaker Slovak/English switching tracked as a separate coverage gap. Preserve the original 30 Feature 001 fixtures as a separate regression baseline; synthetic concatenations MUST NOT substitute for authentic code-switching evidence.
- **FR-002**: Each fixture MUST include a stable identity, audio checksum, exact reference, language/category labels, duration, source and rights/consent basis, and any derivation steps. Select fixtures and freeze the evaluation set before comparing candidates; document all additions and exclusions. Keep tuning examples distinct from acceptance examples.
- **FR-003**: Report word error rate (WER: substitutions, deletions and insertions divided by reference words), character error rate, technical-term correctness, completeness failures and reviewed meaning errors per fixture and category. Aggregate error counts over reference counts, never average fixture percentages. Empty references, failed decodes and empty outputs MUST have explicit scoring treatment and counts; no failure may disappear from a denominator or report.
- **FR-004**: Keep scoring normalization separate from product normalization. Version scoring rules, retain diacritics and meaningful word/number distinctions, and report raw recognition, assembly and final output separately so formatting or vocabulary substitution cannot conceal recognition regressions. Preserve exact punctuation/case-sensitive comparisons for normalization and vocabulary tests.
- **FR-005**: Record the existing Parakeet baseline before changing its configuration or processing behavior. Retain the carried-forward mixed-language deficiency as deferred diagnostic work, using retained window evidence when that work resumes. Change one factor at a time where practical and record remaining uncertainty.
- **FR-006**: Preserve immutable raw ASR output in received segment/window order, a separately identifiable assembled transcript, and normalized output for each new retained transcription. Assembly MUST not be misrepresented as raw recognition. Users MUST be able to inspect raw versus normalized text locally; normal search, copy and insertion use normalized text.
- **FR-007**: Introduce a bounded assembly stage that combines ASR windows/segments in spoken order, removes only supported processing overlap and preserves genuine repetitions. Define finite limits and overload behavior for its pending segments, overlap state and output in the plan before implementation. Uncertain joins MUST preserve recovered material and mark the result incomplete, without automatic insertion or guessed bridging text.
- **FR-008**: Apply only versioned, deterministic normalization for whitespace, punctuation boundaries, conservative capitalization, canonical Unicode equivalence and explicitly enumerated, safely identifiable engine artifacts. Every rule MUST have positive examples and counterexamples. Do not paraphrase, translate, summarize, correct grammar, infer missing speech, strip accents or remove ordinary repetitions and fillers. Ambiguous cases remain unchanged.
- **FR-009**: Normalization MUST be idempotent for fixed rules and vocabulary. Preserve raw output exactly; record which rule identifiers or vocabulary entry identifiers changed the final text. Changes to rules MUST NOT silently rewrite history.
- **FR-010**: Provide local management of preferred vocabulary with add, edit, enable/disable and delete actions, canonical spelling, optional explicit aliases and validation. Matching MUST respect whole-term boundaries and Unicode equivalence, reject conflicting mappings or leave ambiguity unchanged, and never use fuzzy or semantic replacement. Preserve exact canonical spelling, including capitalization and diacritics. Preferred entries without aliases can establish canonical casing for unambiguous matches; this does not promise correction of unheard terms.
- **FR-011**: Assign a stable vocabulary revision when each dictation starts. Bound entry count, entry/alias length, alias count and total storage with concrete capacities in planning. Report limit violations without silent eviction. Engine-specific vocabulary hints are optional and MUST be evaluated separately from deterministic replacements.
- **FR-012**: Persist transcription provenance alongside the result: engine identity/version, model identity/version and artifact checksum, application build, recognition settings including language hints, input duration and format, window/overlap configuration, assembly and normalization versions, vocabulary revision, stage timings, completion/failure reasons, and any fallback attempts and selected result. Record unavailable metadata as unknown with a reason. Link this record to the exact output; do not log transcript text or vocabulary contents in ordinary diagnostics.
- **FR-013**: Keep existing history readable without inventing missing raw text or provenance. Save new result representations and metadata together durably. Raw text and associated metadata follow the same explicit deletion and privacy rules as the transcription; retention does not authorize keeping ordinary dictation audio.
- **FR-014**: Alternative local engines MAY be evaluated behind the existing transcription abstraction. Replacing the current default or adding a production fallback requires a recorded comparison meeting SC-007, with model/dependency provenance, licensing, provisioning, cancellation and release evidence. Retaining the current engine is a valid explicit decision if evidence does not support a safe advantage.
- **FR-015**: All heavy transcription models, including experimental alternatives and fallbacks, MUST use the existing central ModelLifecycleCoordinator for load, use, cancellation and release. Default engine handover MUST finish releasing the previous heavy model before loading another. No feature-owned runtime or default concurrent residency is allowed. Any lifecycle exception requires an ADR and explicit constitution review.
- **FR-016**: Preserve offline dictation after explicit model provisioning, the 180-second duration limit, current delivery/recovery safeguards and existing model residency settings. All new processing, vocabulary and history access MUST work with network disabled and no server running. No automatic model acquisition is part of transcription.
- **FR-017**: Keep one native client, the existing independent server boundary and shared wire schemas. This feature MUST NOT add LLM rewriting, server communication, meeting recording, diarization or an extended recording duration. No VoiceInk application source may be copied.
- **FR-018**: Publish a quality decision report with reproducible run instructions, pinned inputs/settings, per-fixture results, observed limitations and the chosen mixed-language disposition. Meaning reviews MUST identify the reviewer and exact reference/output hashes; unreviewed or unmeasured items remain explicitly open.
- **FR-019**: Treat T014 as the immutable historical quality baseline, not a correctness oracle where parity depends on lexical deletion without supported overlap evidence. Chunk-planner adoption MUST be deterministic and bounded, cover every input sample exactly once for contiguous plans, discard no lexical words for contiguous plans, produce zero ambiguous or join-incomplete contiguous results, and record material category-level quality regressions. Under the owner priority revision, unresolved downloaded-corpus recognition regressions do not block current-engine integration; word-preservation and bounded-processing requirements still apply. Do not widen T014 thresholds to fit a candidate.
- **FR-020**: Extend public acceptance with continuous intervals from original rights-cleared recordings: approximately 10 Slovak fixtures of 60–90 seconds, 10 Slovak fixtures of 120–180 seconds and 5 English fixtures of 60–180 seconds. Each fixture MUST retain dataset revision, source recording ID, exact interval, transcript/alignment span IDs, source recording hash and converted fixture hash. Do not concatenate source clips.
- **FR-021**: Provision every selected chunk-planner artifact explicitly through the existing model provisioning boundary. Represent VAD separately from ASR, pin and validate its revision and files offline, and measure artifact bytes, load time and RSS increment while ASR is active. No automatic model acquisition may occur during transcription.

### Key Entities *(include if feature involves data)*

- **Quality fixture**: Versioned audio/reference pair, provenance, checksums, language switches, category labels and reviewed expectations.
- **Evaluation run**: Fixture-set version, build, hardware/OS, model and processing settings, per-stage outputs, scores, failures, resource measurements and review records.
- **Transcription result**: Raw window/segment output, assembled text, normalized text, completeness and delivery/recovery status, plus processing provenance.
- **Normalization ruleset**: Identified rules and version, expected transformations, counterexamples and applied-rule record.
- **Preferred vocabulary**: Local entries with canonical spellings, aliases, enabled state and stable revision assigned to each dictation.
- **Engine decision**: Baseline/candidate evidence, quality and resource differences, limitations, decision rationale and any production fallback conditions.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: Preserve all 30 original FLEURS fixtures as a separate legacy subset. Reconstruct the pinned public corpus locally, targeting 20 Slovak general, 20 English general, 10 technical/technology, 10 entity/numeric, 10 longer Slovak and 10 Slovak-accented-English clips. Use pinned official FLEURS and VoxPopuli releases without account credentials; Common Voice 26.0 validated clips remain an optional additional corpus. Freeze source IDs, references, hashes and deterministic conversion rules; do not commit audio. Categories may overlap without physical duplication. Public-corpus baseline acceptance is independent of authentic within-speaker Slovak/English code-switching, which remains an explicit coverage gap. Synthetic stress tests never count as authentic switching. Longer source segments must cross a processing window; 60–180-second and near-limit natural speech remain separate coverage gaps if unavailable.
- **SC-002**: Every baseline and candidate run accounts for 100% of selected fixtures and exposes per-stage outputs and failure status. Rescoring saved outputs twice produces identical counts and scores. Two recognition runs under the same recorded conditions either reproduce the outputs or explicitly quantify their differences.
- **SC-003**: Historical diagnostic targets, deferred as release gates for the current-engine integration by the owner priority revision. Do not relabel an unmet target as passed. English and Slovak each retain aggregate WER <=15% on the original sets and regress by no more than 1 absolute percentage point against the freshly reproduced baseline. Mixed-language closure requires either (a) at least 20% relative WER reduction on the fixed authentic mixed set with no increase in incomplete or meaning-changing results, or (b) a reviewed decision report that localizes failures, records controlled processing comparisons and explicitly justifies retaining the engine, changing it or introducing a bounded fallback. Both paths report authentic and synthetic results separately and state whether the inherited mixed-language <=15% target is met. A decision report never counts as passing that accuracy target.
- **SC-004**: All reviewed assembly contract cases produce the expected word sequence and completeness state, with zero assembly-induced duplications or omissions on cases with sufficient boundary evidence. Every deliberately ambiguous/gapped case retains recovered text, is marked incomplete and is withheld from automatic insertion. End-to-end long-form and mixed fixture reports enumerate every observed join failure separately from recognition errors. An overlapping assembler must prove each discarded lexical item under T021; a contiguous plan must report exactly zero lexical words discarded by `TranscriptAssembler`.
- **SC-005**: All reviewed normalization cases preserve meaning and are idempotent, with zero unapproved lexical/number changes. Vocabulary cases produce the specified canonical spelling for every unambiguous match and zero replacements in negative or ambiguous cases. At least 10 held-out term occurrences demonstrate correction of explicit alias/case variants, without implying improved acoustic recognition.
- **SC-006**: Every newly saved acceptance transcription retains its exact raw output, normalized result and required provenance across restart. Legacy records remain readable. Confirmed deletion removes the associated representations and provenance. All offline, cancellation, incomplete-result and storage-failure scenarios preserve Feature 001 recovery behavior.
- **SC-007**: Default-engine replacement or production fallback adoption demonstrates at least 20% relative WER reduction in its declared target category, or at least 20% lower measured peak transcription working memory or median transcription time on the same workload. Comparison uses the same acceptance fixtures and recorded hardware/conditions, with resource/timing results repeated at least three times. No language category worsens by more than 1 absolute WER percentage point; completeness failures and reviewed meaning errors do not increase; all inherited resource gates still pass. A fallback comparison measures the full sequential path and its triggering policy, not only the second engine. Record absolute counts and limitations of the small corpus alongside percentages.
- **SC-008**: With models provisioned and network disabled, the full acceptance workflow completes without outbound requests or a running server. Resource acceptance meets every inherited threshold below, with measured results and no unexplained growth flags. Scaffolding checks alone do not establish this outcome.

## Assumptions

- The quantitative corpus sizes, 20% improvement/adoption thresholds and 1-point non-regression allowance are proposed Feature 002 acceptance defaults. They are requirements to test, not measured claims; changes must be recorded before evaluating candidates rather than adjusted to fit results.
- "Longer utterances" means multi-window dictation within the existing 180-second maximum. Long-form chunk-planner acceptance uses genuine 60–180-second continuous source intervals and includes a fixture near the ceiling. Reaching that maximum still requires review before explicit copy or insertion.
- T014 remains unchanged as historical evidence. [ADR 0011](../../docs/adr/0011-chunk-planner-quality-baseline-semantics.md) defines why lower WER caused by unproven deletion is not a correctness oracle and records the separate overlapping/contiguous T021 rules.
- Vocabulary is local and user-managed. Explicit aliases and conservative spelling/case canonicalization are the initial scope; automatic learned replacements, broad phonetic matching, import/sync and language-model rewriting are excluded.
- Existing provisioned Parakeet assets, Feature 001 fixtures and the current transcription boundary are the baseline. Public dataset access and applicable evaluation rights are baseline dependencies. Authentic code-switching is a separately tracked coverage gap, not a requirement to record a private corpus.
- Feature 001's [accuracy evidence](../001-local-dictation/acceptance/accuracy.md) records 10.58% Slovak, 7.18% English and 23.87% synthetic mixed WER, with six incomplete mixed results. It distinguishes model omissions from uncertain joins. These are historical observations to reproduce, not new measurements or authentic code-switching acceptance.
- Feature 001 owner acceptance deferred mixed-language switching without widening its accuracy threshold. This feature records that deficiency as deferred following the owner priority revision; it does not retroactively mark Feature 001's mixed-language criterion as passed.
- Local result inspection and evaluation artifacts contain sensitive text and follow existing private storage and explicit deletion rules. Normal application logs remain content-free. Evaluation retention is explicit and separate from ephemeral ordinary dictation audio.
- Detailed capacities, matching precedence for nonambiguous overlapping terms, normalization rule tables and diagnostic representation belong in planning. Planning must resolve those concrete limits before implementation; no architectural exception is proposed here.

## LocalFlow resource and failure acceptance

The [constitution](../../.specify/memory/constitution.md) and [Feature 001 memory protocol](../../docs/performance/memory-budget.md) remain binding. Use decimal MB. Preserve unloaded idle RSS <=150 MB and capture-only overhead <=100 MB above idle, excluding model working sets measured separately on Apple M5. Do not invent an absolute model-memory cap.

Run the existing 20-cycle release benchmark. Every settled unloaded RSS median must remain within max(20 MB, 10% of baseline) of baseline. Investigate a positive slope above 0.5 MB/cycle or a median increase above 10 MB between cycles 1–5 and 16–20; acceptance permits no unexplained growth flag. Cover default cooldown, rapid reuse and existing explicit keep-loaded/manual-release settings. Record hardware, OS, build, model identity, settings and all samples.

Measure the added raw/assembled/normalized text and metadata cost, assembly/normalization duration, model load/release duration, peak queues and end-to-end transcription time. Exercise maximum-duration speech and the maximum supported vocabulary. Compare the original and new pipeline under matching conditions. For any fallback, include cancellation and failed handover, proving default single-model residency and eventual release.

Planning must assign finite capacities and overload behavior to every new buffer, queue, cache, vocabulary store, result representation and evaluation trace. Evaluation must process a corpus incrementally rather than retain all audio or model instances. Ordinary audio remains ephemeral and is cleaned after completion, cancellation, failure and restart. No full-recording accumulation is introduced.

At capacity, duration, permission, model or storage failures, stop safely, preserve completed text and explain its incomplete or unsaved state. Never auto-insert an incomplete, duration-limited or uncertain result, discard saved history to make room, or report persistence before a durable save. Save retries must not duplicate or mismatch raw text, normalized text and provenance. Test restart recovery and legacy history alongside successful results.

Run `make check` for repository validation. Real speech quality, meaning review, microphone acceptance and hardware/resource measurements are separate evidence; skipped or unavailable checks remain explicitly unverified.
