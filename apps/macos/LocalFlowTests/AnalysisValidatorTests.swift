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

  // MARK: T044 — source validation

  private func evidenceWithNotes() -> AnalysisEvidence {
    var evidence = evidence()
    evidence.notes = [
      NoteParagraph(ordinal: 1, text: "First note.", hash: EvidenceVersion.hash(paragraph: "First note.")),
      NoteParagraph(ordinal: 2, text: "Second note.", hash: EvidenceVersion.hash(paragraph: "Second note.")),
    ]
    return evidence
  }

  private func assertSourceFailure(_ result: AnalysisResult, detail: String? = nil) {
    XCTAssertThrowsError(
      try AnalysisValidator.validate(
        result: result, against: evidenceWithNotes(), policy: policy)
    ) { error in
      let failure = error as? AnalysisFailure
      XCTAssertEqual(failure?.category, .sourceValidation)
      if let detail { XCTAssertEqual(failure?.detail, detail) }
    }
  }

  /// A segment id absent from the final pass fails the run.
  func testUnknownSegmentFails() {
    assertSourceFailure(
      result(decisions: [wireItem("Fabricated", sources: [.segment(UUID())])]),
      detail: "unknown_segment")
  }

  /// A segment id minted for another meeting is equally foreign.
  func testCrossMeetingSegmentFails() throws {
    let other = try IntelligenceFixtures.meeting("slovak")
    let foreign = try XCTUnwrap(other.segments.first?.id)
    assertSourceFailure(
      result(decisions: [wireItem("Borrowed", sources: [.segment(foreign)])]),
      detail: "unknown_segment")
  }

  /// A note ordinal beyond the paragraph count fails.
  func testNoteOrdinalBeyondParagraphsFails() {
    assertSourceFailure(
      result(decisions: [wireItem("Note nine", sources: [.note(9)])]),
      detail: "unknown_note")
    assertSourceFailure(
      result(decisions: [wireItem("Note zero", sources: [.note(0)])]),
      detail: "unknown_note")
  }

  /// The resolved note ref carries the current paragraph's hash; when the
  /// paragraph's content changes, a newly resolved ref carries the new hash —
  /// the "This note has changed" check compares against it.
  func testNoteRefCarriesCurrentHash() throws {
    var evidence = evidenceWithNotes()
    let (validated, _) = try AnalysisValidator.validate(
      result: result(decisions: [wireItem("Backed by a note", sources: [.note(1)])]),
      against: evidence, policy: policy)
    guard case .note(let ordinal, let hash)? = validated.decisions.first?.sources.first
    else { return XCTFail("expected a note source") }
    XCTAssertEqual(ordinal, 1)
    XCTAssertEqual(hash, EvidenceVersion.hash(paragraph: "First note."))

    evidence.notes[0] = NoteParagraph(
      ordinal: 1, text: "Changed note.",
      hash: EvidenceVersion.hash(paragraph: "Changed note."))
    let (updated, _) = try AnalysisValidator.validate(
      result: result(decisions: [wireItem("Backed by a note", sources: [.note(1)])]),
      against: evidence, policy: policy)
    guard case .note(_, let newHash)? = updated.decisions.first?.sources.first
    else { return XCTFail("expected a note source") }
    XCTAssertNotEqual(newHash, hash)
  }

  /// More than ten references on one target fails.
  func testOverTenSourcesFails() {
    let many = Array(repeating: [WireSourceRef.segment(segA), .segment(segB)], count: 6)
      .flatMap { $0 }
    assertSourceFailure(
      result(decisions: [wireItem("Too many", sources: many)]), detail: "too_many_sources")
  }

  /// Each of the five item kinds requires at least one source.
  func testItemKindsRequireOneSource() {
    assertSourceFailure(
      result(decisions: [wireItem("No source", sources: [])]), detail: "missing_source")
    assertSourceFailure(
      result(actionItems: [action("No source", sources: [])]), detail: "missing_source")
    assertSourceFailure(
      result(nextSteps: [wireItem("No source", sources: [])]), detail: "missing_source")
    var questions = result()
    questions.openQuestions = [wireItem("No source", sources: [])]
    assertSourceFailure(questions, detail: "missing_source")
    var risks = result()
    risks.risks = [wireItem("No source", sources: [])]
    assertSourceFailure(risks, detail: "missing_source")
  }

  /// A summary with zero references or `whole_meeting: true` passes; a topic
  /// may be broad.
  func testSummaryWithoutSourcesPasses() throws {
    var bare = result()
    bare.summary = WireSummary(text: "Broad strokes.", sources: [], wholeMeeting: false)
    let (validated, _) = try AnalysisValidator.validate(
      result: bare, against: evidenceWithNotes(), policy: policy)
    XCTAssertEqual(validated.summary.text, "Broad strokes.")
  }

  /// A note-typed reference keeps `source_kind = note` through validation.
  func testNoteSourceKindSurvives() throws {
    let (validated, _) = try AnalysisValidator.validate(
      result: result(decisions: [wireItem("Noted", sources: [.note(2)])]),
      against: evidenceWithNotes(), policy: policy)
    guard case .note(let ordinal, _)? = validated.decisions.first?.sources.first
    else { return XCTFail("expected a note source") }
    XCTAssertEqual(ordinal, 2)
  }
}
