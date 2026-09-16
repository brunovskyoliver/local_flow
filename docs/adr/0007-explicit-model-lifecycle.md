# 0007: Explicit ML model lifecycle

## Status

Accepted, 2026-09-16. Future capabilities remain deferred.

## Context

Hidden caching and concurrent heavy runtimes undermine memory targets.

## Decision

Centralize exclusive workload leases, lazy preparation, cancellation and release in ModelLifecycleCoordinator.

## Consequences

Feature code cannot create runtimes. ASR and diarization are exclusive by default. Test timer races and measure actual release.

## Alternatives considered

Per-feature ownership; permanent model cache; always-loaded inference.

## Amendment: user-selected idle retention (2026-09-16)

The user requested keeping the model loaded to avoid cold-start delays. Add a persistent opt-in idle retention policy, with startup preparation of verified assets under ModelLifecycleCoordinator. Default behavior remains lazy with a 30-second idle cooldown. The opted-in runtime stays resident after successful use. Manual unload, cancellation/failure, replacement and shutdown retain joined release; disabling retention restores a fresh cooldown.

Constitution check: passes principles 2 and 3. Startup loading occurs only on a saved explicit user request, and the runtime remains releasable and centrally owned. All existing capacity, privacy and source boundaries remain intact. This is a configurable residency policy, not an ownership exception. Extra resident model memory is expected; no new hardware memory claim is made.
