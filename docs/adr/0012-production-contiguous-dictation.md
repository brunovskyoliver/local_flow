# ADR 0012: contiguous dictation with saved processing stages

Date: 2026-09-17. Status: implemented for the current-engine pipeline under the [owner priority revision](../../specs/002-transcription-quality/acceptance/owner-priorities.md).

## Decision

Keep the pinned Parakeet engine and use fixed contiguous windows of at most 239,360 samples. Production overlap is zero and stride is 239,360 samples; the final window contains the remaining real samples and retains the existing 4,800-sample minimum padding. The 180-second input cap permits at most 13 fixed windows, within the existing 14-window bound.

Use `TranscriptAssembler`'s contiguous path with algorithm identity `contiguous_fixed239360_preserve_v1`. It preserves the received text in order, adds a separator only where needed, and discards no lexical words. No VAD dependency is loaded. Contiguous assembly avoids unsupported overlap deletion and the need to infer duplicate words from uncertain timings. Boundary recognition errors remain possible and must be reported when observed in ordinary use.

This adopts the simple bounded path from the existing experiments, not the best downloaded-corpus WER result. The owner explicitly removed those scores and within-sentence switching as integration blockers. Existing regressions remain in the historical reports, and this decision claims no new speech-accuracy result or resource acceptance.

## Evidence and delivery

Whole-window admission reserves processing metadata headroom and counts both raw and assembled JSON escaping. A new window becomes part of the retained envelope only after complete detail validation. A later failure preserves the last validated envelope. Fixed contiguous seams are stored with zero-discard audit fields. These optional fields preserve older detail hashes when absent.

After assembly, the coordinator applies the versioned N001–N006 normalizer once, records the actual normalization duration and changed rule IDs, and saves raw/assembled/normalized representations atomically. Empty vocabulary has an explicit revision/hash. Model identity and manifest/artifact hashes come from the descriptor also verified by the lifecycle's factory. Unavailable source dirty state is recorded as unavailable, not inferred from the bundle version.

Any known loss, capacity failure, interruption or normalization review reason prevents automatic insertion. An empty recognized chunk within otherwise nonempty output requires review; a wholly silent recording retains the existing no-speech behavior. Failed saves retain one full envelope; retry never reruns processing or rewrites its hash.

Historical evaluation commands explicitly select the historical overlap profile. Their geometry, assembly identity and absent-normalization labeling remain unchanged. No production UI exposes this historical profile.

## Constitution check

No exception is required. The changes use existing native targets, the central model lifecycle and shared GRDB owner. No server or wire change, extra runtime dependency, network request or additional model residency is introduced. Existing text/metadata/window/row/database caps, full-envelope reservation, cancellation, audio cleanup and explicit insertion guards remain enforced. No VoiceInk code is used.

Deterministic tests verify exact audio coverage at 180 seconds, zero contiguous lexical discards, stage hashes, bounded admission, full-envelope recovery and insertion suppression. Signed-app launch and automated tests do not replace owner speech checks or uncollected resource measurements.
