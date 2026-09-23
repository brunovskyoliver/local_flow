import XCTest

@testable import LocalFlow

/// T034 — the Summary tab's read-model and header cases (`contracts/ui.md`).
@MainActor
final class SummaryModelTests: XCTestCase {

  /// Speaker names in the summary are found by full name, then first name with a
  /// short case ending; "You" never matches and a full name is not split.
  func testSpeakerMentions() {
    let text = "Lucia Majerovska ukázala Olivera. Lucia a Oliver. You too. Olivia."
    let mentions = SummaryModel.speakerMentions(
      in: text, speakers: [("Lucia Majerovska", 1), ("Oliver Brunovský (You)", 3), ("You", 0)])
    let found = mentions.sorted { $0.range.lowerBound < $1.range.lowerBound }
      .map { (String(text[$0.range]), $0.colorIndex) }
    XCTAssertEqual(found.map(\.0), ["Lucia Majerovska", "Olivera", "Lucia", "Oliver"])
    XCTAssertEqual(found.map(\.1), [1, 3, 1, 3])
  }

  // MARK: Deployment read model

  /// The stored deployment analysis renders summary, one decision and three
  /// action items; participant owners resolve from the speaker record — name
  /// and color index — never from anything the run stored.
  func testDeploymentAnalysisLoadsIntoReadModel() async throws {
    let fixture = try IntelligenceFixtures.meeting("deployment")
    let (model, _, _, speakers) = try await makeModel(fixture: fixture)
    let martin = UUID(uuidString: "aaaa0002-0000-4000-8000-000000000002")!
    let peter = UUID(uuidString: "aaaa0003-0000-4000-8000-000000000003")!
    let oliver = UUID(uuidString: "aaaa0001-0000-4000-8000-000000000001")!
    // The speaker record carries different names than the evidence fixture —
    // the read model must show these, not the request-time names.
    await speakers.setSummaries([
      SpeakerSummary(
        id: martin, source: .remote, labelOrdinal: 2, colorIndex: 5,
        displayName: "Martin K.", inRoom: false, speechMs: 1_000),
      SpeakerSummary(
        id: peter, source: .remote, labelOrdinal: 3, colorIndex: 1,
        displayName: "Peter S.", inRoom: false, speechMs: 1_000),
      SpeakerSummary(
        id: oliver, source: .remote, labelOrdinal: 1, colorIndex: 3,
        displayName: nil, inRoom: false, speechMs: 1_000,
        identity: SpeakerIdentity(
          state: .confirmed, origin: .userConfirmation,
          knownSpeakerID: UUID(), knownSpeakerName: "Oliver B.")),
    ])

    await model.refresh()
    let read = try XCTUnwrap(model.readModel)
    XCTAssertEqual(model.header, .succeeded)
    XCTAssertEqual(
      read.summary.text,
      "The team settled the Monday deployment and split the preparation work.")
    XCTAssertEqual(read.decisions.map(\.text), ["Deployment moves to Monday"])
    XCTAssertEqual(read.topics.map(\.title), ["Deployment"])
    XCTAssertEqual(read.actionItems.count, 3)
    XCTAssertEqual(read.nextSteps.count, 1)
    // Sections without content stay absent.
    XCTAssertTrue(read.openQuestions.isEmpty)
    XCTAssertTrue(read.risks.isEmpty)

    let owners = read.actionItems.map { item -> (String, Int) in
      guard case .participant(let name, let colorIndex, _) = item.owner else {
        XCTFail("expected a participant owner, got \(item.owner)")
        return ("", -1)
      }
      return (name, colorIndex)
    }
    XCTAssertEqual(
      owners.map(\.0), ["Martin K.", "Peter S.", "Oliver B."],
      "owner names come from the speaker record, not the stored analysis")
    XCTAssertEqual(owners.map(\.1), [5, 1, 3])
    // The fixture's request-time names never reach the read model.
    XCTAssertFalse(owners.map(\.0).contains("Martin"))
    XCTAssertFalse(owners.map(\.0).contains("Peter"))
  }

  // MARK: Header states

  func testEligibleHeaderAndNoAnalysis() async throws {
    let fixture = try IntelligenceFixtures.meeting("english")
    let (model, _, _, _) = try await makeModel(fixture: fixture, run: false)
    await model.refresh()
    XCTAssertEqual(model.header, .eligible)
    XCTAssertNil(model.readModel)
  }

  func testNotEligibleReasons() async throws {
    let fixture = try IntelligenceFixtures.meeting("english")
    let (model, _, reader, _) = try await makeModel(fixture: fixture, run: false)

    // Transcription never asked for.
    reader.transcription = nil
    await model.refresh()
    XCTAssertEqual(
      model.header, .notEligible(reason: SummaryModel.transcriptionOffReason))

    // A pass is on its way but not final.
    reader.transcription = MeetingTranscription(
      meetingID: fixture.id, state: .pending, liveRequested: true, updatedAt: 0)
    await model.refresh()
    XCTAssertEqual(
      model.header, .notEligible(reason: SummaryModel.notFinishedReason))
  }

  /// The AI-generated tag is part of the header state, not decoration.
  func testSucceededHeaderCarriesAIGeneratedLabel() async throws {
    let fixture = try IntelligenceFixtures.meeting("deployment")
    let (model, _, _, _) = try await makeModel(fixture: fixture)
    await model.refresh()
    XCTAssertEqual(model.header, .succeeded)
    let line = try XCTUnwrap(model.generatedLine)
    XCTAssertTrue(line.hasPrefix("Generated "), line)
    XCTAssertTrue(line.hasSuffix("· AI-generated"), line)
  }

  // MARK: T047 — View source

  /// A segment reference requests the Transcript tab's segment — the first
  /// segment wins over any note references on the same item — and the item's
  /// attribution names the segment's speaker.
  func testOpenSourceOnSegmentReferenceRequestsTranscriptTab() async throws {
    let fixture = try IntelligenceFixtures.meeting("deployment")
    let (model, _, _, speakers) = try await makeModel(fixture: fixture)
    let martin = UUID(uuidString: "aaaa0002-0000-4000-8000-000000000002")!
    let oliver = UUID(uuidString: "aaaa0001-0000-4000-8000-000000000001")!
    await speakers.setSummaries([
      SpeakerSummary(
        id: martin, source: .remote, labelOrdinal: 2, colorIndex: 5,
        displayName: "Martin K.", inRoom: false, speechMs: 1_000),
      SpeakerSummary(
        id: oliver, source: .remote, labelOrdinal: 1, colorIndex: 3,
        displayName: nil, inRoom: false, speechMs: 1_000,
        identity: SpeakerIdentity(
          state: .confirmed, origin: .userConfirmation,
          knownSpeakerID: UUID(), knownSpeakerName: "Oliver B.")),
    ])
    var requests: [SummaryModel.SourceRequest] = []
    model.onOpenSource = { requests.append($0) }
    await model.refresh()
    let read = try XCTUnwrap(model.readModel)

    // The decision's sources are [segment aaaa…001, note:1]; the segment wins.
    let decision = try XCTUnwrap(read.decisions.first)
    model.openSource(for: decision)
    XCTAssertEqual(requests, [.segment(oliver)])
    XCTAssertEqual(decision.speakerAttribution, "Oliver B.")

    // Action item 1's only source is segment aaaa…002.
    let first = try XCTUnwrap(read.actionItems.first)
    model.openSource(for: first)
    XCTAssertEqual(requests.last, .segment(martin))
    XCTAssertEqual(first.speakerAttribution, "Martin K.")
  }

  /// A note-only item requests My thoughts with the paragraph ordinal and
  /// hash, and carries no speaker attribution (FR-025).
  func testOpenSourceOnNoteReferenceRequestsThoughtsTab() async throws {
    let fixture = try IntelligenceFixtures.meeting("deployment")
    let (model, store, _, _) = try await makeModel(fixture: fixture)
    let note = try XCTUnwrap(fixture.notes.first)
    let noteOnly = ValidatedAnalysis(
      language: .en,
      summary: ValidatedSummary(
        text: "Notes only.", sources: [], wholeMeeting: true),
      topics: [],
      decisions: [
        ValidatedItem(
          kind: .decision, text: "Customer asked for Monday",
          sources: [.note(ordinal: note.ordinal, hash: note.hash)])
      ],
      actionItems: [], nextSteps: [], openQuestions: [], risks: [])
    let run = try await store.admit(
      meetingID: fixture.id, trigger: .manual,
      evidence: EvidenceVersion(hex: String(repeating: "b", count: 64)),
      passID: UUID(), policy: AnalysisPolicy(), now: 2)
    _ = try await store.start(runID: run.id, now: 3)
    _ = try await store.adopt(
      runID: run.id, result: noteOnly, counts: ValidationCounts(),
      identity: RunIdentity(
        serverVersion: "0.3.0", backendKind: "k", backendModel: "m",
        promptVersions: "full=1", pipelineVersion: "analysis_v1"),
      now: 4)

    var requests: [SummaryModel.SourceRequest] = []
    model.onOpenSource = { requests.append($0) }
    await model.refresh()
    let item = try XCTUnwrap(model.readModel?.decisions.first)
    model.openSource(for: item)
    XCTAssertEqual(requests, [.note(ordinal: note.ordinal, hash: note.hash)])
    XCTAssertNil(
      item.speakerAttribution, "note content is never attributed to a speaker")
  }

  // MARK: T054 — owner chips, suggestions, accept

  /// Every owner-certainty row renders its contract `accessibilityValue`, and
  /// an uncertain participant never shows a name (ui.md "Owner chip").
  func testOwnerAccessibilityValues() async throws {
    let fixture = try IntelligenceFixtures.meeting("english")
    let (model, store, _, speakers) = try await makeModel(fixture: fixture, run: false)
    let confirmed = UUID()
    let recognized = UUID()
    let local = UUID()
    let user = UUID()
    let possible = UUID()
    await speakers.setSummaries([
      SpeakerSummary(
        id: confirmed, source: .remote, labelOrdinal: 1, colorIndex: 0,
        displayName: nil, inRoom: false, speechMs: 100,
        identity: SpeakerIdentity(
          state: .confirmed, origin: .userConfirmation,
          knownSpeakerID: UUID(), knownSpeakerName: "Oliver B.")),
      SpeakerSummary(
        id: recognized, source: .remote, labelOrdinal: 2, colorIndex: 1,
        displayName: nil, inRoom: false, speechMs: 100,
        identity: SpeakerIdentity(
          state: .recognized, origin: .automaticMatch,
          knownSpeakerID: UUID(), knownSpeakerName: "Martin K.")),
      SpeakerSummary(
        id: local, source: .remote, labelOrdinal: 3, colorIndex: 2,
        displayName: "Stretko", inRoom: false, speechMs: 100),
      SpeakerSummary(
        id: user, source: .local, labelOrdinal: 0, colorIndex: 3,
        displayName: nil, inRoom: true, speechMs: 100,
        identity: SpeakerIdentity(
          state: .confirmed, origin: .newProfileCreated,
          knownSpeakerID: UUID(), knownSpeakerName: "Oliver")),
      SpeakerSummary(
        id: possible, source: .remote, labelOrdinal: 4, colorIndex: 4,
        displayName: nil, inRoom: false, speechMs: 100,
        identity: SpeakerIdentity(
          state: .possible, origin: .automaticMatch,
          knownSpeakerID: UUID(), knownSpeakerName: "Tomáš Juríček")),
    ])
    let items = [
      (
        ValidatedOwner.participant(
          speakerID: confirmed, knownSpeakerID: nil, certainty: .confirmed), "confirmed participant"
      ),
      (
        .participant(speakerID: recognized, knownSpeakerID: nil, certainty: .recognized),
        "recognized participant"
      ),
      (
        .participant(speakerID: local, knownSpeakerID: nil, certainty: .localName),
        "meeting participant"
      ),
      (.participant(speakerID: user, knownSpeakerID: nil, certainty: .localUser), "you"),
      (
        .participant(speakerID: possible, knownSpeakerID: nil, certainty: .possible),
        "owner unresolved"
      ),
      (.mentioned(name: "Nobody"), "mentioned name"),
      (.none, "owner unresolved"),
    ]
    _ = try await adopt(
      store, meetingID: fixture.id,
      actionItems: items.enumerated().map { index, pair in
        ValidatedActionItem(
          text: "Task \(index)", owner: pair.0, ownershipState: .supported,
          due: ValidatedDue(state: .absent), sources: [])
      })

    await model.refresh()
    let read = try XCTUnwrap(model.readModel)
    XCTAssertEqual(read.actionItems.count, items.count)
    for (item, expected) in zip(read.actionItems, items) {
      XCTAssertEqual(
        SummaryTabView.OwnerChip.accessibilityValue(item.owner), expected.1,
        "item \(item.ordinal)")
    }
    // The possible root renders its anonymous label, never the candidate name.
    let possibleItem = read.actionItems[4]
    guard case .unresolved(let label) = possibleItem.owner else {
      return XCTFail("expected unresolved, got \(possibleItem.owner)")
    }
    XCTAssertEqual(label, "Speaker 4")
    XCTAssertFalse(label.contains("Tomáš"))
    // The local user renders "You".
    guard case .participant(let name, _, let certainty) = read.actionItems[3].owner
    else { return XCTFail("expected a participant owner") }
    XCTAssertEqual(certainty, .localUser)
  }

  /// A mentioned name matching a known speaker's display name — case- and
  /// diacritic-insensitive — gets a local suggestion; a non-match gets none.
  func testMentionedSuggestionIsLocalAndDiacriticInsensitive() async throws {
    let fixture = try IntelligenceFixtures.meeting("english")
    let identities = FakeIdentityStore()
    let tomasID = UUID()
    await identities.setKnown([
      KnownSpeakerRow(
        id: tomasID, name: "Tomáš Juríček", activeSampleCount: 3,
        recognitionEnabled: true, state: .active, isLocalUser: false,
        revision: 0, createdAt: 1)
    ])
    let (model, store, _, _) = try await makeModel(
      fixture: fixture, run: false, identities: identities)
    _ = try await adopt(
      store, meetingID: fixture.id,
      actionItems: [
        ValidatedActionItem(
          text: "Send it", owner: .mentioned(name: "tomas juricek"),
          ownershipState: .supported, due: ValidatedDue(state: .absent),
          sources: []),
        ValidatedActionItem(
          text: "Call her", owner: .mentioned(name: "Ingrid"),
          ownershipState: .supported, due: ValidatedDue(state: .absent),
          sources: []),
      ])

    await model.refresh()
    let read = try XCTUnwrap(model.readModel)
    guard case .mentioned(_, let suggestion) = read.actionItems[0].owner
    else { return XCTFail("expected a mentioned owner") }
    XCTAssertEqual(suggestion, KnownSpeakerRef(id: tomasID, name: "Tomáš Juríček"))
    guard case .mentioned(_, let none) = read.actionItems[1].owner
    else { return XCTFail("expected a mentioned owner") }
    XCTAssertNil(none)
  }

  /// Accepting the suggestion writes one owner overlay —
  /// `{"kind":"participant","speaker_id":…}` pointing at the profile-linked
  /// meeting speaker — and touches no spec 010 row (FR-035).
  func testAcceptSuggestionWritesParticipantOverlayOnly() async throws {
    let fixture = try IntelligenceFixtures.meeting("english")
    let identities = FakeIdentityStore()
    let tomasID = UUID()
    let root = UUID()
    await identities.setKnown([
      KnownSpeakerRow(
        id: tomasID, name: "Tomáš Juríček", activeSampleCount: 3,
        recognitionEnabled: true, state: .active, isLocalUser: false,
        revision: 0, createdAt: 1)
    ])
    await identities.setIdentities(
      [
        root: SpeakerIdentity(
          state: .recognized, origin: .automaticMatch,
          knownSpeakerID: tomasID, knownSpeakerName: "Tomáš Juríček")
      ],
      for: fixture.id)
    let (model, store, _, speakers) = try await makeModel(
      fixture: fixture, run: false, identities: identities)
    await speakers.setSummaries([
      SpeakerSummary(
        id: root, source: .remote, labelOrdinal: 1, colorIndex: 0,
        displayName: nil, inRoom: false, speechMs: 100,
        identity: SpeakerIdentity(
          state: .recognized, origin: .automaticMatch,
          knownSpeakerID: tomasID, knownSpeakerName: "Tomáš Juríček"))
    ])
    _ = try await adopt(
      store, meetingID: fixture.id,
      actionItems: [
        ValidatedActionItem(
          text: "Send it", owner: .mentioned(name: "Tomáš Juríček"),
          ownershipState: .supported, due: ValidatedDue(state: .absent),
          sources: [])
      ])
    await model.refresh()
    let item = try XCTUnwrap(model.readModel?.actionItems.first)

    let knownBefore = await identities.known
    await model.acceptSuggestion(item: item)

    let overlays = try await store.overlays(meetingID: fixture.id)
    XCTAssertEqual(overlays.count, 1)
    let overlay = try XCTUnwrap(overlays.first)
    XCTAssertEqual(overlay.field, .owner)
    XCTAssertEqual(overlay.targetKind, .item(item.id))
    // user_value's contract shape: {"kind":"participant","speaker_id":…}
    XCTAssertEqual(overlay.value, .owner(.participant(root)))
    XCTAssertEqual(
      try AnalysisStore.encodeOverlayValue(overlay.value, field: .owner),
      "{\"kind\":\"participant\",\"speaker_id\":\"\(root.uuidString)\"}")

    // The chip is now the profile-linked participant.
    let updated = try XCTUnwrap(model.readModel?.actionItems.first)
    guard case .participant(let name, _, let certainty) = updated.owner
    else { return XCTFail("expected a participant owner") }
    XCTAssertEqual(name, "Tomáš Juríček")
    XCTAssertEqual(certainty, .recognized)

    // FR-035: nothing in spec 010 tables changed — the fake records every
    // write it was asked to make.
    let knownAfter = await identities.known
    XCTAssertEqual(knownAfter, knownBefore)
    let identityRows = await identities.identityRows
    XCTAssertEqual(identityRows[fixture.id]?.count, 1)
    let added = await identities.addedSamples
    XCTAssertTrue(added.isEmpty)
    let calls = await identities.calls
    XCTAssertTrue(
      calls.allSatisfy { ["knownSpeakers"].contains($0.name) },
      "only reads reached the identity store: \(calls)")
  }

  // MARK: T059 — due-date rendering

  /// The due-dates fixture renders: `tomorrow` resolved against the meeting's
  /// date in its zone, `soon` unresolved with the phrase kept, `Send the
  /// report` with no due — and the one settled decision (spec US4).
  func testDueDatesFixtureRendersResolvedAndUnresolvedDues() async throws {
    let fixture = try IntelligenceFixtures.meeting("due-dates")
    let (model, _, _, _) = try await makeModel(
      fixture: fixture, response: "due-dates-valid")
    await model.refresh()
    let read = try XCTUnwrap(model.readModel)

    XCTAssertEqual(read.decisions.map(\.text), ["We will deploy on Monday"])
    XCTAssertEqual(read.actionItems.count, 3)

    let resolved = read.actionItems[0]
    XCTAssertEqual(resolved.dueState, .explicitRelativeResolved)
    XCTAssertEqual(resolved.dueDate, "2026-09-21")
    XCTAssertEqual(resolved.dueOriginal, "tomorrow")
    XCTAssertEqual(SummaryModel.dueText(resolved.dueDate!), "21 Sep")

    let vague = read.actionItems[1]
    XCTAssertEqual(vague.dueState, .unresolved)
    XCTAssertNil(vague.dueDate)
    XCTAssertEqual(vague.dueOriginal, "soon")

    let report = try XCTUnwrap(read.actionItems.first { $0.text == "Send the report" })
    XCTAssertEqual(report.dueState, .absent)
    XCTAssertNil(report.dueDate)
  }

  /// An analysis without decisions leaves the read model's decisions empty —
  /// the view renders no Decisions section for it.
  func testNoDecisionsLeavesSectionEmpty() async throws {
    let fixture = try IntelligenceFixtures.meeting("english")
    let (model, store, _, _) = try await makeModel(fixture: fixture, run: false)
    _ = try await adopt(
      store, meetingID: fixture.id,
      actionItems: [
        ValidatedActionItem(
          text: "Send it", owner: .none, ownershipState: .unresolved,
          due: ValidatedDue(state: .absent), sources: [])
      ])
    await model.refresh()
    let read = try XCTUnwrap(model.readModel)
    XCTAssertTrue(read.decisions.isEmpty)
    XCTAssertEqual(read.actionItems.count, 1)
  }

  // MARK: T077 — rename relabel and stale banner

  /// Renaming a speaker relabels the owner chip at the next load: the stored
  /// item text is untouched, no stale flag rises and the evidence version is
  /// unchanged because names are hashed out of it.
  func testRenameRelabelsOwnerWithoutStaleOrProseChange() async throws {
    let fixture = try IntelligenceFixtures.meeting("deployment")
    let (model, _, _, speakers) = try await makeModel(fixture: fixture)
    let martin = UUID(uuidString: "aaaa0002-0000-4000-8000-000000000002")!
    let peter = UUID(uuidString: "aaaa0003-0000-4000-8000-000000000003")!
    let oliver = UUID(uuidString: "aaaa0001-0000-4000-8000-000000000001")!
    await speakers.setSummaries([
      SpeakerSummary(
        id: martin, source: .remote, labelOrdinal: 2, colorIndex: 5,
        displayName: "Speaker 2", inRoom: false, speechMs: 1_000),
      SpeakerSummary(
        id: peter, source: .remote, labelOrdinal: 3, colorIndex: 1,
        displayName: "Peter S.", inRoom: false, speechMs: 1_000),
      SpeakerSummary(
        id: oliver, source: .remote, labelOrdinal: 1, colorIndex: 3,
        displayName: nil, inRoom: false, speechMs: 1_000,
        identity: SpeakerIdentity(
          state: .confirmed, origin: .userConfirmation,
          knownSpeakerID: UUID(), knownSpeakerName: "Oliver B.")),
    ])
    await model.refresh()
    let before = try XCTUnwrap(model.readModel)
    let itemText = before.actionItems.first?.text

    // Speaker 2 is renamed to "Martin".
    try await speakers.saveNames(meetingID: fixture.id, names: [martin: "Martin"], now: 1)
    await model.refresh()

    let read = try XCTUnwrap(model.readModel)
    XCTAssertFalse(read.stale, "a rename is not an evidence change")
    XCTAssertEqual(read.actionItems.first?.text, itemText, "item prose is not rewritten")
    guard case .participant(let name, _, _) = read.actionItems.first?.owner else {
      XCTFail("expected a participant owner")
      return
    }
    XCTAssertEqual(name, "Martin")
  }

  /// A stale analysis stays readable behind the amber banner with Regenerate
  /// offered; the flag comes from the evidence-version comparison.
  func testStaleAnalysisStaysReadableWithBanner() async throws {
    let fixture = try IntelligenceFixtures.meeting("deployment")
    let (model, _, reader, speakers) = try await makeModel(fixture: fixture)
    await speakers.setSummaries([])
    await model.refresh()
    XCTAssertEqual(model.header, .succeeded)

    // A notes write after acceptance marks the analysis stale.
    reader.noteRows.append(
      NoteParagraph(ordinal: 99, text: "Added later.", hash: String(repeating: "b", count: 64)))
    await model.refresh()

    let read = try XCTUnwrap(model.readModel)
    XCTAssertTrue(read.stale)
    XCTAssertEqual(
      SummaryTabView.staleBannerText,
      "The transcript, speakers or notes changed after this summary.")
    XCTAssertFalse(read.summary.text.isEmpty, "the old analysis stays readable")
  }

  // MARK: Helpers

  /// Admits + adopts `actionItems` into `store` as the accepted analysis.
  private func adopt(
    _ store: FakeAnalysisStore, meetingID: UUID,
    actionItems: [ValidatedActionItem],
    decisions: [ValidatedItem] = []
  ) async throws -> AnalysisRun {
    let analysis = ValidatedAnalysis(
      language: .en,
      summary: ValidatedSummary(text: "A meeting.", sources: [], wholeMeeting: true),
      topics: [], decisions: decisions, actionItems: actionItems, nextSteps: [],
      openQuestions: [], risks: [])
    let run = try await store.admit(
      meetingID: meetingID, trigger: .manual,
      evidence: EvidenceVersion(hex: String(repeating: "a", count: 64)),
      passID: UUID(), policy: AnalysisPolicy(), now: 2)
    _ = try await store.start(runID: run.id, now: 3)
    return try await store.adopt(
      runID: run.id, result: analysis, counts: ValidationCounts(),
      identity: RunIdentity(
        serverVersion: "0.3.0", backendKind: "k", backendModel: "m",
        promptVersions: "full=1", pipelineVersion: "analysis_v1"),
      now: 4)
  }

  // MARK: T084 — reading time, order, report

  /// FR-037: the deployment analysis reads as `1 MIN READ`, computed on the
  /// Mac; action items lead the four lists in contract order and the two
  /// empty lists stay absent.
  func testReadingMinutesOrderAndHiddenEmpties() async throws {
    let fixture = try IntelligenceFixtures.meeting("deployment")
    let (model, _, _, _) = try await makeModel(fixture: fixture)
    await model.refresh()
    let read = try XCTUnwrap(model.readModel)
    XCTAssertEqual(read.readingMinutes, 1)
    XCTAssertEqual(read.actionItems.count, 3)
    XCTAssertEqual(
      read.nextSteps.map(\.text), ["Reconfirm the deployment window on Monday morning"])
    XCTAssertEqual(read.decisions.map(\.text), ["Deployment moves to Monday"])
    XCTAssertTrue(read.openQuestions.isEmpty)
    XCTAssertTrue(read.risks.isEmpty)
  }

  /// `copyText()` is `AnalysisReport`: the fixture's title and date head the
  /// report, the trailing line closes it, and the dated action item carries
  /// `(due 25 Sep)`.
  func testCopyTextDelegatesToAnalysisReport() async throws {
    let fixture = try IntelligenceFixtures.meeting("deployment")
    let (model, _, _, _) = try await makeModel(fixture: fixture)
    await model.refresh()
    let read = try XCTUnwrap(model.readModel)
    let text = try XCTUnwrap(model.copyText())
    XCTAssertEqual(
      text,
      AnalysisReport.text(model: read, title: "Deployment sync", date: "20 Sep 2026"))
    XCTAssertTrue(text.hasPrefix("Deployment sync\n20 Sep 2026"))
    XCTAssertTrue(text.contains("(due 25 Sep)"))
    XCTAssertTrue(text.hasSuffix(AnalysisReport.trailingLine))
    XCTAssertFalse(text.contains("Open questions"), "an empty section is absent")
    XCTAssertFalse(text.contains("Risks / blockers"), "an empty section is absent")
  }

  /// Color is never the only cue: the participant chip pairs a name with its
  /// color index, the mentioned chip carries its caption and the unresolved
  /// chip keeps a text label — each maps to its contract accessibilityValue.
  func testOwnerChipStylesAreNeverColorAlone() {
    XCTAssertEqual(
      SummaryTabView.OwnerChip.accessibilityValue(
        .participant(name: "Martin K.", colorIndex: 5, certainty: .confirmed)),
      "confirmed participant")
    XCTAssertEqual(
      SummaryTabView.OwnerChip.accessibilityValue(
        .mentioned(name: "Jana", suggestion: nil)),
      "mentioned name")
    XCTAssertEqual(
      SummaryTabView.OwnerChip.accessibilityValue(.unresolved(label: "Speaker 3")),
      "owner unresolved")
  }

  // MARK: T096 — overlay edits (US11)

  /// Text, owner and due edits each write one overlay carrying
  /// `ai_value_snapshot`, `item_text_snapshot` and `source_key`; the read
  /// model reports the effective value, the `edits` set and the AI values
  /// "Show AI value" reveals.
  func testTextOwnerDueEditsWriteOneOverlayEach() async throws {
    let fixture = try IntelligenceFixtures.meeting("deployment")
    let (model, store, _, _) = try await makeModel(fixture: fixture)
    await model.refresh()
    let item = try XCTUnwrap(model.readModel?.actionItems.first)
    let aiText = item.text
    let aiOwner = item.owner
    let aiDue = item.dueDate

    await model.editText("Ship it Tuesday", item: item)
    await model.setOwner(.mentioned("Tomáš Juríček"), item: item)
    await model.setDue("2026-09-25", item: item)

    let overlays = try await store.overlays(meetingID: fixture.id)
    XCTAssertEqual(overlays.count, 3)
    for overlay in overlays {
      // A due overlay's aiValue may be nil — the fixture carries no AI due.
      if overlay.field != .dueDate {
        XCTAssertNotNil(overlay.snapshot.aiValue, "\(overlay.field)")
      }
      XCTAssertEqual(overlay.snapshot.itemText, aiText, "\(overlay.field)")
      XCTAssertEqual(
        overlay.snapshot.sourceKey, SummaryModel.sourceKey(item.sources),
        "\(overlay.field)")
      XCTAssertEqual(overlay.itemID, item.id, "\(overlay.field)")
    }
    let read = try XCTUnwrap(model.readModel)
    let edited = try XCTUnwrap(read.actionItems.first)
    XCTAssertEqual(edited.text, "Ship it Tuesday")
    XCTAssertEqual(edited.aiText, aiText)
    XCTAssertEqual(edited.owner, .mentioned(name: "Tomáš Juríček", suggestion: nil))
    XCTAssertEqual(edited.aiOwner, aiOwner)
    XCTAssertEqual(edited.dueDate, "2026-09-25")
    XCTAssertEqual(edited.aiDueDate, aiDue)
    XCTAssertEqual(edited.edits, [.taskText, .owner, .dueDate])
    XCTAssertEqual(edited.overlayIDs.count, 3)
    XCTAssertNil(model.editError)
  }

  /// The summary text takes one `summary_text` overlay on the summary
  /// target; "Show AI value" is `aiText`, "Remove edit" restores it.
  func testSummaryEditAndRemove() async throws {
    let fixture = try IntelligenceFixtures.meeting("deployment")
    let (model, store, _, _) = try await makeModel(fixture: fixture)
    await model.refresh()
    let aiText = try XCTUnwrap(model.readModel?.summary.aiText)

    await model.editSummaryText("A corrected summary.")
    var read = try XCTUnwrap(model.readModel)
    XCTAssertEqual(read.summary.text, "A corrected summary.")
    XCTAssertEqual(read.summary.aiText, aiText)
    XCTAssertTrue(read.summary.edited)

    let overlayID = try XCTUnwrap(read.summary.overlayID)
    await model.removeEdit(id: overlayID)
    read = try XCTUnwrap(model.readModel)
    XCTAssertEqual(read.summary.text, aiText)
    XCTAssertFalse(read.summary.edited)
    let remaining = try await store.overlays(meetingID: fixture.id)
    XCTAssertTrue(remaining.isEmpty)
  }

  /// Status cycles open → completed and the row menu dismisses/reopens; a
  /// completed item copies `[x]`, a dismissed item leaves the report.
  func testStatusOverlayCyclesAndShapesTheReport() async throws {
    let fixture = try IntelligenceFixtures.meeting("deployment")
    let (model, store, _, _) = try await makeModel(fixture: fixture)
    await model.refresh()
    let item = try XCTUnwrap(model.readModel?.actionItems.first)

    await model.setStatus(.completed, item: item)
    var read = try XCTUnwrap(model.readModel)
    XCTAssertEqual(read.actionItems[0].status, .completed)
    XCTAssertTrue(read.actionItems[0].edits.contains(.status))
    let completed = try XCTUnwrap(model.copyText())
    XCTAssertTrue(completed.contains("- [x] \(read.actionItems[0].text)"))

    await model.setStatus(.dismissed, item: read.actionItems[0])
    read = try XCTUnwrap(model.readModel)
    XCTAssertEqual(read.actionItems[0].status, .dismissed)
    let dismissed = try XCTUnwrap(model.copyText())
    XCTAssertFalse(dismissed.contains(read.actionItems[0].text))

    await model.setStatus(.open, item: read.actionItems[0])
    read = try XCTUnwrap(model.readModel)
    XCTAssertEqual(read.actionItems[0].status, .open)
    let overlays = try await store.overlays(meetingID: fixture.id)
    XCTAssertEqual(
      overlays.count, 1,
      "one overlay row carries every status change")
  }

  /// The owner menu lists every meeting speaker — Possible and Unknown under
  /// their "Speaker N" labels — then "Someone else…" and "No owner".
  func testOwnerChoicesListSpeakersAndMenuOptions() async throws {
    let fixture = try IntelligenceFixtures.meeting("deployment")
    let (model, _, _, speakers) = try await makeModel(fixture: fixture)
    let named = UUID()
    let unnamed = UUID()
    await speakers.setSummaries([
      SpeakerSummary(
        id: named, source: .remote, labelOrdinal: 1, colorIndex: 2,
        displayName: "Martin", inRoom: false, speechMs: 100,
        identity: SpeakerIdentity(
          state: .possible, origin: .automaticMatch,
          knownSpeakerID: nil, knownSpeakerName: nil)),
      SpeakerSummary(
        id: unnamed, source: .remote, labelOrdinal: 3, colorIndex: 5,
        displayName: nil, inRoom: false, speechMs: 100),
    ])
    await model.refresh()

    XCTAssertEqual(
      model.ownerChoices.map(\.label), ["Martin", "Speaker 3"],
      "a Possible match with a local name shows the name; an unnamed speaker "
        + "shows its label, never a candidate")
    XCTAssertEqual(model.ownerChoices.map(\.id), [named, unnamed])
  }

  /// A second adoption re-matches edits: the overlay whose item kept its
  /// sources follows the new row; the edit whose item vanished lands in
  /// `previousEdits` with its snapshots — never deleted.
  func testRegenerationCarriesMatchedEditsAndOrphansTheRest() async throws {
    let fixture = try IntelligenceFixtures.meeting("deployment")
    let (model, store, _, _) = try await makeModel(fixture: fixture, run: false)
    let segment = try XCTUnwrap(fixture.segments.first).id
    _ = try await adopt(
      store, meetingID: fixture.id,
      actionItems: [
        ValidatedActionItem(
          text: "Follow up with Tomáš", owner: .none,
          ownershipState: .unresolved, due: ValidatedDue(state: .absent),
          sources: [.segment(segment)])
      ],
      decisions: [
        ValidatedItem(
          kind: .decision, text: "Deploy Monday", sources: [.segment(segment)])
      ])
    await model.refresh()
    let item = try XCTUnwrap(model.readModel?.actionItems.first)
    let decision = try XCTUnwrap(model.readModel?.decisions.first)
    await model.editText("Ping Tomáš Juríček", item: item)
    await model.editText("Deploy Tuesday", item: decision)

    // The regeneration keeps the action item (same source) and drops the
    // decision entirely.
    _ = try await adopt(
      store, meetingID: fixture.id,
      actionItems: [
        ValidatedActionItem(
          text: "Follow up with Tomáš Juríček", owner: .none,
          ownershipState: .unresolved, due: ValidatedDue(state: .absent),
          sources: [.segment(segment)])
      ])
    await model.refresh()

    let read = try XCTUnwrap(model.readModel)
    let carried = try XCTUnwrap(read.actionItems.first)
    XCTAssertEqual(carried.text, "Ping Tomáš Juríček")
    XCTAssertTrue(carried.edits.contains(.taskText))
    let orphan = try XCTUnwrap(read.previousEdits.first)
    XCTAssertEqual(read.previousEdits.count, 1)
    XCTAssertEqual(orphan.itemTextSnapshot, "Deploy Monday")
    XCTAssertEqual(orphan.aiValue, "Deploy Monday")
    XCTAssertEqual(orphan.userValue, "Deploy Tuesday")
    XCTAssertEqual(orphan.field, .decisionText)
  }

  /// "Remove all edits" deletes every overlay for the meeting; edits never
  /// touch known_speakers, voice_samples or identity_assignments — the fakes
  /// record no writes.
  func testRemoveAllEditsAndNoSpec010Writes() async throws {
    let fixture = try IntelligenceFixtures.meeting("deployment")
    let identities = FakeIdentityStore()
    let (model, store, _, speakers) = try await makeModel(
      fixture: fixture, identities: identities)
    await model.refresh()
    let item = try XCTUnwrap(model.readModel?.actionItems.first)
    await model.editText("Edited", item: item)
    await model.setStatus(.completed, item: item)
    let written = try await store.overlays(meetingID: fixture.id)
    XCTAssertEqual(written.count, 2)

    await model.removeAllEdits()
    let cleared = try await store.overlays(meetingID: fixture.id)
    XCTAssertTrue(cleared.isEmpty)
    let read = try XCTUnwrap(model.readModel)
    XCTAssertFalse(read.actionItems[0].edits.contains(.status))
    XCTAssertEqual(read.actionItems[0].text, item.aiText)

    // FR-035: overlays are the only writes — the identity and speaker fakes
    // saw reads, never a mutation.
    let writes = await identities.calls.filter { $0.name != "knownSpeakers" }
    XCTAssertTrue(writes.isEmpty)
    let savedNames = await speakers.savedNames
    let corrections = await speakers.corrections
    XCTAssertTrue(savedNames.isEmpty)
    XCTAssertTrue(corrections.isEmpty)
  }

  /// A store refusal surfaces the persistence message on `editError` — a
  /// capacity error is never swallowed.
  func testOverlayCapacitySurfacesPersistenceMessage() async throws {
    let fixture = try IntelligenceFixtures.meeting("deployment")
    let (model, store, _, _) = try await makeModel(fixture: fixture)
    await model.refresh()
    let item = try XCTUnwrap(model.readModel?.actionItems.first)
    store.failures["setOverlay"] = AnalysisFailure(
      .persistenceCapacity, detail: "overlay_cap")
    await model.editText("Edited", item: item)
    XCTAssertEqual(
      model.editError,
      "The summary couldn't be saved. Meeting storage is full.")
  }

  /// Runs the analyzer on `fixture` (unless `run` is false) against the
  /// scripted `response` stream, then returns the model plus the fakes the
  /// test tunes.
  private func makeModel(
    fixture: IntelligenceFixture, run: Bool = true,
    response: String = "deployment-valid",
    identities: FakeIdentityStore = FakeIdentityStore()
  ) async throws -> (SummaryModel, FakeAnalysisStore, FakeEvidenceReader, FakeSpeakerStore) {
    let reader = FakeEvidenceReader(fixture: fixture)
    let store = FakeAnalysisStore()
    let transport = FakeAnalysisTransport()
    if run { try transport.script(response: response) }
    let clock = FakeMeetingClock()
    let analyzer = MeetingAnalyzer(
      evidence: reader, transport: transport, store: store, clock: clock,
      endpoint: {
        RewriteEndpoint(url: URL(string: "http://127.0.0.1:8765")!, origin: "test")
      },
      settings: { nil })
    let coordinator = MeetingIntelligenceCoordinator(
      analyzer: analyzer, store: store, automaticEnabled: { false }, clock: clock)
    let speakers = FakeSpeakerStore()
    let model = SummaryModel(
      meetingID: fixture.id, coordinator: coordinator, store: store,
      speakers: speakers, identities: identities, analyzer: analyzer,
      transcripts: reader)
    if run {
      _ = try await analyzer.run(meetingID: fixture.id, trigger: .manual)
    }
    return (model, store, reader, speakers)
  }
}
