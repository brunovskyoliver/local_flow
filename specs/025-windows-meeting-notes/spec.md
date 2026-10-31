# Feature Specification: Windows meeting notes on a server

**Feature Branch**: `rust-features-025-026` (stacked on `remote-pairing`, owner's instruction)
**Created**: 2026-10-31
**Status**: Built autonomously; the owner waived the clarify and analyze gates
**Input**: Phase 4 of `docs/architecture/cross-platform-gpui.md`: "WASAPI capture, AAC, TPM key, Google sign-in, installer", plus Rust token pairing deferred by ADR 0037, and the Rust client gaps listed in `specs/024-gpui-desktop-views/progress.md`.

## User Scenarios & Testing

### User Story 1 - Connect the Rust client to a server (Priority: P1)

A person on Windows or macOS pastes a pairing token and server address, or signs in, and the Rust client becomes an enrolled device of that server. Turning it off removes every credential.

**Why this priority**: Nothing server-side works without a device identity, and it's the part that has to be right for security.

**Independent Test**: With a throwaway flowd on loopback and fake key storage: pair with a real token, see `remote.state` become enrolled, refresh, change the address, turn off, and see all four credentials gone.

**Acceptance Scenarios**:
1. **Given** a valid token and matching address, **When** the user pairs, **Then** the device is enrolled and approved with no fingerprint comparison, and the token is never stored or logged.
2. **Given** an address reaching another server, **When** the user pairs, **Then** the hello can't be opened by that server, the client reports a mismatch, and the token stays unspent.
3. **Given** a public `http://` address, **When** the user enters it, **Then** it's refused before any connection; on a private address, the not-TLS notice is shown.
4. **Given** an enrolled device, **When** the user changes the address to a route reaching the same server key, **Then** no re-pairing is needed; if the key differs, the change is refused.
5. **Given** an enrolled device, **When** the user turns remote off, **Then** Keychain or Credential Manager items and the device key are removed and a parked channel is closed.

### User Story 2 - Sign in with Google on Windows (Priority: P2)

A person whose server allows Google signs in from the system browser. The browser returns to a loopback address; the server's identity is verified first and pending approval is shown.

**Independent Test**: A fake authorization server and a real flowd with a test JWKS: the loopback listener takes the code, rejects a wrong `state`, exchanges with PKCE, and enrolls with the channel-bound nonce.

**Acceptance Scenarios**:
1. **Given** no Google client ID in the build, **When** sign-in shows, **Then** Google is hidden as on the Mac app.
2. **Given** a callback with a wrong `state`, **When** it arrives, **Then** it's rejected and nothing is exchanged.

### User Story 3 - Record a meeting on Windows (Priority: P1)

A person starts a meeting on Windows. The microphone and system audio (excluding LocalFlow's own output) go to AAC-LC ADTS segments in `%LOCALAPPDATA%\LocalFlow`, in the layout the database and the server already understand. A crash loses at most about a frame and the fsync window.

**Independent Test**: Pure logic on the Mac: bounded ring overload, resampling and channel handling, ADTS framing, segment rollover, `.part` recovery, using a fake source and fake encoder. Windows code: cross-compile only here; real capture is hardware acceptance.

**Acceptance Scenarios**:
1. **Given** a running meeting, **When** the device changes or a source fails, **Then** the segment finalizes and a new sequence opens, or the failure is shown; audio already written stays.
2. **Given** the ring is full because the disk stalled, **When** more audio arrives, **Then** the overload is counted and reported per the existing policy, and memory doesn't grow.
3. **Given** no microphone consent, **When** a meeting starts, **Then** the start is refused with the Settings link.

### User Story 4 - Meeting processed on the server (Priority: P1)

A recorded meeting is handed to the server (ADR 0033), and its transcript, speakers and summary merge back. If approval is pending or the server is offline, the audio stays on disk and the Notetaker page shows "Waiting for your server".

**Independent Test**: Throwaway flowd on loopback: a segment fixture goes through export, upload, processing with the stub backend, download and merge, using `bundle.sqlite` compatible with the Swift client; offline and refused paths keep the audio.

**Acceptance Scenarios**:
1. **Given** a finished meeting and an approved device, **When** the handoff runs, **Then** it's resumable after interruption and idempotent on retry, and results merge.
2. **Given** an unreachable server, **When** the handoff runs, **Then** nothing is lost and it retries later.

### User Story 5 - Install on Windows (Priority: P2)

A person runs one per-user installer with no administrator prompt. Uninstall leaves their data unless they ask otherwise. Launch at login uses the Run key.

**Independent Test**: The script and its inputs are checked statically. The installer itself isn't built or run here.

### Edge Cases
- TPM missing or disabled: key creation reports `deviceKeyUnavailable`; no software fallback, since principle 15 requires device binding and principle 5 names TPM-backed keys.
- Credential larger than the Credential Manager blob limit (2560 bytes): split or fail explicitly, never truncate.
- Refresh token reuse and device key loss: same handling as `RemoteEnrollment.deviceKeyLost`.
- Build older than 20348: process loopback unavailable; meeting start refused, with the reason.
- Elevated apps and Bluetooth profile switches during capture are hardware acceptance.

## Requirements

### Functional
- **FR-001**: `flow-platform` MUST offer secret storage: Keychain on macOS with the existing item names, Credential Manager on Windows with DPAPI protection supplied by it.
- **FR-002**: `flow-platform` MUST offer a device key: Secure Enclave P-256 on macOS; on Windows TPM 2.0 P-256 through the Platform Crypto Provider, non-exportable. Signatures MUST be ASN.1 DER as flowd verifies them.
- **FR-003**: `flow-core` MUST provide the channel, enrollment, `pair`, refresh, address edit, turn off and error mapping with the behaviour of `packages/LocalFlowCore/.../Remote/`, passing `fixtures/remote/pairing-vectors.json` and `hpke-vectors.json`.
- **FR-004**: Clients MUST apply the address rule FR-012a of Feature 027 exactly.
- **FR-005**: The Rust pairing form and link handling MUST match Swift's, including `localflow://pair` and the failure messages. Tokens stay in memory only until redeemed.
- **FR-006**: The channel pool MUST exist and `close_parked_channels` MUST work.
- **FR-007**: Google sign-in on Windows MUST use the loopback flow with PKCE, `state` and a channel-bound nonce, and bind only to a loopback address.
- **FR-008**: Windows capture MUST use event-driven shared WASAPI for the microphone and process loopback excluding this process for system audio, through a bounded ring.
- **FR-009**: Windows MUST encode AAC-LC through Media Foundation and write ADTS segments per ADR 0015 at 64 and 96 kbit/s.
- **FR-010**: Meeting state MUST use the existing store, segment rows and launch reconciliation.
- **FR-011**: Meeting handoff MUST behave as `MeetingHandoff` and `HandoffFileTransfer` do, against the unchanged wire protocol and Swift's `bundle.sqlite`.
- **FR-012**: On Windows, launch at login, free disk, high contrast, reduce motion and microphone consent MUST be real, not `Unavailable`.
- **FR-013**: A per-user installer definition MUST exist. Unsigned builds MUST be labelled as such. Nothing here is signed or published.
- **FR-014**: Logs MUST exclude tokens, audio and text. Tokens never appear in argv.
- **FR-015**: `service` rows in Feature 024's inventory that this feature settles MUST be updated; each stays open if it isn't really done.

### Success Criteria
- **SC-001**: Rust pairs with, refreshes on, and is turned off from a throwaway flowd in an automated test.
- **SC-002**: A fixture meeting completes the server path against a throwaway flowd in an automated test.
- **SC-003**: `cargo xwin` builds the client for `x86_64-pc-windows-msvc`, and `make check` passes.
- **SC-004 (open, hardware)**: A full meeting through `flowd` on real Windows hardware, the architecture exit gate. Not runnable here.

## Clarifications

### Session 2026-10-31 (answered by the agent under the owner's no-gates override; see `progress.md`)
- Q: Does 025 also build Mac meeting capture in Rust? → A: No. Windows only; Mac system audio stays with the Swift app until cutover. Mac microphone capture comes with 026.
- Q: Which installer? → A: Inno Setup per-user script. Velopack stays Feature 028's decision.
- Q: Fall back to a software key without a TPM? → A: No. Report the device key as unavailable.
- Q: Google client type on Windows? → A: Google's "Desktop app" client, read at build time. Its secret isn't confidential by Google's own design, and is optional at build time. Registering it is the owner's.
- Q: How do automated tests avoid the owner's Keychain? → A: Fakes in unit tests; the Keychain FFI is exercised only against a temporary keychain file.
