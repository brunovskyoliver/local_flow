# 0008: ScreenCaptureKit for meeting/system audio

## Status

Accepted, 2026-09-16. Future capabilities remain deferred.

## Context

Future meetings need separate mic/system tracks and bounded memory.

## Decision

Prefer ScreenCaptureKit for system audio, with supported microphone capture or AVAudioEngine according to OS availability. Stream encoded independent tracks.

## Consequences

Feature 003 must settle OS support, clock alignment and crash-recoverable fragments; an unfinished M4A alone is insufficient. No meeting implementation now.

## Alternatives considered

Virtual audio drivers; one mixed track; raw PCM accumulation.
