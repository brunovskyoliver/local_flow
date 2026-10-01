# 0031: One server for every service, and one specification for it

## Status

Proposed, 2026-10-01 (Feature 018). Refines ADR 0028. Records a constitution exception. Measurements are still to be collected.

## Context

Feature 014 moved dictation recognition and rewriting to the user's LocalFlow server. Summaries still go to whatever Settings › Summaries names, meeting transcription, speaker labels and identification run only on the Mac, and the Mac keeps its local models loaded even while the server serves. The owner wants one switch that puts every service on the server, with per-service overrides, and chose to specify the routing, the UI and remote meeting work as one feature.

The constitution's delivery gates say "Meeting and server capabilities remain separate specifications".

## Decision

- **Constitution exception.** Feature 018 is one specification covering server routing and remote meeting work. The rule exists to keep meeting work from riding along untested inside a server change. Mitigations: meeting work is its own independently testable user story with its own acceptance (spec User Story 3, quickstart §4–6), and its own task phase that the rest of the feature does not depend on. The exception applies to Feature 018 only; the gate stays in force.
- **Prepared windows, not segment upload.** The Mac keeps decoding, echo gating, levelling, windowing, resume and reconciliation, and sends the server the prepared window each model call needs, as 16 kHz mono 16-bit samples (`s16le`, in binary frames of kind `0x02`; Feature 018 research R1, R2). This supersedes ADR 0028's "meeting audio uploads as the existing ADTS AAC segments". Dictation keeps Float32 frames.
- **Two workers.** Live-preview windows use the dictation worker's resident Parakeet at a lower priority than dictation. Whisper Turbo, diarization and voice embeddings run in a second worker mode, `flowd-speech meeting`, with its own model owner, supervisor and 300 s job deadline (R3). The app's meeting runtimes move into `LocalFlowSpeech` so both share one copy (R4).
- **Three channels per device**: interactive (dictation, rewrite), live (live preview), background (summaries, meeting jobs) (R6).
- **Summaries on the channel** through an `analysis` op that fragments large requests and events (R8). A custom summaries server stays on the Mac; the server never fetches a client-supplied URL (R9).
- **Residency.** While the server serves rewriting and summaries the Mac stops its local rewrite model; while it serves dictation, Parakeet is not kept loaded; meeting models load only for a local fallback (R10).
- **Waiting, not silent local work.** When the server is unreachable or busy, summaries and meeting work wait and retry, with a per-item "Run on this Mac" action (spec FR-031).

## Consequences

- Meeting finalization sends about 1.9 MB per track-minute instead of 1.2 MB per minute of AAC; a 2-hour meeting is about 460 MB. Estimates, not measurements.
- The 24 GB Mac mini holds Parakeet, the 4B rewrite model and one meeting model at a time; working sets are measured in Feature 018 quickstart §5.
- The remote consent text gains meeting audio and summaries, with a new consent version.
- A meeting worker crash affects only meeting work; dictation and rewriting continue.

## Alternatives considered

- Two specifications (routing and UI, then remote meetings): follows the gate literally but splits one routing design across two features; the owner declined.
- Uploading AAC segments and repeating the Mac's preparation on the server: duplicates the decode, echo and levelling pipeline and its resume state.
- One worker for every model: Whisper or diarization would evict the resident Parakeet and stall dictation.
- Forwarding the custom summaries server through the LocalFlow server: lets any approved user make the shared server fetch arbitrary URLs and places one user's key on it.
