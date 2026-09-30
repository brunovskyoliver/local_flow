import XCTest

@testable import LocalFlow
@testable import LocalFlowSpeech

@MainActor
final class FakeRemoteRouter: RemoteDictationRouting {
  var current: RemoteDictationSettings
  var provisioned = true
  let flowd = FakeFlowdDictation()
  let credentials = FakeSessionCredentials()
  lazy var opener = FakeRemoteTransportOpener { [flowd] _ in flowd.transport() }
  private(set) var started: [RemoteDictationSettings] = []
  private(set) var sessionsMade = 0
  private(set) var completedCount = 0
  private(set) var fullCalls = 0
  var pendingStore: PendingRemoteDictationStore?
  var keepFails = false

  init(state: RemoteDictationState = .approved) {
    current = RemoteDictationSettings(
      enabled: true, serverOrigin: URL(string: "https://mini.example.com"), state: state,
      fallbackThreshold: .milliseconds(300))
  }

  func settings() -> RemoteDictationSettings { current }
  func dictationStarted(settings: RemoteDictationSettings) { started.append(settings) }

  func makeSession(
    settings: RemoteDictationSettings, boost: RemoteBoost?,
    read: @escaping RemoteDictationSession.SampleReader,
    recorded: @escaping RemoteDictationSession.SampleCounter
  ) -> RemoteDictationSession? {
    sessionsMade += 1
    return RemoteDictationSession(
      configuration: .init(
        channelURL: URL(string: "wss://mini.example.com/v1/remote/channel")!,
        serverKey: FakeRemoteServer.serverKey.publicKey.rawRepresentation, boost: boost,
        threshold: settings.fallbackThreshold, pumpInterval: .milliseconds(20)),
      transports: opener, credentials: credentials, clock: SystemRemoteClock(), read: read,
      recorded: recorded)
  }

  var localModelProvisioned: Bool { provisioned }

  func keepForRetry(
    id: UUID, audio: URL, sampleCount: Int, failure: RemoteFailureReason, targetBundleID: String?
  ) async throws {
    if keepFails { throw PendingRemoteDictationStore.Failure.full }
    _ = try await pendingStore!.add(
      id: id, audio: audio, sampleCount: sampleCount, failure: failure,
      targetBundleID: targetBundleID, now: 1_000)
  }

  func retryQueueFull(audio: URL, sampleCount: Int) async { fullCalls += 1 }
  func completed(_ result: RemoteDictationResult, dictation: UUID) { completedCount += 1 }
}

/// Feature 014 routing in `DictationCoordinator` (FR-002, FR-017 to FR-019, R12).
@MainActor
final class RemoteDictationRoutingTests: XCTestCase {
  private enum Timeout: Error { case expired }
  private var directories: [URL] = []

  override func tearDown() async throws {
    for directory in directories { try? FileManager.default.removeItem(at: directory) }
    directories = []
  }

  private final class LoadCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func increment() { lock.withLock { value += 1 } }
    var loads: Int { lock.withLock { value } }
  }

  private func makeStore() throws -> TranscriptionStore {
    let directory = try makeSpoolRoot()
    directories.append(directory)
    return try TranscriptionStore(path: directory.appendingPathComponent("history.sqlite").path)
  }

  private func makeCoordinator(
    store: TranscriptionStore, remote: (any RemoteDictationRouting)?,
    capture: FakeCapture = FakeCapture(samples: Array(repeating: 0.1, count: 1_600)),
    insertion: FakeInsertion? = nil, loads: LoadCounter = LoadCounter(),
    text: String = "local words"
  ) throws -> DictationCoordinator {
    let spoolRoot = try makeSpoolRoot()
    directories.append(spoolRoot)
    let lifecycle = ModelLifecycleCoordinator {
      loads.increment()
      return FakeRuntime(text: text)
    }
    return DictationCoordinator(
      store: store, lifecycle: lifecycle, capture: capture,
      insertion: insertion ?? FakeInsertion(store: store), spoolRoot: spoolRoot, remote: remote)
  }

  private func dictate(_ coordinator: DictationCoordinator, afterStart: () -> Void = {})
    async throws
  {
    coordinator.begin()
    try await waitUntil { coordinator.state == .recording }
    afterStart()
    try await Task.sleep(for: .milliseconds(60))
    coordinator.release()
    try await waitUntil { !coordinator.busy }
  }

  private func waitUntil(_ predicate: @escaping @MainActor () -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while !predicate() {
      guard ContinuousClock.now < deadline else {
        XCTFail("timed out")
        throw Timeout.expired
      }
      try await Task.sleep(for: .milliseconds(2))
    }
  }

  func testRemoteOffMakesNoConnectionAndBehavesAsToday() async throws {
    let store = try makeStore()
    let router = FakeRemoteRouter()
    router.current = .off
    let coordinator = try makeCoordinator(store: store, remote: router)
    try await dictate(coordinator)
    let entry = try await store.recent().first
    XCTAssertEqual(entry?.text, "local words")
    XCTAssertEqual(entry?.recognitionPath, .local)
    XCTAssertNil(entry?.serverFailure)
    XCTAssertEqual(entry?.deliveryState, .confirmed)
    XCTAssertEqual(router.sessionsMade, 0)
    XCTAssertEqual(router.opener.openCount, 0)
    // No router at all is the same local flow.
    let plain = try makeCoordinator(store: store, remote: nil)
    try await dictate(plain)
    let rows = try await store.recent()
    XCTAssertEqual(rows.map(\.recognitionPath), [.local, .local])
  }

  func testApprovedDeviceUsesTheServerWithoutTheLocalLease() async throws {
    let store = try makeStore()
    let router = FakeRemoteRouter()
    let loads = LoadCounter()
    let insertion = FakeInsertion(store: store)
    let coordinator = try makeCoordinator(
      store: store, remote: router, insertion: insertion, loads: loads)
    try await dictate(coordinator)
    let entry = try await store.recent().first
    XCTAssertEqual(entry?.text, "window 0")
    XCTAssertEqual(entry?.recognitionPath, .server)
    XCTAssertNil(entry?.serverFailure)
    // Saved before the insertion attempt, then inserted.
    XCTAssertTrue(insertion.sawAttempting)
    XCTAssertEqual(entry?.deliveryState, .confirmed)
    XCTAssertEqual(loads.loads, 0)
    XCTAssertEqual(router.completedCount, 1)
    XCTAssertEqual(router.flowd.ends, [1_600])
    let detail = try await store.qualityDetail(try XCTUnwrap(entry).id)
    XCTAssertEqual(detail?.provenance.modelID, "m")
  }

  func testTheDecisionIsTakenOnceAtKeyPress() async throws {
    let store = try makeStore()
    let router = FakeRemoteRouter()
    let coordinator = try makeCoordinator(store: store, remote: router)
    try await dictate(coordinator) {
      // A later change of state does not move this dictation off the server.
      router.current.state = .pending
    }
    let entry = try await store.recent().first
    XCTAssertEqual(entry?.recognitionPath, .server)
    XCTAssertEqual(router.started.map(\.state), [.approved])
  }

  func testServerFailureWithALocalModelRecognizesTheWholeSpoolLocally() async throws {
    let store = try makeStore()
    let router = FakeRemoteRouter()
    router.flowd.behavior = .badWindow
    let loads = LoadCounter()
    let coordinator = try makeCoordinator(store: store, remote: router, loads: loads)
    try await dictate(coordinator)
    let entry = try await store.recent().first
    XCTAssertEqual(entry?.text, "local words")
    XCTAssertEqual(entry?.recognitionPath, .localAfterServerFailure)
    XCTAssertEqual(entry?.serverFailure, .protocolError)
    XCTAssertEqual(entry?.deliveryState, .confirmed)
    XCTAssertEqual(loads.loads, 1)
  }

  func testBusyFallsBackWithItsReason() async throws {
    let store = try makeStore()
    let router = FakeRemoteRouter()
    router.flowd.behavior = .startError("busy")
    let coordinator = try makeCoordinator(store: store, remote: router)
    try await dictate(coordinator)
    let entry = try await store.recent().first
    XCTAssertEqual(entry?.recognitionPath, .localAfterServerFailure)
    XCTAssertEqual(entry?.serverFailure, .busy)
  }

  func testWithoutALocalModelTheAudioWaitsForARetry() async throws {
    let store = try makeStore()
    let router = FakeRemoteRouter()
    router.provisioned = false
    router.flowd.behavior = .startError("worker_unavailable")
    let pendingDirectory = try makeSpoolRoot().appendingPathComponent("PendingAudio")
    directories.append(pendingDirectory.deletingLastPathComponent())
    let pending = try PendingRemoteDictationStore(
      database: store.database, directory: pendingDirectory)
    router.pendingStore = pending
    let insertion = FakeInsertion(store: store)
    let loads = LoadCounter()
    let coordinator = try makeCoordinator(
      store: store, remote: router, insertion: insertion, loads: loads)
    try await dictate(coordinator)
    let items = try await pending.all()
    XCTAssertEqual(items.count, 1)
    XCTAssertEqual(items.first?.sampleCount, 1_600)
    XCTAssertEqual(items.first?.lastFailure, .workerUnavailable)
    let file = pending.audioURL(try XCTUnwrap(items.first))
    XCTAssertEqual(try Data(contentsOf: file).count, 1_600 * 4)
    let rows = try await store.recent()
    XCTAssertTrue(rows.isEmpty)
    XCTAssertFalse(insertion.sawAttempting)
    XCTAssertEqual(loads.loads, 0)
    XCTAssertEqual(coordinator.state, .idle)
  }

  func testAFullRetryQueueAsksTheUser() async throws {
    let store = try makeStore()
    let router = FakeRemoteRouter()
    router.provisioned = false
    router.keepFails = true
    router.flowd.behavior = .startError("busy")
    let coordinator = try makeCoordinator(store: store, remote: router)
    try await dictate(coordinator)
    XCTAssertEqual(router.fullCalls, 1)
    let rows = try await store.recent()
    XCTAssertTrue(rows.isEmpty)
  }

  func testSwitchingRemoteOffMidDictationCompletesLocally() async throws {
    let store = try makeStore()
    let router = FakeRemoteRouter()
    let coordinator = try makeCoordinator(store: store, remote: router)
    try await dictate(coordinator) { router.current.enabled = false }
    let entry = try await store.recent().first
    // Switching off is the user's choice, not a server failure.
    XCTAssertEqual(entry?.text, "local words")
    XCTAssertEqual(entry?.recognitionPath, .local)
    XCTAssertNil(entry?.serverFailure)
  }

  func testUnapprovedDevicesDictateLocallyWithoutAFailureCode() async throws {
    for state in [RemoteDictationState.pending, .rejected, .revoked, .pinMismatch] {
      let store = try makeStore()
      let router = FakeRemoteRouter(state: state)
      let coordinator = try makeCoordinator(store: store, remote: router)
      try await dictate(coordinator)
      let entry = try await store.recent().first
      XCTAssertEqual(entry?.recognitionPath, .local, state.rawValue)
      XCTAssertNil(entry?.serverFailure, state.rawValue)
      XCTAssertEqual(router.sessionsMade, 0, state.rawValue)
      XCTAssertEqual(router.started.map(\.state), [state], state.rawValue)
    }
  }

  func testSleepAbandonsTheSessionAndRecognizesLocally() async throws {
    let store = try makeStore()
    let router = FakeRemoteRouter()
    let insertion = FakeInsertion(store: store)
    let coordinator = try makeCoordinator(
      store: store, remote: router,
      capture: FakeCapture(reason: .failure(.sleep), samples: Array(repeating: 0.1, count: 1_600)),
      insertion: insertion)
    coordinator.begin()
    try await waitUntil { !coordinator.busy }
    let entry = try await store.recent().first
    XCTAssertEqual(entry?.recognitionPath, .localAfterServerFailure)
    XCTAssertEqual(entry?.serverFailure, .unreachable)
    XCTAssertEqual(entry?.stopReason, .sleep)
    XCTAssertEqual(entry?.quality, .incomplete)
    XCTAssertFalse(insertion.sawAttempting)
  }

  func testTheDurationLimitBehavesAsLocally() async throws {
    let store = try makeStore()
    let router = FakeRemoteRouter()
    let coordinator = try makeCoordinator(
      store: store, remote: router,
      capture: FakeCapture(reason: .durationLimit, samples: Array(repeating: 0.1, count: 1_600)))
    coordinator.begin()
    try await waitUntil { !coordinator.busy }
    let entry = try await store.recent().first
    XCTAssertEqual(entry?.recognitionPath, .server)
    XCTAssertEqual(entry?.quality, .durationLimited)
    XCTAssertEqual(entry?.stopReason, .durationLimit)
  }
}

/// Feature 014 T086: the replay harness behind `scripts/remote-dictation-benchmark.sh`.
@MainActor
final class RemoteDictationReplayTests: XCTestCase {
  func testReplayMeasuresEveryModeAndFindsTranscriptDifferences() async throws {
    let root = try makeSpoolRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let recording = root.appendingPathComponent("clip.f32")
    let samples = (0..<260_000).map { Float($0 % 100) / 1_000 }
    try samples.withUnsafeBufferPointer { Data(buffer: $0) }.write(to: recording)
    let router = FakeRemoteRouter()
    let unreachable = FakeRemoteRouter()
    unreachable.flowd.behavior = .startError("busy")
    let lifecycle = ModelLifecycleCoordinator { FakeRuntime(text: "local words") }
    var configuration = RemoteDictationReplay.Configuration()
    configuration.recordings = [recording]
    configuration.runs = 2
    configuration.users = 2
    configuration.speed = 50
    let report = try await RemoteDictationReplay(
      router: router, lifecycle: lifecycle,
      transcriber: WindowedTranscriber(lifecycle: lifecycle), unreachable: unreachable
    ).run(configuration)
    let modes = Dictionary(grouping: report.rows, by: \.mode).mapValues(\.count)
    XCTAssertEqual(modes[.remote], 2)
    XCTAssertEqual(modes[.local], 2)
    XCTAssertEqual(modes[.fallback], 2)
    XCTAssertEqual(modes[.concurrent], 4)
    XCTAssertTrue(report.rows.filter { $0.mode == .remote }.allSatisfy { $0.failure == nil })
    XCTAssertTrue(report.rows.filter { $0.mode == .fallback }.allSatisfy { $0.failure == "busy" })
    XCTAssertEqual(report.rows.first { $0.mode == .fallback }?.text, "local words local words")
    XCTAssertTrue(report.rows.allSatisfy { $0.addedMilliseconds >= 0 && $0.samples == 260_000 })
    // The fake server's words differ from the fake local runtime's: reported, not hidden.
    XCTAssertEqual(report.transcriptDifferences, ["clip.f32 boost=false"])
    XCTAssertEqual(Set(report.summaries.map(\.mode)), [.remote, .local, .fallback, .concurrent])
  }

  func testPercentilesAreNearestRank() {
    let values = (1...20).map(Double.init)
    XCTAssertEqual(RemoteDictationReplay.percentile(values, 0.5), 10)
    XCTAssertEqual(RemoteDictationReplay.percentile(values, 0.95), 19)
    XCTAssertEqual(RemoteDictationReplay.percentile([7], 0.95), 7)
    XCTAssertEqual(RemoteDictationReplay.percentile([], 0.5), 0)
  }

  func testRecordingsReadFloatWAVAndRawSamples() throws {
    let root = try makeSpoolRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let raw = Data([0, 0, 128, 63, 0, 0, 0, 191])
    let wav = PendingRemoteDictationStore.wav(fromFloat32: raw)
    try wav.write(to: root.appendingPathComponent("a.wav"))
    try raw.write(to: root.appendingPathComponent("b.f32"))
    XCTAssertEqual(
      try RemoteDictationReplay.samples(root.appendingPathComponent("a.wav")), [1, -0.5])
    XCTAssertEqual(
      try RemoteDictationReplay.samples(root.appendingPathComponent("b.f32")), [1, -0.5])
  }
}
