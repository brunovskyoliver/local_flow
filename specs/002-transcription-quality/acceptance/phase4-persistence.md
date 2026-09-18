# Phase 4 persistence, admission and recovery

Date: 2026-09-17. Scope: the owner's instruction to resume Phase 4 with `speckit-implement`, following the completed long-form comparison. This report covers deterministic implementation checks, not speech-quality or hardware acceptance.

## Completed work

| Task | Implementation and evidence |
| --- | --- |
| T016 | Storage tests cover exact decomposed-Unicode/raw-byte and hash round trips, history-v1 migration without invented detail, all-representation quotas, full reservation rejection, conflicting raw/provenance retries, restart usage reconciliation, cascading deletion, detail-write rollback and SQLite-full retry. Storage recovery also verifies that interrupted delivery becomes uncertain after restart without changing the detail hash. |
| T017 | Coordinator and unsaved-result tests cover a full authored envelope, repeated save failure, concurrent retry suppression, explicit discard, blocked new capture, duration/capture failure, cancellation joining, model-load failure and automatic insertion suppression. Existing permission and cancellation/lifecycle cases continue to pass. An injected `DictationTranscribing` boundary supplies authored results without claiming model evidence. |
| T018 | `TranscriptionEnvelope` carries a summary plus optional immutable detail. `TranscriptionQualityDetail` defines schema 1 raw windows, exact raw hashes, original tagged timing evidence and validity, assembled/normalized hashes, versioned algorithms, deduplicated applied IDs, explicit empty vocabulary identity, typed reasons and bounded attempts. |
| T019 | Sorted-key `quality-content-v1` serialization hashes exact UTF-8. Validation checks engine/SDK/model/artifact/build/dirty/language/input-format/duration/window/padding/OS/folding/stage-time identities and explicit reasons for missing metadata. Nonfinite original timing values remain tagged. IDs, arrays, text and serialized metadata are bounded before secondary encoding. Escaping overhead counts toward metadata. The final diagnostic slot and 4,096 metadata bytes are reserved for terminal explanations. No fallback engine is implemented. |
| T020 | The runtime bounds SDK text/token counts and combined token text before word building and carries original SDK evidence separately. `RecognitionAdmission` accepts whole windows only, caps 14 windows and 65,536 total raw bytes, checks token and metadata budgets, and retains the admitted prefix on later failure. The transcriber returns admitted evidence and typed terminal reasons. Existing 239,360/32,000/207,360 geometry and 4,800 padding remain unchanged. |
| T022 | New `quality-v2` migration follows unchanged `history-v1`; creates `transcription_quality`, `vocabulary_entries` and one-row `vocabulary_state`. Detail uses TEXT JSON with a cascading foreign key. Summary rows expose only an association bit; legacy detail remains absent. The legacy explanation is defined for the later detail UI. No vocabulary editor or matching behavior is implemented. |
| T023 | Capture reserves 393,216 bytes. Save commits parent/detail/usage together; normalized text is counted once in the parent and exact serialized detail bytes once in the detail. Retry compares exact text bytes, immutable metadata identity and content hashes while preserving delivery revisions. Startup reconciliation and confirmed deletion count all retained representations. Original row/payload/database ceilings, free-space checks and durable SQLite settings remain. |

## Integration boundary

T024 is **not complete**. The coordinator can now save and retain one full envelope, retry it without losing detail, discard it explicitly, and suppress insertion for incomplete detail even when an outer result flag is incorrectly complete. Tests exercise this with authored detail records.

Ordinary dictation still uses `WindowTextAssembler`. It receives bounded raw-window evidence from the transcriber but does not yet construct or save a production `TranscriptionQualityDetail`. Ordinary saved rows therefore continue to have no quality detail. Neither `ChunkPlanner` nor the new `TranscriptAssembler` has been wired into ordinary dictation. Completing that path, production provenance construction, and the safe assembler's integration belongs to the remaining T024 work after the adoption gate is resolved. History detail presentation remains Phase 5.

The failed planner gate does not invalidate the completed storage/admission/recovery support. It still prevents claiming Phase 4 or production adoption complete. See [the chunk-planner decision](chunk-planner-final.md) and [ADR 0011](../../../docs/adr/0011-chunk-planner-quality-baseline-semantics.md).

## Verification

Tests were added before the corresponding implementations. Initial targeted runs failed on the missing envelope/detail, transcriber and admission APIs; those failures were followed by passing targeted storage, recovery and admission runs. Bounds tests also drove the reserved diagnostic-overflow behavior.

`make check` passes: Swift format, shell syntax, JSON/artifact/document-link checks, 7 historical scorer tests, 25 quality scorer tests, 12 acquisition tests, plist validation, Go tests/vet and XCTest. The full XCTest result contains **261 passed, 9 skipped, 0 failed**. The skipped opt-in tests do not establish real model, speech or signed-app acceptance. `git diff --check` passes.

Local logs are under ignored `build/phase4-*.log`. No new ASR comparison, hardware resource measurement or signed-app acceptance was performed. Earlier long-form measurements were not rerun or relabeled as evidence for these changes.

## Constitution check

The changes stay within the existing native macOS targets and shared GRDB owner. No dependency, model owner, server endpoint or wire-schema change was introduced. Retained representations, tokens, windows, diagnostics and reservation sizes have explicit bounds; capacity failures preserve existing data. Normal logs contain no new speech or vocabulary content. No VoiceInk source was used. No architecture exception is required.

Pre-existing worktree changes were preserved. No commit, reset, model download, broad parameter search, normalization implementation or vocabulary behavior was performed.

## Bounded adoption investigation

The [regression investigation](phase4-regression-investigation.md) is complete. Saved evidence locates changed recognition at chunk edges and elsewhere, including a repeatable empty second decode behind minimum VAD's four-word technology loss. It also corrects the earlier distinction between time-only trim and anchored suffix replacement. No defensible implementation correction emerged. Retain the existing production path and defer T024; its checkbox stays open. Supporting persistence/admission/recovery remains complete. No Phase 5 work or new inference cycle was started.
