# 0005: LLM runtime isolated from API server

## Status

Accepted, 2026-09-16. Future capabilities remain deferred.

## Context

Inference weights must not inflate the control server or client.

## Decision

Run inference as an independent process behind a server adapter; clients use LocalFlow API only.

## Consequences

Independent restarts and resource accounting; bounded timeouts and validated outputs are required.

## Alternatives considered

Embedded LLM; client-specific Ollama/MLX calls.
