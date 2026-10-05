import Foundation
import LocalFlowSpeech

/// Value types for the six `meetings-v5` tables plus the published status.
/// Timestamps are Unix milliseconds unless the name ends in `Ns`.

public enum MeetingTrackKind: String, CaseIterable, Sendable, Codable {
  case microphone, system

  /// File-name prefix; titles never appear in file names (FR-023).
  public var filePrefix: String {
    switch self {
    case .microphone: "mic"
    case .system: "system"
    }
  }
  public var displayName: String {
    switch self {
    case .microphone: "Microphone"
    case .system: "System audio"
    }
  }
  public var bitrate: Int {
    switch self {
    case .microphone: 64_000
    case .system: 96_000
    }
  }
  /// Encoded channel count for a source with `sourceChannels` channels.
  public func encodedChannels(sourceChannels: Int) -> Int {
    switch self {
    case .microphone: 1
    case .system: max(1, min(sourceChannels, 2))
    }
  }
  public static let codec = "aac_lc"
  public static let container = "adts"
  public static let sampleRate = 48_000
}

public enum TrackHealth: String, Sendable, Codable {
  case healthy, failed, finalized, unrecoverable
}
public enum SegmentState: String, Sendable, Codable { case open, finalized, unrecoverable }
public enum SegmentOpenReason: String, Sendable, Codable {
  /// `rotated`: Feature 020, the phone cuts a segment every 360 s (`phone-meetings-v19`).
  case start, resume, rotated
  case deviceChanged = "device_changed"
}
public enum SegmentCloseReason: String, Sendable, Codable {
  case pause, stop, recovered, rotated
  case systemSleep = "system_sleep"
  case sourceFailed = "source_failed"
  case storageFailed = "storage_failed"
  case deviceChanged = "device_changed"
}
public enum PauseReason: String, Sendable, Codable {
  case user
  case systemSleep = "system_sleep"
}
/// Feature 020: who recorded the meeting (`meetings.origin`, `phone-meetings-v19`).
public enum MeetingOrigin: String, Sendable, Codable { case local, iphone }
public enum PauseClosedBy: String, Sendable, Codable { case resume, stop, reconciliation }
public enum FinalizationStage: String, Sendable, Codable { case none, mic, system, both }

public struct Meeting: Sendable, Equatable, Identifiable {
  public static let maximumTitleBytes = 256
  public static let maximumDetailBytes = 512
  public let id: UUID
  public var state: MeetingState
  public var title: String?
  public let createdAt: Int64
  public var startedAt: Int64?
  public var stoppedAt: Int64?
  public var completedAt: Int64?
  public var wallClockMs: Int64
  public var recordedMs: Int64
  public var finalizationStage: FinalizationStage?
  public var failureReason: MeetingFailureReason?
  public var failureDetail: String?
  public var updatedAt: Int64
  public var revision: Int64
  /// The language the final transcript is decoded in; nil is the Settings default.
  public var language: MeetingLanguage?
  /// Feature 018: **Run on this Mac** — the meeting's remaining work stays local.
  public var runLocally = false
  /// IANA name of the zone the meeting is analyzed in — the capture zone;
  /// not persisted, defaults to the current zone.
  public var timeZone: String = TimeZone.current.identifier

  public init(
    id: UUID, state: MeetingState, title: String? = nil, createdAt: Int64, startedAt: Int64? = nil,
    stoppedAt: Int64? = nil, completedAt: Int64? = nil, wallClockMs: Int64, recordedMs: Int64,
    finalizationStage: FinalizationStage? = nil, failureReason: MeetingFailureReason? = nil,
    failureDetail: String? = nil, updatedAt: Int64, revision: Int64,
    language: MeetingLanguage? = nil, runLocally: Bool = false,
    timeZone: String = TimeZone.current.identifier
  ) {
    self.id = id
    self.state = state
    self.title = title
    self.createdAt = createdAt
    self.startedAt = startedAt
    self.stoppedAt = stoppedAt
    self.completedAt = completedAt
    self.wallClockMs = wallClockMs
    self.recordedMs = recordedMs
    self.finalizationStage = finalizationStage
    self.failureReason = failureReason
    self.failureDetail = failureDetail
    self.updatedAt = updatedAt
    self.revision = revision
    self.language = language
    self.runLocally = runLocally
    self.timeZone = timeZone
  }

  public var displayTitle: String { title ?? fallbackTitle(createdAt: createdAt) }
}

/// Feature 018: the stored `inference_path` of a meeting's results.
public struct MeetingProvenance: Sendable, Equatable {
  public var transcript: String?
  public var speakers: String?
  public var summary: String?

  public init(transcript: String? = nil, speakers: String? = nil, summary: String? = nil) {
    self.transcript = transcript
    self.speakers = speakers
    self.summary = summary
  }

  /// "Transcript: your server · Speaker labels: this Mac", or nil when nothing is done.
  public var text: String? {
    let parts = [("Transcript", transcript), ("Speaker labels", speakers), ("Summary", summary)]
      .compactMap { name, path in path.map { "\(name): \(Self.place($0))" } }
    return parts.isEmpty ? nil : parts.joined(separator: " · ")
  }

  public static func place(_ path: String) -> String {
    switch path {
    case "server": "your server"
    case "custom": "your custom server"
    case "local_after_server_failure": "this Mac (server unavailable)"
    default: "this Mac"
    }
  }
}

public struct MeetingTrack: Sendable, Equatable, Identifiable {
  public let id: UUID
  public let meetingID: UUID
  public let kind: MeetingTrackKind
  public var codec = MeetingTrackKind.codec
  public var container = MeetingTrackKind.container
  public var sampleRate = MeetingTrackKind.sampleRate
  public var channelCount: Int
  public var bitrate: Int
  public var health: TrackHealth = .healthy
  public var failureReason: MeetingFailureReason?
  public var failedAt: Int64?
  public var totalDurationMs: Int64 = 0
  public var totalBytes: Int64 = 0
  public var durationWarning = false
  public var droppedFrames: Int64 = 0

  public init(
    id: UUID, meetingID: UUID, kind: MeetingTrackKind, codec: String = MeetingTrackKind.codec,
    container: String = MeetingTrackKind.container, sampleRate: Int = MeetingTrackKind.sampleRate,
    channelCount: Int, bitrate: Int, health: TrackHealth = .healthy,
    failureReason: MeetingFailureReason? = nil, failedAt: Int64? = nil, totalDurationMs: Int64 = 0,
    totalBytes: Int64 = 0, durationWarning: Bool = false, droppedFrames: Int64 = 0
  ) {
    self.id = id
    self.meetingID = meetingID
    self.kind = kind
    self.codec = codec
    self.container = container
    self.sampleRate = sampleRate
    self.channelCount = channelCount
    self.bitrate = bitrate
    self.health = health
    self.failureReason = failureReason
    self.failedAt = failedAt
    self.totalDurationMs = totalDurationMs
    self.totalBytes = totalBytes
    self.durationWarning = durationWarning
    self.droppedFrames = droppedFrames
  }
}

public struct MeetingSegment: Sendable, Equatable, Identifiable {
  public static let maximumPathBytes = 255
  public static let maximumNoteBytes = 512
  public let id: UUID
  public let trackID: UUID
  public let sequence: Int
  public var relativePath: String
  public var state: SegmentState = .open
  public var startOffsetMs: Int64
  public var durationMs: Int64 = 0
  public var byteSize: Int64 = 0
  public let startedAt: Int64
  public let hostStartNs: Int64
  public let openReason: SegmentOpenReason
  public var closeReason: SegmentCloseReason?
  public var droppedFrames: Int64 = 0
  public var recoveryNote: String?
  public var failureReason: MeetingFailureReason?
  /// Feature 019: the microphone this microphone-track segment recorded from; nil for
  /// system audio and for segments from before `input-device-v18`.
  public var inputDeviceName: String? = nil

  public init(
    id: UUID, trackID: UUID, sequence: Int, relativePath: String, state: SegmentState = .open,
    startOffsetMs: Int64, durationMs: Int64 = 0, byteSize: Int64 = 0, startedAt: Int64,
    hostStartNs: Int64, openReason: SegmentOpenReason, closeReason: SegmentCloseReason? = nil,
    droppedFrames: Int64 = 0, recoveryNote: String? = nil,
    failureReason: MeetingFailureReason? = nil, inputDeviceName: String? = nil
  ) {
    self.id = id
    self.trackID = trackID
    self.sequence = sequence
    self.relativePath = relativePath
    self.state = state
    self.startOffsetMs = startOffsetMs
    self.durationMs = durationMs
    self.byteSize = byteSize
    self.startedAt = startedAt
    self.hostStartNs = hostStartNs
    self.openReason = openReason
    self.closeReason = closeReason
    self.droppedFrames = droppedFrames
    self.recoveryNote = recoveryNote
    self.failureReason = failureReason
    self.inputDeviceName = inputDeviceName
  }

  public var isPartFile: Bool { relativePath.hasSuffix(".part") }
}

public struct PauseInterval: Sendable, Equatable, Identifiable {
  public let id: UUID
  public let meetingID: UUID
  public let startedAt: Int64
  public var endedAt: Int64?
  public let reason: PauseReason
  public var closedBy: PauseClosedBy?

  public init(
    id: UUID, meetingID: UUID, startedAt: Int64, endedAt: Int64? = nil, reason: PauseReason,
    closedBy: PauseClosedBy? = nil
  ) {
    self.id = id
    self.meetingID = meetingID
    self.startedAt = startedAt
    self.endedAt = endedAt
    self.reason = reason
    self.closedBy = closedBy
  }
}

public struct MeetingNotes: Sendable, Equatable {
  public static let maximumBytes = 1_048_576
  public static let author = "user"
  public let meetingID: UUID
  public var text: String
  public var updatedAt: Int64
  public var revision: Int64

  public init(meetingID: UUID, text: String, updatedAt: Int64, revision: Int64) {
    self.meetingID = meetingID
    self.text = text
    self.updatedAt = updatedAt
    self.revision = revision
  }
}

public struct RecoveryOutcome: Sendable, Equatable, Identifiable {
  public static let maximumSummaryBytes = 512
  public var id = UUID()
  public let meetingID: UUID
  public let ranAt: Int64
  public let foundState: MeetingState
  public let foundStage: FinalizationStage?
  public var segmentsRecovered = 0
  public var segmentsUnrecoverable = 0
  public var segmentsMissing = 0
  public var pauseClosed = false
  public var bytesTruncated: Int64 = 0
  public var summary: String

  public init(
    id: UUID = UUID(), meetingID: UUID, ranAt: Int64, foundState: MeetingState,
    foundStage: FinalizationStage?, segmentsRecovered: Int = 0, segmentsUnrecoverable: Int = 0,
    segmentsMissing: Int = 0, pauseClosed: Bool = false, bytesTruncated: Int64 = 0, summary: String
  ) {
    self.id = id
    self.meetingID = meetingID
    self.ranAt = ranAt
    self.foundState = foundState
    self.foundStage = foundStage
    self.segmentsRecovered = segmentsRecovered
    self.segmentsUnrecoverable = segmentsUnrecoverable
    self.segmentsMissing = segmentsMissing
    self.pauseClosed = pauseClosed
    self.bytesTruncated = bytesTruncated
    self.summary = summary
  }
}

/// One library row. Enough to render the list without loading the detail.
public struct MeetingSummary: Sendable, Equatable, Identifiable {
  public let id: UUID
  public let title: String?
  public let createdAt: Int64
  public let state: MeetingState
  public let recordedMs: Int64
  /// Any track is `failed` or `unrecoverable`.
  public let hasTrackWarning: Bool
  public let revision: Int64
  /// Feature 005: the transcription row's state, nil for meetings without one.
  public var transcriptState: TranscriptState? = nil

  public init(
    id: UUID, title: String?, createdAt: Int64, state: MeetingState, recordedMs: Int64,
    hasTrackWarning: Bool, revision: Int64, transcriptState: TranscriptState? = nil
  ) {
    self.id = id
    self.title = title
    self.createdAt = createdAt
    self.state = state
    self.recordedMs = recordedMs
    self.hasTrackWarning = hasTrackWarning
    self.revision = revision
    self.transcriptState = transcriptState
  }

  public var displayTitle: String { title ?? fallbackTitle(createdAt: createdAt) }
}

public struct MeetingTrackDetail: Sendable, Equatable, Identifiable {
  public var id: UUID { track.id }
  public let track: MeetingTrack
  public let segments: [MeetingSegment]

  public init(track: MeetingTrack, segments: [MeetingSegment]) {
    self.track = track
    self.segments = segments
  }
}

public struct MeetingDetail: Sendable, Equatable {
  public let meeting: Meeting
  public let tracks: [MeetingTrackDetail]
  public let pauses: [PauseInterval]
  public let notes: MeetingNotes
  public let outcomes: [RecoveryOutcome]

  public init(
    meeting: Meeting, tracks: [MeetingTrackDetail], pauses: [PauseInterval], notes: MeetingNotes,
    outcomes: [RecoveryOutcome]
  ) {
    self.meeting = meeting
    self.tracks = tracks
    self.pauses = pauses
    self.notes = notes
    self.outcomes = outcomes
  }

  public func track(_ kind: MeetingTrackKind) -> MeetingTrackDetail? {
    tracks.first { $0.track.kind == kind }
  }
}

/// Published per-track state; a track whose capture or storage failed is never `capturing`.
public enum TrackStatus: Sendable, Equatable {
  case notStarted, capturing, finalized
  case failed(MeetingFailureReason, at: Int64)

  public var isCapturing: Bool { self == .capturing }
}

/// The one observable value `MeetingCoordinator` exposes (FR-006).
public struct MeetingStatus: Sendable, Equatable {
  public let id: UUID
  public var title: String?
  public var state: MeetingState
  public var transcriptionRequested: Bool = false
  public var microphone: TrackStatus = .notStarted
  public var system: TrackStatus = .notStarted
  public var pauseReason: PauseReason?
  public var storageWarning: String?
  public var droppedFrames: Int64 = 0
  public var notice: String?
  public let createdAt: Int64
  /// Per-meeting transcript language; nil is the Settings default.
  public var language: MeetingLanguage?

  public init(
    id: UUID, title: String? = nil, state: MeetingState, transcriptionRequested: Bool = false,
    microphone: TrackStatus = .notStarted, system: TrackStatus = .notStarted,
    pauseReason: PauseReason? = nil, storageWarning: String? = nil, droppedFrames: Int64 = 0,
    notice: String? = nil, createdAt: Int64, language: MeetingLanguage? = nil
  ) {
    self.id = id
    self.title = title
    self.state = state
    self.transcriptionRequested = transcriptionRequested
    self.microphone = microphone
    self.system = system
    self.pauseReason = pauseReason
    self.storageWarning = storageWarning
    self.droppedFrames = droppedFrames
    self.notice = notice
    self.createdAt = createdAt
    self.language = language
  }

  public var displayTitle: String { title ?? fallbackTitle(createdAt: createdAt) }
  public func track(_ kind: MeetingTrackKind) -> TrackStatus {
    switch kind {
    case .microphone: microphone
    case .system: system
    }
  }
}

/// Dates the app shows or sends to the server are English whatever the system
/// locale: the interface is English and summaries are English or Slovak, so a
/// system date in another language must not leak into either. Fixed patterns
/// under `en_US_POSIX` read the same on every system ("24 Sep 2026, 14:05").
public enum EnglishDateFormat {
  public static let locale = Locale(identifier: "en_US_POSIX")
  /// "24 Sep 2026, 14:05": meeting titles and row dates.
  public static let dateTimePattern = "d MMM yyyy, HH:mm"
  /// Cached for the current time zone; formatting a configured DateFormatter is
  /// thread-safe.
  public static let dateTime = formatter(dateTimePattern)

  public static func formatter(
    _ pattern: String, timeZone: TimeZone = .autoupdatingCurrent,
    calendar: Calendar = Calendar(identifier: .gregorian)
  ) -> DateFormatter {
    let formatter = DateFormatter()
    formatter.locale = locale
    formatter.calendar = calendar
    formatter.timeZone = timeZone
    formatter.dateFormat = pattern
    return formatter
  }
}

/// Derived, never stored: "Meeting " + English date and time of `created_at` in
/// the local time zone. Sent as the meeting title when the meeting has none.
public func fallbackTitle(createdAt: Int64, timeZone: TimeZone = .autoupdatingCurrent) -> String {
  let formatter =
    timeZone == .autoupdatingCurrent
    ? EnglishDateFormat.dateTime
    : EnglishDateFormat.formatter(EnglishDateFormat.dateTimePattern, timeZone: timeZone)
  return "Meeting " + formatter.string(from: Date(timeIntervalSince1970: Double(createdAt) / 1_000))
}

/// Content-free duration text for lists and cards.
public func meetingDurationText(_ milliseconds: Int64) -> String {
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
public enum MeetingRecoveryOutcomeKind: String, CaseIterable, Sendable {
  case recovered, unrecoverable, orphan, failed, deferred
}
