# Feature 009: Turbo meeting transcription

Created: 2026-09-19. Status: Implemented and verified.
Input: Use Turbo by default for meeting transcriptions.

## User scenarios and testing

### US1: Default final meeting transcription (P1)
After recording a meeting, the user receives a local Whisper large-v3-turbo final transcript without choosing an engine. Automatic completion, Transcribe, Retry, Re-transcribe and interrupted-pass recovery use the same default.
Acceptance: a recorded meeting completes using Turbo and records its model identity. Dictation and live previews continue using their existing model.

### US2: Install the meeting model (P1)
Settings names the default meeting model and provides installation and verification. Once installed, final transcription works offline.
Acceptance: a missing or invalid model gives actionable setup guidance. An attempted retranscription with an unavailable model preserves the existing final transcript.

### US3: Cancel and recover (P1)
The user can cancel final transcription and later retry. Audio remains on disk and completed persisted progress remains recoverable.
Acceptance: cancellation releases the model before another heavy workload starts. A changed model or processing geometry restarts an incompatible partial pass.

### Edge cases
Silence, very short trailing audio, multilingual speech, repeated hallucinations, helper startup/crash/timeout, missing assets, concurrent dictation, oversized output and interrupted provisioning.

## Requirements

- FR-001: All final meeting actions MUST default to Whisper large-v3-turbo; live previews and dictation retain Parakeet.
- FR-002: Recognition MUST stay local and work offline after explicit verified provisioning.
- FR-003: Missing Turbo MUST produce setup guidance, preserve an existing final transcript before admission, and MUST NOT silently substitute another model.
- FR-004: Final processing MUST use bounded audio windows, bounded output and one heavy model at a time. Cancellation MUST release model resources and remove temporary audio.
- FR-005: Pass identity MUST distinguish Turbo from older passes and incompatible window geometry.
- FR-006: Obvious consecutive phrase loops MUST trigger a bounded shorter-window retry; unrecovered loops MUST fail visibly instead of being silently accepted or deleted.
- FR-007: Packaging MUST include the native helper and required license notices, with pinned model integrity metadata.

### Key entities
Meeting model package: immutable asset identities and installation readiness.
Final transcription pass: model, engine, processing geometry, progress and transcript segments.

## Success criteria

- SC-001: All five final action paths select Turbo without a model selector.
- SC-002: Missing-model retranscription leaves the previous final text readable.
- SC-003: Recorded excerpts can run through the production runtime offline; result and elapsed time are recorded without claiming a human-verified accuracy score.
- SC-004: Automated lifecycle, cancellation, bounds, repetition and finalization regression checks pass.

## Assumptions
The conversation concerns final meeting transcripts. Existing recordings are not rewritten or automatically retranscribed. The previously evaluated native Turbo model is the intended Turbo model. Model quality is imperfect; repetition checks cannot detect every hallucination.

## LocalFlow resource and failure acceptance
Never accumulate full meeting audio. At most 120 seconds per request, one request at a time, with shorter bounded retries. Preserve original recordings. Test helper cancellation and resource exclusion. Record actual smoke measurements separately from hardware resource acceptance; do not claim unmeasured RSS targets.
