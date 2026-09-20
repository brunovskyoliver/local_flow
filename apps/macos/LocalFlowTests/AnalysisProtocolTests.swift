import Foundation
import XCTest

@testable import LocalFlow

/// Wire-contract tests for the analysis protocol types
/// (`specs/011-meeting-intelligence/contracts/analysis-protocol.md`).
final class AnalysisProtocolTests: XCTestCase {

  // MARK: Request encoding

  func testRequestEncodesExactKeySet() throws {
    let meetingID = UUID(), runID = UUID(), requestID = UUID(), speakerID = UUID()
    let request = AnalysisRequest(
      requestID: requestID, runID: runID, stage: .full, chunk: nil,
      meeting: AnalysisRequest.Meeting(
        id: meetingID, title: "Sync", startedAt: "2026-09-20T09:00:00+02:00",
        durationMs: 60_000, timeZone: "Europe/Bratislava",
        languagePolicy: .init(output: .en, preserveTerms: true)),
      participants: [
        .init(
          speakerID: speakerID, certainty: .localName, origin: "none",
          knownSpeakerID: nil, name: "Martin")
      ],
      segments: [
        .init(id: UUID(), startMs: 0, endMs: 1_000, speakerID: nil, text: "hello")
      ],
      notes: [.init(ordinal: 1, text: "note")], partials: nil)
    let data = try JSONEncoder().encode(request)
    let object = try XCTUnwrap(
      JSONSerialization.jsonObject(with: data) as? [String: Any])
    XCTAssertEqual(
      Set(object.keys), [
        "schema_version", "request_id", "run_id", "priority", "stage", "meeting",
        "participants", "segments", "notes",
      ])
    XCTAssertEqual(object["schema_version"] as? Int, 1)
    XCTAssertEqual(object["priority"] as? String, "background")
    XCTAssertEqual(object["stage"] as? String, "full")
    let meeting = try XCTUnwrap(object["meeting"] as? [String: Any])
    let policy = try XCTUnwrap(meeting["language_policy"] as? [String: Any])
    XCTAssertEqual(policy["output"] as? String, "en")
    XCTAssertEqual(policy["preserve_terms"] as? Bool, true)
    let participant = try XCTUnwrap(
      (object["participants"] as? [[String: Any]])?.first)
    XCTAssertEqual(participant["speaker_id"] as? String, speakerID.uuidString)
    XCTAssertEqual(participant["certainty"] as? String, "local_name")
    XCTAssertNil(participant["known_speaker_id"])
    let segment = try XCTUnwrap((object["segments"] as? [[String: Any]])?.first)
    XCTAssertTrue(segment.keys.contains("speaker_id"))
    XCTAssertTrue(segment["speaker_id"] is NSNull)
    let note = try XCTUnwrap((object["notes"] as? [[String: Any]])?.first)
    XCTAssertEqual(note["id"] as? String, "note:1")
  }

  func testChunkRequestCarriesIndex() throws {
    let request = AnalysisRequest(
      requestID: UUID(), runID: UUID(), stage: .chunk,
      chunk: .init(index: 3, count: 9),
      meeting: AnalysisRequest.Meeting(
        id: UUID(), title: "t", startedAt: "2026-09-20T09:00:00Z", durationMs: 0,
        timeZone: "UTC", languagePolicy: .init(output: .en, preserveTerms: true)),
      participants: [], segments: [], notes: nil, partials: nil)
    let object = try XCTUnwrap(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(request))
        as? [String: Any])
    let chunk = try XCTUnwrap(object["chunk"] as? [String: Any])
    XCTAssertEqual(chunk["index"] as? Int, 3)
    XCTAssertEqual(chunk["count"] as? Int, 9)
  }

  // MARK: Event decoding

  private func line(_ json: [String: Any]) throws -> Data {
    try JSONSerialization.data(withJSONObject: json)
  }

  func testDecodeAccepted() throws {
    let event = try AnalysisEvent.decode(
      line: line([
        "schema_version": 1, "type": "accepted", "request_id": "abc",
        "server": ["name": "flowd", "version": "0.3.0"],
      ]))
    guard case .accepted(let id, let server) = event else {
      return XCTFail("expected accepted")
    }
    XCTAssertEqual(id, "abc")
    XCTAssertEqual(server?.name, "flowd")
  }

  func testDecodeResult() throws {
    let meetingID = UUID().uuidString
    let segmentID = UUID().uuidString
    let event = try AnalysisEvent.decode(
      line: line([
        "schema_version": 1, "type": "result", "request_id": "r", "stage": "full",
        "backend": ["kind": "openai-compatible", "model": "m"],
        "prompt_version": 1, "pipeline_version": "analysis_v1",
        "analysis": [
          "schema_version": 1, "meeting_id": meetingID, "partial": false,
          "language": "en",
          "summary": ["text": "s", "sources": [], "whole_meeting": true],
          "topics": [],
          "decisions": [
            [
              "text": "Ship Monday", "evidence_class": "explicit",
              "sources": [["kind": "segment", "id": segmentID]],
            ]
          ],
          "action_items": [
            [
              "text": "Do it",
              "owner": ["kind": "participant", "speaker_id": segmentID],
              "ownership_state": "explicit",
              "due": ["state": "absent"],
              "sources": [["kind": "segment", "id": segmentID]],
            ]
          ],
          "next_steps": [], "open_questions": [], "risks": [],
        ],
      ]))
    guard case .result(let payload) = event else { return XCTFail("expected result") }
    XCTAssertEqual(payload.analysis.meetingID.uuidString, meetingID)
    XCTAssertEqual(payload.analysis.decisions.first?.text, "Ship Monday")
    XCTAssertEqual(payload.analysis.actionItems.first?.ownershipState, .explicit)
    XCTAssertEqual(payload.backend?.model, "m")
  }

  func testDecodeError() throws {
    let event = try AnalysisEvent.decode(
      line: line([
        "schema_version": 1, "type": "error", "request_id": "r",
        "code": "backend_timeout",
      ]))
    guard case .error(_, let code) = event else { return XCTFail("expected error") }
    XCTAssertEqual(code, "backend_timeout")
  }

  func testRejectsUnsupportedSchemaVersion() {
    XCTAssertThrowsError(
      try AnalysisEvent.decode(line: line(["schema_version": 2, "type": "accepted"]))
    ) { XCTAssertEqual(($0 as? AnalysisFailure)?.category, .unsupportedVersion) }
  }

  func testRejectsUnknownEventType() {
    XCTAssertThrowsError(
      try AnalysisEvent.decode(line: line(["schema_version": 1, "type": "nope"]))
    ) { XCTAssertEqual(($0 as? AnalysisFailure)?.category, .malformedResponse) }
  }

  func testRejectsUnknownFieldInAnalysis() {
    XCTAssertThrowsError(
      try decodeAnalysis(["unexpected": 1])
    ) { XCTAssertEqual(($0 as? AnalysisFailure)?.category, .malformedResponse) }
  }

  func testRejectsOverCapDecisions() {
    var analysis = minimalAnalysis()
    analysis["decisions"] = (0..<41).map { _ in
      ["text": "x", "sources": [["kind": "segment", "id": UUID().uuidString]]]
    }
    XCTAssertThrowsError(try decodeAnalysis(analysis)) {
      XCTAssertEqual(($0 as? AnalysisFailure)?.category, .overCap)
    }
  }

  func testPartialCapsAreHalf() {
    var analysis = minimalAnalysis()
    analysis["partial"] = true
    analysis["decisions"] = (0..<21).map { _ in
      ["text": "x", "sources": [["kind": "segment", "id": UUID().uuidString]]]
    }
    XCTAssertThrowsError(try decodeAnalysis(analysis, partial: true)) {
      XCTAssertEqual(($0 as? AnalysisFailure)?.category, .overCap)
    }
  }

  func testRejectsDuplicateSources() {
    var analysis = minimalAnalysis()
    let id = UUID().uuidString
    analysis["decisions"] = [
      [
        "text": "x",
        "sources": [
          ["kind": "segment", "id": id], ["kind": "segment", "id": id],
        ],
      ]
    ]
    XCTAssertThrowsError(try decodeAnalysis(analysis)) {
      XCTAssertEqual(($0 as? AnalysisFailure)?.category, .malformedResponse)
    }
  }

  func testRejectsItemWithoutSources() {
    var analysis = minimalAnalysis()
    analysis["decisions"] = [["text": "x", "sources": []]]
    XCTAssertThrowsError(try decodeAnalysis(analysis)) {
      XCTAssertEqual(($0 as? AnalysisFailure)?.category, .malformedResponse)
    }
  }

  func testRejectsInvalidDueDate() {
    var analysis = minimalAnalysis()
    analysis["action_items"] = [
      [
        "text": "x", "owner": ["kind": "none"], "ownership_state": "unresolved",
        "due": [
          "state": "explicit_absolute", "date": "25-09-2026", "original": "Friday",
          "source": ["kind": "segment", "id": UUID().uuidString],
        ],
        "sources": [["kind": "segment", "id": UUID().uuidString]],
      ]
    ]
    XCTAssertThrowsError(try decodeAnalysis(analysis)) {
      XCTAssertEqual(($0 as? AnalysisFailure)?.category, .malformedResponse)
    }
  }

  func testRejectsAbsentDueWithDate() {
    var analysis = minimalAnalysis()
    analysis["action_items"] = [
      [
        "text": "x", "owner": ["kind": "none"], "ownership_state": "unresolved",
        "due": ["state": "absent", "date": "2026-09-25"],
        "sources": [["kind": "segment", "id": UUID().uuidString]],
      ]
    ]
    XCTAssertThrowsError(try decodeAnalysis(analysis)) {
      XCTAssertEqual(($0 as? AnalysisFailure)?.category, .malformedResponse)
    }
  }

  func testRejectsParticipantOwnerWithName() {
    var analysis = minimalAnalysis()
    analysis["action_items"] = [
      [
        "text": "x",
        "owner": [
          "kind": "participant", "speaker_id": UUID().uuidString, "name": "Oliver",
        ],
        "ownership_state": "explicit",
        "due": ["state": "absent"],
        "sources": [["kind": "segment", "id": UUID().uuidString]],
      ]
    ]
    XCTAssertThrowsError(try decodeAnalysis(analysis)) {
      XCTAssertEqual(($0 as? AnalysisFailure)?.category, .malformedResponse)
    }
  }

  func testRejectsOversizedLine() {
    let line = Data(repeating: 0x7b, count: AnalysisBounds.maxLineBytes + 1)
    XCTAssertThrowsError(try AnalysisEvent.decode(line: line)) {
      XCTAssertEqual(($0 as? AnalysisFailure)?.category, .oversizedResponse)
    }
  }

  // MARK: Health

  func testHealthDecode() throws {
    let health = try AnalysisHealth.decode(
      line([
        "schema_version": 1, "service": "localflow-analysis",
        "protocol_versions": [1],
        "server": ["name": "flowd", "version": "0.3.0"],
        "backend": [
          "state": "ready", "kind": "openai-compatible", "model": "m",
          "json_schema": true,
        ],
        "prompt_versions": ["full": 1, "chunk": 1, "synthesis": 1],
        "result_schema_version": 1,
        "limits": [
          "input_bytes": 98_304, "output_bytes": 98_304, "context_tokens": 32_768,
          "concurrency": 1,
        ],
        "caps": [
          "sources_per_item": 10, "topics": 20, "decisions": 40,
          "action_items": 60, "next_steps": 40, "open_questions": 40, "risks": 40,
        ],
      ]))
    XCTAssertTrue(health.isAnalysisService)
    XCTAssertTrue(health.resultSchemaSupported)
    XCTAssertEqual(health.limits?.inputBytes, 98_304)
    XCTAssertEqual(health.caps?.actionItems, 60)
    XCTAssertEqual(health.backend?.state, "ready")
  }

  func testPolicyLowersToServerLimits() {
    let health = AnalysisHealth(
      schemaVersion: 1, service: "localflow-analysis", protocolVersions: [1],
      serverName: nil, serverVersion: nil, backend: nil, promptVersions: [:],
      resultSchemaVersion: 1,
      limits: .init(
        inputBytes: 16_000, outputBytes: 98_304, contextTokens: 8_192,
        concurrency: 1),
      caps: .init(
        sourcesPerItem: 4, topics: 10, decisions: 40, actionItems: 60,
        nextSteps: 40, openQuestions: 40, risks: 40))
    let policy = AnalysisPolicy().lowered(by: health)
    XCTAssertEqual(policy.chunkBudgetBytes, 16_000)
    XCTAssertEqual(policy.contextTokens, 8_192)
    XCTAssertEqual(policy.topicCap, 10)
    XCTAssertEqual(policy.sourcesPerItem, 4)
    XCTAssertEqual(policy.actionItemCap, 60)
  }

  // MARK: Helpers

  private func minimalAnalysis() -> [String: Any] {
    [
      "schema_version": 1, "meeting_id": UUID().uuidString, "partial": false,
      "language": "en",
      "summary": ["text": "s", "sources": [], "whole_meeting": true],
      "topics": [], "decisions": [], "action_items": [], "next_steps": [],
      "open_questions": [], "risks": [],
    ]
  }

  private func decodeAnalysis(
    _ analysis: [String: Any], partial: Bool = false
  ) throws -> AnalysisResult {
    try AnalysisResult.decode(analysis, partial: partial)
  }
}
