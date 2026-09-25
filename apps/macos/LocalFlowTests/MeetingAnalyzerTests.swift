import Foundation
import GRDB
import XCTest

@testable import LocalFlow

final class MeetingAnalyzerTests: XCTestCase {

  // MARK: T032 / FR-006 — eligibility

  func testNonFinalTranscriptRefusedWithoutRequest() async throws {
    let reader = FakeEvidenceReader()
    let store = FakeAnalysisStore()
    let transport = FakeAnalysisTransport()
    let analyzer = makeAnalyzer(reader: reader, store: store, transport: transport)
    let meetingID = UUID()
    reader.transcription = MeetingTranscription(
      meetingID: meetingID, state: .finalizing, liveRequested: false,
      passID: UUID(), updatedAt: 0)

    do {
      try await analyzer.run(meetingID: meetingID, trigger: .manual)
      XCTFail("expected not_eligible")
    } catch let failure as AnalysisFailure {
      XCTAssertEqual(failure.category, .notEligible)
    }
    XCTAssertTrue(transport.requests.isEmpty)
    XCTAssertEqual(store.admitCalls, 0)
  }

  func testMissingTranscriptRefusedWithoutRequest() async throws {
    let reader = FakeEvidenceReader()
    let store = FakeAnalysisStore()
    let transport = FakeAnalysisTransport()
    let analyzer = makeAnalyzer(reader: reader, store: store, transport: transport)

    do {
      try await analyzer.run(meetingID: UUID(), trigger: .manual)
      XCTFail("expected not_eligible")
    } catch let failure as AnalysisFailure {
      XCTAssertEqual(failure.category, .notEligible)
    }
    XCTAssertTrue(transport.requests.isEmpty)
    XCTAssertEqual(store.admitCalls, 0)
  }

  // MARK: T032 / FR-029 — full-path success

  func testDeploymentFixtureRunsFullAnalysis() async throws {
    let fixture = try IntelligenceFixtures.meeting("deployment")
    let reader = FakeEvidenceReader(fixture: fixture)
    let store = FakeAnalysisStore()
    let transport = FakeAnalysisTransport(fixture: fixture)
    try transport.script(response: "deployment-valid")
    let analyzer = makeAnalyzer(reader: reader, store: store, transport: transport)

    let run = try await analyzer.run(meetingID: fixture.id, trigger: .automatic)

    // pending → running → succeeded, each store write before the next publish.
    XCTAssertEqual(store.admitCalls, 1)
    XCTAssertEqual(store.adoptCalls, 1)
    XCTAssertEqual(store.startedRuns, [run.id])
    XCTAssertEqual(run.state, .succeeded)
    XCTAssertEqual(run.startedAt ?? 0 >= run.createdAt, true)
    XCTAssertEqual(run.completedAt ?? 0 >= run.startedAt ?? 0, true)

    let model = try await store.readModel(meetingID: fixture.id)
    XCTAssertEqual(
      model?.summary?.text,
      "The team settled the Monday deployment and split the preparation work.")
    let decisions = model?.items.filter { $0.kind == .decision } ?? []
    let actionItems = model?.items.filter { $0.kind == .actionItem } ?? []
    XCTAssertEqual(decisions.count, 1)
    XCTAssertEqual(decisions.first?.text, "Deployment moves to Monday")
    XCTAssertEqual(actionItems.count, 3)

    // Owners resolve to participants, never to stored names.
    let owners = actionItems.compactMap { item -> (UUID, ParticipantCertainty)? in
      guard case .participant(let id, _, let certainty) = item.owner else { return nil }
      return (id, certainty)
    }
    XCTAssertEqual(owners.count, 3)
    XCTAssertEqual(
      owners[0].0, UUID(uuidString: "aaaa0002-0000-4000-8000-000000000002"))
    XCTAssertEqual(owners[0].1, .localName)
    XCTAssertEqual(
      owners[1].0, UUID(uuidString: "aaaa0003-0000-4000-8000-000000000003"))
    XCTAssertEqual(owners[1].1, .localName)
    XCTAssertEqual(
      owners[2].0, UUID(uuidString: "aaaa0001-0000-4000-8000-000000000001"))
    XCTAssertEqual(owners[2].1, .confirmed)

    // Run identity (FR-046).
    let latest = try await store.latestRun(meetingID: fixture.id)
    XCTAssertEqual(latest?.state, .succeeded)
    XCTAssertEqual(latest?.serverVersion, "0.3.0")
    XCTAssertEqual(latest?.protocolVersion, 1)
    XCTAssertEqual(latest?.schemaVersion, 1)
    XCTAssertEqual(latest?.backendKind, "openai-compatible")
    XCTAssertEqual(latest?.backendModel, "test-model")
    XCTAssertEqual(latest?.pipelineVersion, "analysis_v1")
    XCTAssertEqual(latest?.languagePolicy, .en)
    XCTAssertEqual(latest?.promptVersions, "chunk=1,full=1,synthesis=1")
    XCTAssertEqual(latest?.requestConfigJSON, AnalysisPolicy().requestConfigJSON())
    XCTAssertEqual(latest?.inputBytes ?? 0 > 0, true)
    XCTAssertEqual(latest?.outputBytes ?? 0 > 0, true)

    // Evidence was read through the paged boundary; the reader protocol has no
    // transcription, diarization or identification entry points (FR-009).
    XCTAssertFalse(reader.pageRequests.isEmpty)
    let fixture2 = try IntelligenceFixtures.meeting("deployment")
    XCTAssertEqual(reader.segments.map(\.id), fixture2.segments.map(\.id))
  }

  func testRequestCarriesContractKeySetAndLanguagePolicy() async throws {
    let fixture = try IntelligenceFixtures.meeting("deployment")
    let reader = FakeEvidenceReader(fixture: fixture)
    let store = FakeAnalysisStore()
    let transport = FakeAnalysisTransport(fixture: fixture)
    try transport.script(response: "deployment-valid")
    let analyzer = makeAnalyzer(reader: reader, store: store, transport: transport)

    _ = try await analyzer.run(meetingID: fixture.id, trigger: .manual)

    let request = try XCTUnwrap(transport.requests.first)
    XCTAssertEqual(transport.requests.count, 1)
    XCTAssertEqual(request.stage, .full)
    XCTAssertNil(request.chunk)
    XCTAssertNil(request.partials)

    let data = try JSONEncoder().encode(request)
    let object = try XCTUnwrap(
      JSONSerialization.jsonObject(with: data) as? [String: Any])
    XCTAssertEqual(
      Set(object.keys),
      [
        "schema_version", "request_id", "run_id", "priority", "stage",
        "meeting", "participants", "segments", "notes",
      ])
    XCTAssertEqual(object["schema_version"] as? Int, 1)
    XCTAssertEqual(object["priority"] as? String, "background")
    XCTAssertEqual(object["stage"] as? String, "full")

    let meeting = try XCTUnwrap(object["meeting"] as? [String: Any])
    let language = try XCTUnwrap(meeting["language_policy"] as? [String: Any])
    XCTAssertEqual(language["output"] as? String, "en")
    XCTAssertEqual(language["preserve_terms"] as? Bool, true)

    // The possible-match participant ships without a name; the others ship
    // theirs.
    let participants = try XCTUnwrap(object["participants"] as? [[String: Any]])
    XCTAssertEqual(participants.count, 4)
    let possible = try XCTUnwrap(
      participants.first { ($0["certainty"] as? String) == "possible" })
    XCTAssertNil(possible["name"])
    let confirmed = try XCTUnwrap(
      participants.first { ($0["certainty"] as? String) == "confirmed" })
    XCTAssertEqual(confirmed["name"] as? String, "Oliver Brunovský")
  }

  func testUnsupportedResultSchemaRefused() async throws {
    let fixture = try IntelligenceFixtures.meeting("deployment")
    let reader = FakeEvidenceReader(fixture: fixture)
    let store = FakeAnalysisStore()
    let transport = FakeAnalysisTransport(fixture: fixture)
    let health = try await transport.health(
      endpoint: RewriteEndpoint(
        url: URL(string: "http://127.0.0.1:8765")!, origin: "test"))
    transport.healthResult = .success(
      AnalysisHealth(
        schemaVersion: 1, service: AnalysisHealth.serviceName,
        protocolVersions: [1], serverName: "flowd", serverVersion: "0.3.0",
        backend: health.backend, promptVersions: health.promptVersions,
        resultSchemaVersion: 2, limits: health.limits, caps: health.caps))
    let analyzer = makeAnalyzer(reader: reader, store: store, transport: transport)

    let run = try await analyzer.run(meetingID: fixture.id, trigger: .manual)
    XCTAssertEqual(run.state, .failed)
    XCTAssertEqual(run.failureCategory, .unsupportedVersion)
    XCTAssertTrue(transport.requests.isEmpty)
  }

  func testServerErrorEventFailsRunWithCategory() async throws {
    let fixture = try IntelligenceFixtures.meeting("deployment")
    let reader = FakeEvidenceReader(fixture: fixture)
    let store = FakeAnalysisStore()
    let transport = FakeAnalysisTransport(fixture: fixture)
    transport.script(
      .full,
      [
        .lines(
          FakeAnalysisTransport.Lines(value: [
            [
              "type": "error", "schema_version": 1, "request_id": "*",
              "code": "backend_timeout",
            ]
          ]))
      ])
    let analyzer = makeAnalyzer(reader: reader, store: store, transport: transport)

    let run = try await analyzer.run(meetingID: fixture.id, trigger: .manual)
    XCTAssertEqual(run.state, .failed)
    XCTAssertEqual(run.failureCategory, .backendTimeout)
  }

  func testEvidenceChangedMidRunFailsSourceValidation() async throws {
    let fixture = try IntelligenceFixtures.meeting("deployment")
    let inner = FakeEvidenceReader(fixture: fixture)
    // Read 1 is admission, 2 the start check; 3, before adoption, changes.
    let reader = SecondReadMutatingReader(inner: inner, mutatingFrom: 3)
    let store = FakeAnalysisStore()
    let transport = FakeAnalysisTransport(fixture: fixture)
    try transport.script(response: "deployment-valid")
    let analyzer = MeetingAnalyzer(
      evidence: reader, transport: transport, store: store,
      clock: FakeMeetingClock(),
      endpoint: {
        RewriteEndpoint(url: URL(string: "http://127.0.0.1:8765")!, origin: "test")
      },
      settings: { nil })

    // The second evidence snapshot (before adoption) sees an extra note, so
    // the recomputed version no longer matches the admitted one.
    let run = try await analyzer.run(meetingID: fixture.id, trigger: .manual)
    XCTAssertEqual(run.state, .failed)
    XCTAssertEqual(run.failureCategory, .sourceValidation)
    XCTAssertEqual(run.failureDetail, "evidence_changed")
    XCTAssertEqual(transport.requests.count, 1, "the request ran; adoption was refused")
  }

  /// A run can wait in the queue after admission; evidence that changed in
  /// the meantime fails it at start, before any request is spent.
  func testQueuedRunWithChangedEvidenceFailsBeforeAnyRequest() async throws {
    let fixture = try IntelligenceFixtures.meeting("deployment")
    let reader = FakeEvidenceReader(fixture: fixture)
    let store = FakeAnalysisStore()
    let transport = FakeAnalysisTransport(fixture: fixture)
    try transport.script(response: "deployment-valid")
    let analyzer = makeAnalyzer(reader: reader, store: store, transport: transport)

    let admission = try await analyzer.admit(meetingID: fixture.id, trigger: .automatic)
    reader.noteRows.append(
      NoteParagraph(
        ordinal: 99, text: "added while queued", hash: String(repeating: "e", count: 64)))
    let run = try await analyzer.execute(admission)
    XCTAssertEqual(run.state, .failed)
    XCTAssertEqual(run.failureCategory, .sourceValidation)
    XCTAssertEqual(run.failureDetail, "evidence_changed")
    XCTAssertTrue(transport.requests.isEmpty)
    XCTAssertEqual(store.adoptCalls, 0)
  }

  /// Summaries from one backend never mix with partials from another: the
  /// partial cache is keyed (and scoped) by the pinned backend.
  func testPartialCacheIsKeyedByBackend() async throws {
    let cache = AnalysisPartialCache()
    let meetingID = UUID()
    let result = AnalysisResult(
      schemaVersion: 1, meetingID: meetingID, partial: true, language: .en,
      summary: WireSummary(text: "A part.", sources: [], wholeMeeting: false),
      topics: [], decisions: [], actionItems: [], nextSteps: [], openQuestions: [], risks: [])
    func key(_ backend: String) -> AnalysisPartialCache.Key {
      .init(
        meetingID: meetingID, evidenceVersion: "v", backend: backend,
        firstOrdinal: 0, lastOrdinal: 10)
    }
    await cache.store(result, for: key("a"))
    let fromA = await cache.result(for: key("a"))
    let fromB = await cache.result(for: key("b"))
    XCTAssertNotNil(fromA)
    XCTAssertNil(fromB)
    await cache.store(result, for: key("b"))
    let afterSwitch = await cache.result(for: key("a"))
    XCTAssertNil(afterSwitch, "a new backend replaces the scope")
  }

  func testResolvedLanguageCacheIsBounded() {
    let cache = ResolvedLanguageCache()
    let passID = UUID()
    func key(_ n: Int) -> ResolvedLanguageCache.Key {
      .init(
        passID: n == 0 ? passID : UUID(), meetingLanguage: nil, transcriptPipeline: nil,
        sampleBytes: n)
    }
    cache.store(.sk, for: key(0))
    XCTAssertEqual(cache.value(for: key(0)), .sk)
    XCTAssertNil(
      cache.value(
        for: .init(
          passID: passID, meetingLanguage: .english, transcriptPipeline: nil, sampleBytes: 0)),
      "the meeting's language setting is part of the key")
    for n in 1...ResolvedLanguageCache.capacity { cache.store(.en, for: key(n)) }
    XCTAssertNil(cache.value(for: key(0)), "cleared when full")
  }

  // MARK: T051 — the request never leaks uncertain identity

  /// For every certainty fixture the encoded request carries no Possible-match
  /// candidate name, no name for any Unknown participant, no `known_speakers`
  /// list, no embedding, no vocabulary and no other meeting's id (spec US3).
  func testRequestNeverLeaksUncertainIdentity() async throws {
    let fixtureNames = [
      "deployment", "slovak", "english", "mixed", "due-dates",
      "certainty-confirmed", "certainty-possible", "certainty-unknown",
    ]
    let otherIDs = try fixtureNames.map { try IntelligenceFixtures.meeting($0).id }

    for name in ["certainty-possible", "certainty-unknown", "certainty-confirmed", "deployment"] {
      let fixture = try IntelligenceFixtures.meeting(name)
      let reader = FakeEvidenceReader(fixture: fixture)
      let store = FakeAnalysisStore()
      let transport = FakeAnalysisTransport(fixture: fixture)
      try transport.script(
        response: name == "deployment" ? "deployment-valid" : "certainty-confirmed")
      let analyzer = makeAnalyzer(reader: reader, store: store, transport: transport)

      _ = try await analyzer.run(meetingID: fixture.id, trigger: .manual)

      let request = try XCTUnwrap(transport.requests.first, name)
      let data = try JSONEncoder().encode(request)
      let body = String(decoding: data, as: UTF8.self)
      XCTAssertFalse(body.contains("Tomáš Juríček"), name)
      XCTAssertFalse(body.contains("candidate"), name)
      XCTAssertFalse(body.contains("known_speakers"), name)
      XCTAssertFalse(body.contains("embedding"), name)
      XCTAssertFalse(body.contains("vocabulary"), name)
      for id in otherIDs where id != fixture.id {
        XCTAssertFalse(body.contains(id.uuidString), "\(name) leaked a foreign meeting id")
      }

      let object = try XCTUnwrap(
        JSONSerialization.jsonObject(with: data) as? [String: Any], name)
      let participants = try XCTUnwrap(object["participants"] as? [[String: Any]], name)
      for participant in participants {
        let certainty = participant["certainty"] as? String
        if certainty == "possible" || certainty == "unknown" {
          XCTAssertNil(participant["name"], "\(name): \(certainty) participant named")
        }
      }
    }
  }

  /// A `local_name` participant on a Possible-match root ships only the typed
  /// name — never the candidate name the matcher proposed.
  func testLocalNameOnPossibleRootCarriesOnlyTypedName() async throws {
    let fixture = try IntelligenceFixtures.meeting("certainty-possible")
    let reader = FakeEvidenceReader(fixture: fixture)
    let speaker = UUID()
    reader.participantRows = [
      EvidenceParticipant(
        speakerID: speaker, certainty: .localName, origin: "automatic_match",
        knownSpeakerID: UUID(), name: "Stretko")
    ]
    XCTAssertEqual(reader.candidateNameSet, ["Tomáš Juríček"])
    let store = FakeAnalysisStore()
    let transport = FakeAnalysisTransport(fixture: fixture)
    try transport.script(response: "certainty-confirmed")
    let analyzer = makeAnalyzer(reader: reader, store: store, transport: transport)

    _ = try await analyzer.run(meetingID: fixture.id, trigger: .manual)

    let request = try XCTUnwrap(transport.requests.first)
    let data = try JSONEncoder().encode(request)
    XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("Tomáš Juríček"))
    let object = try XCTUnwrap(
      JSONSerialization.jsonObject(with: data) as? [String: Any])
    let participants = try XCTUnwrap(object["participants"] as? [[String: Any]])
    let local = try XCTUnwrap(
      participants.first { ($0["certainty"] as? String) == "local_name" })
    XCTAssertEqual(local["name"] as? String, "Stretko")
  }

  /// The local root linked to a saved voice profile is sent with its name but
  /// without `known_speaker_id`, which the server allows only for confirmed and
  /// recognized matches (the 2026-09-20 call failed with `invalid_request`).
  func testLocalUserWithProfileIsSentWithoutKnownSpeakerID() async throws {
    let fixture = try IntelligenceFixtures.meeting("certainty-possible")
    let reader = FakeEvidenceReader(fixture: fixture)
    reader.participantRows = [
      EvidenceParticipant(
        speakerID: UUID(), certainty: .localUser, origin: "none",
        knownSpeakerID: UUID(), name: "Oliver", isLocalUser: true)
    ]
    let store = FakeAnalysisStore()
    let transport = FakeAnalysisTransport(fixture: fixture)
    try transport.script(response: "certainty-confirmed")
    let analyzer = makeAnalyzer(reader: reader, store: store, transport: transport)

    _ = try await analyzer.run(meetingID: fixture.id, trigger: .manual)

    let request = try XCTUnwrap(transport.requests.first)
    let data = try JSONEncoder().encode(request)
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let participants = try XCTUnwrap(object["participants"] as? [[String: Any]])
    let local = try XCTUnwrap(
      participants.first { ($0["certainty"] as? String) == "local_user" })
    XCTAssertEqual(local["name"] as? String, "Oliver")
    XCTAssertNil(local["known_speaker_id"])
  }

  /// A server response that names a Possible-match speaker as a participant
  /// owner is re-checked against the identity rule: the adopted owner is
  /// unresolved and the downgrade is counted — the run still succeeds.
  func testServerNamedPossibleOwnerDowngrades() async throws {
    let fixture = try IntelligenceFixtures.meeting("deployment")
    let reader = FakeEvidenceReader(fixture: fixture)
    let store = FakeAnalysisStore()
    let transport = FakeAnalysisTransport(fixture: fixture)
    try transport.script(response: "named-possible-owner")
    let analyzer = makeAnalyzer(reader: reader, store: store, transport: transport)

    let run = try await analyzer.run(meetingID: fixture.id, trigger: .manual)

    XCTAssertEqual(run.state, .succeeded)
    XCTAssertEqual(run.identityDowngradeCount, 1)
    XCTAssertEqual(run.unresolvedOwnerCount, 1)
    let model = try await store.readModel(meetingID: fixture.id)
    let item = try XCTUnwrap(model?.items.first { $0.kind == .actionItem })
    XCTAssertEqual(item.owner, ValidatedOwner.none)
    XCTAssertEqual(item.ownershipState, .unresolved)
  }

  // MARK: T059 — conservative due dates end to end

  /// The due-dates fixture: "tomorrow" re-resolves client-side to 2026-09-21,
  /// "soon" stays unresolved, "Send the report" survives ownerless, and
  /// exactly one decision is stored (spec US4).
  func testDueDatesFixtureResolvesConservatively() async throws {
    let fixture = try IntelligenceFixtures.meeting("due-dates")
    let reader = FakeEvidenceReader(fixture: fixture)
    let store = FakeAnalysisStore()
    let transport = FakeAnalysisTransport(fixture: fixture)
    try transport.script(response: "due-dates-valid")
    let analyzer = makeAnalyzer(reader: reader, store: store, transport: transport)

    let run = try await analyzer.run(meetingID: fixture.id, trigger: .automatic)

    XCTAssertEqual(run.state, .succeeded)
    let model = try await store.readModel(meetingID: fixture.id)
    let decisions = model?.items.filter { $0.kind == .decision } ?? []
    XCTAssertEqual(decisions.count, 1)
    XCTAssertEqual(decisions.first?.text, "We will deploy on Monday")

    let items = model?.items.filter { $0.kind == .actionItem } ?? []
    XCTAssertEqual(items.count, 3)

    XCTAssertEqual(items[0].due?.state, .explicitRelativeResolved)
    XCTAssertEqual(items[0].due?.date, "2026-09-21")
    XCTAssertEqual(items[0].due?.original, "tomorrow")

    XCTAssertEqual(items[1].due?.state, .unresolved)
    XCTAssertNil(items[1].due?.date)
    XCTAssertEqual(items[1].due?.original, "soon")

    let report = try XCTUnwrap(items.first { $0.text == "Send the report" })
    XCTAssertEqual(report.owner, ValidatedOwner.none)
    XCTAssertEqual(report.ownershipState, .unresolved)
    XCTAssertEqual(report.due?.state, .absent)
    XCTAssertNil(report.due?.date)
  }

  // MARK: T065 — mutated literals

  /// The mutated-IP and mutated-price responses each adopt with the forged
  /// item dropped and `dropped_literal_count` on the run row; the dropped
  /// text appears nowhere in the stored rows.
  func testMutatedLiteralResponsesDropItemsAndCount() async throws {
    let fixture = try IntelligenceFixtures.meeting("deployment")
    let reader = FakeEvidenceReader(fixture: fixture)
    let store = FakeAnalysisStore()
    let transport = FakeAnalysisTransport(fixture: fixture)
    let ip = try IntelligenceFixtures.response("mutated-ip-item")[.full]![0]
    let price = try IntelligenceFixtures.response("mutated-price-decision")[.full]![0]
    transport.script(.full, [.lines(.init(value: ip)), .lines(.init(value: price))])
    let analyzer = makeAnalyzer(reader: reader, store: store, transport: transport)

    let first = try await analyzer.run(meetingID: fixture.id, trigger: .manual)
    XCTAssertEqual(first.state, .succeeded)
    XCTAssertEqual(first.droppedLiteralCount, 1)
    var model = try await store.readModel(meetingID: fixture.id)
    XCTAssertEqual(model?.items.filter { $0.kind == .actionItem }.count, 3)
    XCTAssertFalse(
      (model?.items ?? []).contains { ($0.text).contains("172.19.223.20") })

    let second = try await analyzer.run(meetingID: fixture.id, trigger: .manual)
    XCTAssertEqual(second.state, .succeeded)
    XCTAssertEqual(second.droppedLiteralCount, 1)
    model = try await store.readModel(meetingID: fixture.id)
    XCTAssertEqual(model?.items.filter { $0.kind == .decision }.count, 1)
    XCTAssertFalse(
      (model?.items ?? []).contains { ($0.text).contains("$1,300") })
  }

  /// A summary-level mutation fails the run `protected_literal`: no content
  /// row is written and the previously accepted analysis and evidence stay
  /// byte-identical.
  func testMutatedSummaryLiteralFailsAndPreservesAccepted() async throws {
    let fixture = try IntelligenceFixtures.meeting("deployment")
    let reader = FakeEvidenceReader(fixture: fixture)
    let store = FakeAnalysisStore()
    let transport = FakeAnalysisTransport(fixture: fixture)
    let valid = try IntelligenceFixtures.response("deployment-valid")[.full]![0]
    let mutated = try IntelligenceFixtures.response("mutated-digit-summary")[.full]![0]
    transport.script(.full, [.lines(.init(value: valid)), .lines(.init(value: mutated))])
    let analyzer = makeAnalyzer(reader: reader, store: store, transport: transport)

    let first = try await analyzer.run(meetingID: fixture.id, trigger: .manual)
    XCTAssertEqual(first.state, .succeeded)
    let accepted = try await store.readModel(meetingID: fixture.id)

    let second = try await analyzer.run(meetingID: fixture.id, trigger: .manual)
    XCTAssertEqual(second.state, .failed)
    XCTAssertEqual(second.failureCategory, .protectedLiteral)

    let preserved = try await store.readModel(meetingID: fixture.id)
    XCTAssertEqual(preserved, accepted)
  }

  // MARK: T068 — failure matrix

  /// Every transport or validation failure lands on the run row with a
  /// category and `completed_at`; no content row is written and the accepted
  /// analysis — when one exists — stays byte-identical (T068).
  private func runAndAssertFailure(
    steps: [FakeAnalysisTransport.Step],
    category: AnalysisFailureCategory,
    state: AnalysisRunState = .failed,
    file: StaticString = #filePath, line: UInt = #line
  ) async throws {
    let fixture = try IntelligenceFixtures.meeting("deployment")
    let reader = FakeEvidenceReader(fixture: fixture)
    let store = FakeAnalysisStore()
    let transport = FakeAnalysisTransport(fixture: fixture)
    let valid = try IntelligenceFixtures.response("deployment-valid")[.full]![0]
    transport.script(.full, [.lines(.init(value: valid))] + steps)
    let analyzer = makeAnalyzer(reader: reader, store: store, transport: transport)

    let accepted = try await analyzer.run(meetingID: fixture.id, trigger: .manual)
    XCTAssertEqual(accepted.state, .succeeded, file: file, line: line)
    let before = try await store.readModel(meetingID: fixture.id)

    let run = try await analyzer.run(meetingID: fixture.id, trigger: .manual)
    XCTAssertEqual(run.state, state, file: file, line: line)
    XCTAssertEqual(run.failureCategory, category, file: file, line: line)
    XCTAssertNotNil(run.completedAt, file: file, line: line)
    let after = try await store.readModel(meetingID: fixture.id)
    XCTAssertEqual(after, before, file: file, line: line)
  }

  func testFailureMatrixTransportErrors() async throws {
    // What AnalysisClient throws for a refused connection, a 401 and a 404.
    for (error, category) in [
      (AnalysisFailure(.serverUnreachable), AnalysisFailureCategory.serverUnreachable),
      (AnalysisFailure(.authenticationFailed), .authenticationFailed),
      (AnalysisFailure(.serverUnavailable), .serverUnavailable),
      (AnalysisFailure(.oversizedResponse), .oversizedResponse),
    ] {
      try await runAndAssertFailure(steps: [.failure(error)], category: category)
    }
  }

  func testFailureMatrixServerErrorEvents() async throws {
    for (code, category) in [
      ("backend_unavailable", AnalysisFailureCategory.backendUnavailable),
      ("backend_timeout", .backendTimeout),
      ("backend_first_token_timeout", .backendTimeout),
    ] {
      let event: [String: Any] = [
        "schema_version": 1, "type": "error", "request_id": "*", "code": code,
      ]
      try await runAndAssertFailure(
        steps: [.lines(.init(value: [event]))], category: category)
    }
  }

  func testFailureMatrixResponseFixtures() async throws {
    for (name, category) in [
      ("unsupported-version", AnalysisFailureCategory.unsupportedVersion),
      ("malformed-json", .malformedResponse),
      ("wrong-meeting", .meetingMismatch),
      ("over-cap-decisions", .overCap),
    ] {
      let batch = try IntelligenceFixtures.response(name)[.full]![0]
      try await runAndAssertFailure(steps: [.lines(.init(value: batch))], category: category)
    }
  }

  /// SQLITE_FULL from the store maps to `persistence_capacity`, not a generic
  /// failure — the UI tells the user storage is full.
  func testStoreCapacityMapsToPersistenceCapacity() async throws {
    let fixture = try IntelligenceFixtures.meeting("deployment")
    let reader = FakeEvidenceReader(fixture: fixture)
    let store = FakeAnalysisStore()
    let transport = FakeAnalysisTransport(fixture: fixture)
    try transport.script(response: "deployment-valid")
    store.failures["adopt"] = DatabaseError(resultCode: .SQLITE_FULL, message: "full")
    let analyzer = makeAnalyzer(reader: reader, store: store, transport: transport)

    let run = try await analyzer.run(meetingID: fixture.id, trigger: .manual)
    XCTAssertEqual(run.state, .failed)
    XCTAssertEqual(run.failureCategory, .persistenceCapacity)
    let model = try await store.readModel(meetingID: fixture.id)
    XCTAssertNil(model)
  }

  /// R11: the deadline is 60 s + 90 s × 1 request = 150 s. A stream still
  /// parked when the clock passes it ends the run `timed_out` and cancels the
  /// work — nothing is adopted when the gate opens afterwards.
  func testRunDeadlineFiresTimedOut() async throws {
    let fixture = try IntelligenceFixtures.meeting("deployment")
    let reader = FakeEvidenceReader(fixture: fixture)
    let store = FakeAnalysisStore()
    let transport = FakeAnalysisTransport(fixture: fixture)
    let batch = try IntelligenceFixtures.response("deployment-valid")[.full]![0]
    let gate = PreparationGate()
    transport.script(.full, [.hold(gate, lines: .init(value: batch))])
    let clock = FakeMeetingClock()
    let analyzer = makeAnalyzer(
      reader: reader, store: store, transport: transport, clock: clock)

    let task = Task { try await analyzer.run(meetingID: fixture.id, trigger: .manual) }
    await clock.waitForSleepers()
    // One request: the run deadline is 60 s plus one per-request timeout.
    await clock.advance(by: AnalysisPolicy().runDeadline(requestCount: 1))
    let run = try await task.value
    XCTAssertEqual(run.state, .timedOut)
    XCTAssertEqual(run.failureCategory, .timeout)
    XCTAssertNotNil(run.completedAt)
    await gate.open()
    let model = try await store.readModel(meetingID: fixture.id)
    XCTAssertNil(model)
  }

  /// Cancelling mid-stream cancels the transport and writes `cancelled`; a
  /// result that arrives afterwards writes nothing.
  func testCancellationMidStreamWritesCancelled() async throws {
    let fixture = try IntelligenceFixtures.meeting("deployment")
    let reader = FakeEvidenceReader(fixture: fixture)
    let store = FakeAnalysisStore()
    let transport = FakeAnalysisTransport(fixture: fixture)
    let batch = try IntelligenceFixtures.response("deployment-valid")[.full]![0]
    let gate = PreparationGate()
    transport.script(.full, [.hold(gate, lines: .init(value: batch))])
    let analyzer = makeAnalyzer(reader: reader, store: store, transport: transport)

    let task = Task { try await analyzer.run(meetingID: fixture.id, trigger: .manual) }
    await gate.waitUntilStarted()
    task.cancel()
    await gate.open()
    await assertThrowsErrorAsync(try await task.value) { error in
      XCTAssertTrue(error is CancellationError)
    }
    let run = try await store.latestRun(meetingID: fixture.id)
    XCTAssertEqual(run?.state, .cancelled)
    let model = try await store.readModel(meetingID: fixture.id)
    XCTAssertNil(model)
  }

  /// A retry on unchanged evidence hashes to the same `evidence_version`.
  func testRetryReusesEvidenceVersionWhenUnchanged() async throws {
    let fixture = try IntelligenceFixtures.meeting("deployment")
    let reader = FakeEvidenceReader(fixture: fixture)
    let store = FakeAnalysisStore()
    let transport = FakeAnalysisTransport(fixture: fixture)
    try transport.script(response: "deployment-valid")
    let analyzer = makeAnalyzer(reader: reader, store: store, transport: transport)

    let first = try await analyzer.run(meetingID: fixture.id, trigger: .manual)
    let retry = try await analyzer.run(meetingID: fixture.id, trigger: .retry)
    XCTAssertEqual(first.state, .succeeded)
    XCTAssertEqual(retry.state, .succeeded)
    XCTAssertEqual(retry.evidenceVersion, first.evidenceVersion)
    let rows = try await store.runs(meetingID: fixture.id, limit: 10)
    XCTAssertEqual(rows.count, 2)
  }

  // MARK: T075 — regeneration and FR-011

  /// A successful `regenerate` supersedes the previous accepted run, deletes
  /// its content rows and records the evidence version it validated against.
  /// The analyzer never calls transcription, diarization or identification —
  /// it reuses the evidence reader's current snapshot.
  func testRegenerateSupersedesOldRunAndAdoptsNewEvidence() async throws {
    let fixture = try IntelligenceFixtures.meeting("deployment")
    let reader = FakeEvidenceReader(fixture: fixture)
    let store = FakeAnalysisStore()
    let transport = FakeAnalysisTransport(fixture: fixture)
    try transport.script(response: "deployment-valid")
    let analyzer = makeAnalyzer(reader: reader, store: store, transport: transport)

    let first = try await analyzer.run(meetingID: fixture.id, trigger: .manual)
    XCTAssertEqual(first.state, .succeeded)

    // The evidence changed since the accepted run: the transcript gained a
    // segment, so the regeneration records a new evidence version.
    reader.segments.append(
      EvidenceSegment(
        id: UUID(), ordinal: reader.segments.count, startMs: 0, endMs: 1,
        speaker: .unknown, text: "One more remark."))

    let regen = try await analyzer.run(meetingID: fixture.id, trigger: .regenerate)
    XCTAssertEqual(regen.state, .succeeded)
    XCTAssertEqual(regen.trigger, .regenerate)
    XCTAssertNotEqual(regen.evidenceVersion, first.evidenceVersion)

    // The old run is superseded with no content rows; the read model is the
    // new run's analysis.
    let rows = try await store.runs(meetingID: fixture.id, limit: 10)
    XCTAssertEqual(rows.first { $0.id == first.id }?.state, .superseded)
    let model = try await store.readModel(meetingID: fixture.id)
    XCTAssertEqual(model?.run.id, regen.id)
  }

  /// A failed regeneration leaves the accepted analysis byte-identical.
  func testFailedRegenerationPreservesAcceptedAnalysis() async throws {
    let fixture = try IntelligenceFixtures.meeting("deployment")
    let reader = FakeEvidenceReader(fixture: fixture)
    let store = FakeAnalysisStore()
    let transport = FakeAnalysisTransport(fixture: fixture)
    let valid = try IntelligenceFixtures.response("deployment-valid")[.full]![0]
    transport.script(
      .full,
      [
        .lines(FakeAnalysisTransport.Lines(value: valid)),
        .failure(AnalysisFailure(.serverUnreachable)),
      ])
    let analyzer = makeAnalyzer(reader: reader, store: store, transport: transport)

    let first = try await analyzer.run(meetingID: fixture.id, trigger: .manual)
    XCTAssertEqual(first.state, .succeeded)
    let accepted = try await store.readModel(meetingID: fixture.id)

    let regen = try await analyzer.run(meetingID: fixture.id, trigger: .regenerate)
    XCTAssertEqual(regen.state, .failed)
    XCTAssertEqual(regen.failureCategory, .serverUnreachable)
    XCTAssertEqual(regen.trigger, .regenerate)

    let preserved = try await store.readModel(meetingID: fixture.id)
    XCTAssertEqual(preserved, accepted)
  }

  /// FR-011: a run whose response lands after it lost the `current_run_id`
  /// race writes nothing; its row is superseded, never failed, and the newer
  /// run's accepted state wins.
  func testOlderRunFinishingLastIsDiscarded() async throws {
    let fixture = try IntelligenceFixtures.meeting("deployment")
    let reader = FakeEvidenceReader(fixture: fixture)
    let store = FakeAnalysisStore()
    let transport = FakeAnalysisTransport(fixture: fixture)
    let gate = PreparationGate()
    let valid = try IntelligenceFixtures.response("deployment-valid")[.full]![0]
    transport.script(
      .full,
      [
        .holdBeforeCompletion(gate, lines: .init(value: valid)),
        .lines(.init(value: valid)),
      ])
    let analyzer = makeAnalyzer(reader: reader, store: store, transport: transport)

    let admissionA = try await analyzer.admit(meetingID: fixture.id, trigger: .manual)
    let taskA = Task { try await analyzer.execute(admissionA) }
    // A is running; its stream delivered the result and parks before
    // `completed`. Then A loses the race: it goes terminal mid-flight.
    for _ in 0..<200 {
      if (try? await store.latestRun(meetingID: fixture.id))?.state == .running { break }
      await Task.yield()
    }
    try await store.supersede(runID: admissionA.run.id, now: 2)

    let admissionB = try await analyzer.admit(meetingID: fixture.id, trigger: .manual)
    let runB = try await analyzer.execute(admissionB)
    XCTAssertEqual(runB.state, .succeeded)

    await gate.open()
    let late = try await taskA.value
    XCTAssertEqual(late.id, runB.id, "the stale run returns the winning state")

    let rows = try await store.runs(meetingID: fixture.id, limit: 10)
    let runA = try XCTUnwrap(rows.first { $0.id == admissionA.run.id })
    XCTAssertEqual(runA.state, .superseded)
    XCTAssertNil(runA.failureCategory, "a discarded result is not a failure")
    let model = try await store.readModel(meetingID: fixture.id)
    XCTAssertEqual(model?.run.id, runB.id)
  }

  // MARK: Helpers

  // MARK: T045 — fabricated and foreign sources

  /// A `source_ref` that names no segment of this meeting's final pass fails
  /// the run `source_validation`; no content row is written and the prior
  /// accepted analysis stays byte-identical.
  func testFabricatedAndCrossMeetingSourcesFailAndPreserveAccepted() async throws {
    let fixture = try IntelligenceFixtures.meeting("deployment")
    let reader = FakeEvidenceReader(fixture: fixture)
    let store = FakeAnalysisStore()
    let transport = FakeAnalysisTransport()
    let valid = try IntelligenceFixtures.response("deployment-valid")[.full]![0]
    let fabricated = try IntelligenceFixtures.response("fabricated-segment")[.full]![0]
    let foreign = try IntelligenceFixtures.response("cross-meeting-segment")[.full]![0]
    transport.script(
      .full,
      [
        .lines(.init(value: valid)), .lines(.init(value: fabricated)),
        .lines(.init(value: foreign)),
      ])
    let analyzer = makeAnalyzer(reader: reader, store: store, transport: transport)

    let first = try await analyzer.run(meetingID: fixture.id, trigger: .manual)
    XCTAssertEqual(first.state, .succeeded)
    let accepted = try await store.readModel(meetingID: fixture.id)

    let second = try await analyzer.run(meetingID: fixture.id, trigger: .manual)
    XCTAssertEqual(second.state, .failed)
    XCTAssertEqual(second.failureCategory, .sourceValidation)

    let third = try await analyzer.run(meetingID: fixture.id, trigger: .manual)
    XCTAssertEqual(third.state, .failed)
    XCTAssertEqual(third.failureCategory, .sourceValidation)

    // The accepted analysis is byte-identical; neither failed run wrote content.
    let preserved = try await store.readModel(meetingID: fixture.id)
    XCTAssertEqual(preserved, accepted)
  }

  // MARK: T088 — bounded staged analysis (US9)

  /// One scripted chunk stream: `accepted` plus a partial result. The tail
  /// chunk carries the last-five-minute decision; the others carry only a
  /// summary in meeting vocabulary (the lexical support check runs on every
  /// stage's output).
  private func chunkStep(
    index: Int, decisionSegmentID: String?,
    summary: String = "The group discussed the release checklist."
  ) -> FakeAnalysisTransport.Step {
    var decisions: [[String: Any]] = []
    if let decisionSegmentID {
      decisions.append([
        "text": "Deployment moves to Monday",
        "evidence_class": "explicit",
        "sources": [["kind": "segment", "id": decisionSegmentID]],
      ])
    }
    return .lines(
      FakeAnalysisTransport.Lines(value: [
        [
          "schema_version": 1, "type": "accepted", "request_id": "*",
          "server": ["name": "flowd", "version": "0.3.0"],
        ],
        [
          "schema_version": 1, "type": "result", "request_id": "*", "run_id": "*",
          "stage": "chunk",
          "server": ["name": "flowd", "version": "0.3.0"],
          "backend": ["kind": "openai-compatible", "model": "test-model"],
          "prompt_version": 1, "pipeline_version": "analysis_v1",
          "analysis": [
            "schema_version": 1, "meeting_id": "*", "partial": true,
            "language": "*",
            "summary": [
              "text": summary,
              "sources": [], "whole_meeting": false,
            ],
            "topics": [], "decisions": decisions, "action_items": [],
            "next_steps": [], "open_questions": [], "risks": [],
          ],
        ] as [String: Any],
      ]))
  }

  private func synthesisStep(decisionSegmentID: String) -> FakeAnalysisTransport.Step {
    .lines(
      FakeAnalysisTransport.Lines(value: [
        [
          "schema_version": 1, "type": "accepted", "request_id": "*",
          "server": ["name": "flowd", "version": "0.3.0"],
        ],
        [
          "schema_version": 1, "type": "result", "request_id": "*", "run_id": "*",
          "stage": "synthesis",
          "server": ["name": "flowd", "version": "0.3.0"],
          "backend": ["kind": "openai-compatible", "model": "test-model"],
          "prompt_version": 1, "pipeline_version": "analysis_v1",
          "analysis": [
            "schema_version": 1, "meeting_id": "*", "partial": false,
            "language": "*",
            "summary": [
              "text": "The group discussed the release checklist and open work.",
              "sources": [], "whole_meeting": true,
            ],
            "topics": [],
            "decisions": [
              [
                "text": "Deployment moves to Monday",
                "evidence_class": "explicit",
                "sources": [["kind": "segment", "id": decisionSegmentID]],
              ]
            ],
            "action_items": [], "next_steps": [], "open_questions": [],
            "risks": [],
          ],
        ] as [String: Any],
      ]))
  }

  func testFourHourMeetingRunsChunksThenSynthesis() async throws {
    let fixture = IntelligenceFixtures.fourHourMeeting()
    let reader = FakeEvidenceReader(fixture: fixture)
    let store = FakeAnalysisStore()
    let transport = FakeAnalysisTransport(fixture: fixture)
    let tailID = "f0000000-0000-4000-8000-fffffffffffe"
    let tailUUID = UUID(uuidString: tailID)!

    // ~300 KB of segment text: more than 16 chunk requests, then a bounded
    // reduce — two groups of ≤16 partials, then one final synthesis (the
    // scripted step is clamped and answers all three).
    let chunkCount = try AnalysisChunkPlanner.plan(
      segments: fixture.segments, notes: [], policy: AnalysisPolicy()
    ).chunks.count
    XCTAssertTrue((17...32).contains(chunkCount))
    transport.script(
      .chunk,
      (0..<chunkCount).map {
        chunkStep(index: $0, decisionSegmentID: $0 == chunkCount - 1 ? tailID : nil)
      })
    transport.script(.synthesis, [synthesisStep(decisionSegmentID: tailID)])

    var planChunkCount: Int?
    var requestsAtPlan: Int?
    store.recordPlanHook = { _, count in
      planChunkCount = count
      requestsAtPlan = transport.requests.count
    }

    final class LabelBox: @unchecked Sendable {
      private let lock = NSLock()
      private(set) var labels: [String] = []
      func add(_ label: String) { lock.withLock { labels.append(label) } }
    }
    let box = LabelBox()
    var analyzer = makeAnalyzer(reader: reader, store: store, transport: transport)
    analyzer.progress = { _, progress in
      guard let progress else { return }
      box.add(progress.label)
    }

    let run = try await analyzer.run(meetingID: fixture.id, trigger: .automatic)
    XCTAssertEqual(run.state, .succeeded)

    // chunk × n, then three synthesis requests — sequential by default.
    let requests = transport.requests
    XCTAssertEqual(requests.count, chunkCount + 3)
    for (index, request) in requests.enumerated() {
      if index < chunkCount {
        XCTAssertEqual(request.stage, .chunk)
        XCTAssertEqual(request.chunk, .init(index: index, count: chunkCount))
      } else {
        XCTAssertEqual(request.stage, .synthesis)
        XCTAssertNil(request.chunk)
      }
    }
    XCTAssertLessThanOrEqual(transport.maxInFlight, 1)

    // Every chunk request stays inside the segment-text budget and carries a
    // whole-segment window; the windows cover every ordinal, tail included.
    var covered: [UUID] = []
    for request in requests.prefix(chunkCount) {
      let window = try XCTUnwrap(request.segments)
      let bytes = window.reduce(0) { $0 + $1.text.utf8.count }
      XCTAssertLessThanOrEqual(bytes, AnalysisPolicy().chunkBudgetBytes)
      XCTAssertFalse(window.isEmpty)
      covered += window.map(\.id)
    }
    XCTAssertEqual(covered, fixture.segments.map(\.id))
    // The last request is the second reduce level: two group outputs in.
    XCTAssertEqual(requests.last?.partials?.count, 2)
    XCTAssertLessThanOrEqual(requests.last?.partials?.count ?? 0, 16)

    // chunk_count was fixed before the first request; request_count tracked
    // completion.
    XCTAssertEqual(planChunkCount, chunkCount)
    XCTAssertEqual(requestsAtPlan, 0)
    XCTAssertEqual(run.chunkCount, chunkCount)
    XCTAssertEqual(run.requestCount, chunkCount + 3)

    // Staged progress labels.
    XCTAssertTrue(box.labels.contains("Analyzing part 3 of \(chunkCount)"))
    XCTAssertTrue(box.labels.contains("Combining"))

    // The final decision cites the original tail segment — no chunk or
    // request identifier appears anywhere in stored sources.
    let stored = try await store.readModel(meetingID: fixture.id)
    let model = try XCTUnwrap(stored)
    let decisions = model.items.filter { $0.kind == .decision }
    XCTAssertEqual(decisions.count, 1)
    XCTAssertEqual(decisions.first?.text, "Deployment moves to Monday")
    XCTAssertEqual(decisions.first?.sources, [.segment(tailUUID)])
    let knownIDs = Set(fixture.segments.map(\.id))
    for item in model.items {
      for source in item.sources {
        guard case .segment(let id) = source else { continue }
        XCTAssertTrue(knownIDs.contains(id))
      }
    }

    // Windows were built through the paged reader, never a whole-meeting
    // slice: at least one page call per chunk beyond the initial snapshot.
    XCTAssertGreaterThanOrEqual(reader.pageRequests.count, chunkCount + 1)
    XCTAssertTrue(reader.pageRequests.allSatisfy { $0.limit <= 200 })
  }

  /// A partial is never adopted: an invented name in a chunk summary does
  /// not fail the run — the final result carries the literal rules.
  func testInventedLiteralInPartialDoesNotFailRun() async throws {
    let fixture = IntelligenceFixtures.fourHourMeeting()
    let store = FakeAnalysisStore()
    let transport = FakeAnalysisTransport(fixture: fixture)
    let tailID = "f0000000-0000-4000-8000-fffffffffffe"
    transport.script(
      .chunk,
      [
        chunkStep(index: 0, decisionSegmentID: nil, summary: "The group met Zyxworth today."),
        chunkStep(index: 1, decisionSegmentID: tailID),
      ])
    transport.script(.synthesis, [synthesisStep(decisionSegmentID: tailID)])
    let analyzer = makeAnalyzer(
      reader: FakeEvidenceReader(fixture: fixture), store: store, transport: transport)

    let run = try await analyzer.run(meetingID: fixture.id, trigger: .manual)
    XCTAssertEqual(run.state, .succeeded)
  }

  func testChunkResultFailingSourceValidationFailsRun() async throws {
    let fixture = IntelligenceFixtures.fourHourMeeting()
    let reader = FakeEvidenceReader(fixture: fixture)
    let store = FakeAnalysisStore()
    let transport = FakeAnalysisTransport(fixture: fixture)

    // Chunk 0 cites a segment that does not exist in the evidence.
    transport.script(
      .chunk,
      [chunkStep(index: 0, decisionSegmentID: "eeeeeeee-0000-4000-8000-000000000000")])
    transport.script(
      .synthesis, [synthesisStep(decisionSegmentID: "f0000000-0000-4000-8000-fffffffffffe")])

    let analyzer = makeAnalyzer(reader: reader, store: store, transport: transport)
    let run = try await analyzer.run(meetingID: fixture.id, trigger: .automatic)
    XCTAssertEqual(run.state, .failed)
    XCTAssertEqual(run.failureCategory, .sourceValidation)
    XCTAssertEqual(transport.requests.count, 1)
    let storedModel = try await store.readModel(meetingID: fixture.id)
    XCTAssertNil(storedModel?.summary)
  }

  /// A chunked run takes minutes; evidence that changes after the first
  /// chunk stops the run before the next chunk request.
  func testEvidenceChangeBetweenChunksStopsBeforeTheNextChunk() async throws {
    let fixture = IntelligenceFixtures.fourHourMeeting()
    let reader = FakeEvidenceReader(fixture: fixture)
    let store = FakeAnalysisStore()
    let transport = FakeAnalysisTransport(fixture: fixture)
    let chunkCount = try AnalysisChunkPlanner.plan(
      segments: fixture.segments, notes: [], policy: AnalysisPolicy()
    ).chunks.count
    var steps = (0..<chunkCount).map { chunkStep(index: $0, decisionSegmentID: nil) }
    guard case .lines(let first) = steps[0] else { return XCTFail("lines expected") }
    let gate = PreparationGate()
    steps[0] = .holdBeforeCompletion(gate, lines: first)
    transport.script(.chunk, steps)
    let analyzer = makeAnalyzer(reader: reader, store: store, transport: transport)

    let running = Task { try await analyzer.run(meetingID: fixture.id, trigger: .manual) }
    await gate.waitUntilStarted()
    reader.noteRows.append(
      NoteParagraph(ordinal: 99, text: "added mid-run", hash: String(repeating: "d", count: 64)))
    await gate.open()
    let run = try await running.value
    XCTAssertEqual(run.state, .failed)
    XCTAssertEqual(run.failureDetail, "evidence_changed")
    XCTAssertEqual(transport.requests.count, 1, "no second chunk on outdated evidence")
  }

  /// A retry after a failed synthesis reuses the chunk results that already
  /// passed: only the synthesis is requested again.
  func testRetryAfterFailedSynthesisReusesChunks() async throws {
    let fixture = IntelligenceFixtures.fourHourMeeting()
    let store = FakeAnalysisStore()
    let transport = FakeAnalysisTransport(fixture: fixture)
    let tailID = "f0000000-0000-4000-8000-fffffffffffe"
    let chunkCount = try AnalysisChunkPlanner.plan(
      segments: fixture.segments, notes: [], policy: AnalysisPolicy()
    ).chunks.count
    transport.script(
      .chunk,
      (0..<chunkCount).map {
        chunkStep(index: $0, decisionSegmentID: $0 == chunkCount - 1 ? tailID : nil)
      })
    let invalid: [String: Any] = [
      "schema_version": 1, "type": "error", "request_id": "*", "code": "output_invalid",
    ]
    transport.script(
      .synthesis,
      [.lines(.init(value: [invalid]))] + [synthesisStep(decisionSegmentID: tailID)])
    let analyzer = makeAnalyzer(
      reader: FakeEvidenceReader(fixture: fixture), store: store, transport: transport)

    let failed = try await analyzer.run(meetingID: fixture.id, trigger: .manual)
    XCTAssertEqual(failed.state, .failed)
    let firstCount = transport.requests.count
    XCTAssertEqual(firstCount, chunkCount + 1)

    let retried = try await analyzer.run(meetingID: fixture.id, trigger: .retry)
    XCTAssertEqual(retried.state, .succeeded)
    let retryRequests = transport.requests.dropFirst(firstCount)
    XCTAssertFalse(retryRequests.isEmpty)
    XCTAssertTrue(retryRequests.allSatisfy { $0.stage == .synthesis })
  }

  /// A user-started run while the model is not loaded is refused before
  /// admission: no failed row, one message.
  func testManualRunRefusedWhileBackendNotReady() async throws {
    let fixture = try IntelligenceFixtures.meeting("deployment")
    let store = FakeAnalysisStore()
    let transport = FakeAnalysisTransport(fixture: fixture)
    transport.healthResult = .success(
      AnalysisHealth(
        schemaVersion: 1, service: AnalysisHealth.serviceName,
        protocolVersions: [1], serverName: "flowd", serverVersion: "0.3.0",
        backend: .init(
          state: "unavailable", kind: "openai-compatible", model: "test-model",
          jsonSchema: false),
        promptVersions: ["full": 1, "chunk": 1, "synthesis": 1],
        resultSchemaVersion: 1, limits: nil, caps: nil))
    let analyzer = makeAnalyzer(
      reader: FakeEvidenceReader(fixture: fixture), store: store, transport: transport)

    do {
      _ = try await analyzer.admit(meetingID: fixture.id, trigger: .manual)
      XCTFail("admitted against a stopped backend")
    } catch let failure as AnalysisFailure {
      XCTAssertEqual(failure.category, .backendUnavailable)
    }
    let latest = try await store.latestRun(meetingID: fixture.id)
    XCTAssertNil(latest)
    XCTAssertTrue(transport.requests.isEmpty)
  }

  // MARK: - T091 — preemption retries (US10)

  /// Contract step 6: a `preempted` error retries the same stage after
  /// 2 s × attempt. Two preemptions then a success completes the run;
  /// `preemption_count` counts the interrupted attempts.
  func testPreemptedTwiceRetriesThenSucceeds() async throws {
    let fixture = try IntelligenceFixtures.meeting("deployment")
    let reader = FakeEvidenceReader(fixture: fixture)
    let store = FakeAnalysisStore()
    let transport = FakeAnalysisTransport(fixture: fixture)
    let valid = try IntelligenceFixtures.response("deployment-valid")[.full]![0]
    let preempted: [String: Any] = [
      "schema_version": 1, "type": "error", "request_id": "*", "code": "preempted",
    ]
    transport.script(
      .full,
      [
        .lines(.init(value: [preempted])),
        .lines(.init(value: [preempted])),
        .lines(.init(value: valid)),
      ])
    let clock = FakeMeetingClock()
    let analyzer = makeAnalyzer(
      reader: reader, store: store, transport: transport, clock: clock)

    let task = Task {
      try await analyzer.run(meetingID: fixture.id, trigger: .manual)
    }
    // Sleeper 1 is the run deadline; each preemption parks one retry sleep.
    await clock.waitForSleepers(2)
    await clock.advance(by: .seconds(2))
    await clock.waitForSleepers(3)
    await clock.advance(by: .seconds(4))
    let run = try await task.value

    XCTAssertEqual(run.state, .succeeded)
    XCTAssertEqual(run.preemptionCount, 2)
    XCTAssertEqual(transport.requests.count, 3)
    // Same stage, same shape on every attempt.
    XCTAssertTrue(transport.requests.allSatisfy { $0.stage == .full })
  }

  /// The fourth `preempted` answer ends the run `backend_busy` — the retry
  /// budget is three. Every interrupted attempt lands on the counters.
  func testPreemptedFourTimesFailsBackendBusy() async throws {
    let fixture = try IntelligenceFixtures.meeting("deployment")
    let reader = FakeEvidenceReader(fixture: fixture)
    let store = FakeAnalysisStore()
    let transport = FakeAnalysisTransport(fixture: fixture)
    let preempted: [String: Any] = [
      "schema_version": 1, "type": "error", "request_id": "*", "code": "preempted",
    ]
    transport.script(
      .full,
      (0..<4).map { _ in .lines(.init(value: [preempted])) })
    let clock = FakeMeetingClock()
    let analyzer = makeAnalyzer(
      reader: reader, store: store, transport: transport, clock: clock)

    let task = Task {
      try await analyzer.run(meetingID: fixture.id, trigger: .manual)
    }
    await clock.waitForSleepers(2)
    await clock.advance(by: .seconds(2))
    await clock.waitForSleepers(3)
    await clock.advance(by: .seconds(4))
    await clock.waitForSleepers(4)
    await clock.advance(by: .seconds(6))
    let run = try await task.value

    XCTAssertEqual(run.state, .failed)
    XCTAssertEqual(run.failureCategory, .backendBusy)
    XCTAssertEqual(run.preemptionCount, 4)
    XCTAssertEqual(run.requestCount, 4)
    XCTAssertEqual(run.retryCount, 3)
    XCTAssertEqual(transport.requests.count, 4)
    let storedModel = try await store.readModel(meetingID: fixture.id)
    XCTAssertNil(storedModel?.summary)
  }

  /// `server_busy` fails the run `server_unavailable` with the code preserved
  /// in `failure_detail` — the detail is the coordinator's requeue signal.
  func testServerBusyFailsServerUnavailableWithDetail() async throws {
    let fixture = try IntelligenceFixtures.meeting("deployment")
    let reader = FakeEvidenceReader(fixture: fixture)
    let store = FakeAnalysisStore()
    let transport = FakeAnalysisTransport(fixture: fixture)
    let busy: [String: Any] = [
      "schema_version": 1, "type": "error", "request_id": "*", "code": "server_busy",
    ]
    transport.script(.full, [.lines(.init(value: [busy]))])
    let analyzer = makeAnalyzer(reader: reader, store: store, transport: transport)

    let run = try await analyzer.run(meetingID: fixture.id, trigger: .manual)
    XCTAssertEqual(run.state, .failed)
    XCTAssertEqual(run.failureCategory, .serverUnavailable)
    XCTAssertEqual(run.failureDetail, "server_busy")
  }

  // MARK: T099 — language policy (US12)

  /// The three language fixtures send `language_policy.output` of `sk`, `en`
  /// and `mixed` with `preserve_terms: true`; the run row stores the
  /// `language_policy` the accepted result reported (the scripted response
  /// echoes the request's output value).
  func testLanguageFixturesSendPolicyAndStoreIt() async throws {
    for (name, expected) in [("slovak", AnalysisLanguage.sk), ("english", .en), ("mixed", .mixed)] {
      let fixture = try IntelligenceFixtures.meeting(name)
      let reader = FakeEvidenceReader(fixture: fixture)
      let store = FakeAnalysisStore()
      let transport = FakeAnalysisTransport()
      try transport.script(response: "language-valid")
      let analyzer = makeAnalyzer(reader: reader, store: store, transport: transport)

      let run = try await analyzer.run(meetingID: fixture.id, trigger: .manual)
      XCTAssertEqual(run.state, .succeeded, name)
      let request = try XCTUnwrap(transport.requests.first, name)
      XCTAssertEqual(request.meeting.languagePolicy.output, expected, name)
      XCTAssertTrue(request.meeting.languagePolicy.preserveTerms, name)
      XCTAssertEqual(run.languagePolicy, expected, name)
      let rows = try await store.runs(meetingID: fixture.id, limit: 1)
      XCTAssertEqual(rows.first?.languagePolicy, expected, name)
    }
  }

  func testMeetingAndFinalPassLanguagePrecedence() async throws {
    let fixture = try IntelligenceFixtures.meeting("english")
    // The language the final pass decoded in wins over the meeting's current choice.
    let cases: [(MeetingLanguage?, String?, AnalysisLanguage)] = [
      (.slovak, nil, .sk), (.english, "lang_sk_prompt_v1", .sk),
      (.slovak, "lang_en_prompt_v1", .en),
      (nil, "geometry+lang_sk_prompt_v1+normalizer", .sk),
      (nil, "geometry+lang_sk_prompt_v2+normalizer", .sk),
      (.automatic, "lang_sk_prompt_v1", .sk),
      (.slovak, "lang_auto_prompt_v1+speech_language_v3", .sk),
      (nil, "lang_auto_prompt_v1+speech_language_v3", .en),
      (nil, "not_lang_sk_prompt_v1", .en),
      (nil, nil, .en),
    ]
    for (language, pipeline, expected) in cases {
      let reader = FakeEvidenceReader(fixture: fixture)
      reader.meetingRow?.language = language
      reader.transcription?.pipelineVersion = pipeline
      let store = FakeAnalysisStore()
      let transport = FakeAnalysisTransport()
      try transport.script(response: "language-valid")
      let analyzer = makeAnalyzer(reader: reader, store: store, transport: transport)
      let run = try await analyzer.run(meetingID: fixture.id, trigger: .manual)
      XCTAssertEqual(run.state, .succeeded)
      XCTAssertEqual(transport.requests.first?.meeting.languagePolicy.output, expected)
      XCTAssertEqual(run.languagePolicy, expected)
    }
  }

  func testLanguageChangeMarksEvidenceStaleAndRejectsInFlightResult() async throws {
    let fixture = try IntelligenceFixtures.meeting("english")
    let reader = FakeEvidenceReader(fixture: fixture)
    let store = FakeAnalysisStore()
    let transport = FakeAnalysisTransport()
    try transport.script(response: "language-valid")
    let analyzer = makeAnalyzer(reader: reader, store: store, transport: transport)
    let original = try await analyzer.currentEvidenceVersion(meetingID: fixture.id)
    let admission = try await analyzer.admit(meetingID: fixture.id, trigger: .manual)
    reader.meetingRow?.language = .slovak
    let changed = try await analyzer.currentEvidenceVersion(meetingID: fixture.id)
    XCTAssertNotEqual(original, changed)
    let run = try await analyzer.execute(admission)
    XCTAssertEqual(run.failureCategory, .sourceValidation)
    XCTAssertEqual(store.adoptCalls, 0)
  }

  func testDeclaredLanguageMismatchPreservesAcceptedSummary() async throws {
    let fixture = try IntelligenceFixtures.meeting("deployment")
    let reader = FakeEvidenceReader(fixture: fixture)
    let store = FakeAnalysisStore()
    let transport = FakeAnalysisTransport(fixture: fixture)
    try transport.script(response: "deployment-valid")
    let analyzer = makeAnalyzer(reader: reader, store: store, transport: transport)
    let accepted = try await analyzer.run(meetingID: fixture.id, trigger: .manual)
    let before = try await store.readModel(meetingID: fixture.id)
    reader.meetingRow?.language = .slovak
    var lines = try XCTUnwrap(IntelligenceFixtures.response("deployment-valid")[.full]?.first)
    for index in lines.indices {
      guard var event = lines[index] as? [String: Any],
        var analysis = event["analysis"] as? [String: Any]
      else { continue }
      analysis["language"] = "en"
      event["analysis"] = analysis
      lines[index] = event
    }
    transport.script(.full, [.lines(.init(value: lines))])
    let rejected = try await analyzer.run(meetingID: fixture.id, trigger: .regenerate)
    XCTAssertEqual(accepted.state, .succeeded)
    XCTAssertEqual(rejected.failureCategory, .malformedResponse)
    XCTAssertEqual(store.adoptCalls, 1)
    let after = try await store.readModel(meetingID: fixture.id)
    XCTAssertEqual(after?.summary?.text, before?.summary?.text)
  }

  /// The server echoes the requested language, so the prose is checked: a long
  /// English summary for a Slovak request is rejected and nothing is adopted.
  func testConfidentlyWrongProseLanguageIsRejected() async throws {
    let fixture = try IntelligenceFixtures.meeting("english")
    let reader = FakeEvidenceReader(fixture: fixture)
    reader.meetingRow?.language = .slovak
    reader.transcription?.pipelineVersion = nil
    let store = FakeAnalysisStore()
    let transport = FakeAnalysisTransport()
    var lines = try XCTUnwrap(IntelligenceFixtures.response("language-valid")[.full]?.first)
    for index in lines.indices {
      guard var event = lines[index] as? [String: Any],
        var analysis = event["analysis"] as? [String: Any],
        var summary = analysis["summary"] as? [String: Any]
      else { continue }
      summary["text"] = Self.englishProse
      analysis["summary"] = summary
      event["analysis"] = analysis
      lines[index] = event
    }
    transport.script(.full, [.lines(.init(value: lines))])
    let analyzer = makeAnalyzer(reader: reader, store: store, transport: transport)
    let run = try await analyzer.run(meetingID: fixture.id, trigger: .manual)
    XCTAssertEqual(run.failureCategory, .malformedResponse)
    XCTAssertEqual(run.failureDetail, "prose_language")
    XCTAssertEqual(store.adoptCalls, 0)
  }

  private static let englishProse =
    "The team reviewed the release plan in detail and agreed that the deployment moves to "
    + "Monday. Martin will prepare the backup before the change window, and the customer "
    + "will be told about the new schedule by the end of the week. The open question about "
    + "the database migration stays with the platform group until they have measured it."

  /// Only substantial, confidently wrong prose fails; Slovak prose full of English
  /// jargon, short answers and names pass.
  func testProseLanguageCheckIsConservative() {
    func result(_ summary: String, topics: [String] = []) -> AnalysisResult {
      AnalysisResult(
        schemaVersion: 1, meetingID: UUID(), partial: false, language: .sk,
        summary: WireSummary(text: summary, sources: [], wholeMeeting: true),
        topics: topics.map {
          WireTopic(title: "Deployment", summary: $0, bullets: [], sources: [])
        },
        decisions: [], actionItems: [], nextSteps: [], openQuestions: [], risks: [])
    }
    let slovakJargon =
      "Tím prebral deployment na M6, backup cez Veeam a konfiguráciu SAPGUI. Martin pošle "
      + "ticket do Jiry a Peter overí, či CI/CD pipeline zvládne rollback. Na budúci týždeň "
      + "sa dohodli, že release pôjde v pondelok a zákazník dostane správu do piatku. Otvorená "
      + "otázka ostáva pri migrácii databázy, ktorú ešte treba zmerať na produkčných dátach."
    XCTAssertTrue(MeetingAnalyzer.proseMatches(result(slovakJargon), output: .sk))
    XCTAssertTrue(MeetingAnalyzer.proseMatches(result(slovakJargon), output: .mixed))
    XCTAssertFalse(MeetingAnalyzer.proseMatches(result(slovakJargon), output: .en))
    XCTAssertFalse(MeetingAnalyzer.proseMatches(result(Self.englishProse), output: .sk))
    XCTAssertFalse(
      MeetingAnalyzer.proseMatches(result("Stretnutie.", topics: [Self.englishProse]), output: .sk))
    XCTAssertTrue(MeetingAnalyzer.proseMatches(result(Self.englishProse), output: .en))
    XCTAssertTrue(
      MeetingAnalyzer.proseMatches(result("Deployment pipeline, Kubernetes, M6."), output: .sk))
  }

  func testFailureMetricsUseTerminalRun() async throws {
    let fixture = try IntelligenceFixtures.meeting("deployment")
    let store = FakeAnalysisStore()
    let transport = FakeAnalysisTransport(fixture: fixture)
    try transport.script(response: "mutated-digit-summary")
    let clock = FakeMeetingClock()
    transport.healthHook = { await clock.advance(by: .seconds(1)) }
    let capture = try RecorderCapture.make()
    defer { capture.cleanup() }
    let analyzer = makeAnalyzer(
      reader: FakeEvidenceReader(fixture: fixture), store: store,
      transport: transport, clock: clock, recorder: capture.recorder)

    let run = try await analyzer.run(meetingID: fixture.id, trigger: .manual)
    XCTAssertEqual(run.failureCategory, .protectedLiteral)
    XCTAssertGreaterThan(run.inputBytes, 0)
    let samples = try await capture.samples()
    func sample(_ metric: String) -> [String: Any]? {
      samples.first { $0["metric"] as? String == metric }
    }
    XCTAssertEqual(sample("analysisFailure")?["meetingKey"] as? String, "protected_literal")
    XCTAssertEqual(sample("analysisRequestCount")?["itemCount"] as? Int, run.requestCount)
    XCTAssertEqual(sample("analysisInputBytes")?["payloadBytes"] as? Int, run.inputBytes)
    XCTAssertEqual(sample("analysisChunkCount")?["itemCount"] as? Int, run.chunkCount)
    XCTAssertEqual(sample("analysisRunDuration")?["durationNanoseconds"] as? Int, 1_000_000_000)
  }

  func testCancellationMetricsUseTerminalRun() async throws {
    let fixture = try IntelligenceFixtures.meeting("deployment")
    let store = FakeAnalysisStore()
    let transport = FakeAnalysisTransport(fixture: fixture)
    transport.script(.full, [.failure(CancellationError())])
    let clock = FakeMeetingClock()
    transport.healthHook = { await clock.advance(by: .seconds(1)) }
    let capture = try RecorderCapture.make()
    defer { capture.cleanup() }
    let analyzer = makeAnalyzer(
      reader: FakeEvidenceReader(fixture: fixture), store: store,
      transport: transport, clock: clock, recorder: capture.recorder)
    do {
      _ = try await analyzer.run(meetingID: fixture.id, trigger: .manual)
      XCTFail("expected cancellation")
    } catch is CancellationError {}
    let samples = try await capture.samples()
    XCTAssertEqual(
      samples.first { $0["metric"] as? String == "analysisChunkCount" }?["itemCount"] as? Int, 0)
    XCTAssertEqual(
      samples.first { $0["metric"] as? String == "analysisRunDuration" }?["durationNanoseconds"]
        as? Int, 1_000_000_000)
    XCTAssertFalse(samples.contains { $0["metric"] as? String == "analysisFailure" })
  }

  private func makeAnalyzer(
    reader: FakeEvidenceReader,
    store: FakeAnalysisStore,
    transport: FakeAnalysisTransport,
    clock: MeetingClock = FakeMeetingClock(),
    recorder: ResourceRecorder? = nil
  ) -> MeetingAnalyzer {
    MeetingAnalyzer(
      evidence: reader, transport: transport, store: store, clock: clock,
      endpoint: {
        RewriteEndpoint(url: URL(string: "http://127.0.0.1:8765")!, origin: "test")
      },
      settings: { nil }, recorder: recorder)
  }
}

/// Returns an extra note paragraph on every `notes` call after the first, so a
/// run's pre-adoption re-check sees a different evidence version than the
/// admitted one.
private final class SecondReadMutatingReader: MeetingEvidenceReading, @unchecked Sendable {
  private let inner: FakeEvidenceReader
  private let mutatingFrom: Int
  private let lock = NSLock()
  private var calls = 0

  init(inner: FakeEvidenceReader, mutatingFrom: Int = 2) {
    self.inner = inner
    self.mutatingFrom = mutatingFrom
  }

  func notes(meetingID: UUID) async throws -> [NoteParagraph] {
    let n = lock.withLock { () -> Int in
      calls += 1
      return calls
    }
    let rows = try await inner.notes(meetingID: meetingID)
    guard n >= mutatingFrom else { return rows }
    return rows + [
      NoteParagraph(
        ordinal: 99, text: "added mid-run",
        hash: String(repeating: "f", count: 64))
    ]
  }

  func segmentPage(meetingID: UUID, passID: UUID, after ordinal: Int?, limit: Int)
    async throws -> [EvidenceSegment]
  {
    try await inner.segmentPage(meetingID: meetingID, passID: passID, after: ordinal, limit: limit)
  }

  func participants(meetingID: UUID) async throws -> [EvidenceParticipant] {
    try await inner.participants(meetingID: meetingID)
  }

  func possibleCandidateNames(meetingID: UUID) async throws -> Set<String> {
    try await inner.possibleCandidateNames(meetingID: meetingID)
  }

  func transcription(meetingID: UUID) async throws -> MeetingTranscription? {
    try await inner.transcription(meetingID: meetingID)
  }

  func meeting(id: UUID) async throws -> Meeting? {
    try await inner.meeting(id: id)
  }
}
