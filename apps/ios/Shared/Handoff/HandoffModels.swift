import Foundation

/// Feature 016 keyboard ↔ app handoff, version 1 (`contracts/keyboard-handoff.md`).
/// Foundation only: compiled into the app and the keyboard.
enum Handoff {
  static let version = 1
  /// Results older than this are never offered and are deleted by the app.
  static let resultLifetime: Int64 = 10 * 60 * 1000
  /// The app ignores requests older than this.
  static let requestLifetime: Int64 = 10 * 1000

  static func milliseconds(_ date: Date) -> Int64 { Int64(date.timeIntervalSince1970 * 1000) }
}

protocol HandoffFile: Codable, Sendable {
  var v: Int { get }
}

struct SessionFile: HandoffFile, Equatable {
  enum State: String, Codable, Sendable { case starting, ready, recording, finishing, ended }
  enum EndReason: String, Codable, Sendable {
    case idleTimeout, afterOneDictation, userEnded, interrupted, audioFailure, modelUnavailable
    case permissionDenied
  }
  enum Outcome: String, Codable, Sendable {
    case empty, busy, failed
    case noSession = "no_session"
  }
  /// Who started the dictation in progress (Feature 017).
  enum Source: String, Codable, Sendable { case keyboard, app, control }

  var v = Handoff.version
  var sessionID: UUID
  var state: State
  var idleDeadline: Int64?
  /// `IdleTimeout.rawValue`: `afterOne`, `5m`, `15m`, `1h` or `never` (017).
  var idleTimeout: String
  var dictationID: UUID?
  var endReason: EndReason?
  var lastRequestID: UUID?
  var lastOutcome: Outcome?
  var updatedAt: Int64
  // Feature 017, optional so 016 files still decode (contracts/keyboard-handoff-v1-additions.md).
  /// While `recording` only.
  var recordingStartedAt: Int64?
  /// The input port name, while `recording` only.
  var inputName: String?
  /// While `recording` or `finishing`.
  var dictationSource: Source?

  enum CodingKeys: String, CodingKey {
    case v, state
    case sessionID = "session_id"
    case idleDeadline = "idle_deadline"
    case idleTimeout = "idle_timeout"
    case dictationID = "dictation_id"
    case endReason = "end_reason"
    case lastRequestID = "last_request_id"
    case lastOutcome = "last_outcome"
    case updatedAt = "updated_at"
    case recordingStartedAt = "recording_started_at"
    case inputName = "input_name"
    case dictationSource = "dictation_source"
  }
}

struct RequestFile: HandoffFile, Equatable {
  /// `end` ends the session (017).
  enum Kind: String, Codable, Sendable { case start, stop, cancel, end }

  var v = Handoff.version
  /// For `stop` and `cancel`, the ID of the `start` it ends.
  var requestID: UUID
  var kind: Kind
  var sessionID: UUID
  var createdAt: Int64

  enum CodingKeys: String, CodingKey {
    case v, kind
    case requestID = "request_id"
    case sessionID = "session_id"
    case createdAt = "created_at"
  }
}

struct ResultFile: HandoffFile, Equatable {
  var v = Handoff.version
  var requestID: UUID
  var dictationID: UUID
  /// Always `text`: requests without text are reported in `session.json`.
  var outcome = "text"
  var text: String
  var limitReached: Bool
  var createdAt: Int64

  enum CodingKeys: String, CodingKey {
    case v, outcome, text
    case requestID = "request_id"
    case dictationID = "dictation_id"
    case limitReached = "limit_reached"
    case createdAt = "created_at"
  }

  func expired(now: Int64) -> Bool { now - createdAt >= Handoff.resultLifetime }
}

struct DeliveryFile: HandoffFile, Equatable {
  enum Delivery: String, Codable, Sendable { case inserted, offered }

  var v = Handoff.version
  var dictationID: UUID
  var delivery: Delivery
  var at: Int64

  enum CodingKeys: String, CodingKey {
    case v, delivery, at
    case dictationID = "dictation_id"
  }
}

struct KeyboardStatusFile: HandoffFile, Equatable {
  var v = Handoff.version
  var hasFullAccess: Bool
  var lastSeen: Int64
  var peakFootprintBytes: UInt64
  /// `phys_footprint` when the file was written. Optional so files from older keyboards
  /// still decode.
  var footprintBytes: UInt64?

  enum CodingKeys: String, CodingKey {
    case v
    case hasFullAccess = "has_full_access"
    case lastSeen = "last_seen"
    case peakFootprintBytes = "peak_footprint_bytes"
    case footprintBytes = "footprint_bytes"
  }
}

/// `levels.bin`: a UInt32 write index, then 31 UInt32 slots holding Float32 bit patterns
/// in 0–1, little-endian, 128 bytes in all. The writer overwrites the oldest slot.
struct LevelsFile: Equatable, Sendable {
  static let slotCount = 31
  static let byteCount = 128

  private(set) var writeIndex: UInt32 = 0
  private(set) var slots = [Float](repeating: 0, count: slotCount)

  init() {}

  init?(data: Data) {
    guard data.count == Self.byteCount else { return nil }
    let words = (0..<32).map { index in
      data.withUnsafeBytes {
        UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: index * 4, as: UInt32.self))
      }
    }
    writeIndex = words[0]
    slots = words.dropFirst().map { Float(bitPattern: $0) }
  }

  mutating func append(_ level: Float) {
    slots[Int(writeIndex % UInt32(Self.slotCount))] = min(max(level.isFinite ? level : 0, 0), 1)
    writeIndex &+= 1
  }

  /// Oldest first.
  var levels: [Float] {
    let start = Int(writeIndex % UInt32(Self.slotCount))
    return Array(slots[start...] + slots[..<start])
  }

  var data: Data {
    var data = Data(capacity: Self.byteCount)
    for word in [writeIndex] + slots.map(\.bitPattern) {
      withUnsafeBytes(of: word.littleEndian) { data.append(contentsOf: $0) }
    }
    return data
  }
}
