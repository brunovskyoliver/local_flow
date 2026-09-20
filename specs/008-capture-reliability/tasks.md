# Tasks: Capture reliability

## Setup and foundation
- [x] T001 Define scope and constitution gates in specs/008-capture-reliability/spec.md and plan.md.
- [x] T002 Reproduce timeline compression and stalled heartbeat in apps/macos/LocalFlowTests/MeetingTrackWorkerTests.swift and record evidence in specs/008-capture-reliability/research.md.

## US1: Recording survives slow progress
- [x] T003 [US1] Implement bounded independent delivery and finalization cancellation in apps/macos/LocalFlow/Core/Meetings/MeetingTrackWorker.swift.
- [x] T004 [US1] Verify stalled-recipient, coalescing and terminal-state tests in apps/macos/LocalFlowTests/MeetingTrackWorkerTests.swift.

## US2: Preserve recording timeline
- [x] T005 [P] [US2] Add source positions and opt-in bounded silence emission in apps/macos/LocalFlow/Core/Audio/AudioCaptureRing.c and AudioCaptureRing.h.
- [x] T006 [US2] Wire preserving pop and bounded complete final drain in apps/macos/LocalFlow/Core/Audio/MeetingSampleRing.swift and Core/Meetings/MeetingTrackWorker.swift.
- [x] T007 [US2] Test middle/trailing/multiple gaps, samples, channel layouts, and codec duration in apps/macos/LocalFlowTests/MeetingSampleRingTests.swift and MeetingTrackWorkerTests.swift.

## US3: Make loss visible
- [x] T008 [US3] Retain nonzero loss warnings independently of duration and test late progress in apps/macos/LocalFlow/Core/Storage/MeetingStore.swift and LocalFlowTests/MeetingStoreTests.swift.
- [x] T009 [US3] Present clear existing/new recording loss warnings in apps/macos/LocalFlow/Features/Meetings/MeetingDetailView.swift and relevant status view.

## Validation
- [x] T010 Record changed capture contract and constitution check in docs/adr/0018-capture-progress-and-timeline.md and docs/architecture/audio-pipeline.md.
- [x] T011 Review actual diff, run targeted regressions and make check; record results in specs/008-capture-reliability/acceptance/validation.md.
- [x] T012 Record real-device acceptance status and remaining conditions in specs/008-capture-reliability/acceptance/hardware.md.

## Dependencies and delivery

T001–T002 precede implementation. US1 and C-ring work T005 are disjoint and can run in parallel. T006 follows both T003 and T005. Warnings follow defined gap semantics. Final validation follows all implementation. Deliver capture independence, then timing preservation and warnings. Hardware acceptance remains explicitly separate from deterministic validation.

## Phase 6: Convergence

- [ ] T013 Collect SC-005 physical microphone/system-audio acceptance under representative load using specs/008-capture-reliability/quickstart.md; record actual duration, alignment, loss, queue and RSS measurements in specs/008-capture-reliability/acceptance/hardware.md. Deterministic checks do not complete this task.

Convergence outcome: implementation covers FR-001–FR-009 and deterministic SC-001–SC-004. The only remaining acceptance task is SC-005 hardware evidence. No additional code defect was found in independent review.
