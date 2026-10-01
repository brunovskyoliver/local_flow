# Research: Feature 018 — One server for everything

Decisions that the specification left to the plan. Code references are to the tree at `ab32a5a`.

## R1. Where meeting work crosses to the server: prepared windows, not AAC segments

**Decision**: The Mac keeps every meeting stage it runs today (decoding the durable tracks, echo gating, level normalization, windowing, resume bookkeeping, diarization reconciliation, identity matching) and sends the server only the prepared window each model call needs. The server runs the same model call and returns the same result type. The seam is the three runtime protocols the stages already call through `ModelLifecycleCoordinator`: `TranscriptionRuntime`, `DiarizationRuntime` and `VoiceEmbeddingRuntime` (`LocalFlowSpeech/SpeechBoundaries.swift`, `ModelWorkloadBoundaries.swift`).

**Rationale**:
- Every meeting stage calls one of `lifecycle.transcribe`, `lifecycle.diarize` or `lifecycle.embed` and receives the coordinator in its `init` (`AppServices.swift:874-926`). Remote runtimes behind a second coordinator change no stage code.
- Resume stays exact. `MeetingFinalizer` persists `progress_sequence`/`progress_sample` per window, and `matches()` refuses to resume across engines. A server window is just another window (FR-022 for free).
- Local and server results stay comparable (SC-006). The server sees exactly the samples a local runtime would, after echo gating and levelling.
- The server stays stateless per request (principle 5): nothing to keep between windows, nothing to clean up but one window.
- Uploading the AAC segments (ADR 0015) would make the server repeat `MeetingTrackDecoder`, `EchoGate`, `TrackLevelNormalizer` and the per-track mixer, and either move them into the shared package or duplicate them, plus server-side resume state.

**Cost**: windows are larger than AAC. At 16 kHz, Float32 is 3.84 MB per track-minute; AAC is 1.2 MB per minute for both tracks together. This is why R2 uses 16-bit samples.

**Alternatives considered**: AAC upload with server-side decode (rejected above); mixing to one track (the Turbo pass is per track, `per_track_fixed1920000_turbo_level_v2`, and diarization is per track).

**Spec impact**: FR-021 and User Story 3 said the app uploads the durable compressed segments. They are amended to "prepared audio windows"; ADR 0028's "meeting audio uploads as ADTS AAC segments" is superseded by ADR 0031.

## R2. Meeting audio on the wire: little-endian 16-bit samples

**Decision**: Meeting work (live preview, final transcription, diarization, voice regions) sends 16 kHz mono signed 16-bit little-endian samples (`s16le`) in a new channel frame kind `0x02`, up to 32,000 samples (64,000 bytes) per frame. Dictation keeps Feature 014's `f32le` frames unchanged.

**Rationale**:
- Halves the bytes: 1.92 MB per track-minute. A 20-minute two-track meeting is about 77 MB for the final pass, a 2-hour meeting about 460 MB. At a 20 Mbit/s uplink that is 31 s and about 3 minutes, overlapping with server work because windows stream one at a time.
- 16-bit PCM is the native input precision of both Whisper and Parakeet front ends; the window values are already in [-1, 1] after levelling. Quantization noise at 16 bits (≈ -96 dBFS) is far below the recordings' noise floor. SC-006 still compares server and local transcripts and documents any difference.
- Feature 014 anticipated this: `dictation_start.format` exists so PCM16 can be added later (ADR 0028 refinement R2).

**Alternatives considered**: Float32 everywhere (double the bytes for no measurable gain); re-encoding windows to AAC or Opus (adds codec work on both ends, lossy at the model input, and breaks byte-identical comparisons).

## R3. Server workers: the dictation worker gains live preview; a second worker owns the meeting models

**Decision**:
- Live meeting preview windows (96,000 samples, Parakeet) run on the existing `flowd-speech serve` worker, which already holds Parakeet resident. The speech scheduler gains a priority class: dictation windows first, live-preview windows second, round robin between users inside each class.
- Final transcription (Whisper Turbo), diarization and voice embeddings run in a second worker process, `flowd-speech meeting`, under its own supervisor. It hosts its own `ModelLifecycleCoordinator` with the app's meeting, diarization and embedding factories, loads a model on first use and releases it after 10 idle minutes.

**Rationale**:
- Principle 3: one owner per runtime. The dictation worker pins Parakeet (`setKeepLoaded(true)`); its coordinator keeps one resident runtime, so loading Whisper there would evict Parakeet and stall dictation. A separate process keeps both owners independent, and a crash in one cannot stop the other (principle 8).
- Live preview uses the same model as dictation, so it reuses the resident Parakeet instead of loading a second copy.
- Feature 014's 30 s job deadline suits dictation windows but not a 120 s Whisper window or a 10-minute diarization window. The meeting supervisor uses its own deadline (R7).
- Memory on the 24 GB mini: Parakeet ≈ 1.4 GB, MTPLX 4B ≈ 3.3 GB, Whisper Turbo weights 1.62 GB plus runtime, diarization and embedding models a few hundred MB. That fits, but the working sets are measured (quickstart §5), not assumed.

**Alternatives considered**: one worker for everything (evicts Parakeet, breaks principle 3's per-runtime owner, and couples crash domains); a worker per model (three processes for one GPU queue with no benefit; the coordinator already serializes the three meeting workloads).

## R4. Sharing the meeting model code with the worker

**Decision**: Move `WhisperMeetingRuntime`, `FluidAudioDiarizer` and `FluidAudioVoiceEmbedder` from the app into `packages/LocalFlowCore/Sources/LocalFlowSpeech`, with the two failure enums they use (`DiarizationFailureCategory`, `IdentificationFailureCategory`) and the vocabulary term-byte constant. The app and the worker then compile one copy. The Whisper helper path becomes an init parameter (`create(helperURL:)` already exists); the app passes `Contents/Helpers/localflow-whisper-engine`, the worker passes the helper installed next to it.

**Rationale**: The three files import `LocalFlowCore` (which links GRDB) only for those small types. `LocalFlowSpeech` is GRDB-free and already holds the coordinator, the runtime protocols and the meeting/diarization/embedding factory hooks, so the worker's import check (`check-speech-worker-imports.sh`) keeps passing. ADR 0029 already moved speech sources the same way.

**Alternatives considered**: compiling app files into the worker target (two homes for one source, and pulls GRDB); reimplementing the runtimes for the server (results would drift from local ones).

## R5. Client routing: a second coordinator with remote runtimes for meetings

**Decision**: `AppServices` builds a `MeetingInferenceRouter` that hands the meeting stages one of two coordinators per meeting: the existing local coordinator, or a remote coordinator whose factories return `RemoteTranscriptionRuntime`, `RemoteDiarizationRuntime` and `RemoteVoiceEmbeddingRuntime`. The choice is made when a stage acquires its lease (server routing on, device approved, server offers the capability, meeting not marked "Run on this Mac"). Live preview uses a `RemoteLiveRecognizer` path through the same router.

**Rationale**: Stage code is unchanged; local loading never happens on the server path (FR-013); the dictation coordinator is never blocked by meeting work. The remote coordinator's single-resident rule is harmless (it holds no weights) and keeps cancellation and lease semantics identical.

**Alternatives considered**: a `remote:` flag inside each runtime (spreads routing through four classes); routing inside `ModelLifecycleCoordinator` (mixes network policy into the model owner, against principle 3's intent).

## R6. Channels per device and which work uses which

**Decision**: Raise `MaxChannelsPerDevice` from 2 to 3. The client keeps three channel roles: **interactive** (dictation and rewrite; Feature 014's parked channel), **live** (live meeting preview while recording) and **background** (summaries, final transcription, diarization, voice regions; strictly one op at a time). The global cap `MaxChannels` stays 32.

**Rationale**: A channel runs one op at a time. Without separate roles a long summary would block a live preview, and a live preview would block dictation. Background work is serial anyway (one meeting job at a time per user on the server).

**Alternatives considered**: multiplexing ops on one channel (a protocol change to every op for no gain at household scale); a channel per op (unbounded).

## R7. Meeting job limits and priority on the server

**Decision**:
- Per user: at most 2 waiting background jobs plus 1 running; at most 1 live-preview window waiting. Above that the server answers `busy` and the client waits and retries (FR-031).
- Meeting worker job deadline 300 s (a 120 s Whisper window with repetition retries; a 10-minute diarization window). Embedding regions are 3–20 s.
- A meeting job starts only when no dictation window and no rewrite is in flight; once started it runs to completion (the helper cannot be preempted mid-window), so dictation waits at most one meeting job on shared GPU or ANE time. Analysis keeps the existing gate: rewrite preempts it.
- Server capacity: 4 concurrent background ops across all users, round robin between users.

**Rationale**: matches principle 15's order (dictation, rewrite, then meeting work) with bounded queues and explicit `busy`, and keeps the worst-case dictation delay to one meeting job, which SC-007 measures.

## R8. Summaries over the channel

**Decision**: Add an `analysis` op that mirrors Feature 014's `rewrite` op (R14): the server's analysis handler gains a transport-independent `Run(ctx, req, emit)`, like `rewrite.Handler.Run`. Because analysis requests may reach 262,144 bytes and event lines 98,304 bytes while a channel control message is capped at 65,536, requests and events travel as ordered `analysis_part` fragments (each ≤ 48 KB of payload) closed by the `analysis`/`analysis_event` message. The server builds the analysis handler always and mounts its HTTP routes only with `--analysis`; the remote op serves approved users with the server's own backend. `MaxAnalysesPerUser = 1`.

**Rationale**: reuses the gate, schemas and validation unchanged (principle 11). Refusing large requests with `limit_exceeded` would make long-meeting synthesis fail.

## R9. A custom summaries server without letting the server fetch arbitrary URLs

**Decision**: The summaries "custom server" override stays on the Mac. The app sends it to its own loopback flowd with the ADR 0021 headers plus a new `X-LocalFlow-Primary-Only: 1`, which disables flowd's local secondary. If the custom server fails before producing a result, the app sends the same request over the channel to the LocalFlow server (FR-009).

**Rationale**: Forwarding a client-supplied URL and key to the shared server would let any approved user make the server fetch arbitrary addresses (server-side request forgery) and would put one user's key on a multi-user machine. The app's loopback flowd holds no weights and can stay running while local MTPLX is stopped.

## R10. Local model residency

**Decision**: One derived value, `servedByServer(service)`, is true when server routing is on, the device is approved, the server advertises the service and no override points it at this Mac.
- **Rewrite model (MTPLX)**: `LocalModelResidency` stops it (existing `SIGTERM`) when rewriting and summaries are both served by the server, and `wake()` becomes a no-op while that holds. It starts again when either service returns to this Mac.
- **Parakeet**: `setKeepLoaded(keepModelReady && !servedByServer(.dictation))`; fallback loads it on demand and the normal idle release applies.
- **Meeting models**: load only through the local coordinator, which the router uses only for "Run on this Mac" or when server routing is off.

**Rationale**: the existing stop and keep-loaded mechanisms already do the work; only the conditions change.

## R11. Capabilities

**Decision**: `ready` gains an optional `capabilities` object: the session ops the server serves (built from the registered operation map so it cannot drift) and, for meeting work, the engine and model identity of the final-transcription, diarization and voice-embedding models (`VoiceModelIdentity` fields). The public identity endpoint stays unchanged.

**Rationale**: per session and authenticated; old clients ignore the field. The voice-model identity lets the app refuse to compare server embeddings with a library built on another model (FR-023, principle 10).

## R12. Waiting and retrying meeting work and summaries

**Decision**: Remote runtimes map unreachable, busy and worker-unavailable to a new transient failure, `waitingForServer`. Finalization, diarization, identification and analysis treat it like an interruption: progress already stored is kept, the item shows "Waiting for server" with a **Run on this Mac** action, and a retry timer re-queues it with backoff (30 s doubling to 10 min, reset on network change or a successful channel). A live-preview window that cannot be served becomes a `serverUnavailable` gap row (64-range cap unchanged). Run on this Mac sets a per-meeting local override for the remaining work.

**Rationale**: implements FR-031 with the existing requeue and gap machinery; nothing stored is lost.

## R13. Settings migration

**Decision**: On first launch of this version:
- `summaryServer == remote` with a URL and model → summaries override `custom` with the same URL, model and Keychain key (account `summary-server`, unchanged).
- A non-loopback `rewriteEndpoint` with a stored secret → rewrite override `custom` with that endpoint and secret.
- Otherwise overrides are `server`.
- `useServerForEverything` defaults to on when remote dictation is enabled and approved.
- The app shows a one-time notice listing kept overrides.

The migration runs once (a version key in preferences) and never deletes a value.

## R14. Exposure and threat model changes

Exposure stays Tailscale Funnel on the remote listener (ADR 0028 amendment). New threats and their answers:
- Larger uploads as a resource-exhaustion vector: per-user and global limits (R7), per-frame caps, op deadlines.
- Server-side request forgery through summaries: prevented by R9.
- Cross-user access to meeting results: ops are scoped by the token's user ID; the isolation suite covers every new message type (FR-028).
- Voice data: embeddings are returned and dropped; profiles never leave the Mac (FR-023).
