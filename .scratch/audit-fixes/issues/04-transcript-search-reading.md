# 04 Transcript search and long-text reading

Audit: `~/agent-runs/2026-10-22-localflow-audit/` — audit.md items 4 and 7, ui-audit.md UI-02 and UI-03.

## Status: done (code and unit tests); manual UI checks still open

## What changed

### UI-02 / item 4 (macOS meeting transcript)

- `packages/LocalFlowCore/Sources/LocalFlowCore/Transcripts/TranscriptSearch.swift` (new):
  `TranscriptTextQuery` walks the store's keyset pages (`labeledPage`, 200 rows) one at a
  time.
  - `search` returns ordinal and id for each matching row. It uses the FR-020 rules:
    normalized text or the speaker display text, `localizedStandardContains`, so case and
    diacritics are ignored as before. Hits are capped by the caller, and the result
    reports when the cap cut it short.
  - `export` streams copy text to a sink. `fullText` builds the pasteboard string and
    throws `tooLong` past 20 MiB; a meeting holds at most 16 MiB of text.
  - `TranscriptTextFormatter` emits the existing copy format (plain lines, or `Label:`
    blocks), row by row, so selection copy and full copy produce identical output.
  - There is no FTS table and no schema change. SQL `LIKE` cannot match the existing
    diacritic-insensitive behaviour, so search scans at most 101 indexed page reads per
    meeting (20,000-row store cap).
- `TranscriptPager`:
  - New `search(_:)`, `searchResult`, `currentMatchIndex`, `isSearching` and
    `showMatch(forward:)`. A hit outside the resident pages loads its page, which keeps
    the two-page, 400-row limit, and highlights the row.
  - New `fullTranscriptText()` and `exportTranscript(to:)`. Export writes 64 KiB chunks
    and removes the partial file if it fails.
  - `copyText()` became `selectionText()`, which returns the selection only (empty when
    nothing is selected).
- `MeetingDetailView` (transcript header and list only):
  - The search field shows a whole-transcript count ("Searching…", "No matches",
    "41 matches", "3 of 41", "1,000+") and previous/next buttons. A search runs 250 ms
    after typing stops and runs again when finality, labels or the row count change.
  - The copy button is now a menu with Copy Selected Segments (disabled with no
    selection), Copy Full Transcript and Export Transcript….
  - The paging sentinels follow the resident pages, not the filtered rows. A search
    with no resident matches therefore keeps paging. Its empty state now says the
    matches are elsewhere and points to the arrows.

### UI-03 / item 7 (iPhone)

- `apps/ios/App/Features/Reader/DictationReaderView.swift` (new):
  - `DictationReaderView` has Copy and Share in the toolbar.
  - `SelectableText` is a read-only `UITextView`. It scrolls itself, supports range
    selection, uses Figtree scaled through `UIFontMetrics`, and sets
    `adjustsFontForContentSizeCategory`.
- `DictateView`:
  - The page scrolls (GeometryReader plus minHeight, so a short screen still centres
    the capsule).
  - The result text no longer truncates.
  - Copy, Open and Share sit together and wrap to a column at large sizes. Open shows
    the reader in a sheet.
- `HistoryView`: tapping the four-line preview, or the new Open button, pushes the
  reader with the full saved text and a caption (source · delivery · app · review).
  Copy and Share in the row still work as before.
- `HistoryViewModel.item(id:)` serves the detail lookup.
- `SessionView`: the messages scroll, and End session/Close is pinned with
  `safeAreaInset(edge: .bottom)`.

## Verification

- macOS: `xcodebuild … -scheme LocalFlow … test -only-testing:LocalFlowTests/TranscriptPagerTests -only-testing:LocalFlowTests/TranscriptPagerPagingTests -only-testing:LocalFlowTests/TranscriptPagerLabelTests`.
  All 24 passed. New tests:
  - `testSearchFindsAndRevealsAMatchBeyondTheResidentPages`: a hit at ordinal 750
    while 0–399 are resident; no resident rows match, the search still finds it, and
    the jump keeps residency ≤ 400.
  - `testSearchHitsAreCappedAndNavigationWraps`
  - `testFullCopyAndExportIncludeRowsBeyondTheResidentPages`: 1,000 rows; line 750 and
    999 are present; the exported file is identical; residency stays 400.
  - `testFullCopyIsBounded`
  - Store-backed search over speaker names, run against a real GRDB `TranscriptStore`.
  - The existing label/copy tests now go through `fullTranscriptText()` and
    `selectionText()`.
- iOS: `xcodebuild … -scheme LocalFlowPhone -destination "platform=iOS Simulator,id=<iPhone 18 Pro>" … test -only-testing:LocalFlowPhoneTests/DictationReaderTests -only-testing:LocalFlowPhoneTests/HistoryViewModelTests`.
  All 8 passed. The new tests use about 6,000 characters of mixed English and Slovak
  text and check:
  - the reader content is not truncated;
  - the text view is read-only, selectable and scrollable, and follows Dynamic Type;
  - at accessibility XXXL the font is over 40 pt and the text is more than five
    screens tall, the end can be reached and a sub-range can be selected;
  - the History caption;
  - `item(id:)` returns the complete text and returns nil after delete.
- `swift build --package-path packages/LocalFlowCore` succeeded.
  `swift format lint --strict` is clean on all changed files.
- No snapshot-test pattern exists in the repo, so none was added.

## Left open

- Nothing has been checked by hand in a running app:
  - macOS: Find next/previous scrolling and the copy menu's appearance in the header.
  - iPhone: largest Dynamic Type sizes, VoiceOver order, the reader's toolbar inside the
    tab and sheet contexts, and History row taps not interfering with Copy/Share.
- Search scans every page of the meeting in Swift (at most 101 reads). It is debounced
  and cancellable but not measured on a 20,000-row meeting. If that turns out slow, an
  FTS5 table needs its own spec, because the constitution allows only the schema the
  current feature needs.
- Export runs its file writes on the main actor in 64 KiB chunks. This is fine for the
  16 MiB cap; a very slow disk could stutter the UI.
- Live (recording) meetings still filter only the in-memory live ring. That is
  unchanged, because the live model is bounded and not in the store.
- Full `make check` is left to the merge step.
