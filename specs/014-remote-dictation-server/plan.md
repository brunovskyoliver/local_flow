# Implementation plan: Remote dictation on a self-hosted LocalFlow server

**Feature identifier**: `014-remote-dictation-server` | **Branch**: `t3code/remote-dictation` | **Date**: 2026-09-27 | **Spec**: [spec.md](spec.md) | **ADR**: [0028](../../docs/adr/0028-remote-inference-server.md) | **Constitution**: 2.0.0

## Summary

With remote dictation on, the app opens an end-to-end encrypted WebSocket channel to flowd through the owner's Cloudflare Tunnel at key press and streams the spool's Float32 samples while the user speaks. flowd cuts the same contiguous 239,360-sample windows the app uses and sends each to a Swift speech worker process that runs the app's own FluidAudio and term-boosting code. The window results come back as `TranscriptionWindow`s, and the app assembles, normalizes, spells, saves and inserts them through the same code as local dictation. Rewrites travel over the same channel. Accounts come from Sign in with Apple or Google plus `flowd admin` approval; refresh is bound to a Secure Enclave key. Any failure falls back to local recognition from the spool, or to a bounded retry queue when no local model is installed. A `dev` build variant keeps branch builds away from the installed app.

## Technical context

| Item | Decision |
| --- | --- |
| Languages | Swift 6.0 (app, worker), Go 1.26 (flowd; up from 1.23 for `crypto/hpke`) |
| Client frameworks | CryptoKit (HPKE, Secure Enclave P-256), AuthenticationServices (Sign in with Apple, `ASWebAuthenticationSession` for Google), `URLSessionWebSocketTask`, Security (Keychain), GRDB, FluidAudio 0.15.7. No new Swift package |
| Server packages | Standard library plus `github.com/coder/websocket` (ISC) and `modernc.org/sqlite` (BSD-3-Clause, pure Go), reviewed in [research.md](research.md) R3, R8 |
| Worker | New command-line target `flowd-speech` compiling the app's recognition sources; child process of flowd over stdin/stdout ([contract](contracts/speech-worker-ipc.md)) |
| Storage | Server: SQLite `flowd-remote.sqlite` (users, devices, audit). Client: migration `remote-dictation-v15` (path column, pending retry table), Keychain service `<bundle id>.remote`. See [data-model.md](data-model.md) |
| Wire | [remote-channel.md](contracts/remote-channel.md): HPKE X25519/HKDF-SHA256/ChaCha20-Poly1305 both directions, sequence-checked frames, versioned JSON control messages, raw f32le audio |
| Testing | XCTest with fake channel, fake server and fake clock; Go tests with in-process WebSocket, fake worker, debug OIDC issuer; shared HPKE vectors; isolation suite; log scan. Hardware acceptance outside `make check` |
| Target platform | Client: macOS 14+ on Apple Silicon with Secure Enclave. Server: Apple Silicon Mac mini under launchd, behind cloudflared |
| Performance goals | SC-001 to SC-004 targets, unmeasured |
| Scale | One server, a household of users: 16 channels, 8 concurrent dictations, 100 pending accounts |

No open clarifications remain; the protocol details the spec deferred to the plan are settled in research R2–R6.

## Constitution check

Gate before research: pass. Re-checked after design: pass. No exceptions and no new ADR beyond 0028; the plan refines ADR 0028 in two places (R2 raw Float32 audio, not Opus; R4 the reverse direction is a second HPKE context), which the implementation records as an update to ADR 0028.

| Principle | Result |
| --- | --- |
| 1 Native client | Pass. Swift and Apple frameworks only; the worker is a Swift tool on the server, not a client runtime |
| 2 Memory efficiency | Pass. Every buffer, queue and table has a bound (research R11, data-model). No local model lease in remote mode until fallback. flowd RSS measured for SC-004; worker measured separately; client recording overhead in remote mode measured against the 100 MB target. The server model is loaded when the worker starts and released when it exits: lazy per process and releasable by stopping it |
| 3 Model lifecycle | Pass. The worker hosts one `ModelLifecycleCoordinator`, the single owner of the server runtime; flowd schedules jobs and loads nothing. The app's coordinator is unchanged and used only on the local path |
| 4 Local-first | Pass. Off by default; fallback on every failure; audio kept in the spool, then in `PendingAudio/` when no local model exists; nothing lost |
| 5 Privacy | Pass. Per-device opt-in after a consent step; only the owner's server; inner HPKE encryption because TLS ends at Cloudflare; server keeps no audio or text; keys and tokens in Keychain and the Secure Enclave; content-free logs with a scan |
| 6 Streaming | Pass. Audio streams in ≤ 64 KB frames; the server holds at most one window plus one frame per session |
| 7 Simple persistence | Pass. SQLite on both sides, one client migration, server `user_version` migrations; audio in files, never BLOBs |
| 8 Server isolation | Pass. flowd in Go under launchd, no weights; speech in a child worker whose crash cannot stop flowd; LLM stays on MTPLX |
| 9 Recoverability | Pass. Pending retries survive restarts; orphans cleaned at start; server writes in transactions |
| 10 Speaker attribution | Not affected |
| 11 Structured LLM output | Pass. Rewrite schema and validation unchanged |
| 12 Testability | Pass. Channel, credential store, identity provider, worker and clock behind protocols with fakes; tests for cancellation, capacity, failure and preservation of text |
| 13 Observability | Pass. flowd logs queue depth, job duration, worker state and latency; the client records recognition path and remote timings in the existing provenance |
| 14 Scope | Pass. Accounts only as principle 15 allows; no web admin, no sync, no second server; two small server dependencies with license review |
| 15 Authenticated access | Pass. Apple/Google verified by the server, pending by default, admin approval, 15-minute access tokens, Secure Enclave–bound rotating refresh, revocation within 1 s, scoping from the token only, fair bounded scheduling with `busy` |
| Remote delivery gate | Threat model in the spec; authentication and revocation in [remote-channel.md](contracts/remote-channel.md); isolation in data-model and the SC-006 suite; fallback in research R12; network latency measured on the Mac mini in quickstart §6 before the feature is called done |

## Design overview

### Client dictation flow (remote on, device approved)

```text
key down ─┬─ capture → spool (unchanged)
          └─ RemoteDictationSession: open channel → hello(session) → dictation_start(boost)
                 every 200 ms: send new spool samples as audio frames
                 receive window_result → windows[sampleStart]
key up ────── send tail frame + dictation_end → wait for remaining results (1.5 s no-progress threshold)
          ├─ complete: WindowedTranscriber(window source = remote windows) → normalize → spell → save → insert
          │            → rewrite over the same channel (RemoteRewriteTransport)
          └─ failed(reason): local model provisioned? → acquire lease → local transcriber over the spool
                                                    no → move spool to PendingAudio + pending row → retry later
```

`DictationCoordinator` gets one decision at session start, `local` or `remote`, from a settings snapshot and the cached device state. The local branch is today's code. The window-source refactor ([research.md](research.md) R1) is the only change to `WindowedTranscriber`.

### Server flow

```text
cloudflared → 127.0.0.1:8090 → remote.Listener
  channel: open hello (HPKE) → authenticate from account snapshot → operations
    dictation: frames → window buffer → speech.Scheduler (per-user queue, round-robin) → worker → window_result
    rewrite:   rewrite.Run (extracted from the HTTP handler) → rewrite_event
  accounts.Store (SQLite) ← flowd admin (separate process); data_version poll every 250 ms → close revoked channels
  oidc.Verifier: Apple and Google JWKS, cached and bounded
```

## Project structure

### Documentation

```text
specs/014-remote-dictation-server/
├── spec.md
├── plan.md
├── research.md
├── data-model.md
├── quickstart.md
├── contracts/
│   ├── remote-channel.md
│   ├── speech-worker-ipc.md
│   └── flowd-cli.md
└── tasks.md            # created by /speckit-tasks
```

### Source

```text
protocol/schemas/
├── remote-identity.schema.json            # new
├── remote-hello.schema.json               # new
└── remote-message.schema.json             # new: every control message, oneOf by type

server/
├── go.mod                                 # go 1.26; coder/websocket, modernc.org/sqlite
├── cmd/flowd/
│   ├── main.go                            # remote flags, second listener
│   └── admin.go                           # flowd admin
└── internal/
    ├── remote/                            # new: listener, HPKE channel, framing, operations, limits
    ├── accounts/                          # new: SQLite store, tokens, audit, snapshot + data_version watcher
    ├── oidc/                              # new: Apple/Google ID token verification, JWKS cache, debug issuer
    ├── speech/                            # new: ipc.go, supervisor.go, scheduler.go
    └── rewrite/handler.go                 # extract Run(ctx, req, emit) for HTTP and channel

apps/macos/
├── LocalFlow/
│   ├── App/AppIdentity.swift              # new: bundle id, variant, directories, labels, ports
│   ├── App/AppServices.swift              # wiring; identity instead of literals
│   ├── Core/RemoteBoundaries.swift        # new: protocols for channel, credentials, sign-in, clock
│   ├── Core/Remote/                       # new
│   │   ├── RemoteChannel.swift            #   WebSocket + HPKE + frames
│   │   ├── RemoteProtocol.swift           #   Codable messages and validation
│   │   ├── RemoteCredentialStore.swift    #   Keychain + Secure Enclave key
│   │   ├── RemoteEnrollment.swift         #   pin, Apple/Google sign-in, enroll, refresh, status
│   │   ├── RemoteDictationSession.swift   #   streaming, results, fallback triggers
│   │   ├── PendingRemoteRetrier.swift     #   bounded retry schedule
│   │   └── RemoteRewriteTransport.swift   #   RewriteTransporting over the channel
│   ├── Core/Storage/HistoryMigrations.swift   # remote-dictation-v15
│   ├── Core/Storage/PendingRemoteDictationStore.swift  # new
│   ├── Core/Storage/TranscriptionEntry.swift  # recognitionPath, serverFailure
│   ├── Core/Transcription/WindowedTranscriber.swift  # window-source refactor
│   ├── Core/LocalAI/LocalAIRuntime.swift  # labels, ports and paths from AppIdentity
│   ├── Core/Rewrite/RewriteCredentialStore.swift     # service from AppIdentity
│   ├── Features/Dictation/DictationCoordinator.swift # local/remote route, fallback, path label
│   ├── Features/Settings/RemoteDictationView.swift   # new: consent, server, fingerprint, sign-in, state
│   └── Features/Transcriptions/…          # path label and "Waiting for server" rows
├── LocalFlow/LocalFlowSignIn.entitlements # new: Sign in with Apple, provisioned builds only
├── LocalFlow/Core/Observability/DictationBenchmark.swift  # new: Debug replay harness
├── SpeechWorker/main.swift                # new target flowd-speech
├── SpeechWorker/WorkerFraming.swift       # new: also compiled into LocalFlowTests
└── LocalFlowTests/Remote*Tests.swift      # new

scripts/
├── dev-macos.sh                           # --dev variant; refuses to touch LocalFlow.app with --dev
├── install-remote-server.sh               # new
├── check-remote-logs.sh                   # new, SC-009
├── snapshot-installed-state.sh            # new, SC-008
├── remote-dictation-benchmark.sh          # new, SC-001 to SC-005
├── check-speech-worker-imports.sh         # new: no SwiftUI, AppKit or GRDB in the worker
└── bundle-local-ai.sh                     # agent templates per variant; flowd-speech is not bundled (see below)

fixtures/remote/                           # HPKE vectors, worker-frames/, messages/, test JWKS; shared by Swift and Go
Makefile                                   # run-dev
THIRD_PARTY_NOTICES.md                     # new server modules
docs/adr/0028-remote-inference-server.md   # refinements R2, R4; status stays Proposed until acceptance
```

**Worker packaging (T091)**: `flowd-speech` is not added to the app bundle. The app never starts it; it runs only beside flowd on the server, where `scripts/install-remote-server.sh` builds it from the same Xcode project and installs it with the pinned descriptors. Bundling it would ship a 14 MB binary no client uses.

**Structure decision**: one macOS app, one Go server, shared schemas in `protocol/`, as today. The worker is a second product of the existing Xcode project so it compiles the app's recognition files directly and cannot drift from them.

## Bounds and failure behaviour

All server bounds and overflow results are in [research.md](research.md) R11; channel errors and client reactions are in [remote-channel.md](contracts/remote-channel.md). Client side:

| Resource | Bound | Overflow or failure |
| --- | --- | --- |
| Audio held for one dictation | the existing spool, ≤ 180 s (11.52 MB) | unchanged Feature 001 duration limit |
| Frames in flight | the WebSocket send buffer, at most 4 unsent frames | stop sending, treat as `timeout` failure |
| Pending retries | 20 rows, 24 h, ≤ 230 MB of `PendingAudio/` | ask to recognize locally, copy or discard; never dropped silently |
| Channels | 1 per dictation, plus 1 for enrollment or refresh | serialized |
| Remote window results | 14 windows, each within `RecognitionAdmission` limits | `invalid_result` → fallback |

Every failure path ends in inserted text, text saved for review, or a pending retry. The faithful transcript is saved before insertion and before rewrite, as today.

## Model ownership

Server: the worker's `ModelLifecycleCoordinator` owns the Parakeet runtime and the optional keyword spotter; flowd owns scheduling and never loads weights; the worker loads the runtime at start with the coordinator's keep-loaded rule and keeps it resident until the process exits (FR-032, no idle release on the server). Client: the local coordinator is untouched and acquired only for local dictation or fallback.

## Privacy and security summary

Consent before any network use; pin before sign-in; everything after the WebSocket upgrade is sealed. The server keeps accounts, devices, token hashes and audit rows only. Audio and terms exist in server memory for one window job and one session buffer. The threat model table in the spec is the acceptance list; each row maps to a test in the isolation, token, OIDC or channel suites.

## Validation

- `make check` runs Swift format, Go vet and tests, XCTest, schema validation and the log scan. The new deterministic suites are listed in [quickstart.md](quickstart.md) §1.
- Hardware and network acceptance (quickstart §3–§6) runs on the owner's Mac mini and MacBook. Results go in `specs/014-remote-dictation-server/acceptance/` with hardware, build, model and network. No SC is reported as met until measured.

## Delivery order

1. `AppIdentity` and the `dev` variant (User Story 5) before any remote code, so development never touches the installed app.
2. Window-source refactor with the equality test.
3. Channel crypto and framing on both sides, with shared vectors.
4. Accounts, OIDC, `flowd admin`, enrollment UI (User Stories 2, 3).
5. Worker target, supervisor and scheduler.
6. Remote dictation session, fallback, pending retries, path label (User Story 1).
7. Rewrite over the channel.
8. Isolation suite and concurrency (User Story 4), then hardware acceptance.

## Complexity tracking

No constitution violations to justify.
