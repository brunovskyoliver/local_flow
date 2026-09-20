# 0017: Speaker diarization engine and workload-keyed model lifecycle

**Status**: Accepted (2026-09-18), Feature 007 design. Window length, reconciliation
and alignment thresholds stay provisional until the Phase 2 measurements in
[acceptance/throughput.md](../../specs/007-speaker-diarization/acceptance/throughput.md)
freeze them.

## Context

Feature 007 labels a finished meeting transcript by speaker. ADR 0002 already names a
future diarization engine on FluidAudio, and ADR 0007 requires ASR and diarization to
be exclusive by default. FluidAudio 0.15.7 ships several diarizers. Its offline loader
downloads and purges caches on failure unless told not to, and its Core ML predictions
can crash on macOS 14 through an Apple BNNS bug (FluidAudio issue #878).

## Decision

- **Engine.** Use FluidAudio's `OfflineDiarizerManager` (pyannote community-1: powerset
  segmentation, WeSpeaker embeddings, PLDA, VBx) with community defaults,
  `exclusiveSegments = false` so overlap survives, and `exposeChunkEmbeddings = true`
  for in-memory cross-window centroids. Each track is diarized in windows of at most
  10 minutes that never cross a recorded stretch. The microphone track is constrained to
  one speaker unless the meeting is marked in-room.
- **Assets.** A pinned manifest (`speaker-diarization-offline.json`, capability
  `speaker_diarization`) installs the offline variant through `ModelProvisioner` into its
  own directory. `ModelHub.offlineMode` is set at launch. The factory loads with
  `OfflineDiarizerModels.load(from:)` and `initialize(models:)` and never calls
  `prepareModels()`, so a missing file is an error, never a download or a cache purge.
- **Lifecycle.** `ModelLifecycleCoordinator` stays the only owner and keys its one lease
  and one resident runtime by workload (`speechRecognition`, `diarization`). A workload
  switch releases the resident runtime before preparing the other, so the two are never
  co-resident. A speech-recognition acquire preempts a diarization lease through
  `cancelAndJoin`, joining the in-flight window. A diarization acquire refuses with
  `busy` while any lease is held. A diarization lease releases at finish with no
  cooldown. With Keep model ready on, ASR is re-prepared afterwards.
- **OS gate.** Diarization runs on macOS 15 or later. On macOS 14 a run fails with
  `os_unsupported` and nothing loads. The deployment target stays macOS 14.
- **No persisted embeddings.** Window and run centroids live in memory for one run and
  are discarded at its end. Only turns, clusters, assignments and user corrections are
  stored.

## Consequences and limits

- Preemption restarts a run from its first window because no embedding is persisted.
  The preemption count is recorded; per-window resume is added only if acceptance shows
  starvation.
- Window boundaries can split a turn or leave a speaker unmatched across windows. An
  uncertain match stays a separate cluster the user can merge.
- macOS 14 users get no speaker labels until FluidAudio or Apple ships a fix.
- Remote voices played through speakers into the microphone are labeled Overlapping,
  not solved.

## Constitution check

Constitution 1.0.0: no exception. No new package (1, 14). Bounded windows, cluster
state and batches (2, 6). One lifecycle owner, exclusive workloads, release without
cooldown (3). Offline after provisioning, no network path, content-free logs, no stored
embeddings (4, 5, 10). New tables with cascades and atomic adoption (7, 9). Fakes for
the runtime and stores (12). Load, release, RTF and RSS recorded per run (13).

## Alternatives

Sortformer caps at four speakers. LS-EEND is a streaming research model with more false
alarms. The legacy `DiarizerManager` is weakest in noise and overlap. Whole-file
`process(url)` is not bounded for an 8-hour meeting. A second lifecycle coordinator for
diarization would break single ownership. Keeping ASR resident during diarization would
need a measured exception ADR.
