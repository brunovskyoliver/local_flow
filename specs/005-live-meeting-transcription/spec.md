# Feature Specification: Feature 005 — Live Meeting Transcription

**Feature Branch**: `main` (existing branch; no branch-creation hook configured)

**Created**: 2026-09-18

**Status**: Draft — clarified 2026-09-18 (5 questions); remaining agenda items carry accepted proposed defaults

**Input**: Add local transcription to active and completed Feature 004 meetings. While a meeting records, LocalFlow progressively shows provisional transcript text with useful near-real-time latency. After the meeting stops, LocalFlow finalizes a stable, timestamped transcript from the durable recorded audio, using the existing local Parakeet path, deterministic assembly and normalization, and a stable vocabulary snapshot. Recording always has priority over transcription; transcription failure never harms the recording; memory stays bounded regardless of meeting length; the transcript is reproducible from stored audio and retryable. No diarization, speaker identity, summaries, action items, semantic search, LLM rewriting, backup or cloud work is included. The transcript produced here is the source for Features 006–008.

## Boundary with Features 001–004 and later features

Features 001–003 own push-to-talk dictation, local recognition, deterministic assembly and normalization, vocabulary learning and optional server rewriting. Feature 004 owns durable meeting capture: two separate tracks (microphone, system audio) stored as ordered segment files, pause intervals, manual notes, lifecycle, reconciliation and deletion.

Feature 005 adds one capability on top of 004: a timestamped transcript for a meeting, produced locally by the same recognition, assembly and normalization machinery dictation already uses. It introduces a second, independent lifecycle (meeting transcription) alongside the meeting recording lifecycle. A meeting whose recording completed and whose transcription failed is a valid state.

Feature 005 does not touch the Feature 004 tracks except to read them. It does not alter dictation. It stores no speaker information. Feature 006 will consume the transcript segments and the original tracks for anonymous diarization; Feature 007 adds persistent identity; Feature 008 adds summaries, decisions and tasks. Feature 005 therefore preserves timestamps, raw recognition text and the description of which audio was analyzed, so later features can align speakers to exact meeting audio.

## Clarifications

### Session 2026-09-18

- Q: What live-transcript latency gate should Feature 005 commit to, given that the existing dictation chunking (~15 s windows) can't get below roughly 13–17 s? → A: Option B — add an isolated, versioned live planner with shorter windows; gate median ≤ 5 s, p95 ≤ 10 s; finalization keeps production geometry.
- Q: When a meeting stops, should finalization re-transcribe the whole recording from stored audio, or only the stretches the live pass skipped? → A: Option A — re-transcribe everything at finalization with production geometry; live segments are a preview and are replaced.
- Q: Which audio should recognition analyze — one mixed mono stream of both tracks, the tracks separately, or mixed live and separate at finalization? → A: Option A — one mixed mono stream for both passes; no per-segment track attribution; echo limitation documented.
- Q: Should live transcription be on by default for new meetings, with a per-meeting override at start? → A: Option A — on by default; global setting plus per-meeting override at start.
- Q: When live recognition falls behind, what lag thresholds should trigger "catching up", dropping live audio into a gap, and suspending the live path? → A: Option A — tolerate lag ≤ 10 s; between 10 s and a 30 s-of-audio queue capacity drop the oldest live audio and record a live gap; at capacity suspend live processing until the queue drains.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Live transcript while recording (Priority: P1)

As a person in a meeting, I see transcript text appear in the active-meeting view while the meeting keeps recording, without stopping the meeting. The view shows whether transcription is active, whether it is keeping up, the latest segments, and marks the text as provisional. If transcription fails, the view says so and the recording continues untouched.

**Why this priority**: This is the product goal of the feature. Everything else exists to make this text trustworthy and durable.

**Independent Test**: Start a meeting with transcription enabled, speak for two minutes, and confirm provisional text appears while the recording state remains "recording" and the track files keep growing.

**Acceptance Scenarios**:

1. **Given** a meeting is recording with transcription enabled, **When** the user speaks, **Then** provisional transcript text for that speech appears within the latency target (SC-001) while the meeting stays in the recording state.
2. **Given** a meeting is recording with transcription enabled, **When** the user looks at the transcript area, **Then** it shows the transcription state (active, catching up, degraded, failed), an activity indicator, the most recent segments in order, and a visible provisional marker on every unfinalized segment.
3. **Given** a meeting is recording with transcription enabled, **When** transcription fails for any reason, **Then** the transcript area shows a failure state with reason category, the recording continues, both track files keep growing, and the meeting lifecycle state is unchanged.
4. **Given** a meeting is recording, **When** the user scrolls up in the live transcript, **Then** the view stays where the user scrolled; when the user returns to the bottom, auto-follow resumes.

---

### User Story 2 - Transcription disabled is a first-class mode (Priority: P1)

As a user who only wants audio and notes for a meeting, I record with transcription off. No recognition model loads, no transcription work runs, and the meeting shows its transcript as "not requested" rather than "failed".

**Why this priority**: The constitution forbids loading models without need, and Feature 004 behavior must remain unchanged when transcription is inactive.

**Independent Test**: Record a meeting with transcription off while the model-lifecycle instrumentation runs; confirm no model load is reported and the meeting's transcript state is "not requested".

**Acceptance Scenarios**:

1. **Given** transcription is disabled for a meeting, **When** the meeting records, pauses, resumes and stops, **Then** no recognition model is loaded, no transcript segments exist, and the transcript state reads "not requested".
2. **Given** transcription is disabled, **When** the meeting is inspected after completion, **Then** all Feature 004 metadata, playback and notes behave exactly as in Feature 004 and the transcript area offers "Transcribe this meeting" (see User Story 9).

---

### User Story 3 - Bounded live analysis and backpressure (Priority: P1)

As a user in a three-hour meeting, LocalFlow's memory stays roughly where it was after ten minutes, even if recognition is slower than real time. If recognition falls behind, live text gets staler or skips a stretch, but the recording is never affected, memory never grows to hold the backlog, and the skipped stretch is still transcribed at finalization.

**Why this priority**: Memory is a product requirement; a live path that buffers audio without bound would defeat Feature 004's design.

**Independent Test**: Run a meeting with a deliberately slowed recognition double; confirm the analysis queue never exceeds its declared bound, skipped intervals are recorded, recording continues, and finalization covers the skipped intervals.

**Acceptance Scenarios**:

1. **Given** recognition keeps up, **When** the meeting runs for the acceptance duration, **Then** the process memory series settles and does not grow with duration (SC-003).
2. **Given** recognition lags by less than the tolerated lag, **When** speech continues, **Then** live text appears later but nothing is skipped and the state shows "catching up".
3. **Given** recognition lags beyond the tolerated lag, **When** the analysis queue reaches its capacity, **Then** the oldest queued audio is dropped from the live path only, the dropped interval is recorded as a live gap pending finalization, the recording continues, and the state shows "degraded".
4. **Given** recognition stays behind for an extended period, **When** the skip policy triggers repeatedly, **Then** live processing is suspended until the queue drains, every skipped interval is recorded, and no audio is buffered beyond the declared bound at any time.

---

### User Story 4 - Timestamped segments aligned to recorded audio (Priority: P1)

As a user reviewing a meeting, every transcript segment carries a start and end time on the meeting's recorded-audio timeline, so playback and later speaker work can find the exact audio. Paused stretches never produce transcript text or implied duration.

**Why this priority**: Timestamps are what make the transcript usable for playback, review and the diarization features that follow.

**Independent Test**: Record a meeting with a pause; confirm no segment overlaps the pause interval, every segment's times lie within the recorded duration, and seeking to a segment plays the matching audio.

**Acceptance Scenarios**:

1. **Given** a finalized transcript, **When** segments are inspected, **Then** each has a start and end time on the recorded-audio timeline, start < end, times increase with ordinal, and every time is within the meeting's recorded duration.
2. **Given** a meeting with a pause interval, **When** the transcript is finalized, **Then** no segment claims time inside the pause, and segments after the pause continue on the recorded-audio timeline without a gap that represents the pause.
3. **Given** a segment, **When** its wall-clock time is requested, **Then** it can be derived from recorded time plus the meeting's start and pause intervals.

---

### User Story 5 - Finalize the transcript after the meeting stops (Priority: P1)

As a user, when I stop a meeting, LocalFlow finishes the transcript on its own: it processes whatever audio the live path did not cover, assembles and normalizes the text with a stable vocabulary snapshot, and marks the transcript final. I do not need to keep the meeting open. If the app quits during this work, it resumes after the next launch.

**Why this priority**: The final transcript is the authoritative artifact and the input to every later feature.

**Independent Test**: Stop a meeting that has live gaps, quit the app during finalization, relaunch, and confirm finalization resumes and the final transcript covers the full recorded duration.

**Acceptance Scenarios**:

1. **Given** a recording meeting with live transcription, **When** the user stops it, **Then** the meeting completes per Feature 004, the transcript state moves to finalizing, in-flight live work finishes or is cancelled safely, and finalization starts without further user action.
2. **Given** finalization is running, **When** the user closes the meeting detail view or the main window, **Then** finalization continues and its state is visible when the meeting is reopened.
3. **Given** finalization completes, **When** the transcript is inspected, **Then** every segment is marked final, provisional segments have been replaced or confirmed, the transcript records engine, model, pipeline version and vocabulary snapshot, and the state reads "final".
4. **Given** the app terminates during finalization, **When** it launches again, **Then** the transcript is detected as interrupted, finalization resumes from durable audio and persisted progress, and no already-finalized segment is silently changed.

---

### User Story 6 - Transcription failure is separate from recording (Priority: P1)

As a user, if the recognition model is unavailable, fails to load, or crashes at runtime, my meeting recording is untouched and I can retry transcription later from the stored audio.

**Why this priority**: Losing a recording because of a transcription problem is unacceptable; the constitution requires that processing failures never destroy recordings.

**Independent Test**: Make the model unavailable, record a meeting with transcription enabled, and confirm the meeting completes normally with transcript state "failed" and a working "Retry" action.

**Acceptance Scenarios**:

1. **Given** the recognition model cannot be provisioned or loaded, **When** a meeting starts with transcription enabled, **Then** the meeting records normally, the transcript state is "failed" with the category "model unavailable" or "model load failure", and the audio is complete.
2. **Given** recognition fails at runtime mid-meeting, **When** the failure occurs, **Then** already-produced segments are kept, the transcript state is "failed" with the category "runtime failure", and the recording continues to a normal stop.
3. **Given** a transcript in the failed state and healthy source audio, **When** the user chooses Retry, **Then** a new finalization pass runs from the stored audio and, on success, the state becomes "final".
4. **Given** a transcript that failed repeatedly, **When** source audio still exists, **Then** Retry remains available; the meeting is never marked permanently untranscribable.

---

### User Story 7 - Transcript view in meeting detail (Priority: P2)

As a user, I open a completed meeting and read its transcript in order, with timestamps, a clear final/provisional/failed state, retry when applicable, the ability to select and copy text, and diagnostics (engine, model, pipeline, vocabulary snapshot) when I need them. Long transcripts load in pages; opening a three-hour meeting is fast.

**Why this priority**: The transcript must be readable to be useful, but the view is deliberately minimal until diarization exists.

**Independent Test**: Open a meeting with several thousand segments; confirm the view opens promptly, shows a bounded window of segments, scrolls to load more, and never loads the whole transcript.

**Acceptance Scenarios**:

1. **Given** a meeting with a final transcript, **When** the detail view opens, **Then** a Transcript section shows segments chronologically with a timestamp per segment, the final state, and the transcription metadata.
2. **Given** a transcript with more segments than the page window, **When** the user scrolls, **Then** further segments load incrementally and the number of segments held in memory stays within the declared window.
3. **Given** transcript text is displayed, **When** the user selects and copies it, **Then** the copied text contains the selected normalized text.
4. **Given** a final transcript and a playable track, **When** the user activates a segment, **Then** playback seeks to approximately that segment's start time (best effort; see Assumptions).

---

### User Story 8 - Notes stay independent (Priority: P2)

As a user, my manual notes remain exactly what I typed; the transcript never merges with, rewrites, or interprets them, and notes are never used to correct recognition.

**Why this priority**: Feature 004 established notes as user-authored content; mixing them with generated text would break that guarantee.

**Independent Test**: Write notes during a transcribed meeting; confirm notes text is byte-identical after finalization and no transcript segment contains note text.

**Acceptance Scenarios**:

1. **Given** notes are edited during a transcribed meeting, **When** the transcript finalizes, **Then** the notes are unchanged and no segment was derived from them.
2. **Given** a detail view showing notes and transcript, **When** either is displayed, **Then** they are visibly separate and separately copyable.

---

### User Story 9 - Transcribe a meeting recorded without transcription (Priority: P2)

As a user, I can later transcribe a completed or interrupted Feature 004 meeting that was recorded with transcription off, or that pre-dates this feature, using the same finalization path.

**Why this priority**: Users will have meetings recorded before enabling transcription; the finalization path already exists.

**Independent Test**: Choose "Transcribe" on a meeting with transcript state "not requested"; confirm a final transcript is produced from its stored audio.

**Acceptance Scenarios**:

1. **Given** a completed meeting with transcript state "not requested", **When** the user chooses Transcribe, **Then** finalization runs over the stored tracks and the transcript state becomes "final" or "failed".
2. **Given** an interrupted meeting with recovered partial audio, **When** the user chooses Transcribe, **Then** the transcript covers the recovered audio only and the metadata records the coverage.

---

### User Story 10 - Deletion and recovery cascade (Priority: P2)

As a user, deleting a meeting removes its transcript and all derived transcription artifacts; nothing global (vocabulary, models) is touched. After a crash, launch reconciliation puts every transcript job into a truthful state.

**Why this priority**: Orphaned transcript data would violate the constitution's data-ownership and recoverability rules.

**Independent Test**: Delete a transcribed meeting and confirm no transcript rows, job rows or derived files remain; force-quit during live transcription and confirm reconciliation marks the transcript interrupted and offers finalization.

**Acceptance Scenarios**:

1. **Given** a meeting with a transcript, **When** the user confirms deletion, **Then** the transcription record, all segments and any derived analysis artifacts are removed, and other meetings' transcripts are untouched.
2. **Given** the app terminates during live transcription, **When** it launches, **Then** Feature 004 marks the meeting interrupted, the transcript is marked interrupted, provisional segments are preserved, and finalization over the recovered audio is available (automatically resumed or offered per the recovery policy).
3. **Given** a meeting record is gone, **When** reconciliation runs, **Then** no transcript job or segment survives for it.

---

### Edge Cases

- Both tracks silent for long stretches: no segments are produced for silence; timestamps of surrounding segments stay correct.
- Only one track healthy (Feature 004 source failure): the analysis stream uses the healthy track; the transcript metadata records which tracks contributed.
- Microphone and system audio overlap (two people talking at once): a single analysis stream yields imperfect text; no speakers are invented; the limitation is documented.
- Acoustic bleed (remote speech audible on the microphone track): the single mixed analysis stream cannot duplicate text; echo may degrade recognition; no deduplication heuristics are added (decided, see Clarifications).
- Vocabulary edited mid-meeting: the live pass keeps its snapshot; finalization uses the snapshot recorded for that pass (agenda item 9).
- Pause longer than the model-retention threshold: model released; resume reloads it; live text resumes after reload with the reload recorded.
- Stop pressed while ASR jobs are pending: pending live jobs are cancelled or finished within a bound; finalization covers everything.
- Storage failure ends the meeting (Feature 004): transcription follows the meeting into finalization over the retained audio.
- Database write failure while persisting segments: transcript state becomes "failed" with category "persistence failure"; recording continues; segments already persisted are kept; retry is available.
- Transcript persistence capacity reached: new segments are refused, the failure is reported, recording continues, and the dictation-history quota is not involved.
- Model provisioning missing when Retry is chosen: clear guidance to provision the model; no network access is attempted implicitly.
- Meeting deleted while finalization is running: finalization is cancelled and its artifacts removed.
- Very long meeting (8 hours): memory bounded, segment count within the capacity model, UI paging works.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: Provide a global meeting-transcription setting, on by default, that determines whether a new meeting starts with live transcription, and a per-meeting override at start. When transcription is not requested, no recognition model MAY be loaded and no transcription work MAY run; the transcript state MUST read "not requested".
- **FR-002**: Define an explicit finite transcript lifecycle with at least the states not requested, pending, live, finalizing, final, failed and interrupted. Every transition MUST be persisted before it is reported to the UI. The transcript lifecycle MUST be independent of the Feature 004 meeting lifecycle: recording completed with transcript failed is a valid combination, and no transcript transition MAY change meeting state.
- **FR-003**: Transcription failures MUST NEVER stop, corrupt or mark failed the meeting recording. A transcription failure MUST record a category from at least: model unavailable, model provisioning, model load failure, audio decode failure, analysis-stream failure, runtime failure, finalization interrupted, persistence failure, persistence capacity.
- **FR-004**: Use the existing local recognition path: the existing transcription-engine abstraction, the central model lifecycle coordinator, the existing assembler, normalizer and preferred-spelling vocabulary, and the existing content-free instrumentation. No separate meeting-only recognition architecture, no Whisper production engine and no client language model MAY be introduced. Parakeet v3 remains the production engine.
- **FR-005**: Transcription MUST read the Feature 004 tracks and MUST NOT modify them. Any derived analysis audio MUST be reproducible from the tracks, bounded in size, either temporary or explicitly versioned, and removable without affecting the recording. Source tracks MUST NEVER be replaced by a mixed file.
- **FR-006**: Both the live path and finalization MUST analyze one mono analysis stream mixed from the microphone and system tracks (falling back to the single healthy track when the other has failed), recorded in the Analysis Stream Descriptor with its version. No per-segment track attribution and no bleed-deduplication heuristic MAY be added in this feature. The stream MUST use bounded buffers; meeting duration MUST NOT cause in-memory audio accumulation; the live path MUST NEVER require the whole recording in memory.
- **FR-007**: Every transcript segment MUST carry: stable identity, meeting identity, ordinal, start and end time on the recorded-audio timeline, raw recognition text, assembled text, normalized text, provisional/final state, engine and model identity, pipeline version, and a description of the analyzed audio (which tracks contributed, analysis-stream version). No speaker field MAY carry an invented value; if present it MUST be "unassigned".
- **FR-008**: Timestamps MUST use the recorded-audio timeline as authority (seconds from the start of recorded audio, excluding pauses). Wall-clock time MUST be derivable from the meeting start and Feature 004 pause intervals. No segment MAY overlap a pause interval or extend beyond recorded duration.
- **FR-009**: Provisional and final segments MUST be distinguishable in storage and in the UI. A finalized segment MUST NOT be silently mutated; finalization MAY replace provisional segments and MUST record that it did. The transcript becomes authoritative only when finalization succeeds.
- **FR-010**: Stopping a meeting MUST, after Feature 004 finalizes audio, let live work finish or cancel within a declared bound, then start finalization automatically (agenda item 13). Finalization MUST re-transcribe the complete recorded audio from the durable tracks (live segments are a preview and are replaced, never stitched), assemble, normalize, apply the vocabulary snapshot and persist the final state. Stop, Retry and Transcribe MUST share this one finalization path. It MUST continue when the detail view or window is closed (agenda item 14).
- **FR-011**: Finalization MUST be restart-safe. Progress (last durable audio position processed, segments persisted) MUST be persisted incrementally so that after termination it can resume from durable audio without redoing finalized segments and without reading the complete recording into memory.
- **FR-012**: The final transcript MUST be reproducible from stored audio plus recorded engine, model, pipeline and vocabulary-snapshot metadata, within the model-determinism limits already documented. The database MUST NOT be the only source of truth; re-transcription from audio MUST be possible by explicit user action. No automatic re-transcription MAY happen outside the recovery policy in FR-018.
- **FR-013**: Provide Retry for failed or interrupted transcripts, and Transcribe for meetings whose transcript is "not requested" (agenda item 20), both running the finalization path over stored audio. Retry MUST remain available as long as source audio exists (agenda item 19).
- **FR-014**: Live transcription MUST respect pauses: while paused no audio is analyzed and no segment is produced; in-flight work finishes or cancels (agenda item 7). The model retention policy during pause is per agenda item 8.
- **FR-015**: Capture a vocabulary snapshot identifier at live-transcription start and use it for the whole live pass. Finalization MUST record the snapshot it used; whether it reuses the live snapshot or takes a new one is per agenda item 9. Mid-meeting vocabulary edits MUST NOT change the interpretation of earlier segments in the same pass.
- **FR-016**: Manual notes MUST remain independent: never merged into the transcript, never interpreted, never sent to a language model, never used as recognition corrections.
- **FR-017**: Transcript text MUST be read-only in this feature (agenda item 10).
- **FR-018**: On every launch, reconcile transcript jobs left in live, finalizing, pending or interrupted states against the Feature 004 meeting state: completed meeting with interrupted finalization → resume finalization; interrupted meeting with recovered audio → preserve provisional segments and make finalization available; deleted meeting → no orphan jobs or segments. Reconciliation MUST be deterministic and MUST NOT delete or alter audio.
- **FR-019**: Deleting a meeting MUST cascade to its transcription record, segments, derived analysis artifacts and any future child artifacts, using the existing confirmed-deletion pattern; global vocabulary and models MUST NOT be affected.
- **FR-020**: Every new queue, buffer and cache (analysis audio queue, pending recognition jobs, provisional segment buffer, transcript UI window, persistence batch, finalization work list) MUST have an explicit capacity and overload policy declared in planning. Prohibited: whole-meeting audio in memory, unbounded segment arrays, unbounded queues, unbounded UI rendering, multiple loaded copies of the recognition model.
- **FR-021**: If live recognition falls behind, the system MUST follow this bounded strategy: lag ≤ 10 s is tolerated and shown as "catching up"; the analysis queue holds at most 30 s of audio; when lag exceeds 10 s the oldest queued live-path audio is dropped and the interval is recorded as a live gap pending finalization, shown as "degraded"; when the queue is at capacity live processing is suspended until it drains. Durable recording MUST NEVER be degraded to keep live text current.
- **FR-022**: Transcript persistence MUST use the existing SQLite store through explicit migrations with meeting-specific capacity limits derived from a capacity model for 30-minute, 1-hour, 3-hour and 8-hour meetings. The dictation-history row ceiling MUST NOT govern meeting segments. Reaching transcript capacity MUST be reported, never silent.
- **FR-023**: Transcript loading for display MUST be paged: no view or model may hold more than the declared window of segments (agenda item 16). Persistence MUST write in bounded batches.
- **FR-024**: The recognition model MUST be leased only while live transcription or finalization needs it; it MUST NOT be loaded because the app is open or because a meeting without transcription is recording. After finalization it MUST become eligible for normal release. Diarization models MUST remain unloaded.
- **FR-025**: The live path MUST use an isolated, versioned meeting-specific live chunk planner with shorter windows than the Feature 002 production chunking, targeting SC-001. The live planner MUST remain bounded, preserve exact audio coverage, record its version in the transcription metadata and have deterministic contract tests. Finalization MUST use the Feature 002 production chunk geometry. Ordinary dictation MUST NOT change.
- **FR-026**: Extend content-free instrumentation with: model load time, live latency, analysis-queue depth, recognition-queue depth, segments produced (provisional/final), backpressure events, skipped-live intervals, finalization duration, real-time factor, persistence batch duration, RSS, model release duration and failure counts. Transcript text, note text and audio MUST NEVER be recorded in logs or metrics.
- **FR-027**: Everything MUST work offline after model provisioning. No audio or transcript MAY be sent to the control server, the rewrite service or any external service; Feature 003 rewriting MUST NOT be applied to meeting transcripts.
- **FR-028**: Features 001–004 MUST behave unchanged when meeting transcription is inactive; their regression suites MUST pass unchanged.
- **FR-029**: Provide deterministic tests, with doubles for the engine, audio source, storage and clock, for at least: live enabled start; disabled start with zero recognition work; provisional segment creation; final segment creation; pause/resume; stop with pending work; recognition falling behind; bounded backpressure; live gap recovered at finalization; model load failure; runtime failure; database write failure; restart during live; restart during finalization; retry; deletion cascade; vocabulary snapshot stability; no transcript text in logs; long-transcript paging; timestamps within recorded duration; no false duration across pauses; raw audio unchanged; capture continues when recognition fails; Feature 001–003 regressions.

### Key Entities *(include if data involved)*

- **Meeting Transcription**: The transcription job and state for one meeting. State, engine, model identity/version, pipeline version, vocabulary snapshot, analysis strategy and version, started/finalized timestamps, failure category and reason, progress (last durable audio position processed), live-gap intervals, coverage of recorded duration. Owned by exactly one Meeting.
- **Transcript Segment**: One timestamped unit of recognized speech. Identity, meeting, ordinal, start/end on the recorded-audio timeline, raw text, assembled text, normalized text, provisional/final state, engine/model/pipeline identity, analyzed-audio description. No speaker.
- **Live Gap**: An interval of recorded audio skipped by the live path under backpressure or pause of live work, pending finalization coverage.
- **Vocabulary Snapshot**: A version identifier of the preferred-spelling vocabulary frozen for one transcription pass.
- **Analysis Stream Descriptor**: Which tracks fed recognition and how they were combined, with a version, so results are reproducible and later features know what was analyzed.
- **Transcript Recovery Outcome**: Result of launch reconciliation for one transcription job.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: Live provisional latency, measured from the end of a spoken phrase in captured audio to its provisional text being visible, has median ≤ 5 s and p95 ≤ 10 s on the reference machine over the 60-minute live run, using the live chunk planner (FR-025).
- **SC-002**: With transcription disabled, the model-lifecycle instrumentation reports zero model loads during a full meeting, and Feature 004 acceptance results are unchanged within measurement noise.
- **SC-003**: On the reference M5 32 GB machine, a ≥ 60-minute meeting with live transcription shows a settled RSS slope below 1 MB per 10 minutes, analysis-queue depth never above its declared capacity, and reported: idle RSS, recording-only RSS, recording + recognition RSS, peak RSS, slope, queue depths, skipped-interval count, latency distribution, finalization duration, coverage and file/database growth. Unit tests are never presented as this evidence.
- **SC-004**: With recognition artificially slowed to 3× slower than real time, memory does not exceed the declared bounds, the recording completes with full-length tracks, and the final transcript covers 100% of recorded speech intervals including all skipped live intervals.
- **SC-005**: For every acceptance meeting, 100% of final segments have start < end within recorded duration, none overlaps a pause interval, and the final transcript coverage of recorded duration is reported.
- **SC-006**: Finalization of a 60-minute meeting completes without the whole recording in memory and within a real-time factor to be set in planning from measured Parakeet throughput (reported, not assumed).
- **SC-007**: Across the recovery scenarios (restart during live, restart during finalization, model load failure, runtime failure, database write failure, retry, deletion), 100% pass deterministically on repeated runs, and at least one real force-quit during finalization on the reference machine resumes and completes.
- **SC-008**: Opening a meeting whose transcript has ≥ 10,000 segments shows the first page within 1 s and never holds more than the declared window of segments in memory.
- **SC-009**: On the reused Feature 002 fixtures (English, Slovak, technical, long continuous, mixed stress, pauses) and meeting-style fixtures, the meeting pipeline's WER is within 1 absolute percentage point of the Feature 002 production dictation path on the same audio; the known mixed-language limitation is reported, not solved.
- **SC-010**: Instrumentation and logs collected during acceptance contain no transcript text, note text or audio.
- **SC-011**: All Feature 001–004 regression suites pass unchanged with transcription inactive.
- **SC-012**: Deleting a transcribed meeting leaves zero transcript rows, jobs or derived files for it and leaves other meetings byte-identical.

## Assumptions

Proposed defaults below are decisions to confirm in `$speckit-clarify`, not measurements.

- The reference machine is the owner's M5 MacBook Pro 32 GB used for Features 001–004.
- Feature 004 stores ADTS AAC-LC segment files per track; transcription decodes them incrementally. Decoding cost is part of the finalization real-time factor.
- Feature 002 production chunking uses ~15 s windows with a ~12.9 s minimum stride, so provisional latency with unchanged geometry would be on the order of 13–17 s. Decided: the live pass uses a separate, shorter-window live planner (FR-025) to meet SC-001; the exact window/stride values are set in planning from measured Parakeet throughput. Finalization keeps the production geometry.
- Decided: live and final passes both use one mixed mono analysis stream so 005 stays thin; original tracks are untouched and remain available to Feature 006 for source-based attribution. Bleed cannot produce duplicate text with a single stream; echo degradation is documented.
- Decided: finalization re-transcribes the complete meeting from durable audio, so stop, Retry and Transcribe share one deterministic path; live output is a preview. Cost is bounded by the finalization real-time factor.
- Proposed: recorded-audio timeline is authoritative; wall-clock is derived.
- Proposed: during pause, live work stops; the model stays leased up to 10 minutes of pause, then is released and reloaded on resume.
- Proposed: vocabulary snapshot at live-transcription start for the live pass; finalization takes its own snapshot at its start and records it.
- Proposed: transcript read-only; no manual edits in this feature.
- Decided backpressure: tolerate up to 10 s of lag; between 10 s and the queue capacity (30 s of audio) drop the oldest live-path audio and record a live gap; beyond that suspend live processing until the queue drains (FR-021).
- Proposed: finalization starts automatically after stop and continues when views close; an interrupted finalization resumes automatically at launch; a failed transcript is retried only by explicit user action.
- Proposed: bounds designed for 8-hour meetings; acceptance runs use 10–15 minutes during development and ≥ 60 minutes finally.
- Proposed: UI window of 200 segments with one page of lookahead; persistence batch of 50 segments or 2 s, whichever first.
- Proposed: raw recognition text retained per segment; analyzed-audio descriptor stored per transcription and per segment; no per-segment track attribution in 005.
- Seek-from-transcript is best effort and lower priority than correctness and recovery; if scope grows, it defers to a later feature.
- Existing SQLite/GRDB storage, migration patterns, confirmed deletion and content-free instrumentation are reused; exact schema belongs to planning.

## Clarification agenda

Items 1–5 and 12 were resolved in the 2026-09-18 clarification session. The remaining items keep their proposed defaults as decisions unless a later clarification pass changes them; do not settle them differently during implementation.

1. Default for new meetings. Resolved (see Clarifications): on by default, global setting plus per-meeting override.
2. Latency gate. Resolved (see Clarifications): isolated, versioned live planner; median ≤ 5 s, p95 ≤ 10 s.
3. Finalization strategy. Resolved (see Clarifications): re-transcribe everything; live output is a preview.
4. Track strategy. Resolved (see Clarifications): mixed mono stream for both passes.
5. Duplicate text from bleed. Resolved with item 4: none needed under a single mixed stream; echo limitation documented.
6. Authoritative timeline. Proposed: recorded-audio; wall-clock derived.
7. Live transcription while paused. Proposed: stops; in-flight work finishes or cancels.
8. Model during pause. Proposed: leased up to 10 minutes, then released.
9. Vocabulary snapshot timing. Proposed: at live start for live; new snapshot at finalization start, recorded.
10. Manual transcript edits. Proposed: read-only.
11. Edits vs. re-transcription. Not applicable if 10 is read-only.
12. Backpressure thresholds. Resolved (see Clarifications): 10 s tolerate / 30 s queue with gap recording / suspend at capacity.
13. Auto-start finalization after stop. Proposed: yes.
14. Continue when detail window closes. Proposed: yes.
15. Maximum supported duration. Proposed: 8 hours designed, 60 minutes measured.
16. UI segment window. Proposed: 200 segments plus one page lookahead.
17. Retain raw recognition text. Proposed: yes.
18. Per-segment track origin metadata. Proposed: analyzed-audio descriptor only; no attribution.
19. Permanently retryable while audio exists. Proposed: yes.
20. Transcribe meetings recorded without transcription. Proposed: yes, via Transcribe action.

## LocalFlow resource and failure acceptance

The [constitution](../../.specify/memory/constitution.md) and the [memory budget](../../docs/performance/memory-budget.md) remain binding. Recording overhead stays within Feature 004's 100 MB above idle; the recognition working set is measured separately on M5 and reported, not assigned. Planning MUST declare capacity and overload policy for the analysis audio queue, pending recognition jobs, provisional segment buffer, transcript UI window, persistence batch and finalization work list. At capacity, live audio is dropped and counted as a live gap; segments are never dropped silently; recording is never throttled for transcription.

Duration independence is measured: the 60-minute live run and the finalization run report RSS series, slope, peak, queue depths, skipped intervals, latency distribution, real-time factor, coverage and storage growth with hardware, OS, build, model, chunk-planner version and conditions identified. A recording-only run provides the baseline.

Offline behavior: every story works with no network and no server after the recognition model is provisioned. Model failures produce a failed transcript with guidance and an intact recording. Storage failures follow Feature 004; persistence failures fail the transcript, not the meeting. Interruptions are reconciled at launch without touching audio.

User data preservation: source tracks and notes are never modified by transcription, finalization, retry or deletion of another meeting. A finalized segment is never silently mutated. A failed save is never reported as persisted.

Run `make check` for repository validation. Hardware measurements, the force-quit run and the long-run acceptance are separate evidence and remain unverified until recorded.
