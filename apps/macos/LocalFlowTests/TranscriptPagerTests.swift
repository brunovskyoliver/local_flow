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

/// Feature 007 (T027): labels arrive with their page and never mix two results.
@MainActor
final class TranscriptPagerLabelTests: XCTestCase {
  private var fixture: MeetingTestStore!
  private var transcripts: TranscriptStore!
  private var speakers: SpeakerStore!

  override func setUp() async throws {
    fixture = try MeetingTestStore.make()
    transcripts = TranscriptStore(database: fixture.history.database)
    speakers = SpeakerStore(database: fixture.history.database)
  }
  override func tearDown() async throws { fixture.cleanup() }

  private func meeting(segments count: Int) async throws -> (UUID, UUID) {
    let meeting = try await fixture.store.create(now: 1)
    try await fixture.store.transition(
      id: meeting.id, to: .preparing, now: 2, effects: [.insertTranscription(liveRequested: true)])
    let spans = (0..<count).map { (Int64($0) * 1_000, Int64($0) * 1_000 + 900) }
    let pass = try await DiarizationTestSupport.finalTranscript(
      transcripts, meetingID: meeting.id, segments: spans,
      stretchLengths: [Int64(count) * 1_000])
    return (meeting.id, pass)
  }

  /// Adopts a run whose one speaker (from `track`) covers every segment.
  @discardableResult
  private func accept(_ meetingID: UUID, pass: UUID, track: MeetingTrackKind, now: Int64)
    async throws -> UUID
  {
    let run = try await speakers.admit(
      meetingID: meetingID, transcriptPassID: pass, trigger: .manual,
      identity: DiarizationTestSupport.identity, expectedRevision: nil, now: now)
    _ = try await speakers.start(runID: run.id, now: now)
    let speaker = SpeakerDraft(id: UUID(), clusterKey: 0, track: track, reconciliation: .confident)
    try await speakers.appendWindow(
      runID: run.id, speakers: [speaker],
      turns: [.init(speakerID: speaker.id, track: track, startMs: 0, endMs: 600_000, quality: nil)],
      audioMs: 600_000)
    var assignments: [AssignmentDraft] = []
    var after: Int?
    while true {
      let page = try await transcripts.page(
        meetingID: meetingID, finality: .final, after: after, limit: 200)
      assignments += page.map {
        AssignmentDraft(
          segmentID: $0.id, kind: .speaker, speakerID: speaker.id, topSpeakerID: speaker.id,
          secondSpeakerID: nil, topCoverage: 1, secondCoverage: 0)
      }
      guard page.count == 200, let last = page.last else { break }
      after = last.ordinal
    }
    _ = try await speakers.complete(runID: run.id, assignments: assignments, now: now)
    return run.id
  }

  /// Adopts a run with one remote speaker; segment N gets `kinds[N]` (the rest Unknown).
  private func accept(_ meetingID: UUID, pass: UUID, kinds: [SpeakerAssignmentKind]) async throws {
    let run = try await speakers.admit(
      meetingID: meetingID, transcriptPassID: pass, trigger: .manual,
      identity: DiarizationTestSupport.identity, expectedRevision: nil, now: 10)
    _ = try await speakers.start(runID: run.id, now: 10)
    let speaker = SpeakerDraft(
      id: UUID(), clusterKey: 0, track: .system, reconciliation: .confident)
    try await speakers.appendWindow(
      runID: run.id, speakers: [speaker],
      turns: [.init(speakerID: speaker.id, track: .system, startMs: 0, endMs: 900, quality: nil)],
      audioMs: 900)
    let rows = try await transcripts.page(
      meetingID: meetingID, finality: .final, after: nil, limit: 200)
    let assignments = rows.enumerated().map { index, row in
      let kind = index < kinds.count ? kinds[index] : .unknown
      return AssignmentDraft(
        segmentID: row.id, kind: kind, speakerID: kind == .speaker ? speaker.id : nil,
        topSpeakerID: nil, secondSpeakerID: nil, topCoverage: 0, secondCoverage: 0)
    }
    _ = try await speakers.complete(runID: run.id, assignments: assignments, now: 10)
  }

  func testUnknownAndOverlappingRowsCarryTextAndNoPaletteColor() async throws {
    let (id, pass) = try await meeting(segments: 3)
    try await accept(id, pass: pass, kinds: [.speaker, .unknown, .ambiguous])
    let pager = TranscriptPager(meetingID: id, store: transcripts)
    await pager.loadFirst()
    let labels = pager.segments.map { pager.label(for: $0.id) }
    XCTAssertEqual(labels.map { $0?.text }, ["Speaker 1", "Unknown", "Overlapping"])
    XCTAssertEqual(labels.map { $0?.colorIndex }, [0, nil, nil])
    XCTAssertEqual(labels[1]?.kind, .unknown)
    XCTAssertEqual(labels[2]?.kind, .overlapping)
  }

  func testContiguousUnknownOrOverlappingRowsGroupUnderOneLabel() async throws {
    let (id, pass) = try await meeting(segments: 7)
    try await accept(
      id, pass: pass,
      kinds: [.speaker, .unknown, .unknown, .ambiguous, .ambiguous, .speaker, .unknown])
    let pager = TranscriptPager(meetingID: id, store: transcripts)
    await pager.loadFirst()
    let rows = pager.segments
    XCTAssertEqual(
      rows.indices.map { pager.startsGroup(at: $0, in: rows) },
      [true, true, false, true, false, true, true])
  }

  func testManyUnknownSegmentsLeaveTheHeaderCountUnchanged() async throws {
    let (id, pass) = try await meeting(segments: 150)
    try await accept(id, pass: pass, kinds: [.speaker, .ambiguous])
    let pager = TranscriptPager(meetingID: id, store: transcripts)
    await pager.loadFirst()
    XCTAssertEqual(pager.speakerCount, 1)
    XCTAssertEqual(
      pager.segments.filter { pager.label(for: $0.id)?.kind == .unknown }.count, 148)
  }

  func testLabeledPagesStayTwoHundredRowsWithTwoResident() async throws {
    let (id, pass) = try await meeting(segments: 450)
    try await accept(id, pass: pass, track: .system, now: 10)
    let pager = TranscriptPager(meetingID: id, store: transcripts)
    await pager.loadFirst()
    XCTAssertEqual(pager.segments.count, 200)
    XCTAssertEqual(pager.speakerCount, 1)
    XCTAssertTrue(pager.segments.allSatisfy { pager.label(for: $0.id)?.text == "Speaker 1" })
    await pager.loadNext()
    await pager.loadNext()
    XCTAssertEqual(pager.pages.count, TranscriptPager.maximumResidentPages)
    XCTAssertEqual(pager.segments.map(\.ordinal).first, 200)
    XCTAssertTrue(pager.segments.allSatisfy { pager.label(for: $0.id) != nil })
  }

  func testNoDiarizationRowsMatchesFeature006() async throws {
    let (id, _) = try await meeting(segments: 5)
    let pager = TranscriptPager(meetingID: id, store: transcripts)
    await pager.loadFirst()
    let plain = try await transcripts.page(meetingID: id, finality: .final, after: nil, limit: 200)
    XCTAssertEqual(pager.segments, plain)
    XCTAssertNil(pager.speakers)
    XCTAssertNil(pager.speakerCount)
    XCTAssertTrue(pager.segments.allSatisfy { pager.label(for: $0.id) == nil })
  }

  func testAnAcceptedRunForAnotherPassShowsSourceLabels() async throws {
    let (id, _) = try await meeting(segments: 3)
    // Aligned against a pass that is not the transcript's current pass.
    try await accept(id, pass: UUID(), track: .system, now: 10)
    let pager = TranscriptPager(meetingID: id, store: transcripts)
    await pager.loadFirst()
    XCTAssertNil(pager.speakers)
    XCTAssertTrue(pager.segments.allSatisfy { pager.label(for: $0.id) == nil })
  }

  func testAResultChangeBumpsTheRevisionAndReloadsWithoutMixing() async throws {
    let (id, pass) = try await meeting(segments: 450)
    try await accept(id, pass: pass, track: .system, now: 10)
    let pager = TranscriptPager(meetingID: id, store: transcripts)
    await pager.loadFirst()
    XCTAssertEqual(pager.labelsRevision, 0)
    // A new result lands; a page read before the reload keeps no labels from it.
    try await accept(id, pass: pass, track: .microphone, now: 20)
    await pager.loadNext()
    let mixed = pager.segments.compactMap { pager.label(for: $0.id)?.text }
    XCTAssertEqual(Set(mixed), ["Speaker 1"])
    await pager.applyLabels()
    XCTAssertEqual(pager.labelsRevision, 1)
    XCTAssertEqual(pager.pages.count, 1)
    XCTAssertEqual(pager.segments.first?.ordinal, 0)
    XCTAssertTrue(pager.segments.allSatisfy { pager.label(for: $0.id)?.text == "You" })
    // The same result again changes nothing.
    await pager.applyLabels()
    XCTAssertEqual(pager.labelsRevision, 1)
  }

  // MARK: Corrections (T057)

  /// Two remote speakers: segment N belongs to `Speaker (N % 2) + 1`.
  private func acceptTwoSpeakers(_ meetingID: UUID, pass: UUID) async throws -> (UUID, UUID) {
    let run = try await speakers.admit(
      meetingID: meetingID, transcriptPassID: pass, trigger: .manual,
      identity: DiarizationTestSupport.identity, expectedRevision: nil, now: 10)
    _ = try await speakers.start(runID: run.id, now: 10)
    let first = SpeakerDraft(id: UUID(), clusterKey: 0, track: .system, reconciliation: .confident)
    let second = SpeakerDraft(
      id: UUID(), clusterKey: 1, track: .system, reconciliation: .confident)
    try await speakers.appendWindow(
      runID: run.id, speakers: [first, second],
      turns: [
        .init(speakerID: first.id, track: .system, startMs: 0, endMs: 900, quality: nil),
        .init(speakerID: second.id, track: .system, startMs: 1_000, endMs: 1_900, quality: nil),
      ], audioMs: 2_000)
    var assignments: [AssignmentDraft] = []
    var after: Int?
    while true {
      let page = try await transcripts.page(
        meetingID: meetingID, finality: .final, after: after, limit: 200)
      assignments += page.map { row in
        let speaker = row.ordinal % 2 == 0 ? first.id : second.id
        return AssignmentDraft(
          segmentID: row.id, kind: .speaker, speakerID: speaker, topSpeakerID: speaker,
          secondSpeakerID: nil, topCoverage: 1, secondCoverage: 0)
      }
      guard page.count == 200, let last = page.last else { break }
      after = last.ordinal
    }
    _ = try await speakers.complete(runID: run.id, assignments: assignments, now: 10)
    return (first.id, second.id)
  }

  func testACorrectedRowRelabelsAloneWithAnEditedMarker() async throws {
    let (id, pass) = try await meeting(segments: 250)
    let (first, second) = try await acceptTwoSpeakers(id, pass: pass)
    let pager = TranscriptPager(meetingID: id, store: transcripts)
    await pager.loadFirst()
    await pager.loadNext()
    XCTAssertEqual(pager.segments.count, 250)
    XCTAssertEqual(pager.speakerCount, 2)
    let before = pager.segments.map { pager.label(for: $0.id) }
    XCTAssertTrue(before.allSatisfy { $0?.edited == false })
    XCTAssertEqual(before[201]?.kind, .speaker(root: second))
    // Row 201 (Speaker 2) becomes Speaker 1, row 202 Unknown, row 203 a new speaker.
    let rows = pager.segments
    try await speakers.correctSegment(
      meetingID: id, segmentID: rows[201].id, to: .speaker(first), now: 20)
    try await speakers.correctSegment(meetingID: id, segmentID: rows[202].id, to: .unknown, now: 21)
    let created = try await speakers.correctSegment(
      meetingID: id, segmentID: rows[203].id, to: .newSpeaker, now: 22)
    XCTAssertEqual(pager.label(for: rows[201].id)?.text, "Speaker 2", "until the pager refreshes")
    await pager.refreshLabels()
    XCTAssertEqual(pager.labelsRevision, 1)
    XCTAssertEqual(pager.pages.count, 2, "the resident pages stay put")
    XCTAssertEqual(pager.segments, rows)
    let after = pager.segments.map { pager.label(for: $0.id) }
    for index in rows.indices where ![201, 202, 203].contains(index) {
      XCTAssertEqual(after[index], before[index], "row \(index) is untouched")
    }
    XCTAssertEqual(after[201]?.text, "Speaker 1")
    XCTAssertEqual(after[201]?.kind, .speaker(root: first))
    XCTAssertEqual(after[201]?.colorIndex, 0)
    XCTAssertTrue(after[201]?.edited == true)
    XCTAssertEqual(after[202]?.text, "Unknown")
    XCTAssertEqual(after[202]?.kind, .unknown)
    XCTAssertTrue(after[202]?.edited == true)
    XCTAssertEqual(after[203]?.text, "Speaker 3")
    XCTAssertEqual(after[203]?.kind, .speaker(root: try XCTUnwrap(created)))
    XCTAssertEqual(after[203]?.colorIndex, 2)
    XCTAssertTrue(after[203]?.edited == true)
    XCTAssertEqual(pager.speakerCount, 3, "the new speaker counts once it labels a row")
    XCTAssertEqual(pager.speakers?.speakers.map(\.label), ["Speaker 1", "Speaker 2", "Speaker 3"])
  }

  func testAMergedPairCountsOnceAndShowsOneLabel() async throws {
    let (id, pass) = try await meeting(segments: 6)
    let (first, second) = try await acceptTwoSpeakers(id, pass: pass)
    let pager = TranscriptPager(meetingID: id, store: transcripts)
    await pager.loadFirst()
    XCTAssertEqual(pager.speakerCount, 2)
    let rows = pager.segments
    XCTAssertEqual(
      rows.indices.map { pager.startsGroup(at: $0, in: rows) },
      [true, true, true, true, true, true]
    )
    try await speakers.saveNames(meetingID: id, names: [first: "Ana"], now: 19)
    try await speakers.merge(meetingID: id, speakerID: second, into: first, now: 20)
    await pager.refreshLabels()
    XCTAssertEqual(pager.speakerCount, 1, "merged pairs count once (FR-018)")
    let labels = rows.map { pager.label(for: $0.id) }
    XCTAssertTrue(labels.allSatisfy { $0?.text == "Ana" && $0?.kind == .speaker(root: first) })
    XCTAssertTrue(labels.allSatisfy { $0?.edited == false }, "a merge is not a row edit")
    XCTAssertEqual(
      rows.indices.map { pager.startsGroup(at: $0, in: rows) },
      [true, false, false, false, false, false], "one contiguous group")
    let summaries = try await speakers.speakerSummaries(meetingID: id)
    XCTAssertEqual(summaries.map(\.id), [first], "quotes attach to the root")
    XCTAssertEqual(summaries[0].includes.map(\.anonymousLabel), ["Speaker 2"])
    try await speakers.unmerge(meetingID: id, speakerID: second, now: 21)
    await pager.refreshLabels()
    XCTAssertEqual(pager.speakerCount, 2)
    XCTAssertEqual(pager.label(for: rows[1].id)?.text, "Speaker 2")
  }

  // MARK: Copy and search (T070)

  func testCopyProducesLabelBlocksInTranscriptOrderWithoutMetadata() async throws {
    let (id, pass) = try await meeting(segments: 6)
    let (first, second) = try await acceptTwoSpeakers(id, pass: pass)
    try await speakers.saveNames(meetingID: id, names: [first: "Ana"], now: 19)
    // Row 3 joins Ana's rows 2 and 4 in one block; row 5 becomes Unknown.
    let rows = try await transcripts.page(meetingID: id, finality: .final, after: nil, limit: 200)
    let row3 = try XCTUnwrap(rows.first { $0.ordinal == 3 }?.id)
    let row5 = try XCTUnwrap(rows.first { $0.ordinal == 5 }?.id)
    try await speakers.correctSegment(meetingID: id, segmentID: row3, to: .speaker(first), now: 20)
    try await speakers.correctSegment(meetingID: id, segmentID: row5, to: .unknown, now: 21)
    let pager = TranscriptPager(meetingID: id, store: transcripts)
    await pager.loadFirst()
    XCTAssertEqual(
      pager.copyText(),
      """
      Ana:
      Words 0.

      Speaker 2:
      Words 1.

      Ana:
      Words 2.
      Words 3.
      Words 4.

      Unknown:
      Words 5.
      """)
    for forbidden in ["confidence", "coverage", first.uuidString, second.uuidString, "cluster"] {
      XCTAssertFalse(pager.copyText().contains(forbidden))
    }
    // Selection keeps transcript order and the same block rules.
    pager.toggleSelection(pager.segments[3].id)
    pager.toggleSelection(pager.segments[0].id)
    XCTAssertEqual(pager.copyText(), "Ana:\nWords 0.\nWords 3.")
  }

  func testUndiarizedCopyMatchesFeature006() async throws {
    let (id, _) = try await meeting(segments: 3)
    let pager = TranscriptPager(meetingID: id, store: transcripts)
    await pager.loadFirst()
    XCTAssertEqual(pager.copyText(), "Words 0.\nWords 1.\nWords 2.")
    // A result for another pass shows source labels, and copies like Feature 006 too.
    try await accept(id, pass: UUID(), track: .system, now: 10)
    await pager.applyLabels()
    XCTAssertEqual(pager.copyText(), "Words 0.\nWords 1.\nWords 2.")
  }

  func testSearchMatchesDisplayNamesAndText() async throws {
    let (id, pass) = try await meeting(segments: 4)
    let (first, _) = try await acceptTwoSpeakers(id, pass: pass)
    try await speakers.saveNames(meetingID: id, names: [first: "Ana Nováková"], now: 19)
    let pager = TranscriptPager(meetingID: id, store: transcripts)
    await pager.loadFirst()
    let rows = pager.segments
    XCTAssertEqual(rows.filter { pager.matches($0, query: "nov") }.map(\.ordinal), [0, 2])
    XCTAssertEqual(rows.filter { pager.matches($0, query: "Speaker 2") }.map(\.ordinal), [1, 3])
    XCTAssertEqual(rows.filter { pager.matches($0, query: "words 3") }.map(\.ordinal), [3])
    XCTAssertEqual(rows.filter { pager.matches($0, query: "") }.count, 4)
    XCTAssertTrue(rows.filter { pager.matches($0, query: "zzz") }.isEmpty)
  }

  func testLiveRowsCarryNoSpeakerLabels() async throws {
    let meeting = try await fixture.store.create(now: 1)
    try await fixture.store.transition(
      id: meeting.id, to: .preparing, now: 2, effects: [.insertTranscription(liveRequested: true)])
    let pass = UUID()
    try await transcripts.transition(
      meetingID: meeting.id, to: .live, now: 3, effects: [.setPass(id: pass, kind: .live)])
    let draft = TranscriptSegmentDraft(
      ordinal: 0, stretchSequence: 1, startMs: 0, endMs: 900, coveredMs: 1_000, windowIndex: 0,
      timingBasis: .window, rawText: "hi", assembledText: "hi", normalizedText: "Hi.",
      analysisTracks: .mic)
    _ = try await transcripts.appendSegments(
      meetingID: meeting.id, passID: pass, drafts: [draft], progress: nil, now: 4)
    // An accepted result that names this very pass still labels nothing while live.
    let run = try await speakers.admit(
      meetingID: meeting.id, transcriptPassID: pass, trigger: .manual,
      identity: DiarizationTestSupport.identity, expectedRevision: nil, now: 5)
    _ = try await speakers.start(runID: run.id, now: 5)
    _ = try await speakers.complete(runID: run.id, assignments: [], now: 6)
    let pager = TranscriptPager(meetingID: meeting.id, store: transcripts)
    await pager.loadFirst()
    XCTAssertEqual(pager.finality, .provisional)
    XCTAssertEqual(pager.segments.count, 1)
    XCTAssertNil(pager.speakers)
    XCTAssertNil(pager.label(for: pager.segments[0].id))
  }
}

final class SpeakerPaletteTests: XCTestCase {
  func testEightColorsKeepContrastInLightAndDarkAndCycle() {
    XCTAssertEqual(SpeakerPalette.pairs.count, 8)
    for pair in SpeakerPalette.pairs {
      for surface in SpeakerPalette.lightSurfaces {
        XCTAssertGreaterThanOrEqual(SpeakerPalette.contrast(pair.light, surface), 3)
      }
      for surface in SpeakerPalette.darkSurfaces {
        XCTAssertGreaterThanOrEqual(SpeakerPalette.contrast(pair.dark, surface), 3)
      }
    }
    XCTAssertEqual(SpeakerPalette.contrast(0xFFFFFF, 0x000000), 21, accuracy: 0.01)
  }

  func testLabelText() {
    XCTAssertEqual(SpeakerPalette.text(source: .local, ordinal: 1, name: nil, inRoom: false), "You")
    XCTAssertEqual(
      SpeakerPalette.text(source: .local, ordinal: 1, name: "Ana", inRoom: false), "Ana (You)")
    XCTAssertEqual(
      SpeakerPalette.text(source: .local, ordinal: 2, name: nil, inRoom: true), "Local 2")
    XCTAssertEqual(
      SpeakerPalette.text(source: .local, ordinal: 2, name: "Ana", inRoom: true), "Ana")
    XCTAssertEqual(
      SpeakerPalette.text(source: .remote, ordinal: 3, name: nil, inRoom: false), "Speaker 3")
    XCTAssertEqual(
      SpeakerPalette.text(source: .remote, ordinal: 3, name: "Bo", inRoom: false), "Bo")
    XCTAssertEqual(SpeakerPalette.unknown, "Unknown")
    XCTAssertEqual(SpeakerPalette.overlapping, "Overlapping")
  }
}
