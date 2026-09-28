# Feature Specification: Feature 014 — Remote Dictation on a Self-Hosted LocalFlow Server

**Feature Branch**: `t3code/remote-dictation` (existing branch; no branch-creation hook configured)

**Created**: 2026-09-27

**Status**: Draft

**Input**: User description: "Feature: opt-in remote dictation on a self-hosted, multi-user LocalFlow server (first slice of ADR 0028; constitution 2.0.0, principles 4, 5, 8, 15). Goal: let the macOS app use a LocalFlow server I run (a Mac mini, reachable through Cloudflare Tunnel without a VPN) for dictation speech recognition and rewriting, so the models live on the server and the Mac is a thin client, while local dictation keeps working as the default and as the fallback." (Full description, including users and access, dictation behavior, security and privacy, server behavior, development coexistence, out-of-scope items and success criteria, is reproduced in the sections below.)

## Boundary with earlier features

The dictation pipeline stays the same:

CAPTURE → WINDOWED RECOGNITION → ASSEMBLED → NORMALIZED → PREFERRED SPELLINGS / TERM HINTS → FAITHFUL TRANSCRIPT → optional rewrite (Features 003, 012) → SAFE INSERTION

Feature 014 changes only *where* windowed recognition and rewriting run. With remote dictation on, recognition of each filled window happens on the user's server instead of in the app, and rewrite requests travel over the same authenticated channel instead of the Feature 003 shared-token connection. Everything after the recognized windows (assembly, normalization, Dictionary spellings, context spelling, history, insertion, recovery) stays in the app and behaves as today. Local dictation stays the default and the fallback.

This is the first slice of ADR 0028. It adds accounts, device enrollment, administrator approval and one audio streaming session type. Meeting audio, iOS, server storage and alternative server hardware are later slices.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Dictate through my server with local fallback (Priority: P1)

I turned on remote dictation on my MacBook and my account is approved. I hold the shortcut, speak for twenty seconds and let go. While I speak, audio streams to my Mac mini and the windows I have filled are already transcribed there. After I release the key, only the last window is left. The faithful transcript is inserted, then the rewrite replaces it as it does today. If the server is down, too slow, busy or refuses my credentials, the app transcribes locally instead and the result tells me which path was used. I never lose a dictation.

**Why this priority**: This is the reason for the feature: the models live on the server while dictation stays as reliable as it is today.

**Independent Test**: With an approved device and a running server, dictate a fixed set of recordings remotely and locally and compare transcripts and post-release latency. Then stop the server, block the network, force a busy result and revoke the device, each mid-dictation, and confirm every dictation ends with inserted or recoverable text and a visible path indicator.

**Acceptance Scenarios**:

1. **Given** remote dictation is on and the device is approved, **When** I dictate and release the key, **Then** the faithful transcript is inserted, marked as recognized on the server, and the rewrite follows through the same channel.
2. **Given** I have spoken for more than one window, **When** I release the key, **Then** only the unfinished tail window is recognized after release; earlier windows were recognized during recording.
3. **Given** the server stops responding mid-dictation and the local speech model is provisioned, **When** the fallback threshold passes, **Then** the whole dictation is recognized locally from audio kept on the Mac, inserted, and marked as recognized locally after a server failure.
4. **Given** the server returns busy, **When** I dictate, **Then** the app falls back immediately without waiting for the threshold.
5. **Given** the server is unreachable and no local speech model is provisioned, **When** I finish a dictation, **Then** the app keeps the audio, shows the dictation as waiting for the server, retries it, and offers the text for recovery once it succeeds, without inserting it into whatever field is focused by then.
6. **Given** my Dictionary has enabled terms and the term booster is installed on the server, **When** I dictate a term remotely, **Then** term boosting applies with the same rules and result as local dictation (ADR 0027).
7. **Given** remote dictation is off, **When** I dictate, **Then** behavior is identical to the current local-only app and no network connection to the server is made.

---

### User Story 2 - Sign in and wait for approval (Priority: P1)

In Settings I turn on remote dictation. The app explains that my audio and transcripts will leave this Mac and go to the server address I enter, and asks me to confirm. I enter the server address, the app shows the server's identity to pin, and I sign in with Apple or Google. The server records me and this device as pending, and the app shows "Waiting for approval". Until an administrator approves me, the app keeps dictating locally.

**Why this priority**: Without enrollment there is no remote dictation, and the consent step is required by constitution principle 5.

**Independent Test**: Enroll a fresh device against a test server, confirm the consent step cannot be skipped, confirm the pending state receives no inference, then approve it and confirm remote dictation starts without restarting the app.

**Acceptance Scenarios**:

1. **Given** remote dictation is off, **When** I turn it on, **Then** the app shows the consent step and does nothing until I confirm it.
2. **Given** I confirmed consent and entered a server address, **When** the app first contacts the server, **Then** it shows the server identity and pins it for this device before any sign-in.
3. **Given** I signed in with Apple or Google, **When** the server verifies my identity, **Then** my account and device are pending and the app shows "Waiting for approval".
4. **Given** my account is pending, **When** I dictate, **Then** the server returns no recognition and the app dictates locally without an error dialog.
5. **Given** an administrator approves my account and device, **When** I next dictate, **Then** it goes to the server without re-signing in.
6. **Given** I turn remote dictation off, **When** I confirm, **Then** the app deletes this device's tokens and keys from Keychain and stops contacting the server.

---

### User Story 3 - Administer users and devices from the server (Priority: P1)

On the Mac mini I run `flowd admin` to list pending and approved users and devices, approve or reject them, and revoke a whole user or one device. A revocation takes effect immediately, including for a dictation that is streaming at that moment.

**Why this priority**: There is no open registration, so approval is the only way in, and revocation is the answer to a lost or stolen device.

**Independent Test**: With two enrolled users and three devices, approve, reject and revoke through the admin command and check each client's resulting state and the audit record.

**Acceptance Scenarios**:

1. **Given** users and devices are pending, **When** I list them, **Then** I see the provider, the account email or name the provider returned, device name, enrollment time and state, but no audio or text.
2. **Given** a device is streaming a dictation, **When** I revoke that device, **Then** its session ends within one second, its next token refresh fails, and the app falls back locally and shows that the device was removed from the server.
3. **Given** I revoke a user, **When** any of that user's devices connects, **Then** it is refused, while other users are unaffected.
4. **Given** I reject a pending user, **When** that identity signs in again, **Then** it stays rejected until I approve it explicitly.
5. **Given** any approval, rejection or revocation, **When** it completes, **Then** an audit entry records who, what, when and which account or device, with no audio, text or credentials.

---

### User Story 4 - Several people dictate at once without seeing each other's data (Priority: P2)

My partner and I both have approved accounts. We dictate at the same time. Neither of us waits noticeably for the other, and neither can obtain the other's audio, transcripts, term lists, cached prompts or results by any request.

**Why this priority**: Multi-user support is part of the goal, but one approved user already gets full value from Stories 1–3.

**Independent Test**: Run two and four simulated users dictating the same recordings concurrently, measure per-user added wait, and run an isolation test suite that tries every request type with another user's session, stream and request identifiers.

**Acceptance Scenarios**:

1. **Given** two approved users dictate concurrently, **When** both release the key, **Then** neither's final result waits more than one window's recognition time for the other's work.
2. **Given** user A knows an identifier from user B's session, **When** A sends any request using it, **Then** the server answers as if the identifier does not exist and logs a content-free security event.
3. **Given** the server is at capacity, **When** a new dictation arrives, **Then** it receives an explicit busy result instead of waiting in an unbounded queue, and the client falls back.
4. **Given** dictation and rewrite work are both waiting, **When** the server schedules the next job, **Then** dictation runs first, and each user's work is taken in turn so one user cannot starve another.

---

### User Story 5 - Develop this feature without disturbing the installed app (Priority: P2)

I use LocalFlow from `main` every day. Development builds from this branch install and run next to it with their own identity, data, Keychain items and server agents, so building, testing or crashing the development app never affects the installed one.

**Why this priority**: It protects the working tool during development; it does not add user value by itself.

**Independent Test**: With the installed app running and its model loaded, build, run and uninstall a development build, including its flowd and inference agents, and confirm the installed app's database, settings, Keychain items, launch agents and model state are unchanged.

**Acceptance Scenarios**:

1. **Given** the installed app is running, **When** I launch a development build, **Then** both run at once and the development build uses its own bundle identifier, Application Support directory, Keychain service names and launch agent labels.
2. **Given** a development build starts for the first time, **When** it sets up storage, **Then** it creates a new database and never opens, copies or migrates the installed app's database.
3. **Given** the development build installs its flowd and MTPLX agents, **When** both apps are running, **Then** neither app's agents replace, stop or share a port or socket with the other's.

### Edge Cases

- The network drops for a few seconds mid-dictation and returns: the client resumes or restarts the session from audio it still holds; frames are never recognized twice or out of order, and the transcript has no duplicated or missing words.
- The server restarts mid-dictation: the session is gone; the client falls back or retries with the audio it holds.
- The access token expires during a dictation: the session that already started finishes; refresh happens before the next dictation or in the background.
- The refresh fails because the device was revoked or the device key is missing (for example after restoring the Mac from backup onto new hardware): the app falls back locally and asks the user to enroll again.
- The pinned server key does not match (the server was reinstalled or someone is intercepting): the app refuses to send audio, falls back locally, and tells the user the server identity changed; re-pinning requires going through enrollment again.
- The provider identity token is expired, has the wrong audience, or is signed with an unknown key: the server rejects sign-in.
- The same provider account signs in from a second Mac: that device is a new pending device of the existing user.
- The user switches remote dictation off during a streaming dictation: that dictation completes locally.
- Dictation reaches the 180-second limit remotely: same behavior as local (Feature 001 FR-008).
- The speech worker process crashes on the server: flowd stays up, in-flight sessions get an error that triggers fallback, and the worker restarts under its supervisor.
- The server has no term booster model installed: remote dictation works without term hints, as local dictation does without the booster.
- A client sends the wrong schema version: the server rejects the message with a versioned error and the client falls back.
- The Mac sleeps mid-dictation: the recording ends as it does locally; the session is abandoned and any held audio is recognized locally or retried.
- Clock skew between Mac and server: token checks tolerate a small skew window and never depend on the client's clock for expiry decisions.

## Requirements *(mandatory)*

### Functional Requirements

**Opt-in and consent**

- **FR-001**: Remote dictation MUST be off by default and enabled per device in Settings, only after the user confirms a consent step stating that dictation audio, transcripts, Dictionary terms and rewrite text leave this Mac for the named server.
- **FR-002**: With remote dictation off, the app MUST make no connection to the server and behave exactly as the current local-only app.
- **FR-003**: Turning remote dictation off MUST remove the device's tokens, device key and pinned server key from Keychain and the Secure Enclave, and MUST NOT delete local history.

**Identity, enrollment and approval**

- **FR-004**: Users MUST sign in with Sign in with Apple or Google from the app. The server MUST verify the identity token's signature against the provider's published keys, and its issuer, audience, expiry and nonce, before creating or matching an account.
- **FR-005**: A newly seen identity and a newly seen device MUST start as pending. Pending, rejected or revoked accounts and devices MUST receive no recognition or rewriting.
- **FR-006**: There MUST be no open registration and no shared static secret for remote clients. The existing Feature 003 shared rewrite token MUST NOT grant access to remote dictation.
- **FR-007**: At enrollment the device MUST create a non-exportable Secure Enclave key and register its public key with the server. Token refresh MUST require a signature from that key.
- **FR-008**: Access tokens MUST expire within 15 minutes. Refresh tokens MUST be bound to the device key, rotated on each use, and invalid after device or user revocation. Reuse of an already rotated refresh token MUST revoke that device.
- **FR-009**: At enrollment the app MUST fetch the server's public key, show a short fingerprint, and pin it. All later sessions MUST fail closed if the server key does not match the pin.
- **FR-010**: Tokens, the pinned server key and device key references MUST be stored only in Keychain and the Secure Enclave.
- **FR-011**: The `flowd admin` command on the server MUST list users and devices with their state, and approve, reject and revoke users and single devices. Revocation MUST end the affected live sessions within one second and refuse all later requests from them.
- **FR-012**: The server MUST write an audit entry for sign-in, enrollment, approval, rejection, revocation, refresh-token reuse and cross-user access attempts. Audit entries MUST contain identifiers, times and outcomes only.

**Remote dictation**

- **FR-013**: During recording, the client MUST stream audio to the server over the authenticated channel, and the server MUST recognize each filled window during recording using the same windowing, recognition model and term-boosting rules as local dictation, so that only the tail window remains after key release.
- **FR-014**: The client MUST send the user's enabled Dictionary terms (at most 256, per ADR 0027) with each dictation session. The server MUST use them only for that session.
- **FR-015**: The client MUST keep every audio frame of the current dictation in bounded local memory or an app-private temporary file until the dictation has a final transcript, so fallback and retry never depend on the server.
- **FR-016**: The server MUST return per-window recognition results with the same evidence the local pipeline records (raw window text, token confidences needed for term hints, model identity), and the client MUST run assembly, normalization, spellings and context spelling locally as today.
- **FR-017**: The client MUST fall back when the server is unreachable, when no result arrives within a fallback threshold, when the server returns busy, when authentication or the key pin fails, or when the server returns an error. The default fallback threshold MUST be 1.5 seconds without progress after key release and MUST be adjustable in development builds.
- **FR-018**: On fallback with the local speech model provisioned, the client MUST recognize the whole dictation locally from the audio it holds. Without it, the client MUST keep the audio and retry remote recognition with backoff for up to 24 hours or until the user discards it, and MUST show the dictation as waiting.
- **FR-019**: Every dictation result and its history entry MUST record which path produced it: server, local, or local after server failure (with the failure reason code). A server result that arrives through a pending retry records the path `server` with the code `pending_retry`.
- **FR-020**: With remote dictation on and rewriting enabled, rewrite requests MUST travel over the authenticated channel of this feature using the existing rewrite schema, and MUST fall back as Feature 003 does today when the server fails. The faithful transcript MUST be inserted or saved before any rewrite.

**Channel security**

- **FR-021**: All remote traffic MUST use TLS to the tunnel edge plus an inner end-to-end encrypted channel between the app and flowd, keyed to the pinned server key, so the tunnel provider sees no audio, text, terms or tokens in clear.
- **FR-022**: Each audio and control frame in the inner channel MUST carry a sequence number that is authenticated with the frame. The server MUST reject replayed, reordered, duplicated or truncated streams and end the session.
- **FR-023**: New wire messages (sign-in, enrollment, token refresh, session start, audio frames, window results, busy and error results, session end) MUST be versioned JSON schemas in `protocol/`, following the existing `schema_version` rules; audio payloads travel inside the encrypted frames.

**Isolation and data handling**

- **FR-024**: Every request MUST be authorized and scoped by the user and device from the verified access token, never from a user or device identifier in the request body.
- **FR-025**: Audio, transcripts, Dictionary terms and rewrite text MUST be held only in memory or bounded temporary files for the duration of a request and deleted when it ends, fails or is cancelled, and at server start. Shared caches MAY hold only content identical for all users, such as fixed prompts.
- **FR-026**: The server MUST persist only accounts, devices, token state and audit metadata.
- **FR-027**: Logs on the app and the server MUST NOT contain audio, transcript text, Dictionary terms, rewrite text, identity tokens, access or refresh tokens, or keys.

**Server behavior**

- **FR-028**: flowd MUST act as the gateway (authentication, sessions, scheduling, routing) and MUST NOT load model weights. Speech recognition MUST run in a separate server-side worker process that reuses the app's existing recognition and term-boosting code; the LLM MUST stay on MTPLX.
- **FR-029**: The worker interface MUST allow a different recognition worker to be added later without changing the client protocol.
- **FR-030**: A worker crash MUST NOT stop flowd. In-flight sessions MUST receive an error that triggers client fallback, and the worker MUST be restarted.
- **FR-031**: Scheduling MUST use bounded per-user queues with round-robin between users, and MUST run dictation ahead of rewriting ahead of meeting analysis. When a queue or the worker is full, the server MUST return an explicit busy result immediately.
- **FR-032**: The speech worker MUST load its model through a single owner on the server when the worker process starts, and keep it loaded for as long as the process runs. The model is released only when the worker exits or is restarted; there is no idle release on the server.

**Development coexistence**

- **FR-033**: Development builds from this branch MUST use a bundle identifier, Application Support directory, Keychain service names and launch agent labels distinct from the installed `org.localflow.LocalFlow` app and its `org.localflow.LocalFlow.flowd` and `org.localflow.LocalFlow.mtplx` agents, and MUST use different ports or sockets.
- **FR-034**: A development build MUST NOT open, migrate, copy or delete the installed app's database, settings, Keychain items, models or launch agents.

### Key Entities

- **User account**: One person on the server. Provider (Apple or Google), provider subject identifier, display email or name as returned, state (pending, approved, rejected, revoked), created and changed times.
- **Device**: One enrolled Mac of a user. Device name, Secure Enclave public key, state (pending, approved, revoked), enrollment time, last seen time.
- **Refresh token record**: Server-side state for one device's current refresh token (hash only), its rotation lineage and expiry.
- **Audit entry**: Who acted (administrator, user, device or system), action, target, outcome and time. No content.
- **Server identity**: The server's long-term public key the app pins at enrollment, plus its fingerprint.
- **Remote dictation session** (in memory only): One dictation's encrypted stream, its sequence state, the user's term list, and window results; discarded when the dictation ends.
- **Pending remote dictation** (client, bounded): A dictation whose audio is held for retry because no local model is provisioned; audio file reference, created time, attempt count, last failure reason.

## Threat Model

| Threat | Mitigation | Residual risk |
|--------|------------|---------------|
| **Stolen refresh token** (copied from memory, logs or a backup) | Refresh requires a signature from a non-exportable Secure Enclave key on the enrolled device (FR-007). Tokens are rotated on use; reuse of an old token revokes the device (FR-008). Tokens never appear in logs (FR-027). | A thief with code execution on the enrolled Mac can use the device while they keep access to it. |
| **Stolen laptop** | Keychain items and the Secure Enclave key are unavailable without unlocking the Mac. The administrator revokes the device; live sessions end within one second and refresh fails (FR-011). | An unlocked stolen laptop can dictate until the administrator revokes the device. After revocation, live sessions end within one second and no new session is accepted. |
| **Unapproved account** (anyone with an Apple or Google account who finds the hostname) | Identity is verified against the provider, but new accounts start pending and get no inference (FR-004, FR-005). No open registration, no shared secret (FR-006). Sign-in attempts are audited. | Pending sign-ins can create account rows; the pending list may need pruning. Rate limiting of sign-in attempts is part of the plan. |
| **Replayed or reordered audio frames** | Frames are sealed in the inner channel with a per-session key and an authenticated sequence number; replays, gaps, reordering and truncation end the session (FR-022). Session keys are never reused across sessions. | None known beyond denial of service by breaking the connection, which triggers fallback. |
| **Compromised tunnel provider** (Cloudflare or anyone terminating TLS at the edge) | The inner channel is encrypted end to end to the server key pinned at enrollment (FR-009, FR-021). The edge sees sizes, timing and the hostname, not audio, text, terms or tokens. | Traffic analysis (dictation length and timing). A compromised provider at the moment of first enrollment could present its own key; the user compares the fingerprint shown in the app with the one `flowd admin` prints. |
| **One user reading another's data** | All authorization comes from the verified token (FR-024). Nothing user-specific is stored after a request (FR-025, FR-026). Shared caches hold only common content. Unknown or foreign identifiers get the same answer as nonexistent ones and are audited. | A bug in the server or worker could mix sessions in memory; the isolation test suite (SC-006) must cover every request type. |
| **Compromised server host** | Out of this feature's control: the administrator operates the server and can see audio in memory while it is processed. The consent step says so. | Accepted by design (constitution principle 5). |

## Success Criteria *(mandatory)*

All figures below are targets to measure. None have been measured. Reports must name the hardware (client Mac, server Mac mini model and memory), build, model and network conditions.

### Measurable Outcomes

- **SC-001**: Added time from key release to inserted faithful transcript, remote versus local on the same recordings, is measured on home Wi-Fi and on phone-tethered LTE through the tunnel. Target: median added time under 150 ms on Wi-Fi and under 400 ms on LTE for dictations of 5–60 seconds.
- **SC-002**: With two and with four users dictating the same recordings concurrently, no user's final result waits longer than when dictating alone by more than one window's recognition time for each other user dictating at the same moment: at most one window with two users, at most three with four.
- **SC-003**: When the server disappears mid-dictation, the time from key release to inserted text via local fallback is measured. Target: at most the fallback threshold plus local recognition time of the same recording, and 100% of such dictations produce inserted or recoverable text.
- **SC-004**: flowd resident memory is measured idle and while serving four concurrent dictations, excluding worker processes. Targets: 100 MB idle and 250 MB processing (constitution principle 8).
- **SC-005**: Remote and local transcripts of the same benchmark recordings are identical, or differ only where documented windowing timing differences apply, with term boosting on and off.
- **SC-006**: The cross-user isolation test suite, covering every request type with another user's tokens, session identifiers and stream frames, reports zero cases where one user receives any of another user's data.
- **SC-007**: A revoked device loses access to live sessions within one second and cannot refresh, in 100% of tests.
- **SC-008**: Across a development cycle of build, run, crash and uninstall of the development build, the installed app's database, settings, Keychain items and launch agents are byte-for-byte or state-for-state unchanged.
- **SC-009**: A search of client and server logs after the benchmark and isolation suites finds no audio, transcript text, Dictionary terms or credentials.

## Assumptions

- The server is an Apple Silicon Mac mini the owner operates, running flowd, the speech worker and MTPLX under launchd, and reachable through a Cloudflare Tunnel hostname the owner controls.
- The administrator is whoever can run `flowd admin` on the server machine; there is no remote admin API in this slice.
- Without a local speech model, a failed remote dictation is kept for retry for up to 24 hours or until the user discards it (FR-018).
- Rewriting falls back as Feature 003 does today: the faithful transcript is inserted unchanged when the rewrite path fails.
- The numeric targets in SC-001 (150 ms Wi-Fi, 400 ms LTE), the 1.5-second fallback threshold (FR-017) and the 15-minute access token lifetime (FR-008) are starting defaults chosen for this draft, to be confirmed or revised after measurement.
- Clients are the LocalFlow macOS app on Apple Silicon Macs with a Secure Enclave, running the same macOS versions the app already supports.
- The server uses the same speech model, windowing and term booster as the app; the term booster on the server is optional, as it is on the Mac.
- The existing Feature 003 rewrite and Feature 011 analysis routes keep working for clients that do not use remote dictation; their shared-token access is unchanged in this slice.
- Meeting capture, transcription, diarization and analysis keep running as today; meeting audio does not go to the server.
- The client stays authoritative for history (ADR 0006); the server keeps no dictation history.
- The protocol and data details (inner channel construction, frame format, audio encoding, token format) are settled in the plan within ADR 0028's decisions.

## Out of Scope

iOS client; meeting capture, transcription or diarization on the server; server-side storage or synchronization of user history; a CUDA or other non-Apple recognition worker; a web admin interface; billing; open registration; identity providers other than Apple and Google; Cloudflare Access for the app.

## LocalFlow resource and failure acceptance

- **Bounds**: Client audio held for a dictation is bounded by the 180-second dictation limit. Pending retries are bounded to 20 dictations; above that the oldest waiting dictation is not dropped silently but the user is asked to recognize it locally, copy what exists, or discard it. Server per-user queues, total sessions, frame size, session length and term list size each have explicit caps set in the plan; overflow returns busy.
- **Overload**: The server never queues without bound. Busy results trigger immediate client fallback (FR-031, FR-017).
- **Offline**: With the server unreachable, dictation works locally when the local model is provisioned. Without it, audio is kept and retried; nothing is lost (FR-018).
- **Permission and credential failures**: Pending, rejected or revoked accounts, expired tokens, a missing device key or a changed server key all fall back locally with a visible reason and never block dictation.
- **Preservation of user data**: The faithful transcript is saved in local history before insertion and before rewriting, as today. Server or network failure never destroys a recording or transcript. Temporary audio on both sides is removed after completion, failure, cancellation and at startup.
- **Model ownership**: The server speech worker has a single owner for its model runtime; flowd loads no weights. The app's local model lifecycle is unchanged and is used only on the local path.
- **Resource acceptance**: SC-001 to SC-004 are measured on the owner's hardware and reported with conditions. Constitution delivery gates for remote capabilities (threat model, authentication and revocation, per-user isolation, fallback behavior, measured network latency) apply before the feature is called done.
