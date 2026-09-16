# 0002: FluidAudio as initial local audio ML implementation

## Status

Accepted, 2026-09-16. Future capabilities remain deferred.

## Context

Slovak and English STT must run locally, and model ownership must stay controllable.

## Decision

Prefer FluidAudio with Parakeet TDT v3 behind TranscriptionEngine. Future DiarizationEngine and SpeakerEmbeddingEngine are separate protocols added with those features.

## Consequences

Pin and review a release and model license in Feature 001. Verify Slovak accuracy, bounded chunk behavior and release on M5. SDK and model licenses are separate; inspect binary/transitive components. Do not assume the English streaming model meets multilingual requirements.

## Alternatives considered

Whisper/native CoreML adapters; direct model integration.
