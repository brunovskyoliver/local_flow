import Foundation
import XCTest

@testable import LocalFlow

/// Commit failures are permanent for this store, so the coordinator must keep
/// the one in-memory result instead of assuming a later attempt will succeed.
private actor UnsavableStore: TranscriptionStoring {
  let base: TranscriptionStore
  private(set) var commitAttempts = 0
  private var allowCommit = false

  init(_ base: TranscriptionStore) { self.base = base }
  func permitCommit() { allowCommit = true }

  func verifyWritable() async throws { try await base.verifyWritable() }
  func reserve(maxBytes: Int) async throws -> TranscriptionStore.Reservation {
    try await base.reserve(maxBytes: maxBytes)
  }
  func commit(reservation: TranscriptionStore.Reservation, entry: TranscriptionEntry) async throws
    -> TranscriptionEntry
  {
    commitAttempts += 1
    guard allowCommit else { throw TranscriptionStore.Error.databaseLimitExceeded }
    return try await base.commit(reservation: reservation, entry: entry)
  }
  func releaseReservation(_ reservation: TranscriptionStore.Reservation) async {
    await base.releaseReservation(reservation)
  }
  func recent(limit: Int) async throws -> [TranscriptionEntry] {
    try await base.recent(limit: limit)
  }
  func get(_ id: UUID) async throws -> TranscriptionEntry? { try await base.get(id) }
  func beginAttempt(id: UUID, revision: Int64) async throws -> TranscriptionStore.Attempt {
    try await base.beginAttempt(id: id, revision: revision)
  }
  func recordOutcome(
    id: UUID, revision: Int64, attemptID: UUID, outcome: TranscriptionStore.Outcome
  ) async throws -> TranscriptionEntry {
    try await base.recordOutcome(
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
final class UnsavedResultTests: XCTestCase {
  private enum TestTimeout: Error { case expired }
  private var ownedRoots: [URL] = []

  override func tearDown() async throws {
    for root in ownedRoots.reversed() { try? FileManager.default.removeItem(at: root) }
    ownedRoots.removeAll()
  }

  /// One bounded result survives the failed save, carries its session identity
  /// and stop reason, warns that it is not durable and blocks another capture.
  func testSaveFailureKeepsOneBoundedWarnedResultAndBlocksCapture() async throws {
    let store = UnsavableStore(try makeStore())
    let capture = FakeCapture()
    let insertion = FakeInsertion()
    let coordinator = makeCoordinator(store: store, capture: capture, insertion: insertion)

    coordinator.begin()
    try await waitUntil { coordinator.state == .recording }
    let sessionID = try XCTUnwrap(coordinator.controlTag?.sessionID)
    coordinator.release()
    try await waitUntil { !coordinator.busy }

    let unsaved = try XCTUnwrap(coordinator.unsaved)
    XCTAssertEqual(unsaved.id, sessionID, "The result keeps its session identity for retry")
    XCTAssertEqual(unsaved.stopReason, .keyRelease)
    XCTAssertEqual(unsaved.quality, .complete)
    XCTAssertLessThanOrEqual(unsaved.text.utf8.count, 65_536)
    XCTAssertTrue(coordinator.status.contains("unsaved"), coordinator.status)
    XCTAssertEqual(insertion.dispatchCount, 0, "Unsaved text must never be delivered")

    XCTAssertFalse(coordinator.canBegin)
    let startsBefore = await capture.starts
    coordinator.begin()
    try await waitUntil { !coordinator.busy }
    let startsAfter = await capture.starts
    XCTAssertEqual(startsAfter, startsBefore, "An unsaved result must block a new recording")

    // A second failure keeps exactly one result rather than accumulating them.
    await coordinator.retrySave()
    XCTAssertEqual(try XCTUnwrap(coordinator.unsaved).id, unsaved.id)
    let attempts = await store.commitAttempts
    XCTAssertEqual(attempts, 2)
  }

  /// Copy is a clipboard action only. It must not resolve the loss risk.
  func testCopyDoesNotClearUnsavedStateAndRetryUsesTheSameRow() async throws {
    let real = try makeStore()
    let store = UnsavableStore(real)
    let coordinator = makeCoordinator(store: store, capture: FakeCapture())

    coordinator.begin()
    try await waitUntil { coordinator.state == .recording }
    coordinator.release()
    try await waitUntil { !coordinator.busy }
    let unsaved = try XCTUnwrap(coordinator.unsaved)

    coordinator.copy(unsaved.text)
    XCTAssertEqual(coordinator.unsaved, unsaved, "Copy must leave the unsaved result in place")
    XCTAssertFalse(coordinator.canBegin)

    await store.permitCommit()
    await coordinator.retrySave()
    XCTAssertNil(coordinator.unsaved)
    let rows = try await real.recent(limit: 20)
    XCTAssertEqual(rows.count, 1, "Retry reuses the reserved row instead of adding another")
    XCTAssertEqual(rows.first?.id, unsaved.id)
    XCTAssertEqual(rows.first?.text, unsaved.text)
    XCTAssertTrue(coordinator.canBegin)
  }

  /// Discarding is explicit, releases the reservation and frees capture again.
  func testConfirmedDiscardReleasesTheReservationAndUnblocksCapture() async throws {
    let real = try makeStore()
    let store = UnsavableStore(real)
    let capture = FakeCapture()
    let coordinator = makeCoordinator(store: store, capture: capture)

    coordinator.begin()
    try await waitUntil { coordinator.state == .recording }
    coordinator.release()
    try await waitUntil { !coordinator.busy }
    XCTAssertNotNil(coordinator.unsaved)

    await coordinator.discardUnsaved()
    XCTAssertNil(coordinator.unsaved)
    XCTAssertTrue(coordinator.status.contains("discarded"), coordinator.status)
    XCTAssertTrue(coordinator.canBegin)
    let rows = try await real.recent(limit: 20)
    XCTAssertTrue(rows.isEmpty, "A discarded result is never persisted")

    await store.permitCommit()
    let startsBefore = await capture.starts
    coordinator.begin()
    try await waitUntil { coordinator.state == .recording }
    coordinator.release()
    try await waitUntil { !coordinator.busy }
    let startsAfter = await capture.starts
    XCTAssertEqual(startsAfter, startsBefore + 1, "Capture resumes after an explicit discard")
  }

  /// Dismissing recovery resolves the review state but not the delivery fact.
  /// The duplication warning must survive it, or a second insertion looks safe.
  func testDuplicateWarningSurvivesRecoveryDismissal() async throws {
    let store = try makeStore()
    let coordinator = makeCoordinator(store: store, capture: FakeCapture())
    let explicit = ExplicitInsertionCoordinator(
      store: store, insertion: FakeInsertion(), dictation: coordinator, presentsPanel: false)

    let entry = try TranscriptionEntry(
      id: UUID(), text: "saved text",
      createdAtMilliseconds: Int64(Date().timeIntervalSince1970 * 1000),
      quality: .complete, stopReason: .keyRelease)
    let saved = try await store.commit(reservation: try await store.reserve(), entry: entry)
    let attempt = try await store.beginAttempt(id: saved.id, revision: saved.revision)
    let uncertain = try await store.recordOutcome(
      id: saved.id, revision: attempt.entry.revision, attemptID: attempt.id, outcome: .uncertain)

    XCTAssertTrue(explicit.beginReview(uncertain))
    XCTAssertTrue(explicit.warnings.contains { $0.contains("already be in the destination") })
    explicit.cancel()

    let dismissed = try await store.dismissRecovery(id: saved.id, revision: uncertain.revision)
    XCTAssertEqual(dismissed.recoveryState, .resolved)
    XCTAssertEqual(dismissed.deliveryState, .uncertain)
    XCTAssertTrue(explicit.beginReview(dismissed))
    XCTAssertTrue(
      explicit.warnings.contains { $0.contains("already be in the destination") },
      "Dismissal resolves review, not the uncertain delivery")
    explicit.cancel()
  }

  private func makeCoordinator(
    store: any TranscriptionStoring, capture: any AudioCapturing,
    insertion: FakeInsertion = FakeInsertion()
  ) -> DictationCoordinator {
    DictationCoordinator(
      store: store, lifecycle: ModelLifecycleCoordinator { FakeRuntime() },
      capture: capture, insertion: insertion, spoolRoot: makeRoot(name: "spool"))
  }

  private func makeStore() throws -> TranscriptionStore {
    try TranscriptionStore(
      path: makeRoot(name: "store").appendingPathComponent("history.sqlite").path)
  }

  private func makeRoot(name: String) -> URL {
    let root = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("LocalFlowUnsaved-\(name)-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(
      at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    ownedRoots.append(root)
    return root
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
}
