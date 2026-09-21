import XCTest

@testable import LocalFlow

/// T082 — FR-037: `1 MIN READ` is `ceil(words / 200)` over the rendered prose
/// (summary, topics and items), minimum one minute. The value is computed on
/// the Mac; no wire field is consulted.
final class ReadingTimeTests: XCTestCase {

  func testEmptyModelIsOneMinute() {
    XCTAssertEqual(ReadingTime.minutes(for: model()), 1)
  }

  func testTwoHundredWordsIsOneMinute() {
    let read = model(summary: words(200))
    XCTAssertEqual(ReadingTime.minutes(for: read), 1)
  }

  func testTwoHundredOneWordsRoundsUpToTwo() {
    let read = model(summary: words(201))
    XCTAssertEqual(ReadingTime.minutes(for: read), 2)
  }

  func testEveryRenderedSectionCounts() {
    // 100 summary + 50 topic title/summary + 50 bullets + 50 items = 250 → 2.
    let read = model(
      summary: words(100),
      topics: [topic(title: words(25), summary: words(25), bullets: [words(50)])],
      actionItems: [action(text: words(25))],
      decisions: [item(text: words(25))])
    XCTAssertEqual(ReadingTime.minutes(for: read), 2)
  }

  /// The wire result carries no reading time: two models with identical
  /// `generatedAt`/`backendModel` metadata still derive the minutes only from
  /// the prose.
  func testMinutesIgnoreRunMetadata() {
    var read = model(summary: words(400))
    read.backendModel = "some-server-model"
    read.generatedAt = 9_999
    XCTAssertEqual(ReadingTime.minutes(for: read), 2)
  }

  // MARK: Helpers

  private func words(_ count: Int) -> String {
    (1...count).map { "w\($0)" }.joined(separator: " ")
  }

  private func topic(title: String, summary: String, bullets: [String]) -> TopicReadModel {
    TopicReadModel(
      id: UUID(), title: title, summary: summary, bullets: bullets, sources: [])
  }

  private func item(text: String) -> ItemReadModel {
    ItemReadModel(
      id: UUID(), kind: .decision, ordinal: 1, text: text, aiText: text, sources: [])
  }

  private func action(text: String) -> ActionItemReadModel {
    ActionItemReadModel(
      id: UUID(), ordinal: 1, text: text, aiText: text, owner: .unresolved(label: "Speaker 1"),
      aiOwner: .unresolved(label: "Speaker 1"), ownershipState: .unresolved,
      dueDate: nil, dueOriginal: nil, dueState: .absent, status: .open, sources: [])
  }

  private func model(
    summary: String = "", topics: [TopicReadModel] = [],
    actionItems: [ActionItemReadModel] = [], nextSteps: [ItemReadModel] = [],
    decisions: [ItemReadModel] = [], openQuestions: [ItemReadModel] = [],
    risks: [ItemReadModel] = []
  ) -> MeetingAnalysisReadModel {
    MeetingAnalysisReadModel(
      summary: SummaryReadModel(text: summary, aiText: summary, edited: false, sources: []),
      topics: topics, actionItems: actionItems, nextSteps: nextSteps,
      decisions: decisions, openQuestions: openQuestions, risks: risks,
      previousEdits: [], readingMinutes: 1, evidenceVersion: "", stale: false,
      generatedAt: 0, backendModel: "")
  }
}
