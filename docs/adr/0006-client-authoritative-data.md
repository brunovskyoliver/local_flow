# 0006: Local-first client-authoritative data

## Status

Accepted, 2026-09-16. Future capabilities remain deferred.

## Context

Recording and transcription must survive network/server failure.

## Decision

Keep authoritative data locally. Server archival is backup, not synchronization.

## Consequences

Pending AI/backup work remains locally usable. Stable UUIDs, hashes and snapshot semantics precede backup implementation.

## Alternatives considered

Server-authoritative data; initial multi-device synchronization.
