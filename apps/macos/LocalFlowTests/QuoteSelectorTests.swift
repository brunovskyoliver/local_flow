import GRDB
import XCTest

@testable import LocalFlow

/// Feature 007 (T052): representative quotes per research R9.
final class QuoteSelectorTests: XCTestCase {
  private func candidate(_ ordinal: Int, third: Int, _ text: String) -> QuoteSelector.Candidate {
    .init(ordinal: ordinal, third: third, text: text)
  }

  func testBestCandidatePerThirdInTranscriptOrder() {
    let chosen = QuoteSelector.select([
      candidate(30, third: 2, "Closing remarks about the budget and the road ahead."),
      candidate(1, third: 0, "Opening remarks about the agenda for today."),
      candidate(2, third: 0, "A longer opening remark about the agenda that goes on further."),
      candidate(15, third: 1, "Middle of the meeting, discussing the numbers."),
    ])
    XCTAssertEqual(chosen.map(\.ordinal), [2, 15, 30], "the longest of each third, by ordinal")
  }

  func testFillsFromRemainingCandidatesByLengthWhenAThirdIsEmpty() {
    let chosen = QuoteSelector.select([
      candidate(1, third: 0, "Short one with four words"),
      candidate(2, third: 0, "This is the longest candidate of the whole first third by far."),
      candidate(3, third: 0, "A medium length candidate sits here."),
      candidate(20, third: 2, "One from the last third."),
    ])
    XCTAssertEqual(chosen.map(\.ordinal), [2, 3, 20])
  }

  func testCandidatesNeedAtLeastFourWords() {
    let chosen = QuoteSelector.select([
      candidate(1, third: 0, "OK."),
      candidate(2, third: 0, "Yes, sure, fine."),
      candidate(3, third: 1, "Right, that works for me."),
      candidate(4, third: 2, "No."),
    ])
    XCTAssertEqual(chosen.map(\.ordinal), [3], "three-word segments are not quotes")
  }

  func testFallsBackToTheLongestShortSegmentsSoASpeakerNeverShowsNone() {
    let chosen = QuoteSelector.select([
      candidate(5, third: 0, "OK."),
      candidate(2, third: 1, "Yes, sure."),
      candidate(9, third: 2, "Right."),
      candidate(7, third: 2, "Hmm."),
    ])
    XCTAssertEqual(chosen.map(\.ordinal), [2, 7, 9], "longest three, then transcript order")
  }

  func testTiesBreakByOrdinalAndOutputIsStable() {
    let candidates = [
      candidate(8, third: 0, "Same length words here."),
      candidate(3, third: 0, "Same length words here."),
      candidate(5, third: 1, "Same length words here."),
      candidate(4, third: 1, "Same length words here."),
      candidate(6, third: 2, "Same length words here."),
    ]
    let first = QuoteSelector.select(candidates)
    XCTAssertEqual(first.map(\.ordinal), [3, 4, 6])
    for _ in 0..<5 { XCTAssertEqual(QuoteSelector.select(candidates.shuffled()), first) }
    XCTAssertTrue(QuoteSelector.select([]).isEmpty)
  }
}

/// The candidate query behind `speakerSummaries` (T053): effective labels only.
final class QuoteCandidateQueryTests: XCTestCase {
  private var fixture: MeetingTestStore!
  private var store: SpeakerStore!
  private var transcripts: TranscriptStore!

  override func setUpWithError() throws {
    fixture = try MeetingTestStore.make()
    store = SpeakerStore(database: fixture.history.database)
    transcripts = TranscriptStore(database: fixture.history.database)
  }
  override func tearDown() { fixture.cleanup() }

  private static func text(_ ordinal: Int) -> String {
    switch ordinal % 3 {
    case 0: "OK."
    case 1: "Segment \(ordinal) has more than four words in it."
    default: "Segment \(ordinal) is the longer one of the pair with a few more words."
    }
  }

  func testAmbiguousSegmentsAndManualReassignmentsAreNotQuoted() async throws {
    let meeting = try await fixture.store.create(now: 1)
    try await fixture.store.transition(
      id: meeting.id, to: .preparing, now: 2, effects: [.insertTranscription(liveRequested: true)])
    let spans = (0..<9).map { (Int64($0) * 1_000, Int64($0) * 1_000 + 900) }
    let pass = try await DiarizationTestSupport.finalTranscript(
      transcripts, meetingID: meeting.id, segments: spans, stretchLengths: [9_000])
    let rows = try await transcripts.page(
      meetingID: meeting.id, finality: .final, after: nil, limit: 200)
    try await fixture.history.database.write { db in
      for row in rows {
        try db.execute(
          sql: "UPDATE transcript_segments SET normalized_text=? WHERE id=?",
          arguments: [Self.text(row.ordinal), row.id.uuidString])
      }
    }
    let run = try await store.admit(
      meetingID: meeting.id, transcriptPassID: pass, trigger: .manual,
      identity: DiarizationTestSupport.identity, expectedRevision: nil, now: 10)
    _ = try await store.start(runID: run.id, now: 10)
    let alice = SpeakerDraft(id: UUID(), clusterKey: 0, track: .system, reconciliation: .confident)
    let bob = SpeakerDraft(id: UUID(), clusterKey: 1, track: .system, reconciliation: .confident)
    try await store.appendWindow(
      runID: run.id, speakers: [alice, bob],
      turns: [
        .init(speakerID: alice.id, track: .system, startMs: 0, endMs: 6_000, quality: nil),
        .init(speakerID: bob.id, track: .system, startMs: 6_000, endMs: 9_000, quality: nil),
      ], audioMs: 9_000)
    // Alice gets ordinals 0–5 except 4 (ambiguous); Bob the rest.
    let assignments = rows.map { row -> AssignmentDraft in
      if row.ordinal == 4 {
        return .init(
          segmentID: row.id, kind: .ambiguous, speakerID: nil, topSpeakerID: alice.id,
          secondSpeakerID: bob.id, topCoverage: 0.5, secondCoverage: 0.5)
      }
      let speaker = row.ordinal < 6 ? alice.id : bob.id
      return .init(
        segmentID: row.id, kind: .speaker, speakerID: speaker, topSpeakerID: speaker,
        secondSpeakerID: nil, topCoverage: 1, secondCoverage: 0)
    }
    _ = try await store.complete(runID: run.id, assignments: assignments, now: 20)
    // Ordinal 5 (Alice's longest) is manually reassigned to Bob.
    let moved = rows.first { $0.ordinal == 5 }!
    try await fixture.history.database.write { db in
      try db.execute(
        sql: """
          UPDATE speaker_assignments SET manual_kind='speaker', manual_speaker_id=?, manual_at=30
          WHERE run_id=? AND segment_id=?
          """, arguments: [bob.id.uuidString, run.id.uuidString, moved.id.uuidString])
    }
    let summaries = try await store.speakerSummaries(meetingID: meeting.id)
    XCTAssertEqual(summaries.map(\.id), [alice.id, bob.id])
    XCTAssertEqual(
      summaries[0].quotes, [Self.text(1), Self.text(2)],
      "OK. rows are too short, 4 is ambiguous and 5 moved to Bob")
    XCTAssertEqual(summaries[1].quotes, [Self.text(5), Self.text(7), Self.text(8)])
    let again = try await store.speakerSummaries(meetingID: meeting.id)
    XCTAssertEqual(again, summaries, "reopening shows the same quotes")
  }
}
