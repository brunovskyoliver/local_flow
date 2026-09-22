# Tasks: Turbo meeting transcription

## Phase 1: Design
- [x] T001 Record spec, research, bounds, contracts and constitution check in specs/009-turbo-meeting-transcription.

## Phase 2: US1 default final transcription
- [x] T002 [P] Add native runtime, bounded cancellation/IO and repetition retries in Core/Transcription/WhisperMeetingRuntime.swift (FR-004, FR-006).
- [x] T003 [P] Add lifecycle meeting workload and finalizer geometry/identity with missing-model preservation (FR-001, FR-003, FR-005).
- [x] T004 [P] Add verified Turbo package and settings/AppServices default routing (FR-001, FR-002, FR-003).
- [x] T005 Package helper and dependency notices; document ADR/provenance (FR-007).

## Phase 3: Validation
- [x] T006 Verify focused regression tests and production offline excerpt smoke (SC-002, SC-003, SC-004).
- [x] T007 Run make check, independent review and resolve findings (SC-001, SC-004).
- [x] T008 Converge against spec and record acceptance evidence without unmeasured resource claims.

## Language reliability follow-up
- [x] T009 [US1] Add regression cases in apps/macos/LocalFlowTests/WhisperMeetingRuntimeTests.swift for short/weak, empty, repetitive and valid changed-language evidence.
- [x] T010 [US1] Gate language decisions in third_party/sotto/Engine/worker.cpp and fallback updates in apps/macos/LocalFlow/Core/Transcription/WhisperMeetingRuntime.swift; version automatic passes in Core/Transcription/MeetingLanguage.swift.
- [x] T011 Run make check and review the language changes; report real-meeting quality and resource measurements separately.

Validation (2026-09-21): baseline and final `make check` passed, including the native helper build. Focused regressions reproduced the fallback defects before the fix. No new real-meeting WER, latency or RSS measurement was collected; the 3-second threshold remains a heuristic.
