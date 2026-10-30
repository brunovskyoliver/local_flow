# Feature Specification: Meeting-first onboarding

**Feature Branch**: `022-meeting-first-onboarding`
**Created**: 2026-10-30
**Status**: Draft
**Input**: "We should be able to have the meeting on remote in the onboarding as well, so that the application is not only for dictations but also targeting people who wanna use it only as meeting notes." Design: `docs/architecture/cross-platform-gpui.md`, section "Meeting-first onboarding".

## Clarifications

### Session 2026-10-30

- Q: Which purpose is preselected? → A: Both.
- Q: What must a meetings-only user on this computer download? → A: Speech, Whisper and speaker models (about 2.3 GB), with live transcript.
- Q: Do meetings on this computer offer the local AI model? → A: Yes, with a clear Skip that says summaries won't be available.
- Q: What does Both with Your server do? → A: Same as today: everything goes to the server and the local speech model stays as a dictation fallback. It does not turn on server-only.

## User Scenarios & Testing

### User Story 1 - Meeting notes on my server (Priority: P1)

A new user who only wants meeting notes, and who has a LocalFlow server, finishes setup without downloading a model, granting keyboard permissions or setting a dictation shortcut, then records a meeting that the server processes.

**Why this priority**: This is the request. Today setup cannot finish without the speech model download and Input Monitoring.

**Independent Test**: On a clean profile choose Meeting notes and Your server, enroll against a test server, and reach the Notetaker page. No model file is downloaded and no Input Monitoring or Accessibility prompt appears.

**Acceptance Scenarios**:

1. **Given** a first run, **When** the user picks Meeting notes then Your server, **Then** the next step is the existing server connection and consent step.
2. **Given** the device is approved or pending, **When** the user continues, **Then** setup skips downloads, the shortcut and the dictation test, and asks only for Microphone and system audio access.
3. **Given** setup is finished, **When** the app opens, **Then** it shows Notetaker and no model loads on this Mac.
4. **Given** approval is pending or the server is offline, **When** the user records a meeting, **Then** the recording is saved locally and Notetaker says it is waiting for the server.

### User Story 2 - Meeting notes on this Mac (Priority: P2)

A new user who wants meeting notes with no server downloads the meeting models and finishes setup without dictation steps.

**Independent Test**: Choose Meeting notes and This computer on a clean profile; meeting models download as required items, and setup ends on Notetaker with no shortcut or keyboard permission requested.

**Acceptance Scenarios**:

1. **Given** Meeting notes and This computer, **When** downloads start, **Then** the models a local meeting needs are required before setup can finish, and the language model stays optional.
2. **Given** a download fails, **When** the user retries, **Then** it resumes as today's downloads do.

### User Story 3 - Dictation or both (Priority: P2)

A user who picks Dictation gets today's flow. A user who picks Both gets today's flow plus meeting models and the system audio request.

**Independent Test**: Compare step order for Dictation against the current flow; only the new purpose step differs.

**Acceptance Scenarios**:

1. **Given** Dictation, **When** the user proceeds, **Then** every later step behaves as it does today.
2. **Given** Both, **When** downloads run, **Then** meeting models are requested without the user pressing Download.

### User Story 4 - Adding dictation later (Priority: P3)

A meeting-only user can turn dictation on from Settings without repeating the rest of setup.

**Independent Test**: From a finished meetings-only setup, use Set up dictation in Settings; dictation works afterwards, and meetings are untouched.

**Acceptance Scenarios**:

1. **Given** a `meetings` purpose, **When** the user chooses Set up dictation, **Then** only the shortcut, permission and, if the Mac may run local models, speech model steps appear.

### Edge Cases

- Existing users who completed onboarding see no change; a missing purpose means Both.
- Going Back from a later step and changing purpose must not leave a server-only setting or a queued download from the abandoned path.
- A meeting-only server user whose access is revoked keeps their recordings, and work stays waiting with the existing message.
- System audio refused: setup can finish, and the first meeting records the microphone with the existing refusal message.
- The user quits mid-setup: onboarding starts again, as it does today, and chosen values are not treated as completed setup.

## Requirements

### Functional Requirements

- **FR-001**: Onboarding MUST ask what the user wants LocalFlow for: Dictation, Meeting notes or Both, after the introduction, with Both preselected.
- **FR-002**: The introduction copy MUST describe meeting notes as well as dictation.
- **FR-003**: Meeting notes MUST offer This computer or Your server; the choice MUST state what leaves the Mac.
- **FR-004**: Meeting notes on Your server MUST use the existing enrollment and consent, and MUST turn on server-only so no speech or language model downloads or loads.
- **FR-005**: The meeting-only paths MUST NOT request Input Monitoring or Accessibility, enable the shortcut, or show the dictation test.
- **FR-006**: The meeting paths MUST request Microphone and system audio during setup; refusal of system audio MUST NOT block finishing.
- **FR-007**: A meeting-only path MUST finish on the Notetaker page and open there on later launches.
- **FR-008**: The purpose MUST persist; a missing purpose MUST behave as Both, with no change for existing users.
- **FR-009**: Recording MUST NOT depend on server reachability or approval; audio MUST be kept and processing MUST wait (constitution principle 4).
- **FR-010**: Settings MUST offer Set up dictation to a meeting-only user.
- **FR-011**: Changing purpose or location with Back MUST undo settings the abandoned path made.
- **FR-013**: Meeting notes on This computer MUST require the speech, Whisper and speaker models before finishing, and MUST offer the local AI model with a Skip stating that summaries won't be available.
- **FR-014**: Both on Your server MUST keep today's routing: everything on the server, local speech model downloaded as the dictation fallback, server-only off.
- **FR-012**: Consent copy MUST state that meeting audio and text go to the server and that handed-off meetings stay there until merged, at most 7 days (ADR 0033).

### Key Entities

- **Purpose**: `dictation`, `meetings` or `both`; stored per device.
- **Meeting readiness**: whether storage, Microphone and, without server-only, local meeting models are ready.

## Success Criteria

- **SC-001**: A meeting-only server user reaches Notetaker with zero model bytes downloaded and zero keyboard permission prompts.
- **SC-002**: The Dictation path has the same steps as today plus the one purpose step.
- **SC-003**: Existing installs that finished onboarding show the same first page and settings after updating.
- **SC-004**: A meeting recorded while the server is offline is complete on disk and is processed once the server returns, with no user re-recording.

## Assumptions

- The server path reuses Feature 018 routing and ADR 0033 handoff; no server or wire change is needed.
- Sign-in stays as it is on the Mac.
- This is built in the SwiftUI app, and the GPUI client ports the same flow later (ADR 0036).

## LocalFlow resource and failure acceptance

- Bounds: no new queue or buffer. The server path loads no model on this Mac.
- Failure: recordings survive an unreachable server, a refused approval and a quit during setup.
- Privacy: nothing leaves the Mac before consent and approval.
- Measurement: no new model; record that the server path adds no model working set.
