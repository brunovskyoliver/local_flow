# Implementation plan: One server for everything

**Feature identifier**: `018-one-server` | **Branch**: `main` (no branch hook) | **Date**: 2026-10-01 | **Spec**: [spec.md](spec.md) | **ADR**: [0031](../../docs/adr/0031-one-server-for-every-service.md), refining [0028](../../docs/adr/0028-remote-inference-server.md) | **Constitution**: 2.0.0

## Summary

With remote dictation approved, one switch sends every inference service to the user's LocalFlow server. Rewriting already travels over the channel; the plan makes Settings and the connection check reflect that. Summaries get an `analysis` op on the same encrypted channel, a mirror of the Feature 014 rewrite op with fragmenting for large requests. Meeting work keeps every Mac-side stage (decoding, echo gating, levelling, windowing, resume, reconciliation, matching) and swaps only the model calls: a second `ModelLifecycleCoordinator` with remote runtimes sends prepared 16-bit windows to the server. There, live-preview windows run on the existing Parakeet worker, and final transcription, diarization and voice embeddings run in a new meeting worker that reuses the app's runtimes moved into `LocalFlowSpeech`. While the server serves, the Mac stops its local rewrite model and keeps Parakeet unloaded; local models load only for a fallback or **Run on this Mac**. Settings gain a Server section first, with per-service overrides under Advanced and a lossless migration of existing settings.

## Technical context

| Item | Decision |
| --- | --- |
| Languages | Swift 6.0 (app, worker), Go 1.26 (flowd) |
| Client frameworks | Existing only: SwiftUI, CryptoKit, GRDB, FluidAudio 0.15.7, the bundled Sotto/whisper.cpp helper. No new package |
| Server | flowd standard library plus its two Feature 014 dependencies; a second worker mode of `flowd-speech`; the Sotto helper (`scripts/build-meeting-whisper.sh` output) installed beside the worker. No new dependency |
| Shared code | `WhisperMeetingRuntime`, `FluidAudioDiarizer`, `FluidAudioVoiceEmbedder` and their failure enums move into `packages/LocalFlowCore/Sources/LocalFlowSpeech` (research R4) |
| Storage | Client migration `one-server-v17` (where-it-ran columns, `run_locally`, a gap reason); new preferences ([data-model.md](data-model.md)). Server: no new table |
| Wire | [remote-channel.md](contracts/remote-channel.md): `ready.capabilities`, `analysis`, `live_window`, `meeting_job`, frame kind `0x02` s16le, 3 channels per device. Worker: [meeting-worker-ipc.md](contracts/meeting-worker-ipc.md) |
| UI | [settings-ui.md](contracts/settings-ui.md) |
| Testing | Go: op tests with fake workers and fake clock, isolation suite extension, schema vectors. XCTest: routing table, migration, residency, remote runtimes over a fake channel, waiting/retry, UI view models. Hardware acceptance per [quickstart.md](quickstart.md), outside `make check` |
| Target | Client macOS 14+ on Apple Silicon. Server: the owner's Mac mini M5 Pro 24 GB under launchd, behind Tailscale Funnel |
| Performance goals | SC-002, SC-003, SC-005, SC-007 targets; unmeasured until quickstart §5 |
| Scale | One server, a household: 32 channels, 3 per device, 4 concurrent background ops |

No open clarifications remain. The spec's choices that the plan refines are recorded in research R1 (prepared windows instead of AAC upload; FR-021 amended) and R9 (custom summaries server stays on the Mac).

## Constitution check

Gate before research: pass with one recorded exception. Re-checked after design: pass.

| Principle | Result |
| --- | --- |
| 1 Native client | Pass. Swift and Apple frameworks only; nothing new in the client process |
| 2 Memory efficiency | Pass. Every new queue has a bound (R7, data-model). Remote runtimes hold one window. The Mac stops MTPLX and keeps Parakeet unloaded while served (R10). Server meeting models load lazily and release after 10 idle minutes. Working sets measured (quickstart §5) |
| 3 Model lifecycle | Pass. The dictation worker remains Parakeet's only owner; the meeting worker's coordinator owns Whisper, diarization and embeddings; flowd loads nothing. On the Mac, the remote coordinator holds no weights and the local coordinator remains the only owner of local runtimes |
| 4 Local-first | Pass. Off unless remote dictation is approved; dictation falls back locally; meeting work and summaries wait and retry with **Run on this Mac** (FR-031); local models stay provisioned |
| 5 Privacy | Pass. Covered by Feature 014's consent, which names audio, transcripts and rewrite text; the consent text adds meeting audio and summaries (FR-001 consent version bump, so existing devices confirm once). Inner HPKE unchanged; the server drops windows after each job; voice profiles never leave the Mac; content-free logs |
| 6 Streaming | Pass. Meeting audio is never whole in memory: the Mac decodes 4,096 frames at a time into one window per lane (unchanged); the server holds one window per job and streams it to the worker |
| 7 Simple persistence | Pass. One additive migration; media stays in files |
| 8 Server isolation | Pass. flowd in Go without weights; a second worker process with its own supervisor; a meeting-worker crash cannot stop flowd or dictation |
| 9 Recoverability | Pass. Resume per stored window unchanged; waiting state survives restarts through existing pass rows |
| 10 Speaker attribution | Pass. Diarization and identification stay distinct; server embeddings carry model identity and are never compared across models (FR-023) |
| 11 Structured LLM output | Pass. Analysis schemas and validation unchanged; the channel carries the same request and events |
| 12 Testability | Pass. Remote runtimes, channel and capabilities behind protocols with fakes |
| 13 Observability | Pass. flowd logs queue depth, job kind, duration and worker state; the client records `inference_path` per item |
| 14 Scope | Pass. No new dependency, no server storage, no new service; reuses two existing processes plus one worker mode |
| 15 Authenticated access | Pass. Every op scoped by the token's user; per-user bounds with round robin; dictation, then rewrite, then meeting work (R7); `busy` at capacity |
| Remote delivery gate | Threat model additions in research R14; auth and revocation unchanged; isolation suite extended; fallback in R12; network latency through Funnel measured in quickstart §5 |
| **Delivery gate: "Meeting and server capabilities remain separate specifications"** | **Exception**, chosen by the owner on 2026-10-01 and recorded in ADR 0031: one specification covers server routing and remote meeting work. Mitigation: User Story 3 (meetings) is independently testable and has its own acceptance; tasks keep meeting work in its own phase so the rest can ship first |

## Design overview

### Client routing

```text
Settings switch + approval + capabilities + overrides ──▶ servedByServer(service)
  dictation ─▶ Feature 014 path (interactive channel)       | local Parakeet
  rewrite   ─▶ RoutingRewriteTransport (interactive)         | loopback flowd/MTPLX or custom HTTP
  summaries ─▶ RoutingAnalysisTransport ─▶ analysis op (background)
               custom: loopback flowd, primary-only ─▶ on failure: analysis op
  meetings  ─▶ MeetingInferenceRouter
               live:  RemoteLiveRecognizer ─▶ live_window (live channel) | LiveRecognizer local
               final/diarize/embed: remote ModelLifecycleCoordinator
                     (RemoteTranscription/Diarization/VoiceEmbedding runtimes) ─▶ meeting_job (background)
                     | local ModelLifecycleCoordinator (fallback, Run on this Mac, switch off)
residency: servedByServer(rewrite ∧ summaries) ─▶ stop MTPLX, no wake
           servedByServer(dictation) ─▶ keepLoaded = false
```

### Server

```text
flowd ── remote listener (Funnel) ── session ops:
   dictation_start ─▶ speech scheduler [dictation class] ─▶ flowd-speech serve (Parakeet)
   live_window     ─▶ speech scheduler [live class]      ─▶ flowd-speech serve (Parakeet)
   rewrite         ─▶ rewrite handler ─▶ MTPLX
   analysis        ─▶ analysis handler Run() (gate: rewrite preempts) ─▶ MTPLX
   meeting_job     ─▶ meeting queue (per-user RR, waits for no dictation/rewrite) ─▶ flowd-speech meeting
                        (Whisper Turbo via Sotto helper | diarization | embeddings; one resident)
```

## Project structure

```text
specs/018-one-server/
├── plan.md  research.md  data-model.md  quickstart.md
├── contracts/ remote-channel.md  meeting-worker-ipc.md  settings-ui.md
├── checklists/requirements.md
└── tasks.md                      # $speckit-tasks

docs/adr/0031-one-server-for-every-service.md        # new: exception + decisions R1–R3, R6, R9
docs/distribution/remote-server.md                   # meeting provisioning, helper install

server/
├── cmd/flowd/main.go, remote.go, remote_ops_session.go   # analysis handler always built; meeting supervisor; capabilities
├── internal/remote/{protocol.go, channel.go, listener.go}  # new messages, frame kind 0x02, 3 channels per device
├── internal/remote/{analysis.go, live.go, meeting.go}       # new ops (+ _test.go, isolation_test.go additions)
├── internal/analysis/handler.go, router.go                  # Run(ctx, req, emit); Router.For(url, model, key); primary-only header
└── internal/speech/{scheduler.go, supervisor.go, ipc.go, meeting_queue.go}  # priority classes; per-supervisor deadline; meeting frames

apps/macos/SpeechWorker/main.swift                     # `meeting` mode
packages/LocalFlowCore/Sources/LocalFlowSpeech/        # moved: WhisperMeetingRuntime, FluidAudioDiarizer, FluidAudioVoiceEmbedder, failure enums
packages/LocalFlowCore/Sources/LocalFlowCore/HistoryMigrations.swift   # one-server-v17

apps/macos/LocalFlow/
├── Core/Remote/  RemoteAnalysisTransport.swift, RemoteMeetingRuntimes.swift, RemoteLiveRecognizer.swift,
│                 RemoteCapabilities.swift, RemoteProtocol.swift (new messages), RemoteChannelPool (3 roles)
├── Core/Routing/ServerRouting.swift            # servedByServer, overrides (R13 migration withdrawn)
├── Core/Intelligence/AnalysisClient.swift      # RoutingAnalysisTransport, primary-only header
├── Core/LocalAI/LocalAIRuntime.swift           # residency conditions R10
├── Core/Transcripts/, Core/Diarization/, Core/Identification/  # waitingForServer handling, inference_path
├── App/AppServices.swift                       # MeetingInferenceRouter, second coordinator, wiring
└── Features/Settings/  ServerSettingsView.swift (new), SettingsView.swift, SettingsViewModel.swift, RemoteDictationView.swift

scripts/install-remote-server.sh                 # drop --analysis=false; install helper + meeting descriptors
protocol/schemas/remote-message.schema.json      # new messages and capabilities
```

**Structure decision**: no new project or target; one new worker mode in the existing `flowd-speech` target, new files beside their Feature 014 counterparts.

## Delivery order

1. **Routing core and UI** (User Stories 1, 2, 4): capabilities, `servedByServer`, residency, Settings Server section, migration, connection check over real paths. Ships value alone: rewriting is already remote.
2. **Summaries** (User Story 1 scenario 2): analysis `Run`, `analysis` op with fragments, client transport, custom-server fallback.
3. **Meetings** (User Story 3): code move into `LocalFlowSpeech`, meeting worker, `live_window` and `meeting_job` ops, scheduler classes, remote runtimes, router, waiting/retry, migration columns, install changes.
4. **Fairness and isolation** (User Story 5): priority checks, isolation suite, two-user measurement.
5. **Acceptance**: quickstart §2–6 on the Mac mini.

## Complexity tracking

| Item | Why needed | Simpler alternative rejected because |
| --- | --- | --- |
| Constitution exception: one specification for server and meeting capabilities | Owner's choice; the routing switch, UI and meeting work share one routing model and one acceptance | Two specifications would duplicate the routing design; mitigated by an independent meeting story and phase |
| Second worker process | Whisper, diarization and embeddings cannot share Parakeet's resident owner without stalling dictation | One worker evicts Parakeet on every meeting job (R3) |
| Third channel per device | Live preview must not wait behind summaries, nor dictation behind either | Multiplexing ops changes every op's framing (R6) |

## LocalFlow constitution gates

- **Bounds and overflow**: channel frames 64 KB; per-user 1 running + 2 waiting background jobs, 1 waiting live window; 4 background ops globally; analysis assembly ≤ 262,144 bytes; one window per job on the server; `busy` beyond. Client: existing live-pass ring and gap caps; one in-flight remote window per lane.
- **Lifecycle owner and release**: dictation worker (Parakeet), meeting worker coordinator (Whisper, diarization, embeddings; idle release 10 min), MTPLX under launchd; Mac local coordinator unchanged, remote coordinator holds no weights. Evidence: worker state logs and quickstart §5.
- **Offline and privacy**: R12 waiting and retry, **Run on this Mac**; consent text and version bump; no server retention; content-free logs scanned (SC-009).
- **Recovery and persistence**: per-window resume unchanged; `inference_path` and `run_locally` survive restarts; server temp files deleted per job and at start.
- **Dependencies and licenses**: none new. The Sotto helper and Whisper Turbo model licences already reviewed for the app (ADR 0019) are copied with the server install.
- **Memory acceptance and tests**: quickstart §1 (deterministic) and §5 (measured); unmeasured targets are reported as such.
