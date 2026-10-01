import GRDB
import XCTest

@testable import LocalFlow
@testable import LocalFlowCore

@MainActor
final class HistoryViewModelTests: XCTestCase {
  private var harness: PhoneHarness!

  override func setUp() async throws { harness = try PhoneHarness() }
  override func tearDown() async throws { harness = nil }

  private func save(_ text: String, source: PhoneDictationStore.Source, at seconds: Double)
    async throws -> UUID
  {
    let id = UUID()
    try await harness.dictations.save(
      .init(
        id: id, text: text, createdAt: Date(timeIntervalSince1970: seconds), source: source,
        durationMilliseconds: 1_000, quality: .complete, stopReason: .keyRelease,
        endDetail: nil, sessionID: UUID(), detail: nil))
    return id
  }

  func testEntriesAreNewestFirstFromBothSources() async throws {
    _ = try await save("first note", source: .app, at: 1_790_000_000)
    let keyboard = try await save("from the keyboard", source: .keyboard, at: 1_790_000_100)
    _ = try await save("last note", source: .app, at: 1_790_000_200)
    try await harness.dictations.markDelivery(dictationID: keyboard, .inserted)
    let model = HistoryViewModel(store: harness.dictations)
    await model.refresh()
    XCTAssertEqual(model.items.map(\.text), ["last note", "from the keyboard", "first note"])
    XCTAssertEqual(model.items.map(\.source), ["Note", "Keyboard", "Note"])
    XCTAssertEqual(model.items[1].delivery, "Inserted")
    XCTAssertEqual(model.items[0].delivery, "Saved")
    XCTAssertFalse(model.items.contains(where: \.needsReview))
  }

  func testDeleteRemovesBothRows() async throws {
    let id = try await save("delete me", source: .keyboard, at: 1_790_000_000)
    let model = HistoryViewModel(store: harness.dictations)
    await model.refresh()
    await model.delete(id)
    XCTAssertTrue(model.items.isEmpty)
    XCTAssertEqual(try harness.rowCount(), 0)
    let phone = try await harness.history.database.read {
      try Int.fetchOne($0, sql: "SELECT count(*) FROM phone_dictations") ?? -1
    }
    XCTAssertEqual(phone, 0)
  }
}

extension HistoryViewModelTests {
  func testARecoveredEntryIsMarkedForReview() async throws {
    try await harness.dictations.save(
      .init(
        id: UUID(), text: "recovered", createdAt: Date(), source: .keyboard,
        durationMilliseconds: 1_000, quality: .incomplete, stopReason: .failure,
        endDetail: .recoveredAfterTermination, sessionID: nil, detail: nil))
    let model = HistoryViewModel(store: harness.dictations)
    await model.refresh()
    XCTAssertEqual(model.items.map(\.needsReview), [true])
  }
}
