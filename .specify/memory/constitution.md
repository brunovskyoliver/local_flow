<!-- Sync impact report
Version: 1.0.0 -> 2.0.0 (major: principles 3, 4, 5, 8 and 14 redefined for opt-in remote inference)
Modified: 3 Explicit model lifecycle (server workers); 4 Local-first operation (local fallback);
  5 Privacy by architecture (remote inference opt-in, encrypted, no server retention);
  8 Server isolation (gateway plus model worker processes); 14 Scope discipline (accounts allowed
  only on a self-hosted, admin-approved server).
Added: 15 Authenticated, isolated server access. Delivery gate for remote capabilities.
Templates: plan/spec/tasks templates read the constitution at run time; no template edits.
Related: ADR 0028 (proposed). Deferred follow-ups: remote inference specification; latency and
  resource budgets for remote dictation are unmeasured targets.
-->
# LocalFlow constitution

## Core principles

### 1. Native lightweight client

The client MUST use Swift, SwiftUI and Apple frameworks, with AppKit where needed. Electron, Chromium shells, embedded UI web servers, client LLMs, and persistent Python or Node runtimes are prohibited.

### 2. Memory efficiency

Memory is a product requirement. Every queue, stream, cache and buffer MUST have an explicit capacity and overload policy. Models MUST be lazy-loaded and releasable. Resource regressions are defects. Initial unloaded client RSS target is 150 MB; recording overhead is 100 MB above idle excluding ML working sets. Model working sets MUST be measured independently on M5, not assigned invented limits.

### 3. Explicit model lifecycle

A central ModelLifecycleCoordinator MUST exclusively authorize heavy model creation, use, cancellation and release. Features MUST NOT instantiate runtimes. ASR and diarization MUST be mutually exclusive by default. Exceptions require an ADR backed by measurements. On a server, each model runtime MUST have one owner that admits, schedules, cancels and releases work for all users; request handlers MUST NOT instantiate runtimes.

### 4. Local-first operation

Dictation, capture, recording, transcription and local persistence MUST work offline after explicit model provisioning. Remote inference is an optional mode; when the server is unreachable, slow or rejects a request, the client MUST fall back to local models where they are provisioned, or keep the audio for a retry, and MUST NOT lose it. The client owns locally created data. Server or network failure MUST NOT destroy recordings or transcripts.

### 5. Privacy by architecture

Speech recognition and recordings MUST remain local by default. Sending audio or text to a server requires explicit per-device opt-in and is allowed only to a LocalFlow server the user or their administrator operates. Audio and text MUST be encrypted in transit end to end between client and that server; when TLS terminates at a third party such as a tunnel provider, an inner application-layer encryption layer is required. The server MUST process audio and text in memory or bounded temporary files and MUST NOT retain them after the request, unless a later specification adds user-controlled storage. No mandatory cloud, telemetry, advertising or external analytics SDK is allowed. Credentials and device keys belong in Keychain or the Secure Enclave. Logs on client and server MUST exclude audio, transcript text and credentials. Changes to these defaults require a specification and explicit user consent.

### 6. Streaming over accumulation

Audio, large files and network payloads MUST be processed incrementally with bounded working memory. Full meeting audio MUST NEVER be loaded into memory. Normal dictation audio is ephemeral; bounded temporary files must be cleaned after completion, cancellation, failure and on restart.

### 7. Simple persistence

Structured data MUST use SQLite, preferably GRDB.swift on the client, with explicit migrations and transactions. Media belongs in files, never database BLOBs. SwiftData/Core Data MUST NOT be the storage authority. Add only schema needed by the current feature.

### 8. Server isolation

The control server MUST use Go and run independently of every model runtime, including under launchd without Docker. It MUST NOT load model weights: LLM, ASR, diarization and embedding models run in separate worker processes behind server adapters, and a worker crash MUST NOT take down the server. Clients speak LocalFlow API only; backend-specific inference stays behind a server adapter. Idle server RSS target is 100 MB; ordinary processing target is 250 MB excluding model worker processes.

### 9. Recoverability

Long-lived data MUST use crash-safe writes. Future meeting capture MUST detect and recover incomplete sessions after crashes, forced quit and storage errors. Backup MUST use consistent SQLite snapshots, stable identifiers, hashes, resumability and idempotency. Copying a live database file alone is prohibited. Backup is not synchronization.

### 10. Speaker attribution correctness

Diarization and identification MUST remain distinct. Uncertain identities MUST remain unknown and correctable. Persistent embeddings MUST record model, version, dimension, quality metadata and creation date; a timeless vector on a participant is prohibited.

### 11. Structured LLM output

AI outputs MUST conform to versioned shared schemas and be validated before persistence or rendering. Behavior MUST NOT depend on parsing arbitrary prose or Markdown. Ordinary summarization sends structured transcript text, not audio.

### 12. Testability

External and AI boundaries MUST have protocols and test doubles. Tests MUST cover lifecycle transitions, cancellation, capacity limits, failure recovery and preservation of completed text. Add regression tests for defects where practical.

### 13. Local observability

Development tooling MUST measure RSS, model load/unload duration, ASR and diarization incremental memory, recording overhead, queue depth, transcription/finalization duration and server latency locally. Reports MUST identify hardware, build, model and conditions.

### 14. Scope discipline

Build thin feature slices through Spec Kit. Do not add speculative infrastructure, package proliferation, distributed queues, multi-server clustering or generic platforms. Accounts are allowed only as described in principle 15; public self-service platforms, billing and cross-server federation are out of scope. Prefer Apple APIs, then small maintained native dependencies. Substantial dependencies require documented justification and license review. Never copy VoiceInk application source.

### 15. Authenticated, isolated server access

A LocalFlow server serves only approved users. Identity comes from Sign in with Apple, Google or another OIDC provider, verified by the server against the provider's keys; a new identity starts pending and gets no inference until an administrator approves it. There is no open registration and no shared static secret for remote clients. Server-issued access tokens MUST be short-lived, refresh MUST be bound to a per-device key, and administrators MUST be able to revoke a device or user immediately. Every request MUST be scoped by the user identity from the verified token, never from the request body. One user's audio, text, caches and results MUST NOT be visible to another; shared caches may hold only content common to all users, such as fixed prompts. Scheduling MUST be fair and bounded per user, with dictation ahead of rewriting and rewriting ahead of meeting work; overload returns an explicit busy result rather than unbounded queuing.

## Delivery gates

Substantial changes follow specify, clarify where needed, plan, tasks, analyze, implement and converge. Each plan MUST document constitution compliance, bounds/overload behavior, model ownership, privacy, recovery, dependencies and validation. Resource acceptance is part of feature acceptance. Meeting and server capabilities remain separate specifications. Remote capabilities MUST also document the threat model, authentication and revocation, per-user isolation, fallback behavior and measured network latency on the target server hardware.

## Governance

This constitution takes precedence over convenience and feature-local designs. Reviewers MUST check compliance. Exceptions require an ADR documenting the conflict, evidence, mitigation and approval; an ADR alone does not silently amend a mandatory principle. Amendments record rationale, update affected templates/docs/specs and use semantic versioning: major for incompatible principles, minor for additions, patch for clarifications. Unmeasured targets MUST NOT be represented as achieved.

**Version**: 2.0.0 | **Ratified**: 2026-09-16 | **Last amended**: 2026-09-27
