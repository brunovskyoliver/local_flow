import Foundation

/// Value types for the six `meetings-v5` tables plus the published status.
/// Timestamps are Unix milliseconds unless the name ends in `Ns`.

enum MeetingTrackKind: String, CaseIterable, Sendable, Codable {
  case microphone, system

  /// File-name prefix; titles never appear in file names (FR-023).
  var filePrefix: String {
    switch self {
    case .microphone: "mic"
    case .system: "system"
    }
  }
  var displayName: String {
    switch self {
    case .microphone: "Microphone"
    case .system: "System audio"
    }
  }
  var bitrate: Int {
    switch self {
    case .microphone: 64_000
    case .system: 96_000
    }
  }
  /// Encoded channel count for a source with `sourceChannels` channels.
  func encodedChannels(sourceChannels: Int) -> Int {
    switch self {
    case .microphone: 1
    case .system: max(1, min(sourceChannels, 2))
    }
  }
  static let codec = "aac_lc"
  static let container = "adts"
  static let sampleRate = 48_000
}

enum TrackHealth: String, Sendable, Codable { case healthy, failed, finalized, unrecoverable }
enum SegmentState: String, Sendable, Codable { case open, finalized, unrecoverable }
enum SegmentOpenReason: String, Sendable, Codable {
  case start, resume
  case deviceChanged = "device_changed"
}
enum SegmentCloseReason: String, Sendable, Codable {
  case pause, stop, recovered
  case systemSleep = "system_sleep"
  case sourceFailed = "source_failed"
  case storageFailed = "storage_failed"
  case deviceChanged = "device_changed"
}
enum PauseReason: String, Sendable, Codable {
  case user
  case systemSleep = "system_sleep"
}
enum PauseClosedBy: String, Sendable, Codable { case resume, stop, reconciliation }
enum FinalizationStage: String, Sendable, Codable { case none, mic, system, both }

struct Meeting: Sendable, Equatable, Identifiable {
  static let maximumTitleBytes = 256
  static let maximumDetailBytes = 512
  let id: UUID
  var state: MeetingState
  var title: String?
  let createdAt: Int64
  var startedAt: Int64?
  var stoppedAt: Int64?
  var completedAt: Int64?
  var wallClockMs: Int64
  var recordedMs: Int64
  var finalizationStage: FinalizationStage?
  var failureReason: MeetingFailureReason?
  var failureDetail: String?
  var updatedAt: Int64
  var revision: Int64

  var displayTitle: String { title ?? fallbackTitle(createdAt: createdAt) }
}

struct MeetingTrack: Sendable, Equatable, Identifiable {
  let id: UUID
  let meetingID: UUID
  let kind: MeetingTrackKind
  var codec = MeetingTrackKind.codec
  var container = MeetingTrackKind.container
  var sampleRate = MeetingTrackKind.sampleRate
  var channelCount: Int
  var bitrate: Int
  var health: TrackHealth = .healthy
  var failureReason: MeetingFailureReason?
  var failedAt: Int64?
  var totalDurationMs: Int64 = 0
  var totalBytes: Int64 = 0
  var durationWarning = false
  var droppedFrames: Int64 = 0
}

struct MeetingSegment: Sendable, Equatable, Identifiable {
  static let maximumPathBytes = 255
  static let maximumNoteBytes = 512
  let id: UUID
  let trackID: UUID
  let sequence: Int
  var relativePath: String
  var state: SegmentState = .open
  var startOffsetMs: Int64
  var durationMs: Int64 = 0
  var byteSize: Int64 = 0
  let startedAt: Int64
  let hostStartNs: Int64
  let openReason: SegmentOpenReason
  var closeReason: SegmentCloseReason?
  var droppedFrames: Int64 = 0
  var recoveryNote: String?
  var failureReason: MeetingFailureReason?

  var isPartFile: Bool { relativePath.hasSuffix(".part") }
}

struct PauseInterval: Sendable, Equatable, Identifiable {
  let id: UUID
  let meetingID: UUID
  let startedAt: Int64
  var endedAt: Int64?
  let reason: PauseReason
  var closedBy: PauseClosedBy?
}

struct MeetingNotes: Sendable, Equatable {
  static let maximumBytes = 1_048_576
  static let author = "user"
  let meetingID: UUID
  var text: String
  var updatedAt: Int64
  var revision: Int64
}

struct RecoveryOutcome: Sendable, Equatable, Identifiable {
  static let maximumSummaryBytes = 512
  var id = UUID()
  let meetingID: UUID
  let ranAt: Int64
  let foundState: MeetingState
  let foundStage: FinalizationStage?
  var segmentsRecovered = 0
  var segmentsUnrecoverable = 0
  var segmentsMissing = 0
  var pauseClosed = false
  var bytesTruncated: Int64 = 0
  var summary: String
}

/// One library row. Enough to render the list without loading the detail.
struct MeetingSummary: Sendable, Equatable, Identifiable {
  let id: UUID
  let title: String?
  let createdAt: Int64
  let state: MeetingState
  let recordedMs: Int64
  /// Any track is `failed` or `unrecoverable`.
  let hasTrackWarning: Bool
  let revision: Int64

  var displayTitle: String { title ?? fallbackTitle(createdAt: createdAt) }
}

struct MeetingTrackDetail: Sendable, Equatable, Identifiable {
  var id: UUID { track.id }
  let track: MeetingTrack
  let segments: [MeetingSegment]
}

struct MeetingDetail: Sendable, Equatable {
  let meeting: Meeting
  let tracks: [MeetingTrackDetail]
  let pauses: [PauseInterval]
  let notes: MeetingNotes
  let outcomes: [RecoveryOutcome]

  func track(_ kind: MeetingTrackKind) -> MeetingTrackDetail? {
    tracks.first { $0.track.kind == kind }
  }
}

/// Published per-track state; a track whose capture or storage failed is never `capturing`.
enum TrackStatus: Sendable, Equatable {
  case notStarted, capturing, finalized
  case failed(MeetingFailureReason, at: Int64)

  var isCapturing: Bool { self == .capturing }
}

/// The one observable value `MeetingCoordinator` exposes (FR-006).
struct MeetingStatus: Sendable, Equatable {
  let id: UUID
  var title: String?
  var state: MeetingState
  var recordedElapsed: Duration = .zero
  var microphone: TrackStatus = .notStarted
  var system: TrackStatus = .notStarted
  var pauseReason: PauseReason?
  var storageWarning: String?
  var droppedFrames: Int64 = 0
  var notice: String?
  let createdAt: Int64

  var displayTitle: String { title ?? fallbackTitle(createdAt: createdAt) }
  func track(_ kind: MeetingTrackKind) -> TrackStatus {
    switch kind {
    case .microphone: microphone
    case .system: system
    }
  }
}

/// Derived, never stored: "Meeting " + local short date and time of `created_at`.
func fallbackTitle(createdAt: Int64, timeZone: TimeZone = .autoupdatingCurrent) -> String {
  let formatter = DateFormatter()
  formatter.dateStyle = .short
  formatter.timeStyle = .short
  formatter.timeZone = timeZone
  return "Meeting " + formatter.string(from: Date(timeIntervalSince1970: Double(createdAt) / 1_000))
}

/// Content-free duration text for lists and cards.
func meetingDurationText(_ milliseconds: Int64) -> String {
  let seconds = max(0, milliseconds) / 1_000
  let hours = seconds / 3_600
  let minutes = (seconds % 3_600) / 60
  let remainder = seconds % 60
  return hours > 0
    ? String(format: "%d:%02d:%02d", hours, minutes, remainder)
    : String(format: "%d:%02d", minutes, remainder)
}

/// Outcome kinds a launch reconciliation records per meeting; also the only
/// `meetingRecoveryOutcome` metric key values.
enum MeetingRecoveryOutcomeKind: String, CaseIterable, Sendable {
  case recovered, unrecoverable, orphan, failed, deferred
}
