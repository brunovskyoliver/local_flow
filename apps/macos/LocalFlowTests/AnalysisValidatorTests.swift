import XCTest

@testable import LocalFlow

/// T031 — the validator skeleton: meeting-id check, the duplicate rule and the
/// partial merge; the other stages are pass-through stubs for now.
final class AnalysisValidatorTests: XCTestCase {
  private let meetingID = UUID()
  private let segA = UUID()
  private let segB = UUID()

  private func evidence() -> AnalysisEvidence {
    AnalysisEvidence(meetingID: meetingID, segmentIDs: [segA, segB])
  }

  private func wireItem(_ text: String, sources: [WireSourceRef]) -> WireItem {
    WireItem(text: text, sources: sources)
  }

  private func result(
    meetingID: UUID? = nil,
    actionItems: [WireActionItem] = [], nextSteps: [WireItem] = [],
    decisions: [WireItem] = []
  ) -> AnalysisResult {
    AnalysisResult(
      schemaVersion: 1, meetingID: meetingID ?? self.meetingID, partial: false,
      language: .en,
      summary: WireSummary(text: "A meeting.", sources: [], wholeMeeting: true),
      topics: [], decisions: decisions, actionItems: actionItems,
      nextSteps: nextSteps, openQuestions: [], risks: [])
  }

  private func action(_ text: String, sources: [WireSourceRef]) -> WireActionItem {
    WireActionItem(
      text: text, owner: WireOwner(kind: .none),
      ownershipState: .unresolved, due: WireDue(state: .absent), sources: sources)
  }

  private let policy = AnalysisPolicy()

  func testMeetingMismatchFails() {
    let result = result(meetingID: UUID())
    XCTAssertThrowsError(
      try AnalysisValidator.validate(
        result: result, against: evidence(), policy: policy)
    ) { error in
      XCTAssertEqual(
        (error as? AnalysisFailure)?.category, .meetingMismatch)
    }
  }

  func testNextStepIdenticalToActionItemIsDroppedUncounted() throws {
    let source = WireSourceRef.segment(segA)
    let result = result(
      actionItems: [action("Ship the release", sources: [source])],
      nextSteps: [wireItem("Ship the release!", sources: [WireSourceRef.segment(segB)])])
    let (validated, counts) = try AnalysisValidator.validate(
      result: result, against: evidence(), policy: policy)
    XCTAssertTrue(validated.nextSteps.isEmpty)
    XCTAssertEqual(validated.actionItems.count, 1)
    XCTAssertEqual(counts.droppedUnsupportedCount, 0)
    XCTAssertEqual(counts.droppedLiteralCount, 0)
    XCTAssertEqual(counts.itemCount, 1)
  }

  func testDistinctNextStepSurvives() throws {
    let source = WireSourceRef.segment(segA)
    let result = result(
      actionItems: [action("Ship the release", sources: [source])],
      nextSteps: [wireItem("Book the retro", sources: [source])])
    let (validated, _) = try AnalysisValidator.validate(
      result: result, against: evidence(), policy: policy)
    XCTAssertEqual(validated.nextSteps.count, 1)
  }

  func testIdenticalSourceSetAndTextMerges() throws {
    let source = WireSourceRef.segment(segA)
    let result = result(
      decisions: [
        wireItem("Deploy on Monday", sources: [source]),
        wireItem("Deploy on Monday.", sources: [source]),
        wireItem("Deploy on Monday", sources: [WireSourceRef.segment(segB)]),
      ])
    let (validated, _) = try AnalysisValidator.validate(
      result: result, against: evidence(), policy: policy)
    // First and second collapse (same sources, same normalized text); the
    // third has a different source set and survives.
    XCTAssertEqual(validated.decisions.count, 2)
  }

  func testActionItemsMergeToo() throws {
    let source = WireSourceRef.segment(segA)
    let result = result(
      actionItems: [
        action("Call the vendor", sources: [source]),
        action("Call the vendor", sources: [source]),
      ])
    let (validated, _) = try AnalysisValidator.validate(
      result: result, against: evidence(), policy: policy)
    XCTAssertEqual(validated.actionItems.count, 1)
  }
}
