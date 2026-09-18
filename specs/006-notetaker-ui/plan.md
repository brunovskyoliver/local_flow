# Implementation plan: Notetaker UI

Date: 2026-09-18. Spec: [spec.md](spec.md).

## Summary and technical context
Native SwiftUI presentation over existing MeetingLibraryViewModel, MeetingNotesEditor and TranscriptPager. AppKit remains limited to existing clipboard/playback and native presentation. No dependencies, server changes or schema migrations.

## Constitution check
Pass before and after design. One native app and existing source boundaries; no model ownership changes; bounded existing paging; one preview load retained with cancellation/stale-result guards; offline reading and editing; existing SQLite transactions and confirmed file deletion; no inferred identities for mixed audio; no AI output is generated; no new dependencies. No exception or ADR required. No hardware memory measurements claimed.

## Project structure
Change Features/Meetings/MeetingLibraryView.swift and MeetingDetailView.swift. Add shared presentation components in Features/Meetings/NotetakerStyle.swift. Extend MeetingLibraryViewModel with isolated hover-preview state. Add source presentation metadata in Core/Transcripts/TranscriptModels.swift. Rename the destination in App/MainWindowRouter.swift. Regression tests remain in LocalFlowTests/MeetingLibraryTests.swift and transcript tests. Register added source files in the Xcode project.

## Design
List content maximum width 760 points; detail reading width 600 points, toolbar width 860 points; preview width 230 points, collapsing into a popover below 800 points of content width. Warm gray Today card, 10-point row corners, 28-point document icon tile, quiet 13-point type. Detail title uses Iowan Old Style at 28 points. Transcript bubbles fit their content with source labels above contiguous source groups. Thin underlined tab strip. Existing technical cards live in Recording details sheet. No invented summary text: preview explains unavailable summary and can show an explicitly labeled thoughts excerpt.

## Validation
Run make check, regression tests for source mapping and preview isolation, then render native views using synthetic records in a test harness and inspect captures at wide/compact sizes and dark appearance. Use no personal recordings for fixtures. Resource/hardware capture acceptance stays separate.
