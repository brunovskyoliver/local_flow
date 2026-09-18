# Feature specification: Notetaker UI

Created: 2026-09-18. Status: implementation. Input: six supplied Wispr Flow screenshots.

## User scenarios & testing

### US1: Browse recordings (P1)
Rename Meetings to Notetaker. Show a centered, date-grouped Past notes list, Today card, New note action, and a right-hand preview on hover or keyboard focus. Clicking a note opens its full-page detail. The three-dot menu has Copy link, Share, Report and Delete in screenshot order.
Acceptance: existing recordings appear with their title and local time; hover changes the preview without opening the note; Delete asks for confirmation and preserves existing failure recovery.

### US2: Read and edit a note (P1)
The detail screen has a serif title, timestamp, My thoughts / Transcript / + Summary tabs, a back button and compact toolbar. My thoughts edits the existing saved notes. Transcript uses neutral rounded bubbles and colored source labels. Summary uses the same reading column and toolbar with an honest unavailable state.
Acceptance: reopening preserves thoughts; tab changes preserve edits; transcript source labels distinguish microphone-only, system-only and mixed audio; playback, retranscription and diagnostics remain accessible.

### Edge cases
Empty library, missing note, rapid hover/selection changes, deleted preview, long titles, paused/active capture, failed save/delete/transcription, dark appearance, keyboard navigation and narrow windows must remain usable.

## Requirements

- FR-001: Match the supplied list geometry, warm neutral surfaces, compact icons, date headers and restrained hover state; rename navigation to Notetaker.
- FR-002: Hover and keyboard focus must preview the correct note's title, timestamp, duration and available overview without stale results.
- FR-003: Display the four menu options in supplied order; deletion must work through the existing confirmed local deletion path.
- FR-004: Open each note in a centered full-page reader with three tabs, persistent title/time and back navigation.
- FR-005: My thoughts must autosave through existing persistence, surface failures and flush when leaving.
- FR-006: Transcript bubbles must label microphone-only audio You, system-only audio Others, and mixed audio Unassigned. These are audio-source labels, not speaker identification. Never infer a speaker count from track count.
- FR-007: Keep recording controls, playback, recovery, transcript paging/copy/retry and technical information accessible.
- FR-008: Missing summary, sharing, reporting, calendar and chat services must have truthful unavailable or empty states, with no fake data or silent network activity.

## Key entities
Existing recordings, notes and transcript segments. Hover preview and selected tab are transient presentation state.

## Success criteria
- SC-001: A recording opens in one click and returns to Past notes in one click.
- SC-002: All three tabs and all four menu choices are visible and keyboard accessible.
- SC-003: The library, hover preview and detail screens are visually inspected against the supplied references at wide and compact sizes.
- SC-004: Source-label cases and stale preview behavior pass regression tests; repository checks pass.

## Assumptions and clarification
User explicitly chose “Focus on the UI and source labels” on 2026-09-18. Summary generation and shared-note services are out of scope. Existing mixed transcripts cannot identify individual speakers. Use source labels only when supported. Unavailable screenshot actions explain this limitation. Preserve the existing app sidebar destinations and branding.

## LocalFlow resource and failure acceptance
Retain the library's 40-row and transcript pager's existing bounds. Keep only one hover preview and discard stale asynchronous loads. No models or network requests are introduced by browsing. Notes retain their 1 MiB bound and existing autosave/recovery. Hardware resource acceptance is not claimed by this visual change.
