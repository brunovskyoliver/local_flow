@preconcurrency import ApplicationServices
import Foundation
import XCTest

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
  private var insertedTextStorage: [String] = []
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

  var insertedTexts: [String] {
    lock.lock()
    defer { lock.unlock() }
    return insertedTextStorage
  }

  func insertOnce(attemptID: UUID, target: CapturedTarget, text: String) async -> InsertionOutcome {
    lock.withLock {
      dispatchCountStorage += 1
      insertedTextStorage.append(text)
    }
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

/// Authored evidence only; never claims these values came from a model run.
func makeQualityEnvelope(
  id: UUID = UUID(), raw: String = "raw evidence", text: String = "assembled",
  build: String = "test-build", reasons: [TranscriptionQualityDetail.CompletionReason] = []
) throws -> TranscriptionEnvelope {
  let provenance = TranscriptionProvenance(
    engine: "fake", sdkVersion: "test", modelID: "test-model", modelRevision: "test-revision",
    modelManifestHash: TranscriptionQualityDetail.hash("manifest"),
    artifactHashes: ["model": TranscriptionQualityDetail.hash("artifact")],
    build: build, dirty: false, languageHint: nil, automaticLanguage: true,
    sampleRate: 16_000, channels: 1, inputSamples: 16_000,
    inputDurationSeconds: 1, inputSampleFormat: "float32_pcm",
    windowSamples: 239_360, overlapSamples: 32_000, strideSamples: 207_360,
    minimumPaddedSamples: 4_800, operatingSystem: "test-os", foldingRuntime: "test-foundation",
    stageDurations: ["recognition": 0.1, "assembly": 0.01, "normalization": 0],
    unavailableMetadata: [])
  let detail = try TranscriptionQualityDetail(
    rawWindows: [
      .init(
        sequence: 0, sampleStart: 0, sampleCount: 16_000,
        paddedSampleCount: 16_000, text: raw, timings: nil, timingValidation: .unavailable)
    ],
    assembledText: text, normalizedText: text, assemblyVersion: "test-assembly-v1",
    normalizationVersion: "identity-v1", provenance: provenance, completionReasons: reasons)
  let entry = try TranscriptionEntry(
    id: id, text: text, createdAtMilliseconds: 1,
    quality: reasons.isEmpty ? .complete : .incomplete, stopReason: .keyRelease)
  return TranscriptionEnvelope(entry: entry, detail: detail)
}

struct FakeDictationTranscriber: DictationTranscribing {
  let result: TranscriptionResult
  var gate: Gate? = nil
  func transcribe(spool: AudioSpool, lease: ModelLease, sampleCount: Int) async
    -> TranscriptionResult
  {
    await gate?.wait()
    return result
  }
}

/// In-memory `RewriteAttemptStoring` with the same ordinal, attempt-limit,
/// in-flight and quota rules as the real store. `begin` throws without writing.
actor FakeRewriteAttemptStore: RewriteAttemptStoring {
  enum Call: Equatable, Sendable {
    case begin(UUID)
    case recordResult(UUID)
    case recordFailure(UUID, RewriteFailureCategory)
    case recordCancelled(UUID)
    case markStale(UUID)
    case attempts(UUID)
    case cancelPendingOnStartup
    case recordDelivered(UUID)
  }
  private(set) var rows: [UUID: RewriteAttempt] = [:]
  private(set) var calls: [Call] = []
  private(set) var payloadBytes = 0
  var quotaBytes = TranscriptionStore.maximumPayloadBytes
  /// Dictations the fake knows about; `begin` for any other id throws `missingEntry`.
  private var known: Set<UUID> = []
  private var stateChanged: [UUID: TranscriptionEntry.RewriteState] = [:]

  init(known: [UUID] = []) { self.known = Set(known) }

  func register(_ id: UUID) { known.insert(id) }
  func setQuota(_ bytes: Int) { quotaBytes = bytes }

  func rewriteState(for transcriptionID: UUID) -> TranscriptionEntry.RewriteState {
    stateChanged[transcriptionID] ?? .notRequested
  }
  func attempts(for transcriptionID: UUID) -> [RewriteAttempt] {
    calls.append(.attempts(transcriptionID))
    return rows.values.filter { $0.transcriptionID == transcriptionID }.sorted {
      $0.ordinal < $1.ordinal
    }
  }
  var allAttempts: [RewriteAttempt] {
    rows.values.sorted { $0.startedAtMilliseconds < $1.startedAtMilliseconds }
  }
  var beginCount: Int {
    calls.filter { if case .begin = $0 { return true } else { return false } }.count
  }

  func begin(_ admission: RewriteAdmission) throws -> RewriteAttempt {
    calls.append(.begin(admission.transcriptionID))
    guard known.contains(admission.transcriptionID) else {
      throw TranscriptionStore.Error.missingEntry
    }
    let existing = rows.values.filter { $0.transcriptionID == admission.transcriptionID }
    guard existing.count < RewriteAttempt.maximumPerDictation else {
      throw RewriteFailure(.attemptLimit)
    }
    guard !existing.contains(where: { $0.state == .pending }),
      rows.values.filter({ $0.state == .pending }).count < RewriteAttempt.maximumPendingOverall
    else { throw RewriteFailure(.concurrencyLimit) }
    guard payloadBytes + admission.reservedBytes <= quotaBytes else {
      throw RewriteFailure(.capacityExceeded)
    }
    payloadBytes += admission.reservedBytes
    let attempt = RewriteAttempt(
      id: UUID(), transcriptionID: admission.transcriptionID,
      ordinal: (existing.map(\.ordinal).max() ?? 0) + 1, mode: admission.mode, state: .pending,
      inputText: admission.inputText,
      inputHash: TranscriptionQualityDetail.hash(admission.inputText),
      outputText: nil, outputHash: nil, unchanged: false, failureCategory: nil, stale: false,
      startedAtMilliseconds: Int64(Date().timeIntervalSince1970 * 1000), spans: .none,
      serverQueueMilliseconds: nil, backendFirstTokenMilliseconds: nil, backendMilliseconds: nil,
      protocolVersion: 1, identity: .unknown, endpointOrigin: admission.endpointOrigin,
      insecureOverride: admission.insecureOverride, delivered: false)
    rows[attempt.id] = attempt
    stateChanged[admission.transcriptionID] = .pending
    return attempt
  }

  private var resultGate: Gate?
  let resultEntered = Gate()
  func gateResult(_ gate: Gate?) { resultGate = gate }
  func addKnown(_ id: UUID) { known.insert(id) }

  func recordResult(id: UUID, result: RewriteResult, spans: RewriteSpans) async throws
    -> RewriteAttempt
  {
    if let gate = resultGate {
      await resultEntered.openGate()
      await gate.wait()
    }
    calls.append(.recordResult(id))
    let current = try pending(id)
    payloadBytes -= RewriteBounds.maximumResultBytes(inputBytes: current.inputText.utf8.count)
    payloadBytes += result.text.utf8.count
    return replace(
      current, state: .succeeded, category: nil, output: result.text, spans: spans,
      identity: RewriteIdentity(result: result), result: result)
  }

  func recordFailure(id: UUID, category: RewriteFailureCategory, spans: RewriteSpans) throws
    -> RewriteAttempt
  {
    calls.append(.recordFailure(id, category))
    guard category.isPersistable else { throw TranscriptionStore.Error.invalidAttempt }
    let current = try pending(id)
    payloadBytes -= RewriteBounds.maximumResultBytes(inputBytes: current.inputText.utf8.count)
    return replace(
      current, state: category == .timeout ? .timedOut : .failed, category: category, output: nil,
      spans: spans, identity: current.identity, result: nil)
  }

  func recordCancelled(id: UUID, spans: RewriteSpans) throws -> RewriteAttempt {
    calls.append(.recordCancelled(id))
    let current = try pending(id)
    payloadBytes -= RewriteBounds.maximumResultBytes(inputBytes: current.inputText.utf8.count)
    return replace(
      current, state: .cancelled, category: nil, output: nil, spans: spans,
      identity: current.identity, result: nil)
  }

  func markStale(id: UUID) throws {
    calls.append(.markStale(id))
    guard let current = rows[id] else { throw TranscriptionStore.Error.missingEntry }
    rows[id] = copy(current, stale: true)
  }

  func cancelPendingOnStartup() -> Int {
    calls.append(.cancelPendingOnStartup)
    var count = 0
    for attempt in rows.values where attempt.state == .pending {
      payloadBytes -= RewriteBounds.maximumResultBytes(inputBytes: attempt.inputText.utf8.count)
      _ = replace(
        attempt, state: .failed, category: .interrupted, output: nil, spans: attempt.spans,
        identity: attempt.identity, result: nil)
      count += 1
    }
    return count
  }

  func recordDelivered(attemptID: UUID) throws {
    calls.append(.recordDelivered(attemptID))
    guard let current = rows[attemptID], current.state == .succeeded else {
      throw TranscriptionStore.Error.invalidAttempt
    }
    rows[attemptID] = copy(current, delivered: true)
  }

  private func pending(_ id: UUID) throws -> RewriteAttempt {
    guard let current = rows[id] else { throw TranscriptionStore.Error.missingEntry }
    guard current.state == .pending else { throw TranscriptionStore.Error.invalidAttempt }
    return current
  }

  private func replace(
    _ current: RewriteAttempt, state: RewriteAttemptState, category: RewriteFailureCategory?,
    output: String?, spans: RewriteSpans, identity: RewriteIdentity, result: RewriteResult?
  ) -> RewriteAttempt {
    let next = RewriteAttempt(
      id: current.id, transcriptionID: current.transcriptionID, ordinal: current.ordinal,
      mode: current.mode, state: state, inputText: current.inputText, inputHash: current.inputHash,
      outputText: output, outputHash: output.map(TranscriptionQualityDetail.hash),
      unchanged: output.map { $0.utf8.elementsEqual(current.inputText.utf8) } ?? false,
      failureCategory: category, stale: current.stale,
      startedAtMilliseconds: current.startedAtMilliseconds, spans: spans,
      serverQueueMilliseconds: result?.serverQueueMilliseconds,
      backendFirstTokenMilliseconds: result?.backendFirstTokenMilliseconds,
      backendMilliseconds: result?.backendMilliseconds, protocolVersion: current.protocolVersion,
      identity: identity, endpointOrigin: current.endpointOrigin,
      insecureOverride: current.insecureOverride, delivered: current.delivered)
    rows[next.id] = next
    let newest = rows.values.filter { $0.transcriptionID == next.transcriptionID }
      .max { $0.ordinal < $1.ordinal }
    stateChanged[next.transcriptionID] = newest.map { TranscriptionEntry.RewriteState($0.state) }
    return next
  }

  private func copy(_ current: RewriteAttempt, stale: Bool? = nil, delivered: Bool? = nil)
    -> RewriteAttempt
  {
    RewriteAttempt(
      id: current.id, transcriptionID: current.transcriptionID, ordinal: current.ordinal,
      mode: current.mode, state: current.state, inputText: current.inputText,
      inputHash: current.inputHash, outputText: current.outputText, outputHash: current.outputHash,
      unchanged: current.unchanged, failureCategory: current.failureCategory,
      stale: stale ?? current.stale, startedAtMilliseconds: current.startedAtMilliseconds,
      spans: current.spans, serverQueueMilliseconds: current.serverQueueMilliseconds,
      backendFirstTokenMilliseconds: current.backendFirstTokenMilliseconds,
      backendMilliseconds: current.backendMilliseconds, protocolVersion: current.protocolVersion,
      identity: current.identity, endpointOrigin: current.endpointOrigin,
      insecureOverride: current.insecureOverride, delivered: delivered ?? current.delivered)
  }
}

/// In-memory credential store with the same validation as the Keychain store.
final class FakeRewriteCredentialStore: RewriteCredentialStoring, @unchecked Sendable {
  private let lock = NSLock()
  private var secrets: [String: String] = [:]
  private(set) var readCount = 0

  func read(origin: String) throws -> String? {
    lock.withLock {
      readCount += 1
      return secrets[origin]
    }
  }
  func write(origin: String, secret: String) throws {
    try RewriteCredentialValidation.validate(secret: secret)
    lock.withLock { secrets[origin] = secret }
  }
  func remove(origin: String) throws { lock.withLock { _ = secrets.removeValue(forKey: origin) } }
  func exists(origin: String) -> Bool { lock.withLock { secrets[origin] != nil } }
}

/// Manual clock: `sleep` parks until `advance` moves time past its deadline.
/// Tests can wait for a sleeper to register before advancing.
actor FakeRewriteClock: DictationClock {
  private var now: Duration = .zero
  private var sleepers:
    [(id: UUID, deadline: Duration, continuation: CheckedContinuation<Void, Error>)] = []
  private var registrationWaiters: [CheckedContinuation<Void, Never>] = []
  private(set) var sleepCount = 0

  var elapsed: Duration { now }

  func sleep(for duration: Duration) async throws {
    let id = UUID()
    let deadline = now + duration
    sleepCount += 1
    let waiters = registrationWaiters
    registrationWaiters.removeAll()
    for waiter in waiters { waiter.resume() }
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<Void, Error>) in
        if Task.isCancelled {
          continuation.resume(throwing: CancellationError())
        } else if deadline <= now {
          continuation.resume()
        } else {
          sleepers.append((id, deadline, continuation))
        }
      }
    } onCancel: {
      Task { await self.cancel(id) }
    }
  }

  /// Resolves once at least `count` sleeps have been requested in total.
  func waitForSleepers(_ count: Int = 1) async {
    while sleepCount < count {
      await withCheckedContinuation { registrationWaiters.append($0) }
    }
  }

  func advance(by duration: Duration) {
    now += duration
    let due = sleepers.filter { $0.deadline <= now }
    sleepers.removeAll { $0.deadline <= now }
    for sleeper in due { sleeper.continuation.resume() }
  }

  private func cancel(_ id: UUID) {
    guard let index = sleepers.firstIndex(where: { $0.id == id }) else { return }
    sleepers.remove(at: index).continuation.resume(throwing: CancellationError())
  }

}

/// Scripted transport. Each request id (or the default) maps to a script; every
/// request is recorded. `failOnAnyCall` fails the test if the transport is used.
final class FakeRewriteTransport: RewriteTransporting, @unchecked Sendable {
  indirect enum Script: Sendable {
    /// A valid `result` with the given text and identity.
    case succeed(
      text: String, backendModel: String = "fake-model", promptVersion: Int = 1,
      shieldVersion: Int = 1, responseMode: String? = nil, responseID: UUID? = nil)
    /// Wait on the fake clock, then run the next script.
    case delay(Duration, then: Script)
    /// Wait for a gate (e.g. after the attempt was cancelled), then run the next script.
    case after(Gate, then: Script)
    /// The result bytes arrive before cancellation; EOF is deliberately delayed.
    case resultBeforeEOF(text: String, emitted: Gate, finish: Gate)
    case fail(RewriteFailureCategory)
    case httpStatus(Int, code: String?)
    case malformed
    case oversized
    case events([RewriteEvent])
    /// Never finishes; ends only when the consumer cancels or the timeout fires.
    case hang
  }

  struct Recorded: Sendable, Equatable {
    let request: RewriteRequest
    let endpoint: RewriteEndpoint
    let timeout: Duration
  }

  private let lock = NSLock()
  private var scripts: [UUID: Script] = [:]
  private var defaultScript: Script
  private(set) var recorded: [Recorded] = []
  private(set) var healthCalls = 0
  private(set) var invalidations = 0
  var healthGate: Gate?
  let healthStarted = Gate()
  var healthResult: Result<HealthResponse, RewriteConnectionFailure>?
  let clock: FakeRewriteClock
  let failOnAnyCall: Bool
  private let started = Gate()

  init(
    defaultScript: Script = .succeed(text: "Rewritten."),
    clock: FakeRewriteClock = FakeRewriteClock(),
    failOnAnyCall: Bool = false
  ) {
    self.defaultScript = defaultScript
    self.clock = clock
    self.failOnAnyCall = failOnAnyCall
  }

  func script(_ script: Script, for requestID: UUID) {
    lock.withLock { scripts[requestID] = script }
  }
  func setDefault(_ script: Script) { lock.withLock { defaultScript = script } }
  var requests: [RewriteRequest] { lock.withLock { recorded.map(\.request) } }
  var callCount: Int { lock.withLock { recorded.count } }
  /// Resolves once the first rewrite call has been recorded.
  func waitUntilCalled() async { await started.wait() }

  func rewrite(request: RewriteRequest, endpoint: RewriteEndpoint, timeout: Duration)
    -> AsyncThrowingStream<RewriteTransportItem, Error>
  {
    if failOnAnyCall { XCTFail("RewriteTransporting must not be invoked in this configuration") }
    let script: Script = lock.withLock {
      recorded.append(Recorded(request: request, endpoint: endpoint, timeout: timeout))
      return scripts[request.requestID] ?? defaultScript
    }
    let clock = clock
    let started = started
    return AsyncThrowingStream { continuation in
      let task = Task {
        await started.openGate()
        do {
          try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
              try await clock.sleep(for: timeout)
              throw RewriteFailure(.timeout)
            }
            group.addTask {
              try await Self.run(script, request: request, clock: clock, continuation: continuation)
            }
            try await group.next()
            group.cancelAll()
          }
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }

  private static func run(
    _ script: Script, request: RewriteRequest, clock: FakeRewriteClock,
    continuation: AsyncThrowingStream<RewriteTransportItem, Error>.Continuation
  ) async throws {
    switch script {
    case .delay(let duration, let next):
      try await clock.sleep(for: duration)
      try await run(next, request: request, clock: clock, continuation: continuation)
    case .after(let gate, let next):
      await gate.wait()
      try Task.checkCancellation()
      try await run(next, request: request, clock: clock, continuation: continuation)
    case .resultBeforeEOF(let text, let emitted, let finish):
      try await run(
        .succeed(text: text), request: request, clock: clock, continuation: continuation)
      await emitted.openGate()
      await finish.wait()
    case .fail(let category):
      continuation.yield(.firstByte)
      throw RewriteFailure(category)
    case .httpStatus(let status, let code):
      continuation.yield(.firstByte)
      throw RewriteFailure(RewriteFailureCategory.forHTTPStatus(status, code: code))
    case .malformed:
      continuation.yield(.firstByte)
      throw RewriteFailure(.malformedResponse)
    case .oversized:
      continuation.yield(.firstByte)
      throw RewriteFailure(.oversizedResponse)
    case .hang:
      try await clock.sleep(for: .seconds(86_400))
    case .events(let events):
      continuation.yield(.firstByte)
      var bytes = 0
      for event in events {
        continuation.yield(.event(event))
        bytes += 64
      }
      continuation.yield(.completed(requestBytes: request.inputBytes + 96, responseBytes: bytes))
    case .succeed(
      let text, let backendModel, let promptVersion, let shieldVersion, let responseMode,
      let responseID):
      let payload = RewriteEvent.ResultPayload(
        schemaVersion: 1, requestID: (responseID ?? request.requestID).uuidString,
        mode: responseMode ?? request.mode.rawValue,
        text: text, textIsString: true, server: .init(name: "fake", version: "0"),
        backend: .init(kind: "fake", model: backendModel), promptVersion: promptVersion,
        shield: .init(version: shieldVersion, placeholders: 0, restored: 0),
        timing: .init(
          queueMilliseconds: 1, backendFirstTokenMilliseconds: 20, backendMilliseconds: 80))
      continuation.yield(.firstByte)
      continuation.yield(.event(.accepted(requestID: request.requestID.uuidString)))
      continuation.yield(.event(.result(payload)))
      continuation.yield(
        .completed(requestBytes: request.inputBytes + 96, responseBytes: text.utf8.count + 200))
    }
  }

  func health(endpoint: RewriteEndpoint) async throws -> HealthResponse {
    if failOnAnyCall { XCTFail("RewriteTransporting.health must not be invoked") }
    lock.withLock { healthCalls += 1 }
    await healthStarted.openGate()
    if let healthGate { await healthGate.wait() }
    switch healthResult {
    case .success(let health): return health
    case .failure(let failure): throw failure
    case nil: throw RewriteConnectionFailure(category: .serverUnreachable, diagnostic: "unscripted")
    }
  }

  func invalidate() { lock.withLock { invalidations += 1 } }
}

/// AppServices-equivalent rewrite wiring for tests: a real `RewriteCoordinator`
/// over the fakes above, against whichever attempt store the test already uses.
/// The defaults are the SC-001 guard shape — always wired, rewriting off, and a
/// transport that fails the test if it is ever called.
@MainActor
final class RewriteRig {
  let preferences: AppPreferences
  let credentials = FakeRewriteCredentialStore()
  let transport: FakeRewriteTransport
  let coordinator: RewriteCoordinator
  private let suiteName: String

  init(
    store: any RewriteAttemptStoring,
    enabled: Bool = false,
    mode: RewriteMode = .clean,
    endpoint: String = "http://127.0.0.1:8080",
    credential: String? = nil,
    timeoutSeconds: Int = 5,
    script: FakeRewriteTransport.Script = .succeed(text: "Rewritten text."),
    failOnAnyCall: Bool = true
  ) {
    suiteName = "LocalFlow-rewrite-rig-\(UUID())"
    preferences = AppPreferences(defaults: UserDefaults(suiteName: suiteName)!)
    preferences.rewriteEnabled = enabled
    preferences.rewriteEndpoint = endpoint
    preferences.rewriteDefaultMode = mode
    preferences.rewriteTimeoutSeconds = timeoutSeconds
    if let credential, let origin = RewriteSettings.normalizedOrigin(endpoint) {
      try? credentials.write(origin: origin, secret: credential)
    }
    transport = FakeRewriteTransport(defaultScript: script, failOnAnyCall: failOnAnyCall)
    coordinator = RewriteCoordinator(
      preferences: preferences, credentials: credentials, transport: transport, store: store)
  }

  var callCount: Int { transport.callCount }

  func removeSuite() {
    UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
  }
}
