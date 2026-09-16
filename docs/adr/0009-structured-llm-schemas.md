# 0009: Structured LLM schemas

## Status

Accepted, 2026-09-16. Future capabilities remain deferred.

## Context

Generated prose is not a reliable application contract.

## Decision

Use shared versioned JSON schemas, validate before persistence/rendering, and check referenced identities against source data.

## Consequences

Initial schemas are provisional design contracts only. Breaking changes need version changes. Uncertain ownership remains null.

## Alternatives considered

Markdown parsing; arbitrary unvalidated JSON.
