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

  // MARK: Helpers

  /// Runs the analyzer on `fixture` (unless `run` is false) against the
  /// scripted `deployment-valid` response, then returns the model plus the
  /// fakes the test tunes.
  private func makeModel(
    fixture: IntelligenceFixture, run: Bool = true
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
      speakers: speakers, identities: FakeIdentityStore(), analyzer: analyzer,
      transcripts: reader)
    if run {
      _ = try await analyzer.run(meetingID: fixture.id, trigger: .manual)
    }
    return (model, store, reader, speakers)
  }
}
