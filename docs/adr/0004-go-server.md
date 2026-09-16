# 0004: Go lightweight server

## Status

Accepted, 2026-09-16. Future capabilities remain deferred.

## Context

The Mac mini control plane must be small and operable under launchd.

## Decision

Use a single Go service with standard-library HTTP and separately specified SQLite/filesystem storage.

## Consequences

No mandatory Docker or distributed services. Initial executable only reports version.

## Alternatives considered

Python/Node service; microservices; mandatory containers.
