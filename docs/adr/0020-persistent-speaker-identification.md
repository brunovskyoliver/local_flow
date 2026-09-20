# 0020: Persistent speaker identification on the provisioned diarization embeddings

**Status**: Accepted (2026-09-20), Feature 010 design. The matching thresholds, region
rules and sample caps stay provisional until the calibration and measurement runs in
[acceptance/](../../specs/010-persistent-speaker-identification/acceptance/) freeze them.

## Context

Feature 007 labels each meeting with anonymous clusters ("Speaker 1", "Speaker 2") and
lets the user name them. Feature 010 adds a persistent layer: with explicit consent a
voice is remembered as a known speaker, and later meetings are compared against the
library so the transcript can show a name, a "Name?" suggestion, or nothing. The
constitution requires one model owner (3), offline operation (4), privacy by
architecture (5), bounded memory (2, 6), SQLite with explicit migrations (7), and that
persisted embeddings carry model, version, dimension, quality and creation date (10).

## Decision

- **Embedding engine.** Voice embeddings come from the WeSpeaker ResNet34-LM 256-d model
  that Feature 007 already provisions (`FluidInference/speaker-diarization-coreml`,
  offline variant). `FluidAudioVoiceEmbedder` loads the same `OfflineDiarizerModels`
  from the same verified `LocalModelDescriptor` and runs an `OfflineDiarizerManager`
  with `clustering.numSpeakers = 1`, `exposeChunkEmbeddings = true` and
  `postProcessing.exclusiveSegments = false` over one 3–20 s speech region at a time. The
  region embedding is the duration-weighted, L2-normalized mean of the dominant cluster's
  chunk embeddings. No second model, manifest, package or download path is added; the
  FluidAudio version and the diarization licence review recorded for Feature 007 (ADR
  0017) cover the embedding files used here.
- **Fourth workload, same rules.** `ModelWorkload` gains `speakerIdentification`.
  `ModelLifecycleCoordinator` gains a `VoiceEmbeddingFactory`, a resident `.embedding`
  case and one inference entry, `embed(_:region:)`. Speech workloads preempt an
  identification lease exactly as they preempt diarization; an identification acquire
  never preempts and refuses with `busy` while any owner exists; `finish` releases at
  once with no cooldown. Identification runs only after the diarization coordinator has
  finished its lease and committed adoption, so the diarizer and the embedder are never
  resident together.
- **Vectors in SQLite.** Migration `identities-v8` adds `known_speakers`,
  `voice_samples`, `meeting_identification`, `identification_runs`,
  `identity_assignments`, `match_candidates` and `rejected_candidates` to
  `history.sqlite`. One sample is a 1,024-byte `BLOB` of 256 little-endian Float32 values
  with its engine, model id, revision, manifest hash, dimension, pipeline version,
  quality, source meeting, source cluster, time range, consent and creation date. A 1 KB
  structured value is not media in the sense of constitution 7; audio never enters the
  database and vectors never leave it.
- **No SQLCipher.** The database sits under the user's home protection (FileVault) and
  app-private storage. Encrypting it separately would add a substantial dependency for a
  threat model (another local user of the same account) the constitution does not ask
  this feature to cover. Recorded as a decision, not a requirement.
- **Consent trail.** Every sample row records the explicit action that created it
  (`remember`, `also_remember`, `local_enroll`). No code path writes a sample without one;
  automatic assignments never add samples.

## Consequences and limits

- A future model change bumps the revision or engine; stored samples stay but stop being
  compared, and the speaker shows "needs re-enrollment" until re-extracted.
- Thresholds tuned on a small internal corpus may be optimistic elsewhere. The margin and
  support conditions keep automatic naming conservative; CAM++ or PLDA scoring is the
  documented upgrade path if SC-001 to SC-003 fail on calibration.
- A preempted run restarts from its first region; no mid-run state is persisted.
- The past-search queue is memory-only by design and is dropped on quit.

## Constitution check

Constitution 1.0.0: no exception. No new package, model or manifest (1, 14). One region
resident, bounded profiles and candidate rows, no full-meeting audio (2, 6). One
lifecycle owner, exclusive workloads, release without cooldown (3). Offline after
provisioning, content-free logs, samples only in app-private SQLite (4, 5). New tables
with cascades, CHECKs and single-transaction adoption, enrollment, deletion and rename
(7, 9). Diarization and identification stay separate tables and runs; uncertain matches
stay Unknown or Possible and every vector carries its model identity and creation date
(10). Fakes for the runtime and store (12). Load, release, durations and RSS recorded
per run (13).
