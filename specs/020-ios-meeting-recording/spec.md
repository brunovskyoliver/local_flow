# Feature Specification: Meeting Recording on iPhone, Processed by the Server

**Feature Branch**: `t3code/phone-audio-relay-feasibility` (no branch-creation hook; started from main at `cb7e32b`)

**Created**: 2026-10-05

**Status**: Draft

**Input**: User description: "I would like to build another feature into the iOS application which would be meeting recording. I don't care about the dictation that much for now and the meeting Recording is gonna be held via Mac Mini server so we do not need to host anything locally. It's just gonna be recorded and we can maybe some implement some stuff so that when it's reachable during the meeting it can also start to do the transcribing ahead of time so it can transcribe during the meeting in some chunks and after the meeting it can upload to the server and it it's gonna process it and then it's gonna sync up."

## Summary

The owner records meetings on their iPhone. The phone records the meeting and keeps the audio itself. It runs no speech models for meetings. All transcription, speaker labelling and summarising runs on the owner's LocalFlow server, the Mac mini.

If the server is reachable while the meeting is still running, the phone sends finished stretches of audio as it goes, and the server starts transcribing them. When the meeting ends, only what is left goes up, so the result comes back sooner. If the server is not reachable, the phone just records. It uploads after the meeting, or later, whenever the server is back. Either way the finished meeting (transcript, speaker labels, summary) comes back to the phone and is stored there. A copy also goes to the owner's Mac the next time it connects.

Today the iPhone app has no connection to the server at all: sign-in, approval and the encrypted channel exist only in the Mac app. This feature brings them to the phone, for meetings only. Dictation on the phone stays as it is (local, Feature 016/017).

## Clarifications

### Session 2026-10-05

- Q: How should transcription during the meeting work? → A: The phone uploads finished audio segments into the server's meeting handoff while recording; the server transcribes them as they arrive and finishes the rest after stop. The server's handoff is extended to accept audio while a meeting is still running. The phone holds no transcription logic.
- Q: What does the owner see on the phone during the meeting? → A: Recording status plus the server's progress ("Transcribed up to 34:00"); the transcript text appears after stop.
- Q: How does the iPhone sign in to the server? → A: Google only, reusing the Mac's iOS OAuth client if Google accepts it for the phone's bundle ID; otherwise the owner creates one more client.
- Q: May uploads use cellular data? → A: Yes, any network.
- Q: Do phone meetings also appear in the Mac app? → A: Yes. Each finished phone meeting is made available for the owner's Mac to pull, as a one-time copy (audio, transcript, speakers, summary). This needs a new ADR amending ADR 0006 and ADR 0033 retention.

## Boundary with earlier features

| Capability | Before | After Feature 020 |
| --- | --- | --- |
| iPhone dictation | Local Parakeet (016, 017) | Unchanged |
| iPhone to server connection | None | Sign-in, admin approval, pinned encrypted channel, used for meetings only |
| Meeting recording | Mac only | Mac, and iPhone (one microphone track) |
| Meeting processing on the server | Mac uploads a finished meeting (handoff, ADR 0033) | Same path for the phone, plus uploading finished audio stretches while the meeting is still running |
| Meeting results | Stored on the Mac | Phone meetings stored on the phone, and copied once to the owner's Mac; Mac meetings stay on the Mac |

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Record a meeting on my iPhone (Priority: P1)

I'm in a meeting with only my phone. I open LocalFlow, tap Record meeting, and put the phone on the table, locked. The recording keeps going in the background, a Live Activity shows the elapsed time and a Stop button, and the system microphone indicator is on. When the meeting ends I tap Stop. The meeting appears in my Meetings list with its length and date, and I can play it back. Nothing has to be reachable for this to work.

**Why this priority**: Recording is the base for everything else. A meeting recorded and kept safely on the phone already has value, even before the server touches it.

**Independent Test**: In airplane mode, record a 20-minute meeting with the phone locked for most of it, stop it from the Live Activity, and check the meeting is listed with the right length and plays back from start to end.

**Acceptance Scenarios**:

1. **Given** microphone permission is granted, **When** I tap Record meeting, **Then** recording starts within 1 second, the Live Activity shows the elapsed time and Stop, and the meeting screen shows the elapsed time and an input level.
2. **Given** a meeting is recording, **When** I lock the phone or switch apps, **Then** recording continues and the Live Activity stays up.
3. **Given** a meeting is recording, **When** I tap Stop in the app or in the Live Activity, **Then** the recording ends and the meeting is listed with its date, title (date and time by default, editable) and duration.
4. **Given** a phone call or another app takes the microphone, **When** the interruption ends, **Then** recording resumes in the same meeting, and the gap is marked rather than silently lost.
5. **Given** the app is killed or the phone runs out of battery while recording, **When** I open LocalFlow again, **Then** the meeting is recovered with all audio up to the last few seconds and marked as recovered.
6. **Given** a phone dictation session is running, **When** I start a meeting, **Then** the dictation session ends first (one microphone owner at a time), and I'm told so.

---

### User Story 2 - The server processes the meeting and the result comes back (Priority: P1)

After I stop, the phone uploads the meeting to my Mac mini over the encrypted channel. The server transcribes it, labels the speakers and writes a summary. The finished meeting appears on my phone: the transcript with speaker labels and timestamps, and the summary. If the server is unreachable when I stop, the meeting waits as "Waiting for server" and goes up by itself when the server is back, without me doing anything. The server copy is deleted once the phone has the result.

**Why this priority**: This is the point of the feature: meeting transcripts and notes without running models on the phone.

**Independent Test**: With the server reachable, record a 10-minute two-person meeting, stop it, leave the app, and check the transcript, speaker labels and summary appear on the phone and the server holds no copy afterwards. Repeat with the server unreachable at stop, then bring it back and check the meeting finishes on its own.

**Acceptance Scenarios**:

1. **Given** the device is approved and the server is reachable, **When** I stop a meeting, **Then** the meeting shows its upload progress, then "Processing" with the server's progress, then the finished transcript and summary.
2. **Given** the server is unreachable when I stop, **When** the server becomes reachable later while LocalFlow is open or running in the background, **Then** the upload starts on its own and resumes where it stopped, without resending what the server already has.
3. **Given** an upload is interrupted halfway (network change, app suspended), **When** it resumes, **Then** it continues from what the server confirmed and the server's copy matches the phone's audio exactly.
4. **Given** the server reports the meeting failed, **When** I look at it, **Then** it shows the failure with Retry, and my recording is untouched.
5. **Given** the finished result has come back, **When** the phone has stored it, **Then** the phone tells the server to delete its copy.
6. **Given** the device is not signed in, pending, rejected or revoked, **When** I stop a meeting, **Then** the meeting stays on the phone, says why it isn't processed, and links to the server settings.

---

### User Story 3 - Transcription starts while the meeting is still running (Priority: P2)

During a long meeting the server is reachable. Every few minutes the phone sends the latest finished stretch of audio, and the server transcribes it. The meeting screen shows how far the server has got ("Transcribed up to 34:00"). When I stop, only the last stretch goes up, and the transcript is ready a short time after the meeting ends instead of a time proportional to its length. If the connection drops mid-meeting, recording is unaffected; the phone catches up when it can.

**Why this priority**: It makes results arrive faster, but recording and the after-meeting path (Stories 1 and 2) already deliver the full value without it.

**Independent Test**: Record a 30-minute meeting with the server reachable. Check that during the meeting the server's progress advances, and that the finished transcript arrives within 3 minutes of stopping. Turn on airplane mode for 5 minutes mid-meeting and check the recording has no gap and the server catches up after.

**Acceptance Scenarios**:

1. **Given** the server is reachable during a meeting, **When** a stretch of audio is finished, **Then** the phone sends it within a minute, and the meeting screen shows the server's transcription progress.
2. **Given** the connection drops mid-meeting, **When** it comes back, **Then** the phone sends the stretches it missed, in order, and the recording itself never paused.
3. **Given** the server is busy with someone's dictation, **When** a stretch arrives, **Then** the server finishes the dictation first; the meeting stretch waits.
4. **Given** I stop a meeting whose earlier stretches are already transcribed, **When** the server finishes, **Then** the final transcript matches what a whole-meeting upload would have produced, with no gaps or duplicated text at stretch boundaries.

---

### User Story 4 - Sign this iPhone in to my server (Priority: P1)

In Settings › Server, I enter (or pick) my Mac mini's address, see its fingerprint, sign in, and wait for approval. Once approved, the section says "Approved" and a switch "Process meetings on this server" is on, with a line that says meeting audio is sent to and stored on the server until the result comes back (at most 7 days). I can sign out, which removes the device's credentials.

**Why this priority**: Stories 2 and 3 cannot run without it. It is listed fourth because it is setup, not the thing the owner wants to do.

**Independent Test**: On a fresh install, sign in, approve the device on the server, check the state reads Approved, record and process a meeting, then revoke the device on the server and check the next upload stops with a "revoked" message and no audio is sent.

**Acceptance Scenarios**:

1. **Given** a fresh install, **When** I enter the server address, **Then** the phone fetches the server's identity, shows its fingerprint and asks me to confirm it before signing in.
2. **Given** I signed in, **When** the administrator hasn't approved the device yet, **Then** the section says "Waiting for approval" and no meeting audio is sent.
3. **Given** the device is approved and the switch is on, **When** a meeting is recorded, **Then** it is processed on the server; with the switch off, meetings stay on the phone unprocessed.
4. **Given** the administrator revokes the device, **When** the phone next talks to the server, **Then** it shows "Revoked", stops sending, and keeps every recording.
5. **Given** I sign out, **When** I confirm, **Then** the device credentials are deleted from the phone and no further requests are made.

---

### User Story 5 - Read and manage meetings on the phone (Priority: P2)

The Meetings tab lists my phone meetings, newest first, each with title, date, duration and state (Recording, Waiting for server, Uploading, Processing, Ready, Failed). A ready meeting shows the summary at the top and the transcript under it, with speaker labels and timestamps; tapping a line plays the audio from there. I can rename the meeting and the speakers, copy or share the transcript and summary as text, and delete a meeting (audio, transcript and any server copy).

**Why this priority**: Without a way to read the result the feature is incomplete, but a plain transcript view covers most of the value; search, renaming and sharing are refinements.

**Independent Test**: With three processed meetings, open one, read the summary, tap a transcript line and hear the audio from that point, rename "Speaker 1", share the transcript, then delete a meeting and check its files and server copy are gone.

**Acceptance Scenarios**:

1. **Given** processed meetings exist, **When** I open Meetings, **Then** each row shows title, date, duration and state.
2. **Given** a ready meeting, **When** I tap a transcript line, **Then** playback starts at that line's time.
3. **Given** a ready meeting, **When** I rename "Speaker 1" to "Anna", **Then** every line by that speaker shows "Anna".
4. **Given** any meeting, **When** I delete it and confirm, **Then** its audio and text are removed from the phone, and the server copy is deleted if one exists.

---

### User Story 6 - My phone meetings also show up on my Mac (Priority: P3)

I recorded a meeting on my phone. Later I open LocalFlow on my Mac, signed in to the same server as the same user. The phone meeting appears in the Mac's meeting list, marked "From iPhone", with its audio, transcript, speakers and summary, and I can work with it like any Mac meeting. It is a copy: renaming it on one device doesn't change the other.

**Why this priority**: The Mac is where the owner does longer work with meetings, but the phone already delivers the meeting without it.

**Independent Test**: Record and process a meeting on the phone. Open the Mac app signed in as the same user, wait for it to connect, and check the meeting appears with audio that plays and the same transcript and summary. Check the server copy is gone afterwards. Repeat with the Mac offline for 8 days and check the server copy expired and the phone still has the meeting.

**Acceptance Scenarios**:

1. **Given** a phone meeting finished processing and "Copy meetings to my Mac" is on, **When** my Mac connects to the server as the same user, **Then** the meeting is imported into the Mac with its audio, transcript and speaker labels, marked as coming from the iPhone, and the Mac then names speakers it recognises and writes the summary as it does for its own meetings.
2. **Given** the Mac imported the meeting and the phone has the result, **When** both are confirmed, **Then** the server deletes its copy.
3. **Given** the Mac doesn't connect within 7 days, **When** retention expires, **Then** the server deletes its copy, the phone keeps the meeting, and the phone shows that the Mac copy was not delivered, with "Send to Mac again".
4. **Given** a meeting was already imported, **When** the Mac connects again, **Then** it is not imported a second time.
5. **Given** "Copy meetings to my Mac" is off, **When** a meeting finishes, **Then** the server deletes its copy as soon as the phone has the result.

### Edge Cases

- Storage runs low while recording: warn at 1 GB free, stop and save the meeting at 200 MB free; never lose what was recorded.
- A meeting longer than the server can take in one job (3-hour processing timeout, 1 GiB per file): the phone splits audio into segments so no file nears the limit; recordings longer than 4 hours stop with a warning.
- The server's per-user limits are full (16 meetings, 8 GiB): the meeting waits and says why.
- The server's software is older and doesn't offer the needed operations: the phone says the server needs an update and keeps the meeting.
- The pinned server identity changes: the phone refuses to send anything and asks me to re-confirm the fingerprint.
- Two meetings waiting at once: they upload one at a time, oldest first.
- The result fails to merge or fails its checksum: nothing partial is stored; the phone retries the download, then offers Retry.
- The server's 7-day retention expires before the phone fetches the result: the phone uploads the meeting again.
- Bluetooth headset connects or disconnects mid-meeting: recording continues on the new route without stopping.
- The owner has no Mac signed in as the same user: the copy waits on the server and expires after 7 days like any other.
- The owner deletes a phone meeting before the Mac imported it: the server copy is deleted and the Mac never sees it.
- I start a meeting while a previous meeting is still uploading: recording takes priority; uploads continue in the background as bandwidth allows.

## Requirements *(mandatory)*

### Functional Requirements

**Recording**

- **FR-001**: Users MUST be able to start and stop a meeting recording from the app and stop it from the Live Activity.
- **FR-002**: Recording MUST continue with the screen locked or the app in the background, with a Live Activity visible for the whole recording (ADR 0030 rule: visible, owner-started).
- **FR-003**: Audio MUST be written to disk in compressed segments as it is recorded, with bounded memory, so that at most the last few seconds are lost on a crash.
- **FR-004**: After a crash, kill or power loss, the app MUST recover the interrupted meeting on next launch, with its audio up to the last flushed segment.
- **FR-005**: Interruptions (calls, other apps taking the microphone, route changes) MUST NOT end the meeting; recording resumes when the interruption ends, and gaps are recorded.
- **FR-006**: The phone MUST use one microphone owner at a time: starting a meeting ends a running dictation session.
- **FR-007**: The phone MUST NOT run any speech or language model for meetings.

**Server connection**

- **FR-010**: The phone MUST enroll with the owner's LocalFlow server the same way the Mac does: fetch and pin the server identity, sign in, get administrator approval, and hold a device key that cannot leave the phone.
- **FR-011**: All meeting traffic MUST use the existing encrypted channel; nothing is sent before approval, or with the processing switch off.
- **FR-012**: The phone MUST show the device's server state (not signed in, waiting for approval, approved, rejected, revoked, unreachable) and let the owner sign out.
- **FR-013**: The consent line shown before the switch is turned on MUST say that meeting audio and text are sent to the server and stored there until the phone has the result, at most 7 days.

**Upload and processing**

- **FR-020**: After a meeting stops, the phone MUST upload it for processing when the device is approved, the switch is on and the server is reachable, and otherwise queue it.
- **FR-021**: Uploads MUST be resumable: an interrupted upload continues from what the server confirmed, and the server's copy is verified against the phone's.
- **FR-022**: Queued meetings MUST upload on their own when the server becomes reachable, while the app is in the foreground or running in the background, one at a time, oldest first.
- **FR-023**: While a meeting is recording and the server is reachable, the phone MUST send each finished audio stretch to the server, and the server MUST start transcribing it before the meeting ends.
- **FR-024**: Sending during the meeting MUST NOT block or slow down recording; a failed send is retried later and never drops audio.
- **FR-025**: The server MUST process phone meetings with the same transcription and speaker-labelling it uses for Mac meetings, and the final transcript MUST be the same whether stretches were sent during the meeting or all at once.
- **FR-026**: A summary MUST be produced for each processed meeting through the server's existing summary path.
- **FR-027**: The phone MUST show upload and server processing progress per meeting.
- **FR-028**: Meeting work from the phone MUST queue behind dictation and rewriting on the server and respect the server's per-user limits; when the server refuses for a limit, the meeting waits and says why.

**Result and storage**

- **FR-030**: The result (transcript with timestamps and speaker labels, summary) MUST be stored on the phone in one all-or-nothing step, after its checksum is verified.
- **FR-031**: After the result is stored on the phone, the server's copy MUST be deleted, unless it is waiting for the Mac copy (FR-040); either way it is deleted within 7 days.
- **FR-032**: Users MUST be able to list, open, play back from a transcript line, rename meetings and speakers, copy or share the transcript and summary, and delete meetings.
- **FR-033**: Deleting a meeting MUST delete its audio, its text and any server copy.
- **FR-034**: A failed processing run MUST leave the recording intact and offer Retry.

**Copy to the Mac**

- **FR-040**: With "Copy meetings to my Mac" on (default on), a finished phone meeting MUST stay on the server, for the same user only, until the owner's Mac has imported it, at most 7 days.
- **FR-041**: The Mac app MUST import such meetings automatically when connected as the same user: audio, transcript and speaker labels, marked as from the iPhone, exactly once per meeting; it then runs its usual speaker identification and summary.
- **FR-042**: The import MUST be all-or-nothing and checksum-verified; a failed import leaves the Mac unchanged and is retried.
- **FR-043**: After the Mac has imported a meeting and the phone has its result, the server MUST delete its copy.
- **FR-044**: The imported meeting is an independent copy; later edits on either device are not synced.
- **FR-045**: The phone MUST show per meeting whether the Mac copy was delivered, and offer "Send to Mac again" when it expired, which uploads and processes the meeting on the server again.

### Key Entities

- **Phone meeting**: one recording on the phone. Title, start time, duration, state (recording, recovered, waiting, uploading, processing, ready, failed), the reason it is waiting or failed.
- **Audio segment**: one compressed piece of the meeting's audio on disk, in order; finished segments are immutable and are the unit sent to the server.
- **Server enrollment**: the server address, pinned identity, device key, sign-in state and approval state for this phone.
- **Upload state**: per meeting, which segments the server has confirmed, the server's processing state and progress.
- **Transcript**: timed lines with a speaker label, produced by the server, stored on the phone.
- **Speaker**: a label from the server ("Speaker 1"), renamable on the phone.
- **Mac copy state**: per phone meeting, whether it is waiting on the server for the Mac, delivered, or expired.
- **Summary**: structured notes for the meeting, produced by the server's summary path.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: A 60-minute meeting recorded with the phone locked has no gaps other than marked interruptions, and plays back for its full length.
- **SC-002**: After a forced kill mid-recording, at most the last 10 seconds of audio are lost.
- **SC-003**: With the server reachable during the whole meeting, the finished transcript of a 30-minute meeting is on the phone within 3 minutes of stopping (target; measured on the Mac mini, not assumed).
- **SC-004**: With the server unreachable at stop, the meeting finishes on its own within 5 minutes of the server becoming reachable while the app runs, with no action from the owner.
- **SC-005**: An interrupted upload never resends more than one segment that the server already confirmed.
- **SC-006**: Recording adds no more than 100 MB of memory above the app's idle use (constitution principle 2), measured on device.
- **SC-007**: After a meeting's result is stored, the server holds no copy of it.
- **SC-009**: A phone meeting processed while the Mac is offline appears on the Mac within 5 minutes of the Mac connecting, with audio and transcript identical to the phone's; the Mac writes its own summary after its speaker identification runs, as for its own meetings.
- **SC-008**: No meeting audio or text leaves the phone before the device is approved and the switch is on.

## Assumptions

- Sign-in on the phone is Google only, through the existing iOS OAuth client where possible.
- Uploads use any network, cellular included; an hour of meeting audio is roughly 30–40 MB.
- The phone reaches the Mac mini the same way the Mac does: on the tailnet, at the `tailscale serve` address (ADR 0028). Tailscale must be on for uploads; recording never needs it.
- Phone meetings record one microphone track; there is no system-audio track on iOS.
- Speaker identification across meetings (voiceprints) stays on the Mac and is out of scope; the phone shows anonymous labels the owner can rename.
- The phone owns its meetings (ADR 0006). The Mac receives a one-time copy through the server; there is no ongoing two-way sync. This needs a new ADR amending ADR 0006 and the ADR 0033 retention rule.
- Dictation on the phone is unchanged and stays local. Remote dictation on the phone is out of scope.
- The server-side processing reuses the meeting handoff path (ADR 0033), extended so it can take audio while a meeting is still running.
- Free-team or paid-team signing does not change; new capabilities (for example Sign in with Apple on the phone's App ID) are registered only with the owner's go-ahead.

## LocalFlow resource and failure acceptance

- **Bounds**: audio is encoded and flushed in segments; no whole-meeting audio in memory on phone or server (principle 6). Upload chunks are fixed-size. At most one meeting uploads at a time; the queue of waiting meetings is bounded by storage, and the server's per-user limits apply (16 meetings, 8 GiB).
- **Offline**: recording, playback and listing never need the server. Unprocessed meetings wait indefinitely on the phone.
- **Permission failures**: without microphone permission, Record meeting explains how to grant it and records nothing. Without approval, nothing is sent.
- **Data preservation**: server or network failure never deletes or alters a recording; results merge all-or-nothing; the server copy is deleted only after the phone has stored the result.
- **Privacy**: meeting audio is stored on the server only under the ADR 0033 exception (extended by this feature's ADR to cover the Mac copy), per user, at most 7 days; logs on both sides carry no audio, transcript text or credentials.
- **Resource acceptance**: recording memory overhead and battery use over a 60-minute locked recording are measured on the owner's iPhone and reported, not assumed.
