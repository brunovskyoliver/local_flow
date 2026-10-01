# Feature Specification: Feature 018 — One Server for Everything

**Feature Branch**: `main` (no branch-creation hook configured; Feature 017 is the iOS work in a separate worktree)

**Created**: 2026-10-01

**Status**: Draft

**Input**: User description: "One server for everything. When remote dictation is on and the device is approved, every inference service runs on that server as one package, with no per-service configuration: dictation, rewriting, meeting summaries, and meeting transcription including Whisper Turbo transcripts, speaker labels and persistent speaker identification. Local models are not kept resident while the server serves, but stay provisioned for fallback. Settings get one Server section with a single switch and per-service overrides under Advanced; existing settings migrate without loss." (The full description is reflected in the sections below.)

## Boundary with earlier features

Feature 014 moved windowed dictation recognition and rewriting onto the user's LocalFlow server, behind enrollment, administrator approval and the encrypted channel. Feature 018 completes ADR 0028's goal of running all models on that server:

| Service | Today with remote dictation approved | After Feature 018 |
| --- | --- | --- |
| Dictation recognition | Server | Server (unchanged) |
| Rewriting | Server, but Settings still shows an unrelated local server address and secret, and the connection test checks that local address | Server, shown and tested as such |
| Meeting summaries and notes analysis | Wherever Settings › Summaries points, over a separate connection | Server, over the same authenticated channel |
| Live meeting preview | This Mac | Server |
| Final meeting transcript | This Mac | Server |
| Speaker labels | This Mac | Server |
| Speaker identification | This Mac | Voice comparison data computed on the server; the voice library and matching stay on this Mac |
| Local models | Kept loaded and restarted on every dictation | Not resident while the server serves; loaded only for a fallback |

Everything the user owns stays on the Mac (ADR 0006): recordings, transcripts, history, Dictionary, notes, named speakers and voice profiles. The server receives what each request needs and drops it when the request ends. Capture, durable recording, transcript storage, insertion and recovery stay in the app and behave as today.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - One switch puts everything on my server (Priority: P1)

My device is approved by my Mac mini. In Settings there is one Server section at the top with the server address, its state ("Approved"), the pinned fingerprint and one switch, "Use this server for everything". With it on, dictation, rewriting, summaries and meeting transcription all run on the server. I don't fill in a rewrite address, a secret or a summaries server. The connection check tests the path my work actually takes.

**Why this priority**: It removes the per-service configuration that made the current setup confusing, and every other story builds on the routing it establishes.

**Independent Test**: On an approved device, turn the switch on, then dictate, rewrite and run a meeting summary and confirm each request reaches the server and none reaches the local services or the old summaries server. Run the connection check with the server up and down and confirm it reports the real path.

**Acceptance Scenarios**:

1. **Given** the device is approved and the switch is on, **When** I dictate with rewriting enabled, **Then** recognition and the rewrite both run on the server and the result shows that the server was used.
2. **Given** the switch is on, **When** a meeting summary is generated, **Then** it runs on the server over the same authenticated channel, and the summaries server configured before this feature is not contacted.
3. **Given** the switch is on, **When** I open Settings, **Then** the Rewriting and Summaries sections show no server address or secret fields, only their behaviour settings (enable, default mode, style) and a line saying they use my server.
4. **Given** the switch is on, **When** I press the connection check, **Then** it reports whether the server answers for dictation, rewriting, summaries and meeting transcription, each on the path my work takes.
5. **Given** my device is pending, rejected or revoked, **When** I look at the Server section, **Then** the state is shown, every service uses its local path, and nothing is sent to the server.
6. **Given** I turn the switch off, **When** I dictate or a summary runs, **Then** each service uses its local path or its per-service setting, exactly as before this feature.

---

### User Story 2 - My Mac stops holding models it doesn't need (Priority: P1)

While the server serves, my Mac doesn't keep the rewrite model or the speech models loaded. The local rewrite model stops when the server takes over and no longer starts on each dictation. "Keep Parakeet loaded" doesn't apply while the server serves. Meeting models load only if a meeting has to fall back to this Mac. The models stay downloaded, so a fallback works offline.

**Why this priority**: The point of a server is that the laptop's memory, battery and fans are free. Today every remote dictation restarts the local rewrite model.

**Independent Test**: With the switch on and the device approved, run a sequence of dictations, rewrites, a meeting and a summary, and confirm no local model process is running and the app's memory stays near its unloaded baseline. Then make the server unreachable and confirm the fallback loads the local speech model and completes the dictation.

**Acceptance Scenarios**:

1. **Given** the switch is on and the device approved, **When** the app starts or the switch is turned on, **Then** the local rewrite model is stopped within 10 seconds and is not started by later dictations.
2. **Given** "Keep Parakeet loaded" is on and the server serves, **When** I dictate, **Then** the local speech model is not kept resident between dictations; the Models section explains that the setting applies when dictating on this Mac.
3. **Given** the server is unreachable during a dictation, **When** the fallback runs, **Then** the local speech model loads, completes the dictation as Feature 014 specifies, and is released again after its normal idle period.
4. **Given** the switch is turned off or the device loses approval, **When** the next dictation or rewrite runs, **Then** the local models start as they do today, and "Keep Parakeet loaded" applies again.
5. **Given** the server serves, **When** I look at the Models section, **Then** each model shows whether it is running on the server or available on this Mac for fallback.

---

### User Story 3 - Meetings are transcribed on my server (Priority: P2)

I record a meeting on my MacBook. Recording happens on the Mac as today. The live preview comes from the server while I record. When I stop, the final transcript, speaker labels and voice comparison data are produced on the server from the recorded audio, which the app sends window by window from its existing recordings. The app stores the transcript and labels and matches voices against my own voice library on the Mac. My named speakers and voice profiles never leave the Mac.

**Why this priority**: Meetings are the heaviest workload and the biggest gain from the server, but dictation and rewriting already deliver daily value, and meetings need a new server workload.

**Independent Test**: Record the same set of meetings with server and local transcription and compare transcripts, speaker labels, identification suggestions, finalization time and Mac memory. Interrupt the network during recording and during finalization and confirm no audio or transcript is lost.

**Acceptance Scenarios**:

1. **Given** the switch is on and the device approved, **When** I record a meeting, **Then** the live preview is produced on the server and the recording itself is stored on the Mac exactly as today.
2. **Given** I stop a meeting, **When** finalization runs, **Then** the final transcript and speaker labels are produced on the server and stored on the Mac, and the meeting shows that the server transcribed it.
3. **Given** I have named speakers with remembered voices, **When** a server-transcribed meeting finalizes, **Then** names and "Name?" suggestions appear with the same rules as for a locally transcribed meeting, and no voice profile or speaker name was sent to the server.
4. **Given** the server becomes unreachable during recording, **When** the meeting continues, **Then** recording is unaffected, the live preview shows a gap per FR-031, and the final transcript still covers the whole recording.
5. **Given** the server becomes unreachable during finalization, **When** it returns, **Then** finalization resumes automatically from the last completed part without re-transcribing what is stored, and until then the meeting shows it is waiting for the server with a "Run on this Mac" action (FR-031).
6. **Given** a server-produced final transcript and a local one exist for the same audio, **When** I compare them, **Then** they differ only by documented engine or timing differences.

---

### User Story 4 - I can still route one service elsewhere (Priority: P2)

Under Advanced in the Server section I can override one service at a time: run rewriting on this Mac, send summaries to another OpenAI-compatible server such as my existing ai-vm box, or keep meeting transcription local. Each override says where that service goes. My summaries server from before this feature is kept as such an override, not deleted.

**Why this priority**: The default is one server, but the owner already uses a stronger summaries model on another machine and must not lose that setup.

**Independent Test**: Set each override in turn and confirm only that service changes path. Upgrade an installation that had a Remote summaries server, a custom rewrite address and a secret, and confirm each value survives and is reachable from Advanced.

**Acceptance Scenarios**:

1. **Given** the switch is on, **When** I set summaries to a custom server, **Then** summaries go to that server, with the server as fallback when it fails before producing a result (ADR 0021), and all other services stay on the server.
2. **Given** the switch is on, **When** I set rewriting to "This Mac", **Then** rewrites use the local rewrite model, which is then allowed to load, and everything else stays on the server.
3. **Given** an installation upgraded from before this feature with a Remote summaries server, **When** the app first starts, **Then** that server, model and key appear as the summaries override, unchanged and still in use, and the user is told once that it was kept.
4. **Given** an installation with a custom rewrite address and secret, **When** the app first starts, **Then** they are kept as a "custom server" rewrite override and are not lost.

---

### User Story 5 - Several people share the server fairly (Priority: P3)

My partner and I both use the Mac mini. If my meeting is being finalized when she dictates, her dictation is not held up by my meeting. Neither of us can obtain the other's meeting audio, transcripts, summaries or voice data.

**Why this priority**: One approved user already gets full value; this extends Feature 014's fairness and isolation to the new workloads.

**Independent Test**: Run a meeting finalization for one user while another dictates, rewrites and summarizes, measure the dictation's added wait, and extend the isolation suite to every new request type.

**Acceptance Scenarios**:

1. **Given** user A's meeting finalization is running, **When** user B dictates, **Then** B's dictation is scheduled ahead of A's meeting work and its added wait stays within Feature 014's bound.
2. **Given** user A knows an identifier from user B's meeting or summary, **When** A uses it in any request, **Then** the server answers as if it does not exist and logs a content-free security event.
3. **Given** the server is saturated with meeting work, **When** a new meeting upload arrives, **Then** it receives an explicit busy result and the client waits and retries automatically per FR-031 instead of the server queuing without bound.

### Edge Cases

- The device is approved but the server lacks a workload, such as an older server without meeting transcription: that service uses its local path, the Server section says the server doesn't offer it, and the other services stay on the server.
- The switch is on and the user turns remote dictation consent off: everything returns to local paths, tokens are removed as Feature 014 specifies, and overrides are kept.
- A meeting recorded while the switch was off is finalized after it is turned on: it is finalized on the server like any other.
- The switch is turned off while a meeting finalizes on the server: the current part finishes or is abandoned and the remaining parts run locally; nothing is transcribed twice into the stored transcript.
- The server's speech model changes between the live preview and finalization: the stored pass records which engine and model produced it, as local passes already do.
- A very long meeting (two hours): upload and finalization stay bounded in memory and disk on both ends; the Mac never holds the whole meeting in memory.
- The upload is interrupted halfway through a segment: that segment is sent again; the server never transcribes partial or duplicated audio into the result.
- The user is on a metered or slow connection: meeting upload is bounded and resumable; dictation keeps priority over a meeting upload from the same Mac.
- The local rewrite model is still loading when the switch turns on: it is stopped once loaded or its start is cancelled; no orphaned model process remains.
- A summaries override server is unreachable and the LocalFlow server is also unreachable: the summary waits and retries on the server (FR-031) and offers "Run on this Mac"; the transcript is unaffected.
- Speaker identification on a server transcript where the server's voice comparison data uses a different embedding model or version than the voice library: the app does not compare across models and shows no suggestion, as Feature 010 requires.

## Requirements *(mandatory)*

### Functional Requirements

**One switch and routing**

- **FR-001**: Settings MUST have one Server section, first in Settings, showing the server address, enrollment state, pinned fingerprint, which services the server offers, and one switch that routes every service the server offers through it.
- **FR-002**: The switch MUST default to on when remote dictation is enabled and the device becomes approved, and MUST be available only after remote dictation enrollment (Feature 014 consent and pinning) has been completed.
- **FR-003**: With the switch on and the device approved, dictation recognition, rewriting, meeting summaries and notes analysis, live meeting preview, final meeting transcription, speaker labels and voice comparison data MUST be requested from the server over the authenticated, encrypted channel, except for services with a per-service override.
- **FR-004**: When the device is not approved, the server is unreachable, or the server does not offer a service, that service MUST use its local path or keep its work for a retry as FR-030 and FR-031 define, without user configuration.
- **FR-005**: With the switch on, the Rewriting and Summaries sections MUST NOT show server address, secret or model fields; they keep their behaviour settings.
- **FR-006**: The connection check MUST test the services the server serves on the path they actually use, and report whether the server answered; Settings MUST show for each service which path it uses and why, if it does not use the server. *(Amended 2026-10-01 by the owner: served services share one channel, so one answer covers them, and the per-service rows were folded into one line.)*
- **FR-007**: Every dictation, rewrite, summary and meeting MUST record whether it was produced on the server or locally, and why it fell back, in the same way Feature 014 does for dictation.

**Per-service overrides**

- **FR-008**: An Advanced area in the Server section MUST let the user override each service: rewriting (server, this Mac, custom server), summaries (server, this Mac, custom OpenAI-compatible server with model and key), and meeting transcription (server, this Mac). Dictation follows Feature 014's own switch.
- **FR-009**: A summaries custom server MUST keep ADR 0021's behaviour: it is tried first, and the LocalFlow server (or this Mac when the switch is off) is the fallback when it fails before producing a result.
- **FR-010**: On first start after upgrade, existing settings MUST be kept without loss but MUST NOT become overrides: with the switch on, every service goes to the server. A Remote summaries server's address, model and key and an off-Mac rewrite address and its secret stay stored, and apply again when the user picks Custom server for that service in Server › Advanced. *(Amended 2026-10-01 by the owner: the first version kept them as custom overrides and showed a one-time notice. On the owner's install that sent summaries to the old server under a switch named "everything", so the migration and its notice were removed.)*

**Local model residency**

- **FR-011**: While the switch is on and the device approved, and no service is overridden to this Mac, the app MUST stop the local rewrite model within 10 seconds and MUST NOT start it on dictation, launch, or game exit.
- **FR-012**: While the server serves dictation, "Keep Parakeet loaded" MUST NOT keep the local speech model resident; the model MUST load only for a fallback and release after its normal idle period.
- **FR-013**: While the server serves meetings, local meeting models (Whisper Turbo, diarization, voice embeddings) MUST load only for a meeting that falls back to this Mac.
- **FR-014**: Local models MUST stay downloaded and verified so every fallback works offline; this feature MUST NOT delete them.
- **FR-015**: When routing returns to local (switch off, approval lost, override to this Mac), local models MUST resume their current behaviour without a restart of the app.
- **FR-016**: The Models section MUST show, for each model, whether it runs on the server or is kept on this Mac for fallback, and MUST hide or explain local controls that have no effect while the server serves.

**Summaries and notes analysis on the server**

- **FR-017**: The server MUST serve meeting summaries and notes analysis to approved users over the encrypted channel, using its own rewrite model, with the same structured, versioned output schemas and validation as local analysis (constitution principle 11).
- **FR-018**: Analysis requests MUST carry only the structured transcript text and the context the local analysis uses today; the server MUST NOT retain them after the request.
- **FR-019**: Analysis work on the server MUST be scheduled after dictation and rewriting and MUST be preemptible by them, as the existing analysis gate already allows locally.

**Meeting transcription on the server**

- **FR-020**: During recording, the app MUST obtain the live meeting preview from the server, sending live audio in bounded portions; recording and durable storage MUST never wait for the server.
- **FR-021**: After Stop, the app MUST send the server the prepared audio windows that each final-pass model call needs (the same samples a local run would use), one window at a time and resumably, and the server MUST produce the final transcript with the same engine family the app uses for final meeting transcripts (ADR 0019), speaker labels (ADR 0017), and voice comparison data (ADR 0020). (Refined in planning, research R1: windows instead of the durable compressed segments, so all Mac-side preparation and resume stay unchanged.)
- **FR-022**: Results MUST arrive in parts the app can store as they complete, so an interrupted finalization resumes from the last stored part without re-transcribing it, and the final transcript replaces the preview only when the pass completes, as ADR 0016 requires locally.
- **FR-023**: Speaker identification MUST match the server's voice comparison data against the voice library on the Mac; named speakers and voice profiles MUST NOT be sent to the server. Comparison data MUST record its model, version and dimension, and MUST NOT be compared against a library built with a different model (constitution principle 10).
- **FR-024**: Each stored meeting pass MUST record whether it was produced on the server or locally, and which engine, model and geometry produced it, so passes from different engines never resume into each other.
- **FR-025**: The server MUST hold meeting audio only in memory or bounded temporary files for the duration of the work and delete it when the work completes, fails or is cancelled, including after a server restart.

**Server capacity, fairness and isolation**

- **FR-026**: Every new server workload MUST have exactly one owner per model runtime, which admits, schedules, cancels and releases work for all users (constitution principle 3); request handlers MUST NOT load models.
- **FR-027**: The server MUST schedule dictation ahead of rewriting, rewriting ahead of summaries, and summaries and meeting work last, round-robin between users within each level, with bounded per-user queues and an explicit busy result at capacity.
- **FR-028**: Every new request type MUST be scoped by the user identity from the verified token; the isolation suite MUST cover each new request type with another user's identifiers.
- **FR-029**: Server logs and the audit trail MUST contain no audio, transcript, summary or voice data, and no credentials.

**Fallback per service**

- **FR-030**: Fallback for dictation and rewriting MUST stay as Feature 014 specifies: local speech recognition when provisioned or audio kept for a retry; faithful text when the rewrite fails.
- **FR-031**: When the server is unreachable or busy for a summary or a meeting's live preview or finalization, the app MUST keep the work and retry it on the server automatically, with bounded backoff, and MUST NOT load local meeting or rewrite models on its own. The meeting or summary MUST show that it is waiting for the server and offer a "Run on this Mac" action that runs that one item locally. A live preview interrupted by an outage shows a gap; the final transcript still covers the whole recording once finalization completes. No recording, transcript or summary already stored may be lost.

**Consent**

- **FR-033**: The remote dictation consent step MUST also name meeting audio, meeting transcripts and summaries, with a new consent version; devices enrolled under the earlier consent MUST confirm the new text once before any meeting audio or summary is sent to the server, and keep using the server for dictation and rewriting until then.

**Server setup**

- **FR-032**: The server install MUST provision and verify the meeting models and enable summaries and meeting transcription without additional owner configuration beyond what Feature 014's install already requires, and the server MUST advertise which services it offers.

### Key Entities

- **Server routing setting**: the one switch, its default, and the per-service overrides (service, target: server, this Mac or custom server; for a custom server its address, model and credential reference). Belongs to the device; the credential lives in Keychain.
- **Service capability**: what the server advertises it offers (dictation, rewriting, analysis, live meeting preview, final meeting transcription, speaker labels, voice comparison data), with engine and model identity.
- **Service outcome**: per dictation, rewrite, summary and meeting pass, where it ran and the fallback reason if any.
- **Meeting upload**: the progress of sending a meeting's durable segments to the server: which segments are acknowledged, which results are stored, so it can resume.
- **Voice comparison data**: per server-transcribed speaker region, the embedding with model, version, dimension, quality and creation date; matched only on the Mac.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: A user with an approved device reaches "everything on my server" with one switch and zero address, secret or model fields filled in; verified on a fresh install and an upgraded install.
- **SC-002**: With the switch on, a session of 20 dictations with rewriting, one 20-minute meeting and its summary produces zero requests to the local rewrite model and zero loads of local speech or meeting models, and the app's memory stays within 20 MB of its unloaded baseline outside recording.
- **SC-003**: The local rewrite model is stopped within 10 seconds of the switch turning on or of launch with the switch on, in 10 of 10 trials.
- **SC-004**: Upgrading an installation with a Remote summaries server and a custom rewrite address loses none of those values, in every tested combination.
- **SC-005**: A 20-minute meeting finalizes on the server in no more than the time the same meeting takes on the owner's MacBook locally, excluding upload; finalization time and Mac memory are measured on the owner's Mac mini and reported, not estimated.
- **SC-006**: Server-produced final transcripts of the reference meetings match local final transcripts except for documented engine or timing differences, and speaker identification suggestions match on the same reference meetings.
- **SC-007**: With one user's meeting finalizing, a second user's dictation added wait stays within Feature 014's bound (at most one window's recognition time with two users).
- **SC-008**: Interrupting the network during recording, during upload and during finalization loses no recording, transcript or summary in 100% of trials, and no finalization part is transcribed twice into the stored result.
- **SC-009**: Zero cross-user cases in the extended isolation suite, and zero content or credential findings in server and client log scans of the acceptance runs.

## Clarifications

### Session 2026-10-01

- Q: When the server is unreachable or busy for summaries or meeting transcription, what happens? → A: Wait and retry on the server automatically; the item shows it is waiting and offers "Run on this Mac"; local meeting and rewrite models never load on their own (FR-031).
- Q: The constitution keeps meeting and server capabilities in separate specifications; how is that handled? → A: One specification, with a constitution exception recorded in a new ADR during planning.
- Q: Is meeting transcription on the server part of this feature or a later one? → A: Part of this feature (owner's choice over a separate feature).

## Assumptions

- The owner's server is the Mac mini (M5 Pro, 24 GB) from Feature 014, serving Qwen 3.5 4B Speed for rewriting and Parakeet v3 for dictation. Adding Whisper Turbo, diarization and embeddings on the same 24 GB machine fits by the model sizes the app already uses, but working sets are measured on the mini, not assumed.
- Meeting transcription on the server uses the same engines as the app (Parakeet for the live preview, Whisper Turbo for final transcripts, the provisioned diarization and embedding models), so server and local results are comparable and the voice library stays compatible.
- Summaries on the server use the server's own rewrite model by default. A user who wants a larger model keeps it as a summaries override (FR-009).
- The iOS companion (Features 016 and 017) gets no UI changes here, but its dictation and rewriting over the server must keep working; meeting features on iOS are out of scope.
- Exposure stays as deployed: Tailscale Funnel to the remote listener (ADR 0028 amendment); no new published port.
- Meeting audio goes to the server as the prepared windows each model call needs, read from the recordings the app already keeps; nothing is re-recorded (research R1).

## Out of scope

- Server-side storage, history or sync of any user data (ADR 0006, roadmap item 12).
- Meeting capture on the server; capture stays on the Mac.
- iOS meeting features and iOS Settings changes.
- Alternative server hardware or CUDA workers.
- Sharing voice libraries between users or devices.

## LocalFlow resource and failure acceptance

- **Bounds**: every new queue and buffer (live meeting audio in flight, upload window, result parts, per-user meeting queue on the server) has a declared capacity and overload policy; meeting audio is never held whole in memory on either side (constitution principles 2 and 6).
- **Offline**: with the server unreachable, recording, dictation (local Parakeet when provisioned) and stored transcripts keep working; summaries and finalization wait and retry on the server, or run on this Mac only when the user asks (FR-031).
- **Data preservation**: no server or network failure may delete or overwrite a stored recording, transcript, summary or voice profile; a server-produced pass replaces stored text only when it completes.
- **Resources to measure**: Mac memory with the switch on (idle, during a remote meeting, after finalization); server working sets for each new model runtime on the Mac mini; server memory with all models loaded; meeting upload bandwidth; live preview delay; finalization time for 20-minute and 2-hour meetings. Reported values must be measured on the named hardware.
- **Process**: the constitution's delivery gates say "Meeting and server capabilities remain separate specifications". The owner chose one specification; the plan MUST record this as a constitution exception in a new ADR (governance section), stating the conflict, why one specification is safe here, and the mitigations (independent user stories, separate acceptance for meeting work).
