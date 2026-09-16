import Foundation
import XCTest

@testable import LocalFlow

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

  func testReplacementSearchAndBoundedNavigation() async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
      "history-vm-\(UUID()).sqlite")
    defer { try? FileManager.default.removeItem(at: url) }
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
    for _ in 0..<3 {
      model.older()
      try await waitForQuery(model)
      XCTAssertLessThanOrEqual(model.entries.count, 20)
      XCTAssertLessThanOrEqual(model.residentTextBytes, 20 * 65_536)
    }
    for _ in 0..<3 {
      model.newer()
      try await waitForQuery(model)
    }
    XCTAssertEqual(model.entries.map(\.id), firstIDs)
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

  func testIndependentBadgesAndCalendarRegrouping() async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
      "history-date-\(UUID()).sqlite")
    defer { try? FileManager.default.removeItem(at: url) }
    let store = try TranscriptionStore(path: url.path)
    let date = Date(timeIntervalSince1970: 1_800_000_000)
    let entry = try TranscriptionEntry(
      id: UUID(), text: "Partial text",
      createdAtMilliseconds: Int64(date.timeIntervalSince1970 * 1000), quality: .durationLimited,
      stopReason: .durationLimit)
    let saved = try await store.commit(reservation: try await store.reserve(), entry: entry)
    let dismissed = try await store.dismissRecovery(id: saved.id, revision: saved.revision)
    XCTAssertEqual(saved.qualityLabel, "Cut short at 180 seconds")
    XCTAssertEqual(saved.recoveryLabel, "Needs insertion")
    XCTAssertEqual(dismissed.qualityLabel, saved.qualityLabel)
    XCTAssertNil(dismissed.recoveryLabel)
    let attempt = try await store.beginAttempt(id: saved.id, revision: dismissed.revision)
    let uncertain = try await store.recordOutcome(
      id: saved.id, revision: attempt.entry.revision,
      attemptID: attempt.id, outcome: .uncertain)
    XCTAssertEqual(uncertain.recoveryLabel, "Delivery uncertain")
    let resolvedUncertain = try await store.dismissRecovery(
      id: saved.id, revision: uncertain.revision)
    XCTAssertNil(resolvedUncertain.recoveryLabel)
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
    defer { try? FileManager.default.removeItem(at: url) }
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
    defer { try? FileManager.default.removeItem(at: url) }
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
    defer { try? FileManager.default.removeItem(at: url) }
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
      model.older()
      try await waitForQuery(model)
      XCTAssertLessThanOrEqual(model.entries.count, 40, "At most two pages stay resident")
      let selectedBytes = model.selectedEntry?.text.utf8.count ?? 0
      XCTAssertLessThanOrEqual(selectedBytes, 65_536)
      XCTAssertLessThanOrEqual(
        model.residentTextBytes + selectedBytes, 2_621_440 + 65_536,
        "Page text plus the selected row must stay inside the resident bound")
    }
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
