import XCTest

@testable import LocalFlow

/// T087 — `chunking_v1` plan shape (contract step 5).
final class AnalysisChunkPlannerTests: XCTestCase {

  private func segment(_ ordinal: Int, bytes: Int) -> EvidenceSegment {
    EvidenceSegment(
      id: UUID(), ordinal: ordinal, startMs: Int64(ordinal * 1000),
      endMs: Int64(ordinal * 1000 + 999), speaker: .unknown,
      text: String(repeating: "a", count: bytes))
  }

  private func segments(_ sizes: [Int]) -> [EvidenceSegment] {
    sizes.enumerated().map { segment($0.offset, bytes: $0.element) }
  }

  private func note(_ ordinal: Int, bytes: Int = 4) -> NoteParagraph {
    NoteParagraph(ordinal: ordinal, text: String(repeating: "n", count: bytes), hash: "")
  }

  private func health(inputBytes: Int) -> AnalysisHealth {
    AnalysisHealth(
      schemaVersion: 1, service: "localflow-analysis", protocolVersions: [1],
      serverName: nil, serverVersion: nil, backend: nil, promptVersions: [:],
      resultSchemaVersion: 1,
      limits: .init(
        inputBytes: inputBytes, outputBytes: 98_304, contextTokens: 8_192,
        concurrency: 1),
      caps: nil)
  }

  func testAtOrBelowBudgetPlansOneFullRequest() throws {
    for total in [1_000, 24_576] {
      let plan = try AnalysisChunkPlanner.plan(
        segments: self.segments([total / 2, total - total / 2]), notes: [],
        policy: AnalysisPolicy())
      XCTAssertTrue(plan.isFull)
      XCTAssertTrue(plan.chunks.isEmpty)
      XCTAssertEqual(plan.requestCount, 1)
      XCTAssertEqual(plan.notesStage, .full)
    }
  }

  func testSegmentNeverStraddlesAChunkBoundary() throws {
    // 6 × 10_000 bytes, budget 24_576 → [0,1], [2,3], [4,5].
    let input = self.segments([10_000, 10_000, 10_000, 10_000, 10_000, 10_000])
    let plan = try AnalysisChunkPlanner.plan(
      segments: input, notes: [], policy: AnalysisPolicy())
    XCTAssertEqual(plan.chunks.count, 3)
    var covered: [Int] = []
    for chunk in plan.chunks {
      XCTAssertLessThan(chunk.firstOrdinal, chunk.lastOrdinal)
      XCTAssertLessThanOrEqual(chunk.segmentBytes, 24_576)
      covered += Array(chunk.firstOrdinal..<chunk.lastOrdinal)
    }
    // Contiguous, whole-segment coverage — the tail is never dropped.
    XCTAssertEqual(covered, [0, 1, 2, 3, 4, 5])
  }

  func testEveryChunkIsWithinBudget() throws {
    let input = self.segments(
      [20_000, 4_000, 4_000, 4_000, 4_000, 8_000, 1_000, 1_000])
    let plan = try AnalysisChunkPlanner.plan(
      segments: input, notes: [], policy: AnalysisPolicy())
    XCTAssertFalse(plan.isFull)
    for chunk in plan.chunks where !chunk.oversized {
      XCTAssertLessThanOrEqual(chunk.segmentBytes, 24_576)
      let bytes = input[chunk.firstOrdinal..<chunk.lastOrdinal]
        .reduce(0) { $0 + $1.text.utf8.count }
      XCTAssertEqual(chunk.segmentBytes, bytes)
    }
  }

  func testOversizedSegmentStandsAloneAndIsFlagged() throws {
    let input = self.segments([5_000, 30_000, 5_000])
    let plan = try AnalysisChunkPlanner.plan(
      segments: input, notes: [], policy: AnalysisPolicy())
    XCTAssertEqual(plan.chunks.count, 3)
    XCTAssertEqual(plan.chunks[0].firstOrdinal, 0)
    XCTAssertEqual(plan.chunks[0].lastOrdinal, 1)
    XCTAssertFalse(plan.chunks[0].oversized)
    XCTAssertEqual(plan.chunks[1].firstOrdinal, 1)
    XCTAssertEqual(plan.chunks[1].lastOrdinal, 2)
    XCTAssertTrue(plan.chunks[1].oversized)
    XCTAssertEqual(plan.chunks[1].segmentBytes, 30_000)
    XCTAssertEqual(plan.chunks[2].firstOrdinal, 2)
    XCTAssertEqual(plan.chunks[2].lastOrdinal, 3)
    XCTAssertFalse(plan.chunks[2].oversized)
  }

  func testOversizedSegmentFirstStandsAlone() throws {
    let input = self.segments([30_000, 5_000])
    let plan = try AnalysisChunkPlanner.plan(
      segments: input, notes: [], policy: AnalysisPolicy())
    XCTAssertEqual(plan.chunks.count, 2)
    XCTAssertTrue(plan.chunks[0].oversized)
    XCTAssertEqual(plan.chunks[0].segmentBytes, 30_000)
    XCTAssertEqual(plan.chunks[1].segmentBytes, 5_000)
  }

  func testSmallerServerLimitLowersTheBudget() throws {
    let policy = AnalysisPolicy().lowered(by: health(inputBytes: 4_000))
    XCTAssertEqual(policy.chunkBudgetBytes, 4_000)
    let plan = try AnalysisChunkPlanner.plan(
      segments: self.segments([1_500, 1_500, 1_500, 1_500]), notes: [],
      policy: policy)
    XCTAssertEqual(plan.chunks.count, 2)
    XCTAssertEqual(plan.chunks.map(\.segmentBytes), [3_000, 3_000])
  }

  func testLargerServerLimitNeverRaisesTheBudget() throws {
    let policy = AnalysisPolicy().lowered(by: health(inputBytes: 1_000_000))
    XCTAssertEqual(policy.chunkBudgetBytes, 24_576)
    XCTAssertEqual(policy.fullBudgetBytes, 24_576)
  }

  func testSixtyFiveChunksFailTooLong() {
    var policy = AnalysisPolicy()
    policy.fullBudgetBytes = 100
    policy.chunkBudgetBytes = 100
    XCTAssertThrowsError(
      try AnalysisChunkPlanner.plan(
        segments: self.segments(Array(repeating: 100, count: 65)), notes: [],
        policy: policy)
    ) { error in
      XCTAssertEqual(
        (error as? AnalysisFailure)?.category, .tooLong)
    }
  }

  func testSeventeenPartialsProduceTwoGroupsThenOne() throws {
    let plan = try AnalysisChunkPlanner.plan(
      segments: self.segments(Array(repeating: 13_000, count: 17)), notes: [],
      policy: AnalysisPolicy())
    XCTAssertEqual(plan.chunks.count, 17)
    XCTAssertEqual(plan.synthesisCounts, [2, 1])
    XCTAssertEqual(plan.requestCount, 17 + 3)
  }

  func testSixtyFourPartialsProduceFourGroupsThenOne() throws {
    let plan = try AnalysisChunkPlanner.plan(
      segments: self.segments(Array(repeating: 13_000, count: 64)), notes: [],
      policy: AnalysisPolicy())
    XCTAssertEqual(plan.chunks.count, 64)
    XCTAssertEqual(plan.synthesisCounts, [4, 1])
    XCTAssertEqual(plan.requestCount, 64 + 5)
  }

  func testReduceDepthBeyondTwoFails() {
    var policy = AnalysisPolicy()
    policy.partialsPerSynthesis = 2
    // 64 partials grouped by 2 needs six levels — over `reduceDepth`.
    XCTAssertThrowsError(
      try AnalysisChunkPlanner.plan(
        segments: self.segments(Array(repeating: 13_000, count: 64)), notes: [],
        policy: policy)
    ) { error in
      XCTAssertEqual((error as? AnalysisFailure)?.category, .tooLong)
      XCTAssertEqual((error as? AnalysisFailure)?.detail, "reduce_too_deep")
    }
  }

  func testNotesRideOnlyFullOrFinalSynthesis() throws {
    let notes = [note(1)]
    let full = try AnalysisChunkPlanner.plan(
      segments: self.segments([100]), notes: notes, policy: AnalysisPolicy())
    XCTAssertEqual(full.notesStage, .full)
    let staged = try AnalysisChunkPlanner.plan(
      segments: self.segments(Array(repeating: 13_000, count: 4)), notes: notes,
      policy: AnalysisPolicy())
    XCTAssertEqual(staged.notesStage, .synthesis)
  }

  func testTooManyNoteParagraphsFailNamingNotes() {
    let notes = (1...257).map { note($0) }
    XCTAssertThrowsError(
      try AnalysisChunkPlanner.plan(
        segments: self.segments([100]), notes: notes, policy: AnalysisPolicy())
    ) { error in
      XCTAssertEqual((error as? AnalysisFailure)?.category, .tooLong)
      XCTAssertEqual((error as? AnalysisFailure)?.detail, "notes_too_large")
    }
  }

  func testOversizedNoteParagraphFailsNamingNotes() {
    let notes = [note(1, bytes: 8_193)]
    XCTAssertThrowsError(
      try AnalysisChunkPlanner.plan(
        segments: self.segments([100]), notes: notes, policy: AnalysisPolicy())
    ) { error in
      XCTAssertEqual((error as? AnalysisFailure)?.category, .tooLong)
      XCTAssertEqual((error as? AnalysisFailure)?.detail, "notes_too_large")
    }
  }
}
