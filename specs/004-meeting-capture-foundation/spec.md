# Feature Specification: Feature 004 — Meeting Capture Foundation

**Feature Branch**: `main` (existing branch; no branch-creation hook configured)

**Created**: 2026-09-18

**Status**: Clarified — ready for `$speckit-plan`

**Input**: Prove that LocalFlow can reliably record a long meeting from the microphone and from macOS system audio as two separate, incrementally written tracks; keep memory bounded regardless of duration; let the user pause, resume, write notes and stop; persist a durable meeting record; detect and recover interrupted meetings after a crash, force quit, reboot or storage failure; and let the user review, play back and delete recorded meetings. No transcription, diarization, identification, summaries, search, backup or cloud work is included. The meeting produced here is the durable source for Features 005–008.

## Boundary with Features 001–003 and later features

Features 001–003 own push-to-talk dictation, local recognition, deterministic assembly and normalization, vocabulary learning and optional server rewriting. Feature 004 adds a second, independent capability: long-form meeting capture. The two do not share a recording session. Dictation continues to work unchanged when no meeting is active (AC-016); whether dictation may run while a meeting is active is decided in planning under the constitution's model-exclusivity and memory rules, with the default that dictation is unavailable during an active meeting unless measurements show both fit the budget.

Feature 004 produces a Meeting with durable microphone audio, durable system audio, manual notes and capture/recovery metadata. Feature 005 consumes the tracks for transcription, 006 for diarization, 007 for speaker identity, 008 for summaries and tasks. Capture storage therefore preserves raw evidence and does not bake in transcription-specific assumptions such as pre-mixed streams, ASR-specific sample formats or transcript placeholders.

## Clarifications

### Session 2026-09-18

- Q: When exactly one audio source fails mid-meeting, should the meeting keep recording on the remaining source, or stop? → A: Continue on the remaining source in both cases with a prominent warning; the failed track keeps its reason and timestamp (agenda items 1–2).
- Q: When storage fails during recording, should the meeting end there or be suspended for a later resume? → A: End the meeting: finalize what was written, mark it interrupted with the storage-failure reason; no resume-after-failure in this feature.
- Q: When the Mac sleeps during an active meeting, what happens on wake? → A: The meeting stays paused with a system-initiated pause interval (reason "system sleep"); the user explicitly resumes or stops; capture never resumes on its own (agenda item 14).
- Q: One file per source for the whole meeting, or a new file segment on every resume? → A: A track is an ordered list of segments; each resume opens a new segment file and each pause or stop finalizes the current one; pause intervals are also persisted as metadata (agenda items 4 and 6).
- Q: Are the remaining proposed defaults (agenda items 3, 5, 7–13, 15) accepted as final? → A: Yes, all accepted as listed: 60-minute acceptance run; codec chosen in planning with recoverability evidence; automatic recovery at launch with outcome shown; unrecoverable files retained; preflight warns below 2 GB and blocks below 500 MB; notes autosave 2 s after last edit and at least every 10 s; fallback title "Meeting" + local start date/time; own sounds excluded where the platform allows; closing the main window has no effect.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Start and stop a meeting (Priority: P1)

As a person about to join a meeting, I start a meeting recording from LocalFlow. A durable meeting identity exists before capture begins. While recording I can see that it is recording, how long it has been recording, whether the microphone and system audio are each capturing, and controls to pause, resume and stop. Stopping finalizes the audio files and saves the completed meeting. Only one meeting can be active at a time; pressing Start twice does not create a second meeting.

**Why this priority**: Every other story depends on a meeting that starts, records and stops. This is the smallest slice that delivers value.

**Independent Test**: Start a meeting, wait a few minutes with both sources active, stop, and confirm one completed meeting exists with two finalized tracks and the expected duration.

**Acceptance Scenarios**:

1. **Given** no active meeting and permissions granted, **When** the user chooses Start Meeting, **Then** a meeting record with a stable identity exists before audio capture begins, the state becomes recording, and the active-meeting view shows elapsed time, microphone state and system-audio state.
2. **Given** an active meeting, **When** the user chooses Start Meeting again (from any entry point), **Then** no second meeting is created and the existing active meeting is shown.
3. **Given** an active meeting, **When** the user chooses Stop, **Then** the state becomes finalizing, both tracks are finalized, the state becomes completed, the stop timestamp and recorded duration are persisted, and the meeting appears in the library as completed.
4. **Given** an active meeting, **When** the user closes the main window, **Then** the meeting keeps recording and the indicator still reports the recording state.

---

### User Story 2 - Microphone and system audio as separate tracks (Priority: P1)

As a user, my meeting records what I said (microphone) and what the others said (system audio) as two independent tracks that stay separate on disk, using only what macOS provides, without installing a virtual audio driver.

**Why this priority**: Separate tracks are the raw evidence later features need. Mixing them permanently would lose information diarization and attribution rely on.

**Independent Test**: Record a meeting while playing known audio on the system and speaking into the microphone; confirm two separate files exist, each containing only its own source.

**Acceptance Scenarios**:

1. **Given** a meeting is recording, **When** the user speaks and system audio plays, **Then** the microphone track contains the speech and the system track contains the system audio, and neither file is a mix of both.
2. **Given** a completed meeting, **When** the user inspects it, **Then** the meeting lists exactly one microphone track and one system track, each with type, codec/container, sample rate, channel count, total duration, total byte size and finalized state, and each listing its ordered segments with per-segment start offset, duration, byte size and finalized state.
3. **Given** no virtual audio device is installed, **When** the user records, **Then** system audio is captured.

---

### User Story 3 - Audio streams to disk with bounded memory (Priority: P1)

As a user recording a two-hour meeting, LocalFlow's memory stays roughly the same as during a twenty-minute meeting, because audio is encoded and written incrementally and never held in full in memory.

**Why this priority**: Memory efficiency is a constitutional product requirement. A capture pipeline that grows with duration is unusable for real meetings.

**Independent Test**: Record with both sources for the acceptance duration while sampling process memory; the recorded track files grow steadily on disk during recording and the memory series settles instead of trending upward.

**Acceptance Scenarios**:

1. **Given** a meeting is recording, **When** one minute passes, **Then** the on-disk size of each active track file has increased and the process does not hold more than the declared bounded working buffers of audio.
2. **Given** a meeting has recorded for the acceptance duration, **When** memory samples are compared, **Then** the settled recording memory does not grow approximately linearly with duration (see SC-003).
3. **Given** the storage backend is inspected, **When** a meeting has been recorded, **Then** no meeting audio is stored inside the structured database.

---

### User Story 4 - Pause and resume (Priority: P2)

As a user, I can pause an active meeting (for a break or a private conversation) and resume it later, staying in the same meeting. Paused time does not count as recorded duration, paused audio is not appended as meeting content, and the timeline records where the pauses were so nothing looks like continuous audio when it was not.

**Why this priority**: Real meetings have breaks; without pause the user would either record private content or lose the meeting's continuity.

**Independent Test**: Record, pause for a measured interval, resume, stop; confirm one meeting, recorded duration excludes the pause, the pause interval is persisted and each track has two finalized segments, one per recording stretch.

**Acceptance Scenarios**:

1. **Given** a recording meeting, **When** the user pauses, **Then** the state becomes paused, elapsed recorded time stops advancing, the pause start is persisted, the current segment of each track is finalized, and no further audio is written as meeting content.
2. **Given** a paused meeting, **When** the user resumes, **Then** the same meeting returns to recording, the pause end is persisted, a new segment is opened for each track, and recorded time continues from where it stopped.
3. **Given** a meeting with pauses, **When** it is stopped and inspected, **Then** recorded duration equals wall-clock duration minus the sum of pause intervals (within the tolerance in SC-005), and every pause interval is listed.
4. **Given** a paused meeting, **When** the user chooses Stop, **Then** the meeting finalizes normally.

---

### User Story 5 - Manual notes during and after a meeting (Priority: P2)

As a user, I write notes while the meeting is recording. My notes save often enough that a crash loses at most a few seconds of typing, belong to that meeting, stay editable afterwards, need no audio processing, and work offline. They are mine, not AI output, and will stay distinguishable from future generated summaries.

**Why this priority**: Notes are the only user-authored artifact in this feature and the first thing the user will look at later. They are independent of audio and cheap to deliver.

**Independent Test**: Type notes during a meeting, force quit, relaunch; the notes are present up to the last autosave. Edit them after the meeting; the edit persists.

**Acceptance Scenarios**:

1. **Given** an active meeting, **When** the user types notes and stops typing, **Then** the notes are persisted within 2 seconds after the last edit and at least every 10 seconds while typing continuously.
2. **Given** notes were typed and the application is force quit, **When** the application relaunches, **Then** the notes are present up to the last autosave and attached to the correct meeting.
3. **Given** a completed or interrupted meeting, **When** the user edits its notes, **Then** the edit is saved and the meeting's audio and metadata are unchanged.
4. **Given** the network is off and no server is configured, **When** the user writes notes, **Then** notes work identically.

---

### User Story 6 - Durable meeting metadata (Priority: P2)

As a user (and as later features), every meeting has a durable record: stable identity, start and stop timestamps, state, recorded and wall-clock duration, pause intervals, optional title, notes, per-track metadata and recovery/finalization state. Track locations are relative to the application's meeting storage so the storage can be relocated later.

**Why this priority**: The record is the contract with Features 005–008. Without it the audio files are orphans.

**Independent Test**: Record a meeting with a pause and a title; read the record back after relaunch and confirm every listed field is present and correct.

**Acceptance Scenarios**:

1. **Given** a completed meeting, **When** its record is read, **Then** it contains all fields listed in FR-014 and each track has the metadata listed in FR-015.
2. **Given** the meeting storage folder is moved to another location and the application is pointed at it, **When** meetings are listed, **Then** track paths still resolve because they are stored relative to the meeting storage root.
3. **Given** a meeting without a title, **When** it is displayed, **Then** the fallback title "Meeting" plus the local start date and time is shown.

---

### User Story 7 - Meeting library and detail (Priority: P2)

As a user, I can see my past meetings with title, date/time, duration and status (completed or interrupted), open one, and see its metadata, notes, available audio tracks and recovery state.

**Why this priority**: Without a library the user cannot find, verify or delete what was recorded.

**Independent Test**: Record two meetings, interrupt a third; the library lists all three with correct titles, times, durations and statuses; opening each shows its detail.

**Acceptance Scenarios**:

1. **Given** several meetings exist, **When** the library is opened, **Then** each shows title or fallback title, date/time, duration and completed/interrupted status, newest first.
2. **Given** a meeting is opened, **When** its detail is shown, **Then** metadata, notes, each audio track with its status, and any recovery state and reason are visible.
3. **Given** the library has many meetings, **When** it is scrolled, **Then** only a bounded window of records is held in memory (FR-025); no semantic or free-text search is offered.

---

### User Story 8 - Play back captured audio (Priority: P2)

As a user, after a meeting I can verify that the microphone and system tracks exist and play each one. Optionally I can listen to both together for monitoring. Playback never changes the source files.

**Why this priority**: Playback is how the user (and the acceptance test) confirms the recording is real and valid.

**Independent Test**: Open a completed meeting, play the microphone track, play the system track; both play from start to end and the file sizes and checksums are unchanged afterwards.

**Acceptance Scenarios**:

1. **Given** a completed meeting, **When** the user selects a track and plays it, **Then** audio plays with a position indicator and can be paused and stopped.
2. **Given** a recovered meeting with one valid track and one that failed validation, **When** the user opens it, **Then** the valid track is playable and the invalid one is labelled as not playable with its recorded reason.
3. **Given** any playback session, **When** it ends, **Then** the source files are byte-identical to before.

---

### User Story 9 - Recover after a crash, force quit or reboot (Priority: P1)

As a user whose Mac crashed, whose application was force quit or who rebooted mid-meeting, I do not lose the meeting. At next launch LocalFlow finds the meeting that was left recording, paused or finalizing, marks it interrupted, recovers whatever audio was already written where technically possible, keeps my notes and track metadata, and tells me why normal completion did not happen. Nothing is deleted automatically.

**Why this priority**: A recording feature that loses an hour of audio when the app dies is worse than none. The constitution requires recoverability.

**Independent Test**: Start a meeting, force quit the process after several minutes, relaunch; the meeting is listed as interrupted, the already-written audio is playable (or marked unrecoverable with a reason), and notes are intact.

**Acceptance Scenarios**:

1. **Given** the application was force quit while a meeting was recording, **When** it relaunches, **Then** the meeting is shown as interrupted, not completed, with the reason "application did not exit cleanly" (or equivalent), and already-written media is recovered automatically without user confirmation, with the outcome shown.
2. **Given** the application was force quit while paused, **When** it relaunches, **Then** the meeting is interrupted, the pause metadata up to the last persisted change is preserved, and recorded duration excludes the open pause.
3. **Given** the application was force quit while finalizing, **When** it relaunches, **Then** tracks already finalized are kept as finalized, unfinalized tracks are recovered where possible, and the meeting is marked interrupted with the finalization stage recorded.
4. **Given** a meeting was interrupted and one track cannot be made playable, **When** recovery runs, **Then** the track is marked unrecoverable with a reason, its file is retained, and the other track and notes are preserved.
5. **Given** no meeting was left in an active state, **When** the application launches, **Then** reconciliation finishes without changing any meeting and dictation starts normally.

---

### User Story 10 - Storage failure during recording (Priority: P1)

As a user whose disk fills up or whose output folder disappears mid-meeting, I am told clearly that recording has stopped, whatever was already written is kept, and the indicator never keeps showing a healthy recording when nothing is being saved.

**Why this priority**: Silent data loss with a green indicator is the worst possible outcome; bounded memory forbids waiting on disk with unlimited buffering.

**Independent Test**: With a storage test double that starts failing writes after N seconds, record; capture stops within the declared bound, the meeting ends as interrupted with a storage-failure reason, already-written audio is retained and memory does not grow.

**Acceptance Scenarios**:

1. **Given** a meeting is recording, **When** writes to a track begin failing, **Then** within the declared bound (default 5 seconds) capture stops, already-written media is finalized where possible, the meeting becomes interrupted with the storage failure recorded as the reason, the user sees a clear notice, and the indicator no longer shows the meeting as recording.
2. **Given** writes are failing, **When** audio keeps arriving, **Then** at most the declared bounded buffer is retained and the rest is dropped and counted; process memory does not grow.
3. **Given** free space is below the preflight threshold, **When** the user chooses Start Meeting, **Then** the user is warned (below 2 GB) or blocked (below 500 MB) before capture starts.
4. **Given** a storage failure ended a meeting, **When** the meeting is opened, **Then** already-written audio up to the failure is retained and, where possible, playable.

---

### User Story 11 - One audio source fails (Priority: P1)

As a user whose microphone unplugs or whose system-audio stream stops, the meeting shows which track failed, keeps the other track where practical, and never claims both are recording.

**Why this priority**: Source failures are common (headset disconnect, permission change) and must be visible and represented in the durable record.

**Independent Test**: Using capture test doubles, fail one source mid-meeting; the meeting shows that track as failed with a reason and timestamp, the other track continues and the final record reflects both outcomes.

**Acceptance Scenarios**:

1. **Given** a recording meeting, **When** the microphone source reports failure, **Then** the microphone track state becomes failed with a reason and time, the UI shows a prominent warning, and the meeting continues with system audio only.
2. **Given** a recording meeting, **When** the system-audio source reports failure, **Then** the system track state becomes failed with a reason and time, the UI shows a prominent warning, and the meeting continues with the microphone only.
3. **Given** both sources have failed, **When** the failure is detected, **Then** the meeting stops and is marked failed or interrupted with both reasons, and already-written audio is retained.
4. **Given** the input device changes during recording, **When** capture continues on the new device or fails, **Then** the outcome is recorded on the track and shown; audio is never silently attributed to a healthy state that did not exist.

---

### User Story 12 - Permissions (Priority: P1)

As a user without microphone or screen/system-audio permission, I get clear, actionable guidance before or at the moment I try to start, and I never end up with an unexplained empty recording. LocalFlow asks for nothing it does not need.

**Why this priority**: System-audio capture requires a permission most users have never granted; without guidance the first meeting fails.

**Independent Test**: With microphone permission denied, then with screen-recording permission denied, choose Start Meeting; each case shows the specific missing permission, how to grant it, and does not start an empty meeting.

**Acceptance Scenarios**:

1. **Given** microphone permission is not granted, **When** the user chooses Start Meeting, **Then** the request is made or the user is directed to the exact system setting, and the meeting does not start until the decision is known.
2. **Given** system-audio permission is not granted, **When** the user chooses Start Meeting, **Then** the user is told which permission is missing and how to grant it, and the meeting does not start with an empty system track presented as healthy.
3. **Given** permission is revoked during a meeting, **When** capture stops as a result, **Then** the affected track is marked failed with reason "permission revoked" and story 11 rules apply.
4. **Given** the feature is used, **When** permission prompts are reviewed, **Then** only microphone and screen/system-audio permissions are requested.

---

### User Story 13 - Delete a meeting (Priority: P2)

As a user, I can delete a meeting after confirmation. Deletion removes the meeting record, its notes, its track metadata and its audio files, and never touches another meeting.

**Why this priority**: Users must be able to remove private recordings; deletion of recovered meetings is also part of the recovery acceptance list.

**Independent Test**: Create two meetings, delete one with confirmation; its record, notes, track rows and files are gone and the other meeting is untouched with files present.

**Acceptance Scenarios**:

1. **Given** a meeting is selected, **When** the user chooses Delete and confirms, **Then** its record, notes, track metadata and audio files are removed, and any future child artifacts are removed through cascade rules.
2. **Given** deletion is requested and not confirmed, **When** the dialog is dismissed, **Then** nothing changes.
3. **Given** an interrupted or recovered meeting, **When** it is deleted with confirmation, **Then** the same removal applies, including unrecoverable retained files.
4. **Given** file removal partially fails, **When** deletion completes, **Then** the outcome is reported and the meeting is not shown as fully deleted while files remain.

---

### Edge Cases

- Start Meeting while a meeting is already active: refused; the active meeting is shown (story 1).
- Start Meeting while a dictation is in progress, or a dictation shortcut during an active meeting: resolved in planning under the constitution's exclusivity and memory rules; the default is to refuse the second activity with a notice rather than run both.
- Meeting identity persisted but a segment file cannot be opened: the meeting moves to failed with reason, no capture starts, no orphan file is left, and the record is kept so the failure is visible.
- Segment file exists but the metadata update fails: on next reconciliation the file is matched to its meeting by location and marked recoverable; the file is not deleted.
- One track finalizes and the second does not: meeting is interrupted; the finalized track is kept as finalized, the other is recovered or marked unrecoverable.
- Crash with segments already finalized: only the open segment of each track is at risk; earlier finalized segments are kept as-is and the open segment is recovered or marked unrecoverable.
- Application crashes while state says recording: story 9.
- Mac sleeps during an active meeting: when the streams stop, the meeting transitions to paused with a system-initiated pause interval (reason "system sleep") whose start is persisted; on wake it stays paused and the UI says why; the user explicitly resumes (which closes the interval) or stops. Capture never resumes automatically; no continuous audio is fabricated for the gap. If the streams keep running through sleep, nothing changes.
- Machine reboots: on next launch the meeting is interrupted with reason "not running at last known state"; recovery runs.
- Very long meeting (multi-hour): memory stays bounded; file sizes grow linearly; the library shows the correct duration.
- Zero-length meeting (start then immediate stop): completed meeting with near-zero duration and two finalized, possibly near-empty tracks; not treated as a failure.
- No system audio playing during the meeting: the system track is healthy and mostly silent; silence is not a failure.
- LocalFlow's own sounds while capturing system audio: the application's own audio is excluded from the system track where the platform allows it; otherwise it is included and the limitation is documented.
- Title edited during or after recording: persisted independently of capture; never used for file names (FR-023).
- Storage becomes available again after a failure: recording never resumes into the interrupted meeting; the user starts a new meeting. Resume-after-failure is out of scope.
- Output directory unavailable at start: preflight fails with a clear reason; no meeting is created in an active state.
- Concurrent note edits from two windows: last write wins within one meeting; no cross-meeting effect.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: Provide an explicit Start Meeting action. Starting MUST create and persist a meeting record with a stable identity before any long-running capture begins; the state sequence MUST be created → preparing → recording.
- **FR-002**: At most one meeting MAY be active (preparing, recording, paused or finalizing) at any time. A second start request MUST be refused deterministically and MUST NOT create a record.
- **FR-003**: Capture microphone audio and macOS system audio as two independent tracks using only platform-provided capture. No virtual audio driver MAY be required. The tracks MUST be persisted as separate files and MUST NOT be permanently mixed during capture.
- **FR-004**: Audio MUST be encoded and written incrementally to the filesystem. The complete recording MUST NEVER be held in memory. Raw audio MAY exist only in bounded working buffers with explicit capacities and overload policies declared in planning. Meeting audio MUST NOT be stored inside the structured database.
- **FR-005**: The compressed audio format MUST support incremental writing, bounded memory, reasonable storage use, recovery after abnormal termination, later decoding for recognition, and speech-adequate quality. Uncompressed multi-hour capture is not permitted without a measured justification. The codec/container is a native compressed format suitable for long speech recordings, chosen in planning with a measured comparison of recoverability after abnormal termination.
- **FR-006**: While active, the UI MUST show recording state, elapsed recorded time, microphone capture state, system-audio capture state, pause/resume availability and a stop control. A track whose persistence or capture has failed MUST NOT be shown as healthy.
- **FR-007**: Provide pause and resume for an active meeting. While paused, recorded duration MUST NOT advance and audio MUST NOT be appended as meeting content. Resume MUST continue the same meeting. Each pause interval MUST be persisted with start, end and reason (user pause or system sleep) so later features can reconstruct the timeline; a silent gap presented as continuous audio is prohibited. When the system stops the capture streams (sleep), the meeting MUST enter paused with reason "system sleep" and MUST stay paused until the user resumes or stops; capture MUST NOT resume automatically. Every pause (user or system) MUST finalize the currently open segment of each track and every resume MUST open a new segment; a resume MUST NOT append into a previously finalized segment file.
- **FR-008**: Stop MUST move the meeting through finalizing to completed, finalize the open segment of every track into a playable container, and persist stop timestamp, recorded duration, wall-clock duration and per-track metadata.
- **FR-009**: Provide a notes editor for the active meeting and for meetings in the library. Notes MUST be persisted automatically 2 s after the last edit and at least every 10 s during continuous editing, MUST belong to exactly one meeting, MUST remain editable after the meeting, MUST NOT depend on audio processing or any network, and MUST be stored as user-authored content distinguishable from any future generated content.
- **FR-010**: Define an explicit finite meeting lifecycle with at least the states created, preparing, recording, paused, finalizing, completed, interrupted and failed. Every transition MUST be checked; invalid transitions (for example completed → recording) MUST be rejected deterministically and MUST NOT partially mutate state. Every transition MUST be persisted before it is reported to the UI as done.
- **FR-011**: Persist meeting state, pause intervals, track metadata and notes during capture, not only at stop, so a meeting is identifiable and recoverable after crash, force quit, reboot or capture failure.
- **FR-012**: On every launch, run reconciliation before any new meeting can start. Meetings found in preparing, recording, paused or finalizing MUST be marked interrupted (or failed when the record shows a fatal error), never completed. Reconciliation MUST record why normal completion did not occur, attempt to recover already-written media and finalize playable containers where technically possible, preserve notes and track metadata, and MUST NOT delete any media. Recovery MUST run automatically without confirmation and MUST NOT block launch; the outcome MUST be shown to the user.
- **FR-013**: Reconciliation MUST handle: a meeting record without any segment file; a segment file without a matching record or with stale metadata; one track finalized and the other not; and a meeting whose state says active while the application was not running. In each case user data MUST be preserved conservatively and the outcome recorded.
- **FR-014**: Each meeting record MUST contain at least: stable identity, creation/start timestamp, stop timestamp when completed, lifecycle state, recorded duration, wall-clock duration, pause intervals, optional title, manual notes, audio-track metadata, and recovery/finalization state including reason text where applicable.
- **FR-015**: Each audio track record MUST contain, where available: type (microphone or system), codec/container, sample rate, channel count, total duration, total byte size, finalized state, health state (healthy, failed, unrecoverable, finalized) with failure reason and timestamp, and an ordered list of segments. Each segment record MUST contain: sequence number, relative file path, start offset within the track's recorded timeline, duration, byte size, finalized state and, for unrecoverable segments, the reason. File locations MUST be stored relative to the application's meeting storage root, not as absolute paths. Only one segment per track MAY be open at any time.
- **FR-016**: Provide a meeting library listing title or fallback title, date/time, duration and completed/interrupted status. Provide a detail view showing metadata, notes, available tracks with their state, and recovery state. No semantic or free-text search is included.
- **FR-017**: Provide playback of each captured track from the detail view with play, pause, stop and position; a track plays its finalized segments in order as one timeline. Combined monitoring playback of both tracks MAY be offered. Playback and inspection MUST NOT modify source files.
- **FR-018**: Storage failures (full filesystem, failed write, unavailable directory, encoder unable to continue) MUST stop capture within a declared bound (default 5 seconds), end the meeting as interrupted with the storage failure recorded as the reason, finalize already-written data where possible, surface a clear failure and remove the healthy indication. The meeting MUST NOT be suspended for a later resume. Audio MUST NOT be buffered without limit while waiting for storage; overflow MUST be dropped and counted.
- **FR-019**: Before starting, check free space at the meeting storage location. Below a warning threshold the user MUST be warned; below a blocking threshold the start MUST be refused with a clear reason (warn below 2 GB, block below 500 MB).
- **FR-020**: Microphone and system-audio health MUST be tracked and persisted independently. When one source fails, the meeting MUST continue recording on the remaining source, the failed track MUST be shown clearly with a prominent warning, reason and timestamp, and the meeting MUST NOT claim both are recording. When both fail, the meeting MUST stop and be marked with both reasons.
- **FR-021**: Before starting capture, check microphone and screen/system-audio permissions. A missing permission MUST produce actionable guidance naming the permission and where to grant it, and MUST prevent an unexplained empty recording. No other permission MAY be requested by this feature.
- **FR-022**: Provide confirmed deletion of a meeting that removes the meeting record, its notes, its track metadata, its audio files and any future child artifacts via cascade, using the existing confirmed-deletion pattern. Deletion MUST NOT affect other meetings and MUST report partial failure.
- **FR-023**: Store meeting media in an application-owned hierarchy keyed by meeting identity (conceptually `Meetings/<identity>/…`). In-progress files MUST be distinguishable from finalized files. File names MUST NOT contain user-entered titles. The database, not the file names, is the authority for what a file is.
- **FR-024**: The feature MUST work with no network, no rewrite server, no language model, no transcription model and no diarization model loaded. No meeting audio or notes MAY leave the client.
- **FR-025**: Every queue, buffer, stream and cache introduced (capture sample queues, encoder input, write queue, note autosave state, library page cache) MUST have an explicit capacity and overload policy defined in planning. Unbounded streams or queues are prohibited. The library MUST load records in bounded pages.
- **FR-026**: Extend the existing content-free local instrumentation with: meeting start duration, capture initialization duration, state transitions, microphone and system-audio queue depth, dropped-buffer count where exposed, bytes written per track, encoder/write failures, pause/resume counts, finalization duration, process RSS, file sizes and recovery outcomes. Audio content, note content, transcript content, titles and title-derived file names MUST NOT be recorded.
- **FR-027**: The Feature 001–003 dictation path MUST be unchanged when no meeting is active; their regression suites MUST pass unchanged.
- **FR-028**: Provide deterministic tests, using test doubles for capture sources, storage and clock where needed, for: every lifecycle transition and every invalid transition; normal start → stop; start → pause → resume → stop; interruption while recording, paused and finalizing; system sleep during recording (paused with reason, no automatic resume); microphone failure; system-audio failure; storage write failure; startup reconciliation for each FR-013 case; deletion of a recovered meeting; buffer capacity and overflow; and note autosave.

### Key Entities *(include if feature involves data)*

- **Meeting**: One recording session. Stable identity, timestamps, lifecycle state, durations, optional title, recovery/finalization state and reason. Owns its tracks, pause intervals and notes.
- **Audio Track**: One captured source (microphone or system) for a meeting. Format details, total duration, total byte size, finalized state, health state with reason and timestamp. Owns an ordered list of segments.
- **Audio Segment**: One contiguous recorded stretch of a track, stored as one file. Sequence number, relative path, start offset in the track's recorded timeline, duration, byte size, finalized state and reason when unrecoverable. A new segment starts on every resume; a segment is finalized on pause, stop or recovery.
- **Pause Interval**: A period during which the meeting was open but not recording. Start, end, and reason (user pause, system sleep). Used with segments to reconstruct the timeline.
- **Meeting Notes**: User-authored text belonging to one meeting, with last-saved timestamp. Distinct from any future generated content.
- **Recovery Outcome**: The result of reconciliation for one meeting: what was found, what was recovered, what was marked unrecoverable, and why.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: A user can start a meeting and see the recording state and timer within 3 seconds of choosing Start on the reference machine with permissions already granted.
- **SC-002**: Across the recovery acceptance scenarios (normal start → stop; start → pause → resume → stop; force quit while recording; force quit while paused; force quit during finalization where practical; microphone failure; system-audio failure; storage write failure simulation; startup recovery; deletion of a recovered meeting), 100% pass deterministically on repeated runs, and at least one real force-quit run on the reference machine leaves a meeting listed as interrupted with playable already-written audio and intact notes.
- **SC-003**: During the long-run acceptance recording on the reference M5 MacBook Pro with both sources active, notes edited and at least one pause/resume, the process RSS series settles: the fitted slope over the settled window is below 1 MB per 10 minutes and the peak is within the constitution's recording overhead budget (100 MB above idle, excluding ML working sets). Reported: starting RSS, settled RSS, peak RSS, slope, final RSS after stop, per-track file sizes, dropped-buffer/error count and finalization duration. The final acceptance duration is 60 minutes, with a 10–15 minute run used during development. A short unit test is never presented as evidence for this criterion.
- **SC-004**: For every completed meeting in acceptance, every segment of both tracks is playable end to end and each track's total duration is within 1% or 2 seconds (whichever is larger) of the meeting's recorded duration.
- **SC-005**: For meetings with pauses, recorded duration equals wall-clock duration minus the sum of pause intervals within 1 second, and each pause is listed with start and end.
- **SC-006**: After a simulated storage failure, capture stops within 5 seconds and the meeting is interrupted with a storage-failure reason, retained audio buffers never exceed the declared capacity, process RSS does not grow by more than the declared buffer bound, and already-written audio up to the failure is retained.
- **SC-007**: Notes typed during a meeting survive a force quit with at most the autosave interval of loss (2 s after the last edit; 10 s during continuous typing).
- **SC-008**: With microphone permission denied, and separately with system-audio permission denied, 100% of start attempts show the specific missing permission and produce no meeting in an active state.
- **SC-009**: Confirmed deletion of one of two meetings removes 100% of its record, notes, track rows and files and leaves the other meeting's record and files byte-identical.
- **SC-010**: With no network, no server and no model provisioned, every story in this specification is exercisable; no model is loaded during capture (verified by the existing model lifecycle instrumentation reporting no load).
- **SC-011**: All Feature 001–003 regression suites pass unchanged with the feature present and no meeting active.
- **SC-012**: Instrumentation collected during the long-run acceptance contains none of: audio, note text, titles or title-derived file names.

## Assumptions

All agenda items were settled in the 2026-09-18 clarification session. Numeric bounds are decisions, not measurements.

- One active meeting at a time; multiple concurrent meetings are out of scope.
- Dictation and meeting capture are mutually exclusive by default; planning may relax this only with measurements under the constitution's memory and model-exclusivity rules.
- Decided: if one source fails, the meeting continues on the remaining source with a prominent warning; if both fail, the meeting stops (items 1–2).
- Decided: a storage failure ends the meeting as interrupted; there is no suspend or resume-after-failure state.
- Decided: final long-run acceptance duration is 60 minutes; development runs are 10–15 minutes (item 3).
- Decided: each track is an ordered list of segment files; every resume opens a new segment and every pause or stop finalizes the open one; pause intervals are also persisted (items 4 and 6).
- Decided: a native compressed speech-suitable codec/container, chosen in planning with a measured comparison of recoverability after abnormal termination (item 5).
- Decided: interrupted meetings are recovered automatically at startup with the outcome shown; no confirmation dialog blocks launch (item 7).
- Decided: incomplete or corrupt track files are retained and marked unrecoverable, never deleted automatically (item 8).
- Decided: free-space preflight warns below 2 GB and blocks below 500 MB at the meeting storage location (items 9–10).
- Decided: notes autosave 2 s after the last edit and at least every 10 s during continuous editing; every save is crash-safe (item 11).
- Decided: fallback title is "Meeting" followed by the local start date and time (item 12).
- Decided: LocalFlow's own sounds are excluded from the system track where the platform allows; otherwise they are included and the limitation is documented (item 13).
- Decided: on system sleep, stopped streams put the meeting into paused with reason "system sleep"; it stays paused on wake until the user resumes or stops; nothing is fabricated for the gap (item 14).
- Decided: closing the main window does not affect an active meeting; the indicator remains (item 15).
- Meeting storage lives under the application's existing data directory; relocation is supported by relative paths but no relocation UI is added.
- Existing SQLite/GRDB storage and migration patterns, the existing confirmed-deletion pattern and the existing content-free instrumentation are reused; exact schema belongs to planning.
- The reference machine is the owner's M5 MacBook Pro used for Features 001–003.

## Clarification agenda (settled)

All fifteen items were settled in the clarification session of 2026-09-18 (see Clarifications).

1. Microphone fails, system audio healthy: continue automatically? Decided: continue with warning.
2. System audio fails, microphone healthy: continue automatically? Decided: continue with warning.
3. Final long-run acceptance duration: 30, 60 or 120 minutes? Decided: 60.
4. One file per track or internal segments? Decided: ordered segments, one file per recording stretch.
5. Initial codec/container default. Decided: native compressed speech-suitable format selected in planning with recoverability evidence.
6. Pause/resume as explicit segments or logical append to one track? Decided: explicit segments plus pause metadata.
7. Interrupted meeting: automatic finalization at startup or explicit confirmation? Decided: automatic with outcome shown.
8. Retain incomplete/corrupt track files that fail validation? Decided: retain.
9. Disk-space preflight policy. Decided: check free space at the storage location before every start.
10. Minimum free-space thresholds. Decided: warn below 2 GB, block below 500 MB.
11. Notes autosave on every edit or debounced? Decided: debounced 2 s, at most 10 s.
12. Fallback title. Decided: "Meeting" + local start date/time.
13. Include LocalFlow's own sounds in the system track? Decided: exclude where possible.
14. Mac sleeps during a meeting. Decided: paused with reason "system sleep", user resumes or stops explicitly; no automatic resume.
15. Closing the main window. Decided: no effect on the active meeting.

## LocalFlow resource and failure acceptance

The [constitution](../../.specify/memory/constitution.md) and the [memory budget](../../docs/performance/memory-budget.md) remain binding. Capture is infrastructure, so the recording overhead target of 100 MB above idle applies in full, with no ML working set to exclude because no model is loaded. Planning MUST declare a finite capacity and overload policy for every new element: per-source sample queues, encoder input buffers, write queues, note autosave state, library paging, instrumentation storage and recovery work lists. At capacity, audio overflow is dropped and counted, never accumulated; note saves are coalesced, never lost silently.

Duration independence is measured, not assumed: the long-run acceptance in SC-003 compares a development run (10–15 minutes) with the final 60-minute run and reports the RSS series, slope, peak, post-stop value, file sizes, dropped-buffer count and finalization duration, with hardware, OS, build, codec settings and conditions identified. Unmeasured targets are reported as unmeasured.

Offline behavior: every story works with the network disabled, no server configured and no model provisioned. Permission failures produce guidance and no active meeting. Storage failures stop capture within the declared bound, end the meeting as interrupted and preserve written data. Source failures are represented per track. Interruptions are reconciled at launch without deleting media and without inventing completion.

User data preservation: no recovery, playback, deletion of another meeting, or later feature may modify or remove meeting audio, notes or metadata except through the confirmed deletion of that meeting. A save failure is never reported as persisted.

Run `make check` for repository validation. Hardware measurements, the real force-quit run and the long-run acceptance are separate evidence and remain explicitly unverified until recorded.
