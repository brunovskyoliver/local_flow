# Notetaker UI acceptance

Date: 2026-09-18. Scope follows the user's confirmation to focus on UI and source labels.

## Design review

The supplied screenshots guided the centered library, Today surface, date groups, document tiles, preview rail, note menu order, serif detail title, underlined tabs and neutral transcript bubbles. Existing LocalFlow branding and navigation destinations are retained. Calendar, summary, sharing and chat services are unavailable and are labeled accordingly. The implementation is a native adaptation; pixel-for-pixel equivalence with Wispr Flow is not asserted.

Native synthetic captures cover the list, My thoughts, Transcript and Summary at 1440 x 850 points in light/dark appearance and at 680 x 850 points in light appearance. The actual 2x bitmap sizes depend on the host display. No personal recording data is used.

## Behavior and bounds

- Hover/focus preview is separate from the open note. A 120 ms debounce and generation guard prevent superseded results from replacing the current preview. One preview is retained.
- Existing library and transcript page bounds remain in place. Search explicitly covers loaded notes or transcript segments.
- Previous/next controls navigate within the loaded notes. Title edits capture the original recording identity before asynchronous saving.
- Detail retains its thoughts editor across refreshes. Back waits for a flush and stays in the reader if text remains unsaved. Save errors expose Retry save.
- Source labels use stored analysisTracks. Microphone is You, system audio is Others, and mixed audio is Unassigned. This does not add diarization or identify individual remote speakers.
- Existing confirmed deletion, retry, transcript copy/paging and recording playback remain available. Recording metadata and recovery details are in a sheet.
- No models, network requests, persistent schemas or dependencies were added.

## Verification

Initial full check: 717 tests passed, 13 skipped, one failure from the old navigation-title expectation. Focused run: 17 passed, one failure from the old navigation-icon expectation. Both expectations were updated for the requested Notetaker destination. The subsequent full check passed. Final verification after adjacent-note navigation and the title-save fix passed: `TEST_RUNNER_LOCALFLOW_UI_CAPTURE_DIR=/tmp/localflow-notetaker-captures make check`, 722 XCTest cases passed, 11 skipped, zero failures. Formatting, foundation validation, Python checks, Go tests/vet and the native build also passed.

Visual inspection found the library readable at compact and wide widths and transcript labels/bubbles legible in both appearances. The serif title was refined after the initial capture. The overview rail appears at the default app window size and becomes an explicit overview popover at narrow widths.

Not verified: signed live pointer/keyboard interaction, VoiceOver, physical audio capture and hardware memory acceptance. Offscreen captures establish layout only.

## Captures

- [Past notes and overview rail](captures/notetaker-list-wide-light.png)
- [Compact Past notes](captures/notetaker-list-compact-light.png)
- [My thoughts](captures/notetaker-thoughts-wide-light.png)
- [Transcript](captures/notetaker-transcript-wide-light.png)
- [Dark transcript](captures/notetaker-transcript-wide-dark.png)
- [Summary unavailable state](captures/notetaker-summary-wide-light.png)

## Spec review and convergence

All eight functional requirements have implementation coverage in T002–T006. The scope clarification removes summary/sharing backend work from this pass. No architecture exceptions or constitution conflicts were found. No extension hooks are configured. Final validation (T007) passed. Convergence checked eight functional requirements, four success criteria, the presentation/state/persistence decisions and all 14 constitution principles. There is no additional unbuilt feature work within the clarified scope. The manual acceptance limits above remain explicit.
