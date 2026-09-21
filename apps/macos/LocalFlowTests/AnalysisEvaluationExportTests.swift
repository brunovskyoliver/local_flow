import Foundation
import NaturalLanguage
import XCTest

@testable import LocalFlow

/// T103: the offline evaluation export. With `LOCALFLOW_ANALYSIS_EVAL_DIR`
/// set, every manifest case runs through the real analyzer against its
/// scripted response and the verdict lands in `analysis-eval.json` (0600):
/// run state, failure category, adopted text, owner labels, due values, the
/// request's candidate-name check and the report's copy text. The Python
/// script reads this file; no validation rule is reimplemented here.
@MainActor
final class AnalysisEvaluationExportTests: XCTestCase {

  /// The `fixtures/intelligence/README.md` manifest: fixture, scripted
  /// response and the outcome the case documents.
  private struct Case {
    let fixture: String
    let response: String
    /// `succeeded` or the expected failure category raw value.
    let expect: String
  }

  private static let cases: [Case] = [
    Case(fixture: "deployment", response: "deployment-valid", expect: "succeeded"),
    Case(fixture: "deployment", response: "fabricated-segment", expect: "source_validation"),
    Case(fixture: "deployment", response: "cross-meeting-segment", expect: "source_validation"),
    Case(fixture: "deployment", response: "mutated-ip-item", expect: "succeeded"),
    Case(fixture: "deployment", response: "mutated-price-decision", expect: "succeeded"),
    Case(fixture: "deployment", response: "mutated-digit-summary", expect: "protected_literal"),
    Case(fixture: "deployment", response: "over-cap-decisions", expect: "over_cap"),
    Case(fixture: "deployment", response: "unsupported-version", expect: "unsupported_version"),
    Case(fixture: "deployment", response: "wrong-meeting", expect: "meeting_mismatch"),
    Case(fixture: "deployment", response: "malformed-json", expect: "malformed_response"),
    Case(
      fixture: "certainty-possible", response: "named-possible-owner-certainty",
      expect: "succeeded"),
    Case(fixture: "deployment", response: "named-possible-owner", expect: "succeeded"),
    Case(fixture: "deployment", response: "mentioned-owner", expect: "succeeded"),
    Case(fixture: "due-dates", response: "due-dates-valid", expect: "succeeded"),
    Case(fixture: "slovak", response: "slovak-valid", expect: "succeeded"),
    Case(fixture: "english", response: "language-valid", expect: "succeeded"),
    Case(fixture: "mixed", response: "mixed-valid", expect: "succeeded"),
  ]

  private struct ItemVerdict: Encodable {
    let kind: String
    let text: String
    let sources: Int
    var owner: String? = nil
    var ownerCertainty: String? = nil
    var dueState: String? = nil
    var dueDate: String? = nil
    var dueOriginal: String? = nil
  }

  private struct Verdict: Encodable {
    let fixture: String
    let response: String
    let expect: String
    let state: String
    var failure: String? = nil
    var language: String? = nil
    var itemCount = 0
    var droppedLiteralCount = 0
    var droppedUnsupportedCount = 0
    var identityDowngradeCount = 0
    var unresolvedOwnerCount = 0
    /// Dominant language of the adopted text, detected the same way the
    /// client's `LanguagePolicy` detects request language.
    var detectedLanguage: String? = nil
    var expectedLanguage: String? = nil
    var expectedTerms: [String] = []
    var candidateNames: [String] = []
    var candidateInRequest = false
    var namedOwnerViolation = false
    var summaryText: String? = nil
    var items: [ItemVerdict] = []
    var copyText: String? = nil
  }

  func testExportAnalysisEvaluation() async throws {
    guard let path = ProcessInfo.processInfo.environment["LOCALFLOW_ANALYSIS_EVAL_DIR"] else {
      throw XCTSkip(
        "Set TEST_RUNNER_LOCALFLOW_ANALYSIS_EVAL_DIR for the offline evaluation export.")
    }
    let output = URL(fileURLWithPath: path, isDirectory: true)
    try FileManager.default.createDirectory(
      at: output, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    var verdicts: [Verdict] = []
    for entry in Self.cases {
      verdicts.append(try await evaluate(entry))
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let payload = try encoder.encode(verdicts)
    let file = output.appendingPathComponent("analysis-eval.json")
    FileManager.default.createFile(atPath: file.path, contents: payload)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o600], ofItemAtPath: file.path)
  }

  @MainActor
  private func evaluate(_ entry: Case) async throws -> Verdict {
    let fixture = try IntelligenceFixtures.meeting(entry.fixture)
    let reader = FakeEvidenceReader(fixture: fixture)
    let store = FakeAnalysisStore()
    let transport = FakeAnalysisTransport()
    try transport.script(response: entry.response)
    let analyzer = MeetingAnalyzer(
      evidence: reader, transport: transport, store: store,
      endpoint: {
        RewriteEndpoint(url: URL(string: "http://127.0.0.1:8765")!, origin: "test")
      },
      settings: { nil })
    let coordinator = MeetingIntelligenceCoordinator(
      analyzer: analyzer, store: store, automaticEnabled: { false })
    // Participant owners resolve their names through speaker summaries, so
    // mirror the fixture's participants one to one.
    let speakers = FakeSpeakerStore(
      summaries: fixture.participants.enumerated().map { ordinal, participant in
        speakerSummary(participant, ordinal: ordinal + 1)
      })
    let model = SummaryModel(
      meetingID: fixture.id, coordinator: coordinator, store: store,
      speakers: speakers, identities: FakeIdentityStore(), analyzer: analyzer,
      transcripts: reader)

    let run = try await analyzer.run(meetingID: fixture.id, trigger: .manual)
    await model.refresh()

    var verdict = Verdict(
      fixture: entry.fixture, response: entry.response, expect: entry.expect,
      state: run.state.rawValue,
      failure: run.failureCategory?.rawValue,
      language: run.languagePolicy?.rawValue,
      itemCount: run.itemCount,
      droppedLiteralCount: run.droppedLiteralCount,
      droppedUnsupportedCount: run.droppedUnsupportedCount,
      identityDowngradeCount: run.identityDowngradeCount,
      unresolvedOwnerCount: run.unresolvedOwnerCount,
      expectedLanguage: fixture.expectedLanguage,
      expectedTerms: fixture.expectedTerms,
      candidateNames: reader.candidateNameSet.sorted())

    // SC-002: a Possible-match candidate name never reaches the request body.
    let encoder = JSONEncoder()
    for request in transport.requests {
      let body = String(decoding: try encoder.encode(request), as: UTF8.self)
      if reader.candidateNameSet.contains(where: { body.contains($0) }) {
        verdict.candidateInRequest = true
      }
    }

    guard let read = model.readModel else { return verdict }
    verdict.summaryText = read.summary.text
    verdict.copyText = model.copyText()

    func itemVerdict(_ item: ItemReadModel) -> ItemVerdict {
      ItemVerdict(kind: item.kind.rawValue, text: item.text, sources: item.sources.count)
    }
    for item in read.decisions + read.nextSteps + read.openQuestions + read.risks {
      verdict.items.append(itemVerdict(item))
    }
    for item in read.actionItems {
      var row = ItemVerdict(
        kind: "action", text: item.text, sources: item.sources.count,
        dueState: item.dueState.rawValue, dueDate: item.dueDate,
        dueOriginal: item.dueOriginal)
      switch item.owner {
      case .participant(let name, _, let certainty):
        row.owner = name
        row.ownerCertainty = certainty.rawValue
        // SC-002: a Possible/Unknown participant can never carry a name.
        if certainty == .possible || certainty == .unknown {
          verdict.namedOwnerViolation = true
        }
      case .mentioned(let name, _):
        row.owner = name
        row.ownerCertainty = "mentioned"
      case .unresolved(let label):
        row.owner = label
        row.ownerCertainty = "unresolved"
      }
      verdict.items.append(row)
    }
    let prose = ([read.summary.text] + verdict.items.map(\.text)).joined(separator: " ")
    let recognizer = NLLanguageRecognizer()
    recognizer.processString(prose)
    verdict.detectedLanguage = recognizer.dominantLanguage?.rawValue
    return verdict
  }

  /// One fixture participant as the speaker summary the read model resolves
  /// owners against: Confirmed/Recognized carry the profile name, local-name
  /// and Possible/Unknown never do.
  private func speakerSummary(
    _ participant: EvidenceParticipant, ordinal: Int
  ) -> SpeakerSummary {
    switch participant.certainty {
    case .localUser:
      return SpeakerSummary(
        id: participant.speakerID, source: .local, labelOrdinal: ordinal,
        colorIndex: ordinal, displayName: participant.name, inRoom: false,
        speechMs: 1_000)
    case .confirmed, .recognized:
      return SpeakerSummary(
        id: participant.speakerID, source: .remote, labelOrdinal: ordinal,
        colorIndex: ordinal, displayName: nil, inRoom: false, speechMs: 1_000,
        identity: SpeakerIdentity(
          state: participant.certainty == .confirmed ? .confirmed : .recognized,
          origin: .userConfirmation,
          knownSpeakerID: participant.knownSpeakerID ?? UUID(),
          knownSpeakerName: participant.name))
    case .localName:
      return SpeakerSummary(
        id: participant.speakerID, source: .remote, labelOrdinal: ordinal,
        colorIndex: ordinal, displayName: participant.name, inRoom: false,
        speechMs: 1_000)
    case .possible:
      return SpeakerSummary(
        id: participant.speakerID, source: .remote, labelOrdinal: ordinal,
        colorIndex: ordinal, displayName: nil, inRoom: false, speechMs: 1_000,
        identity: SpeakerIdentity(
          state: .possible, origin: .automaticMatch,
          knownSpeakerID: participant.knownSpeakerID ?? UUID(),
          knownSpeakerName: nil))
    case .unknown:
      return SpeakerSummary(
        id: participant.speakerID, source: .remote, labelOrdinal: ordinal,
        colorIndex: ordinal, displayName: nil, inRoom: false, speechMs: 1_000)
    }
  }
}
