import Foundation
import GRDB
import XCTest
import os

@testable import LocalFlow
@testable import LocalFlowCore

/// T031: the summary of a merged meeting. The request is built from the merged rows, a
/// result that does not belong to them is refused, a valid one is stored.
@MainActor
final class MeetingSummarizerTests: XCTestCase {
  private var harness: MeetingHarness!

  override func setUp() async throws { harness = try MeetingHarness() }
  override func tearDown() async throws { harness = nil }

  /// A finished meeting with a final transcript as the merge leaves it.
  private func merged(_ texts: [String]) async throws -> (meeting: UUID, segments: [UUID]) {
    await harness.coordinator.start()
    let id = try XCTUnwrap(harness.coordinator.meetingID)
    harness.engine.feed(seconds: 2, into: harness.recorder)
    await harness.coordinator.stop()
    let pass = UUID()
    let segments = texts.map { _ in UUID() }
    try await harness.phone.history.database.write { db in
      for (index, text) in texts.enumerated() {
        try db.execute(
          sql: """
            INSERT INTO transcript_segments(id,meeting_id,pass_id,finality,ordinal,stretch_sequence,
              start_ms,end_ms,window_index,timing_basis,raw_text,assembled_text,normalized_text,
              engine,model_id,model_revision,pipeline_version,analysis_tracks,created_at)
            VALUES(?,?,?,'final',?,1,?,?,0,'window',?,?,?,'FluidAudio','m','r','p','mic',1)
            """,
          arguments: [
            segments[index].uuidString, id.uuidString, pass.uuidString, index, index * 2_000,
            index * 2_000 + 1_900, text, text, text,
          ])
      }
      try db.execute(
        sql: """
          UPDATE meeting_transcriptions SET state='final', pass_id=?, pass_kind='final',
            segment_count=?, covered_ms=?, finalized_at=1 WHERE meeting_id=?
          """, arguments: [pass.uuidString, texts.count, texts.count * 2_000, id.uuidString])
    }
    return (id, segments)
  }

  private func summarizer(_ transport: ScriptedAnalysisTransport, endpoint: Bool = true)
    -> MeetingSummarizer
  {
    let database = harness.phone.history.database
    let origin = URL(string: "https://flow.example")!
    return MeetingSummarizer(
      transcripts: TranscriptStore(database: database), meetings: harness.store,
      store: AnalysisStore(database: database), transport: transport,
      endpoint: {
        guard endpoint else { return nil }
        var value = RewriteEndpoint(url: origin, origin: origin.absoluteString)
        value.viaRemoteChannel = true
        return value
      })
  }

  private func result(_ meeting: UUID, source: UUID, text: String) -> AnalysisResult {
    AnalysisResult(
      schemaVersion: 1, meetingID: meeting, partial: false, language: .en,
      summary: WireSummary(text: text, sources: [.segment(source)], wholeMeeting: true),
      topics: [
        WireTopic(
          title: "Release", summary: "The release ships on Friday.", bullets: [],
          sources: [.segment(source)])
      ],
      decisions: [], actionItems: [], nextSteps: [], openQuestions: [], risks: [])
  }

  private let texts = [
    "We agreed to ship the release on Friday.", "Anna will write the release notes.",
  ]

  func testBuildsTheRequestFromTheMergedRows() async throws {
    let (id, segments) = try await merged(texts)
    let transport = ScriptedAnalysisTransport()
    transport.reply = { request in
      .result(self.result(request.meeting.id, source: segments[0], text: "The release ships."))
    }
    let outcome = await summarizer(transport).run(meetingID: id)
    XCTAssertEqual(outcome, .adopted)
    let request = try XCTUnwrap(transport.requests.first)
    XCTAssertEqual(transport.requests.count, 1)
    XCTAssertEqual(request.stage, .full)
    XCTAssertEqual(request.meeting.id, id)
    XCTAssertEqual(request.meeting.languagePolicy.output, .en)
    XCTAssertEqual(request.segments?.map(\.id), segments)
    XCTAssertEqual(request.segments?.map(\.text), texts)
    XCTAssertEqual(request.segments?.map(\.startMs), [0, 2_000])
    XCTAssertTrue(request.participants.isEmpty, "no speaker labels came back")
    XCTAssertNil(request.partials)
  }

  func testRejectsAResultForAnotherMeeting() async throws {
    let (id, segments) = try await merged(texts)
    let transport = ScriptedAnalysisTransport()
    transport.reply = { _ in .result(self.result(UUID(), source: segments[0], text: "Other.")) }
    let outcome = await summarizer(transport).run(meetingID: id)
    XCTAssertEqual(outcome, .failed(.meetingMismatch))
    let store = AnalysisStore(database: harness.phone.history.database)
    let stored = try await store.readModel(meetingID: id)
    XCTAssertNil(stored)
    let run = try await store.latestRun(meetingID: id)
    XCTAssertEqual(run?.state, .failed)
  }

  func testRejectsAResultCitingAnUnknownSegment() async throws {
    let (id, _) = try await merged(texts)
    let transport = ScriptedAnalysisTransport()
    transport.reply = { request in
      .result(self.result(request.meeting.id, source: UUID(), text: "The release ships."))
    }
    let outcome = await summarizer(transport).run(meetingID: id)
    guard case .failed = outcome else { return XCTFail("adopted \(outcome)") }
    let stored = try await AnalysisStore(database: harness.phone.history.database)
      .readModel(meetingID: id)
    XCTAssertNil(stored)
  }

  func testAdoptsAValidResult() async throws {
    let (id, segments) = try await merged(texts)
    let transport = ScriptedAnalysisTransport()
    transport.reply = { request in
      .result(self.result(request.meeting.id, source: segments[0], text: "The release ships."))
    }
    let outcome = await summarizer(transport).run(meetingID: id)
    XCTAssertEqual(outcome, .adopted)
    let stored = try await AnalysisStore(database: harness.phone.history.database)
      .readModel(meetingID: id)
    XCTAssertEqual(stored?.summary?.text, "The release ships.")
    XCTAssertEqual(stored?.topics.map(\.title), ["Release"])
    XCTAssertEqual(stored?.run.state, .succeeded)
  }

  func testAnUnreachableServerWaits() async throws {
    let (id, _) = try await merged(texts)
    let transport = ScriptedAnalysisTransport()
    transport.failure = AnalysisFailure(
      .serverUnreachable, detail: RemoteAnalysisTransport.waitingDetail)
    let outcome = await summarizer(transport).run(meetingID: id)
    XCTAssertEqual(outcome, .waiting)
    let noEndpoint = await summarizer(transport, endpoint: false).run(meetingID: id)
    XCTAssertEqual(noEndpoint, .waiting)
  }

  func testNoFinalTranscriptIsNotEligible() async throws {
    await harness.coordinator.start()
    let id = try XCTUnwrap(harness.coordinator.meetingID)
    harness.engine.feed(seconds: 1, into: harness.recorder)
    await harness.coordinator.stop()
    let transport = ScriptedAnalysisTransport()
    let outcome = await summarizer(transport).run(meetingID: id)
    XCTAssertEqual(outcome, .failed(.notEligible))
    XCTAssertTrue(transport.requests.isEmpty)
  }

  func testNoteParagraphsMatchTheMacSplit() {
    let notes = MeetingSummarizer.paragraphs("  First line\nsecond line \n\n\n Second  \n")
    XCTAssertEqual(notes.map(\.text), ["First line\nsecond line", "Second"])
    XCTAssertEqual(notes.map(\.ordinal), [1, 2])
    XCTAssertEqual(notes[0].hash, EvidenceVersion.hash(paragraph: "First line\nsecond line"))
  }
}

/// An analysis transport that answers each request with `reply`.
final class ScriptedAnalysisTransport: AnalysisTransporting, @unchecked Sendable {
  enum Reply {
    case result(AnalysisResult)
    case error(String)
  }

  private let lock = NSLock()
  private var seen: [AnalysisRequest] = []
  var reply: (AnalysisRequest) -> Reply = { _ in .error("backend_unavailable") }
  var failure: (any Error)?

  var requests: [AnalysisRequest] { lock.withLock { seen } }

  func analyze(request: AnalysisRequest, endpoint: RewriteEndpoint, timeout: Duration)
    -> AsyncThrowingStream<AnalysisTransportItem, Error>
  {
    lock.withLock { seen.append(request) }
    let answer = reply(request)
    let failure = failure
    return AsyncThrowingStream { continuation in
      if let failure { return continuation.finish(throwing: failure) }
      continuation.yield(.firstByte)
      switch answer {
      case .result(let analysis):
        continuation.yield(
          .event(
            .result(
              .init(
                requestID: request.requestID.uuidString, runID: request.runID.uuidString,
                stage: request.stage.rawValue, server: .init(name: "flowd", version: "test"),
                backend: .init(kind: "test", model: "test"), promptVersion: 1,
                pipelineVersion: nil, timing: nil, preemptions: nil, analysis: analysis))))
      case .error(let code):
        continuation.yield(.event(.error(requestID: nil, code: code)))
      }
      continuation.yield(.completed(requestBytes: 100, responseBytes: 100))
      continuation.finish()
    }
  }

  func health(endpoint: RewriteEndpoint) async throws -> AnalysisHealth {
    if let failure { throw failure }
    return AnalysisHealth(
      schemaVersion: 1, service: AnalysisHealth.serviceName, protocolVersions: [1],
      serverName: "flowd", serverVersion: "test",
      backend: .init(state: "ready", kind: "test", model: "test", jsonSchema: true),
      promptVersions: [:], resultSchemaVersion: 1, limits: nil, caps: nil)
  }

  func invalidate() {}
}
