# Feature Specification: Feature 007 — Speaker Diarization and Speaker Assignment

**Feature Branch**: `main` (existing branch; no branch-creation hook configured)

**Created**: 2026-09-18

**Status**: Draft (clarified 2026-09-18, 3 questions)

**Input**: User description "Feature 006 — Speaker Diarization and Speaker Assignment" plus four reference screenshots (transcript with colored speaker names, the Assign speakers modal with name suggestions, the modal scrolled to later speakers, and a summary that uses named speakers). The description was written as Feature 006. Spec directory 006 is already used by the Notetaker UI, so this spec is numbered 007. In the input, "Feature 007" means persistent cross-meeting speaker identification and "Feature 008" means meeting summaries. This spec calls those **the future identification feature** and **the future summary feature**.

## Clarifications

### Session 2026-09-18

- Q: When does diarization run? → A: Automatically after finalization, with a setting to turn it off.
- Q: Several people sharing the Mac microphone? → A: One local speaker by default, plus a per-meeting in-room toggle that diarizes the microphone.
- Q: What happens to manual edits on rerun? → A: They carry over where turn overlap gives a safe match, and the rest are flagged for review.

## Boundary with earlier and later features

- **Feature 004** provides durable meetings with separate microphone and system-audio tracks. This feature reads those tracks and never rewrites them.
- **Feature 005** provides the finalized, timestamped transcript. This feature attaches speaker assignments to its segments and never changes segment text or timing.
- **Feature 006 (Notetaker UI)** provides the meeting detail reader with My thoughts / Transcript / Summary tabs and audio-source labels (You, Others, Unassigned). This feature replaces those source labels with meeting-local speaker labels when an accepted diarization result exists and falls back to the source labels when none does.
- **The future identification feature** will own persistent voice profiles, embeddings kept across meetings and automatic naming. This feature creates none of those.
- **The future summary feature** will use named speakers. This feature does not produce summaries, decisions or action items.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - See who said what in a completed meeting (Priority: P1)

After a meeting transcript is finalized, LocalFlow works out which anonymous speaker produced each stretch of speech, using only the meeting's durable audio on this Mac. The Transcript tab then shows each utterance under a colored label: "You" for the local microphone speaker and "Speaker 1", "Speaker 2" and so on for remote voices in system audio. The header shows a summary such as "4 SPEAKERS • 24:07".

**Why this priority**: Speaker labels are the core value. Naming, merging and correction all depend on them.

**Independent Test**: Diarize a completed fixture meeting with a local speaker and two remote speakers of known timing. Confirm that the transcript shows You, Speaker 1 and Speaker 2 in chronological order with stable colors, that the header count is 3, and that text, audio and notes are byte-for-byte unchanged.

**Acceptance Scenarios**:

1. **Given** a meeting with a finalized transcript and both tracks, **When** diarization runs, **Then** it completes locally with no network, persists speaker turns and transcript assignments, and the Transcript tab relabels segments by speaker.
2. **Given** system audio with three remote participants, **When** diarization completes, **Then** the result may contain several remote clusters. The count is inferred from the audio, and the user is never asked to enter it.
3. **Given** microphone audio, **When** diarization completes, **Then** microphone speech is attributed to the local speaker, which is shown separately from remote clusters.
4. **Given** the meeting window is closed or the app is restarted while diarization is pending or running, **When** the app is next running, **Then** the work resumes or is reconciled without the meeting being open.
5. **Given** a meeting with no accepted diarization result, **When** the Transcript tab opens, **Then** it shows the existing Feature 006 source labels and an action to run diarization.

---

### User Story 2 - Uncertain speech stays Unknown (Priority: P1)

When the audio does not show clearly who spoke a transcript segment, the segment is labeled Unknown, or Overlapping if two or more speakers talk at once. It is never pushed into the nearest cluster. Examples include overlap, very short interjections, noise, poor system audio and rapid interruptions.

**Why this priority**: Correct labels matter more than labeling everything. A wrong name in a transcript that feeds the future summary feature does more harm than a gap.

**Independent Test**: Run alignment over a fixture where one segment is split evenly between two turns, one falls in silence and one sits fully inside one speaker's turn. Confirm the labels Overlapping, Unknown and that speaker, and confirm that repeated runs give the same result.

**Acceptance Scenarios**:

1. **Given** a segment whose speech is mostly covered by one speaker's turns, **When** alignment runs, **Then** the segment is assigned to that speaker.
2. **Given** a segment where no speaker is clearly dominant, **When** alignment runs, **Then** it is marked ambiguous and shown as Overlapping or Unknown. It is not assigned to a cluster.
3. **Given** the same turns and transcript, **When** alignment runs twice, **Then** the assignments are identical.
4. **Given** many Unknown segments, **When** the header is shown, **Then** Unknown does not add to the speaker count.

---

### User Story 3 - Name speakers with Assign speakers (Priority: P1)

The transcript toolbar has an Assign speakers action. It opens a modal titled "Assign speakers" with the text "Name each voice and we'll relabel the whole transcript." The modal has one section per speaker. Each section shows the speaker's color dot and anonymous label (for example SPEAKER 1), two or three representative quotes and a name field. The modal scrolls when there are many speakers. Cancel closes it without changes. Save names applies every name at once, and the whole transcript relabels immediately. The local speaker's section is visually distinct. When named, the local speaker appears as "Name (You)".

**Why this priority**: Names turn anonymous clusters into a readable transcript, and the future summary feature needs them for owners and action items.

**Independent Test**: Open Assign speakers on a diarized meeting, type names for two speakers, save, restart the app and confirm every segment for those clusters shows the new names. Repeat, change a name, press Cancel and confirm nothing changed.

**Acceptance Scenarios**:

1. **Given** a diarized meeting, **When** the user opens Assign speakers, **Then** each speaker, including the local speaker, appears with its color, anonymous label, representative quotes and an empty or current name field.
2. **Given** edited fields, **When** the user presses Cancel, closes the modal or presses Escape, **Then** no saved name changes.
3. **Given** edited fields, **When** the user presses Save names, **Then** all names are saved together in one transaction, the modal closes and every transcript row, the header and the copied text use the new names.
4. **Given** a field left empty, **When** saving, **Then** that speaker keeps its anonymous label.
5. **Given** a saved name, **When** the user reopens Assign speakers and changes it, **Then** only the display name changes. Diarization does not rerun, and transcript text, audio and clusters are untouched.
6. **Given** the user types in a name field, **When** names were already used in this meeting or in other meetings, **Then** matching names are offered as plain-text suggestions. Picking one does not create or apply any voice identity.
7. **Given** keyboard-only use, **When** the modal is open, **Then** every field, Cancel and Save names can be reached and used from the keyboard, and each speaker is identified by text as well as color.

---

### User Story 4 - Useful representative quotes (Priority: P2)

The quotes in Assign speakers help the user recognize a voice. The app prefers several longer, clearly attributed utterances spread across the meeting, and avoids one-word acknowledgements, noise and overlapping stretches when better examples exist.

**Why this priority**: A modal that shows "OK." for every speaker cannot be used for naming.

**Independent Test**: For a fixture speaker with a mix of "OK." turns and long turns, confirm that the long, non-overlapping turns from different parts of the meeting are chosen, and that repeated opens show the same quotes.

**Acceptance Scenarios**:

1. **Given** a speaker with many utterances, **When** quotes are chosen, **Then** up to three are shown. Each is a confidently assigned segment of at least 4 words, and they are taken from different parts of the meeting where possible.
2. **Given** a speaker with only short utterances, **When** quotes are chosen, **Then** the best available ones are shown rather than none.
3. **Given** unchanged data, **When** the modal reopens, **Then** it shows the same quotes.

---

### User Story 5 - Fix diarization mistakes: merge and per-segment correction (Priority: P2)

Diarization can split one person into two clusters or give a segment to the wrong speaker. The user can merge two speakers into one, undo a merge, and change the speaker of a single transcript segment directly from that transcript row. Corrections apply to this meeting only, take priority over automatic results for display, and keep the original machine evidence.

**Why this priority**: Without correction, one diarization error makes the whole transcript untrustworthy.

**Independent Test**: Merge Speaker 1 and Speaker 4, confirm one label and a lower count, and confirm the original turns still exist. Undo the merge. Then reassign one segment to another speaker, restart, and confirm the correction persists and is recorded as manual.

**Acceptance Scenarios**:

1. **Given** two speakers, **When** the user merges one into the other, **Then** the transcript, header count, quotes and copied text treat them as one speaker, and every original speaker turn remains stored.
2. **Given** a merged speaker, **When** the user undoes the merge, **Then** both original speakers return with their earlier names and colors.
3. **Given** a transcript row, **When** the user picks a different speaker, Unknown, or a new speaker for it, **Then** only that segment's display changes, and it is stored as a manual correction alongside the automatic assignment.
4. **Given** manual corrections, **When** the app restarts, **Then** they are still in effect.
5. **Given** any correction, **Then** no model is retrained, no persistent identity is created and transcript text is not rewritten.

---

### User Story 6 - Reliable runs: status, failure, retry and recovery (Priority: P2)

Diarization shows its state: not requested, pending, running, succeeded, failed or interrupted. A failure never marks the recording or transcript as failed. The user can retry from durable audio after a failure, a model change or model provisioning. A rerun keeps the current accepted result visible until the new run succeeds, and then switches to the new result in one step. After a crash, an interrupted run is reconciled at startup, the previous accepted result is kept and retry is offered.

**Why this priority**: A post-processing step must never put the meeting's primary data at risk.

**Independent Test**: Force a failure halfway through a run and confirm the transcript, notes, audio and previous result are intact and Retry is offered. Kill the app during a run, relaunch, and confirm the run is marked interrupted and can be retried. Rerun on a meeting with an accepted result and confirm the old labels stay until the new run succeeds.

**Acceptance Scenarios**:

1. **Given** a run fails, **Then** transcription and recording states are unchanged and the failure category is shown with Retry.
2. **Given** an accepted result and a new run in progress, **When** the new run fails or is cancelled, **Then** the accepted result stays in use.
3. **Given** an accepted result and a new run, **When** the new run succeeds, **Then** it is adopted in one transaction. Existing manual names and corrections are handled as described in FR-027.
4. **Given** meeting audio is missing or corrupt, **When** diarization is requested, **Then** it is reported as unavailable or failed and the transcript is untouched.

---

### User Story 7 - Copy a speaker-labeled transcript (Priority: P3)

Copy produces plain text in which each speaker change starts with that speaker's current display name, then the utterances. Hidden diarization data such as confidence values and cluster keys is not included.

**Why this priority**: Pasting a labeled transcript elsewhere is a common follow-up, and it is cheap once labels exist.

**Independent Test**: Copy a named, diarized transcript and compare it with the expected "Name:\ntext" blocks.

**Acceptance Scenarios**:

1. **Given** a named, diarized transcript, **When** copied, **Then** the output groups consecutive segments under current display names in chronological order.
2. **Given** an undiarized transcript, **When** copied, **Then** the existing Feature 006 copy behavior is unchanged.

---

### Edge Cases

- Meeting with no remote speech (system track silent): the result contains only the local speaker and the count is 1.
- Meeting with no microphone speech, or a missing or failed microphone track: only remote clusters are produced and no local speaker is invented.
- Local voice echo or bleed in system audio: not fully solved. Such speech may form or join a remote cluster, or be marked ambiguous. Enough evidence (source track per turn and per cluster) is kept for the future identification feature to detect it.
- Several people sharing the Mac microphone in a room: they appear as "You" by default, and the user can turn on the in-room toggle (FR-009) to diarize the microphone.
- A single speaker split into many clusters, or two similar voices merged into one: handled with the correction tools in User Story 5.
- Paused meetings: speaker turns must use the meeting's recorded timeline, the same one the transcript uses, and never span a pause gap.
- Very long meetings that the engine can only process in windows: labels from different windows are not assumed to match. Windows are reconciled from acoustic evidence only, uncertainty is kept, and nothing is truncated silently.
- Meeting deleted while diarization is running: the run is cancelled and all diarization data is removed with the meeting.
- The transcript is re-finalized (Feature 005 retry) after diarization: existing assignments no longer match the new segments. The meeting shows source labels and offers diarization again. Stale assignments are never shown against new text.
- The diarization model is not provisioned or is offline: the run is reported as unavailable with guidance. Transcription is unaffected.
- A name containing only whitespace is treated as empty. Names are trimmed and limited in length.
- Two speakers given the same name: allowed. Both show that name but stay separate clusters until the user merges them explicitly. The modal points out the duplicate and offers a merge.
- Rapid tab switching or paging during relabel: the UI never shows labels from an older result next to a newer one.

## Requirements *(mandatory)*

### Functional Requirements

**Running diarization**

- **FR-001**: The system MUST diarize a completed meeting on this Mac using its durable Feature 004 audio. It MUST NOT use transcript text to decide who spoke. Transcript timing is used only afterward, for alignment.
- **FR-002**: Diarization MUST start automatically after transcript finalization, once speech recognition has been released. A setting, on by default, MUST let the user turn automatic diarization off. A manual run and retry action MUST always be available.
- **FR-003**: Diarization MUST NOT require the meeting to stay open. It MUST be restart-safe and MUST be cancellable.
- **FR-004**: The system MUST infer the number of speakers automatically. Manual speaker-count entry MUST NOT be required. The inferred count MUST be recorded with the run.
- **FR-005**: The system MUST support meetings with 2–6 total speakers for acceptance, and it MUST NOT impose a hard-coded speaker limit.
- **FR-006**: Only post-meeting diarization is in scope. Live transcript text during recording remains unlabeled.

**Source-aware attribution**

- **FR-007**: Microphone-track speech MUST be attributed to a distinct local speaker source. System-track speech MUST be diarized into zero or more remote meeting-local clusters.
- **FR-008**: Each cluster and each turn MUST record its source track. The system MUST NOT assume that system audio never contains the local voice, and MUST NOT permanently mix the two tracks. Temporary bounded analysis audio is allowed and MUST be cleaned up.
- **FR-009**: By default the microphone track MUST map to exactly one local speaker ("You"). A per-meeting "in-room meeting" toggle MUST let the user diarize the microphone track too, producing local speakers (Local 1, Local 2…) that are kept distinct from remote clusters. Changing the toggle triggers a rerun under FR-030.

**Speaker turns and overlap**

- **FR-010**: Speaker turns MUST be stored as time intervals independent of transcript text, each with run, cluster, start, end, source track, and confidence and overlap information where the engine provides them.
- **FR-011**: Stored turns MUST be allowed to overlap. The data model MUST NOT assume one speaker per instant.
- **FR-012**: The system MUST NOT fabricate a confidence score the engine does not provide. Where there is no score, it uses explicit quality classes only when they are justified.

**Alignment**

- **FR-013**: The system MUST align every finalized transcript segment to exactly one of: a speaker (automatic), Unknown, or Ambiguous/Overlapping. The alignment MUST be deterministic and MUST NOT modify segment text or timing.
- **FR-014**: A segment MUST be assigned to a speaker only when that speaker clearly dominates the segment's time span. Proposed default: the speaker's turns cover at least 60% of the segment's duration and at least twice the runner-up's coverage. Otherwise the segment is Ambiguous if two or more speakers overlap it, or Unknown if coverage is insufficient. Planning MUST confirm the thresholds against the evaluation set.
- **FR-015**: Each assignment MUST record whether it is automatic or manual and keep the alignment evidence (coverage values, and confidence where available).

**Display**

- **FR-016**: When an accepted result exists, the Transcript tab MUST show chronological rows labeled with each speaker's display name and color. It MUST use "You" for an unnamed local speaker, "Name (You)" for a named one, "Speaker N" for unnamed remote clusters, and Unknown or Overlapping for unassigned segments.
- **FR-017**: Each speaker MUST get a stable color that survives restarts and remains readable in light and dark mode. Colors MUST be allocated deterministically by order of the speaker's first appearance. Color MUST NOT be used as identity, and labels MUST NOT rely on color alone.
- **FR-018**: The transcript header MUST show the current speaker count and meeting duration (for example "4 SPEAKERS • 24:07"). The count reflects merges and corrections and excludes Unknown and Ambiguous.
- **FR-019**: The transcript MUST remain paged and incremental. Relabeling MUST NOT load every segment or turn of a long meeting at once.
- **FR-020**: Existing transcript search MUST keep working and MAY also match speaker display names. Copy MUST produce speaker-labeled plain text without hidden metadata.

**Naming and correction**

- **FR-021**: The Assign speakers modal MUST provide a heading and explanation, one section per speaker with color dot, anonymous label, representative quotes and name field, scrolling, keyboard navigation, Cancel and Save names. Save names MUST be disabled only when validation fails (for example, a name exceeds 80 characters).
- **FR-022**: Cancel MUST make no changes. Save names MUST apply all names in one transaction, and the transcript MUST relabel immediately.
- **FR-023**: Up to 3 representative quotes per speaker MUST be selected deterministically. The selection prefers confidently assigned segments of at least 4 words, avoids overlap and noise, and spreads across the meeting. When nothing better exists, it falls back to the best available segments.
- **FR-024**: Renaming MUST be a metadata-only change. It MUST NOT rerun diarization or change text, audio or clusters.
- **FR-025**: Users MUST be able to merge two speakers, and undo the merge, from the Assign speakers modal. Merges MUST keep every original cluster and turn and MUST be recorded as manual corrections.
- **FR-026**: Users MUST be able to change a single segment's speaker, including to Unknown or a new speaker, from that transcript row. The correction is manual, applies to this meeting only and takes priority over the automatic assignment for display. The automatic assignment MUST be kept.
- **FR-027**: When a new diarization run is adopted for a meeting that has manual names or corrections, the system MUST carry them over to the new clusters wherever turn overlap gives an unambiguous match. Names and corrections that cannot be matched safely MUST NOT be applied. They are flagged for review in Assign speakers and are never guessed. Planning defines the overlap rule deterministically.
- **FR-028**: Name suggestions MAY come from names already used in other meetings. They are plain text only and MUST NOT trigger automatic naming, voice matching or any stored identity.

**Lifecycle, reliability and data**

- **FR-029**: Diarization state MUST be explicit per meeting: not requested, pending, running, succeeded, failed or interrupted. A failed or interrupted diarization MUST NOT change recording or transcription state.
- **FR-030**: A rerun MUST NOT replace the accepted result until it succeeds. Adoption MUST happen atomically.
- **FR-031**: At startup the system MUST mark any running diarization as interrupted, keep the previous accepted result and offer retry. Missing or corrupt audio MUST be reported without changing the transcript.
- **FR-032**: The diarization model MUST be loaded and released only through the central model lifecycle. It MUST NOT be held at the same time as the speech-recognition model by default: recognition is released before diarization loads, and diarization is released when the run ends, fails or is cancelled.
- **FR-033**: Diarization memory MUST stay bounded regardless of meeting duration. The system MUST NOT load a full recording into memory or keep intermediate results without limit. Windowed processing MUST reconcile clusters across windows deterministically using acoustic evidence and MUST keep uncertainty. Meetings MUST NOT be truncated silently.
- **FR-034**: Diarization data MUST be stored with explicit migrations: runs (engine, model, model version, pipeline version, state, timestamps, failure category, inferred count), clusters, turns, assignments and manual corrections. Speaker names MUST NOT be written into transcript text.
- **FR-035**: Deleting a meeting MUST remove its runs, clusters, turns, assignments, names and corrections. Any temporary analysis audio MUST also be removed.
- **FR-036**: No meeting audio, embeddings, turns or names may leave the Mac. Nothing may be sent to the LocalFlow server, the LLM or any cloud or third-party service. No network is needed after the model is provisioned. No speaker embedding may persist beyond a run as a cross-meeting profile.
- **FR-037**: Content-free instrumentation MUST record: model load and release duration, diarization duration, real-time factor, audio duration processed, inferred speaker count, turn count, overlap turn count, Unknown and Ambiguous assignment counts, peak RSS, window count, cross-window reconciliation counts, and manual rename, merge and correction counts. It MUST NOT log transcript text, names, audio, embeddings or quote content.
- **FR-038**: When diarization is inactive, the behavior of Features 001–006 MUST remain unchanged.

### Key Entities

- **Diarization Run**: One attempt to diarize a meeting. Records engine, model and version, pipeline version, state, start and completion times, failure category and inferred speaker count. A meeting has at most one accepted run and may also have one pending run.
- **Meeting Speaker (Cluster)**: An anonymous, meeting-local voice produced by a run. Records a stable key within the meeting, source classification (local microphone or remote system), color index, an optional user display name, quality information where available, and merge state. It is not a person and not a cross-meeting identity.
- **Speaker Turn**: An interval (start, end) during which a cluster was active, with source track, and confidence and overlap information where available. Turns may overlap. They are machine evidence and are never deleted by user corrections.
- **Transcript Speaker Assignment**: The link from one Feature 005 transcript segment to a speaker, Unknown or Ambiguous, marked automatic or manual, with alignment evidence and a correction timestamp.
- **Speaker Correction**: A record of a user action (rename, merge, unmerge or segment reassignment) with enough detail to replay or undo it, stored separately from machine evidence.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: On the synthetic fixtures with known timing (local + 1, + 2 and + 3 remote speakers), at least 90% of the speech time in segments given a speaker is attributed to the correct speaker. Wrong-speaker assignments are under 5% of segments; uncertain segments must go to Unknown or Ambiguous instead.
- **SC-002**: Where a fixture has valid ground truth, speaker confusion, missed speech, false alarm and diarization error rate are reported. No error rate is reported for material without ground truth.
- **SC-003**: A user can name all speakers in a four-speaker meeting and see the relabeled transcript in under 1 minute. Relabeling after Save names appears within 1 second.
- **SC-004**: On the M5 32 GB reference machine, diarizing a 60-minute meeting reports model load time, model RSS increase, peak RSS, RSS after release, duration, real-time factor, window count, speaker count and Unknown/Ambiguous counts. RSS slope over the run is below 1 MB per 10 minutes. RSS after release returns to within 20 MB of the pre-diarization baseline. Short fixtures are never presented as evidence of bounded operation.
- **SC-005**: Pass/fail thresholds for real-time factor and peak model memory are set in planning from measured runs and are then met on the short, 30–60 minute and 60-minute acceptance runs. Bounds are designed for the 8-hour maximum meeting defined in Feature 005.
- **SC-006**: In fault-injection tests (failure mid-run, crash mid-run, missing audio, rerun failure), the transcript, notes, audio and the previously accepted result are preserved in 100% of cases.
- **SC-007**: Names, merges and corrections persist across restarts in 100% of test cases, and the original automatic evidence is still retrievable afterward.
- **SC-008**: No network request is made during diarization, naming or correction, and resource logs contain no transcript text, names, quotes or audio.
- **SC-009**: All Feature 001–006 regression tests stay green.

## Assumptions

- The initial engine is the local diarization capability of the on-device audio library LocalFlow already ships for speech recognition. The engine sits behind an app-owned boundary (prepare, diarize, cancel, release) so the meeting domain does not depend on its types. The final choice is confirmed in planning.
- Diarization is diarization only. Clusters, names and corrections are meeting-local. No voice profile, and no embedding that outlives a run, is created. Seeding the future identification feature from confirmed names will require explicit user confirmation in that feature.
- Remote system audio and the microphone are diarized separately. There is no combined cross-track reconciliation pass beyond keeping source evidence for later echo handling.
- Overlapping or ambiguous segments appear as one row labeled Overlapping or Unknown. Split multi-speaker rows are out of scope.
- The acceptance range is 2–6 total speakers. The design is for the 8-hour maximum from Feature 005, and measured acceptance uses 60 minutes, matching Features 004 and 005.
- The local speaker is labeled "You" by default. Once named, it shows "Name (You)". With the in-room toggle on, local speakers show "Local N" until named.
- The existing Feature 006 reader, tabs, toolbar, paging, search and copy are extended, not replaced. The Summary tab content stays out of scope.
- The evaluation set uses synthetic controlled multi-speaker fixtures, rights-cleared conversational speech where suitable, and consented owner meetings. It is not a new research corpus.
- Out of scope: persistent speaker profiles or embeddings, cross-meeting recognition, contact or calendar matching, enrollment, automatic naming, summaries, decisions, action items, Ask Meeting, semantic search, backup, meeting-platform participant APIs and cloud diarization.

## LocalFlow resource and failure acceptance

- **Bounded duration**: Audio is decoded and analyzed incrementally in bounded windows. Per-window intermediates are released after their turns are persisted. Turn and assignment writes are batched with explicit capacity. Cross-window reconciliation state is bounded by the number of clusters, not by duration.
- **Queueing**: At most one diarization runs at a time. Other requests wait in a bounded per-meeting queue that deduplicates requests. Speech recognition work, including live meeting transcription and dictation, has priority. Diarization yields the model lifecycle to it and resumes later, with an explicit overload policy.
- **Model ownership**: The central model lifecycle coordinator authorizes diarization model load, use, cancellation and release. By default it is never held together with the speech-recognition model.
- **Offline**: Works fully offline once the model is provisioned. A missing model is reported as unavailable and never triggers a silent download.
- **Permissions**: No new permissions are needed. Existing recordings are read from app storage.
- **Data preservation**: Audio, transcript, notes and the previously accepted diarization result are never modified by a failed, interrupted or cancelled run. Manual corrections are never overwritten by machine output.
- **Measurement**: The metrics in FR-037 and SC-004, reported with hardware, OS, build, model and conditions. Unmeasured targets are not claimed as achieved.
