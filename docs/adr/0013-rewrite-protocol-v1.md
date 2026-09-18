# 0013: Rewrite protocol v1

Status: Accepted for Feature 003, 2026-09-17.

## Context

The native client needs one server-independent contract for optional text rewriting. Backend tokens and prompts belong to flowd, and malformed or partial model output must never reach insertion.

## Decision

Use LocalFlow protocol v1 over HTTP/1.1, with a bounded NDJSON response. Requests contain only schema version, request UUID, mode, faithful text, language hints and the delta preference. Health reports service, protocol and backend availability. The client validates one complete terminal result before saving or inserting it. Progress and deltas are never inserted.

Results identify the server, backend/model, prompt version and shield version and carry timing fields. Validate version, request identity, mode, nonempty text, identity fields and restored placeholders. Input is limited to 20,000 scalars and 65,536 UTF-8 bytes; result text to min(4 × input bytes, 65,536); total response to min(4 × input bytes + 8,192, 73,728). Unsupported versions fail explicitly. Terminal failures preserve the faithful transcript.

The server streams from its OpenAI-compatible backend, bounds accumulation before appending each fragment and cancels on overflow. It never loads model weights. Credentials are separate at the client/server and server/backend boundaries. Off-loopback HTTP requires an explicit per-origin override and a credential.

The normative details are in [the protocol contract](../../specs/003-server-rewriting/contracts/rewrite-protocol.md) and shared [schemas](../../protocol/README.md).

## Consequences

One validated result gives insertion a stable boundary. Backend replacement does not change the client API. NDJSON allows bounded progress reporting and cancellation, but requires explicit line/body limits and terminal-event validation. Quality and latency still require measurements on the selected model.

## Alternatives considered

Direct backend calls would expose backend details and credentials in the client. A single buffered JSON response would lose progress visibility. WebSockets add connection lifecycle work without a bidirectional requirement. Progressive insertion cannot retract invalid output safely.

## Constitution check

Complies with principles 2, 5, 6, 8, 11 and 12 through bounded streams, credential isolation, separate inference, versioned validation and tested failure boundaries. No exception or new dependency.
