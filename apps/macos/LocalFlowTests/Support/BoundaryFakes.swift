@preconcurrency import ApplicationServices
import Foundation

@testable import LocalFlow

actor Gate {
  private var open = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  func wait() async {
    if open { return }
    await withCheckedContinuation { waiters.append($0) }
  }

  func openGate() {
    open = true
    let pending = waiters
    waiters.removeAll()
    for waiter in pending { waiter.resume() }
  }
}

actor FakeRuntime: TranscriptionRuntime {
  let text: String
  let gate: Gate?
  private(set) var shutdownCount = 0
  private let enteredTranscription = Gate()

  init(text: String = "hello", gate: Gate? = nil) {
    self.text = text
    self.gate = gate
  }

  func transcribe(_ samples: [Float]) async throws -> TranscriptionWindow {
    await enteredTranscription.openGate()
    if let gate { await gate.wait() }
    return TranscriptionWindow(text: text, tokens: [])
  }

  func waitUntilTranscribing() async { await enteredTranscription.wait() }

  func shutdown() async { shutdownCount += 1 }
}

actor FakeCapture: AudioCapturing {
  let resultReason: AudioCaptureStopReason
  let samples: [Float]
  let authorized: Bool
  let startGate: Gate?
  let staleSnapshot: Bool
  let staleResult: Bool
  private let enteredStart = Gate()
  private(set) var starts = 0
  private(set) var stops = 0
  private(set) var cancels = 0
  private var spool: AudioSpool?
  private var sessionID: UUID?

  init(
    reason: AudioCaptureStopReason = .keyRelease, samples: [Float] = [0, 0, 0, 0],
    authorized: Bool = true, startGate: Gate? = nil, staleSnapshot: Bool = false,
    staleResult: Bool = false
  ) {
    self.resultReason = reason
    self.samples = samples
    self.authorized = authorized
    self.startGate = startGate
    self.staleSnapshot = staleSnapshot
    self.staleResult = staleResult
  }

  func authorize() async -> Bool { authorized }
  func waitUntilStarting() async { await enteredStart.wait() }

  func start(sessionID: UUID, spool: AudioSpool) async throws {
    starts += 1
    await enteredStart.openGate()
    await startGate?.wait()
    self.sessionID = sessionID
    self.spool = spool
    if !samples.isEmpty { try spool.append(normalizedSamples: samples) }
  }

  func stop(sessionID: UUID) async throws -> AudioCaptureResult {
    stops += 1
    return try makeResult(sessionID: sessionID, reason: resultReason)
  }

  func cancel(sessionID: UUID) async throws -> AudioCaptureResult {
    cancels += 1
    return try makeResult(sessionID: sessionID, reason: .cancelled)
  }

  func snapshot() async -> AudioCaptureSnapshot? {
    guard let sessionID else { return nil }
    return AudioCaptureSnapshot(
      sessionID: staleSnapshot ? UUID() : sessionID, sampleCount: samples.count, level: 0,
      terminalReason: resultReason == .keyRelease ? nil : resultReason)
  }

  private func makeResult(sessionID: UUID, reason: AudioCaptureStopReason) throws
    -> AudioCaptureResult
  {
    guard let spool else { throw AudioCaptureFailure.staleSession }
    return AudioCaptureResult(
      sessionID: staleResult ? UUID() : sessionID, spool: spool, sampleCount: samples.count,
      reason: reason)
  }
}

final class FakeInsertion: TextInserting, @unchecked Sendable {
  let store: TranscriptionStore?
  let target: CapturedTarget
  let dispatchGate: Gate?
  private let lock = NSLock()
  private var dispatchCountStorage = 0
  private var sawAttemptingStorage = false
  var outcome: InsertionOutcome = .confirmed

  init(store: TranscriptionStore? = nil, dispatchGate: Gate? = nil) {
    self.store = store
    self.dispatchGate = dispatchGate
    target = CapturedTarget(
      processIdentifier: 1, launchDate: Date(), bundleIdentifier: "test.bundle",
      element: AXUIElementCreateSystemWide(), focusedWindow: AXUIElementCreateSystemWide(),
      selectedRange: CFRange(location: 0, length: 0), comparisonContext: "")
  }

  var dispatchCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return dispatchCountStorage
  }
  var sawAttempting: Bool {
    lock.lock()
    defer { lock.unlock() }
    return sawAttemptingStorage
  }

  func captureTarget() async -> CapturedTarget? { target }

  func insertOnce(attemptID: UUID, target: CapturedTarget, text: String) async -> InsertionOutcome {
    lock.withLock { dispatchCountStorage += 1 }
    if let store, let entry = try? await store.recent(limit: 1).first {
      lock.withLock { sawAttemptingStorage = entry.deliveryState == .attempting }
    }
    await dispatchGate?.wait()
    return outcome
  }
}

func makeSpoolRoot() throws -> URL {
  let root = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("LocalFlowTests-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(
    at: root, withIntermediateDirectories: true,
    attributes: [.posixPermissions: 0o700])
  return root
}
