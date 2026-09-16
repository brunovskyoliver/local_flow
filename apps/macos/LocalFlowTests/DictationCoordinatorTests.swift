import GRDB
import XCTest

@testable import LocalFlow

@MainActor
final class DictationCoordinatorTests: XCTestCase {
  private enum TestTimeout: Error { case expired }
  private var ownedDirectories: [URL] = []

  override func tearDown() async throws {
    let directories = await MainActor.run {
      let result = ownedDirectories
      ownedDirectories.removeAll()
      return result
    }
    for directory in directories.reversed() { try? FileManager.default.removeItem(at: directory) }
  }

  func testReleaseDuringPreparationDoesNotStartCapture() async throws {
    let gate = Gate()
    let runtime = FakeRuntime(gate: gate)
    let lifecycle = ModelLifecycleCoordinator {
      await gate.wait()
      return runtime
    }
    let capture = FakeCapture()
    let insertion = FakeInsertion()
    let coordinator = try makeCoordinator(
      lifecycle: lifecycle, capture: capture, insertion: insertion)

    coordinator.begin()
    try await waitUntil { coordinator.state == .preparing }
    coordinator.release()
    await gate.openGate()
    try await waitUntil { !coordinator.busy }
    let starts = await capture.starts
    XCTAssertEqual(starts, 0)
  }

  func testCompleteResultIsCommittedBeforeInsertionAndConfirmed() async throws {
    let store = try makeStore()
    let lifecycle = ModelLifecycleCoordinator { FakeRuntime() }
    let capture = FakeCapture()
    let insertion = FakeInsertion(store: store)
    let coordinator = try makeCoordinator(
      store: store, lifecycle: lifecycle, capture: capture, insertion: insertion)

    coordinator.begin()
    try await waitUntil { coordinator.state == .recording }
    coordinator.release()
    try await waitUntil { !coordinator.busy }
    XCTAssertEqual(insertion.dispatchCount, 1)
    XCTAssertTrue(insertion.sawAttempting)
    let entry = try await store.recent(limit: 1).first
    XCTAssertEqual(entry?.deliveryState, .confirmed)
  }

  func testSavedDictationRefreshesVisibleHistoryWithoutNavigation() async throws {
    for outcome: InsertionOutcome in [.confirmed, .uncertain(.unsupported)] {
      let store = try makeStore()
      let history = HistoryViewModel(store: store)
      let insertion = FakeInsertion(store: store)
      insertion.outcome = outcome
      let coordinator = try makeCoordinator(
        store: store, lifecycle: ModelLifecycleCoordinator { FakeRuntime() },
        capture: FakeCapture(), insertion: insertion)
      coordinator.historyChanged = { history.refresh() }
      history.refresh()
      try await waitUntil { !history.isLoading }
      XCTAssertTrue(history.entries.isEmpty)
      coordinator.begin()
      try await waitUntil { coordinator.state == .recording }
      coordinator.release()
      try await waitUntil { !coordinator.busy && !history.isLoading }
      XCTAssertEqual(history.entries.count, 1)
      XCTAssertEqual(
        history.entries.first?.deliveryState, outcome == .confirmed ? .confirmed : .uncertain)
    }
  }

  func testDurationLimitIsReviewOnly() async throws {
    let store = try makeStore()
    let lifecycle = ModelLifecycleCoordinator { FakeRuntime() }
    let capture = FakeCapture(reason: .durationLimit)
    let insertion = FakeInsertion(store: store)
    let coordinator = try makeCoordinator(
      store: store, lifecycle: lifecycle, capture: capture, insertion: insertion)

    coordinator.begin()
    try await waitUntil { !coordinator.busy }
    XCTAssertEqual(insertion.dispatchCount, 0)
    let durationEntry = try await store.recent(limit: 1).first
    XCTAssertEqual(durationEntry?.quality, .durationLimited)
  }

  func testDeadlineResultWinsOrdinaryRelease() async throws {
    let store = try makeStore()
    let insertion = FakeInsertion(store: store)
    let coordinator = try makeCoordinator(
      store: store, capture: FakeCapture(reason: .durationLimit, staleSnapshot: true),
      insertion: insertion)
    coordinator.begin()
    try await waitUntil { coordinator.state == .recording }
    coordinator.release()
    try await waitUntil { !coordinator.busy }
    let entry = try await store.recent().first
    XCTAssertEqual(entry?.quality, .durationLimited)
    XCTAssertEqual(entry?.stopReason, .durationLimit)
    XCTAssertEqual(insertion.dispatchCount, 0)
  }

  func testRepeatedBeginStartsOneSession() async throws {
    let capture = FakeCapture()
    let coordinator = try makeCoordinator(capture: capture)
    coordinator.begin()
    coordinator.begin()
    try await waitUntil { coordinator.state == .recording }
    coordinator.release()
    try await waitUntil { !coordinator.busy }
    let starts = await capture.starts
    XCTAssertEqual(starts, 1)
  }

  func testCancellationRetainsCommittedText() async throws {
    let store = try makeStore()
    let lifecycle = ModelLifecycleCoordinator { FakeRuntime() }
    let capture = FakeCapture()
    let dispatchGate = Gate()
    let insertion = FakeInsertion(store: store, dispatchGate: dispatchGate)
    let coordinator = try makeCoordinator(
      store: store, lifecycle: lifecycle, capture: capture, insertion: insertion)

    coordinator.begin()
    try await waitUntil { coordinator.state == .recording }
    coordinator.release()
    try await waitUntil { insertion.dispatchCount == 1 }
    coordinator.cancel()
    await dispatchGate.openGate()
    try await waitUntil { !coordinator.busy }
    let entry = try await store.recent(limit: 1).first
    XCTAssertEqual(entry?.text, "hello")
    XCTAssertEqual(insertion.dispatchCount, 1)
  }

  func testMailboxOverflowStopsPreparationWithoutCaptureAndReportsFailure() async throws {
    let mailbox = ControlMailbox()
    let capture = FakeCapture()
    let coordinator = try makeCoordinator(capture: capture, mailbox: mailbox)
    coordinator.begin()
    let tag = try XCTUnwrap(coordinator.controlTag)
    for _ in 0..<ControlMailbox.capacity {
      _ = mailbox.tryEnqueue(.init(tag: tag, value: .begin))
    }
    coordinator.release()
    coordinator.cancel()
    try await waitUntil { !coordinator.busy }
    XCTAssertEqual(coordinator.state, .failed)
    XCTAssertTrue(coordinator.status.contains("overflowed"))
    let starts = await capture.starts
    XCTAssertEqual(starts, 0)
    XCTAssertEqual(mailbox.consumeFlags(for: tag).terminal, .failed)
  }

  func testMailboxFailureStopsAreAlwaysReviewOnly() async throws {
    for reason in [
      ControlMailbox.StopReason.overflow, .deviceLoss, .permissionRevoked, .sleep, .failure,
      .durationLimit,
    ] {
      let mailbox = ControlMailbox()
      let store = try makeStore()
      let insertion = FakeInsertion(store: store)
      let coordinator = try makeCoordinator(
        store: store, capture: FakeCapture(), insertion: insertion, mailbox: mailbox)
      coordinator.begin()
      try await waitUntil { coordinator.state == .recording }
      let tag = try XCTUnwrap(coordinator.controlTag)
      XCTAssertTrue(mailbox.tryEnqueue(.init(tag: tag, value: .stop(reason))))
      try await waitUntil { !coordinator.busy }
      let entry = try await store.recent().first
      XCTAssertEqual(entry?.quality, reason == .durationLimit ? .durationLimited : .incomplete)
      XCTAssertEqual(insertion.dispatchCount, 0)
    }
  }

  func testLateFailureBeforeOrAfterAttemptMarkerPreventsDispatch() async throws {
    for phase in [DictationSession.State.persisting, .inserting] {
      for reason in [ControlMailbox.StopReason.failure, .durationLimit] {
        let mailbox = ControlMailbox()
        let store = try makeStore()
        let insertion = FakeInsertion(store: store)
        let coordinator = try makeCoordinator(
          store: store, capture: FakeCapture(), insertion: insertion, mailbox: mailbox)
        coordinator.stateChanged = { [weak coordinator] state in
          if state == phase, let tag = coordinator?.controlTag {
            mailbox.requestStop(reason, for: tag)
          }
        }
        coordinator.begin()
        try await waitUntil { coordinator.state == .recording }
        coordinator.release()
        try await waitUntil { !coordinator.busy }
        let rows = try await store.recent()
        XCTAssertEqual(rows.first?.text, "hello")
        XCTAssertEqual(rows.first?.recoveryState, .needsReview)
        XCTAssertEqual(insertion.dispatchCount, 0)
      }
    }
  }

  func testStaleCancellationCannotStopNextSession() async throws {
    let mailbox = ControlMailbox()
    let capture = FakeCapture()
    let coordinator = try makeCoordinator(capture: capture, mailbox: mailbox)
    coordinator.begin()
    let old = try XCTUnwrap(coordinator.controlTag)
    coordinator.release()
    try await waitUntil { !coordinator.busy }
    coordinator.begin()
    XCTAssertFalse(mailbox.requestCancel(for: old))
    XCTAssertFalse(mailbox.requestStop(.durationLimit, for: old))
    try await waitUntil { coordinator.state == .recording }
    coordinator.release()
    try await waitUntil { !coordinator.busy }
    XCTAssertEqual(coordinator.state, .idle)
  }

  func testEscapeDuringDecodeJoinsAndPreservesReturnedPrefixWithoutInsertion() async throws {
    let gate = Gate()
    let runtime = FakeRuntime(gate: gate)
    let store = try makeStore()
    let insertion = FakeInsertion(store: store)
    let coordinator = try makeCoordinator(
      store: store, lifecycle: ModelLifecycleCoordinator { runtime },
      capture: FakeCapture(), insertion: insertion)
    coordinator.begin()
    try await waitUntil { coordinator.state == .recording }
    coordinator.release()
    try await waitUntil { coordinator.state == .transcribing }
    // Let the fake runtime enter its uninterruptible call before cancelling.
    await runtime.waitUntilTranscribing()
    coordinator.cancel()
    try await waitUntil { coordinator.state == .cancelling }
    XCTAssertTrue(coordinator.busy)
    coordinator.begin()
    await gate.openGate()
    try await waitUntil { !coordinator.busy }
    let entries = try await store.recent()
    XCTAssertEqual(entries.first?.text, "hello")
    XCTAssertEqual(entries.first?.quality, .incomplete)
    XCTAssertEqual(insertion.dispatchCount, 0)
  }

  func testCaptureFailureWithNoAudioReportsCauseInsteadOfSilence() async throws {
    let capture = FakeCapture(reason: .failure(.unsupportedFormat), samples: [])
    let coordinator = try makeCoordinator(
      lifecycle: ModelLifecycleCoordinator { FakeRuntime() }, capture: capture)
    coordinator.begin()
    try await waitUntil { !coordinator.busy }
    XCTAssertEqual(coordinator.state, .failed)
    XCTAssertTrue(coordinator.status.contains("microphone format is unsupported"))
    XCTAssertFalse(coordinator.status.contains("No speech detected"))
  }

  func testDeniedMicrophoneNeverLoadsRuntimeOrStartsCapture() async throws {
    let capture = FakeCapture(authorized: false)
    let lifecycle = ModelLifecycleCoordinator {
      XCTFail("Permission denial must precede model loading")
      return FakeRuntime()
    }
    let coordinator = try makeCoordinator(lifecycle: lifecycle, capture: capture)
    coordinator.begin()
    try await waitUntil { !coordinator.busy }
    let starts = await capture.starts
    XCTAssertEqual(starts, 0)
    XCTAssertEqual(coordinator.state, .failed)
    XCTAssertTrue(coordinator.status.contains("requesting microphone access"))
    XCTAssertTrue(coordinator.status.contains("Microphone access is not allowed"))
  }

  func testCancellationWhileCaptureStartsJoinsWithoutShowingRecording() async throws {
    let gate = Gate()
    let capture = FakeCapture(startGate: gate)
    let coordinator = try makeCoordinator(capture: capture)
    var showedRecording = false
    coordinator.stateChanged = { if $0 == .recording { showedRecording = true } }
    coordinator.begin()
    await capture.waitUntilStarting()
    coordinator.cancel()
    try await waitUntil { coordinator.state == .cancelling }
    XCTAssertTrue(coordinator.busy)
    await gate.openGate()
    try await waitUntil { !coordinator.busy }
    let cancels = await capture.cancels
    XCTAssertGreaterThan(cancels, 0)
    XCTAssertFalse(showedRecording)
  }

  func testStaleCaptureSnapshotCannotFinishCurrentRecording() async throws {
    let capture = FakeCapture(reason: .durationLimit, staleSnapshot: true)
    let coordinator = try makeCoordinator(capture: capture)
    coordinator.begin()
    try await waitUntil { coordinator.state == .recording }
    try await ContinuousClock().sleep(for: .milliseconds(100))
    XCTAssertEqual(coordinator.state, .recording)
    coordinator.release()
    try await waitUntil { !coordinator.busy }
  }

  func testStaleCaptureCompletionNeverReachesDecoderOrInsertion() async throws {
    let store = try makeStore()
    let insertion = FakeInsertion(store: store)
    let coordinator = try makeCoordinator(
      store: store, capture: FakeCapture(staleResult: true), insertion: insertion)
    coordinator.begin()
    try await waitUntil { coordinator.state == .recording }
    coordinator.release()
    try await waitUntil { !coordinator.busy }
    let entries = try await store.recent()
    XCTAssertTrue(entries.isEmpty)
    XCTAssertEqual(insertion.dispatchCount, 0)
    XCTAssertEqual(coordinator.state, .failed)
  }

  func testSilenceCreatesNoHistoryOrDispatch() async throws {
    let store = try makeStore()
    let insertion = FakeInsertion(store: store)
    let coordinator = try makeCoordinator(
      store: store, lifecycle: ModelLifecycleCoordinator { FakeRuntime(text: "  ") },
      capture: FakeCapture(), insertion: insertion)
    coordinator.begin()
    try await waitUntil { coordinator.state == .recording }
    coordinator.release()
    try await waitUntil { !coordinator.busy }
    let entries = try await store.recent()
    XCTAssertTrue(entries.isEmpty)
    XCTAssertEqual(insertion.dispatchCount, 0)
    XCTAssertEqual(coordinator.status, "No speech detected.")
  }

  func testPersistentAttentionIncludesRecoveryOlderThanVisibleHistory() async throws {
    let store = try makeStore()
    var oldest: TranscriptionEntry?
    for index in 0..<21 {
      let entry = try TranscriptionEntry(
        id: UUID(), text: "Entry \(index)",
        createdAtMilliseconds: Int64(index), quality: .incomplete, stopReason: .cancel)
      let reservation = try await store.reserve()
      let saved = try await store.commit(reservation: reservation, entry: entry)
      if index == 0 {
        oldest = saved
      } else {
        _ = try await store.dismissRecovery(id: saved.id, revision: saved.revision)
      }
    }
    let coordinator = try makeCoordinator(store: store, capture: FakeCapture())
    coordinator.setPreviewEnabled(true)
    await coordinator.refreshHistory()
    XCTAssertEqual(coordinator.history.count, 1)
    XCTAssertFalse(coordinator.history.contains { $0.recoveryState == .needsReview })
    XCTAssertTrue(coordinator.hasRecovery)
    try await coordinator.dismissOrThrow(XCTUnwrap(oldest))
    XCTAssertFalse(coordinator.hasRecovery)
    let retained = try await store.get(XCTUnwrap(oldest).id)
    XCTAssertEqual(retained?.quality, .incomplete)
  }

  func testDismissingLastRecoveryClearsRecoveryPresentation() async throws {
    let store = try makeStore()
    let coordinator = try makeCoordinator(
      store: store,
      capture: FakeCapture(reason: .durationLimit))
    coordinator.begin()
    try await waitUntil { !coordinator.busy }
    coordinator.setPreviewEnabled(true)
    await coordinator.refreshHistory()
    XCTAssertEqual(coordinator.state, .recovery)
    XCTAssertTrue(coordinator.hasRecovery)
    let entry = try XCTUnwrap(coordinator.history.first)
    try await coordinator.dismissOrThrow(entry)
    XCTAssertFalse(coordinator.hasRecovery)
    XCTAssertEqual(coordinator.state, .idle)
    XCTAssertEqual(coordinator.history.first?.quality, .durationLimited)
  }

  func testFullHistoryBlocksCaptureUntilConfirmedDeletionFreesCapacity() async throws {
    let root = try makeSpoolRoot()
    ownedDirectories.append(root)
    let path = root.appendingPathComponent("history.sqlite").path
    let store = try TranscriptionStore(path: path)
    let fixture = try DatabaseQueue(path: path)
    try await fixture.write { db in
      for index in 0..<TranscriptionStore.maximumRows {
        try db.execute(
          sql: """
            INSERT INTO transcriptions
              (id, text, created_at, delivery_state, recovery_state, quality, stop_reason, revision)
            VALUES (?, 'Saved', ?, 'not_attempted', 'needs_review', 'complete', 'key_release', 0)
            """, arguments: [UUID().uuidString, index])
      }
      try db.execute(
        sql: "UPDATE history_usage SET row_count = ?, payload_bytes = ? WHERE id = 1",
        arguments: [TranscriptionStore.maximumRows, TranscriptionStore.maximumRows * 5])
    }
    let capture = FakeCapture()
    let coordinator = try makeCoordinator(store: store, capture: capture)
    await coordinator.verifyInitialAdmission()
    XCTAssertFalse(
      coordinator.canBegin, "First-run readiness must reject full history before a hold")
    coordinator.begin()
    try await waitUntil { !coordinator.busy }
    XCTAssertTrue(coordinator.capacityBlocked)
    coordinator.setPreviewEnabled(true)
    await coordinator.refreshHistory()
    XCTAssertTrue(coordinator.status.contains("Explicitly delete"))
    let starts = await capture.starts
    XCTAssertEqual(starts, 0)
    let entry = try XCTUnwrap(coordinator.history.first)
    try await coordinator.dismissOrThrow(entry)
    XCTAssertTrue(coordinator.capacityBlocked)
    coordinator.begin()
    XCTAssertFalse(coordinator.busy)
    let dismissed = try await store.get(entry.id)
    try await coordinator.deleteOrThrow(XCTUnwrap(dismissed))
    XCTAssertFalse(coordinator.capacityBlocked)
    coordinator.begin()
    try await waitUntil { coordinator.state == .recording }
    coordinator.cancel()
    try await waitUntil { !coordinator.busy }
  }

  private func makeCoordinator(
    store: TranscriptionStore? = nil,
    lifecycle: ModelLifecycleCoordinator? = nil,
    capture: any AudioCapturing,
    insertion: (any TextInserting)? = nil,
    mailbox: ControlMailbox = ControlMailbox()
  ) throws -> DictationCoordinator {
    let actualStore: TranscriptionStore
    if let store { actualStore = store } else { actualStore = try makeStore() }
    let actualLifecycle = lifecycle ?? ModelLifecycleCoordinator { FakeRuntime() }
    let actualInsertion = insertion ?? FakeInsertion()
    let spoolRoot = try makeSpoolRoot()
    ownedDirectories.append(spoolRoot)
    return DictationCoordinator(
      store: actualStore, lifecycle: actualLifecycle, capture: capture, insertion: actualInsertion,
      spoolRoot: spoolRoot, mailbox: mailbox)
  }

  private func makeStore() throws -> TranscriptionStore {
    let directory = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("LocalFlowStore-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    ownedDirectories.append(directory)
    return try TranscriptionStore(path: directory.appendingPathComponent("history.sqlite").path)
  }

  private func waitUntil(
    _ predicate: @escaping @MainActor () -> Bool
  ) async throws {
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
}
