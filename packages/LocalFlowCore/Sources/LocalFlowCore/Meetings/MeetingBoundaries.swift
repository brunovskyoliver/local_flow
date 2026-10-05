import AVFoundation
import Darwin
import Foundation
import LocalFlowSpeech

/// Boundary protocols for Feature 004. Every production implementation has a
/// test double in `LocalFlowTests/Support/MeetingFakes.swift`; the capacities
/// and policies are normative in `contracts/meeting-capture.md`.

// MARK: - Clock

public protocol MeetingClock: Sendable {
  /// Unix milliseconds.
  var nowMilliseconds: Int64 { get }
  /// `CLOCK_MONOTONIC_RAW`, for `host_start_ns` and durations.
  var monotonicNanoseconds: UInt64 { get }
  func sleep(for duration: Duration) async throws
}

public struct SystemMeetingClock: MeetingClock {
  public init() {}
  public var nowMilliseconds: Int64 { Int64(Date().timeIntervalSince1970 * 1_000) }
  public var monotonicNanoseconds: UInt64 { clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW) }
  public func sleep(for duration: Duration) async throws {
    try await ContinuousClock().sleep(for: duration)
  }
}

// MARK: - Sources

public struct MeetingSourceFormat: Sendable, Equatable {
  public let sampleRate: Double
  /// 1…8, the ring's channel count. The encoder downmixes per track kind.
  public let channels: Int

  public init(sampleRate: Double, channels: Int) {
    self.sampleRate = sampleRate
    self.channels = channels
  }
}

// MARK: - Encoder and writer

/// A 7-byte ADTS header followed by one raw AAC-LC packet.
public struct ADTSFrame: Sendable, Equatable {
  public static let headerLength = 7
  public static let samplesPerFrame = 1_024
  public static let maximumPayloadBytes = 1_536
  public static let samplingIndex48k: UInt8 = 3
  public let bytes: [UInt8]

  public init(payload: UnsafeRawBufferPointer, channels: Int) {
    var bytes = ADTSFrame.header(payloadLength: payload.count, channels: channels)
    bytes.append(contentsOf: payload)
    self.bytes = bytes
  }

  public init(bytes: [UInt8]) { self.bytes = bytes }

  /// MPEG-4, AAC-LC, 48 kHz, no CRC, one raw data block.
  public static func header(payloadLength: Int, channels: Int) -> [UInt8] {
    let length = headerLength + payloadLength
    let profile: UInt8 = 1  // AAC-LC object type 2, stored as (type - 1)
    return [
      0xFF, 0xF1,
      (profile << 6) | (samplingIndex48k << 2) | UInt8((channels >> 2) & 1),
      UInt8((channels & 3) << 6) | UInt8((length >> 11) & 3),
      UInt8((length >> 3) & 0xFF),
      UInt8((length & 7) << 5) | 0x1F,
      0xFC,
    ]
  }
}

/// Every error carries an errno or a converter status code; never a path.
public enum MeetingCaptureFailure: Error, Equatable, Sendable {
  case open(errno: Int32)
  case write(errno: Int32)
  case sync(errno: Int32)
  case finalize(errno: Int32)
  case invalidPath
  case alreadyExists
  case encoder(code: Int32)
  case closed

  public var reason: MeetingFailureReason {
    switch self {
    case .write, .sync, .finalize, .closed: .storageWriteFailed
    case .open, .invalidPath, .alreadyExists: .storageUnavailable
    case .encoder: .encoderFailed
    }
  }
}

public protocol MeetingEncoding: AnyObject, Sendable {
  /// At most 8 frames per call. Pass nil to drain output the converter still holds.
  func encode(block: AVAudioPCMBuffer?) throws -> [ADTSFrame]
  /// Drains the converter; may be called once.
  func finish() throws -> [ADTSFrame]
  /// Frames encoded so far; `× 1,024 ÷ 48,000` is the segment duration source of truth.
  var encodedFrameCount: Int { get }
  var channels: Int { get }
}

public struct SegmentHandle: Sendable, Hashable {
  public let id: UUID
  public let meetingID: UUID
  public let kind: MeetingTrackKind
  public let sequence: Int
  /// `<meeting>/<type>-<seq>.aac.part`, relative to the storage root.
  public let relativePath: String

  public init(
    id: UUID, meetingID: UUID, kind: MeetingTrackKind, sequence: Int, relativePath: String
  ) {
    self.id = id
    self.meetingID = meetingID
    self.kind = kind
    self.sequence = sequence
    self.relativePath = relativePath
  }

  public var finalRelativePath: String { String(relativePath.dropLast(".part".count)) }

  public static func relativePath(
    meetingID: UUID, kind: MeetingTrackKind, sequence: Int, open: Bool
  )
    -> String
  {
    let name = "\(kind.filePrefix)-" + String(format: "%04d", sequence) + ".aac"
    return meetingID.uuidString + "/" + name + (open ? ".part" : "")
  }
}

public protocol SegmentWriting: Sendable {
  /// Creates `<root>/<meeting>/<type>-<seq>.aac.part` exclusively (O_CREAT|O_EXCL, 0600).
  func open(meetingID: UUID, kind: MeetingTrackKind, sequence: Int) throws -> SegmentHandle
  /// write(2) loop; a partial write is completed or the call throws.
  func append(_ handle: SegmentHandle, frames: [ADTSFrame]) throws
  func sync(_ handle: SegmentHandle) throws
  /// fsync, close, rename to `.aac`, fsync the directory. Returns the final byte size.
  func finalize(_ handle: SegmentHandle) throws -> Int
  /// Close without rename; used by recovery paths and tests.
  func abandon(_ handle: SegmentHandle)
  /// Close and remove the file; used when a start fails before any audio was written.
  func discard(_ handle: SegmentHandle)
  func freeSpace(at root: URL) throws -> Int64
}

// MARK: - Store

/// Side effects applied inside the same write transaction as a state change.
public enum MeetingTransitionEffect: Sendable, Equatable {
  case insertTracks([MeetingTrack])
  case insertTranscription(liveRequested: Bool)
  case setStartedAt(Int64)
  case setStoppedAt(Int64)
  case setCompletedAt(Int64)
  case failure(MeetingFailureReason, detail: String?)
  case finalizationStage(FinalizationStage)
  case openSegment(MeetingSegment)
  case finalizeSegment(
    id: UUID, durationMs: Int64, byteSize: Int64, relativePath: String,
    closeReason: SegmentCloseReason, droppedFrames: Int64)
  case markSegmentUnrecoverable(id: UUID, reason: MeetingFailureReason, note: String?)
  case markTrackFailed(id: UUID, reason: MeetingFailureReason, at: Int64)
  case markTrackFinalized(id: UUID)
  case openPause(PauseInterval)
  case closeOpenPause(at: Int64, closedBy: PauseClosedBy)
  /// Compare each track's total duration with `recorded_ms` (max(1%, 2 s) rule).
  case computeDurationWarnings
  #if DEBUG
    /// Throws after the state row was updated so tests can prove nothing leaks.
    case injectedFailure
  #endif
}

public struct MeetingCursor: Sendable, Equatable {
  public let createdAt: Int64
  public let id: UUID

  public init(createdAt: Int64, id: UUID) {
    self.createdAt = createdAt
    self.id = id
  }
}

public struct DeletionOutcome: Sendable, Equatable {
  /// Relative paths that could not be removed; the row is kept while non-empty.
  public let remainingPaths: [String]
  public let rowDeleted: Bool

  public init(remainingPaths: [String], rowDeleted: Bool) {
    self.remainingPaths = remainingPaths
    self.rowDeleted = rowDeleted
  }
  public var complete: Bool { rowDeleted && remainingPaths.isEmpty }
}

public protocol MeetingStoring: Sendable {
  func activeMeeting() async throws -> Meeting?
  func meeting(id: UUID) async throws -> Meeting?
  func create(now: Int64) async throws -> Meeting
  @discardableResult
  func transition(id: UUID, to: MeetingState, now: Int64, effects: [MeetingTransitionEffect])
    async throws -> Meeting
  func openSegment(_ segment: MeetingSegment, now: Int64) async throws -> MeetingSegment
  func progressSegment(
    id: UUID, durationMs: Int64, byteSize: Int64, droppedFrames: Int64, now: Int64)
    async throws
  func finalizeSegment(
    id: UUID, durationMs: Int64, byteSize: Int64, relativePath: String,
    closeReason: SegmentCloseReason, droppedFrames: Int64, now: Int64) async throws
  func markSegmentUnrecoverable(id: UUID, reason: MeetingFailureReason, note: String?, now: Int64)
    async throws
  func markTrackFailed(id: UUID, reason: MeetingFailureReason, at: Int64) async throws
  func markTrackFinalized(id: UUID, now: Int64) async throws
  func openPause(meetingID: UUID, reason: PauseReason, at: Int64) async throws -> PauseInterval
  func closePause(id: UUID, at: Int64, closedBy: PauseClosedBy) async throws
  func saveNotes(meetingID: UUID, text: String, revision: Int64, now: Int64) async throws -> Int64
  func setTitle(meetingID: UUID, title: String?, revision: Int64, now: Int64) async throws -> Int64
  func setLanguage(meetingID: UUID, language: MeetingLanguage?, revision: Int64, now: Int64)
    async throws -> Int64
  func notes(meetingID: UUID) async throws -> MeetingNotes?
  func setFinalizationStage(meetingID: UUID, stage: FinalizationStage, now: Int64) async throws
  func page(before: MeetingCursor?, limit: Int) async throws -> [MeetingSummary]
  func detail(id: UUID) async throws -> MeetingDetail?
  func activeStateRows() async throws -> [Meeting]
  func recordOutcome(_ outcome: RecoveryOutcome) async throws
  func deleteConfirmed(id: UUID, revision: Int64) async throws -> DeletionOutcome
}

public struct MeetingStartOptions: Sendable, Equatable {
  public var transcription: Bool
  public init(transcription: Bool = true) {
    self.transcription = transcription
  }
}
