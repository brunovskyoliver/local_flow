# Contract: phone surfaces (Feature 020)

## Tabs

`Dictate`, `Meetings` (new, second), `History`, `Dictionary`, `Settings`.

## Meetings tab

- Record meeting button on top; disabled with a reason while a dictation is transcribing.
- List rows: title, date, duration, state label: Recording, Waiting for server (with reason), Uploading n%, Processing n%, Ready, Failed. Mac copy line when relevant: Waiting for Mac, Sent to Mac, Not delivered.
- Recording screen: elapsed time, input level, input name, "Transcribed up to mm:ss" when known, Stop.
- Meeting detail: summary (headline, topics, action items), transcript lines (speaker, time, text), tap a line to play from there, rename meeting, rename speaker, Copy, Share (plain text), Delete (confirm), Retry on failure, Send to Mac again when expired.

## Settings › Server (new section)

- Server address field, Check identity, fingerprint display and Confirm.
- Sign in with Google (when `LocalFlowGoogleClientID` is set), state line (Not signed in, Waiting for approval, Approved, Rejected, Revoked, Unreachable), Sign out.
- Switch "Process meetings on this server" with the consent line (FR-013); switch "Copy meetings to my Mac" (default on).

## Live Activity (meeting)

Lock Screen and Dynamic Island: elapsed time, "Transcribed up to mm:ss" when known, Stop (`StopMeetingIntent`). Requested before recording starts; ended on stop.

## URL

`localflow://meetings` opens the Meetings tab.
