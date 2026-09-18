# Transcription pipeline contract v1

This is a local Swift boundary contract, not a server API. `TranscriptionRuntime` remains behind `ModelLifecycleCoordinator`; the coordinator passes a bounded result envelope through assembly, normalization, persistence and existing delivery checks.

## Stages and evidence

1. Snapshot vocabulary and reserve complete history capacity before recording. If either fails, do not start capture.
2. Decode one window at a time through the existing model lease. Keep automatic language/no hint and original configuration for baseline runs.
3. Admit an immutable `RecognizedWindow`: sequence, sample start/count, exact text, raw optional timing records, derived word spans and validity codes. Derive mappings without modifying raw text. Preserve original timing values; encode nonfinite values as explicit tagged invalid values rather than illegal JSON numbers.
4. Assemble in received order. Return text, seam decisions, source spans and completeness reasons.
5. Normalize using a fixed ruleset and vocabulary snapshot. Return text and applied IDs. Preserve the assembled input.
6. Save the complete immutable envelope atomically, then invoke existing delivery policy with normalized text. Save failure retains the envelope in existing unsaved recovery.

No completeness flag certifies acoustic accuracy. A complete result means processing established its own continuity without known loss; recognition errors remain measurable separately.

## Bounds and overload

| Resource | Capacity | At capacity or invalid input |
| --- | --- | --- |
| Audio/capture | Existing 180 seconds, mono 16 kHz spool and capture ring policies | Keep existing stop, cleanup and review-only behavior |
| Decode window | 239,360 float samples, zero production overlap, stride 239,360; minimum 4,800 padded samples. Historical evaluation retains 32,000 overlap / 207,360 stride | No larger allocation; pad only the final short input; record actual versus padded length |
| Active decode / pending result | One each; no producer backlog or new unbounded stream | Await consumer, reject concurrent session |
| Production window count | 14 | Stop incomplete, retain admitted result prefix |
| Received window | 65,536 text bytes, 16,384 timing tokens, 65,536 combined token text bytes | Reject entire window before admitting it; preserve earlier windows and report `raw_capacity`/`invalid_result` |
| Session raw text | 65,536 bytes across all admitted windows | Reject next window, preserve exact accepted records, stop incomplete |
| Assembly overlap state | Two adjacent window views, at most 2,048 overlap tokens and 16,384 overlap text bytes | Stop incomplete; never evict evidence and claim a safe seam |
| Derived word/source mapping | At most 16,384 entries for the current window; no full-session token array | Reject excessive mapping; preserve raw evidence and recover text |
| Assembled / normalized text | 65,536 bytes each | Do not split a Unicode scalar or silently truncate. Preserve last admitted prefix; normalization overflow returns unchanged assembled input, incomplete |
| Stored structured metadata | 131,072 serialized bytes including raw timing, spans, provenance, IDs and framing | Check incrementally before accepting a window/change. Stop incomplete; reserve terminal reason space |
| Diagnostics | 14 window summaries, 13 seam summaries, <=64 reason records, <=32 rule IDs, <=512 applied entry IDs; IDs <=128 bytes | Deduplicate reason/rule/entry IDs; terminal overflow code uses reserved slot; detailed overflow is incomplete |
| Normalizer scratch | Two 65,536-byte text buffers, <=16,384 spans, <=32 passes, <=8,192 candidate matches per pass | Return unchanged assembled input with capacity/nonconvergence reason |
| Vocabulary | 512 entries, eight aliases each, 256 bytes/64 scalars per string, total <=1,048,576 serialized bytes | Reject edit atomically; preserve current revision and entries |
| Vocabulary resident views | One active snapshot plus one current/editor snapshot; each <=4,608 source keys | No revision cache or per-edit queue; one edit in flight, further Save disabled |
| History write / unsaved recovery | One reservation/write and one bounded envelope, reservation 393,216 bytes | Existing recovery blocks new capture; no duplicate retries or eviction |
| History UI | Existing two 20-row pages of normalized summaries plus one selected detail envelope | Cancel/replace stale selection; detail not loaded for every row |
| Work requests | One processing task/session, one detail request and one vocabulary save | Join cancellation before replacement; disable duplicate actions |

Object counts and byte budgets both apply. Serialized limits do not claim equal RSS; measure Swift container/string overhead at the limits. Validators must bound input before constructing secondary arrays or JSON. Reserve 4,096 of the metadata bytes for terminal failure/provenance fields so exhaustion can be reported. Over-capacity raw evidence is not silently truncated or described as complete.

## Assembly semantics

Validate window sequence and expected offsets. Validate derived times as finite, nonnegative, monotonic and within actual unpadded window duration. Do not sort, clamp away contradictions, or infer silence from absent tokens. Original timing remains diagnostic evidence; padding-only/clamped/invalid evidence cannot establish a duplicate.

For adjacent windows, restrict candidates to their actual audio overlap. Match exact NFC-equivalent words with monotonic one-to-one time agreement within the pinned 160 ms tolerance. Matching normalization is only for comparison; emitted text uses untouched source spans. Require a unique alignment for the entire discarded duplicate span. Every discarded word and intervening punctuation must map to an equivalent retained span; a lone common anchor cannot justify removing a conflicting suffix. Preserve deliberate repetitions occurring at distinct times.

A safe join keeps earlier nonduplicate spans, one copy of the proven overlap and later nonduplicate spans. Preserve punctuation and spacing from source ranges; insert one separator only where distinct retained window fragments otherwise touch. If mappings are missing, competing alignments exist, timing is contradictory, coverage has a gap, or overlap cannot be established, append recovered spans in received order and record `uncertain_join`. Apparent duplicates may remain for review. Do not choose which uncertain words to discard.

The discard proof above applies only when the chunk plan contains audio overlap. For a contiguous plan, adjacent chunks cover disjoint sample ranges and the assembler has nothing to deduplicate. Assert the stronger invariant `lexical words discarded by TranscriptAssembler == 0`, together with exact sample continuity, zero ambiguous seams and zero join-caused incomplete results. This explicit invariant is required evidence for T021; absence of an overlapping code path alone does not satisfy it.

Completeness remains incomplete after any uncertain join, rejected window, cancellation, duration cap or later failure. No later normalization or engine attempt clears the original failure record. Normal copy/explicit insertion can follow existing reviewed recovery actions; automatic insertion remains blocked.

## Required contract cases

Reviewed expected sequences and completeness cover unique overlap, intentional `no no`, repeated phrases at different times, multiple possible anchors, conflicting suffixes, both language switch directions, partial words, punctuation mappings, missing/empty/out-of-order timing, gaps and padding-only times. Include exact-limit and one-over cases for every new bound, invalid floats, huge engine output, cancellation after a completed window and failure on the final window. Preserve all admitted raw bytes in each case.

## Owner priority revision, 2026-09-17

[The current owner decision](../acceptance/owner-priorities.md) removes downloaded-corpus Slovak recognition scores and within-sentence switching as blockers to current-engine integration. Earlier production holds based on those scores are superseded. All bounds, sample-coverage, word-preservation, completeness, lifecycle and persistence requirements in this contract still apply. No alternative-engine adoption or numerical pass is implied.

## Production adoption, 2026-09-17

[ADR 0012](../../../docs/adr/0012-production-contiguous-dictation.md) adopts fixed contiguous assembly for ordinary dictation. The current production assembly ID is `contiguous_fixed239360_preserve_v1`; normalization is `formatting-n001-n006-v1`. Admission reserves 24,576 processing metadata bytes in addition to the existing 4,096 terminal bytes and counts both raw and assembled escaping. Optional stored seam records are capped at 13 and validate zero lexical/byte discard for contiguous output. Legacy detail without those records keeps its original content hash. An empty recognized window amid otherwise nonempty text adds `empty_recognition` and requires review; wholly silent output remains a no-speech result.
