import XCTest

@testable import LocalFlow

/// Starts retry sessions against the scripted flowd, or none while unreachable.
final class FakeRetryStarter: RemoteRetryStarting, @unchecked Sendable {
  let flowd = FakeFlowdDictation()
  let credentials = FakeSessionCredentials()
  private let lock = NSLock()
  var reachable = true
  private(set) var boosts: [RemoteBoost?] = []

  func makeRetrySession(
    boost: RemoteBoost?, read: @escaping RemoteDictationSession.SampleReader,
    recorded: @escaping RemoteDictationSession.SampleCounter
  ) async -> RemoteDictationSession? {
    lock.withLock { boosts.append(boost) }
    let flowd = flowd
    let reachable = lock.withLock { self.reachable }
    return RemoteDictationSession(
      configuration: .init(
        channelURL: URL(string: "wss://mini.example.com/v1/remote/channel")!,
        serverKey: FakeRemoteServer.serverKey.publicKey.rawRepresentation, boost: boost,
        threshold: .milliseconds(300), pumpInterval: .milliseconds(10)),
      transports: FakeRemoteTransportOpener { _ in reachable ? flowd.transport() : nil },
      credentials: credentials, clock: SystemRemoteClock(), read: read, recorded: recorded)
  }
}

final class MutableVocabulary: VocabularyProviding, @unchecked Sendable {
  private let lock = NSLock()
  private var value: VocabularySnapshot = .empty
  func set(_ snapshot: VocabularySnapshot) { lock.withLock { value = snapshot } }
  func snapshot() async throws -> VocabularySnapshot { lock.withLock { value } }
}

final class ManualWallClock: @unchecked Sendable {
  private let lock = NSLock()
  private var value: Int64 = 1_000_000
  var now: Int64 { lock.withLock { value } }
  func advance(_ milliseconds: Int64) { lock.withLock { value += milliseconds } }
}

final class RemoteRecoveryLog: @unchecked Sendable {
  private let lock = NSLock()
  private var entries: [TranscriptionEntry] = []
  private var decisions: [UUID] = []
  func recovered(_ entry: TranscriptionEntry) { lock.withLock { entries.append(entry) } }
  func decision(_ id: UUID) { lock.withLock { decisions.append(id) } }
  var recoveredEntries: [TranscriptionEntry] { lock.withLock { entries } }
  var decisionIDs: [UUID] { lock.withLock { decisions } }
}

final class PendingRemoteRetrierTests: XCTestCase {
  private var root: URL!
  private var history: TranscriptionStore!
  private var store: PendingRemoteDictationStore!
  private var starter: FakeRetryStarter!
  private var vocabulary: MutableVocabulary!
  private var clock: ManualWallClock!
  private var log: RemoteRecoveryLog!

  override func setUp() async throws {
    root = try makeSpoolRoot()
    history = try TranscriptionStore(path: root.appendingPathComponent("h.sqlite").path)
    store = try PendingRemoteDictationStore(
      database: history.database, directory: root.appendingPathComponent("PendingAudio"))
    starter = FakeRetryStarter()
    vocabulary = MutableVocabulary()
    clock = ManualWallClock()
    log = RemoteRecoveryLog()
  }

  override func tearDown() {
    try? FileManager.default.removeItem(at: root)
    super.tearDown()
  }

  private func retrier() async -> PendingRemoteRetrier {
    let clock = clock!
    let log = log!
    let retrier = PendingRemoteRetrier(
      store: store, history: history, vocabulary: vocabulary, starter: starter,
      transcriber: WindowedTranscriber(lifecycle: ModelLifecycleCoordinator { FakeRuntime() }),
      now: { clock.now })
    await retrier.setHandlers(
      recovered: { log.recovered($0) }, decisionNeeded: { log.decision($0.id) })
    return retrier
  }

  private func addPending(samples: Int = 1_600) async throws -> UUID {
    let file = root.appendingPathComponent("\(UUID().uuidString).f32")
    let values = (0..<samples).map { Float($0 % 100) / 100 }
    try values.withUnsafeBufferPointer { Data(buffer: $0) }.write(to: file)
    let id = UUID()
    _ = try await store.add(
      id: id, audio: file, sampleCount: samples, failure: .unreachable,
      targetBundleID: "com.example.editor", now: clock.now)
    return id
  }

  func testBackoffIsTenThirtySecondsTwoMinutesThenTenMinutes() {
    XCTAssertEqual(PendingRemoteDictationStore.firstRetryMilliseconds, 10_000)
    XCTAssertEqual(PendingRemoteRetrier.nextDelay(afterAttempts: 1), 30_000)
    XCTAssertEqual(PendingRemoteRetrier.nextDelay(afterAttempts: 2), 120_000)
    XCTAssertEqual(PendingRemoteRetrier.nextDelay(afterAttempts: 3), 600_000)
    XCTAssertEqual(PendingRemoteRetrier.nextDelay(afterAttempts: 9), 600_000)
  }

  func testRetriesFollowThePersistedScheduleAcrossARestart() async throws {
    let id = try await addPending()
    starter.reachable = false
    let first = await retrier()
    let early = await first.runDue()
    XCTAssertEqual(early, 0)
    var item = try await store.get(id)
    XCTAssertEqual(item?.attempts, 0)
    clock.advance(10_000)
    _ = await first.runDue()
    item = try await store.get(id)
    XCTAssertEqual(item?.attempts, 1)
    XCTAssertEqual(item?.nextAttemptAt, clock.now + 30_000)
    // A new retrier, as after a restart, reads the same schedule.
    let second = await retrier()
    clock.advance(29_000)
    _ = await second.runDue()
    item = try await store.get(id)
    XCTAssertEqual(item?.attempts, 1)
    clock.advance(1_000)
    _ = await second.runDue()
    item = try await store.get(id)
    XCTAssertEqual(item?.attempts, 2)
    XCTAssertEqual(item?.nextAttemptAt, clock.now + 120_000)
  }

  func testSuccessIsSavedForReviewWithPendingRetryAndNeverInserted() async throws {
    let id = try await addPending()
    let entries = [VocabularyEntry(id: "z", canonical: "Zabbix")]
    vocabulary.set(
      try VocabularySnapshot(
        revision: 2,
        hash: TranscriptionQualityDetail.hash(VocabularyValidation.serialize(entries)),
        entries: entries))
    clock.advance(10_000)
    let retrier = await retrier()
    let recovered = await retrier.runDue()
    XCTAssertEqual(recovered, 1)
    let entry = try await history.get(id)
    XCTAssertEqual(entry?.text, "window 0")
    XCTAssertEqual(entry?.recognitionPath, .server)
    XCTAssertEqual(entry?.serverFailure, .pendingRetry)
    XCTAssertEqual(entry?.recoveryState, .needsReview)
    XCTAssertEqual(entry?.deliveryState, .notAttempted)
    XCTAssertEqual(entry?.targetBundleID, "com.example.editor")
    XCTAssertEqual(log.recoveredEntries.map(\.id), [id])
    let remaining = try await store.all()
    XCTAssertTrue(remaining.isEmpty)
    // The Dictionary was read at retry time.
    XCTAssertEqual(starter.boosts.first??.terms.map(\.canonical), ["Zabbix"])
  }

  func testRowsOlderThanADayWaitForTheUserInsteadOfBeingDeleted() async throws {
    let id = try await addPending()
    starter.reachable = false
    let retrier = await retrier()
    clock.advance(PendingRemoteDictationStore.maximumAgeMilliseconds)
    _ = await retrier.runDue()
    _ = await retrier.runDue()
    XCTAssertEqual(log.decisionIDs, [id])
    let waiting = try await retrier.needingDecision()
    XCTAssertEqual(waiting.map(\.id), [id])
    let item = try await store.get(id)
    XCTAssertNotNil(item)
    XCTAssertTrue(FileManager.default.fileExists(atPath: store.audioURL(try XCTUnwrap(item)).path))
    XCTAssertEqual(starter.boosts.count, 0)
  }

  func testRecognizeLocallyUsesTheInstalledModel() async throws {
    let id = try await addPending()
    let retrier = await retrier()
    let lifecycle = ModelLifecycleCoordinator { FakeRuntime(text: "local retry") }
    let entry = try await retrier.recognizeLocally(
      id: id, lifecycle: lifecycle, local: WindowedTranscriber(lifecycle: lifecycle))
    XCTAssertEqual(entry?.text, "local retry")
    XCTAssertEqual(entry?.recognitionPath, .localAfterServerFailure)
    XCTAssertEqual(entry?.serverFailure, .unreachable)
    XCTAssertEqual(entry?.recoveryState, .needsReview)
    let remaining = try await store.all()
    XCTAssertTrue(remaining.isEmpty)
  }

  func testCopyWritesAPlayableWAV() async throws {
    let id = try await addPending(samples: 100)
    let destination = root.appendingPathComponent("copy.wav")
    try await store.exportWAV(id: id, to: destination)
    let data = try Data(contentsOf: destination)
    XCTAssertEqual(data.count, 44 + 400)
    XCTAssertEqual(data.prefix(4), Data("RIFF".utf8))
    XCTAssertEqual(data.subdata(in: 8..<12), Data("WAVE".utf8))
  }
}
