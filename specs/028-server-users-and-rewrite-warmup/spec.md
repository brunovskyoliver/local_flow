# Feature Specification: Server mode in the Rust app, users and devices, faster first rewrite

**Feature Branch**: `028-server-users-and-rewrite-warmup`

**Created**: 2026-11-03

**Status**: Draft

**Input**: User description: "Revisit server pairing so the same application is the server and the client. On the server, onboarding offers 'this is the server', downloads every model it needs, and the app gets a Users page showing users and their connected devices. Pairing records which device belongs to which user and is done carefully; for example the owner's iPhone and Mac, both connected to a remote server, are paired with each other. Also make the first AI rewrite after the 15-minute idle unload faster." The audit in [audit.md](audit.md) is the input for this specification.

## Clarifications

### Session 2026-11-03

- Q: Apply the rewrite cold-start fix now? → A: Yes. Ship the fixed readiness check and a narrower warmup in the app that owns the model services.
- Q: May an enrolled device issue an invite for its own user? → A: Yes, with confirmation on both devices. This needs a constitution amendment to principle 15 and ADR 0039 before User Story 4 is implemented.
- Q: Which computers can be the server? → A: Apple Silicon Macs only in this feature. Windows can't host a server yet.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - The first rewrite after an idle unload is quick (Priority: P1)

The owner dictates after the local AI has been unloaded for inactivity. The rewrite arrives soon after they stop talking, and while the model is still starting, the pill says so instead of looking stuck.

**Why this priority**: It's a daily annoyance with a cause already found and a fix already in the repo.

**Independent Test**: With the model unloaded, dictate a 3-second phrase and time from key release to inserted text. Repeat 10 times with the old and new builds.

**Acceptance Scenarios**:

1. **Given** the model was unloaded, **When** the model finishes loading, **Then** the app sees it as ready within 250 ms instead of up to 5 s later.
2. **Given** the model was unloaded, **When** a rewrite arrives while the model is still warming up, **Then** no extra warmup work is queued ahead of it for prompts in the rewrite size range.
3. **Given** the model is still starting at key release, **When** the app waits for it, **Then** the pill shows that the AI is starting, and the normal state returns once it starts rewriting.
4. **Given** a warm model and two rewrites with the same instructions, **When** the second runs, **Then** it reuses the work for the shared instructions if measurement shows a gain; otherwise that change is dropped and the measurement recorded.

---

### User Story 2 - Set up this Mac as the server (Priority: P2)

On a Mac meant to be the server, the owner runs onboarding in the Rust app and picks "This is the server". The app downloads every model the server needs, asks before opening the server to the network, starts it, and gives the owner a first pairing token for their own devices.

**Why this priority**: Today only the Swift app can do this. The Rust app the owner uses every day can only be a client.

**Independent Test**: On a Mac with no LocalFlow data, finish the server path, then pair a second device with the token and dictate, rewrite and send a phone meeting through the server.

**Acceptance Scenarios**:

1. **Given** a new install on an Apple Silicon Mac, **When** onboarding starts, **Then** the owner chooses "This Mac" or "This is the server" before choosing what they use LocalFlow for.
2. **Given** "This is the server", **When** the model step runs, **Then** it lists each model with its size and the total, picks a language model that fits this Mac's memory, and downloads speech, meeting transcription, speaker separation, the AI runtime and the language model with progress, resume and retry.
3. **Given** the downloads are done, **When** the owner reaches the network step, **Then** nothing is reachable from other devices until they confirm opening the server to the network. If the server doesn't come back healthy within 60 s, the change is undone.
4. **Given** the server is running, **When** onboarding ends, **Then** the owner sees the server's address(es) and fingerprint and a pairing token for themselves, shown as text, link and QR code.
5. **Given** a phone meeting sent to this server, **When** a Mac of the same user is connected, **Then** the meeting can be handed off. Handoff is no longer off on app-created servers.
6. **Given** a Windows PC, **When** onboarding starts, **Then** the server choice isn't offered.

---

### User Story 3 - See and manage users and their devices (Priority: P3)

On the server, a Users page lists each user with their devices underneath: name, kind of device, when it was added, when it was last seen and whether it's connected now. The owner approves, revokes, renames and adds a device for a given user.

**Why this priority**: Ownership is already recorded on the server, but nobody can see it in the app.

**Independent Test**: With two users and three devices against a development server, check every field and action on the page against the server's records.

**Acceptance Scenarios**:

1. **Given** server mode is on, **When** the owner opens Users, **Then** each user appears with name, sign-in kind, state and created date, with that user's devices nested under them.
2. **Given** a device, **When** it's listed, **Then** it shows name, kind (Mac, Windows PC, iPhone or "Unknown" for older clients), added date, last seen and whether it's connected now.
3. **Given** a user, **When** the owner picks "Add device for <user>", **Then** the new token adds a device to that user by default. Creating a new person is a separate, explicit choice.
4. **Given** a user or device, **When** the owner revokes it, **Then** its connections close within 2 s and it can't reconnect.
5. **Given** server mode is off, **When** the app runs, **Then** the Users page isn't shown.
6. **Given** the page is open, **Then** it also shows active tokens (name, target user, expiry) and the recent audit log.

---

### User Story 4 - Pair my own devices with each other (Priority: P4)

The owner's Mac is connected to a server. They want their iPhone on the same account. On the Mac they choose "Add another device", the iPhone scans the code, both screens show the same short code, and the owner confirms on the Mac. The iPhone joins the Mac's user, and each device lists the other under "Your devices".

**Why this priority**: Depends on User Story 3's data and on the constitution amendment. Until then the owner can do the same thing from the Users page.

**Independent Test**: With a Mac paired to a development server, add an iPhone (or a second test client) through an invite, confirm it, and check that phone meetings reach the Mac.

**Acceptance Scenarios**:

1. **Given** an approved device, **When** the owner asks to add another device, **Then** the device gets an invite valid for 10 minutes and usable once, shown as link and QR code.
2. **Given** the new device redeems the invite, **Then** it stays pending, and both devices show the same 6-digit code derived from both device keys and the connection.
3. **Given** matching codes, **When** the owner confirms on the inviting device, **Then** the new device is approved as part of the inviting device's user. If they decline, or 10 minutes pass, it's removed.
4. **Given** a device already enrolled under another user, **When** it tries to redeem an invite, **Then** it's refused, with the reason shown.
5. **Given** any approved device, **When** the owner opens "Your devices", **Then** they see the user's devices and can remove any of them, including with "This wasn't me" for one they don't recognise.
6. **Given** an invite, **Then** it can't add a device to any other user and can't grant admin rights.

---

### Edge Cases

- The model finishes loading after the rewrite timeout: the rewrite fails as today and the text is inserted unrewritten. Nothing is lost.
- Both the Swift app and the Rust app are installed: the model services run whichever app registered them, so each shipped build must carry the fixed readiness check.
- The server Mac lacks memory or disk for the default model set: the model step shows what is missing and offers a smaller language model. The server can still start without AI rewriting, which is reported as unavailable.
- A download is interrupted: it resumes. Server mode doesn't start until speech models are verified.
- Opening to the network fails or the firewall blocks it: the 60-second rollback restores the loopback-only state and says why.
- An older client pairs without declaring its kind: shown as "Unknown".
- An invite is leaked: without confirmation on the inviting device it gives nothing, and it expires in 10 minutes.
- The inviting device is revoked while an invite is pending: the invite and the pending device are removed.
- Two invites are open at once from the same device: the newer one replaces the older.
- Server mode is turned off with devices connected: their connections close, and the Users page hides; the records stay on disk for when it's turned on again.

## Requirements *(mandatory)*

### Functional Requirements

**Rewrite cold start**

- **FR-001**: Every app build that registers the local model services MUST include the readiness check that sees a newly loaded model at once, not after a 5-second cached "not ready".
- **FR-002**: The local AI runtime MUST only run startup warmup work for the prompt size class rewrites use (about 512 tokens).
- **FR-003**: While a rewrite waits for the local model to start, the pill MUST show that the AI is starting.
- **FR-004**: The app MAY ask the runtime to reuse the shared instruction prefix between rewrites only if a measurement on the owner's hardware shows a gain of at least 150 ms per rewrite and no growth in resident memory above 512 MB. One user's text MUST never be reused for another.
- **FR-005**: Cold-start timing MUST be logged locally (model start, ready, first rewrite sent, finished) without any dictated text.

**Server mode in the Rust app**

- **FR-006**: Onboarding on Apple Silicon Macs MUST offer a role choice, "This Mac" or "This is the server", before the purpose choice. Windows MUST NOT offer it.
- **FR-007**: The server path MUST download and verify speech recognition, meeting transcription, speaker separation, the AI runtime and a language model chosen for the Mac's memory, showing each size and the total before starting.
- **FR-008**: The server MUST be able to run phone meeting handoff with what the app ships.
- **FR-009**: Opening the server to the network MUST require explicit confirmation and MUST roll back if the server isn't healthy within 60 s.
- **FR-010**: At the end of the server path the owner MUST get a pairing token for their own user, shown as text, link and QR code, plus the server addresses and fingerprint.
- **FR-011**: Settings MUST let the owner turn server mode on and off later with the same steps, and an existing Swift server-mode install MUST be detected and kept rather than duplicated.
- **FR-012**: The app's own process MUST NOT open a network listener; the server keeps running as its own background service.

**Users and devices**

- **FR-013**: In server mode the app MUST show a Users page listing users with their devices nested, with the fields in User Story 3.
- **FR-014**: Clients MUST declare their device kind (Mac, Windows PC, iPhone) when pairing or enrolling, and the server MUST store it. Devices that predate this MUST show "Unknown".
- **FR-015**: The owner MUST be able to approve, reject, revoke and rename users and devices, and create a user by name, from the page.
- **FR-016**: "Add device" MUST target the chosen existing user by default.
- **FR-017**: The page MUST show whether each device is connected now, refreshed at least every 5 s while the page is visible and not at all while hidden.
- **FR-018**: The page MUST read the server's data in a structured form, not by parsing human-readable text, and reach it only from the server Mac itself.

**Pairing a user's own devices**

- **FR-019**: An approved device MUST be able to request an invite for its own user only. Invites MUST be single use, last 10 minutes, and be stored only as a hash.
- **FR-020**: A device that redeems an invite MUST stay pending until the inviting device confirms with a signature made by its device key after the owner compares a code shown on both screens.
- **FR-021**: The comparison code MUST be derived from both device keys and the connection binding, so a relay or interceptor can't make the codes match.
- **FR-022**: Each approved device MUST be able to list its own user's devices and revoke any of them, including itself.
- **FR-023**: A device enrolled under one user MUST NOT join another user through an invite.
- **FR-024**: All device-to-device pairing MUST go through the server. No client opens a listener.
- **FR-025**: Invite creation MUST be rate-limited per device and per user and recorded in the audit log.

### Key Entities

- **User**: a person known to the server. Name, sign-in kind, state, created date. Owns devices.
- **Device**: one installation of a client. Belongs to exactly one user. Name, kind, key, state, added date, last seen, connected now.
- **Pairing token**: an admin-created, one-time way in for a new device, optionally targeting an existing user.
- **Device invite**: like a pairing token, but created by an approved device for its own user, and redeemed only into a pending state until confirmed.
- **Server role**: whether this Mac hosts the server, which models it has, and whether it's open to the network.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: With the model unloaded, the median time from key release to inserted rewrite for a 3-second dictation drops by at least 2 s against the current build, over 10 runs each on the owner's Mac.
- **SC-002**: With the model loaded, rewrite time doesn't get worse by more than 50 ms median.
- **SC-003**: A new Apple Silicon Mac goes from first launch to a running server with a pairing token in under 5 minutes of the owner's time, not counting download time.
- **SC-004**: After a device pairs, it appears on the Users page under the right user within 5 s.
- **SC-005**: Revoking a device closes its connections within 2 s.
- **SC-006**: The owner adds their iPhone to their Mac's account in under 1 minute, with no step on the server Mac.
- **SC-007**: In a test, an invite that is leaked but not confirmed never yields an approved device, and an invite never adds a device to a different user.

## Assumptions

- The rewrite model is MTPLX serving a 4B model by default, started by the app on the dictation key press, as today.
- Model and runtime sizes come from the existing descriptors: about 4.6 GB with the 4B language model.
- The server Mac stays on and logged in, as in feature 027.
- Admin actions stay on the server Mac. The network listener gets no admin routes, apart from the device-scoped invite and device-list operations in User Story 4.
- QR code rendering in the Rust app needs a small dependency, which goes through license review.
- iOS changes are limited to declaring the device kind, redeeming invites and showing "Your devices".

## Dependencies

- **User Story 4 needs a constitution amendment and ADR 0039.** Principle 15 says only the administrator issues pairing tokens. The owner approved amending it so an approved device may issue a confirmed invite for its own user only. The amendment and ADR come before User Story 4's implementation, not in this spec.
- User Story 3's device kind needs a server schema migration (v4) with the pre-migration copy feature 027 uses.

## LocalFlow resource and failure acceptance

- Rewrite: the wait for the model stays bounded by the existing rewrite timeout (20 s default). On timeout the unrewritten text is inserted. Any instruction-prefix reuse is capped at one entry of 512 MB.
- Server setup: downloads are resumable and verified. A failed step leaves the Mac as it was, apart from downloaded files the owner can delete from Settings.
- Users page: polling stops while the page or window is hidden, and each refresh reads a bounded list (at most 500 devices).
- Invites: at most 3 open invites per user and 10 creations per device per hour. Pending devices from expired invites are removed.
- Resident memory of the app with the Users page open stays within 10 MB of the idle figure. Server idle and processing targets from principle 8 still apply.
- Measurements for SC-001 and SC-002 are recorded with hardware, build and model. No measurement is claimed before it's taken.
