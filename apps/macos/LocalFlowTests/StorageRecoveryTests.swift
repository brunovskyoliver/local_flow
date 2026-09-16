import Foundation
import XCTest

@testable import LocalFlow

/// A forwarding actor makes persistence failures deterministic without replacing the real
/// SQLite implementation used by the coordinator.
private actor FaultingStore: TranscriptionStoring {
  let base: TranscriptionStore
  var failCommit = false
  var failBeginAttempt = false
  var failOutcome = false
  var failWriteProbe = false

  init(_ base: TranscriptionStore) { self.base = base }

  func setWriteProbeFailure() { failWriteProbe = true }
  func verifyWritable() async throws {
    if failWriteProbe {
      failWriteProbe = false
      throw TranscriptionStore.Error.databaseLimitExceeded
    }
    try await base.verifyWritable()
  }

  func reserve(maxBytes: Int) async throws -> TranscriptionStore.Reservation {
    try await base.reserve(maxBytes: maxBytes)
  }

  func commit(reservation: TranscriptionStore.Reservation, entry: TranscriptionEntry) async throws
    -> TranscriptionEntry
  {
    if failCommit {
      failCommit = false
      throw TranscriptionStore.Error.databaseLimitExceeded
    }
    return try await base.commit(reservation: reservation, entry: entry)
  }

  func releaseReservation(_ reservation: TranscriptionStore.Reservation) async {
    await base.releaseReservation(reservation)
  }

  func recent(limit: Int) async throws -> [TranscriptionEntry] {
    try await base.recent(limit: limit)
  }

  func get(_ id: UUID) async throws -> TranscriptionEntry? {
    try await base.get(id)
  }

  func beginAttempt(id: UUID, revision: Int64) async throws -> TranscriptionStore.Attempt {
    if failBeginAttempt {
      failBeginAttempt = false
      throw TranscriptionStore.Error.databaseLimitExceeded
    }
    return try await base.beginAttempt(id: id, revision: revision)
  }

  func recordOutcome(
    id: UUID, revision: Int64, attemptID: UUID, outcome: TranscriptionStore.Outcome
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

@MainActor
final class StorageRecoveryTests: XCTestCase {
  private var ownedRoots: [URL] = []

  override func tearDown() async throws {
    for root in ownedRoots.reversed() { try? FileManager.default.removeItem(at: root) }
    ownedRoots.removeAll()
  }

  func testFailedCommitKeepsUnsavedTextAndRetryUsesOneStableRow() async throws {
    let realStore = try makeStore()
    let store = FaultingStore(realStore)
    await store.setCommitFailure()
    let insertion = FakeInsertion()
    let coordinator = makeCoordinator(store: store, insertion: insertion)

    coordinator.begin()
    try await waitUntil { coordinator.state == .recording }
    coordinator.release()
    try await waitUntil { !coordinator.busy }

    let unsaved = try XCTUnwrap(coordinator.unsaved)
    XCTAssertTrue(coordinator.storageBlocked == false)
    let blockedStartCount = insertion.dispatchCount
    coordinator.begin()
    let afterBlockedStartCount = insertion.dispatchCount
    XCTAssertEqual(afterBlockedStartCount, blockedStartCount)

    await coordinator.retrySave()
    XCTAssertNil(coordinator.unsaved)
    let rows = try await realStore.recent(limit: 20)
    XCTAssertEqual(rows.count, 1)
    XCTAssertEqual(rows[0].id, unsaved.id)
    XCTAssertEqual(rows[0].text, unsaved.text)
  }

  func testFailedBeginAttemptBlocksDeliveryWithoutDispatch() async throws {
    let realStore = try makeStore()
    let store = FaultingStore(realStore)
    await store.setBeginAttemptFailure()
    let insertion = FakeInsertion()
    let coordinator = makeCoordinator(store: store, insertion: insertion)

    coordinator.begin()
    try await waitUntil { coordinator.state == .recording }
    coordinator.release()
    try await waitUntil { !coordinator.busy }

    XCTAssertTrue(coordinator.storageBlocked)
    let beginDispatchCount = insertion.dispatchCount
    XCTAssertEqual(beginDispatchCount, 0)
    let beginRows = try await realStore.recent(limit: 1)
    let row = try XCTUnwrap(beginRows.first)
    XCTAssertEqual(row.deliveryState, .notAttempted)

    await store.setWriteProbeFailure()
    await coordinator.retryStorage()
    XCTAssertTrue(coordinator.storageBlocked)
    XCTAssertEqual(insertion.dispatchCount, 0)
    await coordinator.retryStorage()
    XCTAssertFalse(coordinator.storageBlocked)
  }

  func testFailedOutcomeLeavesAttemptingRowAndRetryResolvesWithoutRedispatch() async throws {
    let realStore = try makeStore()
    let store = FaultingStore(realStore)
    await store.setOutcomeFailure()
    let insertion = FakeInsertion()
    let coordinator = makeCoordinator(store: store, insertion: insertion)

    coordinator.begin()
    try await waitUntil { coordinator.state == .recording }
    coordinator.release()
    try await waitUntil { !coordinator.busy }

    XCTAssertTrue(coordinator.storageBlocked)
    let dispatchCount = insertion.dispatchCount
    XCTAssertEqual(dispatchCount, 1)
    let attemptingRows = try await realStore.recent(limit: 1)
    let attempting = try XCTUnwrap(attemptingRows.first)
    XCTAssertEqual(attempting.deliveryState, .attempting)

    await coordinator.retryStorage()
    XCTAssertFalse(coordinator.storageBlocked)
    let afterRetryDispatchCount = insertion.dispatchCount
    XCTAssertEqual(afterRetryDispatchCount, dispatchCount)
    let resolvedRows = try await realStore.recent(limit: 1)
    let resolved = try XCTUnwrap(resolvedRows.first)
    XCTAssertEqual(resolved.deliveryState, .confirmed)
    XCTAssertEqual(resolved.recoveryState, .resolved)
  }

  private func makeCoordinator(store: any TranscriptionStoring, insertion: FakeInsertion)
    -> DictationCoordinator
  {
    let lifecycle = ModelLifecycleCoordinator { FakeRuntime() }
    let spool = makeRoot(name: "spool")
    return DictationCoordinator(
      store: store, lifecycle: lifecycle, capture: FakeCapture(), insertion: insertion,
      spoolRoot: spool)
  }

  private func makeStore() throws -> TranscriptionStore {
    let root = makeRoot(name: "store")
    return try TranscriptionStore(path: root.appendingPathComponent("history.sqlite").path)
  }

  private func makeRoot(name: String) -> URL {
    let root = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("LocalFlowRecovery-\(name)-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(
      at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    ownedRoots.append(root)
    return root
  }

  private func waitUntil(_ predicate: @escaping @MainActor () -> Bool) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(5))
    while !predicate() {
      guard clock.now < deadline else { throw TestTimeout.expired }
      await Task.yield()
    }
  }

  private enum TestTimeout: Error { case expired }
}

extension FaultingStore {
  fileprivate func setCommitFailure() { failCommit = true }
  fileprivate func setBeginAttemptFailure() { failBeginAttempt = true }
  fileprivate func setOutcomeFailure() { failOutcome = true }
}
