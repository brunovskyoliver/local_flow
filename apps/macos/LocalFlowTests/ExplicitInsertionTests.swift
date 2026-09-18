import AppKit
import XCTest

@testable import LocalFlow

@MainActor
final class ExplicitInsertionTests: XCTestCase {
  func testReviewLocksDictationAndEscapeCancelsWithoutDispatch() async throws {
    let root = try makeSpoolRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try TranscriptionStore(path: root.appendingPathComponent("history.sqlite").path)
    let insertion = FakeInsertion(store: store)
    let capture = FakeCapture()
    let dictation = DictationCoordinator(
      store: store, lifecycle: ModelLifecycleCoordinator { FakeRuntime() },
      capture: capture, insertion: insertion, spoolRoot: root)
    let flow = ExplicitInsertionCoordinator(
      store: store, insertion: insertion, dictation: dictation)
    let entry = try TranscriptionEntry(
      id: UUID(), text: "Review me", createdAtMilliseconds: 0,
      deliveryState: .uncertain, quality: .incomplete, stopReason: .cancel)
    XCTAssertTrue(flow.beginReview(entry))
    XCTAssertEqual(flow.warnings.count, 2)
    XCTAssertTrue(dictation.busy)
    dictation.begin()
    do {
      try await dictation.deleteOrThrow(entry)
      XCTFail("Deletion must be blocked while a review owns the entry")
    } catch { XCTAssertEqual(error as? TranscriptionStore.Error, .busy) }
    dictation.cancel()
    XCTAssertEqual(flow.phase, .idle)
    XCTAssertFalse(dictation.busy)
    XCTAssertEqual(insertion.dispatchCount, 0)
    let starts = await capture.starts
    XCTAssertEqual(starts, 0)
  }

  func testConfirmIsSingleDispatchAndPersistsBeforeDispatch() async throws {
    let root = try makeSpoolRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try TranscriptionStore(path: root.appendingPathComponent("history.sqlite").path)
    let insertion = FakeInsertion(store: store)
    let dictation = DictationCoordinator(
      store: store, lifecycle: ModelLifecycleCoordinator { FakeRuntime() },
      capture: FakeCapture(), insertion: insertion, spoolRoot: root)
    let flow = ExplicitInsertionCoordinator(
      store: store, insertion: insertion, dictation: dictation,
      presentsPanel: false)
    let reservation = try await store.reserve()
    let entry = try await store.commit(
      reservation: reservation,
      entry: TranscriptionEntry(
        id: UUID(), text: "Saved text", createdAtMilliseconds: 0,
        quality: .complete, stopReason: .keyRelease))
    XCTAssertTrue(flow.beginReview(entry))
    flow.armSelection()
    flow.selectTarget()
    try await waitUntil { flow.phase == .confirming }
    flow.confirm()
    flow.confirm()
    try await waitUntil { flow.phase == .idle }
    XCTAssertEqual(insertion.dispatchCount, 1)
    XCTAssertTrue(insertion.sawAttempting)
    let saved = try await store.get(entry.id)
    XCTAssertEqual(saved?.deliveryState, .confirmed)
    XCTAssertFalse(dictation.busy)
  }

  /// T026 (SC-001): explicit insertion never reaches the rewrite transport, with
  /// the coordinator wired as `AppServices` wires it and rewriting switched on.
  /// History's own rewrite entry points arrive in US5.
  func testExplicitInsertionNeverCallsTheRewriteTransport() async throws {
    let root = try makeSpoolRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try TranscriptionStore(path: root.appendingPathComponent("history.sqlite").path)
    let insertion = FakeInsertion(store: store)
    let rig = RewriteRig(store: store, enabled: true, failOnAnyCall: true)
    defer { rig.removeSuite() }
    let dictation = DictationCoordinator(
      store: store, lifecycle: ModelLifecycleCoordinator { FakeRuntime() },
      capture: FakeCapture(), insertion: insertion, spoolRoot: root, rewriter: rig.coordinator)
    let flow = ExplicitInsertionCoordinator(
      store: store, insertion: insertion, dictation: dictation, presentsPanel: false)
    let reservation = try await store.reserve()
    let entry = try await store.commit(
      reservation: reservation,
      entry: TranscriptionEntry(
        id: UUID(), text: "Saved text", createdAtMilliseconds: 0,
        quality: .complete, stopReason: .keyRelease))
    XCTAssertTrue(flow.beginReview(entry))
    flow.armSelection()
    flow.selectTarget()
    try await waitUntil { flow.phase == .confirming }
    flow.confirm()
    try await waitUntil { flow.phase == .idle }
    XCTAssertEqual(insertion.dispatchCount, 1)
    XCTAssertEqual(rig.callCount, 0)
    let attempts = try await store.attempts(for: entry.id)
    XCTAssertTrue(attempts.isEmpty)
  }

  func testStaleReviewedRevisionNeverDispatches() async throws {
    let root = try makeSpoolRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try TranscriptionStore(path: root.appendingPathComponent("history.sqlite").path)
    let insertion = FakeInsertion(store: store)
    let dictation = DictationCoordinator(
      store: store, lifecycle: ModelLifecycleCoordinator { FakeRuntime() },
      capture: FakeCapture(), insertion: insertion, spoolRoot: root)
    let flow = ExplicitInsertionCoordinator(
      store: store, insertion: insertion, dictation: dictation,
      presentsPanel: false)
    let reservation = try await store.reserve()
    let entry = try await store.commit(
      reservation: reservation,
      entry: TranscriptionEntry(
        id: UUID(), text: "Keep this text", createdAtMilliseconds: 0,
        quality: .complete, stopReason: .keyRelease))
    _ = try await store.dismissRecovery(id: entry.id, revision: entry.revision)
    XCTAssertTrue(flow.beginReview(entry))
    flow.armSelection()
    flow.selectTarget()
    try await waitUntil { flow.phase == .confirming }
    flow.confirm()
    try await waitUntil { flow.phase == .idle }
    XCTAssertEqual(insertion.dispatchCount, 0)
    let saved = try await store.get(entry.id)
    XCTAssertEqual(saved?.text, "Keep this text")
    XCTAssertFalse(dictation.busy)
  }

  func testCancelDuringDispatchWaitsForAcknowledgmentBeforeUnlocking() async throws {
    let root = try makeSpoolRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try TranscriptionStore(path: root.appendingPathComponent("history.sqlite").path)
    let gate = Gate()
    let insertion = FakeInsertion(store: store, dispatchGate: gate)
    insertion.outcome = .uncertain(.focusChanged)
    let dictation = DictationCoordinator(
      store: store, lifecycle: ModelLifecycleCoordinator { FakeRuntime() },
      capture: FakeCapture(), insertion: insertion, spoolRoot: root)
    let flow = ExplicitInsertionCoordinator(
      store: store, insertion: insertion, dictation: dictation,
      presentsPanel: false)
    let reservation = try await store.reserve()
    let entry = try await store.commit(
      reservation: reservation,
      entry: TranscriptionEntry(
        id: UUID(), text: "Preserve result", createdAtMilliseconds: 0,
        quality: .complete, stopReason: .keyRelease))
    XCTAssertTrue(flow.beginReview(entry))
    flow.armSelection()
    flow.selectTarget()
    try await waitUntil { flow.phase == .confirming }
    flow.confirm()
    try await waitUntil { insertion.dispatchCount == 1 }
    dictation.cancel()
    XCTAssertTrue(dictation.busy)
    XCTAssertEqual(flow.phase, .inserting)
    flow.confirm()
    await gate.openGate()
    try await waitUntil { flow.phase == .idle }
    let saved = try await store.get(entry.id)
    XCTAssertEqual(saved?.deliveryState, .uncertain)
    XCTAssertEqual(saved?.text, "Preserve result")
    XCTAssertEqual(insertion.dispatchCount, 1)
    XCTAssertFalse(dictation.busy)
  }

  func testFailedAcknowledgmentRetriesStorageWithoutAnotherDispatch() async throws {
    let root = try makeSpoolRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let base = try TranscriptionStore(path: root.appendingPathComponent("history.sqlite").path)
    let store = ExplicitFaultingStore(base: base, failOutcome: true)
    let insertion = FakeInsertion(store: base)
    let dictation = DictationCoordinator(
      store: store, lifecycle: ModelLifecycleCoordinator { FakeRuntime() },
      capture: FakeCapture(), insertion: insertion, spoolRoot: root)
    let flow = ExplicitInsertionCoordinator(
      store: store, insertion: insertion, dictation: dictation,
      presentsPanel: false)
    let reservation = try await store.reserve()
    let entry = try await store.commit(
      reservation: reservation,
      entry: TranscriptionEntry(
        id: UUID(), text: "Durable original", createdAtMilliseconds: 0,
        quality: .complete, stopReason: .keyRelease))
    XCTAssertTrue(flow.beginReview(entry))
    flow.armSelection()
    flow.selectTarget()
    try await waitUntil { flow.phase == .confirming }
    flow.confirm()
    try await waitUntil { flow.phase == .idle }
    XCTAssertTrue(dictation.storageBlocked)
    XCTAssertFalse(flow.beginReview(entry))
    let pending = try await store.get(entry.id)
    XCTAssertEqual(pending?.deliveryState, .attempting)
    XCTAssertEqual(pending?.text, entry.text)
    await dictation.retryStorage()
    XCTAssertFalse(dictation.storageBlocked)
    let saved = try await store.get(entry.id)
    XCTAssertEqual(saved?.deliveryState, .confirmed)
    XCTAssertEqual(insertion.dispatchCount, 1)
  }

  func testCancelBeforeAttemptReturnsPersistsNoDispatchOutcome() async throws {
    let root = try makeSpoolRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let base = try TranscriptionStore(path: root.appendingPathComponent("history.sqlite").path)
    let gate = Gate()
    let store = ExplicitFaultingStore(base: base, beginGate: gate)
    let insertion = FakeInsertion(store: base)
    let dictation = DictationCoordinator(
      store: store, lifecycle: ModelLifecycleCoordinator { FakeRuntime() },
      capture: FakeCapture(), insertion: insertion, spoolRoot: root)
    let flow = ExplicitInsertionCoordinator(
      store: store, insertion: insertion, dictation: dictation,
      presentsPanel: false)
    let reservation = try await store.reserve()
    let entry = try await store.commit(
      reservation: reservation,
      entry: TranscriptionEntry(
        id: UUID(), text: "Keep after cancellation", createdAtMilliseconds: 0,
        quality: .durationLimited, stopReason: .durationLimit))
    XCTAssertTrue(flow.beginReview(entry))
    XCTAssertEqual(flow.warnings.count, 1)
    flow.armSelection()
    flow.selectTarget()
    try await waitUntil { flow.phase == .confirming }
    flow.confirm()
    await store.enteredBegin.wait()
    dictation.cancel()
    XCTAssertTrue(dictation.busy)
    await gate.openGate()
    try await waitUntil { flow.phase == .idle }
    XCTAssertEqual(insertion.dispatchCount, 0)
    let saved = try await store.get(entry.id)
    XCTAssertEqual(saved?.deliveryState, .notInserted)
    XCTAssertEqual(saved?.quality, .durationLimited)
    XCTAssertEqual(saved?.text, entry.text)
  }

  func testChangedTargetRetainsSavedTextForFreshSelection() async throws {
    let root = try makeSpoolRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try TranscriptionStore(path: root.appendingPathComponent("history.sqlite").path)
    let insertion = FakeInsertion(store: store)
    insertion.outcome = .notInserted(.selectionChanged)
    let dictation = DictationCoordinator(
      store: store, lifecycle: ModelLifecycleCoordinator { FakeRuntime() },
      capture: FakeCapture(), insertion: insertion, spoolRoot: root)
    let flow = ExplicitInsertionCoordinator(
      store: store, insertion: insertion, dictation: dictation,
      presentsPanel: false)
    let reservation = try await store.reserve()
    let entry = try await store.commit(
      reservation: reservation,
      entry: TranscriptionEntry(
        id: UUID(), text: "Check target", createdAtMilliseconds: 0,
        quality: .complete, stopReason: .keyRelease))
    XCTAssertTrue(flow.beginReview(entry))
    flow.armSelection()
    flow.selectTarget()
    try await waitUntil { flow.phase == .confirming }
    flow.confirm()
    try await waitUntil { flow.phase == .idle }
    let saved = try await store.get(entry.id)
    XCTAssertEqual(saved?.deliveryState, .notInserted)
    XCTAssertEqual(saved?.text, entry.text)
    XCTAssertNil(flow.entry)
    XCTAssertTrue(flow.message.contains("choose the field again"))
  }

  func testCancellationJoinsPendingTargetCapture() async throws {
    let root = try makeSpoolRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try TranscriptionStore(path: root.appendingPathComponent("history.sqlite").path)
    let insertion = GatedTargetInsertion()
    let dictation = DictationCoordinator(
      store: store, lifecycle: ModelLifecycleCoordinator { FakeRuntime() },
      capture: FakeCapture(), insertion: insertion, spoolRoot: root)
    let flow = ExplicitInsertionCoordinator(
      store: store, insertion: insertion, dictation: dictation,
      presentsPanel: false)
    let entry = try TranscriptionEntry(
      id: UUID(), text: "Review", createdAtMilliseconds: 0,
      quality: .complete, stopReason: .keyRelease)
    XCTAssertTrue(flow.beginReview(entry))
    flow.armSelection()
    flow.selectTarget()
    await insertion.entered.wait()
    dictation.cancel()
    XCTAssertTrue(dictation.busy)
    XCTAssertFalse(flow.beginReview(entry))
    await insertion.release.openGate()
    try await waitUntil { flow.phase == .idle }
    XCTAssertFalse(dictation.busy)
  }

  func testSelectionRequiresExplicitActionAndRejectsOwnAppOrUnsupportedField() async throws {
    let root = try makeSpoolRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try TranscriptionStore(path: root.appendingPathComponent("history.sqlite").path)
    let fixture = FakeInsertion().target
    let ownTarget = CapturedTarget(
      processIdentifier: ProcessInfo.processInfo.processIdentifier,
      launchDate: fixture.launchDate, bundleIdentifier: "localflow.test", element: fixture.element,
      focusedWindow: fixture.focusedWindow, selectedRange: fixture.selectedRange,
      comparisonContext: fixture.comparisonContext)
    let clipboardChangeCount = NSPasteboard.general.changeCount
    for target in [nil, ownTarget] as [CapturedTarget?] {
      let insertion = SelectionStub(target: target)
      let dictation = DictationCoordinator(
        store: store, lifecycle: ModelLifecycleCoordinator { FakeRuntime() },
        capture: FakeCapture(), insertion: insertion, spoolRoot: root)
      let flow = ExplicitInsertionCoordinator(
        store: store, insertion: insertion, dictation: dictation,
        presentsPanel: false)
      let entry = try TranscriptionEntry(
        id: UUID(), text: "Review", createdAtMilliseconds: 0,
        quality: .complete, stopReason: .keyRelease)
      XCTAssertTrue(flow.beginReview(entry))
      flow.armSelection()
      await Task.yield()
      let before = await insertion.captures
      XCTAssertEqual(before, 0)
      flow.selectTarget()
      flow.selectTarget()
      try await waitUntil { flow.message.contains("Choose a supported editable field") }
      XCTAssertEqual(flow.phase, .selecting)
      let after = await insertion.captures
      XCTAssertEqual(after, 1)
      flow.confirm()
      dictation.cancel()
      XCTAssertEqual(flow.phase, .idle)
      XCTAssertFalse(dictation.busy)
    }
    XCTAssertEqual(NSPasteboard.general.changeCount, clipboardChangeCount)
  }

  func testConfirmationPanelRefusesKeyAndMainStatus() {
    let panel = InsertionConfirmationPanel()
    XCTAssertFalse(panel.canBecomeKey)
    XCTAssertFalse(panel.canBecomeMain)
    XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel))
  }

  private func waitUntil(_ condition: () -> Bool) async throws {
    for _ in 0..<200 {
      if condition() { return }
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTFail("Timed out waiting for explicit insertion")
  }

  // MARK: US5 (T048): inserting a chosen text through the same review flow.

  func testInsertingARewriteAttemptRecordsTheRewriteDelivery() async throws {
    try await insertRewrite(failOutcome: false)
  }

  func testRewriteDeliverySurvivesFailedAcknowledgmentWithoutAnotherInsertion() async throws {
    try await insertRewrite(failOutcome: true)
  }

  private func insertRewrite(failOutcome: Bool) async throws {
    let root = try makeSpoolRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try TranscriptionStore(path: root.appendingPathComponent("history.sqlite").path)
    let insertion = FakeInsertion(store: store)
    let faultingStore = ExplicitFaultingStore(base: store, failOutcome: failOutcome)
    let dictation = DictationCoordinator(
      store: faultingStore, lifecycle: ModelLifecycleCoordinator { FakeRuntime() },
      capture: FakeCapture(), insertion: insertion, spoolRoot: root)
    let flow = ExplicitInsertionCoordinator(
      store: faultingStore, insertion: insertion, dictation: dictation, presentsPanel: false)
    let entry = try await store.commit(
      reservation: try await store.reserve(),
      entry: TranscriptionEntry(
        id: UUID(), text: "move it to monday", createdAtMilliseconds: 0,
        quality: .complete, stopReason: .keyRelease))
    let admitted = try await store.begin(
      RewriteAdmission(
        transcriptionID: entry.id, mode: .polished, inputText: entry.text,
        endpointOrigin: "http://127.0.0.1:8080", insecureOverride: false))
    let attempt = try await store.recordResult(
      id: admitted.id,
      result: RewriteResult(
        text: "Please move it to Monday.", unchanged: false, serverName: "flowd",
        serverVersion: "0.2.0", backendKind: "openai-compatible", backendModel: "qwen2.5-3b",
        promptVersion: 1, shieldVersion: 1, serverQueueMilliseconds: nil,
        backendFirstTokenMilliseconds: nil, backendMilliseconds: nil),
      spans: RewriteSpans(durationMilliseconds: 800))

    XCTAssertTrue(flow.beginReview(entry, attempt: attempt))
    XCTAssertEqual(flow.reviewText, "Please move it to Monday.")
    flow.armSelection()
    flow.selectTarget()
    try await waitUntil { flow.phase == .confirming }
    flow.confirm()
    try await waitUntil { flow.phase == .idle }
    if failOutcome {
      XCTAssertTrue(dictation.storageBlocked)
      await dictation.retryStorage()
      XCTAssertFalse(dictation.storageBlocked)
    }
    XCTAssertEqual(insertion.insertedTexts, ["Please move it to Monday."])
    let saved = try await store.get(entry.id)
    XCTAssertEqual(saved?.deliveryState, .confirmed)
    XCTAssertEqual(saved?.deliveredSource, .rewrite)
    XCTAssertEqual(saved?.deliveredRewriteAttemptID, attempt.id)
    let attempts = try await store.attempts(for: entry.id)
    XCTAssertEqual(attempts.first?.delivered, true)
  }

  func testInsertingTheFaithfulTextClearsTheAttemptReference() async throws {
    let root = try makeSpoolRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try TranscriptionStore(path: root.appendingPathComponent("history.sqlite").path)
    let insertion = FakeInsertion(store: store)
    let dictation = DictationCoordinator(
      store: store, lifecycle: ModelLifecycleCoordinator { FakeRuntime() },
      capture: FakeCapture(), insertion: insertion, spoolRoot: root)
    let flow = ExplicitInsertionCoordinator(
      store: store, insertion: insertion, dictation: dictation, presentsPanel: false)
    let entry = try await store.commit(
      reservation: try await store.reserve(),
      entry: TranscriptionEntry(
        id: UUID(), text: "move it to monday", createdAtMilliseconds: 0,
        quality: .complete, stopReason: .keyRelease))
    let admitted = try await store.begin(
      RewriteAdmission(
        transcriptionID: entry.id, mode: .clean, inputText: entry.text,
        endpointOrigin: "http://127.0.0.1:8080", insecureOverride: false))
    let attempt = try await store.recordResult(
      id: admitted.id,
      result: RewriteResult(
        text: "Move it to Monday.", unchanged: false, serverName: "flowd",
        serverVersion: "0.2.0", backendKind: "openai-compatible", backendModel: "qwen2.5-3b",
        promptVersion: 1, shieldVersion: 1, serverQueueMilliseconds: nil,
        backendFirstTokenMilliseconds: nil, backendMilliseconds: nil),
      spans: RewriteSpans(durationMilliseconds: 800))
    // The rewrite is delivered first, then the faithful transcript replaces it.
    let first = try await store.beginAttempt(id: entry.id, revision: entry.revision)
    let afterRewrite = try await store.recordOutcome(
      id: entry.id, revision: first.entry.revision, attemptID: first.id, outcome: .confirmed,
      delivery: RewriteDelivery(source: .rewrite, attemptID: attempt.id, durationMilliseconds: 1))
    XCTAssertEqual(afterRewrite.deliveredRewriteAttemptID, attempt.id)

    XCTAssertTrue(flow.beginReview(afterRewrite))
    XCTAssertEqual(flow.reviewText, "move it to monday")
    flow.armSelection()
    flow.selectTarget()
    try await waitUntil { flow.phase == .confirming }
    flow.confirm()
    try await waitUntil { flow.phase == .idle }
    XCTAssertEqual(insertion.insertedTexts.last, "move it to monday")
    let saved = try await store.get(entry.id)
    XCTAssertEqual(saved?.deliveredSource, .faithful)
    XCTAssertNil(saved?.deliveredRewriteAttemptID)
  }

  func testAPendingAttemptCannotBeReviewedForInsertion() async throws {
    let root = try makeSpoolRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try TranscriptionStore(path: root.appendingPathComponent("history.sqlite").path)
    let insertion = FakeInsertion(store: store)
    let dictation = DictationCoordinator(
      store: store, lifecycle: ModelLifecycleCoordinator { FakeRuntime() },
      capture: FakeCapture(), insertion: insertion, spoolRoot: root)
    let flow = ExplicitInsertionCoordinator(
      store: store, insertion: insertion, dictation: dictation, presentsPanel: false)
    let entry = try await store.commit(
      reservation: try await store.reserve(),
      entry: TranscriptionEntry(
        id: UUID(), text: "move it to monday", createdAtMilliseconds: 0,
        quality: .complete, stopReason: .keyRelease))
    let pending = try await store.begin(
      RewriteAdmission(
        transcriptionID: entry.id, mode: .clean, inputText: entry.text,
        endpointOrigin: "http://127.0.0.1:8080", insecureOverride: false))
    XCTAssertFalse(flow.beginReview(entry, attempt: pending))
    XCTAssertEqual(flow.phase, .idle)
    XCTAssertEqual(insertion.dispatchCount, 0)
  }

}

private actor ExplicitFaultingStore: TranscriptionStoring {
  let base: TranscriptionStore
  var failOutcome: Bool
  let beginGate: Gate?
  let enteredBegin = Gate()
  init(base: TranscriptionStore, failOutcome: Bool = false, beginGate: Gate? = nil) {
    self.base = base
    self.failOutcome = failOutcome
    self.beginGate = beginGate
  }
  func verifyWritable() async throws { try await base.verifyWritable() }
  func reserve(maxBytes: Int) async throws -> TranscriptionStore.Reservation {
    try await base.reserve(maxBytes: maxBytes)
  }
  func commit(reservation: TranscriptionStore.Reservation, entry: TranscriptionEntry) async throws
    -> TranscriptionEntry
  {
    try await base.commit(reservation: reservation, entry: entry)
  }
  func commit(reservation: TranscriptionStore.Reservation, envelope: TranscriptionEnvelope)
    async throws -> TranscriptionEntry
  {
    return try await base.commit(reservation: reservation, envelope: envelope)
  }

  func releaseReservation(_ reservation: TranscriptionStore.Reservation) async {
    await base.releaseReservation(reservation)
  }
  func recent(limit: Int) async throws -> [TranscriptionEntry] {
    try await base.recent(limit: limit)
  }
  func get(_ id: UUID) async throws -> TranscriptionEntry? { try await base.get(id) }
  func beginAttempt(id: UUID, revision: Int64) async throws -> TranscriptionStore.Attempt {
    let attempt = try await base.beginAttempt(id: id, revision: revision)
    await enteredBegin.openGate()
    await beginGate?.wait()
    return attempt
  }
  func recordOutcome(
    id: UUID, revision: Int64, attemptID: UUID, outcome: TranscriptionStore.Outcome,
    delivery: RewriteDelivery
  ) async throws -> TranscriptionEntry {
    if failOutcome {
      failOutcome = false
      throw TranscriptionStore.Error.databaseLimitExceeded
    }
    return try await base.recordOutcome(
      id: id, revision: revision, attemptID: attemptID, outcome: outcome, delivery: delivery)
  }
  func recordOutcome(
    id: UUID, revision: Int64, attemptID: UUID,
    outcome: TranscriptionStore.Outcome
  ) async throws -> TranscriptionEntry {
    if failOutcome {
      failOutcome = false
      throw TranscriptionStore.Error.databaseLimitExceeded
    }
    return try await base.recordOutcome(
      id: id, revision: revision, attemptID: attemptID, outcome: outcome)
  }
  func dismissRecovery(id: UUID, revision: Int64) async throws -> TranscriptionEntry {
    try await base.dismissRecovery(id: id, revision: revision)
  }
  func deleteConfirmed(id: UUID, revision: Int64) async throws {
    try await base.deleteConfirmed(id: id, revision: revision)
  }
}

private actor GatedTargetInsertion: TextInserting {
  let entered = Gate()
  let release = Gate()
  func captureTarget() async -> CapturedTarget? {
    await entered.openGate()
    await release.wait()
    return nil
  }
  func insertOnce(attemptID: UUID, target: CapturedTarget, text: String) async -> InsertionOutcome {
    XCTFail("Cancelled target selection must never dispatch")
    return .notInserted(.unsupported)
  }
}

private actor SelectionStub: TextInserting {
  let target: CapturedTarget?
  private(set) var captures = 0
  init(target: CapturedTarget?) { self.target = target }
  func captureTarget() async -> CapturedTarget? {
    captures += 1
    return target
  }
  func insertOnce(attemptID: UUID, target: CapturedTarget, text: String) async -> InsertionOutcome {
    XCTFail("Ineligible selection must never dispatch")
    return .notInserted(.unsupported)
  }

}
