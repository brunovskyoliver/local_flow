# ADR 0019: Default final meeting transcription with Whisper Turbo

Date: 2026-09-19. Status: Accepted.

## Context
The user requested Whisper large-v3-turbo as the default meeting transcription
model after local replay of the supplied meeting. The 120-second trials recovered
speech lost by short windows, but two excerpts produced repetition loops. The
benchmark helper was not previously part of the app runtime.

## Decision
Bundle the pinned Sotto native speech helper, statically linked with whisper.cpp,
and provision Turbo plus Silero through the existing verified model store. Add a
meetingTranscription workload to ModelLifecycleCoordinator. All final meeting
actions use that workload. Dictation and live previews retain Parakeet. No model
runs alongside another heavy model.

Use bounded 120-second windows with automatic language detection and fresh context
between requests. Retry obvious consecutive repetition with bounded 60-second
windows; fail visibly if it persists. Native helper IO and output are bounded,
with deadlines and kill/join cancellation. Temporary audio is removed after use.

Pass identity includes engine and geometry so old partial passes cannot resume
with different boundaries. Acquire the model before replacing a successful final
pass to preserve the prior transcript when the model is unavailable. Existing
mid-pass partial persistence semantics remain in place.

## Dependency justification
The existing native helper provides the already-evaluated model behavior and
Metal execution without a Python, Node or application server runtime. It links
system frameworks and pinned native libraries. A new native helper adds packaging
and cancellation responsibilities, addressed by signing, bounded protocol IO and
lifecycle ownership. Preserve all dependency notices. Weights are not bundled.

## Constitution check
Principles 1-6: native, local, bounded processing with centralized exclusive model
ownership; no privacy change or full-meeting accumulation. Principles 7-10:
existing SQLite pass persistence and source media retained; no speaker semantics
change. Principles 11-14: structured protocol validation, tests, measured smoke
results separate from memory targets, scoped dependency with notices. No
constitution exception or parallel heavy-model execution is introduced.

## Consequences
Final processing requires the separate Turbo installation. Missing assets give
setup guidance instead of falling back silently. Repetition detection does not
establish transcript correctness. Hardware memory and long-session acceptance
remain separate from automated regression checks.


### Recovery refinement from the full meeting replay

The first full run encountered a loop at 600 seconds into the second recording
stretch. Both the 120-second request and a 60-second retry repeated a stock phrase;
a 30-second request also lost speech. Isolated 15-second requests recovered spoken
content. Recovery now has two bounded levels: split the main request in half,
then split only a still-repeating half into four pieces. With a 120-second main
window, final pieces are at most 15 seconds. Maximum work is 11 requests and
360 seconds of input including retries. Reject repetition in both pieces and
the combined result. The main window geometry and persisted resume boundaries
remain unchanged, so already successful windows can resume safely.
