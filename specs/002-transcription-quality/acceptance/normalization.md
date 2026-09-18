# Phase 5 formatting and history detail

Current status: T024/T029 are now integrated; see [production integration](production-integration.md). The report below preserves the earlier independent Phase 5 implementation checkpoint.

Date: 2026-09-17. The owner requested Phase 5 continuation. This report covers the independent deterministic formatting and history work; it does not approve a production chunk planner or close Phase 4.

## Implemented scope

- T026/T028: `TranscriptNormalizer` applies N001 canonical NFC, N002 line endings, N003 ASCII horizontal whitespace and N004 guarded comma spacing. Capitalization and artifact deletion remain identity. Empty vocabulary is the only supported mode; V001 stays in Phase 6. Exact UTF-8 comparison detects changes, including canonically equivalent but byte-distinct input. A full unchanged pass establishes the fixed point. Changed rule IDs are committed only on success.
- Text buffers are capped at 65,536 bytes, span records at 16,384, comma candidates at 8,192 and passes at 32. Bounds can be reduced in tests but cannot exceed production limits. Capacity or nonconvergence returns unchanged assembled input and no committed IDs. Unexpected controls remain in the output with a review reason. Quote/backtick groups and technical tokens prevent comma edits; letters, numbers, casing and ordinary repetition are not rewritten.
- T027/T030: `selectedEnvelope` reads the parent and detail in one database snapshot, checks cancellation and rejects excessive stored JSON before loading it into Swift. History retains one detail, coalesces replacement requests and waits for the cancelled load to finish before starting another. Closing, confirmed deletion and leaving History clear detail. Refresh reloads delivery/recovery state without reprocessing saved text; externally deleted records clear the cached selection.
- T031: the existing History window contains an inline details panel. It labels Normalized, Assembled and Raw recognition separately, presents raw windows in received order with sample intervals and overlap guidance, and shows completeness separately from delivery/recovery. Processing details include algorithm/model/build/settings identities, vocabulary revision/applied IDs, durations, timing validity, missing evidence, attempts and hashes. Legacy rows display the prescribed unavailable-detail message. Copy and guarded insertion continue to use the saved parent text.

The ordinary history page bounds, window routing, explicit insertion safeguards and shared database owner are unchanged. No history is reprocessed when a detail opens.

## Production dependency

T029 is not implemented. T024 still lacks production quality-envelope construction and an approved assembly path. The [chunk-planner decision](chunk-planner-final.md) and [runtime diagnosis](empty-tail-diagnosis.md) remain in force. Ordinary dictation therefore still saves rows without quality detail. The new normalizer is independently callable and tested, but is not connected to ordinary dictation. No empty vocabulary identity or raw provenance is fabricated for historical rows.

The authored full-envelope tests demonstrate storage and presentation behavior, not production speech quality. Connecting normalization after approved assembly, recording production stage timings/hashes and validating full-envelope normalized retry/insertion remain T029 work.

## Deterministic validation

Tests were written first. Initial targeted builds failed on the missing normalizer and detail-loading APIs in `build/phase5-red.log` and `build/phase5-history-red.log`. The subsequent targeted run passed all 20 tests then present. Additional regressions cover quote delimiters, raw overlap/order, excessive stored detail, changed recovery state and external deletion.

Tests cover every empty-vocabulary N001–N006 authored fixture, exact-byte second-pass idempotence, preserved controls/technical tokens, text/span/candidate bounds, NFC expansion and nonconvergence fallback. History tests cover cancelled and stale loads, a peak of one active detail read, legacy absence, normalized-only search, exact raw bytes and hashes after restart, and deletion clearing cached detail. Lowered candidate/pass bounds exercise overload paths that the independent text/span limits otherwise dominate.

The full repository check is `make check`; private logs are under `build/phase5-check.log`. It checks Swift formatting, shell syntax, JSON/artifacts/document links, Python scorer/acquisition tests, plist validity, Go tests/vet and XCTest. `git diff --check` also passes. Final XCTest counts are recorded in [validation.md](validation.md).

## Acceptance still open

T032 remains unchecked. No signed-app keyboard/VoiceOver, microphone, offline insertion or real speech acceptance was performed during this continuation. No human meaning verdicts were supplied or inferred from the authored fixtures. The fixture review fields remain unchanged and unreviewed. No corpus inference run, model download or hardware resource measurement was performed.

To close T032 after T024/T029, exercise the signed app's stage picker, disclosure groups, error/retry and deletion controls with keyboard and accessibility tools; verify normalized copy/search/guarded insertion and restart persistence with real production envelopes; attach reference/output-hash human meaning reviews. Deterministic tests alone do not close that task.

## Constitution check

The changes stay in the existing native macOS targets and shared GRDB owner. Bounded text/detail processing introduces no model owner, runtime dependency, network request, server or wire-schema change. No transcript or vocabulary content is added to ordinary logs. No architecture exception or VoiceInk source is involved. Existing worktree changes were preserved.
