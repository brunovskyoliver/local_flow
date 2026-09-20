import GRDB
import XCTest

@testable import LocalFlow

/// Feature 007 (T061): `carry_ovl0.50_ratio2_v1` mapping rules, pure.
final class CorrectionCarryOverTests: XCTestCase {
  private let s1 = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
  private let s2 = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
  private let n1 = UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!
  private let n2 = UUID(uuidString: "00000000-0000-0000-0000-00000000000B")!

  private func turn(
    _ speaker: UUID, _ start: Int64, _ end: Int64, track: MeetingTrackKind = .system
  )
    -> CorrectionCarryOver.Turn
  {
    .init(speaker: speaker, track: track, startMs: start, endMs: end)
  }

  private func sweep(old: [CorrectionCarryOver.Turn], new: [CorrectionCarryOver.Turn])
    -> CorrectionCarryOver.OverlapSweep
  {
    var sweep = CorrectionCarryOver.OverlapSweep()
    sweep.add(old: old, new: new)
    return sweep
  }

  private func map(
    old: [CorrectionCarryOver.Speaker], new: [CorrectionCarryOver.Speaker],
    _ sweep: CorrectionCarryOver.OverlapSweep
  ) -> [UUID: UUID] {
    CorrectionCarryOver.map(old: old, new: new, sweep: sweep)
  }

  func testVersionNamesTheThresholds() {
    XCTAssertEqual(CorrectionCarryOver.version, "carry_ovl0.50_ratio2_v1")
    XCTAssertEqual(DiarizationConstants.carryOverlap, 0.5)
    XCTAssertEqual(DiarizationConstants.carryRatio, 2)
  }

  func testAMappingNeedsHalfTheSpeechOverlapping() {
    let old = [CorrectionCarryOver.Speaker(id: s1, track: .system, speechMs: 1_000)]
    let new = [CorrectionCarryOver.Speaker(id: n1, track: .system)]
    // Exactly half maps; one millisecond under does not.
    XCTAssertEqual(
      map(old: old, new: new, sweep(old: [turn(s1, 0, 1_000)], new: [turn(n1, 0, 500)])),
      [s1: n1])
    XCTAssertEqual(
      map(old: old, new: new, sweep(old: [turn(s1, 0, 1_000)], new: [turn(n1, 0, 499)])), [:])
  }

  func testTheBestOverlapMustBeTwiceTheNextBest() {
    let old = [CorrectionCarryOver.Speaker(id: s1, track: .system, speechMs: 1_000)]
    let new = [
      CorrectionCarryOver.Speaker(id: n1, track: .system),
      CorrectionCarryOver.Speaker(id: n2, track: .system),
    ]
    let clear = sweep(old: [turn(s1, 0, 1_000)], new: [turn(n1, 0, 600), turn(n2, 700, 1_000)])
    XCTAssertEqual(map(old: old, new: new, clear), [s1: n1], "600 ≥ 2 × 300")
    let close = sweep(old: [turn(s1, 0, 1_000)], new: [turn(n1, 0, 600), turn(n2, 600, 1_000)])
    XCTAssertEqual(map(old: old, new: new, close), [:], "600 < 2 × 400")
  }

  func testTheMappingIsReciprocalAndUnique() {
    let old = [
      CorrectionCarryOver.Speaker(id: s1, track: .system, speechMs: 500),
      CorrectionCarryOver.Speaker(id: s2, track: .system, speechMs: 1_000),
    ]
    let new = [CorrectionCarryOver.Speaker(id: n1, track: .system)]
    // Both old speakers cover N1 well enough, but N1's best is S2, so S1 stays unmapped.
    let shared = sweep(
      old: [turn(s1, 0, 500), turn(s2, 500, 1_500)], new: [turn(n1, 0, 1_500)])
    XCTAssertEqual(map(old: old, new: new, shared), [s2: n1])
    // A tie for N1's best maps nobody.
    let tie = sweep(old: [turn(s1, 0, 500), turn(s2, 500, 1_000)], new: [turn(n1, 0, 1_000)])
    let tied = [
      CorrectionCarryOver.Speaker(id: s1, track: .system, speechMs: 500),
      CorrectionCarryOver.Speaker(id: s2, track: .system, speechMs: 500),
    ]
    XCTAssertEqual(map(old: tied, new: new, tie), [:])
  }

  func testOnlyTheSameTrackCounts() {
    let old = [CorrectionCarryOver.Speaker(id: s1, track: .microphone, speechMs: 1_000)]
    let new = [
      CorrectionCarryOver.Speaker(id: n1, track: .system),
      CorrectionCarryOver.Speaker(id: n2, track: .microphone),
    ]
    let sweep = sweep(
      old: [turn(s1, 0, 1_000, track: .microphone)],
      new: [turn(n1, 0, 1_000, track: .system), turn(n2, 0, 400, track: .microphone)])
    XCTAssertEqual(sweep.overlap(s1, n1), 0, "cross-track overlap is never counted")
    XCTAssertEqual(sweep.overlap(s1, n2), 400)
    XCTAssertEqual(map(old: old, new: new, sweep), [:], "400 < 500")
  }

  func testSweepPagesAccumulateAndOrderDoesNotMatter() {
    var paged = CorrectionCarryOver.OverlapSweep()
    var whole = CorrectionCarryOver.OverlapSweep()
    let old = (0..<2_500).map { turn(s1, Int64($0) * 10, Int64($0) * 10 + 8) }
    let new = (0..<2_500).map { turn(n1, Int64($0) * 10 + 4, Int64($0) * 10 + 12) }
    whole.add(old: old, new: new)
    for start in stride(from: 0, to: old.count, by: CorrectionCarryOver.page) {
      let page = Array(old[start..<min(start + CorrectionCarryOver.page, old.count)])
      paged.add(old: page, new: new.shuffled())
    }
    XCTAssertEqual(paged, whole)
    // Each new turn overlaps its own old turn by 4 ms and the next one by 2 ms.
    XCTAssertEqual(paged.overlap(s1, n1), 2_500 * 4 + 2_499 * 2)
    XCTAssertEqual(CorrectionCarryOver.page, 1_000)
  }

  func testTheMappingIsDeterministic() {
    let old = [
      CorrectionCarryOver.Speaker(id: s2, track: .system, speechMs: 1_000),
      CorrectionCarryOver.Speaker(id: s1, track: .system, speechMs: 1_000),
    ]
    let new = [
      CorrectionCarryOver.Speaker(id: n2, track: .system),
      CorrectionCarryOver.Speaker(id: n1, track: .system),
    ]
    let sweep = sweep(
      old: [turn(s1, 0, 1_000), turn(s2, 1_000, 2_000)],
      new: [turn(n1, 0, 1_000), turn(n2, 1_000, 2_000)])
    let first = map(old: old, new: new, sweep)
    XCTAssertEqual(first, [s1: n1, s2: n2])
    for _ in 0..<5 {
      XCTAssertEqual(map(old: old.shuffled(), new: new.shuffled(), sweep), first)
    }
  }
}

/// The R7 effects inside `SpeakerStore.complete` (T065): names, merges and segment
/// corrections follow safe mappings; the rest becomes a review notice.
final class CarryOverAdoptionTests: XCTestCase {
  private var fixture: MeetingTestStore!
  private var store: SpeakerStore!
  private var transcripts: TranscriptStore!

  override func setUpWithError() throws {
    fixture = try MeetingTestStore.make()
    store = SpeakerStore(database: fixture.history.database)
    transcripts = TranscriptStore(database: fixture.history.database)
  }
  override func tearDown() { fixture.cleanup() }

  private struct Meeting {
    let id: UUID
    let pass: UUID
    let segments: [TranscriptSegment]
  }

  /// Six final segments, one per second.
  private func meeting() async throws -> Meeting {
    let meeting = try await fixture.store.create(now: 1)
    try await fixture.store.transition(
      id: meeting.id, to: .preparing, now: 2, effects: [.insertTranscription(liveRequested: true)])
    let spans = (0..<6).map { (Int64($0) * 1_000, Int64($0) * 1_000 + 900) }
    let pass = try await DiarizationTestSupport.finalTranscript(
      transcripts, meetingID: meeting.id, segments: spans, stretchLengths: [6_000])
    let rows = try await transcripts.page(
      meetingID: meeting.id, finality: .final, after: nil, limit: 200)
    return Meeting(id: meeting.id, pass: pass, segments: rows)
  }

  /// Adopts a run with remote speakers A over `a`, B over `b` (ms ranges) and the
  /// local speaker over `local`; every segment is assigned to whoever covers its start.
  @discardableResult
  private func adopt(
    _ meeting: Meeting, a: Range<Int64>, b: Range<Int64>? = nil, local: Range<Int64>? = nil,
    pass: UUID? = nil, now: Int64
  ) async throws -> (run: DiarizationRun, a: UUID, b: UUID?, local: UUID?) {
    let run = try await store.admit(
      meetingID: meeting.id, transcriptPassID: pass ?? meeting.pass, trigger: .retry,
      identity: DiarizationTestSupport.identity, expectedRevision: nil, now: now)
    _ = try await store.start(runID: run.id, now: now)
    var drafts: [SpeakerDraft] = []
    var turns: [TurnDraft] = []
    var covers: [(UUID, Range<Int64>)] = []
    func add(_ range: Range<Int64>?, key: Int, track: MeetingTrackKind) -> UUID? {
      guard let range else { return nil }
      let draft = SpeakerDraft(
        id: UUID(), clusterKey: key, track: track, reconciliation: .confident)
      drafts.append(draft)
      turns.append(
        .init(
          speakerID: draft.id, track: track, startMs: range.lowerBound, endMs: range.upperBound,
          quality: nil))
      covers.append((draft.id, range))
      return draft.id
    }
    let aID = add(a, key: 0, track: .system)!
    let bID = add(b, key: 1, track: .system)
    let localID = add(local, key: 2, track: .microphone)
    try await store.appendWindow(runID: run.id, speakers: drafts, turns: turns, audioMs: 6_000)
    let assignments = meeting.segments.map { segment -> AssignmentDraft in
      if let speaker = covers.first(where: { $0.1.contains(segment.startMs) })?.0 {
        return .init(
          segmentID: segment.id, kind: .speaker, speakerID: speaker, topSpeakerID: speaker,
          secondSpeakerID: nil, topCoverage: 1, secondCoverage: 0)
      }
      return .init(
        segmentID: segment.id, kind: .unknown, speakerID: nil, topSpeakerID: nil,
        secondSpeakerID: nil, topCoverage: 0, secondCoverage: 0)
    }
    let done = try await store.complete(runID: run.id, assignments: assignments, now: now + 1)
    return (done, aID, bID, localID)
  }

  private func name(_ id: UUID) async throws -> String? {
    try await fixture.history.database.read { db in
      try String.fetchOne(
        db, sql: "SELECT display_name FROM meeting_speakers WHERE id=?", arguments: [id.uuidString])
    }
  }

  private func mergedInto(_ id: UUID) async throws -> String? {
    try await fixture.history.database.read { db in
      try Optional<String>.fetchOne(
        db, sql: "SELECT merged_into FROM meeting_speakers WHERE id=?", arguments: [id.uuidString]
      ) ?? nil
    }
  }

  private func manual(_ run: UUID, segment: UUID) async throws -> (String?, String?) {
    try await fixture.history.database.read { db in
      let row = try Row.fetchOne(
        db,
        sql:
          "SELECT manual_kind, manual_speaker_id FROM speaker_assignments WHERE run_id=? AND segment_id=?",
        arguments: [run.uuidString, segment.uuidString])
      return (row?["manual_kind"], row?["manual_speaker_id"])
    }
  }

  func testNamesFollowSafeMappingsAndTheRestIsFlagged() async throws {
    let meeting = try await meeting()
    let first = try await adopt(
      meeting, a: 0..<3_000, b: 3_000..<6_000, local: 0..<6_000, now: 10)
    try await store.saveNames(
      meetingID: meeting.id, names: [first.a: "Ana", first.b!: "Ben", first.local!: "Oliver"],
      now: 20)
    // The rerun finds A and You again, and B over exactly half of its speech.
    let second = try await adopt(
      meeting, a: 0..<3_000, b: 3_000..<4_500, local: 0..<6_000, now: 30)
    let aName = try await name(second.a)
    XCTAssertEqual(aName, "Ana")
    let localName = try await name(second.local!)
    XCTAssertEqual(localName, "Oliver")
    let bName = try await name(second.b!)
    XCTAssertEqual(bName, "Ben", "1,500 of 3,000 ms is exactly half, and nothing rivals it")
    let notices = try await store.reviewNotices(meetingID: meeting.id)
    XCTAssertTrue(notices.isEmpty)
    // A third run where B's voice is not found at all flags Ben and keeps the label.
    let third = try await adopt(meeting, a: 0..<3_000, local: 0..<6_000, now: 40)
    let flagged = try await store.reviewNotices(meetingID: meeting.id)
    XCTAssertEqual(flagged.map(\.name), ["Ben"])
    XCTAssertEqual(flagged.map(\.text), ["Couldn't carry over: Ben"])
    let summaries = try await store.speakerSummaries(meetingID: meeting.id)
    XCTAssertEqual(summaries.map(\.displayName), ["Ana", "Oliver"])
    XCTAssertEqual(third.run.state, .succeeded)
    try await store.dismissReview(id: flagged[0].id)
    let cleared = try await store.reviewNotices(meetingID: meeting.id)
    XCTAssertTrue(cleared.isEmpty)
    let stored = try await store.run(id: third.run.id)
    XCTAssertEqual(stored?.state, .succeeded, "a review notice never blocks adoption")
  }

  /// Feature 010 (T057): a manual identity row follows the safe name map with its
  /// rejected pairs; an unmapped one is a review notice; automatic rows are recomputed.
  func testManualIdentityRowsFollowSafeMappingsAndAutomaticRowsAreNotCarried() async throws {
    let meeting = try await meeting()
    let identities = IdentityStore(
      database: fixture.history.database, identity: IdentificationTestSupport.identity)
    let tomas = try await identities.createKnownSpeaker(name: "Tomáš", isLocalUser: false, now: 1)
    let lukas = try await identities.createKnownSpeaker(name: "Lukáš", isLocalUser: false, now: 2)
    let first = try await adopt(
      meeting, a: 0..<3_000, b: 3_000..<6_000, local: 0..<6_000, now: 10)
    // A: confirmed by the user, with Lukáš rejected. B: an automatic match.
    try await identities.link(
      meetingID: meeting.id, speakerID: first.a, to: tomas.id, origin: .userConfirmation, now: 20)
    try await identities.reject(
      meetingID: meeting.id, speakerID: first.a, candidate: lukas.id, keepUnknown: false, now: 21)
    let run = try await identities.admit(
      meetingID: meeting.id, trigger: .manual, identity: IdentificationTestSupport.identity,
      policy: "tiers_v1@wespeaker_resnet34lm_256/11111111", now: 22)
    _ = try await identities.start(runID: run.id, now: 23)
    let candidate = IdentityMatcher.Candidate(
      knownSpeakerID: lukas.id, score: 0.9, tier: .recognized, reasons: [], sampleCount: 3,
      supportCount: 3)
    _ = try await identities.complete(
      runID: run.id,
      decisions: [
        first.b!: .init(state: .recognized, best: candidate, second: nil, candidates: [candidate])
      ], now: 24)
    // The rerun finds A again and B not at all.
    let second = try await adopt(meeting, a: 0..<3_000, local: 0..<6_000, now: 30)
    let carried = try await identities.identities(meetingID: meeting.id)
    XCTAssertEqual(carried[second.a]?.knownSpeakerID, tomas.id)
    XCTAssertEqual(carried[second.a]?.origin, .userConfirmation)
    let rejected = try await identities.rejectedCandidates(meetingID: meeting.id)
    XCTAssertEqual(rejected[second.a], [lukas.id])
    let automatic = try await fixture.history.database.read { db in
      try Int.fetchOne(
        db,
        sql:
          "SELECT count(*) FROM identity_assignments a JOIN meeting_speakers s ON s.id=a.meeting_speaker_id WHERE s.run_id=? AND a.origin='automatic_match'",
        arguments: [second.run.id.uuidString])
    }
    XCTAssertEqual(automatic, 0, "Automatic rows are never carried")
    let notices = try await store.reviewNotices(meetingID: meeting.id)
    XCTAssertEqual(notices.map(\.name), ["Lukáš"], "The name copied on recognition is flagged")
    // A manual row whose cluster vanished, with no name of its own, is flagged by identity.
    let third = try await adopt(meeting, a: 0..<3_000, local: 0..<6_000, now: 40)
    try await identities.link(
      meetingID: meeting.id, speakerID: third.local!, to: lukas.id, origin: .manualProfileSelection,
      now: 41)
    try await fixture.history.database.write { db in
      try db.execute(
        sql: "UPDATE meeting_speakers SET display_name=NULL WHERE id=?",
        arguments: [third.local!.uuidString])
    }
    _ = try await adopt(meeting, a: 0..<3_000, now: 50)
    let flagged = try await store.reviewNotices(meetingID: meeting.id)
    XCTAssertTrue(flagged.map(\.name).contains("Lukáš"))
    XCTAssertEqual(flagged.filter { $0.name == "Lukáš" }.count, 2)
  }

  func testAMergeCarriesOnlyWhenBothMembersMapToDifferentClusters() async throws {
    let meeting = try await meeting()
    let first = try await adopt(meeting, a: 0..<3_000, b: 3_000..<6_000, now: 10)
    try await store.saveNames(meetingID: meeting.id, names: [first.a: "Ana"], now: 19)
    try await store.merge(meetingID: meeting.id, speakerID: first.b!, into: first.a, now: 20)
    // Both map to distinct clusters: the merge follows.
    let second = try await adopt(meeting, a: 0..<3_000, b: 3_000..<6_000, now: 30)
    let carried = try await mergedInto(second.b!)
    XCTAssertEqual(carried, second.a.uuidString)
    let none = try await store.reviewNotices(meetingID: meeting.id)
    XCTAssertTrue(none.isEmpty)
    // Only one member is found: the merge is flagged, not guessed.
    let third = try await adopt(meeting, a: 0..<3_000, now: 40)
    let unmerged = try await mergedInto(third.a)
    XCTAssertNil(unmerged)
    let flagged = try await store.reviewNotices(meetingID: meeting.id)
    XCTAssertEqual(flagged.map(\.name), ["Speaker 2"], "the absorbed speaker's label")
  }

  func testAManualSpeakerMergedIntoAClusterFollowsThatClusterOrStandsAlone() async throws {
    let meeting = try await meeting()
    let first = try await adopt(meeting, a: 0..<3_000, b: 3_000..<6_000, now: 10)
    let created = try await store.correctSegment(
      meetingID: meeting.id, segmentID: meeting.segments[2].id, to: .newSpeaker, now: 20)
    let manualSpeaker = try XCTUnwrap(created)
    try await store.merge(meetingID: meeting.id, speakerID: manualSpeaker, into: first.b!, now: 21)
    // B found again: the manual speaker follows B's new cluster.
    let second = try await adopt(meeting, a: 0..<3_000, b: 3_000..<6_000, now: 30)
    let followed = try await mergedInto(manualSpeaker)
    XCTAssertEqual(followed, second.b?.uuidString)
    // B gone: the manual row stands alone and the merge is flagged.
    let third = try await adopt(meeting, a: 0..<3_000, now: 40)
    let alone = try await mergedInto(manualSpeaker)
    XCTAssertNil(alone)
    let flagged = try await store.reviewNotices(meetingID: meeting.id)
    XCTAssertEqual(flagged.map(\.name), ["Speaker 3"], "the manual speaker's own label")
    let summaries = try await store.speakerSummaries(meetingID: meeting.id)
    XCTAssertEqual(Set(summaries.map(\.id)), [third.a, manualSpeaker])
  }

  func testASegmentCorrectionCarriesOnlyOnTheSamePassWithAMappedTarget() async throws {
    let meeting = try await meeting()
    let first = try await adopt(meeting, a: 0..<3_000, b: 3_000..<6_000, now: 10)
    let rows = meeting.segments
    try await store.correctSegment(
      meetingID: meeting.id, segmentID: rows[0].id, to: .speaker(first.b!), now: 20)
    try await store.correctSegment(
      meetingID: meeting.id, segmentID: rows[1].id, to: .unknown, now: 21)
    let created = try await store.correctSegment(
      meetingID: meeting.id, segmentID: rows[2].id, to: .newSpeaker, now: 22)
    let manualSpeaker = try XCTUnwrap(created)
    // Same pass, B found again: all three carry (B mapped, Unknown, manual speaker).
    let second = try await adopt(meeting, a: 0..<3_000, b: 3_000..<6_000, now: 30)
    let toB = try await manual(second.run.id, segment: rows[0].id)
    XCTAssertEqual(toB.0, "speaker")
    XCTAssertEqual(toB.1, second.b?.uuidString)
    let toUnknown = try await manual(second.run.id, segment: rows[1].id)
    XCTAssertEqual(toUnknown.0, "unknown")
    let toManual = try await manual(second.run.id, segment: rows[2].id)
    XCTAssertEqual(toManual.1, manualSpeaker.uuidString)
    let untouched = try await manual(second.run.id, segment: rows[3].id)
    XCTAssertNil(untouched.0)
    let none = try await store.reviewNotices(meetingID: meeting.id)
    XCTAssertTrue(none.isEmpty)
    // B not found: the correction to B is flagged; Unknown and the manual speaker carry.
    let third = try await adopt(meeting, a: 0..<3_000, now: 40)
    let lost = try await manual(third.run.id, segment: rows[0].id)
    XCTAssertNil(lost.0)
    let stillUnknown = try await manual(third.run.id, segment: rows[1].id)
    XCTAssertEqual(stillUnknown.0, "unknown")
    let stillManual = try await manual(third.run.id, segment: rows[2].id)
    XCTAssertEqual(stillManual.1, manualSpeaker.uuidString)
    let flagged = try await store.reviewNotices(meetingID: meeting.id)
    XCTAssertEqual(flagged.map(\.name), ["Speaker 2"])
  }

  func testAnotherPassCarriesNoSegmentCorrections() async throws {
    let meeting = try await meeting()
    let first = try await adopt(meeting, a: 0..<3_000, b: 3_000..<6_000, now: 10)
    try await store.saveNames(meetingID: meeting.id, names: [first.a: "Ana"], now: 19)
    try await store.correctSegment(
      meetingID: meeting.id, segmentID: meeting.segments[1].id, to: .unknown, now: 20)
    // A run aligned against a new pass id: the name maps by voice, the row does not exist.
    let second = try await adopt(
      meeting, a: 0..<3_000, b: 3_000..<6_000, pass: UUID(), now: 30)
    let aName = try await name(second.a)
    XCTAssertEqual(aName, "Ana")
    let row = try await manual(second.run.id, segment: meeting.segments[1].id)
    XCTAssertNil(row.0)
    let flagged = try await store.reviewNotices(meetingID: meeting.id)
    XCTAssertEqual(flagged.map(\.name), ["Unknown"])
  }
}
