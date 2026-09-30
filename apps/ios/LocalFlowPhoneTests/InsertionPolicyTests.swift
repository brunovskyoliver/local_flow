import XCTest

@testable import LocalFlow

final class InsertionPolicyTests: XCTestCase {
  func testInsertsOnlyWhenVisibleMatchingAndSameDocument() {
    let request = UUID()
    let document = UUID()
    for visible in [true, false] {
      for requestMatches in [true, false] {
        for documentMatches in [true, false] {
          let decision = InsertionPolicy.decide(
            visible: visible, pendingRequestID: request,
            resultRequestID: requestMatches ? request : UUID(), documentIDAtStart: document,
            documentIDNow: documentMatches ? document : UUID())
          let expected: InsertionPolicy.Decision =
            visible && requestMatches && documentMatches ? .insert : .offer
          XCTAssertEqual(
            decision, expected,
            "visible \(visible) request \(requestMatches) doc \(documentMatches)")
        }
      }
    }
  }

  func testMissingPendingRequestOrDocumentOffers() {
    let request = UUID()
    XCTAssertEqual(
      InsertionPolicy.decide(
        visible: true, pendingRequestID: nil, resultRequestID: request, documentIDAtStart: UUID(),
        documentIDNow: UUID()), .offer)
    XCTAssertEqual(
      InsertionPolicy.decide(
        visible: true, pendingRequestID: request, resultRequestID: request, documentIDAtStart: nil,
        documentIDNow: nil), .offer)
  }

  func testUndoRule() {
    let at = Date(timeIntervalSince1970: 100)
    func undo(_ seconds: TimeInterval, _ context: String?, changed: Bool = false) -> Bool {
      InsertionPolicy.canUndo(
        inserted: "Hello there.", insertedAt: at, now: at.addingTimeInterval(seconds),
        contextBefore: context, textChangedSince: changed)
    }
    XCTAssertTrue(undo(1, "Note: Hello there."))
    XCTAssertFalse(undo(10, "Note: Hello there."), "10 s at most")
    XCTAssertFalse(undo(1, "Note: Hello there. More"), "text after the insertion")
    XCTAssertFalse(undo(1, nil), "nil context hides Undo")
    XCTAssertFalse(undo(1, "Note: Hello there.", changed: true), "until the next text change")
  }

  func testOutcomeMessages() {
    XCTAssertEqual(InsertionPolicy.message(for: .empty), "Didn't catch that")
    XCTAssertNotNil(InsertionPolicy.message(for: .failed))
    XCTAssertNil(InsertionPolicy.message(for: .busy))
    XCTAssertNil(InsertionPolicy.message(for: .noSession))
  }
}
