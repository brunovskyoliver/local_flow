# UI contract: Summary tab

Meeting detail keeps "My thoughts | Transcript | Summary" (the placeholder tab already exists as `NoteDetailTab.summary`; its title becomes "Summary"). Everything below lives in `Features/Intelligence/SummaryTabView.swift` and `SummaryModel.swift`, styled with `NotetakerStyle` and `SottoPalette`.

## States

| State | Header row | Body | Footer |
| --- | --- | --- | --- |
| not eligible | `SUMMARY` label | "No summary yet" + one-line reason ("The transcript is not finished yet." / "Transcription is off for this meeting.") | Read transcript |
| eligible, nothing yet | `SUMMARY` label, **Generate Summary** | "No summary yet" + "Generate a structured summary on your server. Only the transcript, speaker names you confirmed, and your notes are sent." | |
| pending | label + "Queued (2 ahead)" + Cancel | previous accepted analysis if any, else the eligible copy | |
| running | label + stage text ("Analyzing part 3 of 9", "Combining") + progress + Cancel | previous accepted analysis if any | |
| failed / timed out / interrupted | label + red category message + Retry | previous accepted analysis if any | |
| succeeded | label + "Generated 20 Sep, 10:14 · AI-generated" + Regenerate + Copy + overflow (Previous edits, Remove all edits) | analysis | "AI-generated. Check against the transcript before acting on it." |
| stale | as succeeded, plus an amber banner "Summary may be outdated — the transcript, speakers or notes changed after it was generated." with Regenerate | analysis | |

Failure messages (fixed strings per category): server unreachable → "Your server could not be reached."; authentication → "The server rejected the credential."; server/backend unavailable → "The server's language model is not running."; backend busy → "The server is busy with dictation. Try again in a moment."; timeout → "The summary took too long and was stopped."; malformed/unsupported → "The server sent a summary LocalFlow could not read."; source/protected-literal/unsupported → "The summary did not pass LocalFlow's checks and was not saved."; too long → "This meeting is too long to summarize with the current limits."; persistence → the existing storage messages.

## Layout (succeeded)

1. `1 MIN READ` (tracked caps, `monospacedDigit`), computed locally.
2. Executive summary paragraph(s). Edited → "Edited" tag; hover shows "AI version" reveal.
3. Topic sections: title (semibold), summary, bullets.
4. `Action items` — each row: status control (open circle / checkmark / dismissed strikethrough), task text, owner chip, due date, sources. Placed first among the lists because it is the section users act on; FR-037 fixes the order of the four that follow.
5. `Next steps`, `Decisions`, `Open questions`, `Risks / blockers` — each hidden when empty. Items are bullets with a trailing **View source** control (`arrow.up.right.square`) that switches to Transcript and scrolls to the first segment reference with a 2-second highlight, or to My thoughts and the note paragraph.

Owner chip:

| Owner | Rendering | `accessibilityValue` |
| --- | --- | --- |
| participant, confirmed | color chip (speaker color) + name | "confirmed participant" |
| participant, recognized | color chip + name | "recognized participant" |
| participant, meeting-local name | color chip + name | "meeting participant" |
| participant, local user | color chip + "You" | "you" |
| mentioned name | neutral outlined chip, name, small "mentioned" caption; optional "might be <known speaker>?" suggestion with Accept (becomes an owner edit) | "mentioned name" |
| unresolved | neutral outlined chip, dashed border, "Speaker 3" or "Owner unresolved" | "owner unresolved" |

Color is never the only cue: unresolved chips have a dashed border and the text label; mentioned chips have the caption.

Due date: `Due 21 Sep` for explicit states with the original phrase in a tooltip; `Due: unclear ("soon")` for unresolved; nothing for absent.

## Editing

- Summary text, task text, decision text and next-step text: inline `TextField`/`TextEditor` on double-click or the row's Edit menu; Save writes an overlay; Escape cancels.
- Owner: menu listing participants (name + color; a Possible-match or Unknown speaker appears with its "Speaker N" label), "Someone else…" (mentioned name text field), "No owner". Choosing writes an overlay; nothing in spec 010 tables changes.
- Due date: date picker with Clear.
- Status: click cycles open → completed; menu offers Dismiss / Reopen.
- Each edited field shows an "Edited" tag and a "Show AI value" affordance; "Remove edit" deletes the overlay.
- "Previous edits" sheet: orphaned overlays with the item text snapshot, the AI value and the user value, each with Delete.

## Copy

`SummaryModel.copyText()` → plain text, sections in reading order, `- ` bullets, action items as `- [ ] task — Owner (due 21 Sep)` / `- [x] …`, dismissed items omitted, unresolved owner as `(owner unresolved)`, mentioned as the name. No ids, states, confidence words, "AI" headers beyond one trailing line "Generated by LocalFlow from the meeting transcript and notes."

## Transcript and notes navigation

- `TranscriptPager.reveal(segmentID:)` loads the page containing the ordinal if needed and publishes `highlightedSegmentID`; `MeetingDetailView` scrolls with `ScrollViewReader` and clears the highlight after 2 s.
- `MeetingNotesEditor.reveal(paragraph: ordinal, hash:)` selects the paragraph range in the editor if the paragraph at that ordinal still hashes the same; otherwise shows the "This note has changed" notice.

## Settings

Settings › Meetings gains "Summarize meetings automatically" (default on, `AppPreferences.meetingSummariesAutomatic`) with the caption "Uses the server configured under Rewriting. Transcript text, confirmed speaker names and your notes are sent; audio never leaves this Mac." The existing server endpoint, credential and connection test are reused; the connection test additionally reports whether the server offers meeting analysis.

## Accessibility identifiers

`meeting.summary`, `meeting.summary.generate`, `meeting.summary.regenerate`, `meeting.summary.cancel`, `meeting.summary.retry`, `meeting.summary.copy`, `meeting.summary.stale`, `meeting.summary.readingTime`, `meeting.summary.actionItems`, `meeting.summary.item.<kind>.<ordinal>`, `meeting.summary.owner`, `meeting.summary.previousEdits`.
