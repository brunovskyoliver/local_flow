# 0016: Live preview and durable-audio transcription passes

**Status**: Accepted (2026-09-18), Feature 005 design. Production implementation
continues after the setup and throughput phases.

## Context

Feature 004 stores microphone and system audio as separate durable ADTS stretches.
Dictation recognizes contiguous 239,360-sample windows. That geometry is useful
for the final transcript but waits too long to provide a live preview.
Recording must continue if recognition fails or cannot keep up.

## Decision

Use two passes under the existing `ModelLifecycleCoordinator`, with one model
lease at a time and no second runtime owner.

The live pass receives a bounded PCM tap from each recording worker, converts
and mixes to one mono 16 kHz analysis stream, and uses a separate, versioned
contiguous planner. Phase 2 selects 96,000-sample windows (`live_contiguous_96000_v1`) from the throughput evidence in
[the Phase 2 report](../../specs/005-live-meeting-transcription/acceptance/throughput.md).
Live text is provisional. Lag may discard complete live windows into recorded
gaps; the capture and durable write path never waits for recognition.

After Stop, finalization decodes the original durable tracks incrementally,
4,096 source frames at a time. It recognizes the entire mixed stream using
`contiguous_fixed239360_preserve_v1`, including intervals skipped by the live
pass. The final pass replaces provisional text only when its completion
transaction commits. Progress and segments are persisted together so a matching
pass can resume at a window boundary after interruption.

Both passes use `mixed_mono_16k_v1`: average each track's channels, resample to
16 kHz, mix both available tracks with `0.5 × (mic + system)` clamped to ±1,
or emit a lone available track at unity gain. The descriptor records source,
geometry and contributing tracks. It does not attribute words to speakers.

## Consequences and limits

- The final transcript can differ from the preview because its windows are
  longer and it decodes AAC instead of pre-encode PCM.
- Echo captured by both tracks can be recognized twice. Simultaneous speakers
  may mask each other in the mix. No echo cancellation, source separation,
  diarization or identity inference is added in Feature 005.
- A single-stream throughput spike establishes a planner input and the SC-006
  multiplier. It does not prove live latency, production finalization time,
  long-run memory stability, recovery, accuracy or two-track mixing behavior.
- Audio remains in the original track files. No derived analysis recording is
  stored and no full meeting is loaded into memory.

## Constitution check

Constitution 1.0.0: no exception. Existing native frameworks and packages only;
fixed-capacity streaming (principles 2 and 6); exclusive model lifecycle
ownership (3); offline local recognition and content-free measurements (4–5);
transactional persistence and recovery (7 and 9); no speaker identity claims
(10); deterministic boundaries plus separate hardware evidence (12–13).
No server, cloud, new permission, package or later-roadmap capability is added.

## Alternatives

Recognizing each track separately doubles work and produces competing text.
Overlapping live windows need seam decisions and add recognition work.
Reusing dictation's bounded whole-session collector would impose its 180-second
limit. Tailing live AAC files adds decoder state and delay to a preview path.
The separate live planner and bounded PCM tap avoid those costs while finalizing
from the durable files preserves reproducibility.
