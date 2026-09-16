# 0003: SQLite and filesystem persistence

## Status

Accepted, 2026-09-16. Future capabilities remain deferred.

## Context

Data must be inspectable, migrated and recoverable without infrastructure.

## Decision

Use SQLite and GRDB.swift on the client, with large media in files and explicit migrations.

## Consequences

Coordinate file/database recovery. Use consistent snapshot APIs for backup. Add schema only when required.

## Alternatives considered

SwiftData/Core Data authority; media BLOBs; PostgreSQL.
