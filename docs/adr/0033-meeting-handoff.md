# 0033: Meeting handoff, server-side processing that survives a disconnect

## Status

Accepted, 2026-10-02. Records an exception to Constitution principle 5 ("the server MUST NOT retain audio or text after the request"), with the owner's explicit consent given on 2026-10-02. The owner chose not to write a specification for this change.

## Context

Server transcription of a meeting streams PCM windows over the remote channel while the Mac waits for each reply. An 80-minute meeting is about 85 MB of AAC on disk, but about 650 MB of PCM crosses the wire (transcription and diarization each send their own copy). On a phone hotspot, stalls of more than 15 s drop the channel, so a long meeting needs several reconnects, and closing the laptop stops the work. The owner wants to upload once, close the laptop, and have the transcript, speaker labels and summary waiting when it reconnects.

## Decision

A `handoff` op on the remote channel (`put`, `start`, `list`, `get`, `delete`), and a headless worker, `flowd-meeting`.

- **Client.** When a finished meeting is eligible, the Mac exports a per-meeting SQLite bundle and uploads it, resumably, in 48,000-byte chunks with the meeting's AAC segments. A meeting is eligible when the server serves final transcripts and summaries, offers `handoff`, the meeting is not set to run on this Mac, and no diarization or analysis run exists yet. The bundle uses the app's own migrations and holds only that meeting's rows plus the vocabulary. On later server-wait retries the Mac polls `list`. When the state is `done`, it downloads the bundle (SHA-256 checked), merges the output tables in one transaction, and deletes the server copy. If the state is `failed`, the server refuses the meeting (no finished audio, the per-user limit), the result does not merge, or the user picks **Run on this Mac**, it deletes the server copy and processes the meeting the usual way.
- **Server.** flowd stores uploads in `<data-dir>/handoff/<user-id>/<meeting>/`, scoped by the token's user. It runs one `flowd-meeting` at a time, with a 3-hour timeout. Limits are 16 meetings and 8 GiB per user and 1 GiB per file. A sweep deletes anything older than 7 days.
- **Worker.** `flowd-meeting` runs the app's `MeetingFinalizer` and `MeetingDiarizer` against the bundle with the server's models. Speaker identification stays on the Mac: voiceprints are never uploaded. The summary is written on the Mac after the merge, once identification has named the speakers, through the usual server summary route. A summary written on the server would say "Speaker 2", and the one-automatic-summary-per-pass rule would keep it.

## Constitution check

- **5 Privacy.** This is the exception. The server keeps meeting audio and transcript text on disk after the request: until the client confirms the merge, and never longer than 7 days. Storage is per user, the transfer stays end-to-end encrypted on the existing channel, and logs carry only state, sizes and durations. Handoff only applies when the owner has opted in to server transcription and summaries for the device.
- **2 Memory.** Uploads and downloads are chunked. The worker uses the same bounded windowing as the client finalizer.
- **4 Offline first.** The Mac keeps its own audio and database. The merge is all-or-nothing, and a failed handoff falls back to the existing paths.
- **8 Server isolation.** flowd owns the worker process. The worker opens no listener.
- **15 Server access.** Every handoff call is scoped by the verified token's user.

## Consequences

- One meeting crosses the wire as AAC once, about a seventh of the PCM it replaces.
- The worker links the client's meeting code, so a schema migration on the client requires redeploying `flowd-meeting`.
- Meetings already partly processed on the Mac do not hand off.
