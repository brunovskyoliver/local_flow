# Contract: speaker UI

This extends the Feature 006 meeting detail Transcript tab. Nothing is replaced. With no accepted result, or a stale one (the transcript pass changed), everything below falls back to the Feature 006 behavior: source labels, the existing header and plain copy.

## Transcript header

The header reads `N SPEAKERS • mm:ss` (or `h:mm:ss`), where N is the number of display roots (FR-018) and Unknown and Overlapping are excluded. With no accepted result, the existing duration and transcript badge stay.

The header also has a **Speakers** menu (`meeting.speakers.menu`) with these items:

- **Assign speakers…**, enabled when an accepted result exists.
- **In-room meeting** (checkmark), which reruns diarization (FR-009).
- **Label speakers** or **Re-run speaker labels**, and **Retry** after a failure.
- **Cancel speaker labeling** while pending or running.

## Status line

| State | Text | Action |
| --- | --- | --- |
| not_requested | "Speakers aren't labeled yet." | Label speakers |
| pending | "Waiting to label speakers…" | Cancel |
| running | "Labeling speakers… 40%" | Cancel |
| failed | Category message, for example "Speaker labeling model isn't installed. Install it in Settings → Models." or "Speaker labeling needs macOS 15 or later." | Retry, when retryable |
| interrupted | "Speaker labeling was interrupted." | Retry |
| succeeded, rerun in progress | The accepted labels stay visible, with "Updating speaker labels…" | Cancel |

## Rows

- A label is shown above each contiguous group with the same display root, or the same Unknown/Overlapping kind. It shows a color dot and text (FR-016, FR-017).
- The label texts are "You", "Name (You)", "Local N", "Speaker N", "Name", "Unknown" and "Overlapping".
- The accessibility label always names the speaker as text.
- The row context menu gains **Change speaker ▸** with every display root, Unknown and New speaker (FR-026). Picking one writes a manual correction and relabels that row only. Manually changed rows show a small "Edited" marker.
- Search also matches display names (FR-020).
- Copy produces `Label:\n<text>` blocks. Consecutive rows with the same label are joined with newlines, and blocks are separated by a blank line. Copy never includes confidence, keys or ids (US7).

## Assign speakers sheet (`meeting.speakers.assign`)

- The title is "Assign speakers", with the subtitle "Name each voice and we'll relabel the whole transcript."
- The sheet has one section per display root, in color order. The local speaker section comes first and has a tinted background and a "This Mac's microphone" caption.
- Each section contains the color dot, the anonymous label in caps (SPEAKER 1, YOU, LOCAL 2), up to 3 quotes in quotation marks, and a name field. The field is prefilled with the current name, and the placeholder is the anonymous label.
- Each section has a **Merge into ▸** menu (FR-025). Merged speakers appear under their target as "Includes Speaker 4", with **Undo merge**.
- When two sections have the same name, the sheet shows the note "Same name as Speaker 3" and a **Merge** button.
- "Couldn't carry over" entries (R7) are listed at the top as review notices, and each can be dismissed.
- Name fields offer up to 8 plain-text suggestions in a completion list. Picking one fills in the text only (FR-028).
- Validation: names are trimmed, and whitespace-only counts as empty (the speaker keeps its anonymous label). Over 80 characters shows an inline error and disables **Save names** (FR-021).
- **Cancel**, Escape and closing the sheet discard every edit. **Save names** commits every name in one transaction, closes the sheet and relabels immediately (FR-022, SC-003). Merge and unmerge apply immediately, because they are their own undoable actions.
- Keyboard: Tab moves through the fields and buttons in order, Return activates Save names, and Escape cancels. Every control has a label (US3 scenario 7).

## Settings

In the Meetings section:

- **Label speakers automatically after transcription**, a toggle that is on by default (`meetingDiarizationEnabled`).
- **Speaker labeling model**: installed or verified state, with Install and Verify through the existing model row. Neither action loads the model.

## Accessibility identifiers

`meeting.speakers.menu`, `meeting.speakers.status`, `meeting.speakers.assign`, `meeting.speakers.save`, `meeting.speakers.cancel`, `meeting.speakers.name.<ordinal>`, `meeting.transcript.row.changeSpeaker`.
