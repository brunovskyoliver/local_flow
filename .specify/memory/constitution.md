<!-- Sync impact report
Version: template -> 1.0.0 (initial ratification)
Principles: all 14 LocalFlow principles adopted.
Added: delivery gates and governance.
Templates: plan/spec/tasks templates reviewed; project gates appended.
Deferred follow-ups: none. Hardware budgets are targets, not measured results.
-->
# LocalFlow constitution

## Core principles

### 1. Native lightweight client

The client MUST use Swift, SwiftUI and Apple frameworks, with AppKit where needed. Electron, Chromium shells, embedded UI web servers, client LLMs, and persistent Python or Node runtimes are prohibited.

### 2. Memory efficiency

Memory is a product requirement. Every queue, stream, cache and buffer MUST have an explicit capacity and overload policy. Models MUST be lazy-loaded and releasable. Resource regressions are defects. Initial unloaded client RSS target is 150 MB; recording overhead is 100 MB above idle excluding ML working sets. Model working sets MUST be measured independently on M5, not assigned invented limits.

### 3. Explicit model lifecycle

A central ModelLifecycleCoordinator MUST exclusively authorize heavy model creation, use, cancellation and release. Features MUST NOT instantiate runtimes. ASR and diarization MUST be mutually exclusive by default. Exceptions require an ADR backed by measurements.

### 4. Local-first operation

Dictation, capture, recording, transcription and local persistence MUST work offline after explicit model provisioning. The client owns locally created data. Server or network failure MUST NOT destroy recordings or transcripts.

### 5. Privacy by architecture

Speech recognition and recordings MUST remain local by default. No mandatory cloud, telemetry, advertising or external analytics SDK is allowed. Credentials belong in Keychain. Logs MUST exclude audio, transcript text and credentials. Changes to these defaults require a specification and explicit user consent.

### 6. Streaming over accumulation

Audio, large files and network payloads MUST be processed incrementally with bounded working memory. Full meeting audio MUST NEVER be loaded into memory. Normal dictation audio is ephemeral; bounded temporary files must be cleaned after completion, cancellation, failure and on restart.

### 7. Simple persistence

Structured data MUST use SQLite, preferably GRDB.swift on the client, with explicit migrations and transactions. Media belongs in files, never database BLOBs. SwiftData/Core Data MUST NOT be the storage authority. Add only schema needed by the current feature.

### 8. Server isolation

The control server MUST use Go and run independently of the LLM runtime, including under launchd without Docker. It MUST NOT load LLM weights. Clients speak LocalFlow API only; backend-specific inference stays behind a server adapter. Idle server RSS target is 100 MB; ordinary processing target is 250 MB excluding the LLM process.

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

Build thin feature slices through Spec Kit. Do not add speculative infrastructure, package proliferation, distributed queues, accounts or generic platforms. Prefer Apple APIs, then small maintained native dependencies. Substantial dependencies require documented justification and license review. Never copy VoiceInk application source.

## Delivery gates

Substantial changes follow specify, clarify where needed, plan, tasks, analyze, implement and converge. Each plan MUST document constitution compliance, bounds/overload behavior, model ownership, privacy, recovery, dependencies and validation. Resource acceptance is part of feature acceptance. Meeting and server capabilities remain separate specifications.

## Governance

This constitution takes precedence over convenience and feature-local designs. Reviewers MUST check compliance. Exceptions require an ADR documenting the conflict, evidence, mitigation and approval; an ADR alone does not silently amend a mandatory principle. Amendments record rationale, update affected templates/docs/specs and use semantic versioning: major for incompatible principles, minor for additions, patch for clarifications. Unmeasured targets MUST NOT be represented as achieved.

**Version**: 1.0.0 | **Ratified**: 2026-09-16 | **Last amended**: 2026-09-16
