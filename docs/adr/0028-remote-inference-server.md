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

## Refinements from Feature 014 (first slice)

Feature 014's design ([research](../../specs/014-remote-dictation-server/research.md) R2, R4, R14) refines two points of the decision above and one of its consequences. The status stays Proposed until the hardware and network acceptance in `specs/014-remote-dictation-server/acceptance/` is recorded.

- **Audio is raw Float32, not Opus or PCM16 (R2).** Dictation frames carry the spool's own little-endian Float32 samples at 16 kHz, at most 16,000 per frame, sent every 200 ms while the user speaks. The server then recognizes exactly the samples local dictation would, so remote and local transcripts can be identical (SC-005). At 512 kbit/s this is well within home and LTE uplinks, and only the last 200 ms is sent after key release. `dictation_start` carries a `format` field (`f32le`), so PCM16 can be added later if the LTE latency measurement shows the uplink is the bottleneck.
- **The server-to-client direction is a second HPKE context (R4).** Both directions use HPKE base mode with DHKEM(X25519, HKDF-SHA256), HKDF-SHA256 and ChaCha20-Poly1305. The client's hello carries a fresh X25519 reply key; the server opens an HPKE sender to it with `info` exported from the client-to-server context, so only the holder of that context can open server frames. Each frame's 8-byte sequence number is authenticated as the AEAD additional data and must equal the receiver's counter. This replaces "the client seals a session key to the server's pinned static key" with two standard contexts, because standalone ChaCha20-Poly1305 is not public in Go's standard library and both directions then keep HPKE's own nonce counters.
- **Rewrites also travel over the channel (R14).** With remote dictation on and the device approved, rewrite requests use the authenticated channel instead of the Feature 003 shared-token HTTP route; the request and event JSON are unchanged. Meeting analysis stays on HTTP in this slice.


## Amendment: Tailscale Funnel as the exposure (2026-10-01)

The owner chose Tailscale Funnel over Cloudflare Tunnel for the Mac mini: `tailscale funnel --bg 8090` publishes the remote listener at `https://mac-mini.tailf15b6.ts.net`. Only the exposure changes. flowd still authenticates every user and device, the client still pins the server key and seals audio and text in the HPKE channel, and only 8090 is published (not the rewrite listener). TLS now terminates on the mini instead of at Cloudflare. The objections above still hold and are accepted: the hostname is a `*.ts.net` name, and Funnel's bandwidth cap is unpublished, which matters little for 512 kbit/s dictation streams. Funnel needs the tailnet's `funnel` node attribute, which the owner grants in the admin console. Cloudflare stays documented as the alternative. Constitution check: principle 8 (flowd loads no weights and runs under launchd) and principle 15 (approved users, short-lived device-bound tokens, per-user scoping) are unchanged; the router still has no forwarded port and clients need no VPN. Latency through Funnel is not measured.

## Amendment: every service on the server (2026-10-01)

ADR 0031 (Feature 018) extends this decision to summaries, live meeting preview, final meeting transcription, speaker labels and voice embeddings, and supersedes the line "meeting audio uploads as the existing ADTS AAC segments": the Mac sends prepared 16-bit windows instead.
