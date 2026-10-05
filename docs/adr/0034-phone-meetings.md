# 0034: Meetings recorded on the iPhone, with a copy for the Mac

## Status

Accepted, 2026-10-05. Amends ADR 0006 (who owns a meeting) and the retention rule of ADR 0033. The owner asked for the Mac copy in the Feature 020 clarification session on 2026-10-05 (`specs/020-ios-meeting-recording/spec.md`).

## Context

Feature 020 lets the iPhone record meetings. The phone runs no meeting models, so it sends the audio to the owner's LocalFlow server through the meeting handoff (ADR 0033) and gets back the transcript and speaker labels. The owner also wants each phone meeting to show up in the Mac app.

Two existing rules are in the way. ADR 0006 says the client that holds the data is its authority and that the server is not a sync channel. ADR 0033 says the server deletes a handed-off meeting as soon as the client has merged the result. With that rule the server copy is gone before the Mac could see it.

## Decision

- **The recording device owns the meeting.** A meeting recorded on the iPhone lives in the phone's database and files, like a Mac meeting lives on the Mac. `meetings.origin` records where it was made (`local` or `iphone`); the Mac keeps `iphone` when it imports one.
- **The Mac gets a one-time copy through the server.** When the owner asks for a Mac copy, the phone marks its uploads with `copy`. After the phone has merged its result it sends `release`. With the copy marker the server keeps the meeting in `done` and records that it was released; without it, `release` deletes the meeting like `delete`. A Mac imports only entries that another device sent (`mine: false`), that asked for a copy and that were released. It downloads `bundle.sqlite` and every AAC file, inserts the meeting in one transaction, and deletes the server copy. Identification and the summary then run on the Mac as they do for its own meetings.
- **No sync.** After the import the two copies are independent. Edits, renames and deletions on one device do not reach the other. Send to Mac again uploads and processes the meeting a second time.
- **Retention.** The server keeps a released meeting until the Mac imports it, and never longer than 7 days: the existing ADR 0033 sweep on directory age removes it. The phone shows the copy as delivered when the entry disappears within 7 days of release and as expired when it disappears later.
- **Schema.** Shared migration `phone-meetings-v19` adds `meetings.origin` and the segment reason `rotated` (the phone rotates segments every 6 minutes). `flowd-meeting` links these migrations, so the server is redeployed with this feature, as ADR 0033 requires for any client migration.

## Constitution check

- **4 Local first.** Recording, playback and storage on the phone need no server. A failed upload or an expired Mac copy never deletes the phone's meeting.
- **5 Privacy.** This extends the ADR 0033 exception. The server already keeps meeting audio and text until the sending device has merged its result; with a Mac copy it keeps them until the Mac imports them, still at most 7 days, still per user. Sending is opt-in per device, and the consent line on the phone says the audio and text are stored on the server for up to 7 days. Logs carry state, sizes and durations only.
- **7 Persistence.** The schema change is an explicit migration that rebuilds `meeting_segments` with its rows and indexes.
- **9 Recoverability.** Uploads are resumable and hash-checked; the Mac import is all-or-nothing.
- **15 Server access.** `mine` is derived from the device in the verified token, never from the request. A Mac sees only meetings of the same user.

## Consequences

- The ADR 0006 statement "server archival is backup, not synchronization" still holds: the copy is a single transfer, not a sync.
- Older Macs ignore phone entries: their handoff step only looks up their own meeting IDs.
- A released meeting with a copy counts against the per-user limits (16 meetings, 8 GiB) until the Mac imports it or the sweep removes it.
- The phone and the Mac can hold different versions of the same meeting after either side edits it.

## Alternatives considered

- **Two-way sync between phone and Mac.** Conflict handling and a sync protocol for one person's meetings; out of scope under principle 14.
- **The phone keeps its meetings to itself.** Simplest, but the owner wants all meetings in the Mac app.
- **Upload from the phone to the Mac directly.** Both devices would have to be online at the same time, and the Mac would need a listener.
