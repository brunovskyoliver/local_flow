import XCTest

@testable import LocalFlow

@MainActor
final class TranscriptPagerTests: XCTestCase {
  func testLiveRingKeepsNewestTwoHundredAndRespectsScrollPosition() {
    let model = LiveTranscriptModel()
    let meeting = UUID()
    let pass = UUID()
    for ordinal in 0..<450 {
      let draft = TranscriptSegmentDraft(
        ordinal: ordinal, stretchSequence: 1, startMs: Int64(ordinal * 100),
        endMs: Int64(ordinal * 100 + 100), coveredMs: 45_000, windowIndex: ordinal,
        timingBasis: .window, rawText: "words", assembledText: "words", normalizedText: "Words",
        analysisTracks: .mic)
      model.append([
        TranscriptSegment(id: UUID(), meetingID: meeting, passID: pass, draft: draft, createdAt: 0)
      ])
      XCTAssertLessThanOrEqual(model.segments.count, 200)
    }
    XCTAssertEqual(model.segments.map(\.ordinal), Array(250..<450))
    XCTAssertTrue(model.autoFollow)
    model.setAtBottom(false)
    XCTAssertFalse(model.autoFollow)
    model.append([])
    XCTAssertFalse(model.autoFollow)
    model.setAtBottom(true)
    XCTAssertTrue(model.autoFollow)
    model.reset()
    XCTAssertTrue(model.segments.isEmpty)
    XCTAssertTrue(model.autoFollow)
  }
}

@MainActor
final class TranscriptPagerPagingTests: XCTestCase {
  private func makePager(count: Int, state: TranscriptState = .final) async -> (
    TranscriptPager, FakeTranscriptStore, UUID
  ) {
    let store = FakeTranscriptStore()
    let meeting = UUID()
    let pass = UUID()
    await store.seed(meeting)
    var row = await store.transcription(meetingID: meeting)!
    row.state = state
    row.passID = pass
    row.passKind = state == .final || state == .finalizing ? .final : .live
    await store.setRow(row)
    await store.seedSegments(
      meeting, passID: pass, finality: state == .final ? .final : .provisional, count: count)
    return (TranscriptPager(meetingID: meeting, store: store), store, meeting)
  }

  func testFirstPageIsOneQueryAndCountComesFromTheRow() async throws {
    let (pager, store, meeting) = await makePager(count: 10_000)
    XCTAssertEqual(TranscriptPager.pageSize, 200)
    XCTAssertEqual(TranscriptPager.maximumResidentPages, 2)
    // The row claims more than the table holds; the count follows the row.
    var row = await store.transcription(meetingID: meeting)!
    row.segmentCount = 12_345
    await store.setRow(row)
    await pager.loadFirst()
    let queries = await store.calls.filter { $0 == "page" }.count
    XCTAssertEqual(queries, 1)
    XCTAssertEqual(pager.segments.count, 200)
    XCTAssertEqual(pager.segments.map(\.ordinal), Array(0..<200))
    XCTAssertEqual(pager.count, 12_345)
    XCTAssertEqual(pager.residentCount, 200)
    XCTAssertEqual(pager.finality, .final)
  }

  func testPagingKeepsAtMostFourHundredResidentAndEvictsDeterministically() async throws {
    let (pager, _, _) = await makePager(count: 10_000)
    await pager.loadFirst()
    for _ in 0..<12 {
      await pager.loadNext()
      XCTAssertLessThanOrEqual(pager.residentCount, 400)
    }
    XCTAssertEqual(pager.segments.first?.ordinal, 2_200)
    XCTAssertEqual(pager.segments.last?.ordinal, 2_599)
    XCTAssertEqual(pager.evictedFirstOrdinals.prefix(3), [0, 200, 400], "farthest page first")
    await pager.loadPrevious()
    XCTAssertEqual(pager.segments.first?.ordinal, 2_000)
    XCTAssertEqual(pager.segments.last?.ordinal, 2_399)
    XCTAssertEqual(pager.evictedFirstOrdinals.last, 2_400, "the far page after scrolling back")
    XCTAssertEqual(pager.residentCount, 400)
    XCTAssertTrue(pager.hasPrevious)
    XCTAssertTrue(pager.hasNext)
    while pager.hasPrevious { await pager.loadPrevious() }
    XCTAssertEqual(pager.segments.first?.ordinal, 0)
    XCTAssertLessThanOrEqual(pager.residentCount, 400)
  }

  func testFinalizingReadsProvisionalThenFinalSwitchesAndReloads() async throws {
    let (pager, store, meeting) = await makePager(count: 5, state: .finalizing)
    await pager.loadFirst()
    XCTAssertEqual(pager.finality, .provisional)
    XCTAssertEqual(pager.segments.count, 5)
    // Completion: provisional rows are replaced by final ones.
    var row = await store.transcription(meetingID: meeting)!
    let finalPass = UUID()
    await store.discardPass(meetingID: meeting, passID: row.passID!)
    row.state = .final
    row.passID = finalPass
    await store.setRow(row)
    await store.seedSegments(meeting, passID: finalPass, finality: .final, count: 3)
    let status = TranscriptStatus(meetingID: meeting, state: .final)
    await pager.apply(status: status)
    XCTAssertEqual(pager.finality, .final)
    XCTAssertEqual(pager.segments.count, 3)
    XCTAssertTrue(pager.segments.allSatisfy { $0.finality == .final })
  }

  func testSelectionCopiesNormalizedTextJoinedByNewlines() async throws {
    let (pager, _, _) = await makePager(count: 4)
    await pager.loadFirst()
    XCTAssertEqual(pager.copyText(), "Seg 0\nSeg 1\nSeg 2\nSeg 3")
    pager.toggleSelection(pager.segments[2].id)
    pager.toggleSelection(pager.segments[0].id)
    XCTAssertEqual(pager.copyText(), "Seg 0\nSeg 2", "selection follows ordinal order")
    pager.toggleSelection(pager.segments[0].id)
    XCTAssertEqual(pager.copyText(), "Seg 2")
    pager.clearSelection()
    XCTAssertEqual(pager.copyText(), "Seg 0\nSeg 1\nSeg 2\nSeg 3")
  }
}
