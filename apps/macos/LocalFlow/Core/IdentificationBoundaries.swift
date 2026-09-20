import Foundation

/// The meeting domain's view of persistent speaker identification (Feature 010,
/// contracts/identification-pipeline.md). Nothing here imports FluidAudio; every value
/// is `Sendable`. Four ideas stay separate: meeting-local speaker (`meeting_speakers`),
/// known speaker (`known_speakers`), identity assignment (`identity_assignments`) and
/// origin/certainty (columns of that row plus `match_candidates`).

// MARK: - Embedding runtime

struct VoiceRegionRequest: Sendable, Equatable {
  /// 3 s at 16 kHz.
  static let minSamples = 48_000
  /// 20 s at 16 kHz.
  static let maxSamples = 320_000
  /// Mono 16 kHz, minSamples...maxSamples, all finite.
  let samples: [Float]

  var isValid: Bool {
    (Self.minSamples...Self.maxSamples).contains(samples.count) && samples.allSatisfy(\.isFinite)
  }
}

struct VoiceEmbedding: Sendable, Equatable {
  static let dimension = 256
  /// L2-normalized, `dimension` finite values.
  let vector: [Float]
  /// Seconds of speech the segmentation model found inside the region.
  let speechSeconds: Double

  var isValid: Bool {
    guard vector.count == Self.dimension, vector.allSatisfy(\.isFinite), speechSeconds.isFinite,
      speechSeconds >= 0
    else { return false }
    let norm = vector.reduce(Float(0)) { $0 + $1 * $1 }.squareRoot()
    return abs(norm - 1) < 0.01
  }
}

enum VoiceEmbeddingFailure: Error, Equatable, Sendable {
  /// The region had no speech; the caller counts it as a rejected region.
  case noSpeech
}

protocol VoiceEmbeddingRuntime: Sendable {
  /// One region at a time. Throws `VoiceEmbeddingFailure.noSpeech` when the region has
  /// no speech.
  func embed(_ request: VoiceRegionRequest) async throws -> VoiceEmbedding
  func shutdown() async
}

typealias VoiceEmbeddingFactory = @Sendable () async throws -> any VoiceEmbeddingRuntime

// MARK: - Regions

/// One eligible speech region of one cluster on the recorded timeline.
struct VoiceRegion: Sendable, Hashable {
  let track: MeetingTrackKind
  let startMs: Int64
  let endMs: Int64
  let engineQuality: Double?

  var durationMs: Int64 { endMs - startMs }
}

/// Why a decoded region was not used (research R4).
enum RegionRejection: String, Sendable, Equatable {
  case clipped
  case tooQuiet = "too_quiet"
  case noSpeech = "no_speech"
}

enum VoiceQualityLabel: String, Sendable, Codable, CaseIterable {
  case good, fair
}

// MARK: - Matching inputs

/// A recognition-enabled known speaker's active compatible samples, loaded once per run.
struct CandidateProfile: Sendable, Equatable {
  let id: UUID
  let samples: [[Float]]
  let isLocalUser: Bool
  /// FR-015: a disabled profile is scored for audit but never named or suggested.
  var recognitionEnabled = true
}

struct QueryRegion: Sendable, Equatable {
  let vector: [Float]
  let weightMs: Int64
}

// MARK: - Store drafts

/// One region's embedding with everything FR-027 asks a sample to record.
struct VoiceSampleDraft: Sendable, Equatable {
  let vector: [Float]
  let identity: VoiceModelIdentity
  let pipelineVersion: String
  let qualityLabel: VoiceQualityLabel
  let qualityScore: Double
  let engineQuality: Double?
  let speechMs: Int64
  let track: MeetingTrackKind
  let startMs: Int64
  let endMs: Int64
  let sourceMeetingID: UUID
  let sourceSpeakerID: UUID
}

/// One `match_candidates` row of a run.
struct MatchCandidateDraft: Sendable, Equatable {
  let meetingSpeakerID: UUID
  let knownSpeakerID: UUID
  let score: Float
  let tier: CandidateTier
  let reasons: [CandidateReason]
  let sampleCount: Int
  let supportCount: Int
}

/// The `merged` row written when the user resolves a merge conflict (research R11).
enum MergedResolution: Sendable, Equatable {
  case knownSpeaker(UUID)
  case keepUnknown
}

// MARK: - Read models

/// The within-margin runner-up shown under Choose another.
struct IdentityCandidateRef: Sendable, Equatable {
  let id: UUID
  let name: String
}

/// One display root's effective identity (data-model.md "Read models"). Never a score.
struct SpeakerIdentity: Sendable, Equatable {
  var state: IdentityState
  var origin: IdentityOrigin
  var knownSpeakerID: UUID?
  var knownSpeakerName: String?
  var secondCandidate: IdentityCandidateRef?
  /// A merge conflict: the sheet says "Choose an identity" and blocks Save.
  var needsChoice = false
  /// The selector found at least one eligible region for the cluster.
  var sampleOfferAvailable = false

  static let unknown = SpeakerIdentity(state: .unknown, origin: .automaticMatch)
}

/// How a transcript row labels its speaker (FR-040).
enum SegmentIdentity: Sendable, Equatable {
  /// `confirmed` or `recognized`: the known speaker's name.
  case named
  /// `possible`: "Name?" with the confirm control, which links to the candidate.
  case suggested(name: String, knownSpeakerID: UUID)
  /// `unknown`, `rejected_unknown` or no row: the 007 label.
  case unknown
}

enum KnownSpeakerState: String, Sendable, Equatable {
  case active
  case needsReenrollment = "needs_reenrollment"
}

/// A Settings row (FR-042).
struct KnownSpeakerRow: Sendable, Equatable, Identifiable {
  let id: UUID
  let name: String
  let activeSampleCount: Int
  let recognitionEnabled: Bool
  let state: KnownSpeakerState
  let isLocalUser: Bool
  let revision: Int64
  let createdAt: Int64
}

/// A sample row in Settings (FR-043): never the vector or a score.
struct VoiceSampleRow: Sendable, Equatable, Identifiable {
  let id: UUID
  let sourceTitle: String?
  /// The source meeting's start, or `created_at` when provenance is unavailable.
  let sourceDate: Int64
  let provenanceUnavailable: Bool
  let speechMs: Int64
  let qualityLabel: VoiceQualityLabel
  let createdAt: Int64
}

/// The status line's view of one meeting (contracts/ui.md).
struct IdentificationStatus: Sendable, Equatable {
  struct PastSearch: Sendable, Equatable {
    let name: String
    let remaining: Int
  }
  let meetingID: UUID
  var state: MeetingIdentificationState
  /// Regions done over regions planned, while running.
  var progress: Double?
  var failure: IdentificationFailureCategory?
  /// An enrollment job for this meeting is queued or extracting.
  var enrolling = false
  var pastSearch: PastSearch?
  /// Bumped whenever this meeting's effective identities change.
  var identityRevision = 0
}

// MARK: - Store

/// Every identity table write goes through one implementation of this.
protocol IdentityStoring: Sendable {
  // Known speakers (FR-042)
  func knownSpeakers() async throws -> [KnownSpeakerRow]
  func createKnownSpeaker(name: String, isLocalUser: Bool, now: Int64) async throws
    -> KnownSpeakerRow
  /// Remember: the profile and, when `speakerID` is given, its `confirmed` identity row
  /// in one transaction, before any model work.
  func enroll(
    meetingID: UUID, speakerID: UUID?, name: String, isLocalUser: Bool, origin: IdentityOrigin,
    now: Int64
  ) async throws -> KnownSpeakerRow
  func rename(knownSpeakerID: UUID, to name: String, expectedRevision: Int64, now: Int64)
    async throws
  func setRecognition(knownSpeakerID: UUID, enabled: Bool, expectedRevision: Int64, now: Int64)
    async throws
  /// R9: keeps copied names; leaves zero referencing rows.
  func deleteKnownSpeaker(id: UUID, expectedRevision: Int64) async throws
  func samples(knownSpeakerID: UUID) async throws -> [VoiceSampleRow]
  func removeSample(id: UUID, now: Int64) async throws
  /// Cap and retirement inside the transaction; refuses when the source cluster is in
  /// `rejected_candidates` for this speaker (FR-007). Returns the rows inserted.
  func addSamples(
    knownSpeakerID: UUID, drafts: [VoiceSampleDraft], consent: SampleConsent, now: Int64
  ) async throws -> Int
  func profiles(compatibleWith identity: VoiceModelIdentity) async throws -> [CandidateProfile]

  // Runs (FR-022 to FR-025)
  func identification(meetingID: UUID) async throws -> MeetingIdentification?
  func admit(
    meetingID: UUID, trigger: IdentificationTrigger, identity: VoiceModelIdentity,
    policy: String, now: Int64
  ) async throws -> IdentificationRun
  func run(id: UUID) async throws -> IdentificationRun?
  func start(runID: UUID, now: Int64) async throws -> IdentificationRun
  func appendCandidates(runID: UUID, rows: [MatchCandidateDraft]) async throws
  /// One transaction (R7): replaces automatic rows, keeps manual rows, supersedes, prunes.
  func complete(runID: UUID, decisions: [UUID: IdentityMatcher.Decision], now: Int64)
    async throws -> IdentificationRun
  func fail(runID: UUID, category: IdentificationFailureCategory, detail: String?, now: Int64)
    async throws
  func interrupt(runID: UUID, now: Int64) async throws
  func requeue(runID: UUID) async throws
  func cancel(runID: UUID) async throws
  func activeRuns(limit: Int) async throws -> [IdentificationRun]
  /// The newest run that is not `superseded`, for the status line's failure.
  func latestRun(meetingID: UUID) async throws -> IdentificationRun?
  func meetingState(meetingID: UUID) async throws -> MeetingIdentificationState
  /// Meetings with an accepted diarization run and at least one remote root whose
  /// effective identity is `unknown` or absent, newest first.
  func meetingsWithUnknownRemoteSpeakers(limit: Int) async throws -> [UUID]

  // Assignments (US1, US3, US4, US7)
  func identities(meetingID: UUID) async throws -> [UUID: SpeakerIdentity]
  /// FR-020: the rejected known speakers per cluster, excluded from matching.
  func rejectedCandidates(meetingID: UUID) async throws -> [UUID: Set<UUID>]
  /// Region counts of a running run, for the run row and the status line.
  func recordRegions(runID: UUID, extracted: Int, rejected: Int) async throws
  func link(
    meetingID: UUID, speakerID: UUID, to knownSpeakerID: UUID, origin: IdentityOrigin,
    now: Int64) async throws
  func reject(
    meetingID: UUID, speakerID: UUID, candidate knownSpeakerID: UUID, keepUnknown: Bool,
    now: Int64
  ) async throws
  func resolveMerged(meetingID: UUID, rootID: UUID, to resolution: MergedResolution, now: Int64)
    async throws
  /// Called by unmerge.
  func clearMergedResolution(meetingID: UUID, rootID: UUID) async throws
  /// Back to `unknown / kept_unknown`.
  func unlink(meetingID: UUID, speakerID: UUID, now: Int64) async throws
}

// MARK: - Coordinator

/// Diarization and meeting lifecycle events the identification scheduler reacts to.
@MainActor protocol IdentificationObserving: AnyObject {
  /// After the diarization lease finished and the adoption committed.
  func diarizationDidAdopt(meetingID: UUID)
  func meetingWillDelete(id: UUID) async
}
