import ApplicationServices
import GRDB
import OSLog
import XCTest

@testable import LocalFlow

/// Feature 012 in the live dictation flow: capture beside recording (T019),
/// local context spelling (T025), consent and exclusions (T027) and content-free
/// logs and metrics (T028). Rewriting stays off with a transport that fails the
/// test if it is ever called.
@MainActor
final class DictationContextFlowTests: XCTestCase {
  private enum TestTimeout: Error { case expired }
  private var ownedDirectories: [URL] = []
  private var rigs: [RewriteRig] = []
  private var suites: [String] = []

  override func tearDown() async throws {
    let directories = await MainActor.run {
      for rig in rigs { rig.removeSuite() }
      rigs.removeAll()
      for suite in suites { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
      suites.removeAll()
      let result = ownedDirectories
      ownedDirectories.removeAll()
      return result
    }
    for directory in directories.reversed() { try? FileManager.default.removeItem(at: directory) }
  }

  // MARK: Rig

  private let enabled = ContextSettings(enabled: true)

  private func snapshot(before: String? = nil, title: String? = "Inbox") -> AppContextSnapshot {
    AppContextSnapshot.make(
      .init(
        appName: "Mail", appCategory: .email, fieldKind: .multiLine, windowTitle: title,
        beforeCursor: before))
  }

  private func makeStore() throws -> TranscriptionStore {
    let directory = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("LocalFlowStore-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    ownedDirectories.append(directory)
    return try TranscriptionStore(path: directory.appendingPathComponent("history.sqlite").path)
  }

  private func makePreferences() -> AppPreferences {
    let suite = "LocalFlow-context-flow-\(UUID())"
    suites.append(suite)
    return AppPreferences(defaults: UserDefaults(suiteName: suite)!)
  }

  private func makeCoordinator(
    store: TranscriptionStore, text: String = "hello", insertion: (any TextInserting)? = nil,
    reader: (any AppContextReading)?, settings: @escaping @MainActor () -> ContextSettings,
    vocabulary: (any VocabularyProviding)? = nil
  ) throws -> DictationCoordinator {
    let spoolRoot = try makeSpoolRoot()
    ownedDirectories.append(spoolRoot)
    let rig = RewriteRig(store: store)
    rigs.append(rig)
    return DictationCoordinator(
      store: store, lifecycle: ModelLifecycleCoordinator { FakeRuntime(text: text) },
      capture: FakeCapture(), insertion: insertion ?? FakeInsertion(store: store),
      spoolRoot: spoolRoot, vocabulary: vocabulary, rewriter: rig.coordinator,
      contextReader: reader, contextSettings: settings)
  }

  private func dictate(_ coordinator: DictationCoordinator) async throws {
    coordinator.begin()
    try await waitUntil { coordinator.state == .recording }
    coordinator.release()
    try await waitUntil { !coordinator.busy }
  }

  private func latest(_ store: TranscriptionStore) async throws
    -> (TranscriptionEntry, DictationContextRecord?)
  {
    let fetched = try await store.recent(limit: 1).first
    let entry = try XCTUnwrap(fetched)
    return (entry, try await store.context(for: entry.id))
  }

  private func contextRowCount(_ store: TranscriptionStore) async throws -> Int {
    try await store.database.read {
      try Int.fetchOne($0, sql: "SELECT count(*) FROM dictation_contexts") ?? -1
    }
  }

  private func waitUntil(_ predicate: @escaping @MainActor () -> Bool) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(5))
    while !predicate() {
      guard clock.now < deadline else {
        XCTFail("timed out")
        throw TestTimeout.expired
      }
      await Task.yield()
    }
  }

  // MARK: Capture beside recording (T019)

  /// SC-005 ordering: recording starts whatever the read takes; a read past the
  /// 250 ms deadline is recorded as `timed_out`.
  func testRecordingNeverWaitsForTheRead() async throws {
    for (delay, expected) in [
      (0, ContextOutcome.used), (200, .used), (600, .timedOut),
    ] {
      let store = try makeStore()
      let reader = FakeAppContextReader(
        defaultScript: .init(delay: .milliseconds(delay), snapshot: snapshot()))
      let coordinator = try makeCoordinator(
        store: store, reader: reader, settings: { self.enabled })
      coordinator.begin()
      try await waitUntil { coordinator.state == .recording }
      if delay > 0 { XCTAssertEqual(reader.finishedCount, 0, "delay \(delay)") }
      coordinator.release()
      try await waitUntil { !coordinator.busy }
      let (entry, context) = try await latest(store)
      XCTAssertEqual(context?.outcome, expected, "delay \(delay)")
      XCTAssertEqual(entry.text, "hello")
      XCTAssertEqual(reader.callCount, 1)
    }
  }

  /// The read uses the target captured at the press; nothing re-reads focus later.
  func testFocusChangeAfterThePressDoesNotChangeTheRead() async throws {
    let store = try makeStore()
    let insertion = SwitchingInsertion(store: store)
    let reader = FakeAppContextReader(defaultScript: .init(snapshot: snapshot()))
    let coordinator = try makeCoordinator(
      store: store, insertion: insertion, reader: reader, settings: { self.enabled })
    try await dictate(coordinator)
    XCTAssertEqual(insertion.captureCount, 1)
    XCTAssertEqual(reader.targets.map { $0?.bundleIdentifier }, ["press.bundle"])
  }

  func testCancellingTheDictationCancelsTheRead() async throws {
    let store = try makeStore()
    let reader = FakeAppContextReader(
      defaultScript: .init(delay: .milliseconds(600), snapshot: snapshot()))
    let coordinator = try makeCoordinator(store: store, reader: reader, settings: { self.enabled })
    coordinator.begin()
    try await waitUntil { coordinator.state == .recording }
    coordinator.cancel()
    try await waitUntil { !coordinator.busy }
    try await waitUntil { reader.cancelledCount + reader.finishedCount == 1 }
    XCTAssertEqual(reader.cancelledCount, 1)
  }

  func testDisabledContextMakesNoReadAndWritesAnOffRow() async throws {
    let store = try makeStore()
    let reader = FakeAppContextReader(failOnAnyCall: true)
    let coordinator = try makeCoordinator(store: store, reader: reader, settings: { .disabled })
    try await dictate(coordinator)
    XCTAssertEqual(reader.callCount, 0)
    let (_, context) = try await latest(store)
    XCTAssertEqual(context, DictationContextRecord(outcome: .off))
  }

  /// Every path that reaches commit writes exactly one row: inserted, not inserted.
  func testEveryCommittedDictationHasExactlyOneContextRow() async throws {
    let store = try makeStore()
    let insertion = FakeInsertion(store: store)
    let reader = FakeAppContextReader(defaultScript: .init(snapshot: snapshot()))
    let coordinator = try makeCoordinator(
      store: store, insertion: insertion, reader: reader, settings: { self.enabled })
    try await dictate(coordinator)
    insertion.outcome = .notInserted(.unsupported)
    try await dictate(coordinator)
    let entries = try await store.recent()
    XCTAssertEqual(entries.count, 2)
    let rows = try await contextRowCount(store)
    XCTAssertEqual(rows, 2)
    for entry in entries {
      let context = try await store.context(for: entry.id)
      XCTAssertEqual(context?.outcome, .used)
    }
  }

  // MARK: Context spelling in the flow (T025)

  func testContextSpellingWorksOfflineWithRewritingOff() async throws {
    let store = try makeStore()
    let insertion = FakeInsertion(store: store)
    let reader = FakeAppContextReader(
      defaultScript: .init(snapshot: snapshot(before: "Hi Miroslav Kováčik,")))
    var measured: [ContextMetrics] = []
    let coordinator = try makeCoordinator(
      store: store, text: "Thanks Kovacik for the update", insertion: insertion, reader: reader,
      settings: { self.enabled })
    coordinator.contextMeasured = { measured.append($0) }
    try await dictate(coordinator)
    let (entry, context) = try await latest(store)
    XCTAssertEqual(entry.text, "Thanks Kováčik for the update")
    XCTAssertEqual(insertion.insertedTexts, ["Thanks Kováčik for the update"])
    XCTAssertEqual(context?.preSpellingText, "Thanks Kovacik for the update")
    XCTAssertEqual(context?.spellerVersion, ContextSpeller.version)
    XCTAssertEqual(
      context?.spellingChanges,
      [
        ContextSpellingChange(
          original: "Kovacik", replacement: "Kováčik", sourcePart: .beforeCursor, start: 7,
          length: 7, match: .exactFold)
      ])
    let detail = try await store.qualityDetail(entry.id)
    XCTAssertEqual(detail?.normalizedHash, TranscriptionQualityDetail.hash(entry.text))
    XCTAssertEqual(measured.map(\.spellingChanges), [1])
    XCTAssertEqual(rigs.last?.callCount, 0)
  }

  /// Story 1.3: with context off the committed text is byte-identical to the
  /// Feature 002 path (no reader wired at all).
  func testContextOffTextIsByteIdenticalToTheFeature002Path() async throws {
    let spoken = "Thanks Kovacik for the update"
    var texts: [String] = []
    var hashes: [String?] = []
    for reader in [nil, FakeAppContextReader(failOnAnyCall: true)] as [FakeAppContextReader?] {
      let store = try makeStore()
      let coordinator = try makeCoordinator(
        store: store, text: spoken, reader: reader, settings: { .disabled })
      try await dictate(coordinator)
      let (entry, context) = try await latest(store)
      texts.append(entry.text)
      hashes.append(try await store.qualityDetail(entry.id)?.normalizedHash)
      XCTAssertNil(context?.preSpellingText)
    }
    XCTAssertEqual(Array(texts[0].utf8), Array(texts[1].utf8))
    XCTAssertEqual(texts[0], spoken)
    XCTAssertEqual(hashes[0], hashes[1])
  }

  /// FR-008: a term the dictionary governs is left to the dictionary.
  func testDictionaryTermsWinOverContext() async throws {
    let store = try makeStore()
    let vocabulary = VocabularyStore(history: store)
    try await vocabulary.save(VocabularyEntry(id: "nb", canonical: "Netbird", aliases: []))
    let reader = FakeAppContextReader(
      defaultScript: .init(snapshot: snapshot(before: "deploy NetBird now")))
    let coordinator = try makeCoordinator(
      store: store, text: "the netbird config", reader: reader, settings: { self.enabled },
      vocabulary: vocabulary)
    try await dictate(coordinator)
    let (entry, context) = try await latest(store)
    XCTAssertEqual(entry.text, "the Netbird config")
    XCTAssertNil(context?.preSpellingText)
  }

  // MARK: Consent and exclusions (T027)

  /// Story 3.1: a fresh or upgraded profile captures nothing until enabled.
  func testFreshAndUpgradedProfilesCaptureNothing() async throws {
    for upgraded in [false, true] {
      let preferences = makePreferences()
      if upgraded { preferences.rewriteEnabled = false }
      let store = try makeStore()
      let reader = FakeAppContextReader(failOnAnyCall: true)
      let coordinator = try makeCoordinator(
        store: store, reader: reader, settings: { preferences.contextSettings() })
      try await dictate(coordinator)
      XCTAssertEqual(reader.callCount, 0)
      let (_, context) = try await latest(store)
      XCTAssertEqual(context?.outcome, .off)
    }
  }

  /// Story 3.2: an excluded app yields `excluded_app` with no text read.
  func testExcludedAppRecordsTheOutcomeWithoutText() async throws {
    let preferences = makePreferences()
    preferences.contextEnabled = true
    preferences.addContextExclusion("test.bundle")
    let source = ScriptedAttributeSource()
    source.text = "private text"
    let store = try makeStore()
    let coordinator = try makeCoordinator(
      store: store, reader: SystemAppContextReader(source: source),
      settings: { preferences.contextSettings() })
    try await dictate(coordinator)
    let (_, context) = try await latest(store)
    XCTAssertEqual(context?.outcome, .excludedApp)
    XCTAssertNil(context?.snapshotJSON)
    XCTAssertEqual(context?.appBundleID, "test.bundle")
    XCTAssertEqual(source.calls, ["trusted"])
  }

  /// Story 3.3: a secure field yields `secure_field`.
  func testSecureFieldRecordsTheOutcomeWithoutText() async throws {
    let source = ScriptedAttributeSource()
    source.subroleValue = "AXSecureTextField"
    source.text = "hunter2"
    let store = try makeStore()
    let coordinator = try makeCoordinator(
      store: store, reader: SystemAppContextReader(source: source), settings: { self.enabled })
    try await dictate(coordinator)
    let (_, context) = try await latest(store)
    XCTAssertEqual(context?.outcome, .secureField)
    XCTAssertNil(context?.snapshotJSON)
    XCTAssertFalse(source.calls.contains { $0.hasPrefix("string") })
  }

  /// FR-017: turning context off applies to the next dictation.
  func testTurningContextOffAppliesToTheNextDictation() async throws {
    let preferences = makePreferences()
    preferences.contextEnabled = true
    let store = try makeStore()
    let reader = FakeAppContextReader(defaultScript: .init(snapshot: snapshot()))
    let coordinator = try makeCoordinator(
      store: store, reader: reader, settings: { preferences.contextSettings() })
    try await dictate(coordinator)
    XCTAssertEqual(reader.callCount, 1)
    preferences.contextEnabled = false
    try await dictate(coordinator)
    XCTAssertEqual(reader.callCount, 1)
    let (_, context) = try await latest(store)
    XCTAssertEqual(context?.outcome, .off)
  }

  // MARK: Privacy (T028)

  /// FR-016: sentinels in every snapshot part and the bundle ID never reach the
  /// process log or the metric sink.
  func testSnapshotTextNeverReachesLogsOrMetrics() async throws {
    let started = Date()
    let sentinels = ["Xylophqa", "Brontevik", "Clarimund", "Dervaloq", "com.sentinel.zq"]
    let source = ScriptedAttributeSource()
    source.title = "Xylophqa planning"
    source.text = "met Brontevik today, Clarimund Dervaloq"
    let prefix = ("met Brontevik today, " as NSString).length
    let target = CapturedTarget(
      processIdentifier: 1, launchDate: Date(), bundleIdentifier: "com.sentinel.zq",
      element: AXUIElementCreateSystemWide(), focusedWindow: AXUIElementCreateSystemWide(),
      selectedRange: CFRange(location: prefix, length: 9), comparisonContext: "")
    let store = try makeStore()
    let recording = try RecorderCapture.make()
    defer { try? FileManager.default.removeItem(at: recording.directory) }
    let coordinator = try makeCoordinator(
      store: store, text: "ask Brontevic now", insertion: FixedTargetInsertion(target: target),
      reader: SystemAppContextReader(source: source), settings: { self.enabled })
    coordinator.contextMeasured = { recording.recorder.record(context: $0) }
    try await dictate(coordinator)
    let (entry, context) = try await latest(store)
    XCTAssertEqual(entry.text, "ask Brontevik now", "the spelling pass ran")
    XCTAssertEqual(context?.snapshot?.selectedText, "Clarimund")
    XCTAssertEqual(context?.snapshot?.afterCursor, " Dervaloq")

    let samples = try await recording.samples()
    XCTAssertFalse(samples.isEmpty)
    let metricText = try samples.map {
      String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self)
    }.joined(separator: "\n")
    let logStore = try OSLogStore(scope: .currentProcessIdentifier)
    let logText = try logStore.getEntries(at: logStore.position(date: started))
      .compactMap { ($0 as? OSLogEntryLog)?.composedMessage }.joined(separator: "\n")
    XCTAssertTrue(logText.contains("Capture stopped"), "the log sink returned this run")
    for sentinel in sentinels {
      XCTAssertFalse(metricText.contains(sentinel), "metrics contain \(sentinel)")
      XCTAssertFalse(logText.contains(sentinel), "log contains \(sentinel)")
    }
  }
}

/// Returns one target at the press and another afterwards, counting calls.
private final class SwitchingInsertion: TextInserting, @unchecked Sendable {
  private let inner: FakeInsertion
  private let lock = NSLock()
  private var calls = 0
  init(store: TranscriptionStore) { inner = FakeInsertion(store: store) }
  var captureCount: Int { lock.withLock { calls } }
  func captureTarget() async -> CapturedTarget? {
    let first = lock.withLock {
      calls += 1
      return calls == 1
    }
    return makeContextTarget(bundleID: first ? "press.bundle" : "later.bundle")
  }
  func insertOnce(attemptID: UUID, target: CapturedTarget, text: String) async -> InsertionOutcome {
    await inner.insertOnce(attemptID: attemptID, target: target, text: text)
  }
}

private final class FixedTargetInsertion: TextInserting, @unchecked Sendable {
  let target: CapturedTarget
  init(target: CapturedTarget) { self.target = target }
  func captureTarget() async -> CapturedTarget? { target }
  func insertOnce(attemptID: UUID, target: CapturedTarget, text: String) async -> InsertionOutcome {
    .confirmed
  }
}
