import XCTest

@testable import LocalFlow

/// Audit UI-07: row metadata is one wrapping string, so large text sizes don't clip it.
@MainActor
final class PhoneUIFormattingTests: XCTestCase {
  private func item(app: String?) -> HistoryViewModel.Item {
    .init(
      id: UUID(), text: "note", date: Date(timeIntervalSince1970: 1_790_000_000),
      source: "Keyboard", delivery: "Inserted", targetApp: app, needsReview: false)
  }

  func testHistoryMetadataJoinsEveryPartInOrder() {
    let parts = HistoryView.metadata(item(app: "com.apple.MobileSMS"))
      .components(separatedBy: " · ")
    XCTAssertEqual(parts.count, 4)
    XCTAssertEqual(Array(parts.suffix(3)), ["Keyboard", "Inserted", "com.apple.MobileSMS"])
  }

  func testHistoryMetadataLeavesOutAMissingApp() {
    let parts = HistoryView.metadata(item(app: nil)).components(separatedBy: " · ")
    XCTAssertEqual(Array(parts.suffix(2)), ["Keyboard", "Inserted"])
    XCTAssertEqual(parts.count, 3)
  }
}
