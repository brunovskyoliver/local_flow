# Feature Specification: Capture reliability

**Created**: 2026-09-19
**Status**: Implemented; physical recording acceptance pending
**Input**: Repair capture loss and track timing identified in the real meeting comparison. Preserve existing recordings and other in-progress features.

## User Scenarios & Testing

### User Story 1 - Recording survives slow progress updates (Priority: P1)

Recording continues while its progress display or persistence is delayed.

**Independent Test**: Suspend progress delivery, feed audio beyond queue capacity, and verify continued recording without drops caused by that suspension.

**Acceptance Scenarios**:
1. Given a recording and a stalled progress recipient, when audio continues arriving, then capture continues draining and memory remains bounded.
2. Given stalled progress delivery, when Stop occurs, then finalization completes without waiting for the recipient and late progress cannot modify a completed segment.

### User Story 2 - Loss does not shift later speech (Priority: P1)

Unavoidable recording loss leaves a silent interval in the correct position rather than moving later speech earlier.

**Independent Test**: Force a known loss between distinguishable audio blocks and at the end; verify output duration, silence position and surviving block order.

**Acceptance Scenarios**:
1. Given one track drops samples, when later samples are captured, then the dropped interval remains in that track's timeline.
2. Given trailing loss before Stop, when finalization completes, then that interval remains in the recording.
3. Given an existing recording, when the updated app opens it, then the original audio is untouched and is not represented as repaired.

### User Story 3 - Capture loss is visible (Priority: P2)

A user can tell that a recording contains missing audio during capture and afterward.

**Independent Test**: A nonzero loss count causes a warning even when silence keeps the file duration equal to the meeting timer.

### Edge Cases

Long gaps, gaps larger than a queue, gaps split across output blocks, stereo/multichannel sources, non-48 kHz input, consecutive drops, terminal drops, cancellation, write/encode failure, delayed heartbeat completion after finalization, and legacy shortened recordings.

## Requirements

- **FR-001**: Progress recipients MUST NOT block ongoing audio draining.
- **FR-002**: Pending progress MUST remain bounded and may coalesce to the newest snapshot; already completed recording state MUST not be overwritten.
- **FR-003**: Captured audio MUST preserve the duration and position of intervals lost through capture overflow using silence, with surviving samples retained in order.
- **FR-004**: Finalization MUST include terminal lost intervals without accumulating whole recordings in memory.
- **FR-005**: Capture callbacks MUST remain nonblocking with fixed memory capacity and counted overflow.
- **FR-006**: Recording loss MUST remain visible during capture and in saved meeting details even when durations match.
- **FR-007**: Existing recordings MUST remain unchanged; their missing samples MUST not be claimed as recovered.
- **FR-008**: Dictation and provisional-analysis overflow behavior MUST remain compatible.
- **FR-009**: Regression tests MUST cover stalled progress, gap ordering, terminal gaps, bounds, completed-state protection and loss warnings.

## Key Entities

- Capture interval: incoming frames in source order, either retained or lost.
- Progress snapshot: latest per-track duration, bytes, queue and loss counters.
- Recording warning: persisted evidence of capture loss or duration mismatch.

## Success Criteria

- **SC-001**: A controlled slow-recipient test records all supplied audio with zero drops caused by progress suspension.
- **SC-002**: Forced-loss output has exactly the original input timeline length before codec padding, and later samples remain at their original positions.
- **SC-003**: Pending progress remains bounded independently of recording duration or recipient delay.
- **SC-004**: Loss warnings appear for every nonzero persisted drop count in regression tests.
- **SC-005**: A measured long recording under load establishes real-device capture loss and alignment separately from deterministic checks. Uncollected hardware evidence remains explicitly pending.

## Assumptions

The exact machine-load condition of the historic meeting cannot be reconstructed from aggregate counters. Fixing a reproduced cause does not prove all sources of capture loss are eliminated. ASR model adoption, cloud services, speaker-model changes, and recovery of old missing audio are outside scope.

## LocalFlow resource and failure acceptance

Fixed capture rings, bounded progress and bounded silence generation; local Swift/C and existing Apple audio APIs; no new dependency or heavy model. Existing failure and crash recovery retain written audio. Hardware acceptance includes load, duration, gap and resource measurements and is not implied by `make check`.
