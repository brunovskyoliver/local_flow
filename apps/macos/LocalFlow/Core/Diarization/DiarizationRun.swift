import Foundation

enum DiarizationRunState: String, CaseIterable, Sendable, Codable {
  case pending, running, succeeded, failed, interrupted, superseded
}

enum DiarizationTrigger: String, CaseIterable, Sendable, Codable {
  case automatic, manual, retry
  case inRoomChange = "in_room_change"
}

enum DiarizationFailureCategory: String, CaseIterable, Sendable, Codable, Error {
  case modelUnavailable = "model_unavailable"
  case osUnsupported = "os_unsupported"
  case modelLoadFailure = "model_load_failure"
  case audioMissing = "audio_missing"
  case audioDecodeFailure = "audio_decode_failure"
  case runtimeFailure = "runtime_failure"
  case transcriptChanged = "transcript_changed"
  case persistenceFailure = "persistence_failure"
  case persistenceCapacity = "persistence_capacity"
  case interrupted
}

/// FR-029: derived, never stored.
enum MeetingDiarizationState: String, CaseIterable, Sendable {
  case notRequested = "not_requested"
  case pending, running, succeeded, failed, interrupted
}

enum DiarizationRunLifecycle {
  struct InvalidTransition: Error, Equatable {
    let from: DiarizationRunState
    let to: DiarizationRunState
  }

  /// data-model.md "Run state transitions". Cancel and meeting deletion remove the
  /// row instead of transitioning; Retry admits a new run.
  static let allowed: Set<String> = [
    "pending>running", "running>succeeded", "running>failed", "pending>failed",
    "running>pending", "running>interrupted", "succeeded>superseded",
  ]

  static func transition(from: DiarizationRunState, to: DiarizationRunState) throws {
    guard allowed.contains("\(from.rawValue)>\(to.rawValue)") else {
      throw InvalidTransition(from: from, to: to)
    }
  }

  /// The current run's state when there is one; otherwise the latest run's failed or
  /// interrupted state; otherwise succeeded when a result is accepted.
  static func meetingState(
    current: DiarizationRunState?, latest: DiarizationRunState?, hasAccepted: Bool
  ) -> MeetingDiarizationState {
    if let current, let state = MeetingDiarizationState(rawValue: current.rawValue),
      current == .pending || current == .running
    {
      return state
    }
    if latest == .failed { return .failed }
    if latest == .interrupted { return .interrupted }
    return hasAccepted ? .succeeded : .notRequested
  }
}

/// Provisional until the Phase 2 measurements freeze them (T016, T044–T045). Every value
/// feeds the pipeline version so stored runs name the exact configuration.
enum DiarizationConstants {
  static let sampleRate = 16_000
  static let windowSamples = 9_600_000
  static let reconcileSimilarity = 0.70
  static let reconcileMargin = 0.10
  static let alignDominant = 0.60
  static let alignRatio = 2.0
  static let alignOverlap = 0.20
  static let carryOverlap = 0.50
  static let carryRatio = 2.0
  static let clustersPerTrack = 64
  static let turnsPerRun = 100_000
  static let writeBatch = 500
}

enum DiarizationPipelineVersion {
  static let engine = "offline_vbx_community1_nonexcl"
  static let reconciler = "xwin_cos_greedy_v1"
  static let maxBytes = 256

  static var window: String {
    "win\(DiarizationConstants.windowSamples / DiarizationConstants.sampleRate)s_v1"
  }

  static var aligner: String {
    "align_dom\(decimal(DiarizationConstants.alignDominant))"
      + "_ratio\(decimal(DiarizationConstants.alignRatio))"
      + "_ovl\(decimal(DiarizationConstants.alignOverlap))_v1"
  }

  /// e.g. `offline_vbx_community1_nonexcl+win600s_v1+xwin_cos_greedy_v1+align_dom0.60_ratio2_ovl0.20_v1`
  static var current: String {
    let value = [engine, window, reconciler, aligner].joined(separator: "+")
    precondition(value.utf8.count <= maxBytes)
    return value
  }

  /// Whole numbers print without a fraction; others with two decimals.
  static func decimal(_ value: Double) -> String {
    value == value.rounded() ? String(Int(value)) : String(format: "%.2f", value)
  }
}

struct DiarizationIdentity: Sendable, Equatable {
  let engine: String
  let modelID: String
  let modelRevision: String
  /// 64 lowercase hex characters.
  let manifestHash: String
  let pipelineVersion: String
}

struct DiarizationRun: Sendable, Equatable {
  let id: UUID
  let meetingID: UUID
  let transcriptPassID: UUID
  var state: DiarizationRunState
  let trigger: DiarizationTrigger
  let inRoom: Bool
  let identity: DiarizationIdentity
  let createdAt: Int64
  var startedAt: Int64?
  var completedAt: Int64?
  var failureCategory: DiarizationFailureCategory?
  var failureDetail: String?
  var inferredSpeakerCount = 0
  var audioMs: Int64 = 0
  var windowCount = 0
  var turnCount = 0
  var overlapTurnCount = 0
  var unknownCount = 0
  var ambiguousCount = 0
  var uncertainReconciliations = 0
  var overflowTurns = 0
  var preemptionCount = 0
}

struct MeetingDiarization: Sendable, Equatable {
  let meetingID: UUID
  var acceptedRunID: UUID?
  var currentRunID: UUID?
  var inRoom: Bool
  var updatedAt: Int64
  var revision: Int64
}

enum SpeakerReconciliation: String, Sendable, Codable { case confident, uncertain }

/// A new run cluster first seen in one window.
struct SpeakerDraft: Sendable, Equatable {
  let id: UUID
  let clusterKey: Int
  let track: MeetingTrackKind
  let reconciliation: SpeakerReconciliation
}

/// A turn on the recorded timeline. `speakerID` nil marks reconciliation overflow.
struct TurnDraft: Sendable, Equatable {
  let speakerID: UUID?
  let track: MeetingTrackKind
  let startMs: Int64
  let endMs: Int64
  let quality: Float?
}

struct SpeakerTurn: Sendable, Equatable {
  let id: Int64
  let runID: UUID
  let speakerID: UUID?
  let track: MeetingTrackKind
  let startMs: Int64
  let endMs: Int64
  let engineQuality: Double?
  let overlapped: Bool
}

struct TurnCursor: Sendable, Equatable {
  let startMs: Int64
  let id: Int64
}

enum SpeakerAssignmentKind: String, CaseIterable, Sendable, Codable {
  case speaker, unknown, ambiguous
}

struct AssignmentDraft: Sendable, Equatable {
  let segmentID: UUID
  let kind: SpeakerAssignmentKind
  let speakerID: UUID?
  let topSpeakerID: UUID?
  let secondSpeakerID: UUID?
  let topCoverage: Double
  let secondCoverage: Double
}

enum SpeakerSource: String, Sendable, Codable { case local, remote }

/// One speaker row of the accepted run, resident per meeting while the detail is open.
struct MeetingSpeaker: Sendable, Equatable, Identifiable {
  let id: UUID
  let source: SpeakerSource
  let labelOrdinal: Int
  let colorIndex: Int
  let displayName: String?
  let mergedInto: UUID?
  let inRoom: Bool

  var rootID: UUID { mergedInto ?? id }
  var label: String {
    SpeakerPalette.text(source: source, ordinal: labelOrdinal, name: displayName, inRoom: inRoom)
  }
}

/// The accepted result as the transcript tab shows it. Nil whenever the accepted run
/// was aligned against another transcript pass (Feature 006 labels apply).
struct AcceptedSpeakers: Sendable, Equatable {
  let runID: UUID
  let speakers: [MeetingSpeaker]
  /// FR-018: display roots with at least one effective `speaker` assignment.
  let count: Int
}

/// The label a transcript row shows, read with its page so it never mixes results.
struct SegmentLabel: Sendable, Equatable {
  enum Kind: Sendable, Equatable {
    case speaker(root: UUID)
    case unknown, overlapping
  }
  let kind: Kind
  let text: String
  let colorIndex: Int?
  /// FR-026: the row carries a manual correction ("Edited" marker).
  var edited: Bool = false
}

struct LabeledSegment: Sendable, Equatable {
  let segment: TranscriptSegment
  let label: SegmentLabel?
  /// The accepted run the label came from.
  var runID: UUID? = nil
}

/// One Assign speakers section: a display root of the accepted run (data-model.md
/// "Read models").
struct SpeakerSummary: Sendable, Equatable, Identifiable {
  let id: UUID
  let source: SpeakerSource
  let labelOrdinal: Int
  let colorIndex: Int
  let displayName: String?
  let inRoom: Bool
  let speechMs: Int64
  /// Up to 3, in transcript order (research R9).
  var quotes: [String] = []
  /// Speakers merged into this root ("Includes Speaker N"), in label order (FR-025).
  var includes: [MergedSpeaker] = []

  /// "You", "Local N" or "Speaker N", whatever the name.
  var anonymousLabel: String {
    SpeakerPalette.text(source: source, ordinal: labelOrdinal, name: nil, inRoom: inRoom)
  }
  /// The default local speaker, shown first and tinted in Assign speakers.
  var isYou: Bool { source == .local && !inRoom }
}

/// A speaker shown under its merge target in Assign speakers.
struct MergedSpeaker: Sendable, Equatable, Identifiable {
  let id: UUID
  let source: SpeakerSource
  let labelOrdinal: Int
  let inRoom: Bool

  var anonymousLabel: String {
    SpeakerPalette.text(source: source, ordinal: labelOrdinal, name: nil, inRoom: inRoom)
  }
}

/// A name, merge or correction that could not be carried over to a rerun (R7). Listed
/// at the top of Assign speakers until dismissed; never applied.
struct ReviewNotice: Sendable, Equatable, Identifiable {
  let id: UUID
  /// The name (or label) that did not carry over.
  let name: String

  var text: String { "Couldn't carry over: \(name)" }
}

/// FR-026: what a transcript row's speaker is changed to.
enum SegmentCorrection: Sendable, Equatable {
  case speaker(UUID)
  case unknown
  /// A manual speaker row (`run_id` NULL, `origin` manual) is created for the row.
  case newSpeaker
}

/// FR-021 name rules, shared by the sheet (inline errors) and the store (refusal).
enum SpeakerNames {
  static let maxLength = 80

  enum Invalid: Error, Equatable { case tooLong, controlCharacter }

  /// Trimmed; blank means no name. Length counts Unicode scalars, as SQLite's
  /// `length()` in the `meeting_speakers` CHECK does.
  static func validate(_ raw: String) -> Result<String?, Invalid> {
    let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if name.isEmpty { return .success(nil) }
    if name.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) {
      return .failure(.controlCharacter)
    }
    if name.unicodeScalars.count > maxLength { return .failure(.tooLong) }
    return .success(name)
  }
}
