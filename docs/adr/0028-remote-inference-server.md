# 0028: Opt-in remote inference on a self-hosted multi-user server

## Status

Proposed, 2026-09-27. Amends constitution to 2.0.0. The specification and plan refine the details; measurements are still to be collected.

## Context

Every audio model runs inside the Mac app today: Parakeet dictation through FluidAudio, Whisper turbo meeting transcription, diarization and voice embeddings. flowd only proxies rewrite and meeting-analysis text to an OpenAI-compatible LLM server, over plain HTTP with one shared bearer token and no user concept. The goal is to run all models on one server that the user operates, with the Mac and later an iOS app as clients, for several approved users at once, reachable without a VPN.

Constitution 1.0.0 forbade this: local-only speech recognition (principle 5), no accounts (14), and a server that proxies only the LLM (8).

## Decision

- **Remote inference is opt-in per device.** Local models stay the default and the fallback. When the server is unreachable, too slow or returns busy, dictation uses local Parakeet if it is provisioned; otherwise the bounded audio is kept for a retry.
- **Server hardware: Apple Silicon first** (Mac mini M6, 32 GB). The ASR, diarization and embedding worker is a headless Swift helper that reuses the existing FluidAudio code, including term boosting (ADR 0027). The LLM stays on MTPLX. The worker interface stays generic so that a CUDA worker (NeMo or Riva, with vLLM for the LLM) can be added later without changing the client protocol.
- **flowd becomes the gateway.** It handles identity, device keys, sessions, per-user fair queues and routing to worker processes. It still loads no weights (principle 8) and runs under launchd.
- **Exposure: Cloudflare Tunnel, authenticated by flowd.** There is no open port and no VPN. Cloudflare Access is not used for the app, because native clients would need a shipped service token. Cloudflare terminates TLS, so audio and text also travel inside an HPKE-established inner channel: the client seals a session key to the server's pinned static key (CryptoKit HPKE, macOS 14+/iOS 17+; Go `crypto/hpke`, Go 1.26), and frames use ChaCha20-Poly1305 with sequence numbers.
- **Identity: Sign in with Apple or Google, then admin approval.** flowd verifies the provider's ID token against its published keys and stores the user as pending. An administrator approves or revokes users and devices. flowd issues short-lived access tokens and refresh tokens bound to a Secure Enclave device key, which provides the device binding that mTLS would have given. mTLS is not used, because client certificates end at Cloudflare.
- **Transport.** Dictation audio streams over a WebSocket, which Cloudflare tunnels support and gRPC on public hostnames does not: binary frames of compressed audio (Opus if the Apple encoder qualifies, else PCM16) and versioned JSON control messages. This departs from ADR 0013's rejection of WebSockets for audio only; rewrite and analysis stay NDJSON over HTTP. Meeting audio uploads as the existing ADTS AAC segments (ADR 0015).
- **Data.** The client stays authoritative (ADR 0006). The server keeps accounts, devices and audit metadata in SQLite and drops audio and text after each request. Every query is scoped by the token's user ID.
- **Scheduling.** Bounded per-user queues with round-robin between users. Priority is dictation, then rewrite, then meeting finalization; meeting work can be preempted, as the existing analysis gate already allows.

## Consequences

- Constitution 2.0.0 redefines principles 3, 4, 5, 8 and 14 and adds principle 15.
- New wire schemas cover auth, device registration and audio sessions. flowd moves from Go 1.23 to 1.26 for `crypto/hpke`.
- Dictation latency adds one network round trip, estimated at 15–45 ms through Cloudflare (80–260 ms has been reported on bad routing). The windows already filled are transcribed during recording, as they are locally. These figures are research estimates and not measured.
- A development build must not replace the installed local-only LocalFlow, or share its database, Keychain items or launch agents.

## Alternatives considered

- **RTX 5060 Ti Linux server.** Much faster LLM prefill and mature batching, but it needs ASR ported to NeMo with a new quality baseline, and systemd instead of launchd. Deferred behind the worker interface.
- **Tailscale Funnel.** TLS ends on the server, but it is limited to `*.ts.net` names and has an unpublished bandwidth cap.
- **Port-forward with Caddy.** Needs a public IP, exposes it, and has no DDoS shield.
- **VPS running Pangolin.** Adds a machine to operate.
- **Cloudflare Access for the app.** Browser-oriented, and native clients would need shared service tokens.
- **mTLS.** Client certificates terminate at Cloudflare, and Access mTLS requires the Enterprise plan.
- **Self-hosted IdP (Authentik, Pocket ID).** Neither provides a clean pending-approval queue.
- **gRPC streaming.** Not supported on public Cloudflare Tunnel hostnames.
- **Server-side user data storage and sync.** Out of scope (ADR 0006, roadmap item 12).
