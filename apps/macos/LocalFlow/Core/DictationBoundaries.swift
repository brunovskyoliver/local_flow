import Foundation

struct TranscriptionToken: Sendable, Equatable {
  let text: String
  let start: Double
  let end: Double
}

struct TranscriptionWindow: Sendable {
  let text: String
  let tokens: [TranscriptionToken]
  var evidence: RecognitionEvidence? = nil
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
  func readText(on target: CapturedTarget, location: Int, length: Int) async throws -> String
}
extension TextInserting {
  func readText(on target: CapturedTarget, location: Int, length: Int) async throws -> String {
    throw TargetIssue.unsupported
  }
}
extension TextInsertionService: TextInserting {}

/// One immutable result travels through save/retry; summaries never contain the detail.
struct TranscriptionEnvelope: Sendable {
  let entry: TranscriptionEntry
  let detail: TranscriptionQualityDetail?

  func validate() throws {
    guard let detail else { return }
    try detail.validate(normalizedText: entry.text)
    guard !detail.incomplete || entry.quality != .complete else {
      throw TranscriptionQualityDetail.Failure.invalidMetadata
    }
  }
}

protocol TranscriptionStoring: Sendable {
  func verifyWritable() async throws
  func hasRecovery() async throws -> Bool
  func reserve(maxBytes: Int) async throws -> TranscriptionStore.Reservation
  func commit(reservation: TranscriptionStore.Reservation, entry: TranscriptionEntry) async throws
    -> TranscriptionEntry
  func commit(reservation: TranscriptionStore.Reservation, envelope: TranscriptionEnvelope)
    async throws
    -> TranscriptionEntry
  func releaseReservation(_ reservation: TranscriptionStore.Reservation) async
  func recent(limit: Int) async throws -> [TranscriptionEntry]
  func get(_ id: UUID) async throws -> TranscriptionEntry?
  func beginAttempt(id: UUID, revision: Int64) async throws -> TranscriptionStore.Attempt
  func recordOutcome(
    id: UUID, revision: Int64, attemptID: UUID, outcome: TranscriptionStore.Outcome
  ) async throws -> TranscriptionEntry
  /// Same as above plus which text was delivered; one transaction.
  func recordOutcome(
    id: UUID, revision: Int64, attemptID: UUID, outcome: TranscriptionStore.Outcome,
    delivery: RewriteDelivery
  ) async throws -> TranscriptionEntry
  func dismissRecovery(id: UUID, revision: Int64) async throws -> TranscriptionEntry
  func deleteConfirmed(id: UUID, revision: Int64) async throws
}

extension TranscriptionStore: TranscriptionStoring {}

/// Attempt persistence for server-assisted rewriting. `begin` is the admission
/// step: it throws `attempt_limit`, `concurrency_limit` or `capacity_exceeded`
/// as `RewriteFailure` without writing anything.
protocol RewriteAttemptStoring: Sendable {
  func begin(_ admission: RewriteAdmission) async throws -> RewriteAttempt
  func recordResult(id: UUID, result: RewriteResult, spans: RewriteSpans) async throws
    -> RewriteAttempt
  func recordFailure(id: UUID, category: RewriteFailureCategory, spans: RewriteSpans) async throws
    -> RewriteAttempt
  func recordCancelled(id: UUID, spans: RewriteSpans) async throws -> RewriteAttempt
  func markStale(id: UUID) async throws
  func attempts(for transcriptionID: UUID) async throws -> [RewriteAttempt]
  @discardableResult func cancelPendingOnStartup() async throws -> Int
  func recordDelivered(attemptID: UUID) async throws
}
extension TranscriptionStore: RewriteAttemptStoring {}

/// The rewrite credential, keyed by endpoint origin. Production is the Keychain;
/// the value is read only when a request is built, never into a snapshot.
protocol RewriteCredentialStoring: Sendable {
  func read(origin: String) throws -> String?
  func write(origin: String, secret: String) throws
  func remove(origin: String) throws
  /// Presence without the value.
  func exists(origin: String) -> Bool
}
extension RewriteCredentialStore: RewriteCredentialStoring {}

/// Result of the admission sequence (`data-model.md`, "Admission"). Only
/// `admitted` has persisted anything.
enum RewriteAdmissionResult: Sendable, Equatable {
  /// Rewriting off, Exact mode or blank text: no category, no notice, no row.
  case notEligible
  /// A pre-admission refusal: no row, no request, one content-free counter.
  case refused(RewriteFailureCategory)
  case admitted(RewriteAttempt)
}

/// Terminal outcome of one attempt as the dictation flow consumes it.
enum RewriteOutcome: Sendable, Equatable {
  case rewritten(text: String, attempt: RewriteAttempt)
  case fallback(faithful: String, category: RewriteFailureCategory)
  case cancelled(faithful: String)
  case refused(RewriteFailureCategory)
  case notEligible
}

/// The dictation flow's view of rewriting. Production wires one
/// `RewriteCoordinator` unconditionally; nil is a test-only configuration that
/// reproduces the Feature 002 flow exactly.
@MainActor
protocol RewriteRequesting: AnyObject {
  /// Runs the admission sequence with a fresh settings snapshot. Returns after
  /// `begin` has persisted the pending row, or without any side effect.
  func admit(
    dictation: UUID, text: String, mode: RewriteMode?, committed: ContinuousClock.Instant,
    context: RewriteNotice.Context
  ) async -> RewriteAdmissionResult
  /// Awaits the admitted attempt's terminal state.
  func complete(attemptID: UUID) async -> RewriteOutcome
  /// Re-runs admission for an existing dictation with a fresh snapshot. With
  /// `origin: .history` the attempt completes into the store and inserts nothing.
  func retry(
    dictation: UUID, faithfulText: String, mode: RewriteMode, origin: RewriteNotice.Context,
    onAdmitted: (@MainActor (RewriteAttempt) -> Void)?
  ) async -> RewriteOutcome
  /// Cancels a pending attempt; later bytes are recorded stale and dropped.
  func cancel(attemptID: UUID)
}

/// Server transport. The stream yields `firstByte`, decoded events, then
/// `completed`; it throws `RewriteFailure` (or `CancellationError`) otherwise.
/// The per-request timeout is enforced inside the transport.
protocol RewriteTransporting: Sendable {
  func rewrite(request: RewriteRequest, endpoint: RewriteEndpoint, timeout: Duration)
    -> AsyncThrowingStream<RewriteTransportItem, Error>
  func health(endpoint: RewriteEndpoint) async throws -> HealthResponse
  /// Release idle resources; the next request recreates them.
  func invalidate()
}

/// Read once at admission; a failure blocks the session instead of changing its meaning.
protocol VocabularyProviding: Sendable {
  func snapshot() async throws -> VocabularySnapshot
}
extension VocabularyStore: VocabularyProviding {}

/// Explicit empty identity for callers without a store.
struct EmptyVocabularyProvider: VocabularyProviding {
  func snapshot() async throws -> VocabularySnapshot { .empty }
}
extension TranscriptionStoring {
  func hasRecovery() async throws -> Bool {
    try await recent().contains { $0.recoveryState == .needsReview }
  }
  func reserve() async throws -> TranscriptionStore.Reservation {
    try await reserve(maxBytes: TranscriptionStore.reservationBytes)
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
    if let failure = error as? VocabularyEditError {
      switch failure.code {
      case .damaged:
        return "Preferred spellings could not be loaded. Repair or delete entries in Settings."
      case .staleRevision: return failure.message
      default: return "Preferred spelling rejected: \(failure.message)"
      }
    }
    if error is CancellationError { return "The operation was cancelled." }
    // Exclude error descriptions and userInfo, which can contain paths or content.
    return "Error type \(String(reflecting: type(of: error))), code \((error as NSError).code)."
  }
}
