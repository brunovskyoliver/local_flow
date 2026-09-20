# 0018: Independent capture progress and overflow timeline preservation

**Status**: Accepted, 2026-09-19. Feature 008.

## Context

A real meeting recorded 199.00 seconds of microphone overflow and 276.34 seconds of system overflow. The earlier capture path omitted lost samples entirely. Independent loss compressed the two tracks by different amounts, undermining mixed transcription and speaker timing.

A deterministic regression using the real track worker and AAC encoder also demonstrated that awaiting a suspended progress recipient stops the recording loop: 40 arriving blocks fill the 32-slot ring and drop eight blocks. This reproduces one cause, not every historical drop.

## Decision

Keep each recording worker on its existing dedicated serial executor. Its progress callback runs independently with one delivery in flight and one replaceable newest snapshot. Capture does not await database/UI progress. Finalization and failure cancel delivery and discard pending progress without waiting for an uncooperative recipient. The existing open-segment database guard prevents late progress from replacing finalized fields.

The capture producer attaches source-frame positions to accepted slots and advances its total for whole callbacks dropped on overflow. The durable meeting consumer emits fixed-size zero blocks for lost intervals before returning later retained samples. After admission closes and callbacks join, it emits terminal loss through the final source position. Ordinary dictation and analysis consumers keep their existing pop contract. No duration-growing gap array, queue expansion or callback allocation is introduced.

Finalization closes admission and drains both retained samples and silence in bounded rounds, yielding between rounds. Source changes need a fresh source-format-compatible ring and encoder; a closed ring must never be reused. UI loss counters are read independently of progress delivery and retained across recording stretches. A saved loss warning depends on lost frames even when silence preserves duration.

## Consequences

New AAC recordings retain the positions of overflow intervals as silence. Silence represents missing audio, not recovered speech. Existing media remains unchanged; no alignment correction can be inferred from aggregate historic counters. Counts and warnings remain essential because matching file duration does not establish lossless capture.

A stalled disk/encoder or exhausted hardware resources can still cause overflow. The repair removes demonstrated progress coupling and prevents overflow from silently shifting subsequent samples. Real-device recording under load remains a separate acceptance measurement.

## Constitution check

Constitution 1.0.0: no exception. Native Swift/C and existing frameworks; fixed capture capacity and constant progress/silence memory (principles 1–2, 6); no model ownership change (3); offline, no audio/text logs or network transfer (4–5); existing SQLite fields and crash-safe media finalization (7, 9); source timing protects downstream attribution without inventing identities (10); regression tests and explicit hardware limits (12–13). Server, shared schemas and dependencies are unchanged (8, 11, 14).
