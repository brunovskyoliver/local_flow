# Feature Specification: Meeting Intelligence

**Feature Branch**: `main` (existing branch; no branch-creation hook configured)

**Created**: 2026-09-20

**Status**: Draft (clarified 2026-09-20, 8 questions)

**Input**: User description "Feature 011 — Meeting Intelligence": structured AI analysis of completed meetings (executive summary, topics, decisions, action items with owners and due dates, next steps, open questions, risks/blockers), generated through the existing self-hosted LocalFlow server from structured meeting text only, with source traceability, identity-certainty enforcement, staleness detection, versioned runs and a Summary tab in meeting detail. Raw audio and speaker embeddings never leave the Mac; the transcript, speaker assignments and manual notes remain authoritative.

## Clarifications

### Session 2026-09-20

- Q: Default for automatic generation after meeting processing? → A: On by default. Every finalized meeting is analyzed automatically when the server is reachable; the setting can be turned off, and Generate Summary remains available manually either way.
- Q: Beyond Confirmed identities, who may appear as a named task owner? → A: Confirmed, Recognized (calibrated high-confidence automatic) and meeting-local typed names may all be named owners. Possible match and Unknown never are.
- Q: Regenerate when user edits exist? → A: Carry edits and statuses forward as overlays onto matching items; edits whose item has no match in the new result are kept in a "previous edits" list rather than discarded.
- Q: Can a task be owned by a person who is mentioned but not a participant ("Tomáš will send the contract")? → A: Yes, as a mentioned-name owner: free text, rendered distinctly from participant owners, never linked to a profile automatically. The client may show a local, non-binding suggestion that the name matches a known speaker; accepting it is a user edit.
- Q: One item fails protected-literal validation in an otherwise valid result: drop it or fail the run? → A: Drop the item and count it; the run succeeds. The run fails only if the executive summary itself contains the mutation or dropped items exceed a configured share of the result.
- Q: Speaker display-name-only rename after generation: refresh labels or mark stale? → A: Refresh owner labels in place; a display-name-only rename does not mark the analysis stale. Reassignments, identity changes, transcript and note edits still do.
- Q: Keep previous accepted analyses viewable after regeneration? → A: No. Only the latest accepted analysis is kept; older run records stay as content-free log entries.
- Q: Restart runs interrupted by quit or crash on relaunch? → A: Only when the interrupted run was automatic and the meeting has no accepted analysis, and only if automatic generation is still on; it re-enters the admission queue. Interrupted manual runs and regenerations wait for Retry.

## Boundary with earlier and later features

- **Spec 003 (server rewriting)** provides the self-hosted LocalFlow server ("flowd"), its versioned structured protocol, and the inference-backend adapter. This feature adds a second, lower-priority workload to that server and does not change dictation rewriting.
- **Spec 004 (meeting capture)** provides durable meetings, meeting metadata and manual notes ("My thoughts"). This feature reads notes as input and never edits them.
- **Spec 005 (meeting transcription)** provides the finalized transcript with stable segment identifiers. This feature never changes segment text or timing.
- **Spec 006 (notetaker UI)** provides the meeting-detail layout with the "My thoughts | Transcript" tabs. This feature adds a third tab, "Summary".
- **Spec 007 (speaker diarization)** provides meeting-local speakers, manual naming and per-segment correction. **Spec 010 (persistent speaker identification)** provides known speakers and the assignment certainty words Confirmed, Recognized, Possible match and Unknown, plus assignment origin. This feature consumes both and never writes back to them.
- **Later features** (Ask Meeting, semantic search, task integrations with Odoo/GitHub/email/calendar, export formats) consume this feature's structured output. None of them is built here.

Where the input says "Feature 007 identity certainty" this spec means spec 010's certainty and origin metadata.

## Vocabulary

- **Meeting evidence**: durable audio, the finalized transcript, speaker assignments with their certainty and origin, and manual notes. Evidence is authoritative and is never changed by this feature.
- **Analysis** (meeting intelligence artifact): the AI-generated derivative of the evidence: one summary plus lists of topics, decisions, action items, next steps, open questions and risks/blockers.
- **Analysis run**: one attempt to produce an analysis. A run has an explicit state and records the evidence version, server, model and prompt versions it used.
- **Accepted analysis**: the most recent run whose result passed every validation step and was stored; it is what the Summary tab shows.
- **Source reference**: a link from an analysis item to a transcript segment or a manual note by stable identifier.
- **Ownership state** of an action item: **explicit** (the person committed or was assigned and accepted in so many words), **supported** (the evidence reasonably supports the owner without a literal self-commitment), **unresolved** (no owner, or the speaker's identity is not certain enough to name).
- **Owner kind**: **participant** (a meeting speaker permitted to be named under FR-014), **mentioned name** (a person named in the evidence who is not a participant; free text, no speaker or profile link), or **none** (unresolved).
- **Due-date state**: **explicit absolute** ("on 25 September"), **explicit relative, resolved** ("tomorrow" resolved against the meeting date), **unresolved** (a time was mentioned but cannot be pinned, e.g. "soon"), **absent**.
- **Stale**: an accepted analysis whose underlying evidence has changed since it was generated.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Generate a structured summary for a finished meeting (Priority: P1)

For a meeting with a finalized transcript, the user chooses **Generate Summary**. LocalFlow sends bounded structured meeting text to the user's self-hosted server and, when a valid result returns, shows a Summary tab with an executive summary and, where the meeting supports them, topics, decisions, action items, next steps, open questions and risks/blockers. Sections that would be empty are hidden. The transcript, notes and speaker assignments look and behave exactly as before.

**Why this priority**: This is the whole product value of the feature. Everything else refines, protects or maintains this output.

**Independent Test**: Generate for the four-line deployment fixture meeting (Oliver, Martin, Peter). Confirm a summary mentioning the Monday deployment, one decision, three action items with the right owners, and unchanged transcript text and notes.

**Acceptance Scenarios**:

1. **Given** a meeting with a finalized transcript and speaker assignments, **When** the user chooses Generate Summary, **Then** a run enters a visible pending/running state and, on success, the Summary tab shows the structured result with the sections that have content.
2. **Given** the fixture meeting, **When** analysis completes, **Then** "Deployment moves to Monday" appears as a decision, and "Prepare the database backup", "Notify the customer" and "Ensure testing is completed before Friday" appear as action items owned by Martin, Peter and Oliver Brunovský respectively.
3. **Given** a meeting whose transcript is not finalized, **When** the user looks for Generate Summary, **Then** generation is unavailable with a short reason and nothing is sent to the server.
4. **Given** any completed run, **When** the user reads the transcript and notes, **Then** no character of transcript text, note text or speaker assignment has changed.
5. **Given** the analysis is shown, **When** the user compares it with the transcript and notes, **Then** the AI-generated content is labelled as such and is visually distinct from both.

---

### User Story 2 - Every item points back to evidence (Priority: P1)

Each decision, action item, next step, open question and risk carries source references to the transcript segments and manual notes that support it. The user can choose **View source** on an item and be taken to that segment or note. Items whose references do not exist, belong to another meeting, or exceed the reference cap are rejected before anything is shown; the model is never trusted to invent provenance.

**Why this priority**: Traceability is what makes AI output reviewable. Without it a user cannot tell a real decision from a plausible-sounding one.

**Independent Test**: Feed a scripted server response containing one action item with a fabricated segment ID and one with an ID from a different fixture meeting; confirm the run is not accepted and the previous accepted analysis (if any) stays visible.

**Acceptance Scenarios**:

1. **Given** an accepted analysis, **When** the user selects View source on an action item, **Then** the Transcript tab scrolls to the referenced segment (or the notes area to the referenced note) and highlights it.
2. **Given** a server response referencing a segment ID that does not exist, **When** validation runs, **Then** the run fails with a source-validation failure category and no partial result is adopted.
3. **Given** a server response referencing a segment from another meeting, **When** validation runs, **Then** the run is rejected the same way.
4. **Given** a manual note "Customer specifically requested Monday" and no spoken equivalent, **When** the analysis uses it, **Then** its source reference is of note type and the rendered item does not attribute the statement to any speaker.
5. **Given** an executive summary, **When** validated, **Then** it may reference the meeting as a whole or a broad set of sources; per-sentence references are not required.

---

### User Story 3 - Uncertain speakers never become confirmed owners (Priority: P1)

Task ownership follows the certainty recorded by spec 010. A Confirmed speaker may be a named owner. A speaker with only a Possible match is shown by their meeting-local label ("Speaker 3") or as "Owner unresolved", never by the suggested person's name. An Unknown speaker stays anonymous. The structured input sent to the server encodes certainty explicitly, and the client enforces the rule again on the result, so a prompt cannot override it.

**Why this priority**: Attributing a commitment to the wrong named person is the most damaging error this feature can make, and it is the one an LLM is most tempted to make.

**Independent Test**: Three fixture meetings with the same line "I'll call the customer" spoken by a Confirmed, a Possible-match and an Unknown speaker. Confirm the owner is the person's name, the meeting-local label, and unresolved respectively, and that the Possible-match person's name appears nowhere in the request.

**Acceptance Scenarios**:

1. **Given** a Confirmed speaker says "I'll call the customer", **When** analysis completes, **Then** the action item names that person with ownership state explicit.
2. **Given** a Possible-match speaker (suggested "Tomáš Juríček") says "I'll send the contract tomorrow", **When** analysis completes, **Then** the owner is "Speaker N" or unresolved, and "Tomáš Juríček" appears neither in the item nor in the request sent to the server.
3. **Given** an Unknown speaker makes a commitment, **When** analysis completes, **Then** the owner is unresolved and the item is still listed.
4. **Given** a server response that names a person as owner of an item whose speaker is not Confirmed or Recognized and has no meeting-local typed name, **When** validation runs, **Then** the client downgrades the owner to unresolved or rejects the run; it never shows the name.
5. **Given** a speaker with a meeting-local typed name and no persistent identity, **When** they commit to a task, **Then** the owner shows that typed name.
6. **Given** a Recognized speaker commits to a task, **When** analysis completes, **Then** the owner shows the recognized person's name.
7. **Given** a Confirmed speaker says "Tomáš will send the contract" and no participant is Tomáš, **When** analysis completes, **Then** the owner is the mentioned name "Tomáš" with ownership state supported, rendered without speaker color or profile link; if a known speaker's display name matches, the item may show a local "might be <name>" suggestion that changes nothing until the user accepts it as an edit.

---

### User Story 4 - Conservative decisions, action items and due dates (Priority: P1)

Only things the participants actually settled are decisions; a proposal ("we could maybe deploy Monday") is not. Only commitments, acceptances or explicit assignments become action items; "someone needs to…" produces an unassigned item, and general future talk produces nothing. Due dates are kept only when the evidence supports them: absolute dates as stated, relative dates resolved against the meeting date with the original phrase kept, and vague terms ("soon") left unresolved rather than guessed.

**Why this priority**: Over-extraction makes the output noisy and untrustworthy; a wrong due date is worse than none.

**Independent Test**: Fixture with one firm decision, one proposal, one "I'll send it tomorrow" (meeting dated 2026-09-20), one "I'll send it soon" and one "someone needs to send the report". Expect exactly one decision, a due date of 2026-09-21 with original text "tomorrow", an unresolved due-date state for "soon", and an unassigned item for the report.

**Acceptance Scenarios**:

1. **Given** "We will deploy on Monday", **When** analysis completes, **Then** it is a decision with at least one source reference.
2. **Given** "We could maybe deploy Monday", **When** analysis completes, **Then** it is not listed as a decision (it may appear as an open question or next step if evidence supports it).
3. **Given** "I'll send it tomorrow" in a meeting dated 2026-09-20, **When** analysis completes, **Then** the item shows due 2026-09-21, original text "tomorrow", state explicit-relative-resolved.
4. **Given** "I'll send it soon", **When** analysis completes, **Then** the item has no resolved due date and state unresolved; it is never rendered as "tomorrow" or any concrete date.
5. **Given** "Someone needs to send the report", **When** analysis completes, **Then** an action item exists with ownership unresolved.
6. **Given** a meeting with no decisions, **When** analysis completes, **Then** the Decisions section is absent rather than filled.

---

### User Story 5 - Protected values are never altered (Priority: P1)

Literal technical and factual values that appear in the analysis (IP addresses, URLs, email addresses, prices, dates, times, model names, version numbers, identifiers, company and product names) must match the evidence. "Server is 172.19.223.30" must not become "172.19.223.20" in the summary. LocalFlow checks this independently of the model.

**Why this priority**: A structured schema does not stop a model from changing a digit, and such changes are invisible to a reader who trusts the summary.

**Independent Test**: Scripted server response that mutates one IP address in an action item and one price in a decision; confirm both items are dropped, the run succeeds with the remaining items, and both mutations are counted. A second scripted response mutating a digit in the executive summary; confirm the run fails with the protected-literal category and the prior accepted analysis is unchanged.

**Acceptance Scenarios**:

1. **Given** an analysis item containing a literal of a protected class, **When** validation runs, **Then** the literal is found verbatim in a referenced source (or in the meeting evidence, for the summary) or the item fails protected-literal validation.
2. **Given** protected-literal validation fails for one item, **When** the result is processed, **Then** that item is dropped and counted, the run succeeds with the remaining items, and the dropped item appears nowhere in the rendered or copied analysis.
3. **Given** protected-literal validation fails in the executive summary, or dropped items exceed the configured share, **When** the result is processed, **Then** the run fails with the protected-literal category and the prior accepted analysis stays in place.

---

### User Story 6 - Server down, meeting untouched; retry and cancel (Priority: P2)

If the server or its inference backend is unreachable, times out or returns malformed output, the meeting, transcript, notes and speaker assignments are unaffected; the run is recorded as failed, timed out or interrupted; the user can retry later. A pending or running generation can be cancelled; a late response from a cancelled or superseded run cannot replace newer state.

**Why this priority**: The feature is optional and must never make a meeting depend on a server. This is a constitution requirement.

**Independent Test**: Start generation with the server stopped, then with a backend that returns malformed output, then with a backend that answers after the timeout. Confirm three failed runs with distinct categories, unchanged evidence, and a working Retry.

**Acceptance Scenarios**:

1. **Given** the server is unreachable, **When** the user chooses Generate Summary, **Then** the run fails with a server-unavailable category, the meeting stays fully usable, and Retry is offered.
2. **Given** the inference backend is unavailable behind a reachable server, **When** generation is attempted, **Then** the run fails with a backend-unavailable category and no partial analysis is stored.
3. **Given** a response that is not valid structured output, or carries an unsupported schema version, or names a different meeting, **When** it is received, **Then** the run fails with the matching category and nothing is rendered from it.
4. **Given** a running generation, **When** the user cancels, **Then** the run is recorded as cancelled, the previous accepted analysis (if any) is still shown, and any later response for that run is discarded.
5. **Given** a run exceeds the configured maximum runtime, **When** the limit passes, **Then** the run is recorded as timed out and treated like a failure.
6. **Given** a failed run, **When** the user retries, **Then** the previous failure record does not need to be deleted and the retry uses the same evidence unless the evidence has changed.

---

### User Story 7 - Regenerate safely; stale analysis is labelled (Priority: P2)

After correcting the transcript, renaming a speaker, confirming an identity or editing notes, the user can **Regenerate** without re-recording, re-transcribing, re-diarizing or re-identifying. The accepted analysis stays visible until the new run passes validation and is stored; a failed regeneration leaves it intact. When evidence changes after generation, the Summary tab shows "Summary may be outdated" while remaining readable.

**Why this priority**: Evidence keeps improving after the meeting; the analysis must be able to follow it without lying about its currency.

**Independent Test**: Generate, then correct one transcript segment; confirm the stale label appears and the old content remains. Regenerate with a failing server; confirm the old analysis remains and is still labelled stale. Regenerate successfully; confirm the label clears.

**Acceptance Scenarios**:

1. **Given** an accepted analysis, **When** the user regenerates, **Then** only meeting-intelligence work runs; no transcription, diarization or identification is repeated.
2. **Given** a regeneration in progress, **When** it fails, is cancelled or times out, **Then** the previously accepted analysis is unchanged and still shown.
3. **Given** an accepted analysis, **When** a transcript segment's text is corrected, a speaker assignment or identity changes, or a note is added, edited or removed, **Then** the analysis is marked stale and the Summary tab shows "Summary may be outdated".
7. **Given** an accepted analysis with an action item owned by "Speaker 2", **When** the user renames Speaker 2 to "Martin" without changing any assignment, **Then** the owner shows "Martin" immediately and the analysis is not marked stale.
4. **Given** a stale analysis, **When** the user opens the Summary tab, **Then** the content is still readable and Regenerate is offered; nothing regenerates automatically.
5. **Given** a stale analysis, **When** regeneration succeeds, **Then** the stale label clears, the new analysis records the new evidence version, and the previous analysis content is no longer stored or viewable.
6. **Given** two runs for the same meeting where the older one finishes last, **When** its response arrives, **Then** it is discarded and the newer state wins.

---

### User Story 8 - Read, copy and navigate the Summary tab (Priority: P2)

The Summary tab follows the established meeting-detail layout: meeting title and date, then "My thoughts | Transcript | Summary". It shows a locally computed reading time ("1 MIN READ"), the executive summary, topic sections with bullets, then Next steps, Decisions, Open questions and Risks / blockers. Named owners reuse the speaker's stable color and name; unresolved owners are visibly different and never by color alone. **Copy** produces a plain human-readable report without identifiers, confidence data or schema internals.

**Why this priority**: A good result that is hard to read or share loses most of its value; copying is the only "export" in this feature.

**Independent Test**: Render the fixture analysis; confirm section order, hidden empty sections, reading time computed from rendered text, distinct styling for an unresolved owner, and that the copied text contains no UUIDs or state words.

**Acceptance Scenarios**:

1. **Given** an accepted analysis with no risks, **When** the Summary tab renders, **Then** the Risks / blockers heading is absent.
2. **Given** an accepted analysis, **When** it renders, **Then** the reading time is derived from the rendered text on the Mac and no reading-time value is requested from or accepted from the server.
3. **Given** an action item owned by a Confirmed speaker with a speaker color, **When** rendered, **Then** the owner shows that color and the name; an unresolved owner shows a neutral style with the label "Speaker N" or "Owner unresolved".
4. **Given** the user chooses Copy, **When** the clipboard is inspected, **Then** it contains headings and bullets in reading order and no internal identifiers, confidence labels, ownership/due-date state words or prompt content.
5. **Given** a rendered Summary, **When** the result contains prose the model formatted as Markdown, **Then** the section structure still comes from the structured fields, not from parsing that prose.

---

### User Story 9 - Long meetings are analyzed in bounded stages (Priority: P2)

Meetings longer than one model context are split deterministically along transcript segments, each part is analyzed into structured, source-referenced partial results, and a bounded final synthesis combines them. The tail of the meeting is never dropped silently. Every final item still references original segment and note identifiers.

**Why this priority**: Multi-hour meetings are normal for this user; an analysis that quietly covers only the first hour is worse than none.

**Independent Test**: A synthetic four-hour fixture with a unique decision in the last five minutes. Confirm the final analysis contains that decision with a valid source reference, that no single request exceeded the configured budget, and that concurrent server requests never exceeded the configured limit.

**Acceptance Scenarios**:

1. **Given** a meeting whose structured input exceeds the configured single-request budget, **When** analysis runs, **Then** it proceeds in stages and completes rather than truncating or failing outright.
2. **Given** staged analysis, **When** the final result is validated, **Then** every source reference resolves to an original segment or note of this meeting; no intermediate identifier leaks.
3. **Given** staged analysis, **When** requests are issued, **Then** the number in flight never exceeds the configured concurrency limit and each request stays within the configured input budget.
4. **Given** a segment would straddle a chunk boundary, **When** chunking runs, **Then** the segment is kept whole in one chunk.

---

### User Story 10 - Dictation stays responsive while analysis runs (Priority: P2)

Meeting analysis is background work. While a long analysis runs, a push-to-talk dictation rewrite is still served within spec 003's acceptance, either by priority handling on the server or by bounding the analysis workload so it cannot monopolize the backend. Analysis jobs across meetings are admitted through a bounded queue with a visible queued state.

**Why this priority**: Feature 003 is interactive and already shipped; regressing it would be a defect under the constitution.

**Independent Test**: Start a long-meeting analysis, then issue dictation rewrites; confirm rewrite latency stays within the spec 003 gates on the reference server. Start analysis for more meetings than the concurrency limit; confirm the extras show as queued, not running.

**Acceptance Scenarios**:

1. **Given** an analysis is running, **When** a dictation rewrite is requested, **Then** the rewrite completes within its spec 003 acceptance on the reference server.
2. **Given** more analysis requests than the admission limit, **When** they are submitted, **Then** the excess are shown as queued (or refused with a clear message), never started invisibly.
3. **Given** the server's request handling, **When** an analysis and a rewrite compete, **Then** the request carries a workload priority the server can act on, even if the initial backend only uses it for ordering.

---

### User Story 11 - Edit and correct the analysis (Priority: P3)

The user can edit the executive summary text, an action item's task text, owner and due date, and the text of decisions and next steps. Edited content is marked as user-edited and kept separately from what the model produced. The user can mark an action item open, completed or dismissed; this is local meeting metadata and does not change any evidence. Regeneration never silently discards edits: it follows the policy in FR-034.

**Why this priority**: Review-and-correct is the last hallucination safeguard, but a read-only analysis already delivers the primary value.

**Independent Test**: Change an owner from unresolved to "Tomáš Juríček" and mark an item completed; confirm the edit is visibly distinguished, the AI-extracted value is still stored, the transcript is unchanged, and no known-speaker or voice-sample data changed.

**Acceptance Scenarios**:

1. **Given** an action item with an unresolved owner, **When** the user sets the owner to a named participant, **Then** the item shows the name with a user-edited indicator, and the AI's original value remains stored.
2. **Given** an action item, **When** the user marks it completed, **Then** its status is persisted with the meeting and the transcript and notes are unchanged.
3. **Given** the user corrects an owner, **When** the change is saved, **Then** no known-speaker profile, voice sample or identity assignment is modified.
4. **Given** the user adds, changes or removes a due date, **When** saved, **Then** the AI-extracted due date and state remain stored alongside the user value.
5. **Given** an analysis with user edits, **When** the user chooses Regenerate, **Then** the behavior follows FR-034 and no edit is lost without the user being told.

---

### User Story 12 - Slovak, English and mixed technical meetings (Priority: P3)

The analysis is written in the meeting's dominant language. Slovak, English and mixed Slovak/English technical meetings are all supported. English technical terms, product names, identifiers, URLs, code and values stay as spoken; nothing is translated wholesale. The language policy is part of the request, not left to the model's guess.

**Why this priority**: The user's meetings are mostly Slovak with English technical vocabulary; an English-only or translated summary would be unusable.

**Independent Test**: Slovak, English and mixed fixtures; confirm the summary language matches the dominant language and that English terms in the mixed fixture survive verbatim.

**Acceptance Scenarios**:

1. **Given** a Slovak meeting, **When** analysis completes, **Then** the summary and item texts are Slovak.
2. **Given** a mixed meeting in Slovak with English terms ("deployment", "backup", "M6"), **When** analysis completes, **Then** the prose is Slovak and those terms appear unchanged.
3. **Given** any meeting, **When** the request is built, **Then** it carries an explicit language policy value.
4. **Given** a meeting explicitly set to Slovak or English, **When** analysis runs, **Then** the requested prose language follows that choice even when technical vocabulary confuses automatic detection. Without a meeting override, a fixed Slovak or English language recorded by the final transcript pass is used. Explicit Automatic, unsupported choices and legacy passes use bounded text detection; Czech summary support is not added in this follow-up.
5. **Given** a response whose declared language differs from the request, **When** validation runs at any stage, **Then** the result is rejected and any accepted summary remains unchanged.
6. **Given** a language-policy change during generation, **When** the result is ready, **Then** it is not adopted under the old policy. Changing the resolved language makes an existing summary stale.
7. **Given** partial summaries of a long meeting, **When** they are combined, **Then** tentative claims remain tentative, owners and deadlines stay attached to their tasks, and uncertain ASR wording is not replaced by invented facts.

---

### Edge Cases

- The meeting is very short or trivial (a two-line check-in): no topic sections are forced; a summary alone is a valid analysis.
- The meeting has a transcript but no speaker assignments at all (diarization off): analysis still runs; every owner is unresolved.
- The meeting has notes but no finalized transcript: generation is unavailable; notes alone do not qualify.
- A manual note is the only evidence for a fact: the item cites the note, and the rendered text does not say anyone said it.
- The user renames a speaker's display name only: participant owner labels refresh in place at render time and the analysis is not marked stale (FR-031a). Summary or item prose that repeats the old name is not rewritten; that needs Regenerate.
- The user deletes the meeting: all runs, analyses, edits and statuses for that meeting are deleted with it.
- The app quits or crashes during a run: the run is recorded as interrupted on next launch; the accepted analysis, evidence and edits are intact. An automatic run for a meeting with no accepted analysis restarts on its own (FR-007a); any other interrupted run waits for Retry.
- The meeting-detail window closes or the app goes to the background during a run: the run continues to completion and the result is adopted when received; if the client cannot receive it, the run is interrupted and handled per FR-007a.
- The server returns more items than the configured caps (e.g. hundreds of decisions): the response is rejected as over-size, not partially adopted.
- The response is schema-valid and all references exist, but one item's evidence plainly does not support it, or one item fails protected-literal validation: the item is dropped and counted and the run still succeeds, subject to the run-level limits in FR-024a.
- Two different meetings are analyzed back to back: no content from one appears in the request or result of the other.
- History database is at its ceiling: the run fails without adoption and evidence is untouched.

## Requirements *(mandatory)*

### Functional Requirements

**Eligibility, generation and run lifecycle**

- **FR-001**: Generation MUST be available only for meetings with a finalized transcript. Ineligible meetings MUST show why, and MUST NOT send anything to the server.
- **FR-002**: The user MUST be able to start generation explicitly with Generate Summary. Automatic generation after meeting processing MUST be governed by a setting that is on by default; when on, a run starts automatically once the transcript is finalized AND the meeting's speaker work has settled — diarization and identification adopted, were skipped or failed, or are turned off — so the run sees every label and name there is instead of generating a speakerless analysis that immediately goes stale, subject to the admission limits in FR-045. At most one automatic run starts per finalized pass. If the server is unreachable at that moment the run fails like any other and the meeting shows Generate Summary for a manual retry. Turning the setting off MUST stop automatic runs without affecting manual generation.
- **FR-003**: Each run MUST be in exactly one of: not requested, pending (queued), running, succeeded, failed, cancelled, timed out, interrupted. An accepted analysis additionally carries a stale flag. Exact naming is set in planning.
- **FR-004**: Each run MUST record: meeting, state, evidence version (FR-030), server version, protocol version, output schema version, backend and model identity plus relevant configuration, prompt version, long-meeting pipeline version, start and completion times, and failure category. Hidden reasoning MUST NOT be stored.
- **FR-005**: A failed, cancelled, timed-out or interrupted run MUST NOT change the meeting's usability, evidence or accepted analysis. A failed analysis MUST NOT be presented as a failed meeting.
- **FR-006**: The user MUST be able to cancel a pending or running run. Cancellation MUST persist the cancelled state, keep the accepted analysis, and MUST cause any later response for that run to be discarded.
- **FR-007**: The user MUST be able to retry a failed, timed-out or interrupted run without deleting prior run records.
- **FR-007a**: On launch, runs left pending or running MUST be recorded as interrupted. An interrupted run MUST then be restarted automatically, through the admission queue (FR-045), only when all of: it was started automatically (FR-002), the meeting has no accepted analysis, and the automatic-generation setting is still on. In every other case the run waits for a manual Retry. Automatic restart MUST happen at most once per launch per meeting; if the restart fails, the meeting shows Generate Summary.
- **FR-008**: A run MUST time out after a configured maximum runtime and be recorded as timed out.
- **FR-009**: Regeneration MUST reuse current durable evidence and MUST NOT trigger transcription, diarization or identification.
- **FR-010**: A new result MUST replace the accepted analysis only after all of: complete server response, schema validation, source-reference validation, identity-certainty validation, protected-literal validation, and successful storage. Until then the previous accepted analysis remains the one shown.
- **FR-011**: A response for a run that is no longer the newest for that meeting MUST be discarded.
- **FR-011a**: A meeting MUST have at most one accepted analysis. When a new result is adopted (FR-010), the previous accepted analysis content MUST be deleted in the same transaction; its run record is retained as a content-free entry (FR-004 fields only). Run records per meeting MUST be capped at a configured count, pruning the oldest non-accepted records first. No history of earlier analyses is browsable in this feature.

**Ownership and identity certainty**

- **FR-012**: The structured input MUST encode, for each participant, the meeting-local speaker identifier, the persistent profile identifier if any, the display name if permitted by FR-013, the identity certainty (Confirmed, Recognized, Possible match, Unknown, or meeting-local-name-only) and the assignment origin.
- **FR-013**: The name of a Possible-match candidate MUST NOT be sent to the server and MUST NOT appear in any analysis item. Unknown speakers MUST be sent without any name.
- **FR-014**: Named owners are permitted for speakers whose certainty is Confirmed or Recognized, and for speakers with a meeting-local typed name and no persistent identity. Possible-match and Unknown speakers MUST NOT be named owners. The rendered owner MUST expose which of the three cases applies to accessibility tooling, so a later feature can treat Recognized owners differently without a schema change.
- **FR-014a**: A person named in the evidence who is not a participant MAY be an owner of kind "mentioned name": stored as free text taken verbatim from the evidence, ownership state at most supported, rendered visibly distinct from participant owners (no speaker color, no profile link), and NEVER linked to a known-speaker profile or meeting speaker automatically. The client MAY show a non-binding suggestion when the mentioned name matches a known speaker's display name; the match is computed on the Mac, known-speaker data is not sent to the server, and accepting the suggestion is a user edit under FR-032 that links the owner to that profile for this item only and MUST NOT change any known speaker (FR-035). A mentioned name that equals a Possible-match candidate's name MUST be treated under FR-013 (not shown as owner).
- **FR-015**: The client MUST enforce FR-013 and FR-014 on the server's output independently of prompt wording; a violating owner MUST be downgraded to unresolved or the run rejected.
- **FR-016**: Every action item MUST carry an ownership state of explicit, supported or unresolved. Initial extraction MUST prefer explicit and supported ownership and MUST NOT infer owners from generic statements ("we should…", "someone needs to…").
- **FR-017**: Action items without an owner and action items without a due date MUST still be included when the commitment itself is evidenced.

**Extraction conservatism**

- **FR-018**: A decision MUST be something the participants settled. Proposals, speculation and options under discussion MUST NOT be listed as decisions.
- **FR-019**: An action item MUST represent an agreed, committed or explicitly assigned task. Not every future-looking statement is a task.
- **FR-020**: Due dates MUST carry a state of explicit absolute, explicit relative resolved, unresolved or absent, plus the original phrase and a source reference. Relative dates MUST be resolved against the meeting's start date in the meeting's time zone. Vague terms (at minimum "soon", "later", "at some point", "eventually", "next time" and their Slovak equivalents) MUST remain unresolved.
- **FR-021**: Next steps MUST NOT duplicate action items verbatim. Open questions and risks MUST be evidenced; empty sections are valid and MUST NOT be padded.
- **FR-022**: Topic sections are optional; short or simple meetings MUST NOT be given artificial topics.

**Source traceability and validation**

- **FR-023**: Every decision, action item, next step, open question and risk MUST carry at least one source reference to a transcript segment or manual note by stable identifier. The executive summary and topic summaries MAY reference broader source sets or the meeting as a whole. Timestamps MUST NOT be the only reference where stable identifiers exist.
- **FR-024**: The client (and/or server) MUST validate that every referenced identifier exists, belongs to this meeting, has a valid type, and that the reference count per item is within a configured cap. Any violation MUST fail the run; fabricated references MUST NEVER be accepted silently. Protected-literal mutations MUST fail validation for the affected item; the item-level and run-level consequences are set by FR-024a.
- **FR-024a**: An item (decision, action item, next step, open question, risk or topic) that fails protected-literal validation or is judged unsupported by its referenced evidence MUST be dropped from the adopted result and counted in metrics (FR-050); the run still succeeds. The run MUST fail with a protected-literal failure category, and nothing is adopted, when every sentence of the executive summary contains a protected-literal mutation (a sentence with one is removed and the rest is kept). The number of dropped items never fails the run: the surviving items are adopted and the drops are counted (amended 2026-09-23 — with a 4B backend the former dropped-share limit discarded whole summaries over paraphrased items). Dropped items MUST NOT be rendered, copied or stored as part of the accepted analysis. Source-reference violations (FR-024) remain run-failing regardless of count.
- **FR-025**: Source references MUST distinguish transcript segments from manual notes, and the rendered analysis MUST NOT attribute note content to a speaker.
- **FR-026**: The user MUST be able to open the source of an item and be taken to the referenced segment or note in the meeting detail.
- **FR-027**: Protected-literal classes (IP addresses, URLs, email addresses, prices, dates, times, model names, version numbers, technical identifiers, company and product names) appearing in analysis text MUST be checked against the referenced evidence.

**Structured output and input contract**

- **FR-028**: The analysis MUST be exchanged and stored as versioned structured data with a schema version; the client MUST render from structured fields and MUST NOT locate sections by parsing Markdown or prose. Unsupported schema versions MUST be rejected.
- **FR-029**: The request MUST contain only: meeting identifier, title, start time, duration, time zone, language policy, participants per FR-012, transcript segments (stable identifier, start, end, speaker reference, final text), and manual notes (stable identifier, text, time metadata if any). It MUST NOT contain audio, speaker embeddings, diarization model evidence, other meetings, global transcript history, or vocabulary lists.
- **FR-030**: The evidence version MUST be a stable identity computed from the final transcript content, speaker assignments (segment-to-speaker mapping), speaker identity state (persistent profile link and certainty, not the display name), manual note content, and the analysis request configuration; it MUST NOT rely on timestamps alone.
- **FR-031**: When the current evidence version differs from the accepted analysis's evidence version, the analysis MUST be marked stale and shown with "Summary may be outdated" (or equivalent) while remaining readable. Staleness MUST NOT trigger automatic regeneration.

**Editing and local status**

- **FR-031a**: Participant owner names MUST be resolved from the current speaker record when rendered and copied, not frozen at generation time; a display-name-only rename therefore updates owner labels in place and MUST NOT mark the analysis stale. Mentioned-name owners (FR-014a) are stored text and are unaffected by renames. Prose fields (summary, topic and item text) are not rewritten on rename.
- **FR-032**: The user MUST be able to edit the executive summary, action-item task text, owner and due date, decision text and next-step text. User-edited values MUST be stored distinctly from AI-extracted values and MUST be visibly marked as edited.
- **FR-033**: Action items MUST support a local status of open, completed or dismissed, stored as meeting metadata, with no effect on evidence and no external synchronization.
- **FR-034**: Regeneration MUST NOT silently destroy user edits. When the new result is adopted, user edits and action-item statuses MUST be carried forward as overlays onto items of the new result that match the edited items (matching rules are set in planning and MUST prefer source-reference overlap over text similarity). Edits whose item has no match MUST be kept in a "previous edits" list visible from the Summary tab, not deleted. The user MUST be able to remove an overlay to reveal the AI value.
- **FR-035**: Owner corrections MUST NOT modify known speakers, voice samples or identity assignments.

**Language**

- **FR-036**: The request MUST carry an explicit language policy; the default is the meeting's dominant language. Slovak, English and mixed Slovak/English MUST be supported. Product names, identifiers, URLs, code, technical values and established English technical terms MUST NOT be translated. Mixed-language content MUST NOT be treated as an error.

**Presentation**

- **FR-037**: Meeting detail MUST gain a Summary tab beside My thoughts and Transcript, showing reading time, executive summary, topic sections, then Next steps, Decisions, Open questions, Risks / blockers, hiding empty sections.
- **FR-038**: Reading time MUST be computed on the Mac from the rendered text; it MUST NOT be requested from the server.
- **FR-039**: Named owners MUST reuse the participant's stable color and name where available; unresolved and unknown owners MUST be visually distinct, and color MUST NOT be the only distinguishing cue.
- **FR-040**: Copy MUST produce a plain human-readable report (headings and bullets in reading order) containing no internal identifiers, confidence or state metadata, prompt content or schema details.
- **FR-041**: AI-generated content MUST be labelled as AI-generated and MUST NOT be presented as guaranteed accurate.

**Server, bounds and priority**

- **FR-042**: All inference MUST go through the existing self-hosted server and its backend adapter. No inference runtime MAY be added to the Mac client.
- **FR-043**: The server MUST validate requests, construct prompts, adapt to the backend, bound output size, validate structured responses and version the protocol for this workload.
- **FR-044**: Long meetings MUST be analyzed through a bounded staged strategy: deterministic chunking along whole transcript segments, structured source-referenced partial results, and a bounded final synthesis. The tail MUST NEVER be dropped silently; provenance MUST resolve to original identifiers at every stage.
- **FR-045**: Per-request input, intermediate artifacts, response accumulation, generated item counts, concurrent requests per run and concurrent runs across meetings MUST all have configured limits. Requests exceeding a limit MUST be refused or queued visibly, never accepted into an unbounded buffer.
- **FR-046**: The server MUST model the configured backend's usable context and reserve room for instructions, output schema and generation; limits MUST be configurable and versioned per backend/model.
- **FR-047**: Requests MUST carry a workload priority so that interactive dictation rewriting can be favored over meeting analysis; the initial implementation MAY use it only for admission ordering.
- **FR-048**: Meeting analysis MUST NOT cause spec 003 rewrite acceptance to regress on the reference server.

**Privacy, observability and isolation**

- **FR-049**: Only the structured meeting text described in FR-029 leaves the Mac, and only to the user's own server. No third-party AI provider is introduced. No analytics containing meeting text exist.
- **FR-050**: Metrics MUST be content-free: durations per stage, chunk counts, input/output sizes, model and backend identity, retry counts, failure categories, source-validation and protected-literal failure counts, item counts, unresolved-owner counts and stale-analysis counts. Transcript text, notes, summary text, item text, speaker names and source content MUST NEVER be logged.
- **FR-051**: With the feature unused, every behavior of specs 001–010 MUST be unchanged and their tests MUST pass unchanged.
- **FR-052**: Deleting a meeting MUST delete all its runs, analyses, edits and statuses.

### Key Entities *(include if feature involves data)*

- **Analysis run**: one generation attempt for one meeting; state, evidence version, server/protocol/schema/model/prompt/pipeline versions, timing, failure category, accepted flag. Contains no analysis content once superseded. Bounded per meeting (FR-011a).
- **Analysis**: the accepted structured result of a run; at most one per meeting; has a stale flag; replaced atomically on adoption.
- **Summary**: executive summary text plus broad source references.
- **Topic**: title, summary, order, source references.
- **Decision**: text, source references, optional evidence classification.
- **Action item**: task text, owner kind (participant, mentioned name, none), owner reference (meeting-local speaker and/or persistent profile; absent for mentioned names), owner display name (stored only for mentioned names; participant names resolve at render time), ownership state, due date, due-date original text, due-date state, local status, source references; plus user-edited values for task, owner and due date with edit origin.
- **Next step / Open question / Risk**: text plus source references (risks and questions may carry an evidence classification).
- **Source reference**: item → transcript segment or manual note, by stable identifier and type.
- **Evidence version**: stable identity of the accepted evidence and request configuration at generation time.
- **User edit**: a user-authored value for an editable field, stored beside the AI value with the time of the edit.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: For every fixture in the evaluation set, the run either produces an accepted analysis or a categorized failure; there are zero silent partial adoptions.
- **SC-002**: Across the evaluation set, zero action items name a person whose speaker certainty was Possible match or Unknown, and zero requests contain a Possible-match candidate's name.
- **SC-003**: Across the evaluation set, zero fabricated or cross-meeting source references are accepted; 100% of accepted decision, action-item, next-step, open-question and risk items carry at least one valid reference.
- **SC-004**: Zero protected-literal mutations pass validation across the evaluation set.
- **SC-005**: Zero due dates are produced from vague terms; 100% of explicit relative dates in the evaluation set resolve to the expected calendar date.
- **SC-006**: On the evaluation set, all explicit decisions and explicit action items are found (0 missed), and no more than 1 in 10 extracted decisions or action items is judged unsupported on human review; proposals are never listed as decisions.
- **SC-007**: A four-hour fixture meeting is analyzed to completion with its last-five-minute decision present, with no request above the configured budget and never more than the configured number of requests in flight.
- **SC-008**: An ordinary meeting (about 30 minutes) completes analysis within 30 seconds warm on the reference server; long meetings report duration as a fraction of meeting length. Numeric gates are confirmed after measuring the reference model and recorded in acceptance, not assumed.
- **SC-009**: While a long analysis runs, spec 003 rewrite latency on the reference server stays within its existing gates (short-bucket median ≤ 1.5 s, ordinary p95 ≤ 3.0 s).
- **SC-010**: Idle client memory is unchanged within measurement noise on the reference Mac; building the request for a four-hour meeting stays within a bounded working set recorded in acceptance; no model is loaded in the client.
- **SC-011**: After a failed, cancelled or timed-out regeneration, the previously accepted analysis is byte-identical to before in 100% of test runs; transcript, notes and assignments are unchanged in 100% of all runs.
- **SC-012**: Every evidence change type (segment text, speaker assignment, identity state, note add/edit/remove) marks the analysis stale within the same session in 100% of tests; a display-name-only rename never does and updates owner labels in 100% of tests.
- **SC-013**: Copied output contains zero identifiers, state words or confidence values across the evaluation set.
- **SC-014**: Slovak, English and mixed fixtures produce prose in the expected language and preserve 100% of listed technical terms verbatim.
- **SC-015**: All tests for specs 001–010 pass unchanged with the feature unused.

## Assumptions

Defaults chosen where the description left room. Each may be revisited in `$speckit-clarify`; the description's own list of 45 questions is carried into that step (see Clarification agenda).

- The reference acceptance environment is the owner's existing spec 003 self-hosted server and its configured model; the exact model/backend is confirmed in clarification and recorded in acceptance.
- Mandatory output: the executive summary. All other sections are optional and appear only with content.
- Unknown speakers are shown as "Speaker N" (their meeting-local label) when a label exists, otherwise "Owner unresolved".
- "We need to…" and "someone needs to…" statements produce unassigned action items when they clearly describe a task; general intent does not.
- Explicit ownership requires a first-person commitment or a direct assignment plus an acknowledgement in the evidence; "supported" covers cases such as an assignment without a spoken acknowledgement.
- Relative dates resolve against the meeting start date in the meeting's recorded time zone (falling back to the Mac's time zone at capture).
- Confidence and evidence classifications are stored but not shown in the ordinary UI or copied output.
- Automatic generation runs once per finalized meeting (plus the FR-007a restart after an interruption); it does not re-run automatically on stale evidence.
- Reference cap per item is on the order of 10 and finalized in planning; item-count caps per section are also set in planning.
- Concurrency default: one analysis run at a time across meetings, with a small bounded number of chunk requests per run; exact numbers are set in planning after measuring the reference backend.
- Timeout default is proportional to meeting length with a fixed floor and ceiling, set in planning.
- Runs continue when the meeting window closes or the app is in the background; quitting the app interrupts them (see FR-007a for what restarts).
- Stale analyses remain readable until regenerated.
- Manual notes are included by default; per-note exclusion is not offered in this feature.
- Dismissed items and completion statuses are overlays like other edits (FR-034): they follow the matched item after regeneration; a dismissed item whose match reappears stays dismissed.
- Source navigation scrolls to and highlights the segment; it does not start playback.
- A successful run requires zero invalid source references; item-level protected-literal and unsupported-content failures follow FR-024a.
- Structured persistence uses the existing history database with explicit migrations; normalized tables per item type are preferred over a single blob; the exact split is planning.
- No content from this feature flows into known speakers or voice samples.

## Clarification agenda

The input lists 45 questions. Three with the greatest scope impact (1, 5–6, 27) were resolved with the user on 2026-09-20 during specify; a second clarify session the same day resolved mentioned-name owners (new), 38 and 43–44 (FR-024a), 35 (FR-031a), analysis history (FR-011a) and 24–25 plus interrupted-run restart (FR-007a); questions 28–31 follow from the FR-034 answer. The remainder keep the defaults recorded in Assumptions and can be revisited after planning: 2–4, 7–13, 15–23, 32, 36–37, 39–42, 45.

## LocalFlow resource and failure acceptance

- Bounded client work: request construction reads segments and notes in pages from the database and never holds more than one chunk's worth of duplicated text; no client model is loaded; idle RSS unchanged.
- Bounded server work: request body size, per-chunk input, intermediate artifacts, response accumulation, generated item counts, concurrent chunk requests per run and concurrent runs are all capped with explicit refuse-or-queue behavior; server RSS excluding the inference backend is measured during a four-hour-meeting analysis and recorded.
- Bounded queue: the analysis admission queue holds run identifiers only, has a fixed capacity, exposes queued state to the user, is cancellable, and is not persisted across restarts (queued runs become interrupted).
- Offline and server failure: meetings, transcripts, notes and assignments are unaffected; runs fail with categories; retry is available; nothing in meeting access depends on the server.
- Interruption: quit, crash or storage error leaves the accepted analysis, evidence and edits intact; the in-flight run is marked interrupted on next launch and restarts only under FR-007a.
- Late and duplicate responses: responses for cancelled or superseded runs are discarded; the newest run always wins.
- Data preservation: no path in this feature edits or deletes transcript text, audio, notes, speaker assignments, known speakers or voice samples. Deleting a meeting removes its analysis data with it.
- Privacy: only the FR-029 payload leaves the Mac; no audio, embeddings or unrelated content; logs and metrics are content-free.
- Dictation independence: spec 003 rewrite latency gates are re-measured with a long analysis running and must hold.
