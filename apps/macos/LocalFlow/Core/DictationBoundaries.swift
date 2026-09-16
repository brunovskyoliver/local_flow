import Foundation

struct TranscriptionToken: Sendable, Equatable {
  let text: String
  let start: Double
  let end: Double
}

struct TranscriptionWindow: Sendable {
  let text: String
  let tokens: [TranscriptionToken]
}

protocol TranscriptionRuntime: Sendable {
  func transcribe(_ samples: [Float]) async throws -> TranscriptionWindow
  func shutdown() async
}

protocol DictationClock: Sendable {
  func sleep(for duration: Duration) async throws
}

struct SystemDictationClock: DictationClock {
  func sleep(for duration: Duration) async throws {
    try await ContinuousClock().sleep(for: duration)
  }
}

struct ModelLease: Sendable, Equatable {
  let sessionID: UUID
  let generation: UInt64
}

enum DictationFailure: Error, Equatable {
  case busy, staleLease, cancelled, invalidAudio, invalidResult, modelUnavailable
}

protocol AudioCapturing: Sendable {
  func authorize() async -> Bool
  func start(sessionID: UUID, spool: AudioSpool) async throws
  func stop(sessionID: UUID) async throws -> AudioCaptureResult
  func cancel(sessionID: UUID) async throws -> AudioCaptureResult
  func snapshot() async -> AudioCaptureSnapshot?
  /// Bounded raw-queue occupancy for local measurement. Adapters without a ring
  /// report nothing rather than a fabricated depth.
  func queueOccupancy() async -> QueueOccupancy?
}

struct QueueOccupancy: Equatable, Sendable {
  let highWater: UInt32
  let capacity: UInt32
}

extension AudioCapturing {
  func queueOccupancy() async -> QueueOccupancy? { nil }
}
extension AudioCaptureService: AudioCapturing {
  func authorize() async -> Bool {
    if Self.permissionStatus == .authorized { return true }
    if Self.permissionStatus == .notDetermined { return await Self.requestPermission() }
    return false
  }
}

protocol TextInserting: Sendable {
  func captureTarget() async -> CapturedTarget?
  func insertOnce(attemptID: UUID, target: CapturedTarget, text: String) async -> InsertionOutcome
}
extension TextInsertionService: TextInserting {}

protocol TranscriptionStoring: Sendable {
  func verifyWritable() async throws
  func hasRecovery() async throws -> Bool
  func reserve(maxBytes: Int) async throws -> TranscriptionStore.Reservation
  func commit(reservation: TranscriptionStore.Reservation, entry: TranscriptionEntry) async throws
    -> TranscriptionEntry
  func releaseReservation(_ reservation: TranscriptionStore.Reservation) async
  func recent(limit: Int) async throws -> [TranscriptionEntry]
  func get(_ id: UUID) async throws -> TranscriptionEntry?
  func beginAttempt(id: UUID, revision: Int64) async throws -> TranscriptionStore.Attempt
  func recordOutcome(
    id: UUID, revision: Int64, attemptID: UUID, outcome: TranscriptionStore.Outcome
  ) async throws -> TranscriptionEntry
  func dismissRecovery(id: UUID, revision: Int64) async throws -> TranscriptionEntry
  func deleteConfirmed(id: UUID, revision: Int64) async throws
}

extension TranscriptionStore: TranscriptionStoring {}
extension TranscriptionStoring {
  func hasRecovery() async throws -> Bool {
    try await recent().contains { $0.recoveryState == .needsReview }
  }
  func reserve() async throws -> TranscriptionStore.Reservation {
    try await reserve(maxBytes: 65_536)
  }
  func recent() async throws -> [TranscriptionEntry] { try await recent(limit: 20) }
}

@MainActor
protocol ShortcutObserving: AnyObject {
  var onEvent: ((ShortcutHoldState.Event) -> Void)? { get set }
  func install(_ preference: ShortcutPreference) throws
  func remove()
}
extension ShortcutController: ShortcutObserving {}

struct MeasurementSample: Sendable {
  let phase: DictationSession.State
  let monotonicNanoseconds: UInt64
  let residentBytes: UInt64
  let queueDepth: Int
  let queueCapacity: Int
}
protocol ResourceRecording: Sendable {
  func record(_ sample: MeasurementSample)
}

/// Bounded, content-free explanations suitable for both UI and local diagnostics.
enum DictationErrorMessage {
  static func describe(_ error: Error) -> String {
    if let failure = error as? ShortcutController.Failure {
      switch failure {
      case .accessibilityRequired: return "Allow Accessibility to record and prioritize shortcuts."
      case .permissionDenied: return "Allow Input Monitoring to use the dictation shortcut."
      case .invalidBinding: return "That shortcut is unavailable. Try another key combination."
      case .conflict: return "That shortcut is already registered. Try another combination."
      case .unavailable:
        return "The keyboard shortcut could not start. Check permissions and try again."
      }
    }
    if let failure = error as? AudioCaptureFailure {
      switch failure {
      case .permissionDenied, .permissionRevoked:
        return
          "Microphone access is not allowed. Enable LocalFlow in System Settings > Privacy & Security > Microphone."
      case .unsupportedFormat:
        return "The selected microphone format is unsupported. Try the built-in microphone."
      case .deviceLost:
        return "The microphone could not start or disconnected. Check the selected input device."
      case .conversion: return "Microphone audio conversion failed. Try another input device."
      case .disk: return "Temporary audio could not be written. Check available disk space."
      case .overflow:
        return "Audio capture could not keep up. Try again after reducing system load."
      case .busy: return "Microphone capture is already in progress."
      case .staleSession: return "The microphone session ended unexpectedly. Try again."
      case .sleep: return "Recording stopped because the Mac went to sleep."
      }
    }
    if let failure = error as? DictationFailure {
      switch failure {
      case .busy:
        return "Another dictation or model operation is still running. Wait for it to finish."
      case .modelUnavailable:
        return "The speech model is unavailable. Verify the local model in Settings."
      case .invalidAudio: return "Recorded audio could not be processed. Try recording again."
      case .invalidResult: return "The speech model returned an invalid result."
      case .staleLease: return "The speech model session expired. Try again."
      case .cancelled: return "The operation was cancelled."
      }
    }
    if error is CancellationError { return "The operation was cancelled." }
    // Exclude error descriptions and userInfo, which can contain paths or content.
    return "Error type \(String(reflecting: type(of: error))), code \((error as NSError).code)."
  }
}
