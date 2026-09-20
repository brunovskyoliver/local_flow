# Implementation plan: Capture reliability

**Date**: 2026-09-19 | **Spec**: [spec.md](spec.md)

## Summary

Reproduce delayed-heartbeat coupling, decouple progress from capture with one in-flight delivery and one newest pending value, and preserve overflow intervals in newly encoded audio. Keep the existing application and model boundaries.

## Technical context

Swift/C, macOS, AVFoundation, existing GRDB store and XCTest. No dependencies or schema migration. Fixed 32-slot capture ring, 4096 source frames per output block. Introduce an opt-in timeline-preserving consumer API for durable meeting recording only; ordinary dictation and analysis consumers retain their policies.

## Constitution check

Pre-design and post-design: principles 1–14 satisfied. Native app and Go server boundaries unchanged. No heavy model changes, uploads, credentials, telemetry or transcript logging. Ring capacity stays fixed; new per-slot offsets and constant counters add bounded metadata. Silence uses an existing reusable PCM buffer; each pop emits at most 4096 frames. Progress capacity is one in-flight plus one newest snapshot. Synchronous encoding/writes remain on the dedicated track executor. Finalization closes admission and drains bounded rounds, yielding between rounds, then finishes the encoder and crash-safe writer. Store updates retain the open-segment guard. No architecture exception or new dependency; record the changed contract in ADR 0018.

## Design

Each valid source callback advances a monotonically increasing source-frame position, including callbacks dropped on overflow. Accepted ring slots record their starting source-frame position. The opt-in pop returns zero-filled blocks before a slot whenever its source position lies ahead of the consumer cursor. It advances the slot only after the gap is exhausted. On closed/joined rings, terminal loss is emitted through the final source position. No gap list grows with duration.

A suspended heartbeat callback must not suspend the worker loop. Keep a single delivery task and a replaceable pending snapshot, preserving delivery order and newest progress. Stop/failure cancels delivery and clears pending state; a callback ignoring cancellation may finish, but its store update is guarded against finalized segments. No unbounded tasks per heartbeat.

Loss warnings use dropped-frame counts independently of duration mismatch. The UI identifies missing audio without claiming it was recovered. Existing AAC files remain unchanged; no retrospective alignment is guessed.

## Project structure

- `apps/macos/LocalFlow/Core/Audio/AudioCaptureRing.{c,h}` and `MeetingSampleRing.swift`: timeline-preserving pop.
- `apps/macos/LocalFlow/Core/Meetings/MeetingTrackWorker.swift`: bounded progress and gap-aware encode/finalize.
- `apps/macos/LocalFlow/Core/Storage/MeetingStore.swift`: persisted warning calculation.
- `apps/macos/LocalFlow/Features/Meetings/`: existing warning surfaces.
- Corresponding ring, worker, storage and coordinator tests.
- `specs/008-capture-reliability/acceptance/`: red/green evidence and pending hardware conditions.

## Validation

Deterministic stalled-recipient reproduction, real ring signal/gap/signal checks, trailing and repeated overflow checks, encoded-duration and finalization tests, completed-state protection, warning tests, source-boundary checks and full `make check`. Keep the full suite running to completion and diagnose stalls rather than declaring a timeout a pass. Real-device long-run acceptance is a separate measurement, never inferred.
