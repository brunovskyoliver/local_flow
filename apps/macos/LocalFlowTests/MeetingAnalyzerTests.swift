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
    let reader = SecondReadMutatingReader(inner: inner)
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
    await clock.advance(by: .seconds(150))
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

  private func makeAnalyzer(
    reader: FakeEvidenceReader,
    store: FakeAnalysisStore,
    transport: FakeAnalysisTransport,
    clock: MeetingClock = FakeMeetingClock()
  ) -> MeetingAnalyzer {
    MeetingAnalyzer(
      evidence: reader, transport: transport, store: store, clock: clock,
      endpoint: {
        RewriteEndpoint(url: URL(string: "http://127.0.0.1:8765")!, origin: "test")
      },
      settings: { nil })
  }
}

/// Returns an extra note paragraph on every `notes` call after the first, so a
/// run's pre-adoption re-check sees a different evidence version than the
/// admitted one.
private final class SecondReadMutatingReader: MeetingEvidenceReading, @unchecked Sendable {
  private let inner: FakeEvidenceReader
  private let lock = NSLock()
  private var calls = 0

  init(inner: FakeEvidenceReader) { self.inner = inner }

  func notes(meetingID: UUID) async throws -> [NoteParagraph] {
    let n = lock.withLock { () -> Int in
      calls += 1
      return calls
    }
    let rows = try await inner.notes(meetingID: meetingID)
    guard n >= 2 else { return rows }
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
