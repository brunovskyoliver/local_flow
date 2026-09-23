import XCTest

@testable import LocalFlow

/// T031 — the validator skeleton: meeting-id check, the duplicate rule and the
/// partial merge; the other stages are pass-through stubs for now.
final class AnalysisValidatorTests: XCTestCase {
  private let meetingID = UUID()
  private let segA = UUID()
  private let segB = UUID()

  private func evidence() -> AnalysisEvidence {
    // The lexical-support step (R6) requires at least one content token of
    // every item in its cited sources; both segments carry the test
    // vocabulary so fixture items survive it.
    let text =
      "we will ship the release and deploy on monday and call the vendor "
      + "and send the report and book the retro and finish the task "
      + "and complete the testing and notify the customer"
    return AnalysisEvidence(
      meetingID: meetingID, segmentIDs: [segA, segB],
      segmentText: [segA: text, segB: text])
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
      NoteParagraph(
        ordinal: 1, text: "First note.", hash: EvidenceVersion.hash(paragraph: "First note.")),
      NoteParagraph(
        ordinal: 2, text: "Second note.", hash: EvidenceVersion.hash(paragraph: "Second note.")),
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

extension AnalysisValidatorTests {
  // MARK: T052 — identity step

  private func action(
    _ text: String, owner: WireOwner,
    ownership: OwnershipState = .explicit, sources: [WireSourceRef]
  ) -> WireActionItem {
    WireActionItem(
      text: text, owner: owner, ownershipState: ownership,
      due: WireDue(state: .absent), sources: sources)
  }

  /// confirmed / recognized / local_name / local_user keep the owner and the
  /// certainty (spec US3 identity table, rows 1–4).
  func testPermittedCertaintiesKeepParticipantOwner() throws {
    for certainty in [ParticipantCertainty.confirmed, .recognized, .localName, .localUser] {
      let speaker = UUID()
      var evidence = evidence()
      evidence.participants = [
        EvidenceParticipant(
          speakerID: speaker, certainty: certainty, origin: "automatic_match",
          knownSpeakerID: UUID(), name: "Named")
      ]
      let result = result(actionItems: [
        action(
          "Do it", owner: WireOwner(kind: .participant, speakerID: speaker),
          sources: [.segment(segA)])
      ])
      let (validated, counts) = try AnalysisValidator.validate(
        result: result, against: evidence, policy: policy)
      let item = try XCTUnwrap(validated.actionItems.first)
      guard case .participant(let id, let known, let kept) = item.owner
      else { return XCTFail("certainty \(certainty): owner lost") }
      XCTAssertEqual(id, speaker)
      XCTAssertNotNil(known)
      XCTAssertEqual(kept, certainty)
      XCTAssertEqual(item.ownershipState, .explicit)
      XCTAssertEqual(counts.identityDowngradeCount, 0)
      XCTAssertEqual(counts.unresolvedOwnerCount, 0)
    }
  }

  /// possible / unknown drop to none + unresolved and count
  /// `identity_downgrade` (spec US3 identity table, rows 5–6) — and the run
  /// does not fail.
  func testUncertainParticipantsDowngrade() throws {
    for certainty in [ParticipantCertainty.possible, .unknown] {
      let speaker = UUID()
      var evidence = evidence()
      evidence.participants = [
        EvidenceParticipant(
          speakerID: speaker, certainty: certainty, origin: "possible",
          knownSpeakerID: nil, name: nil)
      ]
      let result = result(actionItems: [
        action(
          "Do it", owner: WireOwner(kind: .participant, speakerID: speaker),
          sources: [.segment(segA)])
      ])
      let (validated, counts) = try AnalysisValidator.validate(
        result: result, against: evidence, policy: policy)
      let item = try XCTUnwrap(validated.actionItems.first)
      XCTAssertEqual(item.owner, .none)
      XCTAssertEqual(item.ownershipState, .unresolved)
      XCTAssertEqual(counts.identityDowngradeCount, 1)
      XCTAssertEqual(counts.unresolvedOwnerCount, 1)
    }
  }

  /// A participant owner whose id is not in the evidence set becomes
  /// unresolved without counting an identity downgrade.
  func testUnknownParticipantOwnerUnresolved() throws {
    let result = result(actionItems: [
      action(
        "Do it", owner: WireOwner(kind: .participant, speakerID: UUID()),
        sources: [.segment(segA)])
    ])
    let (validated, counts) = try AnalysisValidator.validate(
      result: result, against: evidence(), policy: policy)
    let item = try XCTUnwrap(validated.actionItems.first)
    XCTAssertEqual(item.owner, ValidatedOwner.none)
    XCTAssertEqual(item.ownershipState, .unresolved)
    XCTAssertEqual(counts.identityDowngradeCount, 0)
    XCTAssertEqual(counts.unresolvedOwnerCount, 1)
  }

  /// A `mentioned` owner equal — case- and diacritic-insensitive — to a
  /// Possible-match candidate name downgrades (spec US3).
  func testMentionedMatchingCandidateDowngrades() throws {
    var evidence = evidence()
    evidence.possibleCandidateNames = ["Tomáš Juríček"]
    let result = result(actionItems: [
      action(
        "Do it", owner: WireOwner(kind: .mentioned, name: "tomas juricek"),
        sources: [.segment(segA)])
    ])
    let (validated, counts) = try AnalysisValidator.validate(
      result: result, against: evidence, policy: policy)
    let item = try XCTUnwrap(validated.actionItems.first)
    XCTAssertEqual(item.owner, .none)
    XCTAssertEqual(item.ownershipState, .unresolved)
    XCTAssertEqual(counts.identityDowngradeCount, 1)
    XCTAssertEqual(counts.unresolvedOwnerCount, 1)
  }

  /// A `mentioned` owner claiming `explicit` is capped at `supported` — the
  /// model cannot assert explicit ownership over a name it heard.
  func testMentionedExplicitCapsAtSupported() throws {
    let result = result(actionItems: [
      action(
        "Do it", owner: WireOwner(kind: .mentioned, name: "Someone New"),
        ownership: .explicit, sources: [.segment(segA)])
    ])
    let (validated, counts) = try AnalysisValidator.validate(
      result: result, against: evidence(), policy: policy)
    let item = try XCTUnwrap(validated.actionItems.first)
    XCTAssertEqual(item.owner, .mentioned(name: "Someone New"))
    XCTAssertEqual(item.ownershipState, .supported)
    XCTAssertEqual(counts.identityDowngradeCount, 0)
    XCTAssertEqual(counts.unresolvedOwnerCount, 0)
  }

  /// A mentioned name matching no candidate stays verbatim.
  func testMentionedWithoutCandidateStaysVerbatim() throws {
    var evidence = evidence()
    evidence.possibleCandidateNames = ["Katarína"]
    let result = result(actionItems: [
      action(
        "Do it", owner: WireOwner(kind: .mentioned, name: "Ingrid"),
        ownership: .supported, sources: [.segment(segA)])
    ])
    let (validated, counts) = try AnalysisValidator.validate(
      result: result, against: evidence, policy: policy)
    let item = try XCTUnwrap(validated.actionItems.first)
    XCTAssertEqual(item.owner, .mentioned(name: "Ingrid"))
    XCTAssertEqual(item.ownershipState, .supported)
    XCTAssertEqual(counts.identityDowngradeCount, 0)
  }

  // MARK: Due dates (T058)

  /// The due-dates fixture's anchor: Sunday 2026-09-20, Europe/Bratislava.
  private func dueEvidence() -> AnalysisEvidence {
    var evidence = evidence()
    evidence.meetingStartedAtMs = 1_789_887_600_000  // 2026-09-20T09:00:00+02:00
    evidence.meetingTimeZone = "Europe/Bratislava"
    return evidence
  }

  private func action(
    _ text: String, due: WireDue, sources: [WireSourceRef] = []
  ) -> WireActionItem {
    WireActionItem(
      text: text, owner: WireOwner(kind: .none), ownershipState: .unresolved,
      due: due, sources: sources.isEmpty ? [.segment(segA)] : sources)
  }

  /// `explicit_*` without a parseable date drops to `unresolved` and keeps
  /// the original phrase (contract due-date rules).
  func testExplicitWithoutDateBecomesUnresolved() throws {
    let result = result(actionItems: [
      action(
        "Send it",
        due: WireDue(
          state: .explicitRelativeResolved, date: "not-a-date",
          original: "tomorrow", source: .segment(segB))),
      action(
        "Send the report",
        due: WireDue(
          state: .explicitAbsolute, date: nil, original: "25 September",
          source: .segment(segB))),
    ])
    let (validated, _) = try AnalysisValidator.validate(
      result: result, against: dueEvidence(), policy: policy)
    XCTAssertEqual(validated.actionItems.count, 2)
    for item in validated.actionItems {
      XCTAssertEqual(item.due.state, .unresolved)
      XCTAssertNil(item.due.date)
      XCTAssertNotNil(item.due.original)
    }
  }

  /// `explicit_*` without a source drops to `unresolved`.
  func testExplicitWithoutSourceBecomesUnresolved() throws {
    let result = result(actionItems: [
      action(
        "Send it",
        due: WireDue(
          state: .explicitAbsolute, date: "2026-09-25",
          original: "25 September", source: nil))
    ])
    let (validated, _) = try AnalysisValidator.validate(
      result: result, against: dueEvidence(), policy: policy)
    let due = try XCTUnwrap(validated.actionItems.first).due
    XCTAssertEqual(due.state, .unresolved)
    XCTAssertNil(due.date)
    XCTAssertEqual(due.original, "25 September")
  }

  /// An explicit due whose source is fabricated does not fail the run — the
  /// item drops to `unresolved` (due validation is item-level).
  func testFabricatedDueSourceBecomesUnresolvedWithoutFailingRun() throws {
    let result = result(actionItems: [
      action(
        "Send it",
        due: WireDue(
          state: .explicitRelativeResolved, date: "2026-09-21",
          original: "tomorrow",
          source: .segment(UUID())))
    ])
    let (validated, _) = try AnalysisValidator.validate(
      result: result, against: dueEvidence(), policy: policy)
    let due = try XCTUnwrap(validated.actionItems.first).due
    XCTAssertEqual(due.state, .unresolved)
    XCTAssertNil(due.date)
    XCTAssertEqual(due.original, "tomorrow")
  }

  /// A `date` attached to `unresolved` or `absent` is cleared.
  func testDateOnUnresolvedOrAbsentIsCleared() throws {
    let result = result(actionItems: [
      action(
        "One",
        due: WireDue(
          state: .unresolved, date: "2026-09-25", original: "later",
          source: .segment(segB))),
      action(
        "Two",
        due: WireDue(
          state: .absent, date: "2026-09-25", original: nil, source: nil)),
    ])
    let (validated, _) = try AnalysisValidator.validate(
      result: result, against: dueEvidence(), policy: policy)
    XCTAssertEqual(validated.actionItems[0].due.state, .unresolved)
    XCTAssertNil(validated.actionItems[0].due.date)
    XCTAssertEqual(validated.actionItems[1].due.state, .absent)
    XCTAssertNil(validated.actionItems[1].due.date)
  }

  /// A server date that disagrees with the client-side resolution of a known
  /// phrase drops to `unresolved`; the original phrase stays.
  func testMismatchedServerDateBecomesUnresolved() throws {
    let result = result(actionItems: [
      action(
        "Send it",
        due: WireDue(
          state: .explicitRelativeResolved, date: "2026-09-24",
          original: "tomorrow", source: .segment(segB)))
    ])
    let (validated, _) = try AnalysisValidator.validate(
      result: result, against: dueEvidence(), policy: policy)
    let due = try XCTUnwrap(validated.actionItems.first).due
    XCTAssertEqual(due.state, .unresolved)
    XCTAssertNil(due.date)
    XCTAssertEqual(due.original, "tomorrow")
  }

  /// A matching client resolution keeps the server's resolved value.
  func testMatchingResolutionKeepsServerValue() throws {
    let result = result(actionItems: [
      action(
        "Send it",
        due: WireDue(
          state: .explicitRelativeResolved, date: "2026-09-21",
          original: "tomorrow", source: .segment(segB)))
    ])
    let (validated, _) = try AnalysisValidator.validate(
      result: result, against: dueEvidence(), policy: policy)
    let due = try XCTUnwrap(validated.actionItems.first).due
    XCTAssertEqual(due.state, .explicitRelativeResolved)
    XCTAssertEqual(due.date, "2026-09-21")
    XCTAssertEqual(due.original, "tomorrow")
    XCTAssertEqual(due.source, .segment(segB))
  }

  /// A vague term with a server date still resolves to `unresolved` — the
  /// server cannot pin down "soon".
  func testVagueTermWithServerDateBecomesUnresolved() throws {
    let result = result(actionItems: [
      action(
        "Send it",
        due: WireDue(
          state: .explicitRelativeResolved, date: "2026-09-25",
          original: "soon", source: .segment(segB)))
    ])
    let (validated, _) = try AnalysisValidator.validate(
      result: result, against: dueEvidence(), policy: policy)
    let due = try XCTUnwrap(validated.actionItems.first).due
    XCTAssertEqual(due.state, .unresolved)
    XCTAssertNil(due.date)
    XCTAssertEqual(due.original, "soon")
  }

  /// A phrase outside the known table leaves the server's consistent value.
  func testUnknownPhraseKeepsConsistentServerValue() throws {
    let result = result(actionItems: [
      action(
        "Send it",
        due: WireDue(
          state: .explicitAbsolute, date: "2026-10-01",
          original: "by the next board review", source: .segment(segB)))
    ])
    let (validated, _) = try AnalysisValidator.validate(
      result: result, against: dueEvidence(), policy: policy)
    let due = try XCTUnwrap(validated.actionItems.first).due
    XCTAssertEqual(due.state, .explicitAbsolute)
    XCTAssertEqual(due.date, "2026-10-01")
  }

  /// Due conservatism is item-level: a bad due on one item neither fails the
  /// run nor touches a good item's due.
  func testDueConservatismStaysItemLevel() throws {
    let result = result(
      actionItems: [
        action(
          "Send the report",
          due: WireDue(
            state: .explicitRelativeResolved, date: "2026-09-21",
            original: "tomorrow", source: .segment(segB))),
        action(
          "Notify the customer",
          due: WireDue(
            state: .explicitRelativeResolved, date: "bogus",
            original: "tomorrow", source: .segment(segB))),
      ],
      decisions: [
        wireItem("Deploy on Monday", sources: [.segment(segA)])
      ])
    let (validated, _) = try AnalysisValidator.validate(
      result: result, against: dueEvidence(), policy: policy)
    XCTAssertEqual(validated.actionItems.count, 2)
    XCTAssertEqual(validated.actionItems[0].due.state, .explicitRelativeResolved)
    XCTAssertEqual(validated.actionItems[0].due.date, "2026-09-21")
    XCTAssertEqual(validated.actionItems[1].due.state, .unresolved)
    XCTAssertEqual(validated.decisions.count, 1)
  }

  // MARK: Protected literals and support (T064)

  private func literalEvidence() -> AnalysisEvidence {
    var evidence = evidence()
    let vocabulary = evidence.segmentText[segB] ?? ""
    evidence.segmentText = [
      segA:
        "The new server is at 172.19.223.30 and the license costs $1,200 per year. "
        + vocabulary,
      segB: vocabulary,
    ]
    return evidence
  }

  /// An item whose literal is absent from its referenced sources is dropped
  /// and counted `dropped_literal`; it is absent from `ValidatedAnalysis`.
  func testMutatedLiteralDropsItemCounted() throws {
    let result = result(
      actionItems: [
        action(
          "Check the server at 172.19.223.20",
          due: WireDue(state: .absent), sources: [.segment(segA)]),
        action(
          "Send the report",
          due: WireDue(state: .absent), sources: [.segment(segB)]),
      ],
      decisions: [wireItem("Deploy on Monday", sources: [.segment(segB)])])
    let (validated, counts) = try AnalysisValidator.validate(
      result: result, against: literalEvidence(), policy: policy)
    XCTAssertEqual(counts.droppedLiteralCount, 1)
    XCTAssertEqual(validated.actionItems.map(\.text), ["Send the report"])
    XCTAssertEqual(validated.decisions.count, 1)
  }

  /// A topic with a mutated literal is dropped and counted the same way.
  func testMutatedLiteralDropsTopic() throws {
    var res = result(
      decisions: [
        wireItem("Deploy on Monday", sources: [.segment(segB)]),
        wireItem("Ship the release", sources: [.segment(segB)]),
        wireItem("Call the vendor", sources: [.segment(segB)]),
      ])
    res.topics = [
      WireTopic(
        title: "Server", summary: "It lives at 172.19.223.20", bullets: [],
        sources: [.segment(segA)])
    ]
    let (validated, counts) = try AnalysisValidator.validate(
      result: res, against: literalEvidence(), policy: policy)
    XCTAssertTrue(validated.topics.isEmpty)
    XCTAssertEqual(counts.droppedLiteralCount, 1)
  }

  /// Title, summary and bullets are checked apart — the first word of each
  /// is not a mid-sentence proper noun — and against all evidence, since a
  /// topic's literals may come from segments it does not cite (R5).
  func testTopicPartsCheckedApartAgainstAllEvidence() throws {
    var res = result()
    res.topics = [
      WireTopic(
        title: "Server move", summary: "Discussion of the new host",
        bullets: ["Located at 172.19.223.30"], sources: [.segment(segB)])
    ]
    let (validated, counts) = try AnalysisValidator.validate(
      result: res, against: literalEvidence(), policy: policy)
    XCTAssertEqual(validated.topics.count, 1)
    XCTAssertEqual(counts.droppedLiteralCount, 0)
  }

  /// A dropped topic counts on both sides of the share: one of four
  /// returned entries is under a third, so the run survives.
  func testDroppedTopicCountsAgainstTopicsToo() throws {
    var res = result(decisions: [wireItem("Deploy on Monday", sources: [.segment(segB)])])
    res.topics = [
      WireTopic(
        title: "Server", summary: "It lives at 172.19.223.20", bullets: [],
        sources: [.segment(segA)]),
      WireTopic(title: "Release", summary: "", bullets: [], sources: []),
      WireTopic(title: "Budget", summary: "", bullets: [], sources: []),
    ]
    let (validated, counts) = try AnalysisValidator.validate(
      result: res, against: literalEvidence(), policy: policy)
    XCTAssertEqual(validated.topics.map(\.title), ["Release", "Budget"])
    XCTAssertEqual(counts.droppedLiteralCount, 1)
  }

  /// A summary sentence with a mutated literal is removed; the rest stays.
  func testMutatedSummarySentenceIsRemoved() throws {
    var res = result()
    res.summary = WireSummary(
      text: "The team met. They checked the server at 172.19.223.99. "
        + "The server is at 172.19.223.30.",
      sources: [], wholeMeeting: true)
    let (validated, _) = try AnalysisValidator.validate(
      result: res, against: literalEvidence(), policy: policy)
    XCTAssertEqual(validated.summary.text, "The team met. The server is at 172.19.223.30.")
  }

  /// A summary left with no clean sentence fails the run.
  func testMutatedSummaryLiteralFailsRun() throws {
    var res = result()
    res.summary = WireSummary(
      text: "The team checked the server at 172.19.223.99.",
      sources: [], wholeMeeting: true)
    XCTAssertThrowsError(
      try AnalysisValidator.validate(
        result: res, against: literalEvidence(), policy: policy)
    ) { error in
      XCTAssertEqual((error as? AnalysisFailure)?.category, .protectedLiteral)
    }
  }

  /// An item none of whose content tokens occur in its referenced sources is
  /// dropped and counted `dropped_unsupported`.
  func testUnrelatedSourcesDropItemCounted() throws {
    let result = result(
      actionItems: [
        action(
          "Renew the office lease",
          due: WireDue(state: .absent), sources: [.segment(segB)]),
        action(
          "Send the report",
          due: WireDue(state: .absent), sources: [.segment(segB)]),
      ],
      decisions: [
        wireItem("Deploy on Monday", sources: [.segment(segB)]),
        wireItem("Ship the release", sources: [.segment(segB)]),
      ])
    let (validated, counts) = try AnalysisValidator.validate(
      result: result, against: literalEvidence(), policy: policy)
    XCTAssertEqual(counts.droppedUnsupportedCount, 1)
    XCTAssertEqual(validated.actionItems.map(\.text), ["Send the report"])
    XCTAssertEqual(validated.decisions.count, 2)
  }

  /// Dropping most items never fails the run: the survivors are adopted and
  /// the drops are counted (a small model's paraphrases must not discard a
  /// whole summary).
  func testHighDroppedShareKeepsSurvivors() throws {
    let result = result(
      actionItems: [
        action(
          "Renew the office lease",
          due: WireDue(state: .absent), sources: [.segment(segB)]),
        action(
          "Check the server at 172.19.223.20",
          due: WireDue(state: .absent), sources: [.segment(segA)]),
        action(
          "Send the report",
          due: WireDue(state: .absent), sources: [.segment(segB)]),
      ])
    // 2 of 3 returned items drop (one literal, one unsupported).
    let (validated, counts) = try AnalysisValidator.validate(
      result: result, against: literalEvidence(), policy: policy)
    XCTAssertEqual(counts.droppedLiteralCount + counts.droppedUnsupportedCount, 2)
    XCTAssertEqual(validated.actionItems.map(\.text), ["Send the report"])
  }
}
