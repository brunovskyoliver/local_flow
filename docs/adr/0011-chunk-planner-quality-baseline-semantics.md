# ADR 0011: Chunk-planner quality baseline semantics

## Status

Accepted, 2026-09-17, for Feature 002 acceptance. Production chunk-planner integration remains pending.

## Context

T014 is the immutable historical quality baseline for the frozen public corpus. Replay proved that its historical overlap assembly can improve measured WER by deleting lexical output on timing evidence alone. That behavior cannot establish that the deleted words were duplicate audio. Corrected overlap assembly preserves evidence but leaves ambiguous seams. Evaluation-only contiguous plans remove join ambiguity and lexical deletion, but the first `vad-min` candidate still has material category regressions and the original public corpus reaches only two chunks.

T021 also mixed two cases. Its 160 ms timing proof applies when an overlap assembler discards lexical content. A contiguous plan has no duplicate audio to remove, so its stronger and directly testable rule is zero lexical words discarded by `TranscriptAssembler`.

## Decision

Keep every T014 artifact, score and threshold unchanged. Use it as the historical recognition-quality comparison, not as a correctness oracle when parity depends on unsubstantiated lexical deletion. A candidate does not pass merely by matching T014 text, and it does not fail solely because it retains words that T014 deleted without proof.

Production chunk-planner adoption requires all of the following:

- deterministic output under the recorded conditions;
- bounded planner and audio memory within the 14-window, 180-second contract;
- complete contiguous audio coverage, with no dropped or duplicated samples;
- no lexical deletion without overlap evidence;
- zero ambiguous assembly and zero join-caused incomplete results for contiguous plans;
- no unexplained material recognition-quality regression, with every category-level regression investigated explicitly.

For overlapping plans, T021 keeps its positional identity and 160 ms timing proof for every discarded lexical item. For contiguous plans, acceptance asserts `lexical words discarded by TranscriptAssembler == 0`. This is an affirmative invariant, not a vacuous claim that the overlap rule happened not to run.

The final evaluation compares `contiguous-fixed`, `vad-min` and one bounded `vad-preferred` candidate on both the frozen short corpus and genuine continuous-source long-form fixtures. `vad-preferred` may choose a VAD boundary only inside the existing bounded region and only when its speech probability meets the recorded criterion. Otherwise it uses the deterministic nominal contiguous boundary. It never drops or overlaps audio.

## Constitution check

No exception is required. The planner remains evaluation-only and does not change `WindowedTranscriber` or production dictation. Audio is streamed from the existing bounded spool; the planner has one bounded probe region and no unbounded lookahead. ASR and VAD are separate provisioned capabilities. Heavy ASR ownership remains with `ModelLifecycleCoordinator`; VAD residency and load cost must be measured before adoption. No server, wire schema, normalization, vocabulary, meeting feature, alternate engine or LLM work is authorized. No VoiceInk source is used.

## Consequences

Historical T014 results remain reproducible and visible, including any lower WER caused by deletion. New acceptance reports must separate recognition changes from assembly deletion. Production integration cannot proceed until the long-form and resource evidence satisfies every adoption condition above. Failing a condition leads to a recorded retain/investigate decision, not a wider threshold or another broad parameter search.

## Subsequent owner priority decision, 2026-09-17

[The owner priority revision](../../specs/002-transcription-quality/acceptance/owner-priorities.md) supersedes this ADR's downloaded-corpus recognition-quality hold for current-engine integration. It preserves the historical evidence, sample coverage, deterministic bounds and lexical-preservation conditions. It does not automatically adopt a planner or authorize an engine replacement. No constitutional requirement is waived.
