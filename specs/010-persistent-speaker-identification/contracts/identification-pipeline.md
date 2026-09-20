# Contract: identification pipeline

Internal Swift boundaries of the identification feature. Types are in `Core/IdentificationBoundaries.swift`; nothing there imports FluidAudio. Every value is `Sendable`. Storage shapes are in [../data-model.md](../data-model.md), decisions in [../research.md](../research.md).

## Embedding runtime

```swift
extension ModelWorkload { case speakerIdentification }

struct VoiceRegionRequest: Sendable, Equatable {
  static let minSamples = 48_000        // 3 s at 16 kHz
  static let maxSamples = 320_000       // 20 s
  /// Mono 16 kHz, minSamples...maxSamples, all finite.
  let samples: [Float]
  var isValid: Bool
}

struct VoiceEmbedding: Sendable, Equatable {
  static let dimension = 256
  /// L2-normalized, `dimension` finite values.
  let vector: [Float]
  /// Seconds of speech the segmentation model found inside the region.
  let speechSeconds: Double
  var isValid: Bool
}

protocol VoiceEmbeddingRuntime: Sendable {
  /// One region at a time. Throws `VoiceEmbeddingFailure.noSpeech` when the region has no
  /// speech; the caller counts it as a rejected region.
  func embed(_ request: VoiceRegionRequest) async throws -> VoiceEmbedding
  func shutdown() async
}

/// Production: FluidAudioVoiceEmbedder over the diarization OfflineDiarizerModels (R1).
/// Test double: FakeVoiceEmbeddingRuntime returning scripted vectors per call.
```

`ModelLifecycleCoordinator` additions: `init(… voiceEmbeddingFactory:)`, `Resident.embedding`, `func embed(_ lease: ModelLease, region: VoiceRegionRequest) async throws -> VoiceEmbedding` (guards: owner, `.active`, resident workload `.speakerIdentification`, one in-flight call, `request.isValid`, `result.isValid`). Speech workloads preempt an identification lease exactly as they preempt diarization; an identification acquire never preempts and throws `busy` when any owner exists; `finish` releases at once with no cooldown.

## Region reader

```swift
struct VoiceRegion: Sendable, Equatable {
  let track: MeetingTrackKind
  let startMs: Int64      // recorded timeline
  let endMs: Int64
  let engineQuality: Double?
}

/// Decodes one stretch file forward once and yields each requested region's samples in
/// time order. Never seeks. Holds one region plus 4,096-frame decode buffers.
actor VoiceRegionReader {
  init(storageRoot: MeetingStorageRoot, detail: MeetingDetail, bases: [Int: (Int64, Int64?)])
  func read(
    _ regions: [VoiceRegion],
    handler: @Sendable (VoiceRegion, [Float]) async throws -> Void
  ) async throws
}
```

Failure mapping: open/read/convert errors → `audio_decode_failure`; missing file → the region is skipped and counted `audio_missing` unless every region is missing, which fails the run `audio_missing`.

## Pure logic

```swift
/// regions_v1 (R4). Deterministic for equal input.
enum VoiceRegionSelector {
  struct Limits { let maxRegions: Int; let maxTotalMs: Int64 }   // enroll 5/100_000, query 4/60_000
  static func select(
    rootTurns: [SpeakerTurn], otherTurns: [SpeakerTurn], meetingLengthMs: Int64, limits: Limits
  ) -> [VoiceRegion]
  static func audioCheck(_ samples: [Float]) -> RegionRejection?   // clipped, too_quiet
  static func qualityLabel(durationMs: Int64, engineQuality: Double?) -> VoiceQualityLabel
  static func qualityScore(durationMs: Int64, engineQuality: Double?) -> Double
}

/// tiers_v1 (R6). Never sees the UI; never produces a percentage.
struct IdentificationThresholds: Sendable, Equatable {
  let high: Float, medium: Float, margin: Float
  let minSupport: Int, minQuerySpeechMs: Int64
  let policyVersion: String                       // "tiers_v1@<engine>/<revision8>"
  static func current(for identity: VoiceModelIdentity) -> IdentificationThresholds?
}

struct CandidateProfile: Sendable { let id: UUID; let samples: [[Float]]; let isLocalUser: Bool }
struct QueryRegion: Sendable { let vector: [Float]; let weightMs: Int64 }

enum IdentityMatcher {
  struct Candidate: Sendable, Equatable {
    let knownSpeakerID: UUID; let score: Float; let tier: CandidateTier
    let reasons: [CandidateReason]; let sampleCount: Int; let supportCount: Int
  }
  struct Decision: Sendable, Equatable {
    let state: IdentityState          // recognized | possible | unknown
    let best: Candidate?              // nil when unknown
    let second: Candidate?            // within-margin runner-up for Choose another
    let candidates: [Candidate]       // every scored profile, for match_candidates
  }
  static func decide(
    query: [QueryRegion], profiles: [CandidateProfile], rejected: Set<UUID>,
    thresholds: IdentificationThresholds
  ) -> Decision
}

/// retire_qd_v1 (R5).
enum SampleRetirementPolicy {
  struct Entry { let id: UUID; let vector: [Float]; let qualityScore: Double }
  static func retire(active: [Entry], incoming: [Entry], cap: Int) -> (keep: [UUID], retire: [UUID])
}

/// R11.
enum MergedIdentityRule {
  static func effective(root: IdentityRow?, members: [IdentityRow?], resolution: IdentityRow?) -> EffectiveIdentity
}
```

## Store

```swift
protocol IdentityStoring: Sendable {
  // Known speakers (FR-042)
  func knownSpeakers() async throws -> [KnownSpeakerRow]
  func createKnownSpeaker(name: String, isLocalUser: Bool, now: Int64) async throws -> KnownSpeakerRow
  func rename(knownSpeakerID: UUID, to name: String, expectedRevision: Int64, now: Int64) async throws
  func setRecognition(knownSpeakerID: UUID, enabled: Bool, expectedRevision: Int64, now: Int64) async throws
  /// R9: copies nothing it does not need to; leaves zero referencing rows.
  func deleteKnownSpeaker(id: UUID, expectedRevision: Int64) async throws
  func samples(knownSpeakerID: UUID) async throws -> [VoiceSampleRow]
  func removeSample(id: UUID, now: Int64) async throws
  /// Cap and retirement inside the transaction; refuses when the source cluster is in
  /// rejected_candidates for this speaker (FR-007).
  func addSamples(knownSpeakerID: UUID, drafts: [VoiceSampleDraft], consent: SampleConsent, now: Int64) async throws -> Int
  func profiles(compatibleWith identity: VoiceModelIdentity) async throws -> [CandidateProfile]

  // Runs (FR-022 to FR-025)
  func identification(meetingID: UUID) async throws -> MeetingIdentification?
  func admit(meetingID: UUID, trigger: IdentificationTrigger, identity: VoiceModelIdentity, policy: String, now: Int64) async throws -> IdentificationRun
  func start(runID: UUID, now: Int64) async throws -> IdentificationRun
  func appendCandidates(runID: UUID, rows: [MatchCandidateDraft]) async throws
  /// One transaction (R7): replaces automatic rows, keeps manual rows, supersedes, prunes.
  func complete(runID: UUID, decisions: [UUID: IdentityMatcher.Decision], now: Int64) async throws -> IdentificationRun
  func fail(runID: UUID, category: IdentificationFailureCategory, detail: String?, now: Int64) async throws
  func interrupt(runID: UUID, now: Int64) async throws
  func requeue(runID: UUID) async throws
  func cancel(runID: UUID) async throws
  func activeRuns(limit: Int) async throws -> [IdentificationRun]
  func meetingState(meetingID: UUID) async throws -> MeetingIdentificationState
  func meetingsWithUnknownRemoteSpeakers(limit: Int) async throws -> [UUID]

  // Assignments (US1, US3, US4, US7)
  func identities(meetingID: UUID) async throws -> [UUID: SpeakerIdentity]     // per display root
  func link(meetingID: UUID, speakerID: UUID, to knownSpeakerID: UUID, origin: IdentityOrigin, now: Int64) async throws
  func reject(meetingID: UUID, speakerID: UUID, candidate knownSpeakerID: UUID, keepUnknown: Bool, now: Int64) async throws
  func resolveMerged(meetingID: UUID, rootID: UUID, to: MergedResolution, now: Int64) async throws
  func clearMergedResolution(meetingID: UUID, rootID: UUID) async throws             // called by unmerge
  func unlink(meetingID: UUID, speakerID: UUID, now: Int64) async throws              // back to unknown, kept_unknown
}
```

Refusals: `IdentityStore.Error.capacity(kind)` for known speakers, samples, rejected candidates and candidates; `persistenceCapacity` for SQLITE_FULL; `revisionMismatch` for stale Settings edits; `rejectedSource` for FR-007.

## Coordinator

```swift
@MainActor protocol IdentificationObserving: AnyObject {
  func diarizationDidAdopt(meetingID: UUID)          // after the diarization lease finished
  func meetingWillDelete(id: UUID) async
}

@MainActor @Observable final class SpeakerIdentificationCoordinator: IdentificationObserving {
  static let queueCapacity = 100
  static let pastSearchCapacity = 500
  var status: IdentificationStatus?                  // displayed meeting
  func requestRun(meetingID: UUID, trigger: IdentificationTrigger) async
  func cancel(meetingID: UUID) async
  func enroll(_ request: EnrollmentRequest) async -> EnrollmentOutcome   // queue-ordered, own lease
  func startPastSearch(knownSpeakerID: UUID) async -> Int                 // queued count
  func cancelPastSearch()
  func resume(_ ids: [UUID])                          // launch reconciliation
}
```

Run algorithm (`MeetingIdentifier` actor):

1. Load the pending run; verify the meeting's accepted diarization run id equals `run.diarizationRunID`, else fail `diarization_changed`.
2. Load compatible profiles (`recognition_enabled`, not local unless for evidence, ≥ 1 active compatible sample). If none, complete the run at once with every remote root `unknown` (no lease).
3. Acquire `.speakerIdentification`; `busy` leaves the run pending, `cancelled` marks it preempted (`running → pending`).
4. `start`. For each remote display root: select query regions (`regions_v1`, query limits), read them through `VoiceRegionReader`, embed each as it completes, count rejections. Progress is regions done over regions planned.
5. `finish` the lease. Compute `IdentityMatcher.decide` per root, excluding rejected candidates. Append candidates. Check the accepted diarization run again, then `complete` in one transaction. Record metrics.
6. Any error after `start`: `fail` with the category, delete the run's candidates, leave assignments untouched. Cancellation deletes the run row.

Enrollment algorithm (`EnrollmentJob`):

1. In one transaction create the profile (or use the chosen existing one) and the `confirmed` identity row with the request's origin. This commits before any model work so a failure leaves "0 samples" and a linked name.
2. Select regions (enroll limits) from the root's turns on its track (microphone for the local-user profile).
3. Acquire the lease, embed each region as it is read, release.
4. `addSamples` with the consent value; the store applies the cap and refuses rejected sources.
5. Report `stored(n)` or `noUsableSample`. When `n ≥ 1`, publish `enrollmentDidStore` for the past-meeting prompt.

## Bounds summary (normative)

| Item | Bound |
| --- | --- |
| Identification queue | 100 ids, deduplicated, one run at a time |
| Past-search queue | 500 ids, memory only, one at a time, cancellable |
| Region request | 48,000–320,000 samples |
| Regions | 5 per enrollment, 4 per query root; 64 roots per run (007 cluster cap) |
| Resident audio | one region + decode buffers |
| Profiles in memory | ≤ 1,000 × 10 × 256 Float32 |
| Candidate rows per run | ≤ 64,000 (`persistence_capacity` above) |
| Active samples per profile per model | 10 (+10 retired) |
| Known speakers | 1,000 |
| Rejected candidates per meeting | 1,000 |
| Name copy on rename | batches of 500 rows |

Nothing is dropped silently: every skipped region, refused write or overflow is counted in the run row or surfaced as a notice.

## Metrics (content-free)

Phases: `identifying`, `modelLoading(identification)`, `modelActive(identification)`, `modelReleasing(identification)`. Metrics: the list in [research R14](../research.md#r14-observability-and-acceptance). No name, vector, time range, transcript text or meeting id is recorded.
