# Feature Specification: Persistent Speaker Identification

**Feature Branch**: `main` (existing branch; no branch-creation hook configured)

**Created**: 2026-09-20

**Status**: Draft (clarified 2026-09-20, 8 questions)

**Input**: User description "Feature 007 — Persistent Speaker Identification". The description numbers itself 007 and calls the diarization feature 006, but spec directory 007 already holds speaker diarization, so this spec is numbered 010. Where the input says "Feature 006" this spec means **the diarization feature (spec 007)**; where it says "Feature 008" this spec means **the future summary feature**.

## Clarifications

### Session 2026-09-20

- Q: Historical display after deleting a known speaker? → A: Keep the confirmed name as ordinary meeting-local metadata, unlinked.
- Q: Samples whose only source meeting is deleted? → A: Retain as derived data, marked provenance-unavailable.
- Q: Default state of the global recognition setting? → A: On by default; nothing runs until the first explicit Remember.
- Q: How do samples get added when the user confirms a Possible match or corrects to an existing known speaker? → A: Only an explicit Remember action adds samples. Confirm and correction show an optional "Also remember this voice sample" control, off by default; automatic Recognized assignments never add samples.
- Q: What happens to identity when two meeting-local speakers with different assignments are merged? → A: Same known speaker (or one side without identity): that identity survives. Different known speakers, or a Possible match on either side: merged speaker becomes Unknown and the user is prompted to choose.
- Q: How is an individual voice sample identified in Known speakers for removal? → A: Source meeting title and date, total speech duration and a quality label; provenance-unavailable samples show "Source meeting deleted" with the original date.
- Q: Hard delete or tombstone for a deleted known speaker? → A: Hard delete; the record and all samples are physically removed, historical meetings keep only the copied name, and "deleted" is not a known-speaker state.
- Q: Identify a newly remembered voice in earlier meetings automatically? → A: One-time prompt after enrollment ("Look for this voice in past meetings?"); if accepted, rerun only meetings that still have at least one Unknown remote speaker, one meeting at a time.

## Boundary with earlier and later features

- **Spec 004 (meeting capture)** provides durable meetings with separate microphone and system-audio tracks. This feature reads audio inside accepted speaker turns and never rewrites tracks.
- **Spec 005 (meeting transcription)** provides the finalized transcript. This feature never changes segment text or timing.
- **Spec 007 (speaker diarization)** provides meeting-local anonymous speakers ("Speaker 1", "Speaker 2"), the local "You" speaker from track origin, manual naming, merging and per-segment correction. This feature adds a persistent identity layer on top of those meeting-local speakers and does not change how clusters are produced.
- **The future summary feature** will consume the transcript, speaker assignments, and the identity certainty and origin this feature records. It is not built here.

## Vocabulary

Four ideas stay separate throughout this specification and must not collapse into one name string:

1. **Meeting-local speaker (cluster)**: an anonymous voice found by diarization in one meeting.
2. **Known speaker (persistent profile)**: a person the user has explicitly asked LocalFlow to remember, with one or more confirmed voice samples.
3. **Identity assignment**: the link, within one meeting, between a meeting-local speaker and a known speaker (or the explicit absence of one).
4. **Assignment origin and certainty**: why LocalFlow believes the link, and how sure it is.

Match certainty is shown to the user as one of three words: **Recognized** (high), **Possible match** (medium) and **Unknown** (low or none). Raw similarity numbers are not shown as percentages or probabilities.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Remember a voice only when asked (Priority: P1)

After naming a meeting-local speaker in Assign speakers, the user sees an offer: "Remember this voice for future meetings?" with Remember and Not now. Choosing Remember creates a known speaker from that name and stores eligible voice samples from that meeting. Choosing Not now keeps the name as ordinary meeting metadata and stores nothing that could recognize the voice later. Typing a name alone never creates a known speaker.

**Why this priority**: Enrollment is the entry point for everything else, and the explicit consent step is the privacy guarantee the whole feature rests on.

**Independent Test**: Name "Speaker 2" in a fixture meeting, decline the offer, and confirm no known speaker or voice sample exists. Repeat and accept; confirm one known speaker exists with at least one sample whose source is that meeting and cluster, and that the meeting-local assignment is now Confirmed.

**Acceptance Scenarios**:

1. **Given** a meeting-local speaker with no name, **When** the user types a name and saves without choosing Remember, **Then** the meeting shows the name, no known speaker is created, and no voice sample is stored.
2. **Given** a meeting-local speaker the user has just named, **When** the user chooses Remember, **Then** a known speaker with that name exists, eligible samples from that cluster are stored with their source meeting and cluster, and the assignment origin is recorded as "new profile created".
3. **Given** the cluster has no speech that meets the enrollment quality rules, **When** the user chooses Remember, **Then** the known speaker is still created with zero samples, the user is told that no usable voice sample was found, and the speaker is not eligible for recognition until a sample exists.
4. **Given** the offer to remember a voice, **When** it is shown, **Then** it states in plain words that LocalFlow will store data that can recognize this voice in future meetings on this Mac.

---

### User Story 2 - Recognize a known voice in a later meeting (Priority: P1)

After diarization of a new meeting completes, LocalFlow compares each eligible remote meeting-local speaker against known speakers on this Mac. A Recognized match names the speaker automatically; a Possible match is shown as a suggestion with a question mark; anything weaker stays "Speaker N". This runs after diarization has finished and its model has been released, then releases its own model.

**Why this priority**: Automatic recognition is the product value. Its conservative behavior is what makes it safe to ship.

**Independent Test**: Enroll a known speaker from meeting A. Run identification on meeting B, which contains the same person, a different person and one very short cluster. Confirm the same person is Recognized or a Possible match according to the calibrated tiers, the different person stays Unknown, the short cluster stays Unknown, and the run performs no network activity.

**Acceptance Scenarios**:

1. **Given** at least one recognition-enabled known speaker and a finished diarization, **When** identification runs, **Then** every remote meeting-local speaker receives exactly one identity assignment in state Recognized, Possible match or Unknown.
2. **Given** a cluster whose best candidate meets the high tier and the required margin over the second candidate, **When** identification completes, **Then** the transcript shows the known speaker's name, and the assignment origin is "automatic match".
3. **Given** a cluster whose best candidate meets only the medium tier, **When** identification completes, **Then** the transcript shows "Name?" and the Assign speakers modal offers Confirm, Choose another and Keep Unknown. Nothing is treated as confirmed.
4. **Given** two known speakers whose scores are nearly equal (e.g. 0.82 and 0.81 on the same scale), **When** identification completes, **Then** the cluster is at most a Possible match and is never automatically named.
5. **Given** no known speaker meets the minimum suggestion tier, **When** identification completes, **Then** the speaker stays "Speaker N" and no name is suggested, even if one candidate is numerically closest.
6. **Given** the local "You" speaker, **When** identification runs, **Then** its identity comes from track origin, not from voice comparison.

---

### User Story 3 - Confirm, reject or correct an identity (Priority: P1)

The user can confirm a Possible match, reject it, or change any automatic or suggested identity to a different known speaker, a new name, or Unknown. Corrections update the meeting, record what was rejected, and never feed samples into the wrong person's profile.

**Why this priority**: Automatic identities are not truth. Without cheap correction, a wrong name would flow into future summaries and action items.

**Independent Test**: Start from a meeting where Speaker 2 was automatically named Tomáš. Change it to Lukáš. Confirm the transcript shows Lukáš, the assignment origin is "manual correction", Tomáš's profile gained no sample from this meeting, and Lukáš's profile gained eligible samples only if the user turned on "Also remember this voice sample".

**Acceptance Scenarios**:

1. **Given** a Possible match, **When** the user chooses Confirm, **Then** the assignment becomes Confirmed with origin "user confirmation", and eligible samples from this meeting are added to that known speaker only if the user turned on "Also remember this voice sample" (off by default).
2. **Given** a Possible match, **When** the user chooses Keep Unknown, **Then** the assignment becomes Unknown, the rejected candidate is recorded as rejected for this cluster, and it is not suggested again for this cluster on rerun.
3. **Given** an automatic identity, **When** the user changes it to another known speaker, **Then** the original match is recorded as rejected, the new assignment has origin "manual correction", and no sample from this cluster is ever added to the rejected known speaker.
4. **Given** a Confirmed or manually corrected assignment, **When** identification is rerun, **Then** the manual assignment is kept and is not overwritten by a new automatic result.

---

### User Story 4 - Choose an existing known speaker while naming (Priority: P2)

When naming a meeting-local speaker, the user can pick from the list of known speakers instead of typing. Picking one links the meeting-local speaker to that known speaker and never creates a duplicate profile. Typing a name that exactly matches an existing known speaker offers to use that speaker rather than silently creating a second one.

**Why this priority**: Reuse keeps the known-speaker list clean and is the manual fallback whenever automatic recognition falls short.

**Independent Test**: With three known speakers, open Assign speakers, pick "Lukáš Kocman" for Speaker 3, and confirm the assignment is Confirmed with origin "manual profile selection" and that the known-speaker count is unchanged.

**Acceptance Scenarios**:

1. **Given** known speakers exist, **When** the user opens the name field, **Then** the list of known speakers is offered for selection.
2. **Given** the user picks an existing known speaker, **When** they save, **Then** the assignment is Confirmed, its origin is "manual profile selection", and the number of known speakers is unchanged.
3. **Given** the user types a name identical to an existing known speaker and chooses Remember, **When** they save, **Then** LocalFlow asks whether this is the same person or a new one with the same name, and creates a second profile only if the user chooses new.

---

### User Story 5 - Manage known speakers (Priority: P2)

A "Known speakers" section lists each known speaker with their name, number of confirmed voice samples and whether recognition is enabled. The user can rename, disable or enable recognition per speaker, remove an individual sample, and delete the speaker. A global setting "Remember and recognize speakers across meetings" turns the whole feature off without touching diarization or manual naming.

**Why this priority**: Users must be able to see and undo what LocalFlow remembers about people's voices. This is required for the feature to be trustworthy, but it is not needed to demonstrate recognition itself.

**Independent Test**: Create three known speakers, disable recognition for one, rerun identification on a meeting containing that person, and confirm they are not named or suggested. Delete a speaker and confirm zero samples remain for it and historical transcripts are unchanged. Turn the global setting off and confirm diarization and manual naming still work while no identification runs and no enrollment offer appears.

**Acceptance Scenarios**:

1. **Given** known speakers exist, **When** the user opens Known speakers, **Then** each shows name, sample count and recognition state, and no raw voice data is displayed.
2. **Given** recognition is disabled for one known speaker, **When** identification runs, **Then** that speaker is neither automatically assigned nor suggested, and existing historical assignments are unchanged.
3. **Given** the user deletes a known speaker, **When** deletion completes, **Then** its profile and every associated voice sample are gone, it can never be matched again, transcript text of every meeting is unchanged, and historical display follows the policy in FR-030.
4. **Given** the global setting is off, **When** a meeting finishes diarization, **Then** no identification runs, no enrollment offer is shown, existing known speakers remain stored, and all diarization and manual naming behavior from spec 007 is unchanged.
5. **Given** the user removes one sample from a known speaker, **When** the change is saved, **Then** the sample count drops by one and the sample no longer influences matching.
6. **Given** a known speaker with samples, **When** the user opens its sample list, **Then** each sample shows source meeting title and date, speech duration and a quality label, and samples whose meeting was deleted show "Source meeting deleted" with their date.

---

### User Story 6 - Rerun identification without redoing transcription (Priority: P2)

From a meeting, the user can rerun identification alone. This is useful after adding known speakers, enabling the feature later, a failed run, or a model change. Rerun uses the durable audio, the accepted diarization result and the current known speakers. Accepted automatic results are replaced only when the new run completes; manual assignments are kept.

**Why this priority**: Recognition improves as the library grows; without rerun, older meetings never benefit and failed runs are dead ends.

**Independent Test**: Run identification with an empty library (all Unknown), enroll a speaker from another meeting, rerun, and confirm the person is now named without transcription or diarization being repeated and without transcript changes.

**Acceptance Scenarios**:

1. **Given** a meeting with an accepted diarization result, **When** the user chooses Rerun identification, **Then** neither transcription nor diarization is repeated and the transcript text is unchanged.
2. **Given** a rerun in progress, **When** it fails or is interrupted, **Then** the previously accepted assignments remain in effect and the incomplete run leaves no partial assignments.
3. **Given** a rerun completes, **When** results are adopted, **Then** automatic and suggested assignments are replaced, and Confirmed, manually selected, corrected and Keep Unknown decisions are preserved.
4. **Given** the user has just created a known speaker with at least one sample, **When** enrollment completes, **Then** LocalFlow asks once "Look for this voice in past meetings?"; declining changes nothing, and accepting queues a rerun for each meeting that still has at least one Unknown remote speaker, processed one meeting at a time.
5. **Given** a past-meeting search is queued, **When** a meeting has no Unknown remote speakers, **Then** it is skipped and its assignments are untouched.

---

### User Story 7 - Enroll the local user's own voice (Priority: P3)

The user can explicitly remember their own voice from the local microphone track. This is never done automatically. "You" continues to be identified by track origin; the local profile exists so a later feature can detect local-voice echo in system audio.

**Why this priority**: It completes the model without changing today's behavior, and it lays the groundwork for echo handling later.

**Independent Test**: Enroll the local voice from a meeting, confirm a known speaker marked as the local user exists with samples from the microphone track, and confirm "You" labeling behaves exactly as before in a meeting with and without that profile.

**Acceptance Scenarios**:

1. **Given** a meeting with local microphone speech, **When** the user chooses to remember their own voice, **Then** a known speaker flagged as the local user is created from microphone samples only.
2. **Given** the local profile exists, **When** a new meeting is processed, **Then** the "You" label still comes from track origin and the local profile is not used to relabel system-audio speakers.

---

### Edge Cases

- A cluster has enough speech in total but every region is short, overlapping or noisy: no sample is enrolled and the user is told why.
- Two known speakers score within the margin of each other: at most a Possible match; the modal shows both candidates under Choose another.
- A known speaker has samples only from an older embedding model version: those samples are not compared against new-model embeddings; the speaker shows "needs re-enrollment" until re-extracted from a surviving source meeting or a new confirmation.
- The user renames a known speaker: every historical meeting that links to that speaker shows the new name; meetings with only a typed name (no link) are unchanged.
- Identification is interrupted by quit, crash or storage error: transcript, diarization and known speakers are intact; the run is discarded or resumed; rerun is available.
- The library grows to about 100 known speakers with many samples each: identification still completes within the acceptance budget and memory bounds; sample count per speaker is capped.
- A meeting is deleted: its identity assignments are deleted; known speakers remain; samples sourced from it stay active but can no longer be re-extracted (FR-031).
- The global setting is turned back on: existing known speakers are used again; meetings processed while it was off are not identified retroactively unless the user reruns.
- The past-meeting search after enrollment is interrupted (quit, crash, storage error): completed meetings keep their adopted results, the in-flight meeting keeps its previous assignments, and the remaining queue is dropped; the user can rerun individual meetings.
- Identification runs with zero recognition-enabled known speakers: the run completes immediately with all speakers Unknown and no model is loaded.
- The user merges two meeting-local speakers (spec 007): if both link to the same known speaker, or only one side has an identity, that identity survives on the merged speaker. If they link to different known speakers, or either side is a Possible match, the merged speaker becomes Unknown with origin "kept unknown" and Assign speakers prompts the user to choose. Undoing the merge restores both original assignments.
- Diarization was rerun and produced new clusters: identity assignments tied to superseded clusters are discarded with them; identification reruns on the new accepted result.

## Requirements *(mandatory)*

### Functional Requirements

**Enrollment and consent**

- **FR-001**: A known speaker MUST be created only through an explicit user action ("Remember this voice" or an explicit create action in Known speakers). Typing or choosing a meeting-local name MUST NOT create one.
- **FR-002**: The enrollment offer MUST state that LocalFlow will store data that can recognize this voice in future meetings on this Mac.
- **FR-003**: Voice samples MUST be taken only from speech regions of the confirmed cluster that meet the enrollment quality rules (minimum duration, no overlap, adequate diarization confidence where available, not clipped or obviously noisy). One-word acknowledgements and overlapping speech MUST be excluded. Exact thresholds are set in planning.
- **FR-004**: One confirmation MAY yield several samples from distinct regions of the meeting, preferring regions spread across the meeting.
- **FR-005**: Each known speaker MUST support multiple samples across meetings. Samples MUST NOT be averaged into one vector unless the chosen model's documented guidance supports it.
- **FR-006**: Active samples per known speaker MUST be capped. When the cap is reached, the policy MUST keep higher-quality and more diverse samples and retire lower-quality or outlier ones. The cap is set in planning.
- **FR-007**: Samples MUST NOT be added to a known speaker from a cluster whose match to that speaker was rejected or corrected away.
- **FR-008**: Confirming a suggestion or correcting to another known speaker MUST NOT add samples by itself. Both actions MUST offer an "Also remember this voice sample" control that is off by default; only when it is on are eligible samples added to the resulting known speaker. Automatic Recognized assignments MUST NEVER add samples. Low-quality regions MUST NOT be added merely because the control was on.

**Matching and certainty**

- **FR-009**: Identification MUST produce, for each remote meeting-local speaker, one assignment in exactly one state: Recognized (automatic), Possible match (suggested), Confirmed, Rejected-to-Unknown, or Unknown.
- **FR-010**: Automatic naming MUST require both a model-specific high threshold and a minimum margin between the best and second-best candidates. Failing either MUST yield at most a Possible match.
- **FR-011**: A named suggestion MUST require a model-specific minimum threshold. Below it the speaker MUST stay Unknown; the nearest candidate MUST NOT be shown.
- **FR-012**: Thresholds and margins MUST be derived from a calibration corpus of same-person and different-person comparisons for the specific model and version, and MUST be stored with the model identity they apply to. They MUST NOT be chosen by intuition or hard-coded in UI code.
- **FR-013**: Matching policy MUST consider sample quality and the number of supporting samples on a candidate in addition to the raw score.
- **FR-014**: Certainty MUST be shown to users as Recognized, Possible match or Unknown. Similarity values MUST NOT be presented as percentages or probabilities unless calibration has been demonstrated.
- **FR-015**: Known speakers with recognition disabled MUST be excluded from matching. When the global setting is off, no matching and no enrollment MUST occur.
- **FR-016**: The local "You" speaker MUST be identified by track origin. Voice matching MUST NOT be required for, or override, local identity.
- **FR-017**: A local-user profile MAY exist only through explicit enrollment. This feature MAY record its similarity to system-audio speech as supporting evidence but MUST NOT delete or relabel system-audio speech on that basis alone.

**Assignment origin and auditability**

- **FR-018**: Each identity assignment MUST record its origin as one of: automatic match, user confirmation, manual profile selection, new profile created, manual correction, kept unknown.
- **FR-019**: Each automatic or suggested assignment MUST record the score, the model identity and the threshold policy version that produced it.
- **FR-020**: Rejected candidates MUST be recorded per cluster so that a rerun does not re-suggest a rejected candidate for the same cluster.
- **FR-021**: The transcript and assignment data exposed to later features MUST carry the state and origin so a consumer can tell Confirmed and Recognized from Possible match and Unknown.

**Runs, rerun and recovery**

- **FR-022**: Identification MUST run after diarization has completed and released its model, and MUST release its own model when finished, cancelled or failed.
- **FR-023**: Identification MUST be rerunnable without repeating transcription or diarization, using durable audio, the accepted diarization result and current known speakers.
- **FR-023a**: After a known speaker is created with at least one sample, LocalFlow MUST offer once to look for that voice in past meetings. If accepted, it MUST queue reruns only for meetings that have at least one remote speaker in state Unknown, MUST process them one meeting at a time under the single-model rule, and MUST NOT rerun meetings where every remote speaker already has a named or Confirmed identity. Declining MUST change nothing. There MUST be no automatic backfill without this prompt.
- **FR-024**: Automatic and suggested assignments MUST be replaced only when a new run completes successfully. Manual decisions (Confirmed, manual selection, correction, kept unknown) MUST survive reruns.
- **FR-025**: An interrupted or failed run MUST leave transcript, diarization, known speakers and previously accepted assignments intact, and MUST NOT leave partial automatic assignments in effect.
- **FR-026**: Identification MUST NOT alter transcript text, segment timing, speaker turns or audio.
- **FR-026a**: On a merge of two meeting-local speakers, the merged speaker MUST end with exactly one effective identity assignment: the shared identity when both sides link to the same known speaker or only one side has an identity; otherwise Unknown, with the user prompted to choose. Undoing the merge MUST restore both original assignments.

**Model versioning**

- **FR-027**: Every sample MUST record model identity, model version, vector dimension, extraction pipeline version, quality metadata, source meeting, source cluster, source time ranges and creation date.
- **FR-028**: Samples from incompatible model versions MUST NOT be compared. A known speaker whose samples are all incompatible with the current model MUST be shown as needing re-enrollment and MUST NOT be matched until compatible samples exist.
- **FR-029**: A model change MUST NOT overwrite or discard older samples. Re-extraction from surviving source meetings MAY be offered as an explicit action.

**Deletion and retention**

- **FR-030**: Deleting a known speaker MUST physically remove its record and all its samples (no tombstone or hidden "deleted" state) and its future matching eligibility, and MUST NOT change any transcript text. Historical meetings MUST keep the confirmed name as ordinary meeting-local metadata with no link to any profile, exactly as if the user had typed the name and chosen Not now.
- **FR-031**: Deleting a meeting MUST delete its identity assignments and MUST NOT delete known speakers. Samples whose only source is the deleted meeting MUST be retained as derived data and marked provenance-unavailable, so they keep working for matching but are excluded from any future re-extraction.
- **FR-032**: Removing a single sample MUST be possible from Known speakers and MUST take effect on the next matching run.
- **FR-033**: No orphaned samples MAY remain after any deletion.

**Privacy and storage**

- **FR-034**: Voice samples and comparisons MUST stay on this Mac. Samples, audio and names MUST NOT be sent to the control server, the LLM server, any cloud or analytics service, and MUST NOT be included in ordinary exports or logs.
- **FR-035**: Samples MUST live in LocalFlow's private structured storage, never in user preferences or plain text. Encryption beyond standard app-private protection is a planning decision, not a requirement here.
- **FR-036**: Identification and enrollment MUST work offline once the model is provisioned.
- **FR-037**: Diagnostics MAY record counts and durations (model load, samples extracted, comparisons, automatic, suggested, unknown, confirmations, corrections, peak memory) and MUST NOT record names, audio, transcript text or voice vectors.

**Settings and defaults**

- **FR-038**: A global setting "Remember and recognize speakers across meetings" MUST exist and MUST be on by default. Because enrollment is opt-in per voice, no matching or enrollment occurs until the user has explicitly remembered at least one voice.
- **FR-039**: Recognition MUST be switchable per known speaker without deleting the speaker.

**UI**

- **FR-040**: The transcript MUST show Recognized and Confirmed speakers by name, Possible matches as "Name?" with a subtle confirm control, and Unknown speakers as "Speaker N". Scores MUST NOT appear in the transcript.
- **FR-041**: Assign speakers MUST show, per meeting-local speaker, the current name, match state, candidate known speaker if any, Confirm / Choose another / Keep Unknown for suggestions, a picker of known speakers, the Remember control when a new name is entered, and the "Also remember this voice sample" control (off by default) when confirming or correcting to an existing known speaker.
- **FR-042**: Known speakers MUST list name, sample count and recognition state, with Rename, Disable/Enable recognition, Delete and sample removal. Raw voice data MUST NOT be exposed.
- **FR-043**: Each sample in a known speaker's list MUST be identified by its source meeting title and date, total speech duration and a quality label (never a vector or score). A provenance-unavailable sample (FR-031) MUST show "Source meeting deleted" with its original creation date.

### Key Entities

- **Known speaker**: a person the user asked LocalFlow to remember. Has a stable identifier, display name, created/updated dates, recognition enabled flag, state (active or needs re-enrollment; deletion removes the record), and a flag for the local user.
- **Voice sample**: one confirmed embedding for a known speaker. Has model identity, model version, dimension, pipeline version, quality metadata, source meeting, source cluster, source time ranges, creation date and active flag. A known speaker has zero or more; count is capped.
- **Identity assignment**: for one meeting and one meeting-local speaker, the linked known speaker (or none), state, origin, score, model identity, threshold policy version, and confirmed/corrected timestamps. At most one effective assignment per meeting-local speaker.
- **Identification run**: one execution over a meeting. Has state (pending, running, completed, failed, interrupted, superseded), model identity, threshold policy version, counts and timing. Only a completed run's assignments are adopted.
- **Match candidate record**: per run, cluster and candidate known speaker: score, decision tier and reasons. Kept for audit and to remember rejected candidates.
- **Identification settings**: the global toggle and, per known speaker, the recognition flag.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: In the evaluation corpus, automatic (Recognized) assignments to the wrong person occur in under 1% of automatically named clusters; the target is zero.
- **SC-002**: Across the evaluation corpus, at least 70% of clusters belonging to enrolled speakers with three or more compatible samples are Recognized or offered as the correct Possible match.
- **SC-003**: Clusters belonging to non-enrolled speakers are named automatically in 0% of evaluation cases and suggested in under 5%.
- **SC-004**: When two candidates fall within the calibrated margin, 100% of such clusters end as Possible match or Unknown, never Recognized.
- **SC-005**: No known speaker or sample is ever created in a test run where the user did not choose Remember (100% of consent tests).
- **SC-006**: Rejecting or correcting a match adds zero samples to the rejected known speaker in 100% of correction tests.
- **SC-007**: Rerunning identification changes zero transcript characters and zero manual assignments.
- **SC-008**: With 100 known speakers and the capped number of samples each, identification of a 60-minute meeting with 6 remote speakers completes within 60 seconds after diarization on the reference machine, excluding model download.
- **SC-009**: The identification model is loaded only during identification or enrollment, and memory returns to within the diarization-free baseline after release, as measured on the reference machine. Specific numbers are recorded in acceptance, not assumed.
- **SC-010**: With the global setting off, every existing test for specs 001–009 passes unchanged and no identification or enrollment code path executes.
- **SC-011**: A user can enroll a speaker from Assign speakers in three interactions or fewer (name, Remember, save), and confirm a suggestion in one.
- **SC-012**: Deleting a known speaker leaves zero samples referencing it and zero changes in transcript text across all meetings.

## Assumptions

Defaults chosen where the description left room. Each may be revisited in `$speckit-clarify`; the description's own list of 25 questions is carried into that step.

- Every stored sample traces back to an explicit Remember action: "Remember this voice" for a new profile, or the "Also remember this voice sample" control when confirming or correcting to an existing profile. Confirmation alone is not consent to store samples.
- One confirmation may produce several samples from distinct regions; the initial sample cap per known speaker is on the order of 10 and is finalized in planning.
- Minimum usable speech for a sample is a few seconds of non-overlapping speech; the exact value comes from the model's documented guidance and the calibration corpus.
- The initial embedding implementation is the same local, Apple-silicon speaker toolkit used for diarization, behind a stable abstraction so the domain never depends on its types. The similarity metric is the one that toolkit documents for its model.
- The calibration corpus is built from consenting internal recordings plus existing fixtures; it is not shipped with the app.
- Suggestions appear both in the transcript (as "Name?") and in Assign speakers.
- Duplicate names: an exact match offers to reuse the existing known speaker; the user may still create a second profile.
- The local user's own profile is created only explicitly (US7) and is not used for echo handling in this feature beyond recording evidence.
- Initial performance acceptance targets 100 known speakers, with 10 and 50 also measured.
- Known speakers live in Settings, next to the existing diarization setting.
- Users can remove individual samples.
- A new model version does not trigger automatic re-extraction; it is an explicit action per speaker or for the whole library.
- Later features treat only Confirmed and Recognized assignments as named speakers; Possible match and Unknown are passed through with their state so the consumer can decide.
- Identification is a separate step after diarization and does not run for meetings where diarization is off or has no accepted result.
- The matching library size is small enough that all compatible samples fit in a bounded in-memory comparison; no vector index is introduced.

## LocalFlow resource and failure acceptance

- One heavy model at a time: identification starts only after ASR and diarization have released; the identification model is released on completion, cancellation and failure. Load, extraction, comparison and release durations and RSS deltas are recorded on the reference machine for 10, 50 and 100 known speakers, using synthetic vectors for scale-only tests and never drawing accuracy conclusions from them.
- Bounded queue: the past-meeting search queue holds meeting identifiers only, is processed one meeting at a time, is not persisted across restarts, and is cancellable.
- Bounded audio: sample extraction reads only the selected speech regions, each capped in duration, one region at a time; full meeting audio is never loaded.
- Bounded storage: samples per known speaker are capped; match candidate records per run are bounded by clusters × candidates and superseded runs are pruned on adoption. Storage counts toward the existing history database ceiling; hitting it fails the run without adoption.
- Offline: after model provisioning, enrollment and identification perform no network activity. Missing model produces setup guidance and leaves prior assignments in effect.
- Failure and interruption: transcript, diarization, known speakers and previously accepted assignments are preserved; incomplete runs are discarded or resumed; rerun is always available.
- Permission and consent: enrollment cannot occur without the explicit Remember action; the global setting off short-circuits all identification and enrollment paths.
- Data preservation: no deletion path in this feature removes transcript text, audio or diarization results.
