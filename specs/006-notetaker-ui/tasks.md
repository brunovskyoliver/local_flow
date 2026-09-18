# Tasks: Notetaker UI

## Phase 1: Setup
- [x] T001 Record scope, screenshot design and constitution check in specs/006-notetaker-ui/.

## Phase 2: Foundation
- [x] T002 Add shared native controls in apps/macos/LocalFlow/Features/Meetings/NotetakerStyle.swift and register source.
- [x] T003 Add regression coverage and source presentation in apps/macos/LocalFlow/Core/Transcripts/TranscriptModels.swift and apps/macos/LocalFlowTests/MeetingLibraryTests.swift (FR-006).

## Phase 3: US1 library
- [x] T004 [US1] Implement isolated, stale-safe preview in apps/macos/LocalFlow/Features/Meetings/MeetingLibraryViewModel.swift (FR-002).
- [x] T005 [US1] Rebuild apps/macos/LocalFlow/Features/Meetings/MeetingLibraryView.swift and rename App/MainWindowRouter.swift destination (FR-001, FR-003, FR-008).

## Phase 4: US2 reader
- [x] T006 [US2] Rebuild apps/macos/LocalFlow/Features/Meetings/MeetingDetailView.swift with thoughts/transcript/summary tabs and recording details (FR-004 through FR-008).

## Phase 5: Validation
- [x] T007 Run make check and native synthetic visual captures, record results in specs/006-notetaker-ui/acceptance.md (SC-001 through SC-004).

## Dependencies and execution
T001 -> T002/T003/T004 -> T005 -> T006 -> T007. Foundation model work and styling could run independently; this implementation proceeds sequentially. Validate library first, reader second, then check the whole feature. No hardware acceptance inferred from tests.
