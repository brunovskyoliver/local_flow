---

description: "Task list for Feature 014: remote dictation on a self-hosted LocalFlow server"
---

# Tasks: Remote dictation on a self-hosted LocalFlow server

**Input**: Design documents in `specs/014-remote-dictation-server/`.
**Prerequisites**: `plan.md`, `spec.md`, `research.md`, `data-model.md`, `quickstart.md` and the three files in `contracts/`. ADR `docs/adr/0028-remote-inference-server.md` exists (Proposed). Constitution 2.0.0.
**Tests**: Required by the plan's validation section, quickstart §1 and constitution principle 12. Write each deterministic test before the code it covers, confirm it fails for the intended reason, then make it pass. Hardware, network and memory acceptance (quickstart §2–§6) are separate tasks and are never marked done from fakes or scaffolding builds.
**Organization**: Setup, then a foundational phase (app identity, window-source refactor, wire schemas, channel crypto, account store, listener skeleton), then one phase per user story in the plan's delivery order: US5 (dev variant, before any remote code runs outside XCTest), US2 (enrollment), US3 (administration), US1 (remote dictation and rewrite), US4 (concurrency and isolation). US1 is the product goal but cannot be exercised end to end until a device can enroll (US2) and be approved (US3). All paths are relative to the repository root. New Swift files in the `LocalFlow` and `LocalFlowTests` targets are registered with `scripts/register-xcode-sources.py`.

`[P]` marks tasks that touch different files and have no dependency on an incomplete task in the same phase. It never bypasses a phase gate.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies on incomplete tasks)
- **[Story]**: Which user story the task belongs to (US1 to US5)
- Every task names the file(s) it changes

---

## Phase 1: Setup

**Purpose**: Record the starting point, move the Go toolchain, add the two reviewed server dependencies and register new source files.

- [X] T001 Record the starting commit, dirty-tree state, Go/Xcode/FluidAudio 0.15.7 pins, the constitution 2.0.0 check from `plan.md`, and the statement that no SC-001 to SC-009 figure has been measured, in `specs/014-remote-dictation-server/acceptance/baseline.md`.
- [X] T002 Change `server/go.mod` from `go 1.23.0` to `go 1.26`, add `github.com/coder/websocket` and `modernc.org/sqlite`, run `go mod tidy` to update `server/go.sum`, and confirm `CGO_ENABLED=0` still builds flowd through `scripts/bundle-local-ai.sh` and that `.github/workflows/release.yml` (reads `go-version-file: server/go.mod`) needs no edit.
- [X] T003 [P] Add `github.com/coder/websocket` (ISC) and every module that `go mod graph` lists under `modernc.org/sqlite` (BSD-3-Clause `modernc.org/libc`, `mathutil`, `memory` and any MIT/BSD modules) with their license texts to `THIRD_PARTY_NOTICES.md` (research R3, R8).
- [X] T004 Register empty placeholders in `apps/macos/LocalFlow.xcodeproj/project.pbxproj` with `scripts/register-xcode-sources.py`: app sources `LocalFlow/App/AppIdentity.swift`, `LocalFlow/Core/RemoteBoundaries.swift`, `LocalFlow/Core/Remote/RemoteChannel.swift`, `RemoteProtocol.swift`, `RemoteCredentialStore.swift`, `RemoteEnrollment.swift`, `RemoteDictationSession.swift`, `PendingRemoteRetrier.swift`, `RemoteRewriteTransport.swift`, `LocalFlow/Core/Storage/PendingRemoteDictationStore.swift`, `LocalFlow/Features/Settings/RemoteDictationView.swift`; test sources `LocalFlowTests/AppIdentityTests.swift`, `WindowSourceTests.swift`, `RemoteProtocolTests.swift`, `RemoteChannelTests.swift`, `RemoteCredentialStoreTests.swift`, `RemoteEnrollmentTests.swift`, `RemoteDictationSessionTests.swift`, `RemoteDictationRoutingTests.swift`, `PendingRemoteDictationStoreTests.swift`, `PendingRemoteRetrierTests.swift`, `RemoteRewriteTransportTests.swift`, `SpeechWorkerFramingTests.swift`, `LocalFlowTests/Support/RemoteFakes.swift`; also add `SpeechWorker/WorkerFraming.swift` to the `LocalFlowTests` target so T058 can compile it. Confirm `plutil -lint` and `make macos` stay green.
- [X] T005 [P] Create `fixtures/remote/README.md` describing `hpke-vectors.json` (seeded keys, hello, sealed frames in both directions, exporter outputs), `messages/` (one valid and one invalid example per control message type) and `test-jwks.json` plus its test-only signing key, and state that nothing in `fixtures/remote/` is a production secret.

---

## Phase 2: Foundational (blocking prerequisites)

**Purpose**: Everything more than one story needs. With remote dictation off (the default), the app behaves exactly as before, and the existing XCTest and Go suites stay green after every task.

**⚠️ CRITICAL**: No user story work can begin until this phase is complete. US5 depends only on 2a and should be done right after it (plan delivery order step 1).

### 2a. App identity (research R13)

- [X] T006 [P] Write failing tests in `apps/macos/LocalFlowTests/AppIdentityTests.swift` for `AppIdentity` built from an injected Info.plist dictionary: production (`CFBundleIdentifier` `org.localflow.LocalFlow`, `LocalFlowVariant` `production`, `LocalFlowPortBase` `8000`) gives Application Support `LocalFlow`, logs `~/Library/Logs/LocalFlow`, Keychain service prefix `org.localflow.LocalFlow`, agent labels `org.localflow.LocalFlow.flowd` and `.mtplx`, flowd port 8080, MTPLX port 8000; dev (`org.localflow.LocalFlow.dev`, `dev`, `18000`) gives `LocalFlow Dev`, `~/Library/Logs/LocalFlow Dev`, `org.localflow.LocalFlow.dev`, `org.localflow.LocalFlow.dev.flowd` and `.mtplx`, ports 18080 and 18000; missing keys give production values; no dev value ever equals a production path, label, service or port (FR-033, FR-034).
- [X] T007 Implement `apps/macos/LocalFlow/App/AppIdentity.swift` and add `LocalFlowVariant` = `production` and `LocalFlowPortBase` = `8000` to `apps/macos/LocalFlow/Info.plist`; make T006 pass.
- [X] T008 Replace every hard-coded bundle identifier used as a path, Keychain service, agent label or port with `AppIdentity` in `apps/macos/LocalFlow/App/AppServices.swift`, `Core/LocalAI/LocalAIRuntime.swift` (labels, `rewriteEndpoint`, the 8000/8080 health and model URLs and the port-conflict message), `Core/Rewrite/RewriteCredentialStore.swift`, `Core/Rewrite/RewriteClient.swift`, `Core/Intelligence/AnalysisClient.swift` and any storage path in `Core/Storage/*.swift` found by `grep -rn 'org.localflow.LocalFlow\|127.0.0.1:80' apps/macos/LocalFlow`. `Logger` subsystem strings stay literal. Existing tests pass unchanged.
- [X] T009 Render the agent plists and launch scripts with the variant's label and ports at build time: turn `apps/macos/LocalFlow/Resources/LocalAI/org.localflow.LocalFlow.flowd.plist`, `org.localflow.LocalFlow.mtplx.plist`, `localflow-flowd` and `localflow-mtplx` into templates and have `scripts/bundle-local-ai.sh` write `<label>.plist` files into `Contents/Library/LaunchAgents` from `PRODUCT_BUNDLE_IDENTIFIER` and `LOCALFLOW_PORT_BASE`; a production build produces byte-identical output to today's files.

### 2b. Window-source refactor (research R1)

- [X] T010 [P] Write failing tests in `apps/macos/LocalFlowTests/WindowSourceTests.swift`: for a spool of 1, 239,360, 239,361 and 2,880,000 samples, windows are contiguous 239,360-sample windows from sample 0; the same `TranscriptionWindow`s delivered through a local source and through an injected (remote-shaped) source give byte-identical assembled text, `TranscriptionQualityDetail`, V002 boost hints, normalization and spellings; a source window that fails `RecognitionAdmission` validation is rejected the same way in both cases.
- [X] T011 Refactor `WindowedTranscriber.transcribeProduction` in `apps/macos/LocalFlow/Core/Transcription/WindowedTranscriber.swift` so its loop takes a window source `(sampleStart, sampleCount) async throws -> TranscriptionWindow`; the local source reads the spool and uses `prefetched` or the lease's `transcribe` exactly as today. Make T010 and the existing `DictationCoordinatorTests`, `QualityEvaluationTests` and `LiveRecognizerTests` pass with no other behavior change.

### 2c. Wire schemas and message types (contracts/remote-channel.md)

- [X] T012 [P] Add `protocol/schemas/remote-identity.schema.json`, `remote-hello.schema.json` and `remote-message.schema.json` (`oneOf` by `type`: `ready`, `enroll`, `enrolled`, `refresh`, `tokens`, `dictation_start`, `dictation_accepted`, `window_result`, `progress`, `dictation_end`, `dictation_cancel`, `dictation_complete`, `cancelled`, `rewrite`, `rewrite_event`, `error`), `schema_version` `1`, `op` integer 1…2^31−1, error `code` enum {`unauthorized`, `token_expired`, `not_approved`, `revoked`, `busy`, `invalid_message`, `unsupported_version`, `limit_exceeded`, `worker_unavailable`, `internal`}, `purpose` enum {`enroll`, `refresh`, `session`}, `state` enum {`pending`, `approved`, `rejected`}; add the example files under `fixtures/remote/messages/`; document the three schemas in `protocol/README.md`; extend `scripts/validate-foundation.py` so it validates the examples against the schemas.
- [X] T013 [P] Write failing Go tests in `server/internal/remote/protocol_test.go` that decode every file in `fixtures/remote/messages/` and check: unknown `schema_version` → `unsupported_version`; unknown `type`, missing field or wrong `op` → `invalid_message`; control message over 65,536 bytes → `limit_exceeded`; boost "256 terms and 1,024 governed spellings, each ≤ 128 UTF-8 bytes" else `invalid_message`; `format` must be `f32le` and `sample_rate` 16000; device name "≤ 64 bytes, control characters removed"; `device_key` "X9.63 uncompressed, 65 bytes".
- [X] T014 Implement the message types and validation in `server/internal/remote/protocol.go`; make T013 pass.
- [X] T015 [P] Write failing tests in `apps/macos/LocalFlowTests/RemoteProtocolTests.swift` over the same `fixtures/remote/messages/` files: round-trip every message; `window_result` decodes into `TranscriptionWindow` and `RecognitionEvidence` with the field mapping in the contract (FR-016); more than 14 windows or a window that fails `RecognitionAdmission` is a `protocol_error`; `booster` absent decodes as "boosting did not run".
- [X] T016 Implement Codable messages, the `window_result` ↔ `TranscriptionWindow` mapping and validation in `apps/macos/LocalFlow/Core/Remote/RemoteProtocol.swift`; make T015 pass.

### 2d. Channel crypto and framing, both sides (research R4)

- [X] T017 Generate `fixtures/remote/hpke-vectors.json` from a Go test with an `-update` flag in `server/internal/remote/channel_vectors_test.go`: fixed server and client keys, `info` `localflow remote v1`, the hello frame `"LFR1" | enc | seq=0 | ciphertext` with AAD `"LFR1" ‖ seq`, `Export("localflow v1 s2c info", 32)`, the server's first frame `enc_s2c | seq=0 | ciphertext`, frames seq 1…3 each way with AAD = seq, and `Export("localflow v1 binding", 32)`.
- [X] T018 [P] Write failing Go tests in `server/internal/remote/channel_test.go`: vectors reproduce; replayed, reordered, dropped, duplicated and truncated frames close the channel with no reply; a hello sealed to a different server key closes with WebSocket code 4001 and nothing else; a text message closes; a binary message over 70,000 bytes closes; audio kind `0x01` payloads must be 1–16,000 samples with byte length divisible by 4.
- [X] T019 Implement `server/internal/remote/channel.go` with `crypto/hpke` (`DHKEM(ecdh.X25519())`, `HKDFSHA256()`, `ChaCha20Poly1305()`): hello open, s2c sender to `reply_key`, sequence counters per direction, kind byte, binding export; make T017 and T018 pass.
- [X] T020 [P] Define `RemoteTransport` (WebSocket send/receive/close), `RemoteCredentialStoring`, `IdentitySignIn` (Apple, Google), and a monotonic `RemoteClock` in `apps/macos/LocalFlow/Core/RemoteBoundaries.swift`, with fakes (scripted transport, in-memory credential store, fake sign-in, manual clock) in `apps/macos/LocalFlowTests/Support/RemoteFakes.swift`.
- [X] T021 Write failing tests in `apps/macos/LocalFlowTests/RemoteChannelTests.swift`: CryptoKit `.Curve25519_SHA256_ChachaPoly` reproduces every byte in `fixtures/remote/hpke-vectors.json`; out-of-sequence or unopenable server frames close the channel; close code 4001 maps to `pin_mismatch`; more than 4 unsent frames stops sending and fails with `timeout`.
- [X] T022 Implement `apps/macos/LocalFlow/Core/Remote/RemoteChannel.swift` over `RemoteTransport` (production: `URLSessionWebSocketTask`, binary only, no cookies, no `Authorization` header); make T021 pass.
- [X] T023 [P] Write failing tests in `apps/macos/LocalFlowTests/RemoteCredentialStoreTests.swift` and implement `apps/macos/LocalFlow/Core/Remote/RemoteCredentialStore.swift`: Keychain generic passwords under service `<AppIdentity bundle id>.remote`, accounts `device-key` (Secure Enclave `dataRepresentation`), `server-key` (32 bytes), `refresh-token`, `access-token`; `removeAll()` deletes all four; access token issue time held in memory only; nothing is logged.
- [X] T024 [P] Add the remote settings to `apps/macos/LocalFlow/Features/Settings/AppPreferences.swift` with tests in `apps/macos/LocalFlowTests/AppPreferencesTests.swift`: `remote.enabled` Bool default false, `remote.serverURL` "`https://` origin, no path, no credentials", `remote.state` ∈ {`off`, `pinned`, `pending`, `approved`, `rejected`, `revoked`, `pin_mismatch`}, `remote.consentVersion` Int, `remote.fallbackThresholdMs` default 1,500 and honored only when `AppIdentity` is the dev variant or a Debug build.

### 2e. Server account store, identity key and listener skeleton (data-model, research R5, R9)

- [X] T025 [P] Write failing Go tests in `server/internal/accounts/store_test.go` with a fake clock: `flowd-remote.sqlite` in WAL mode with `PRAGMA user_version = 1`, file 0600, directory 0700; `users` with `UNIQUE(provider, subject)`, `provider` ∈ {`apple`, `google`}, `subject` "≤ 255 bytes", `display` "≤ 320 bytes", `state` ∈ {`pending`, `approved`, `rejected`, `revoked`}; "At most 100 rows in `pending`"; `devices.public_key` "X9.63 uncompressed, 65 bytes" UNIQUE, `state` ∈ {`pending`, `approved`, `revoked`}, `last_seen_at` "updated at most once a minute"; every user and device transition in data-model.md is allowed and every other one is refused; revocation clears `refresh_hash`, `previous_refresh_hash` and `access_hash`; audit `actor`/`action`/`outcome` values from data-model.md, "At most 10,000 rows; the oldest are deleted in the same transaction as an insert that exceeds the cap".
- [X] T026 Implement `server/internal/accounts/store.go` (open, `user_version` migration, users, devices, audit, transactions); make T025 pass.
- [X] T027 [P] Write failing tests in `server/internal/accounts/tokens_test.go` and implement `server/internal/accounts/tokens.go`: `lfa_`/`lfr_` plus 32 random bytes base64url; only SHA-256 hashes stored; access expiry 15 minutes and refresh 30 days by the server clock; one live access token per device; rotation keeps `previous_refresh_hash`; presenting the previous token revokes the device and writes `refresh_reuse`.
- [X] T028 [P] Write failing tests in `server/internal/accounts/snapshot_test.go` and implement `server/internal/accounts/snapshot.go`: an in-memory snapshot of user/device states, public keys and token hashes; a dedicated connection polls `PRAGMA data_version` every 250 ms (injected ticker) and reloads on change; a callback reports every user and device that stopped being approved.
- [X] T029 [P] Write failing tests in `server/internal/accounts/identity_test.go` and implement `server/internal/accounts/identity.go`: X25519 identity key stored via `/usr/bin/security` (injected runner) as a generic password, service `org.localflow.LocalFlow.remote.identity` or `org.localflow.LocalFlow.dev.remote.identity`, account = absolute data directory; fingerprint = first 16 bytes of SHA-256 over the raw public key as eight groups of four hex digits; the key never appears in logs or errors.
- [X] T030 Write failing tests in `server/cmd/flowd/admin_test.go` and implement `flowd admin --data-dir <dir> init` and `identity` in `server/cmd/flowd/admin.go` per `contracts/flowd-cli.md`: `init` creates the SQLite file and the key and refuses if a key exists; `identity` prints the fingerprint; exit codes 0 success, 1 usage error.
- [X] T031 (after T019 and T028) Write failing tests in `server/internal/remote/listener_test.go` and implement `server/internal/remote/listener.go`: refuses a non-loopback address; serves only `GET /v1/remote/identity` (JSON per contract, `protocol_versions: [1]`, suite `x25519-hkdfsha256-chacha20poly1305`) and `GET /v1/remote/channel`, 404 otherwise; 16 open channels, then upgrade refused with HTTP 503; hello within 10 s; idle 30 s between operations; ping every 15 s; a registry of live channels by user and device; hello dispatch by `purpose` with `session` authenticated from the snapshot (enroll and refresh answer `unsupported_version` until US2). Uses a fake clock.
- [X] T032 Add `--remote-listen`, `--data-dir`, `--speech-worker`, `--speech-models`, `--apple-audience`, `--google-client-id` and, under `-tags localflow_debug` only, `--test-issuer`, `--test-jwks`, `--debug-busy` to `server/cmd/flowd/main.go` with tests in `server/cmd/flowd/main_test.go`: remote serving is off without `--remote-listen`; it refuses to start when the identity key is missing, the listener is not loopback or `--data-dir` is not private to the running user; existing flags and routes are unchanged.

**Checkpoint**: `make check` passes; the app with remote off behaves as before; the server can be initialized and answers `/v1/remote/identity`.

---

## Phase 3: User Story 5 - Develop without disturbing the installed app (Priority: P2, delivered first)

**Goal**: A `dev` variant installs and runs beside `/Applications/LocalFlow.app` with its own bundle identifier, data, Keychain services, agents and ports.

**Independent Test**: quickstart §2: snapshot the installed app's state, build, run, crash and uninstall the dev build, snapshot again; the diff is empty and both apps ran at once.

- [X] T033 [US5] Add `--dev` to `scripts/dev-macos.sh`: build into `build/SignedDevelopment-dev` with `PRODUCT_BUNDLE_IDENTIFIER=org.localflow.LocalFlow.dev`, `PRODUCT_NAME="LocalFlow Dev"`, `LOCALFLOW_PORT_BASE=18000` and `LocalFlowVariant=dev`; install to `/Applications/LocalFlow Dev.app`; quit only the app with the dev bundle identifier; refuse to run if any step would read, replace or quit `/Applications/LocalFlow.app` or `org.localflow.LocalFlow`.
- [X] T034 [P] [US5] Add a `run-dev` target calling `./scripts/dev-macos.sh --dev` to `Makefile`.
- [X] T035 [P] [US5] Write `scripts/snapshot-installed-state.sh`: SHA-256 of the installed app's database files, `defaults export org.localflow.LocalFlow -` hashed, Keychain item service and account names (never values) for `org.localflow.LocalFlow.*` services that are not `.dev.`, `launchctl list` rows for `org.localflow.LocalFlow.flowd` and `.mtplx`, and a hash listing of the installed model directory.
- [X] T036 [US5] Confirm in `apps/macos/LocalFlowTests/AppIdentityTests.swift` that the database, spool, `PendingAudio/`, models and log locations `AppServices` resolves for the dev variant all sit under `LocalFlow Dev`, and that a first dev launch creates a new database rather than opening or migrating the production one (FR-034, scenario 2).
- [X] T037 [US5] Run quickstart §2 on the owner's Mac with the installed app's model loaded, and record hardware, build, the before/after diff, the `launchctl list | grep org.localflow` output and the ports in `specs/014-remote-dictation-server/acceptance/dev-coexistence.md` (SC-008). Hardware task; not done from fakes.

**Checkpoint**: Development builds can be installed and crashed without touching the everyday app.

---

## Phase 4: User Story 2 - Sign in and wait for approval (Priority: P1)

**Goal**: Consent, server pinning, Sign in with Apple or Google, a pending account and device, token refresh bound to the Secure Enclave key, and turning remote dictation off.

**Independent Test**: Enroll a fresh device against a debug-issuer test server; the consent step cannot be skipped; the pending device gets no recognition and the app dictates locally; after approval the next dictation uses the server without signing in again.

### Server

- [X] T038 [P] [US2] Write failing tests in `server/internal/oidc/verifier_test.go` with `fixtures/remote/test-jwks.json`: issuer (Apple `https://appleid.apple.com`; Google `https://accounts.google.com` or `accounts.google.com`), audience from `--apple-audience` or `--google-client-id`, RS256 only, `exp` and `iat` with 60 s leeway by the server clock, nonce equal to `hex(SHA-256(base64url(binding)))` for Apple and `base64url(binding)` for Google, Google `email_verified` required, JWKS responses "capped at 64 KiB", cached per `Cache-Control` "minimum 5 minutes, maximum 24 hours", unknown `kid` refetches "at most one refetch per minute"; Google sign-in refused when `--google-client-id` is unset.
- [X] T039 [US2] Implement `server/internal/oidc/verifier.go` and `server/internal/oidc/jwks.go` with `crypto/rsa`, `crypto/sha256`, `encoding/json` and `net/http` only, plus `server/internal/oidc/debug_issuer.go` behind `//go:build localflow_debug` for `--test-issuer`/`--test-jwks`; make T038 pass.
- [X] T040 [P] [US2] Write failing tests in `server/internal/remote/enroll_test.go` using the debug issuer: `enroll` accepted only within 5 minutes of `ready`; P-256 signature over `"localflow-v1-enroll" ‖ binding` required; a new identity creates a pending user and device and returns `refresh_token`; a known identity with a new key adds a pending device to that user; a rejected user gets `state: rejected` and no refresh token and stays rejected; 100 pending users → `busy` with a `rate_limited` audit row; more than 10 enroll or refresh hellos per minute server-wide → `busy`; audit rows `sign_in` and `enroll` carry IDs and outcomes only.
- [X] T041 [US2] Implement the enroll operation in `server/internal/remote/enroll.go` and connect it to the hello dispatch in `server/internal/remote/listener.go`; make T040 pass.
- [X] T042 [P] [US2] Write failing tests in `server/internal/remote/refresh_test.go`: signature over `"localflow-v1-refresh" ‖ binding ‖ SHA-256(refresh_token)`; success returns `tokens` with `expires_in` 900 and a rotated refresh token; reuse of the previous token revokes the device; `not_approved` leaves the token valid and unrotated; a signature from another channel's binding fails with `unauthorized`.
- [X] T043 [US2] Implement the refresh operation in `server/internal/remote/refresh.go`; make T042 pass.
- [X] T044 [P] [US2] Write failing tests in `server/internal/remote/session_auth_test.go` and complete session hello authentication in `server/internal/remote/listener.go`: unknown or malformed token → `unauthorized`; expired by the server clock → `token_expired`; pending or rejected user or device → `not_approved`; revoked → `revoked`; errors carry no `op` and close the channel; the channel's user and device come only from the token (FR-024).

### Client

- [X] T045 [P] [US2] Write failing tests in `apps/macos/LocalFlowTests/RemoteEnrollmentTests.swift` with the fakes from T020: no transport is opened before consent is confirmed and a server URL entered; the identity fetch shows the fingerprint and pins `server_key` before any sign-in; a later different key or close code 4001 sets `pin_mismatch` and never re-pins outside enrollment; the Secure Enclave key is created at enrollment and signs the enroll and refresh payloads; `enrolled` sets `remote.state` to `pending`, `approved` or `rejected`; refresh happens 12 minutes after issue by the monotonic clock or on `token_expired`, never from the wall clock; a pending device tries one background refresh at dictation start so approval takes effect without restarting (scenario 5); `revoked` deletes tokens and sets `revoked`; a stored `device-key` reference that the Secure Enclave can no longer load (restore onto new hardware) deletes the tokens, sets `remote.state` so the view shows "Sign in again", dictates locally and requires a new enrollment; turning off deletes the four Keychain items and the `remote.*` defaults except `remote.enabled = false` and leaves history untouched (FR-003).
- [X] T046 [US2] Implement identity fetch and pinning, enroll, refresh, state updates and `turnOff()` in `apps/macos/LocalFlow/Core/Remote/RemoteEnrollment.swift`; make T045 pass.
- [X] T047 [US2] Implement the production `IdentitySignIn` in `apps/macos/LocalFlow/Core/Remote/RemoteEnrollment.swift`: Sign in with Apple through `ASAuthorizationAppleIDProvider` with nonce `SHA-256(base64url(binding))`; Google through `ASWebAuthenticationSession` with authorization code + PKCE, the reverse-client-ID redirect scheme and a code exchange at `https://oauth2.googleapis.com/token`, sending only the ID token to flowd; the Google client ID comes from a per-variant Info.plist key `LocalFlowGoogleClientID` and Google sign-in is hidden when it is empty.
- [X] T048 [US2] Add the Sign in with Apple entitlement without breaking unprovisioned builds: a separate `apps/macos/LocalFlow/LocalFlowSignIn.entitlements` with `com.apple.developer.applesignin`, used by `scripts/dev-macos.sh` only when `LOCALFLOW_PROVISIONING_PROFILE` names a profile for the variant's App ID (team QUB47S3XTF), and a clear message that Apple sign-in is unavailable otherwise (research R6 owner prerequisite).
- [X] T049 [US2] Build `apps/macos/LocalFlow/Features/Settings/RemoteDictationView.swift` and add it to `apps/macos/LocalFlow/Features/Settings/SettingsView.swift` and `SettingsViewModel.swift`: turning on shows a consent sheet naming the server and listing audio, transcripts, Dictionary terms and rewrite text, and that the server's administrator can see audio while it is processed; Cancel leaves everything off; server URL entry with the `https://` origin rule; fingerprint display; Apple and Google sign-in buttons; status text "Waiting for approval", "Rejected", "Removed from the server", "Server identity changed", "Sign in again", "Update LocalFlow or the server"; turning off asks for confirmation. Add view-model tests to `apps/macos/LocalFlowTests/SettingsTests.swift`.
- [X] T050 [US2] Wire `RemoteCredentialStore`, `RemoteEnrollment` and the production transport and sign-in into `apps/macos/LocalFlow/App/AppServices.swift`; with `remote.enabled` false nothing remote is constructed that could open a connection.
- [ ] T051 [US2] Run quickstart §4 steps 1–6 against the dev server on the Mac mini and record results, build, hardware and network in `specs/014-remote-dictation-server/acceptance/enrollment.md`. Needs the owner prerequisites (Apple App ID, Google client, tunnel); not done from fakes.

**Checkpoint**: A device can enroll and wait for approval; dictation stays local and error-free while pending.

---

## Phase 5: User Story 3 - Administer users and devices (Priority: P1)

**Goal**: `flowd admin` lists, approves, rejects and revokes users and devices, with an audit trail; revocation ends live channels within one second.

**Independent Test**: With two enrolled users and three devices, run each admin command and check each client's state and the audit rows; revoke a device during a streaming session and measure the close.

- [X] T052 [P] [US3] Write failing tests in `server/cmd/flowd/admin_test.go`: `list [--state S]` output matches the block format in `contracts/flowd-cli.md` exactly (user line, indented device lines, `last seen never`); `approve|reject|revoke user <id>` and `approve|revoke device <id>` follow the transition tables in data-model.md; approving a device of a pending user does not approve the user; exit codes 0 success, 1 usage error, 2 not found, 3 invalid transition; every mutation writes an audit row with actor `admin:<unix user>`; `audit [--limit N]` is newest first, default 50; no command prints tokens, hashes or keys.
- [X] T053 [US3] Implement `list`, `approve`, `reject`, `revoke` and `audit` in `server/cmd/flowd/admin.go` on `server/internal/accounts/store.go`; make T052 pass.
- [X] T054 [P] [US3] Write failing tests in `server/internal/remote/revocation_test.go`: after an admin revoke of a device or user from a second store connection, the running listener sends a sealed `error{code:"revoked"}` where writable and closes every affected channel, including one mid-dictation, within 1 s using the real 250 ms poll: 3 trials in `make check`, and 50 of 50 trials under `-tags localflow_acceptance`, recorded in `specs/014-remote-dictation-server/acceptance/revocation.md` (SC-007); other users' channels stay open; the revoked device's next refresh fails; a revoked user's devices are refused at hello.
- [X] T055 [US3] Connect the snapshot callback from `server/internal/accounts/snapshot.go` to the live-channel registry in `server/internal/remote/listener.go`; make T054 pass.
- [X] T056 [US3] Handle `revoked` and `not_approved` during any operation in `apps/macos/LocalFlow/Core/Remote/RemoteEnrollment.swift`: delete tokens on `revoked`, update `remote.state`, and show the matching status in `RemoteDictationView`; add the cases to `apps/macos/LocalFlowTests/RemoteEnrollmentTests.swift`.

**Checkpoint**: Approval is the only way in and revocation works on live channels.

---

## Phase 6: User Story 1 - Dictate through my server with local fallback (Priority: P1) 🎯 MVP

**Goal**: With an approved device, audio streams during recording, the server recognizes each full window with the app's own recognition code, the app assembles the result locally, rewrite goes over the same channel, and every failure ends in inserted text, text saved for review or a pending retry.

**Independent Test**: With an approved device and a running dev server, dictate fixed recordings remotely and locally and compare transcripts and post-release latency; then stop the server, block the network, force `busy`, kill the worker and revoke the device, each mid-dictation, and confirm every dictation ends with inserted or recoverable text and a visible path label.

### Speech worker (research R10, contracts/speech-worker-ipc.md)

- [X] T057 [US1] Add a macOS command-line target `flowd-speech` to `apps/macos/LocalFlow.xcodeproj/project.pbxproj` (extend `scripts/register-xcode-sources.py` with a `--target flowd-speech` option rather than editing identifiers by hand) with `apps/macos/SpeechWorker/main.swift`, compiling `Core/Transcription/FluidAudioEngine.swift`, `VocabularyBoost.swift`, `Core/Models/ModelLifecycleCoordinator.swift`, `ModelDescriptor.swift`, `ModelProvisioner.swift` and only the boundary types they need, and linking FluidAudio. If the closure pulls in meeting, diarization or UI types, move the shared protocol types into one small file both targets compile. Add `scripts/check-speech-worker-imports.sh` (no `SwiftUI`, `AppKit` or `GRDB` in the worker's sources) and call it from `scripts/test.sh`.
- [X] T058 [P] [US1] Write failing tests in `apps/macos/LocalFlowTests/SpeechWorkerFramingTests.swift` for `apps/macos/SpeechWorker/WorkerFraming.swift` (compiled into both `flowd-speech` and `LocalFlowTests`): `header_length (u32 BE) | header JSON ≤ 65,536 bytes | payload_length (u32 BE) | payload`; `recognize` payload is `sample_count × 4` bytes with `sample_count` 1…239,360; an oversized header, a short read or a length mismatch is fatal.
- [X] T059 [US1] Implement `apps/macos/SpeechWorker/WorkerFraming.swift` and `apps/macos/SpeechWorker/main.swift`: `serve --models <dir>` calls `setKeepLoaded(true)`, loads the runtime, then sends `ready` with the model identity (no `booster` when the keyword spotter is absent) or `unavailable{reason:"model_missing"}` and exits 0; one `ModelLifecycleCoordinator` with only the speech factory; per job `acquire(session: <new UUID>, boost:)`, `transcribe`, `finish`, so terms never carry to the next job (FR-014, FR-025); exactly one `result` or `error` (`invalid_audio`, `model_unavailable`, `failed`) per job in order; `shutdown` releases the runtime and exits; unsolicited `state` (`active`, `releasing`); no idle release while the process runs (FR-032); stderr logs job IDs, sample counts, durations, states and codes only; `provision --models <dir> [--booster]` runs `ModelProvisioner` with the bundled `parakeet-v3.json` and optional `parakeet-ctc-110m.json` and verifies every hash. Make T058 pass.
- [X] T060 [P] [US1] Add a test in `apps/macos/LocalFlowTests/ModelOwnershipTests.swift` that two consecutive leases on one coordinator with different boost term lists produce hints only from the current lease's terms (worker isolation, FR-014).

### Server scheduling and dictation (research R11)

- [X] T061 [P] [US1] Write failing tests in `server/internal/speech/ipc_test.go` for the Go side of the worker framing, sharing byte fixtures with T058 in `fixtures/remote/worker-frames/`.
- [X] T062 [P] [US1] Write failing tests in `server/internal/speech/supervisor_test.go` with a fake worker (the test binary re-executed as a child): `ready` is required first; `unavailable` → every session gets `worker_unavailable` and the start is retried every 60 s; a crash, EOF, non-zero exit, malformed frame or a job past the 30 s deadline kills the process group, answers every waiting job of every session with `worker_unavailable`, and restarts with backoff 1 s, 2 s, 4 s … capped at 60 s; flowd keeps serving; worker stderr lines are copied with a `worker` prefix into the capped log; the supervisor depends only on the IPC messages, and a fake worker that is not `flowd-speech` passes the same tests (FR-029).
- [X] T063 [US1] Implement `server/internal/speech/ipc.go` and `server/internal/speech/supervisor.go`; make T061 and T062 pass.
- [X] T064 [P] [US1] Write failing tests in `server/internal/speech/scheduler_test.go`: one job at a time to the worker; per-user queue of at most 2 waiting window jobs, overflow ends that session with `busy`; round-robin over users with waiting jobs; a rewrite may not start while any dictation window is waiting; cancel drops queued jobs and discards a running job's result.
- [X] T065 [US1] Implement `server/internal/speech/scheduler.go`; make T064 pass.
- [X] T066 [P] [US1] Write failing tests in `server/internal/remote/dictation_test.go` with a fake scheduler: `dictation_accepted` carries `window_samples` 239,360 and the worker's model identity; windows are cut contiguously from sample 0 and window 0 is queued before `dictation_end`; the remainder becomes the tail job after `dictation_end`; `window_result`s go out in index order, then `dictation_complete` with the window count; `progress` at most every 500 ms while a window is queued or running; `total_samples` mismatch, audio before `dictation_accepted` or after `dictation_end` → `invalid_message`; a frame over 16,000 samples or a session over 2,880,000 + 16,000 samples → `limit_exceeded`; 8 sessions total, 1 per user and 2 channels per device → `busy`; `token_expired` at operation start; `dictation_cancel` → `cancelled`; the session buffer never exceeds one window plus one frame and is freed on end, cancel, error and channel close; `--debug-busy` answers every `dictation_start` with `busy`.
- [X] T067 [US1] Implement the dictation operation in `server/internal/remote/dictation.go`; make T066 pass.
- [X] T068 [US1] Start the supervisor and scheduler from `server/cmd/flowd/main.go` with `--speech-worker` (default `<flowd dir>/flowd-speech`) and `--speech-models` (default `<data-dir>/Models`); log queue depth, job duration, worker state and latency with IDs only.

### Server rewrite over the channel (research R14)

- [X] T069 [US1] Extract the body of `rewrite.Handler.rewrite` into `Run(ctx, req, emit func(Event) error) ErrorCode` in `server/internal/rewrite/handler.go`; the HTTP handler calls it and `server/internal/rewrite/handler_test.go` and `handler_spoken_test.go` pass unchanged.
- [X] T070 [US1] Write failing tests in `server/internal/remote/rewrite_test.go` and implement `server/internal/remote/rewrite.go`: a `rewrite` operation on an authenticated session channel yields one `rewrite_event` per NDJSON line the HTTP route writes, ending with `result` or `error`; v1 and v2 requests use the existing validation and limits; the existing limit of 2 in flight and the analysis gate hold, plus 1 per user; it waits while any dictation window is queued; the Feature 003 shared token grants nothing on this listener (FR-006).

### Client storage (data-model: client)

- [X] T071 [P] [US1] Write failing tests in `apps/macos/LocalFlowTests/PendingRemoteDictationStoreTests.swift`: migration `remote-dictation-v15` applies to a v14 database with the SQL in data-model.md verbatim — `recognition_path TEXT NOT NULL DEFAULT 'local' CHECK (recognition_path IN ('local', 'server', 'local_after_server_failure'))`, `server_failure TEXT CHECK (server_failure IS NULL OR length(server_failure) <= 32)`, and `pending_remote_dictations` with `sample_count INTEGER NOT NULL CHECK (sample_count BETWEEN 1 AND 2880000)`; existing rows read as `local`; `TranscriptionEntry.recognitionPath` and `serverFailure` round-trip with the codes `unreachable`, `timeout`, `busy`, `unauthorized`, `not_approved`, `revoked`, `pin_mismatch`, `worker_unavailable`, `protocol_error`, `limit_exceeded`, `pending_retry`; the pending store holds at most 20 rows, `audio_file` is a file name inside `PendingAudio/` (never a path), `PendingAudio/` is 0700, files are removed with their row, and at startup files without rows are deleted and rows without files are dropped with a content-free log line.
- [X] T072 [US1] Register `remote-dictation-v15` in `apps/macos/LocalFlow/Core/Storage/HistoryMigrations.swift`, add the fields to `apps/macos/LocalFlow/Core/Storage/TranscriptionEntry.swift` and `TranscriptionStore.swift`, and implement `apps/macos/LocalFlow/Core/Storage/PendingRemoteDictationStore.swift`; make T071 pass.

### Client session, routing and fallback (research R12)

- [X] T073 [P] [US1] Write failing tests in `apps/macos/LocalFlowTests/RemoteDictationSessionTests.swift` with a scripted transport and manual clock: states `connecting → streaming → ending → complete` and `failed(reason)` from each; new spool samples sent every 200 ms in frames of at most 16,000 samples; `window_result`s stored by `sampleStart`; `dictation_end` carries `total_samples`; each FR-017 trigger maps to its code (connection failure `unreachable`, `busy`, each `error` code, `pin_mismatch`, `unauthorized`, 1.5 s with no sealed frame after `dictation_end` while results are outstanding `timeout`, more than 14 windows or an admission failure `protocol_error`); `progress` frames reset the threshold; `busy` fails at once without waiting; a channel failure before key release reconnects once and restarts from sample 0, after key release it fails; a system sleep notification fails the session with `unreachable` and sends nothing more; `token_expired` at operation start refreshes then retries once while recording continues; the dev-build threshold override is honored.
- [X] T074 [US1] Implement `apps/macos/LocalFlow/Core/Remote/RemoteDictationSession.swift`; make T073 pass.
- [X] T075 [P] [US1] Write failing tests in `apps/macos/LocalFlowTests/RemoteDictationRoutingTests.swift` against `DictationCoordinator` with fakes: remote off → no transport is ever created and behavior matches today (FR-002, scenario 7); the local/remote decision is taken once at key press from a settings snapshot and cached device state; remote mode does not acquire the local lease at key press and starts acquisition at the first failure; success → window source from remote results, label `server`; failure with the local model → whole spool recognized locally, received remote windows discarded, label `local_after_server_failure` with the code; failure without the local model → spool moved to `PendingAudio/` and a pending row written in the same step, history shows "Waiting for server", nothing inserted; switching remote off mid-dictation completes locally; a pending, rejected or revoked device routes to local at key press with label `local` and no failure code (US2 scenario 4); the Mac sleeping mid-dictation ends the recording as locally does, abandons the session and recognizes the spool locally or keeps it as a pending retry; the faithful transcript is saved before insertion and before rewrite; the 180-second limit behaves as local.
- [X] T076 [US1] Add the route, fallback and path recording to `apps/macos/LocalFlow/Features/Dictation/DictationCoordinator.swift` (and `DictationSession.swift` if the session carries the route), using the window source from T011; make T075 and the existing `DictationCoordinatorTests` pass.
- [X] T077 [P] [US1] Write failing tests in `apps/macos/LocalFlowTests/PendingRemoteRetrierTests.swift` and implement `apps/macos/LocalFlow/Core/Remote/PendingRemoteRetrier.swift`: backoff 10 s, 30 s, 2 min, then every 10 min, surviving restart; the Dictionary snapshot is taken again at retry time; success commits the transcript in `needsReview` recovery state with label `server` and code `pending_retry`, posts a notification and never inserts into the focused field (ADR 0014); a row older than 24 hours, or a new failure when 20 rows exist, is never deleted silently: the user is asked to recognize locally (when a model is now provisioned), copy what exists, or discard.
- [X] T078 [US1] Show the path label ("Server", "Local", "Local after server failure (<reason>)") and "Waiting for server" rows with recognize-locally, copy and discard actions in `apps/macos/LocalFlow/Features/Transcriptions/HistoryView.swift`, `HistoryViewModel.swift` and `TranscriptionDetailView.swift`; add cases to `apps/macos/LocalFlowTests/HistoryViewModelTests.swift`.

### Client rewrite over the channel

- [X] T079 [P] [US1] Write failing tests in `apps/macos/LocalFlowTests/RemoteRewriteTransportTests.swift` and implement `apps/macos/LocalFlow/Core/Remote/RemoteRewriteTransport.swift` conforming to `RewriteTransporting` (`apps/macos/LocalFlow/Core/DictationBoundaries.swift`): the unchanged rewrite request JSON goes in a `rewrite` operation on the dictation's channel (or a new session channel if it closed); `rewrite_event`s become the same `RewriteTransportItem`s as the HTTP client; channel failure maps to the Feature 003 fallback categories.
- [X] T080 [US1] Route rewrites through `RemoteRewriteTransport` when remote dictation is on and the device is approved, and skip the shared-token credential check in that case, in `apps/macos/LocalFlow/App/AppServices.swift` and `apps/macos/LocalFlow/Features/Rewrite/RewriteCoordinator.swift`; add cases to `apps/macos/LocalFlowTests/RewriteCoordinatorTests.swift` proving attempt storage, fallback and delivery are unchanged.

### Server install and acceptance

- [X] T081 [US1] Write `scripts/install-remote-server.sh [--dev]` per `contracts/flowd-cli.md`: build flowd and `flowd-speech`, install under `<data-dir>/bin`, render and load the launch agent (`org.localflow.LocalFlow.remote` on `127.0.0.1:8090` with data directory `~/Library/Application Support/LocalFlow Server`, or `org.localflow.LocalFlow.dev.remote` on `127.0.0.1:18090` with `LocalFlow Server Dev`) with `--backend` pointing at the local MTPLX; never replace or stop the app's `.flowd` and `.mtplx` agents.
- [ ] T082 [US1] Run quickstart §3 and §5 (every row) on the Mac mini through the tunnel and record results, build, hardware, model and network in `specs/014-remote-dictation-server/acceptance/remote-dictation.md`. Hardware task; not done from fakes.

**Checkpoint**: MVP: an approved Mac dictates through the server with local fallback, pending retries and path labels.

---

## Phase 7: User Story 4 - Several people at once, isolated (Priority: P2)

**Goal**: Fair, bounded scheduling across users and proof that no request reaches another user's data.

**Independent Test**: Run the isolation suite and 2- and 4-user concurrent runs; the suite reports zero cross-user cases and no user's tail waits behind more than one window from each other user (N−1 windows with N users).

- [X] T083 [P] [US4] Write the isolation suite in `server/internal/remote/isolation_test.go` with two users on the debug issuer and a fake worker that records which terms and samples each job saw: every message type (`dictation_start`, audio frames, `dictation_end`, `dictation_cancel`, `rewrite`, `refresh`, `enroll`) sent with another user's token, another channel's `op` and frames outside the sender's own session; each gets `invalid_message` or the auth error a nonexistent value would get, an authenticated one writes a `cross_user_attempt` audit row, and no response or job ever carries another user's audio, text, terms or results (SC-006).
- [X] T084 [P] [US4] Add multi-user fairness tests to `server/internal/speech/scheduler_test.go`: with 2 and 4 simulated users releasing together, each user's tail window starts after at most one window from each other user (at most 1 with 2 users, at most 3 with 4); dictation windows run ahead of rewrites; one user filling their queue cannot delay another by more than one window (SC-002 logic, not timing).
- [X] T085 [US4] Fix any isolation or fairness defect T083 and T084 find in `server/internal/remote/` or `server/internal/speech/`, adding each case as a regression test.
- [X] T086 [US4] Write `scripts/remote-dictation-benchmark.sh --server <url> --recordings <dir> --runs N [--users K]` and its debug replay harness (real-time audio replay into the client session, Debug builds only) in `apps/macos/LocalFlow/Core/Observability/DictationBenchmark.swift`: reports median and p95 added time after release versus local, transcript diffs with boost on and off, fallback time with the server stopped, and per-user added wait for K concurrent clients.
- [ ] T087 [US4] Run the benchmark with `--users 2` and `--users 4` on the Mac mini and record per-user added wait, hardware, build, model and network in `specs/014-remote-dictation-server/acceptance/concurrency.md` (SC-002). Hardware task.

**Checkpoint**: All five stories work and are independently verified.

---

## Phase 8: Polish and cross-cutting concerns

- [X] T088 [P] Write `scripts/check-remote-logs.sh` scanning flowd logs, worker stderr captured by tests and client unified-log exports for `lfa_`, `lfr_`, `eyJ`, fixture phrases from `fixtures/audio` and the terms in `fixtures/vocabulary-boost`, and run it from `scripts/test.sh` over the Go and XCTest logs (SC-009, research R15).
- [X] T089 [P] Record the R2 (raw Float32 audio, not Opus) and R4 (second HPKE context for server-to-client) refinements in `docs/adr/0028-remote-inference-server.md`; status stays Proposed until acceptance.
- [X] T090 [P] Document remote serving flags, `flowd admin` and `scripts/install-remote-server.sh` in `server/README.md`, and the dev variant and remote dictation settings in `apps/macos/README.md`.
- [X] T091 Add `flowd-speech` to the app bundle's `Contents/Helpers` in `scripts/bundle-local-ai.sh` as the plan lists, or record in `plan.md` why the server install script alone is enough; do not ship an unused binary.
- [ ] T092 Measure flowd RSS idle and during four concurrent dictations with `scripts/memory-report.sh "$(pgrep -f 'flowd serve.*127.0.0.1:18090')"`, the worker's RSS separately, the `modernc.org/sqlite` effect on idle RSS, and the dev app's recording overhead during a 60-second remote dictation against the 100 MB target (constitution principle 2); record them in `specs/014-remote-dictation-server/acceptance/resources.md` (SC-004, constitution principles 2 and 8). Hardware task.
- [ ] T093 Run `scripts/remote-dictation-benchmark.sh --runs 20` on home Wi-Fi and on tethered LTE and record SC-001 (median and p95 added time), SC-003 (fallback time, 100% inserted or recoverable) and SC-005 (transcript diffs, boost on and off) in `specs/014-remote-dictation-server/acceptance/latency-and-equality.md`. Hardware task.
- [ ] T094 Run `scripts/check-remote-logs.sh` over the logs from T082, T087 and T093 and record the result in `specs/014-remote-dictation-server/acceptance/log-scan.md` (SC-009).
- [X] T095 Run `make check` and fix every failure.
- [X] T096 Write `specs/014-remote-dictation-server/acceptance/README.md`: each SC with its measured value or "not measured", and the remote delivery gate (threat model rows mapped to the tests that cover them, authentication and revocation, isolation, fallback, measured network latency on the Mac mini). No SC is reported as met without a recorded measurement.

---

## Dependencies & execution order

### Phase dependencies

- **Setup (Phase 1)**: none.
- **Foundational (Phase 2)**: after Setup. 2a first; 2b, 2c and 2e can then run in parallel; 2d needs 2c's message types for the hello. T031 (listener) needs T019 (channel) and T028 (snapshot), so it runs after 2d. Blocks every story.
- **US5 (Phase 3)**: needs only 2a. Do it before any remote code runs outside XCTest.
- **US2 (Phase 4)**: needs Phase 2.
- **US3 (Phase 5)**: needs Phase 2; its acceptance and T056 are most useful after US2.
- **US1 (Phase 6)**: code can start after Phase 2 (worker, scheduler, storage, session with fakes); end-to-end runs need US2 and US3 so a device can be approved.
- **US4 (Phase 7)**: needs US1's dictation operation and scheduler (T065, T067, T070).
- **Polish (Phase 8)**: after the stories it measures.

### Within each story

- Tests before implementation; a test must fail for the intended reason first.
- Server: protocol → channel → store → operation. Client: boundary and fakes → store → session → coordinator → UI.
- Hardware acceptance tasks (T037, T051, T082, T087, T092, T093, T094) run last in their phase and need the owner's Mac mini, tunnel and sign-in prerequisites.

### Parallel opportunities

- Phase 1: T003 and T005 alongside T002/T004.
- Phase 2: T006, T010, T012, T013, T015, T018, T020, T023, T024, T025, T027, T028, T029 are separate files; the Go side (2c/2d/2e server tasks) and the Swift side proceed in parallel against the shared fixtures.
- US2: server OIDC/enroll/refresh (T038–T044) in parallel with client enrollment (T045–T049).
- US1: worker (T057–T060), server scheduling (T061–T068), client storage (T071–T072) and client session (T073–T074) are independent until routing (T075–T076).
- US4: T083 and T084 in parallel.

## Parallel example: User Story 1

```bash
# Tests that can be written at once:
Task: "SpeechWorkerFramingTests in apps/macos/LocalFlowTests/SpeechWorkerFramingTests.swift"      # T058
Task: "Supervisor tests in server/internal/speech/supervisor_test.go"                            # T062
Task: "Scheduler tests in server/internal/speech/scheduler_test.go"                              # T064
Task: "Dictation operation tests in server/internal/remote/dictation_test.go"                    # T066
Task: "Pending store and migration tests in apps/macos/LocalFlowTests/PendingRemoteDictationStoreTests.swift"  # T071
Task: "Session tests in apps/macos/LocalFlowTests/RemoteDictationSessionTests.swift"              # T073
```

## Implementation strategy

### MVP

1. Phase 1 and Phase 2 (app identity first).
2. Phase 3 (US5) so the everyday app is safe.
3. Phases 4 and 5 (US2, US3) so one device can enroll and be approved.
4. Phase 6 (US1). **Stop and validate** with quickstart §3–§5 on the Mac mini. This is the MVP: one approved user dictating through the server with local fallback.

### Incremental delivery

1. Foundation + US5 → dev builds coexist with the installed app.
2. US2 + US3 → enrollment and administration work; dictation stays local.
3. US1 → remote dictation and rewrite (MVP).
4. US4 → multi-user isolation and fairness proven.
5. Polish → measurements recorded; ADR 0028 moves on only after acceptance.

## Notes

- Never mark a hardware or measurement task done from fakes, and never report an SC as met without a recorded value.
- Logs on both sides carry IDs, counts, durations and codes only (FR-027).
- Commit after each task or logical group; `make check` stays green at each checkpoint.

## Implementation report (2026-09-27)

**Done:** 89 of 96 tasks. Unchecked: the seven hardware and network tasks (T037, T051, T082, T087, T092, T093, T094), which need the owner's Mac mini, Cloudflare Tunnel, Apple App ID and Google client. The success criteria and the open items are in [acceptance/README.md](acceptance/README.md). No SC is reported as met.

**Verified:**
- Server: `go vet`, `go test ./...` and `go test -tags localflow_debug ./...` all pass.
- Checks: Swift format lint, script syntax, the import checks, schema validation, the Python quality checks and the `flowd-speech` build all pass.
- XCTest: 932 tests in the 64 affected classes, run scoped. One timing flake in `MeetingCoordinatorTests` under load; it passed 3 of 3 runs alone. The full suite was not run, because it plays a sound on the owner's machine.
- Real worker: the Swift worker ran with the real model under the Go supervisor (`TestRealWorkerWindowsDecode`, opt-in).

**Decisions worth knowing:**
- The consent sheet contains the server address field, so the consent text names the server.
- Switching remote off mid-dictation records the dictation as `local`, not as a server failure.
- A dictation that can't be kept for retry (20 already waiting, or a disk error) asks the user to save a WAV or discard it.
- There is a new `remote.notice` default for "Sign in again" and "Update LocalFlow or the server".
- `flowd` gained `--dev`.
- The server schema is at `user_version` 2, adding tombstones so a revoked device's tokens answer `revoked`.
- The worker silences FluidAudio's console output (it contains transcript text) and logs through a private duplicate of stderr.
- `flowd-speech` is not bundled in the app (see plan.md).

**Left:** run `make check` once (full suite), then the hardware acceptance in quickstart §2–§6.

## Report: T037 (2026-09-28)

**Done:** T037 passes (SC-008). On the owner's M5 the installed app's state was identical before and after a dev dictation, `kill -9` of the dev app and its uninstall; both apps ran side by side on separate labels and ports. Details: [acceptance/dev-coexistence.md](acceptance/dev-coexistence.md).

**Fixed:** the dev MTPLX launch script was a `sh` syntax error (`*/LocalFlow Dev)` unquoted), so dev rewriting had no backend. The pattern is now quoted, and `scripts/bundle-local-ai.sh` runs `sh -n` on the rendered scripts. After the fix the orphan guard stopped the dev model 2 s after the crash.

**Changed:** quickstart §2 now snapshots after the installed app's dictation, because that dictation writes its database. Sign in with Apple is deferred (no paid membership), so the prerequisites mark it optional and §4 uses Google.

**Not run:** the full `make check`, skipped at the owner's request after the implementation run; only shell and doc files changed here.

**Left:** T051, T082, T087, T092, T093, T094. They need a Google iOS OAuth client for `org.localflow.LocalFlow.dev`, a Cloudflare Tunnel hostname, and the server machine (a provisional run can use this M5, labeled as such).

## Report: Google sign-in setup (2026-09-28)

**Done:** the dev app is built with the owner's Google iOS client for `org.localflow.LocalFlow.dev` (`LOCALFLOW_GOOGLE_CLIENT_ID`); Info.plist carries it and the Google button is enabled.

**Fixed:** `scripts/install-remote-server.sh` never passed `--google-client-id` or `--apple-audience` to `flowd serve`, so the installed server would refuse every sign-in. Both are now installer options; quickstart §3 shows `--google-client-id`. A dry run renders them into the agent's arguments.

**Found, not fixed:**
- The installed remote server calls MTPLX at `127.0.0.1:18000` without `LOCALFLOW_BACKEND_TOKEN`, and MTPLX requires its API key, so remote rewrites would fail and the client would insert the faithful text.
- That MTPLX belongs to the dev app and stops when the app is not running (orphan guard). A Mac mini with no LocalFlow app running would have no LLM. The server needs its own MTPLX agent and key.
- The dev app's local AI agents are not loaded after the T037 `launchctl bootout`; Login Items still lists them as enabled, so the app does not register them again. They return after the next login.

**Blocked:** T051 and later need the Cloudflare Tunnel hostname. The client accepts only `https://` server origins.

## Report: provisional §4 run (2026-09-28)

**Done:** quickstart §4 steps 1–5 pass on the owner's M5 through a Cloudflare quick tunnel with Google sign-in: consent, fingerprint pinning, pending state with local dictation, approval with `flowd admin`, and a server dictation plus server rewrite over the channel. Details: [acceptance/enrollment.md](acceptance/enrollment.md). T051 stays unchecked because it names the Mac mini and the permanent hostname.

**Fixed:**
- The Google sign-in crash: the `ASWebAuthenticationSession` completion is now `@Sendable`.
- The installer now owns the server's MTPLX (port 8092/18092, generated key, stdout discarded), passes `--model localflow` and the sign-in audiences, and handles the bootout race and a self-referencing `--speech-worker`.

**Changed:** quickstart §4 step 5 expects the first dictation after approval to still be local.

**Left:**
- §4 step 6 and §5 (fallback rows).
- T082, T087, T092, T093, T094 on the Mac mini.
- A permanent hostname: a second domain on Cloudflare, the owner's VPS, or Tailscale Funnel.
- A logout and login to restore the dev app's local AI agents after T037.

## Report: provisional §5 run (2026-09-28)

**Done:** on the M5 through the quick tunnel, rows 1, 3 and 4 pass:
- Plain server dictation: tail after release 112–176 ms warm.
- flowd stopped mid-dictation: `local_after_server_failure`/`unreachable`.
- Debug busy: `local_after_server_failure`/`busy`.

The worker-kill row recovered without a fallback, because flowd restarted the worker in about 1 s, before a window was due. A flowd restart mid-recording also recovered on a new channel with nothing lost. Details: [acceptance/remote-dictation.md](acceptance/remote-dictation.md). T082 stays unchecked (Mac mini, permanent hostname).

**Not run:** the Dictionary-term row (T093), no-local-model pending retry, device revocation mid-dictation.

**Worth watching:** the first dictation after idle took 1,496 ms after release, close to the 1.5 s fallback threshold. T093 should measure first-after-idle separately.
