# Feature Specification: Server mode and token pairing

**Feature Branch**: `remote-pairing`

**Created**: 2026-10-31

**Status**: Draft

**Input**: User description: "Introduce a feature similar to T3 Code with remote links, so that we will have a server. However, the server will also be a client, installed somewhere, such as a Mac mini, or it does not matter. You should be able to enable it in server mode, then generate new tokens. Each user or device can receive a token to connect via any method. It should be open to the whole network. For example, if I have Tailscale running, I can connect via that. If I have another proxy running, I can connect with that. Rework this while keeping the UI intact. Perhaps create new views for this, such as pairing stuff, and so on. Take inspiration from T3 Code's work on how they handle it."

Numbered 027 because 025 and 026 are reserved for the Rust client's follow-up features (`specs/024-gpui-desktop-views/progress.md`).

## Clarifications

### Session 2026-10-31

- Q: Which clients get this first? → A: flowd, the Swift Mac app and iOS now; the Rust client after Features 025/026.
- Q: Where does the owner manage server mode and tokens? → A: Server mode and a tokens view in the LocalFlow app, plus a Pairing tab in LocalFlow Server; both use `flowd admin`.
- Q: What is a token? → A: One-time, swapped on first use for the existing device-bound credentials; 24-hour default expiry.
- Q: Is plain `http://` allowed? → A: Only on private, Tailscale and `.local` addresses; `https://` elsewhere.
- Q: How many addresses and servers can a client hold? → A: One server and one editable address, with no re-pairing while the key matches.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Pair a device with a token (Priority: P1)

The server's owner creates a named token for a person or device and sends it by any means. On the other device, the user pastes the token, confirms the existing consent text and is connected. There is no Apple or Google sign-in, no fingerprint to compare by hand and no separate approval step.

**Why this priority**: This is the feature. It also removes the sign-in dependency that keeps a self-hosted server from being usable by anyone but the app's own builds.

**Independent Test**: Against a development flowd with a temporary data directory, create a token from the command line, redeem it in the client, and dictate over the channel.

**Acceptance Scenarios**:

1. **Given** a new token, **When** a client redeems it through a route that reaches the server named in the token, **Then** the device is approved, the server key is pinned and the device can use the server.
2. **Given** a redeemed, expired or revoked token, **When** a client presents it, **Then** the client is refused with one fixed message ("This token has expired, been used or been revoked. Ask for a new one."), and no device is created. Unknown tokens get the same answer, so the server reveals nothing about which tokens exist.
3. **Given** a route that reaches a server with a different key from the one named in the token, **When** the client tries to redeem it, **Then** the client stops before sending the token and reports that the address reaches a different server.
4. **Given** the user has not confirmed consent, **When** a token is entered, **Then** no audio or text leaves the device.

---

### User Story 2 - Connect over any route (Priority: P1)

A server can be reached on the LAN, over Tailscale or through a reverse proxy. Clients need only an address that reaches it, and moving a client to another route does not require pairing again.

**Why this priority**: The owner asked for no ties to one network. The current design works only through a tunnel or Tailscale Serve, because the listener is loopback-only and clients accept only `https://`.

**Independent Test**: Run a development flowd bound to a non-loopback address and reach it directly and through a local reverse proxy from the same paired client.

**Acceptance Scenarios**:

1. **Given** server mode with network access on, **When** a client connects to any address that reaches the listener, **Then** the channel opens and the pin is checked as it is today.
2. **Given** a paired client, **When** the user edits the server address, **Then** credentials and pin are kept if the key at the new address matches, and the client reports a mismatch without sending credentials if it does not.
3. **Given** a proxy that terminates TLS, **When** audio or text passes through it, **Then** it sees only ciphertext.
4. **Given** a listener open to the network, **When** a client sends spoofed forwarding headers directly, **Then** per-client limits are not bypassed.

---

### User Story 3 - Turn on server mode on any install (Priority: P2)

On any supported Mac running LocalFlow, the owner turns on server mode. The Mac keeps working as a normal client. The owner sees whether the server is running, the addresses it can be reached at and what is still needed, such as models.

**Why this priority**: It replaces the install script and SSH for new servers, but tokens and routes (P1) are useful on a server installed by script.

**Independent Test**: On a development build using `.dev` labels and a temporary data directory, turn server mode on and off and confirm that local dictation is unaffected and no production agent or data was touched.

**Acceptance Scenarios**:

1. **Given** a normal install, **When** the owner turns on server mode, **Then** the server starts at login, with an identity created once, and the client's own dictation still works.
2. **Given** server mode on, **When** the owner turns it off, **Then** the server stops and accepts nothing, while accounts, tokens and the identity stay until the owner explicitly deletes them.
3. **Given** required models or workers are missing, **When** server mode is on, **Then** the view states what is missing and which services are unavailable.

---

### User Story 4 - Manage tokens and devices (Priority: P2)

The owner sees unredeemed tokens and paired devices, each with a label and state, and can create a token, revoke a token or revoke a device.

**Why this priority**: Revocation is required before a server may be open to the network, so the commands ship with Story 1; the view adds comfort.

**Independent Test**: Create, list and revoke tokens through the view using a fake admin runner, and through `flowd admin` against a temporary data directory.

**Acceptance Scenarios**:

1. **Given** a token just created, **When** the sheet closes, **Then** its value can never be shown again.
2. **Given** a paired device, **When** the owner revokes it, **Then** its live channels close within 1 second and its refresh fails.
3. **Given** a person with several devices, **When** the owner creates a token for that existing person, **Then** the new device joins that user and that user's data remains isolated from other users.

---

### User Story 5 - Existing installs keep working (Priority: P1)

Existing users, devices, pins and refresh tokens carry on with no action. A server installed before this feature stays loopback-only until its owner opens it.

**Why this priority**: The owner's devices rely on the Mac mini today.

**Independent Test**: Migrate a fixture database at the current schema, then refresh and open a session with a device enrolled before the migration.

**Acceptance Scenarios**:

1. **Given** a database at the current schema, **When** new flowd opens it, **Then** it migrates in a transaction and enrolled devices keep working.
2. **Given** a new client and an old server, **When** the user enters a token, **Then** the client reports that the server must be updated and sends nothing else.
3. **Given** an old client and a new server, **Then** the sign-in enrollment path still works.

### Edge Cases

- Two clients redeem one token at once: exactly one succeeds.
- The reply to a redemption is lost: the same device key can retry and get its credentials; another key cannot.
- The app link opens while the user is elsewhere: nothing is spent until the user confirms the host and consent.
- A token is redeemed while it is being revoked: revocation or redemption wins atomically, and a device that was created stays revocable.
- A device key already enrolled to another user redeems a token: refused, as enrollment does today.
- The server's identity key is replaced: every paired client reports `pin_mismatch` and needs a new token.
- The proxy strips WebSocket upgrades or rewrites paths: the client reports that the address is not a usable LocalFlow route.
- The address is plain `http://` on a private route: the client says the connection itself is not TLS while content stays encrypted. On a public address the client refuses it and asks for `https://`.
- The Keychain is locked over SSH: token commands that need no private key still work; the rest fail with a clear message.
- The server Mac's client dictates while the server is transcribing for others: the local and server model owners do not share runtimes, and the memory cost is reported, not hidden.
- Token creation floods the table: live unredeemed tokens have a fixed cap and creation past it fails explicitly.

## Requirements *(mandatory)*

### Functional Requirements

**Tokens**

- **FR-001**: The server MUST create tokens with at least 256 bits of randomness, a label, an expiry and a target that is either a new user or an existing one.
- **FR-002**: The server MUST store only a hash of each token, and MUST show the value once, at creation.
- **FR-003**: A token MUST carry the server's public key, so that holding the token authenticates the server without manual comparison. It MUST be available as text and, where a screen exists, as a QR code and an app link.
- **FR-004**: Clients MUST verify the key at the entered route against the token's fingerprint before sending the token, and MUST send the token only inside the encrypted channel sealed to that key.
- **FR-005**: Redeeming a token MUST be atomic, MUST bind the resulting device to a device-held key and MUST issue the existing short-lived access token and rotating refresh token.
- **FR-006**: Issuing a token MUST count as the administrator's approval, so the device it creates starts approved. The audit log MUST record creation, redemption, refused redemption of a known token and revocation without token values. Refusals of unknown tokens and bad signatures go to the log only, so unauthenticated callers can't push history out of the capped audit log.
- **FR-007**: Owners MUST be able to list tokens and revoke an unredeemed one. Revoking a device or user MUST use the existing path and close live channels within 1 second.
- **FR-008**: Tokens MUST NOT grant administration. Administration stays on the server Mac and is never reachable on the remote listener.

**Network**

- **FR-009**: The remote listener MUST be able to bind to non-loopback addresses when explicitly configured. Server mode MUST keep the main and admin listeners on loopback.
- **FR-010**: New server-mode installs MUST default to listening on all interfaces. An existing install MUST be adopted without rewriting its agent or binaries, and MUST keep its bind until the owner explicitly opens it; that action restores the previous configuration if the server is not healthy within 60 s.
- **FR-011**: Per-client limits MUST use forwarding headers only from a loopback peer, and MUST use the socket peer otherwise. The existing per-client and server-wide limits MUST cover redemption attempts.
- **FR-012**: Only the identity and channel routes are served on the remote listener, as today.
- **FR-012a**: Clients MUST accept `https://` on any host, and `http://` only for loopback, RFC 1918, link-local, IPv6 unique-local and Tailscale `100.64.0.0/10` or `fd7a:115c:a1e0::/48` literals, and for `.local` and `*.ts.net` names and single-label names. Anywhere else they MUST refuse `http://` before connecting. With `http://` they MUST state that the connection is not TLS while content stays encrypted.
- **FR-013**: The client MUST let the user change the server address without pairing again when the key is unchanged.

**Server mode**

- **FR-014**: Any supported Mac install MUST be able to turn server mode on and off from the LocalFlow app, which also holds a tokens view; LocalFlow Server MUST gain a Pairing tab with the same operations. A development build MUST use separate labels, ports, data and Keychain items.
- **FR-015**: A Mac in server mode MUST keep every normal client function, and its local processing MUST NOT depend on the server running.
- **FR-016**: The server-mode view MUST list reachable addresses found on the machine, its status, its fingerprint and any missing requirement.
- **FR-017**: Audit, approval and revocation code paths MUST stay single; no view may bypass `flowd admin` semantics.

**Client and UI**

- **FR-018**: Existing screens, wording and identifiers MUST stay as they are, except for new entry points. Pairing and token management are new views in the same visual language.
- **FR-019**: Consent MUST appear before a client connects with a token, using the existing consent flow.
- **FR-020**: Sign in with Apple and Google MUST keep working for servers configured for them and for already enrolled devices.
- **FR-021**: When the server is unreachable, slow, or refuses a device, clients MUST use the existing local fallback or retry behavior and MUST NOT lose audio.

**Governance**

- **FR-021a**: This feature covers flowd, the Swift Mac app, iOS and LocalFlow Server. The Rust client MUST keep building and passing its checks, unchanged in behavior; its pairing follows Features 025/026.
- **FR-022**: An ADR and a constitution amendment MUST record the changes to principle 15 (identity without an OIDC provider, token redemption) and to ADR 0032's "the client must not gain server-admin powers", before implementation of those parts.
- **FR-023**: Logs MUST exclude token values, as they exclude other credentials; `scripts/check-remote-logs.sh` MUST cover the new token prefix.

### Key Entities

- **Pairing token**: Label, hash, target user or new user, expiry, state (live, redeemed, revoked, expired), the device it created. Its value exists only on creation and in the holder's hands.
- **User**: Gains a token-created kind beside Apple and Google identities; holds no external identity.
- **Device**: Unchanged: device key, state, token hashes. Gains the link to the pairing token it came from.
- **Server address**: The route a client uses. It carries no trust; trust lies in the pinned key.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: From a created token to a working client takes under 1 minute with no sign-in and no manual fingerprint comparison (hardware acceptance).
- **SC-002**: The same paired client works over a direct address and through a proxy with no new pairing, verified by an automated test with a local proxy.
- **SC-003**: A test double acting as a different server at the address never receives a token.
- **SC-004**: Every device enrolled before migration keeps working, verified on a fixture database.
- **SC-005**: Revoking a device closes its live channels within 1 second, and no token value appears in any log or database column.
- **SC-006**: A redemption flood from one client is answered busy after the existing limit, and spoofed headers from a non-loopback peer do not change the bucket.

## Assumptions

- macOS is the only server platform, because the speech worker uses Apple frameworks and the identity key lives in the macOS Keychain. Windows clients can pair once the Rust client's enrollment exists.
- Default token lifetime is 24 hours because tokens may be sent to another person; the owner may choose 1 hour or 7 days. T3 Code uses 5 minutes, for a user at both screens.
- A Mac in server mode keeps using its local models. It uses its own server only if the owner pairs it with a token, like any other device.
- Remote administration, roles and scopes, relays, discovery and automatic TLS certificates are out of scope.
- The client app does not ship `flowd-speech` or the Whisper helper today (`scripts/install-remote-server.sh` builds them), so turning on server mode needs them added to the app or downloaded. The plan decides which and accounts for size and notarization.
- T3 Code research (2026-10-31, commit `15fe2832`): this borrows its one-time pairing code, app link and QR, host confirmation before spending a token, and session list. It departs from T3 Code by hashing tokens at rest, rate limiting redemption and binding trust to the server key, because that source shows plaintext pairing secrets, no pairing rate limit in the files read and no key pinning.

## LocalFlow resource and failure acceptance

- Bounds: live unredeemed tokens have a fixed cap. Existing channel, anonymous-channel and hello limits apply; overload answers `busy`.
- Offline: when the server is unreachable, the client falls back as it does today. Server mode failing never affects local dictation.
- Permissions: Local Network denial and a locked Keychain are reported as such where the platform says so. A firewall block can't be detected reliably, so the view shows a hint when no client has connected.
- Data: no audio or text is kept beyond existing rules. Turning off server mode deletes nothing without explicit confirmation.
- Resources: idle flowd stays within its existing targets, which are unmeasured for the open listener. RSS on a Mac running client and server together MUST be measured before it is claimed. Latency over each route is a hardware acceptance item, not part of scaffolding validation.
