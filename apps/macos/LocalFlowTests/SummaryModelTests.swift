import XCTest

@testable import LocalFlow

/// T034 — the Summary tab's read-model and header cases (`contracts/ui.md`).
@MainActor
final class SummaryModelTests: XCTestCase {

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

  // MARK: Helpers

  /// Admits + adopts `actionItems` into `store` as the accepted analysis.
  private func adopt(
    _ store: FakeAnalysisStore, meetingID: UUID,
    actionItems: [ValidatedActionItem]
  ) async throws -> AnalysisRun {
    let analysis = ValidatedAnalysis(
      language: .en,
      summary: ValidatedSummary(text: "A meeting.", sources: [], wholeMeeting: true),
      topics: [], decisions: [], actionItems: actionItems, nextSteps: [],
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

  /// Runs the analyzer on `fixture` (unless `run` is false) against the
  /// scripted `deployment-valid` response, then returns the model plus the
  /// fakes the test tunes.
  private func makeModel(
    fixture: IntelligenceFixture, run: Bool = true,
    identities: FakeIdentityStore = FakeIdentityStore()
  ) async throws -> (SummaryModel, FakeAnalysisStore, FakeEvidenceReader, FakeSpeakerStore) {
    let reader = FakeEvidenceReader(fixture: fixture)
    let store = FakeAnalysisStore()
    let transport = FakeAnalysisTransport()
    if run { try transport.script(response: "deployment-valid") }
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
