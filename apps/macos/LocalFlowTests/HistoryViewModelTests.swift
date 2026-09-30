import Foundation
import XCTest

@testable import LocalFlow
@testable import LocalFlowSpeech

@MainActor
final class HistoryViewModelTests: XCTestCase {
  private var ownedRoots: [URL] = []

  override func tearDown() async throws {
    for root in ownedRoots.reversed() { try? FileManager.default.removeItem(at: root) }
    ownedRoots.removeAll()
  }

  private func waitForQuery(_ model: HistoryViewModel) async throws {
    for _ in 0..<200 {
      if !model.isLoading { return }
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTFail("History query did not settle")
  }

  // MARK: Feature 014 (T078)

  func testPathLabels() throws {
    func entry(_ path: TranscriptionEntry.RecognitionPath, _ failure: RemoteFailureReason?) throws
      -> TranscriptionEntry
    {
      try TranscriptionEntry(
        id: UUID(), text: "x", createdAtMilliseconds: 1, quality: .complete,
        stopReason: .keyRelease, recognitionPath: path, serverFailure: failure)
    }
    XCTAssertEqual(
      HistoryViewModel.pathLabel(for: try entry(.server, nil), showsLocal: false), "Server")
    XCTAssertEqual(
      HistoryViewModel.pathLabel(for: try entry(.server, .pendingRetry), showsLocal: false),
      "Server")
    XCTAssertNil(HistoryViewModel.pathLabel(for: try entry(.local, nil), showsLocal: false))
    XCTAssertEqual(
      HistoryViewModel.pathLabel(for: try entry(.local, nil), showsLocal: true), "Local")
    XCTAssertEqual(
      HistoryViewModel.pathLabel(
        for: try entry(.localAfterServerFailure, .unreachable), showsLocal: false),
      "Local after server failure (unreachable)")
    XCTAssertEqual(
      HistoryViewModel.pathLabel(for: try entry(.localAfterServerFailure, .busy), showsLocal: true),
      "Local after server failure (busy)")
    for reason in RemoteFailureReason.allCases { XCTAssertFalse(reason.label.isEmpty) }
  }

  func testWaitingForServerRowsAndTheirActions() async throws {
    let root = try makeSpoolRoot()
    ownedRoots.append(root)
    let store = try TranscriptionStore(path: root.appendingPathComponent("h.sqlite").path)
    let pending = try PendingRemoteDictationStore(
      database: store.database, directory: root.appendingPathComponent("PendingAudio"))
    var ids: [UUID] = []
    for _ in 0..<2 {
      let file = root.appendingPathComponent("\(UUID().uuidString).f32")
      try Data(count: 64_000).write(to: file)
      let id = UUID()
      ids.append(id)
      _ = try await pending.add(
        id: id, audio: file, sampleCount: 16_000, failure: .unreachable, targetBundleID: nil,
        now: Int64(Date().timeIntervalSince1970 * 1_000))
    }
    var recognized: [UUID] = []
    var provisioned = false
    let model = HistoryViewModel(store: store)
    model.pendingRemote = .init(
      load: { (try? await pending.all()) ?? [] },
      recognizeLocally: { id in
        recognized.append(id)
        try await pending.remove(id: id)
      },
      export: { id, url in try await pending.exportWAV(id: id, to: url) },
      discard: { id in try await pending.remove(id: id) },
      localModelProvisioned: { provisioned })
    await model.refreshPending()
    XCTAssertEqual(model.pendingItems.map(\.id), ids)
    XCTAssertEqual(HistoryViewModel.pendingStatus(model.pendingItems[0]), "Waiting for server")
    XCTAssertFalse(model.canRecognizePendingLocally)
    provisioned = true
    XCTAssertTrue(model.canRecognizePendingLocally)
    let copy = root.appendingPathComponent("copy.wav")
    await model.exportPending(ids[0], to: copy)
    XCTAssertTrue(FileManager.default.fileExists(atPath: copy.path))
    XCTAssertEqual(model.pendingItems.count, 2)
    await model.recognizePendingLocally(ids[0])
    XCTAssertEqual(recognized, [ids[0]])
    XCTAssertEqual(model.pendingItems.map(\.id), [ids[1]])
    await model.discardPending(ids[1])
    XCTAssertTrue(model.pendingItems.isEmpty)
    XCTAssertNil(model.pendingError)
    let old = PendingRemoteDictationStore.Item(
      id: UUID(), audioFile: "a.f32", sampleCount: 1, createdAt: 0, attempts: 3,
      nextAttemptAt: .max, lastFailure: .timeout, targetBundleID: nil)
    XCTAssertEqual(HistoryViewModel.pendingStatus(old), "Retries stopped after 24 hours")
  }

  func testReplacementSearchAndBoundedNavigation() async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
      "history-vm-\(UUID()).sqlite")
    defer { removeDatabase(at: url) }
    let store = try TranscriptionStore(path: url.path)
    for index in 0..<65 {
      let entry = try TranscriptionEntry(
        id: UUID(), text: "full multiline\ntext \(index)",
        createdAtMilliseconds: Int64(index), quality: .complete, stopReason: .keyRelease)
      _ = try await store.commit(reservation: try await store.reserve(), entry: entry)
    }
    let model = HistoryViewModel(store: store)
    model.refresh()
    try await waitForQuery(model)
    let firstIDs = model.entries.map(\.id)
    XCTAssertEqual(firstIDs.count, 20)
    // Scrolling down joins older pages below the ones already loaded.
    for _ in 0..<3 {
      model.loadOlder()
      try await waitForQuery(model)
    }
    XCTAssertEqual(model.entries.count, 65)
    XCTAssertEqual(Array(model.entries.prefix(20).map(\.id)), firstIDs)
    XCTAssertEqual(model.entries.last?.text, "full multiline\ntext 0")
    XCTAssertFalse(model.hasOlder)
    XCTAssertFalse(model.hasNewer)
    XCTAssertLessThanOrEqual(model.residentTextBytes, 65 * 65_536)
    let selected = try XCTUnwrap(model.entries.first)
    model.selectedEntry = selected
    model.searchText = "text 1"
    model.searchText = "text 2"
    model.searchText = "text 0"
    try await waitForQuery(model)
    XCTAssertEqual(model.entries.map(\.text), ["full multiline\ntext 0"])
    XCTAssertEqual(
      model.selectedEntry, selected,
      "A pending query must preserve the deletion confirmation target")
    model.searchText = "no such text"
    try await waitForQuery(model)
    XCTAssertTrue(model.isNoMatches)
  }

  /// T026 (SC-001): browsing history never reaches the rewrite transport. The
  /// history-side rewrite affordances themselves arrive in US5.
  func testHistoryBrowsingNeverCallsTheRewriteTransport() async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
      "history-rewrite-guard-\(UUID()).sqlite")
    defer { removeDatabase(at: url) }
    let store = try TranscriptionStore(path: url.path)
    let rig = RewriteRig(store: store, enabled: true, failOnAnyCall: true)
    defer { rig.removeSuite() }
    for index in 0..<3 {
      let entry = try TranscriptionEntry(
        id: UUID(), text: "text \(index)", createdAtMilliseconds: Int64(index),
        quality: .complete, stopReason: .keyRelease)
      _ = try await store.commit(reservation: try await store.reserve(), entry: entry)
    }
    let model = HistoryViewModel(store: store)
    model.refresh()
    try await waitForQuery(model)
    model.selectedEntry = model.entries.first
    model.searchText = "text"
    try await waitForQuery(model)
    XCTAssertEqual(model.entries.count, 3)
    XCTAssertEqual(rig.callCount, 0)
    XCTAssertTrue(model.entries.allSatisfy { $0.rewriteState == .notRequested })
  }

  func testIndependentBadgesAndCalendarRegrouping() async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
      "history-date-\(UUID()).sqlite")
    defer { removeDatabase(at: url) }
    let store = try TranscriptionStore(path: url.path)
    let date = Date(timeIntervalSince1970: 1_800_000_000)
    let entry = try TranscriptionEntry(
      id: UUID(), text: "Partial text",
      createdAtMilliseconds: Int64(date.timeIntervalSince1970 * 1000), quality: .durationLimited,
      stopReason: .durationLimit)
    let saved = try await store.commit(reservation: try await store.reserve(), entry: entry)
    let dismissed = try await store.dismissRecovery(id: saved.id, revision: saved.revision)
    XCTAssertEqual(saved.qualityLabel, "Cut short at 180 seconds")
    XCTAssertEqual(dismissed.qualityLabel, saved.qualityLabel)
    let attempt = try await store.beginAttempt(id: saved.id, revision: dismissed.revision)
    let uncertain = try await store.recordOutcome(
      id: saved.id, revision: attempt.entry.revision,
      attemptID: attempt.id, outcome: .uncertain)
    let resolvedUncertain = try await store.dismissRecovery(
      id: saved.id, revision: uncertain.revision)
    XCTAssertEqual(resolvedUncertain.deliveryState, .uncertain)
    XCTAssertEqual(resolvedUncertain.qualityLabel, saved.qualityLabel)
    let model = HistoryViewModel(store: store)
    model.refresh()
    try await waitForQuery(model)
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    model.regroup(calendar: calendar, now: date)
    XCTAssertEqual(model.dateGroups.first?.title, "Today")
    model.regroup(calendar: calendar, now: date.addingTimeInterval(86400))
    XCTAssertEqual(model.dateGroups.first?.title, "Yesterday")
    // Older days read in English whatever the system locale.
    model.regroup(calendar: calendar, now: date.addingTimeInterval(3 * 86400))
    let expected = EnglishDateFormat.formatter(
      "d MMMM yyyy", timeZone: calendar.timeZone, calendar: calendar
    ).string(from: date)
    XCTAssertEqual(model.dateGroups.first?.title, expected)
    var english = Calendar(identifier: .gregorian)
    english.locale = Locale(identifier: "en_GB")
    let months = english.monthSymbols.joined(separator: "|")
    XCTAssertEqual(EnglishDateFormat.locale.identifier, "en_US_POSIX")
    XCTAssertNotNil(
      expected.range(of: #"^\d{1,2} ("# + months + #") \d{4}$"#, options: .regularExpression),
      expected)
    calendar.timeZone = TimeZone(secondsFromGMT: -12 * 3600)!
    model.regroup(calendar: calendar, now: date)
    XCTAssertEqual(model.dateGroups.first?.id, calendar.startOfDay(for: date))
    model.selectedEntry = saved
    model.reportActionError()
    XCTAssertEqual(model.entries.first?.id, saved.id)
    XCTAssertNotNil(model.errorMessage)
  }

  /// Row actions never silently drop history. A stale revision, a failure and a
  /// busy insertion must each leave the visible rows and their status intact.
  func testDeleteRejectsStaleRevisionAndBusyInsertionWithoutLosingRows() async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
      "history-delete-\(UUID()).sqlite")
    defer { removeDatabase(at: url) }
    let store = try TranscriptionStore(path: url.path)
    let entry = try TranscriptionEntry(
      id: UUID(), text: "keep this text",
      createdAtMilliseconds: Int64(Date().timeIntervalSince1970 * 1000),
      quality: .durationLimited, stopReason: .durationLimit)
    let saved = try await store.commit(reservation: try await store.reserve(), entry: entry)
    let dismissed = try await store.dismissRecovery(id: saved.id, revision: saved.revision)
    let coordinator = makeCoordinator(store: store)
    let model = HistoryViewModel(store: store)
    model.refresh()
    try await waitForQuery(model)
    XCTAssertEqual(model.entries.count, 1)

    // The pre-dismissal revision is stale; deleting with it must be rejected.
    do {
      try await coordinator.deleteOrThrow(saved)
      XCTFail("A stale revision must not delete a row")
    } catch { XCTAssertNotNil(error) }
    var rows = try await store.recent(limit: 20)
    XCTAssertEqual(rows.count, 1, "A rejected delete must preserve the row")

    // An active explicit insertion owns the coordinator; deletion must wait.
    let explicit = ExplicitInsertionCoordinator(
      store: store, insertion: FakeInsertion(), dictation: coordinator, presentsPanel: false)
    XCTAssertTrue(explicit.beginReview(dismissed))
    do {
      try await coordinator.deleteOrThrow(dismissed)
      XCTFail("Deletion must not run during an insertion")
    } catch { XCTAssertEqual(error as? TranscriptionStore.Error, .busy) }
    explicit.cancel()
    rows = try await store.recent(limit: 20)
    XCTAssertEqual(rows.count, 1)
    XCTAssertEqual(rows.first?.quality, .durationLimited, "A blocked delete preserves quality")

    // Only the confirmed current revision removes exactly the selected row.
    model.selectedEntry = dismissed
    try await coordinator.deleteOrThrow(dismissed)
    rows = try await store.recent(limit: 20)
    XCTAssertTrue(rows.isEmpty)
    model.refresh()
    try await waitForQuery(model)
    XCTAssertTrue(model.entries.isEmpty)
  }

  /// Copy is clipboard-only and Dismiss resolves review only. Neither may change
  /// the recorded quality or delivery status of the row they act on.
  func testCopyAndDismissPreserveQualityAndDeliveryStatus() async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
      "history-status-\(UUID()).sqlite")
    defer { removeDatabase(at: url) }
    let store = try TranscriptionStore(path: url.path)
    let entry = try TranscriptionEntry(
      id: UUID(), text: "status text",
      createdAtMilliseconds: Int64(Date().timeIntervalSince1970 * 1000),
      quality: .incomplete, stopReason: .overflow)
    let saved = try await store.commit(reservation: try await store.reserve(), entry: entry)
    let attempt = try await store.beginAttempt(id: saved.id, revision: saved.revision)
    let uncertain = try await store.recordOutcome(
      id: saved.id, revision: attempt.entry.revision, attemptID: attempt.id, outcome: .uncertain)
    let coordinator = makeCoordinator(store: store)

    coordinator.copy(uncertain.text)
    let copied = try await store.get(saved.id)
    let afterCopy = try XCTUnwrap(copied)
    XCTAssertEqual(afterCopy.revision, uncertain.revision, "Copy must not write to the database")
    XCTAssertEqual(afterCopy.deliveryState, .uncertain)
    XCTAssertEqual(afterCopy.recoveryState, .needsReview)

    try await coordinator.dismissOrThrow(uncertain)
    let dismissedRow = try await store.get(saved.id)
    let afterDismiss = try XCTUnwrap(dismissedRow)
    XCTAssertEqual(afterDismiss.recoveryState, .resolved)
    XCTAssertEqual(afterDismiss.deliveryState, .uncertain, "Dismissal is not a delivery claim")
    XCTAssertEqual(afterDismiss.quality, .incomplete, "Dismissal preserves recorded quality")
    XCTAssertEqual(afterDismiss.text, saved.text)
  }

  /// Residency stays bounded even with a selected row held outside the page.
  func testResidentPagesAndSelectedRowStayBounded() async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
      "history-residency-\(UUID()).sqlite")
    defer { removeDatabase(at: url) }
    let store = try TranscriptionStore(path: url.path)
    let text = String(repeating: "a", count: 4_000)
    for index in 0..<60 {
      let entry = try TranscriptionEntry(
        id: UUID(), text: "\(text) \(index)", createdAtMilliseconds: Int64(index),
        quality: .complete, stopReason: .keyRelease)
      _ = try await store.commit(reservation: try await store.reserve(), entry: entry)
    }
    let model = HistoryViewModel(store: store)
    model.refresh()
    try await waitForQuery(model)
    model.selectedEntry = model.entries.first
    for _ in 0..<3 {
      model.loadOlder()
      try await waitForQuery(model)
      XCTAssertLessThanOrEqual(model.entries.count, HistoryViewModel.residentLimit)
      let selectedBytes = model.selectedEntry?.text.utf8.count ?? 0
      XCTAssertLessThanOrEqual(selectedBytes, 65_536)
      XCTAssertLessThanOrEqual(
        model.residentTextBytes + selectedBytes,
        HistoryViewModel.residentLimit * 65_536 + 65_536,
        "Page text plus the selected row must stay inside the resident bound")
    }
  }

  /// Scrolling far lets go of the newest rows and scrolling back brings them again.
  func testScrollWindowSlidesBothWaysWithinTheResidentLimit() async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
      "history-window-\(UUID()).sqlite")
    defer { removeDatabase(at: url) }
    let store = try TranscriptionStore(path: url.path)
    let total = HistoryViewModel.residentLimit + 50
    for index in 0..<total {
      let entry = try TranscriptionEntry(
        id: UUID(), text: "row \(index)", createdAtMilliseconds: Int64(index),
        quality: .complete, stopReason: .keyRelease)
      _ = try await store.commit(reservation: try await store.reserve(), entry: entry)
    }
    let model = HistoryViewModel(store: store)
    model.refresh()
    try await waitForQuery(model)
    while model.hasOlder {
      model.loadOlder()
      try await waitForQuery(model)
      XCTAssertLessThanOrEqual(model.entries.count, HistoryViewModel.residentLimit)
    }
    XCTAssertEqual(model.entries.last?.text, "row 0")
    XCTAssertTrue(model.hasNewer)
    while model.hasNewer {
      model.loadNewer()
      try await waitForQuery(model)
      XCTAssertLessThanOrEqual(model.entries.count, HistoryViewModel.residentLimit)
    }
    XCTAssertEqual(model.entries.first?.text, "row \(total - 1)")
    XCTAssertTrue(model.hasOlder)
    // Rows stay newest first and unique across both slides.
    let texts = model.entries.map(\.text)
    XCTAssertEqual(Set(texts).count, texts.count)
    XCTAssertEqual(texts, (0..<texts.count).map { "row \(total - 1 - $0)" })
  }

  func testSelectedDetailReplacementCloseAndDeletion() async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
      "detail-vm-\(UUID()).sqlite")
    defer { removeDatabase(at: url) }
    let store = try TranscriptionStore(path: url.path)
    let first = try makeQualityEnvelope(raw: "raw first", text: "First")
    let second = try makeQualityEnvelope(raw: "raw second", text: "Second")
    let a = try await store.commit(reservation: try await store.reserve(), envelope: first)
    let b = try await store.commit(reservation: try await store.reserve(), envelope: second)
    let gate = DetailLoadGate(store: store)
    let model = HistoryViewModel(store: store, detailLoader: { id in try await gate.load(id) })
    model.showDetail(a)
    while await gate.startedCount == 0 { await Task.yield() }
    model.showDetail(b)
    XCTAssertNil(model.detailEnvelope)
    XCTAssertEqual(model.detailEntryID, b.id)
    await gate.release()
    try await waitForDetail(model)
    XCTAssertEqual(model.detailEnvelope?.entry.id, b.id)
    XCTAssertEqual(model.detailEnvelope?.detail?.rawWindows.first?.text, "raw second")
    let peak = await gate.peak
    XCTAssertEqual(peak, 1, "Replacement must join the cancelled load before starting another")
    model.clearDetail()
    XCTAssertNil(model.detailEnvelope)
    XCTAssertNil(model.detailEntryID)
    model.showDetail(a)
    try await waitForDetail(model)
    try await store.deleteConfirmed(id: a.id, revision: a.revision)
    model.didDelete(a.id)
    XCTAssertNil(model.detailEnvelope)
    XCTAssertNil(model.detailEntryID)
  }

  func testLegacyDetailAndCloseDuringLoad() async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
      "legacy-vm-\(UUID()).sqlite")
    defer { removeDatabase(at: url) }
    let store = try TranscriptionStore(path: url.path)
    let entry = try TranscriptionEntry(
      id: UUID(), text: "legacy", createdAtMilliseconds: 1,
      quality: .complete, stopReason: .keyRelease)
    let saved = try await store.commit(reservation: try await store.reserve(), entry: entry)
    let model = HistoryViewModel(store: store)
    model.showDetail(saved)
    try await waitForDetail(model)
    XCTAssertEqual(model.detailEnvelope?.entry.text, "legacy")
    XCTAssertNil(model.detailEnvelope?.detail)
    let gate = DetailLoadGate(store: store)
    let delayed = HistoryViewModel(store: store, detailLoader: { id in try await gate.load(id) })
    delayed.showDetail(saved)
    while await gate.startedCount == 0 { await Task.yield() }
    delayed.clearDetail()
    await gate.release()
    for _ in 0..<20 { await Task.yield() }
    XCTAssertNil(delayed.detailEnvelope)
    XCTAssertNil(delayed.detailEntryID)
    XCTAssertNil(delayed.detailError)
  }

  func testRefreshUpdatesDeliveryWithoutReprocessingAndClearsExternalDeletion() async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
      "detail-refresh-\(UUID()).sqlite")
    defer { removeDatabase(at: url) }
    let store = try TranscriptionStore(path: url.path)
    let source = try makeQualityEnvelope(text: " preserved  historical spacing ")
    let saved = try await store.commit(reservation: try await store.reserve(), envelope: source)
    let model = HistoryViewModel(store: store)
    model.showDetail(saved)
    try await waitForDetail(model)
    let dismissed = try await store.dismissRecovery(id: saved.id, revision: saved.revision)
    model.refresh()
    try await waitForDetail(model)
    XCTAssertEqual(model.detailEnvelope?.entry.recoveryState, .resolved)
    XCTAssertEqual(model.detailEnvelope?.entry.text, source.entry.text)
    XCTAssertEqual(model.detailEnvelope?.detail?.contentHash, source.detail?.contentHash)
    try await store.deleteConfirmed(id: dismissed.id, revision: dismissed.revision)
    model.refresh()
    try await waitForDetail(model)
    XCTAssertNil(model.detailEnvelope)
    XCTAssertNil(model.detailEntryID)
  }

  private func waitForDetail(_ model: HistoryViewModel) async throws {
    for _ in 0..<200 {
      if !model.isDetailLoading { return }
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTFail("Detail load did not settle")
  }

  /// Feature 012, Story 2.4 and 2.5: whether the latest attempt carried the snapshot.
  func testContextRewriteLineNamesUnsupportedSentAndCopied() {
    func attempt(hash: String?, category: RewriteFailureCategory?) -> RewriteAttempt {
      RewriteAttempt(
        id: UUID(), transcriptionID: UUID(), ordinal: 1, mode: .clean,
        state: category == nil ? .succeeded : .failed, inputText: "x", inputHash: "h",
        outputText: nil, outputHash: nil, unchanged: false, failureCategory: category,
        stale: false, startedAtMilliseconds: 0, spans: .none, serverQueueMilliseconds: nil,
        backendFirstTokenMilliseconds: nil, backendMilliseconds: nil,
        protocolVersion: hash == nil ? 1 : 2, identity: .unknown, endpointOrigin: "o",
        insecureOverride: false, delivered: false, contextHash: hash)
    }
    let hash = String(repeating: "a", count: 64)
    var unsupported = DictationContextRecord(outcome: .used, snapshotJSON: "{}")
    unsupported.rewriteNote = DictationContextRecord.serverUnsupported
    XCTAssertEqual(
      HistoryViewModel.contextRewriteLine(unsupported, latest: attempt(hash: nil, category: nil)),
      "Context not sent: server unsupported")
    XCTAssertEqual(
      HistoryViewModel.contextRewriteLine(.off, latest: attempt(hash: hash, category: nil)),
      "Context sent to the rewrite server")
    XCTAssertEqual(
      HistoryViewModel.contextRewriteLine(
        .off, latest: attempt(hash: hash, category: .contextCopied)),
      "Rewrite used on-screen text you did not say; inserted your transcript.")
    XCTAssertNil(
      HistoryViewModel.contextRewriteLine(.off, latest: attempt(hash: nil, category: nil)))
    XCTAssertNil(HistoryViewModel.contextRewriteLine(nil, latest: nil))
  }

  /// Feature 012 (SC-007, Story 1.4, Story 3.4).
  func testContextOutcomeLabelsAndSpellingChanges() async throws {
    let labels = ContextOutcome.allCases.map {
      HistoryViewModel.contextLabel(DictationContextRecord(outcome: $0))
    }
    XCTAssertEqual(Set(labels).count, ContextOutcome.allCases.count)
    XCTAssertEqual(HistoryViewModel.contextLabel(.off), "Context: off")
    XCTAssertEqual(
      HistoryViewModel.contextLabel(DictationContextRecord(outcome: .noPermission)),
      "Context unavailable: permission")
    XCTAssertEqual(HistoryViewModel.contextLabel(nil), "Context: not recorded")

    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
      "context-vm-\(UUID()).sqlite")
    defer { removeDatabase(at: url) }
    let store = try TranscriptionStore(path: url.path)
    let snapshot = AppContextSnapshot.make(
      .init(appName: "Slack", beforeCursor: "Ask Miroslav Kováčik "))
    let change = ContextSpellingChange(
      original: "Kovacik", replacement: "Kováčik", sourcePart: .beforeCursor, start: 4,
      length: 7, match: .exactFold)
    let entry = try TranscriptionEntry(
      id: UUID(), text: "ask Kováčik", createdAtMilliseconds: 1, quality: .complete,
      stopReason: .keyRelease)
    let context = DictationContextRecord(
      outcome: .used, captureMs: 12, appBundleID: "com.tinyspeck.slackmacgap",
      snapshotJSON: snapshot.canonicalString, preSpellingText: "ask Kovacik",
      spellingChangesJSON: String(decoding: try JSONEncoder().encode([change]), as: UTF8.self),
      spellerVersion: ContextSpeller.version)
    let saved = try await store.commit(
      reservation: try await store.reserve(),
      envelope: TranscriptionEnvelope(entry: entry, detail: nil, context: context))
    let model = HistoryViewModel(store: store)
    model.showDetail(saved)
    try await waitForDetail(model)
    XCTAssertEqual(model.contextLabel, "Context: used")
    XCTAssertEqual(model.contextSpellingChanges, [change])
    XCTAssertEqual(model.contextPreSpellingText, "ask Kovacik")
    XCTAssertEqual(model.contextSnapshot, snapshot)
    XCTAssertEqual(change.sourcePart.historyLabel, "Text before the cursor")
  }

  private func makeCoordinator(store: TranscriptionStore) -> DictationCoordinator {
    let root = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("LocalFlowHistoryVM-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(
      at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    ownedRoots.append(root)
    return DictationCoordinator(
      store: store, lifecycle: ModelLifecycleCoordinator { FakeRuntime() },
      capture: FakeCapture(), insertion: FakeInsertion(), spoolRoot: root)
  }
}

private actor DetailLoadGate {
  let store: TranscriptionStore
  var startedCount = 0
  var active = 0
  var peak = 0
  var continuation: CheckedContinuation<Void, Never>?
  init(store: TranscriptionStore) { self.store = store }
  func load(_ id: UUID) async throws -> TranscriptionEnvelope {
    startedCount += 1
    active += 1
    peak = max(peak, active)
    defer { active -= 1 }
    // Deliberately ignore cancellation until released, like an in-flight database read.
    if startedCount == 1 { await withCheckedContinuation { continuation = $0 } }
    return try await store.selectedEnvelope(id)
  }
  func release() {
    continuation?.resume()
    continuation = nil
  }

}
