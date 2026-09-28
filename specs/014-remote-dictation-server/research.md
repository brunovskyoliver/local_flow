# Research: Remote dictation on a self-hosted LocalFlow server

Feature 014, first slice of [ADR 0028](../../docs/adr/0028-remote-inference-server.md). Every decision below stays inside ADR 0028 unless it says it refines it. Nothing here was measured; figures are design bounds or targets.

## R1. Where the client splits local and remote recognition

**Decision**: Refactor `WindowedTranscriber.transcribeProduction` so the window loop takes a window source, `(sampleStart, sampleCount) async throws -> TranscriptionWindow`. The local source reads the spool and calls `ModelLifecycleCoordinator.transcribe` (or returns a prefetched window, as today). The remote source returns the `window_result` the server sent for that window. Assembly, `RecognitionAdmission`, `TranscriptionQualityDetail`, V002 boost hints, normalization, spellings and context spelling run on the same code in both cases.

**Rationale**: SC-005 asks for identical transcripts. Running the same assembly code over the same window texts is the only way to get that without a second implementation. The production windows are contiguous 239,360-sample windows starting at sample 0, so the server can cut the same windows with no shared state beyond the constant.

**Alternatives considered**: A `TranscriptionRuntime` that forwards each window over the network. It would fit the existing prefetch loop, but windows would only leave the Mac once full, so the tail (up to 15 s of audio, 957 KB) would be uploaded after key release. Rejected for latency on LTE. A server that returns a finished transcript: it would move assembly and normalization to the server and break FR-016.

## R2. Audio encoding on the wire

**Decision**: Raw little-endian Float32 mono at 16 kHz, the spool's own format, in frames of at most 16,000 samples (64,000 bytes). The client sends whatever the spool gained every 200 ms (about 12.8 KB). A 180-second dictation is at most 11.52 MB.

**Rationale**: The server recognizes exactly the samples the local path would, so SC-005 can hold. 512 kbit/s is well under typical home and LTE uplinks. Because frames stream during recording, only the last ≤200 ms is sent after key release.

**Alternatives considered**: Opus (ADR 0028's first choice): lossy, so remote and local recognition would differ and SC-005 would need a new baseline. PCM16: halves bandwidth, but quantizes normalized samples and could change recognition in rare cases. Revisit PCM16 only if the SC-001 LTE measurement shows the uplink is the bottleneck; the `format` field in `dictation_start` leaves room for it.

## R3. Transport

**Decision**: One WebSocket endpoint, `wss://<host>/v1/remote/channel`, on a dedicated flowd listener (default `127.0.0.1:8090`) that serves only `/v1/remote/*`. cloudflared forwards the tunnel hostname to that listener. A channel carries one authenticated hello and then sequential operations: one dictation, then optionally the rewrite of that dictation, or a sign-in, or a refresh. Client: `URLSessionWebSocketTask`. Server: `github.com/coder/websocket`.

**Rationale**: ADR 0028 chose WebSockets because Cloudflare tunnels them. A separate listener means the tunnel never exposes the Feature 003/011 shared-token routes. Reusing the dictation channel for its rewrite avoids a second TLS handshake after the transcript is ready.

**Alternatives considered**: Hand-written RFC 6455 framing in Go (about 300 lines of security-sensitive parsing; a small maintained library is safer). `gorilla/websocket` (fine, but coder/websocket is smaller, context-aware and has no dependencies). HTTP POST per window (a request per window adds round trips and cannot push results).

**Dependency review**: `github.com/coder/websocket`, ISC license, no transitive dependencies, maintained by Coder (formerly `nhooyr.io/websocket`). Add to `THIRD_PARTY_NOTICES.md`.

## R4. Inner end-to-end channel

**Decision**:

- Server identity: a long-term X25519 key pair created by `flowd admin init`. The fingerprint is the first 16 bytes of SHA-256 over the raw public key, shown as eight groups of four hex digits.
- Client to server: HPKE base mode, suite DHKEM(X25519, HKDF-SHA256) / HKDF-SHA256 / ChaCha20-Poly1305 (CryptoKit `.Curve25519_SHA256_ChachaPoly`; Go `crypto/hpke` with `DHKEM(ecdh.X25519())`, `HKDFSHA256()`, `ChaCha20Poly1305()`). The first binary message carries the encapsulated key and the sealed hello. Every later client frame is `Sender.Seal` on the same context.
- Server to client: the hello carries a fresh per-channel client X25519 public key. The server opens an HPKE sender context to that key with `info = client_context.Export("localflow v1 s2c info", 32)`, and sends its encapsulated key in its first frame. Only a party holding the client-to-server context can derive that info, so injected server frames fail to open.
- Every frame starts with an 8-byte big-endian sequence number in clear, which is also the AEAD additional data. The receiver requires it to equal its own counter, which HPKE also uses for the nonce. A replayed, reordered, duplicated or missing frame fails, and the channel closes. A dictation without a sealed `dictation_end` is truncated and yields no result.
- Channel binding for signatures and the OIDC nonce: `Export("localflow v1 binding", 32)`.

**Rationale**: Both directions are HPKE contexts with built-in counters, so Go stays standard-library-only for crypto and the suite matches ADR 0028's ChaCha20-Poly1305. Verified: Go 1.26.0 ships `crypto/hpke` with `NewSender`, `NewRecipient`, `Seal`, `Open`, `Export` and `ChaCha20Poly1305()`. Standalone ChaCha20-Poly1305 is not public in the Go standard library, which is why the reverse direction is a second HPKE context and not a raw AEAD.

**Alternatives considered**: AES-256-GCM frames with exporter keys (standard library too, but departs from the ADR for no gain). `golang.org/x/crypto/chacha20poly1305` (an extra dependency for one primitive). Noise (no Apple or Go standard implementation).

**Consequence**: `server/go.mod` moves from `go 1.23.0` to `go 1.26`. The release workflow reads the version from `go.mod`; local builds fetch the toolchain through `GOTOOLCHAIN=auto`.

## R5. Server tokens

**Decision**: Opaque random tokens. Access tokens are `lfa_` plus 32 random bytes in base64url; refresh tokens are `lfr_` plus 32 random bytes. The server stores only SHA-256 hashes. Access tokens live 15 minutes, measured by the server clock. Refresh tokens live 30 days, rotate on every use, and the device row keeps the previous hash to detect reuse. Reuse revokes the device (FR-008).

Refresh requires an ECDSA P-256 signature from the device's Secure Enclave key over `"localflow-v1-refresh" ‖ binding ‖ SHA-256(refresh token)`. The binding is the channel exporter value, so a captured signature is useless on any other channel and no challenge round trip is needed.

**Rationale**: Every request already looks up the device row to check approval, so a signed token format would add a key and a parser without saving a lookup. The prefixes make leaked tokens easy to find in the SC-009 log scan. Expiry never uses the client clock: the client refreshes when the server answers `token_expired`, or 12 minutes after issuance by its monotonic clock.

**Alternatives considered**: JWT access tokens (stateless, but revocation within one second needs a lookup anyway). DPoP-style signatures on every request (the Secure Enclave signature on refresh already binds the device, and the channel carries the access token only inside the encrypted hello).

## R6. Identity providers

**Decision**:

- **Sign in with Apple**: native `ASAuthorizationAppleIDProvider` in the app. The request nonce is SHA-256 of the channel-bound nonce. The server accepts only issuer `https://appleid.apple.com`, an audience in `--apple-audience` (default `org.localflow.LocalFlow`; development servers add `org.localflow.LocalFlow.dev`), and verifies RS256 against `https://appleid.apple.com/auth/keys`.
- **Google**: OAuth 2.0 authorization code with PKCE through `ASWebAuthenticationSession`, using a Google "iOS" OAuth client (which serves macOS apps) and its reverse-client-ID redirect scheme. The app exchanges the code at `https://oauth2.googleapis.com/token` and sends only the ID token to flowd. The server accepts issuers `https://accounts.google.com` and `accounts.google.com`, an audience in `--google-client-id`, requires `email_verified`, and verifies RS256 against `https://www.googleapis.com/oauth2/v3/certs`.
- Both: `exp` and `iat` checked with 60 s leeway by the server clock, `nonce` must match the channel binding, JWKS responses capped at 64 KiB and cached per `Cache-Control` (minimum 5 minutes, maximum 24 hours), unknown `kid` triggers at most one refetch per minute.
- Verification uses only `crypto/rsa`, `crypto/sha256`, `encoding/json` and `net/http`.
- Debug builds (`-tags localflow_debug`) accept a `--test-issuer` with a local JWKS file, so integration tests run without Apple or Google.

**Rationale**: Native Apple sign-in avoids a web Services ID and a server callback. Google has no native macOS API without its SDK; the PKCE flow in `ASWebAuthenticationSession` is Google's documented flow for installed apps and needs no dependency. The nonce bound to the channel means a stolen ID token cannot be replayed on another channel, so the server needs no nonce store.

**Prerequisite outside the repository**: Sign in with Apple is a restricted entitlement. Each bundle identifier that signs in (`org.localflow.LocalFlow`, `org.localflow.LocalFlow.dev`) needs an App ID with the capability and a provisioning profile embedded at signing. `scripts/dev-macos.sh` currently signs with an identity and no profile, so the development build needs a profile for team QUB47S3XTF. Google needs an OAuth client created in the owner's Google Cloud project. Both are owner actions; the plan does not assume they exist.

**Alternatives considered**: Sign in with Apple through the web flow (needs a Services ID and a public `form_post` callback on flowd). The Google Sign-In SDK (a large dependency for one token). A self-hosted OIDC provider (rejected in ADR 0028).

## R7. Device key and client secrets

**Decision**: `SecureEnclave.P256.Signing.PrivateKey` created at enrollment; its `dataRepresentation` (an encrypted handle usable only on this Mac's Secure Enclave) is stored in Keychain. Keychain generic passwords under service `<bundle id>.remote`, accounts `device-key`, `refresh-token`, `access-token`, `server-key`. The server URL and display state live in `UserDefaults`. Turning remote dictation off deletes all four items (FR-003).

**Rationale**: CryptoKit Secure Enclave keys need no entitlement when the app stores the handle itself. The service name comes from the bundle identifier, so the development build can never read the installed app's items (FR-033). The existing `RewriteCredentialStore` shows the Keychain pattern that already works for this unsandboxed app.

**Alternatives considered**: `kSecAttrTokenIDSecureEnclave` keys in the data-protection keychain (needs a keychain access group entitlement and a provisioning profile for every build).

## R8. Server storage

**Decision**: SQLite at `<data-dir>/flowd-remote.sqlite` through `modernc.org/sqlite`, in WAL mode, with `user_version` migrations. Tables in [data-model.md](data-model.md).

**Rationale**: Constitution principle 7 requires SQLite for structured data, and ADR 0028 names it. flowd is built with `CGO_ENABLED=0` (`scripts/bundle-local-ai.sh`), so a pure-Go driver keeps the build unchanged.

**Dependency review**: `modernc.org/sqlite` is BSD-3-Clause and pulls `modernc.org/libc`, `modernc.org/mathutil`, `modernc.org/memory` (BSD-3-Clause) and a few small MIT/BSD modules. The implementation task records the exact module list from `go mod graph` in `THIRD_PARTY_NOTICES.md` and measures its effect on SC-004 idle RSS. `github.com/mattn/go-sqlite3` was rejected because it needs cgo.

## R9. Revocation within one second

**Decision**: `flowd admin` writes to the same SQLite file from its own process. The running flowd polls `PRAGMA data_version` every 250 ms on a dedicated connection. When it changes, flowd reloads user and device states (a few hundred rows at most) and closes every live channel whose user or device is no longer approved, sending a sealed `error{code:"revoked"}` first when the channel is writable.

**Rationale**: Worst case is 250 ms plus the close, inside the SC-007 bound, with no admin socket or IPC. `data_version` is a local read and costs nothing when nothing changed.

**Alternatives considered**: An admin Unix socket to the running flowd (a second control surface to secure). Signals (cannot say what changed).

## R10. Speech worker

**Decision**: A headless Swift command-line target, `flowd-speech`, in the existing Xcode project. It compiles the app's recognition sources (`FluidAudioEngine.swift`, `VocabularyBoost.swift`, `ModelLifecycleCoordinator.swift`, `ModelDescriptor.swift`, `ModelProvisioner.swift` and the boundary types they need) and links FluidAudio. It hosts one `ModelLifecycleCoordinator` configured with only the speech factory; each job acquires a lease with that job's boost terms, recognizes one window and ends the lease. flowd starts it as a child process and talks over stdin/stdout ([speech-worker-ipc.md](contracts/speech-worker-ipc.md)).

**Rationale**: FR-028 and ADR 0028 require reuse of the app's recognition and term-boosting code. The lifecycle coordinator is already the single owner with a keep-loaded rule, which covers FR-032 and constitution principle 3. A child process on pipes gives flowd crash detection and restart (FR-030) without another launch agent, and gives the worker no network surface.

The first implementation task checks the compile closure. If `ModelLifecycleCoordinator` pulls in meeting or diarization types that drag the UI along, the shared protocol types move into one small file both targets compile. The worker must not import SwiftUI, AppKit or GRDB.

**Model files on the server**: `flowd-speech provision --models <dir>` runs `ModelProvisioner` with the app's pinned descriptors (`parakeet-v3.json`, optional `parakeet-ctc-110m.json`), so the server verifies the same hashes as the app.

**Model residency**: the worker calls `setKeepLoaded(true)` and loads the runtime before it sends `ready`, so the model stays resident for the life of the process (FR-032). There is no idle release and no flag for it; the runtime is released only when the worker exits or flowd restarts it. The server is a dedicated machine, so the resident working set is measured (T092) rather than reclaimed.

**Alternatives considered**: A worker launch agent with a Unix socket (one more label and restart policy to manage, and flowd would still need to detect crashes). Python NeMo worker (ADR 0028 defers non-Apple workers; it would also need a new quality baseline).

## R11. Scheduling and bounds

**Decision**: Recognition jobs are single windows. flowd keeps one bounded queue per user (at most 2 waiting window jobs) and a round-robin cursor over users with waiting jobs; the worker runs one job at a time. Rewrites keep the existing rewrite handler's limit (2 in flight) and gate against analysis, add a per-user limit of 1, and do not start while any dictation window is waiting for the worker. Meeting analysis keeps its existing rewrite-first gate and preemption.

| Bound | Value | On overflow |
| --- | --- | --- |
| Open channels, total | 16 | WebSocket upgrade refused with HTTP 503 |
| Channels per device | 2 | `busy` |
| Dictation sessions, total | 8 | `busy` |
| Dictation sessions per user | 1 | `busy` |
| Waiting window jobs per user | 2 | session ends with `busy` |
| Session length | 2,880,000 samples plus one 16,000-sample frame of slack | `limit_exceeded` |
| Audio frame | 16,000 samples (64,000 bytes) | `limit_exceeded` |
| Control message | 65,536 bytes | `limit_exceeded` |
| Boost terms | 256 terms and 1,024 governed spellings, each ≤ 128 UTF-8 bytes | `invalid_message` |
| Per-session audio buffer on the server | one window (957,440 bytes) plus one frame | not reachable; the tail flushes each full window to the queue |
| Worker job deadline | 30 s | worker killed and restarted; job gets `worker_unavailable` |
| Pending accounts | 100 | sign-in answers `busy` and is audited |
| Sign-in and enrollment hellos | 10 per minute, whole server | `busy` |
| Audit rows | 10,000 | oldest rows pruned |
| Channel idle | 30 s, or 5 minutes while an enrollment waits for the ID token | channel closed |

**Rationale**: With serial window jobs and round-robin, a user's tail window waits behind at most one window from each other user with waiting work, so at most N−1 windows with N users releasing together. That is the SC-002 bound. Per-user caps mean one user cannot fill the queue. The worker runs on a different resource from MTPLX, so dictation-before-rewrite only needs rewrites to yield while windows are waiting.

## R12. Fallback and retry on the client

**Decision**:

- The client opens the channel at key press, beside capture, and sends `dictation_start` as soon as authenticated. Audio frames start as the spool grows.
- Fallback triggers (FR-017): connection failure, `busy`, any `error`, a pin mismatch, authentication failure, or no sealed frame for 1.5 s after `dictation_end` while results are outstanding. The server sends `progress` every 500 ms while a session's windows wait or run, so a long queue does not look like a dead server. The threshold is `RemoteDictationSettings.fallbackThreshold`, adjustable only in development builds.
- If the channel fails while recording continues, the client reconnects once and restarts the session from sample 0 using the spool. After key release there is no restart; it falls back.
- In remote mode the app does not acquire the local model lease at key press. On a failure it starts acquisition immediately, so a cold load overlaps the rest of the recording when possible. SC-003 reports load time separately.
- Local fallback runs the unchanged local transcriber over the whole spool, as spec scenario 3 requires. Remote windows already received are discarded.
- Without a provisioned local model, the spool file moves to `PendingAudio/` and a `pending_remote_dictations` row is written in the same step (at most 20 rows, 24 h). Retries back off at 10 s, 30 s, 2 min, then every 10 min. On success the transcript is committed to history in `needsReview` recovery state and a notification offers it; nothing is inserted into whatever field has focus later (ADR 0014).

**Rationale**: The spool already keeps every sample on disk for the whole dictation (FR-015), so fallback and retry need no new buffer. Restarting from sample 0 is simpler than a resume protocol and cannot recognize a frame twice within one session.

## R13. Development build identity

**Decision**: A `dev` variant built from the same scheme with command-line overrides in `scripts/dev-macos.sh --dev` (and `make run-dev`):

| Item | Installed app | Development variant |
| --- | --- | --- |
| Bundle identifier | `org.localflow.LocalFlow` | `org.localflow.LocalFlow.dev` |
| App path | `/Applications/LocalFlow.app` | `/Applications/LocalFlow Dev.app` |
| Application Support | `LocalFlow` | `LocalFlow Dev` |
| Logs | `~/Library/Logs/LocalFlow` | `~/Library/Logs/LocalFlow Dev` |
| Keychain services | `org.localflow.LocalFlow.*` | `org.localflow.LocalFlow.dev.*` |
| Agent labels | `org.localflow.LocalFlow.flowd`, `.mtplx` | `org.localflow.LocalFlow.dev.flowd`, `.mtplx` |
| Loopback ports (flowd, MTPLX) | 8080, 8000 | 18080, 18000 |
| Remote server label, listener | `org.localflow.LocalFlow.remote`, 8090 | `org.localflow.LocalFlow.dev.remote`, 18090 |
| Server data directory | `LocalFlow Server` | `LocalFlow Server Dev` |

A new `AppIdentity` type reads the bundle identifier and two Info.plist keys (`LocalFlowVariant`, `LocalFlowPortBase`) and replaces every hard-coded identifier, path, label and port listed above. A build phase renders the agent plists with the variant's label and ports. `dev-macos.sh --dev` refuses to touch `/Applications/LocalFlow.app`.

**Rationale**: FR-033 and FR-034. Today `make run` replaces the installed app with the branch build under the same identity, which is exactly what User Story 5 forbids. Command-line overrides avoid adding a build configuration to the hand-maintained `project.pbxproj`.

**Alternatives considered**: A separate Xcode configuration (more pbxproj churn, same result). A separate macOS user account for development (protects data but not the owner's workflow).

## R14. Rewrite over the channel

**Decision**: Extract the body of `rewrite.Handler.rewrite` into `Run(ctx, req, emit func(Event) error) ErrorCode`, used by the HTTP handler and by the channel's `rewrite` operation. On the client, `RemoteRewriteTransport: RewriteTransporting` sends the unchanged rewrite request JSON inside the channel and yields the same `RewriteTransportItem`s. A routing transport picks it when remote dictation is on and the device is approved, and the admission step skips the shared-token credential check in that case.

**Rationale**: FR-020 requires the existing schema over the new channel. `RewriteCoordinator`, attempt storage, fallback categories and delivery stay untouched.

## R15. Log hygiene

**Decision**: Channel and admin logs carry channel, user and device numeric IDs, operation type, byte and sample counts, durations and error codes. They never carry message bodies, terms, tokens, keys, provider emails, or ID token claims other than the provider name. `scripts/check-remote-logs.sh` scans client unified-log exports and flowd logs after the test suites for `lfa_`, `lfr_`, `eyJ` (JWT), fixture phrases and fixture terms (SC-009).

## Open items that need measurement, not research

SC-001 to SC-004 and SC-007 need the owner's Mac mini and network. The 1.5 s threshold, 15-minute token lifetime and the SC-001 targets are starting values to revisit after measurement.
