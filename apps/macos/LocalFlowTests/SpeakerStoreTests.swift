import GRDB
import XCTest

@testable import LocalFlow

final class SpeakerStoreTests: XCTestCase {
  private var fixture: MeetingTestStore!
  private var store: SpeakerStore!
  private var transcripts: TranscriptStore!
  private let identity = DiarizationIdentity(
    engine: "fluidaudio_offline_diarizer", modelID: "FluidInference/speaker-diarization-coreml",
    modelRevision: String(repeating: "1", count: 40),
    manifestHash: String(repeating: "a", count: 64),
    pipelineVersion: DiarizationPipelineVersion.current)

  override func setUpWithError() throws {
    fixture = try MeetingTestStore.make()
    store = SpeakerStore(database: fixture.history.database)
    transcripts = TranscriptStore(database: fixture.history.database)
  }
  override func tearDown() { fixture.cleanup() }

  // MARK: Helpers

  private struct Meeting {
    let id: UUID
    let pass: UUID
    let segments: [UUID]
  }

  private func meeting(segments count: Int = 3) async throws -> Meeting {
    let meeting = try await fixture.store.create(now: 1)
    try await fixture.store.transition(
      id: meeting.id, to: .preparing, now: 2, effects: [.insertTranscription(liveRequested: true)])
    let pass = UUID()
    try await transcripts.transition(
      meetingID: meeting.id, to: .live, now: 3, effects: [.setPass(id: pass, kind: .live)])
    let drafts = (0..<count).map { ordinal in
      TranscriptSegmentDraft(
        ordinal: ordinal, stretchSequence: 1, startMs: Int64(ordinal) * 1_000,
        endMs: Int64(ordinal + 1) * 1_000, coveredMs: 60_000, windowIndex: 0,
        timingBasis: .window, rawText: "raw", assembledText: "raw", normalizedText: "Raw",
        analysisTracks: .both)
    }
    _ = try await transcripts.appendSegments(
      meetingID: meeting.id, passID: pass, drafts: drafts, progress: nil, now: 4)
    let rows = try await transcripts.page(
      meetingID: meeting.id, finality: .provisional, after: nil, limit: 200)
    return Meeting(id: meeting.id, pass: pass, segments: rows.map(\.id))
  }

  private func running(_ meeting: Meeting, trigger: DiarizationTrigger = .automatic) async throws
    -> DiarizationRun
  {
    let run = try await store.admit(
      meetingID: meeting.id, transcriptPassID: meeting.pass, trigger: trigger,
      identity: identity, expectedRevision: nil, now: 10)
    return try await store.start(runID: run.id, now: 11)
  }

  /// Two clusters (remote then local) and three turns; returns the speaker ids.
  @discardableResult
  private func window(
    _ run: DiarizationRun, quality: Float? = 0.5, keys: (Int, Int) = (0, 1)
  ) async throws -> (UUID, UUID) {
    let remote = SpeakerDraft(
      id: UUID(), clusterKey: keys.0, track: .system, reconciliation: .confident)
    let local = SpeakerDraft(
      id: UUID(), clusterKey: keys.1, track: .microphone, reconciliation: .uncertain)
    try await store.appendWindow(
      runID: run.id, speakers: [remote, local],
      turns: [
        TurnDraft(speakerID: remote.id, track: .system, startMs: 0, endMs: 1_500, quality: quality),
        TurnDraft(
          speakerID: local.id, track: .microphone, startMs: 1_000, endMs: 3_000, quality: nil),
        TurnDraft(speakerID: nil, track: .system, startMs: 2_500, endMs: 2_800, quality: nil),
      ], audioMs: 3_000)
    return (remote.id, local.id)
  }

  private func assignments(_ meeting: Meeting, speaker: UUID) -> [AssignmentDraft] {
    meeting.segments.enumerated().map { index, segment in
      index == 0
        ? AssignmentDraft(
          segmentID: segment, kind: .speaker, speakerID: speaker, topSpeakerID: speaker,
          secondSpeakerID: nil, topCoverage: 1, secondCoverage: 0)
        : AssignmentDraft(
          segmentID: segment, kind: index == 1 ? .ambiguous : .unknown, speakerID: nil,
          topSpeakerID: nil, secondSpeakerID: nil, topCoverage: 0, secondCoverage: 0)
    }
  }

  private func count(_ table: String, run: UUID? = nil) async throws -> Int {
    try await fixture.history.database.read { db in
      try Int.fetchOne(
        db,
        sql: run == nil
          ? "SELECT count(*) FROM \(table)" : "SELECT count(*) FROM \(table) WHERE run_id=?",
        arguments: run.map { [$0.uuidString] } ?? []) ?? -1
    }
  }

  /// Every row a run owns, as text, for byte-identity checks.
  private func dump(_ run: UUID) async throws -> String {
    try await fixture.history.database.read { db in
      var lines: [String] = []
      for (table, key) in [
        ("diarization_runs", "id"), ("meeting_speakers", "run_id"), ("speaker_turns", "run_id"),
        ("speaker_assignments", "run_id"),
      ] {
        for row in try Row.fetchAll(
          db, sql: "SELECT * FROM \(table) WHERE \(key)=? ORDER BY 1", arguments: [run.uuidString])
        {
          lines.append("\(table) \(row.description)")
        }
      }
      return lines.joined(separator: "\n")
    }
  }

  private func accepted(_ meeting: Meeting, speakerKeys: (Int, Int) = (0, 1)) async throws
    -> DiarizationRun
  {
    let run = try await running(meeting)
    let (remote, _) = try await window(run, keys: speakerKeys)
    return try await store.complete(
      runID: run.id, assignments: assignments(meeting, speaker: remote), now: 20)
  }

  // MARK: Schema

  func testMigrationOnAFeature006DatabaseAddsOneRowPerMeetingAndNoIdentityTables() throws {
    let directory = try makeMeetingTestRoot()
    defer { try? FileManager.default.removeItem(at: directory) }
    let database = try DatabaseQueue(path: directory.appendingPathComponent("h.sqlite").path)
    try HistoryMigrations.migrator().migrate(database, upTo: "transcripts-v6")
    let ids = [UUID(), UUID()]
    try database.write { db in
      for (index, id) in ids.enumerated() {
        try db.execute(
          sql: "INSERT INTO meetings(id,state,created_at,updated_at) VALUES(?,?,?,?)",
          arguments: [id.uuidString, "completed", 1, 5 + index])
      }
    }
    try HistoryMigrations.migrator().migrate(database)
    try database.read { db in
      let rows = try Row.fetchAll(
        db, sql: "SELECT * FROM meeting_diarization ORDER BY updated_at")
      XCTAssertEqual(rows.map { $0["meeting_id"] as String }, ids.map(\.uuidString))
      XCTAssertTrue(rows.allSatisfy { ($0["in_room"] as Int) == 0 && ($0["revision"] as Int) == 0 })
      let tables = try String.fetchAll(
        db, sql: "SELECT name FROM sqlite_master WHERE type='table'")
      for name in [
        "meeting_diarization", "diarization_runs", "meeting_speakers", "speaker_turns",
        "speaker_assignments", "speaker_corrections",
      ] {
        XCTAssertTrue(tables.contains(name), name)
        for column in try db.columns(in: name) {
          XCTAssertNotEqual(column.type.uppercased(), "BLOB", "\(name).\(column.name)")
          XCTAssertFalse(column.name.contains("confidence"), "FR-012: \(name).\(column.name)")
        }
      }
      XCTAssertFalse(
        tables.contains {
          $0.contains("embedding") || $0.contains("identit") || $0.contains("profile")
        },
        "No identity or embedding table (FR-028, FR-036)")
      // transcript_segments keeps its Feature 005 shape.
      XCTAssertFalse(
        try db.columns(in: "transcript_segments").contains { $0.name.contains("speaker_id") })
    }
  }

  func testPartialUniqueIndexAllowsOnePendingOrRunningRunPerMeeting() async throws {
    let meeting = try await meeting()
    let run = try await running(meeting)
    do {
      _ = try await store.admit(
        meetingID: meeting.id, transcriptPassID: meeting.pass, trigger: .manual,
        identity: identity, expectedRevision: nil, now: 12)
      XCTFail("Second active run admitted")
    } catch { XCTAssertEqual(error as? SpeakerStore.Error, .runInProgress) }
    // The index itself refuses what the store would not attempt.
    try await fixture.history.database.write { db in
      XCTAssertThrowsError(
        try db.execute(
          sql: """
            INSERT INTO diarization_runs (id, meeting_id, transcript_pass_id, state, "trigger", in_room,
              engine, model_id, model_revision, model_manifest_hash, pipeline_version, created_at)
            VALUES (?,?,?,'pending','manual',0,'e','m','r',?,'p',1)
            """,
          arguments: [
            UUID().uuidString, meeting.id.uuidString, meeting.pass.uuidString,
            String(repeating: "b", count: 64),
          ]))
    }
    try await store.fail(runID: run.id, category: .runtimeFailure, detail: "window=2", now: 13)
    _ = try await running(meeting, trigger: .retry)
  }

  func testAdmitChecksTheRevisionAndSnapshotsInRoom() async throws {
    let meeting = try await meeting()
    try await fixture.history.database.write { db in
      try db.execute(
        sql: "UPDATE meeting_diarization SET in_room=1 WHERE meeting_id=?",
        arguments: [meeting.id.uuidString])
    }
    let row = try await store.diarization(meetingID: meeting.id)
    do {
      _ = try await store.admit(
        meetingID: meeting.id, transcriptPassID: meeting.pass, trigger: .manual,
        identity: identity, expectedRevision: (row?.revision ?? 0) + 1, now: 5)
      XCTFail("Stale revision admitted")
    } catch { XCTAssertEqual(error as? SpeakerStore.Error, .staleRevision) }
    let run = try await store.admit(
      meetingID: meeting.id, transcriptPassID: meeting.pass, trigger: .inRoomChange,
      identity: identity, expectedRevision: row?.revision, now: 5)
    XCTAssertTrue(run.inRoom)
    XCTAssertEqual(run.state, .pending)
    let after = try await store.diarization(meetingID: meeting.id)
    XCTAssertEqual(after?.currentRunID, run.id)
    XCTAssertEqual(after?.revision, (row?.revision ?? 0) + 1)
    let state = try await store.meetingState(meetingID: meeting.id)
    XCTAssertEqual(state, .pending)
  }

  // MARK: Transitions

  func testRunFollowsTheTransitionTable() async throws {
    let meeting = try await meeting()
    let pending = try await store.admit(
      meetingID: meeting.id, transcriptPassID: meeting.pass, trigger: .automatic,
      identity: identity, expectedRevision: nil, now: 10)
    do {
      _ = try await store.complete(runID: pending.id, assignments: [], now: 11)
      XCTFail("pending → succeeded")
    } catch {
      XCTAssertEqual(
        error as? SpeakerStore.Error, .invalidTransition(from: .pending, to: .succeeded))
    }
    do {
      try await store.appendWindow(runID: pending.id, speakers: [], turns: [], audioMs: 0)
      XCTFail("Windows need a running run")
    } catch { XCTAssertNotNil(error as? SpeakerStore.Error) }
    let run = try await store.start(runID: pending.id, now: 11)
    XCTAssertEqual(run.state, .running)
    XCTAssertEqual(run.startedAt, 11)
    let state = try await store.meetingState(meetingID: meeting.id)
    XCTAssertEqual(state, .running)
    do {
      _ = try await store.start(runID: run.id, now: 12)
      XCTFail("running → running")
    } catch {
      XCTAssertEqual(error as? SpeakerStore.Error, .invalidTransition(from: .running, to: .running))
    }
    // Every table row agrees with the lifecycle's table.
    for from in DiarizationRunState.allCases {
      for to in DiarizationRunState.allCases {
        let allowed = (try? DiarizationRunLifecycle.transition(from: from, to: to)) != nil
        XCTAssertEqual(
          allowed, DiarizationRunLifecycle.allowed.contains("\(from.rawValue)>\(to.rawValue)"))
      }
    }
    XCTAssertThrowsError(try DiarizationRunLifecycle.transition(from: .succeeded, to: .running))
    XCTAssertThrowsError(try DiarizationRunLifecycle.transition(from: .failed, to: .running))
    XCTAssertThrowsError(try DiarizationRunLifecycle.transition(from: .superseded, to: .succeeded))
  }

  func testCompletionAdoptsAtomicallyWithColorsOrdinalsAndCounters() async throws {
    let meeting = try await meeting()
    let run = try await running(meeting)
    let (remote, local) = try await window(run)
    let done = try await store.complete(
      runID: run.id, assignments: assignments(meeting, speaker: remote), now: 20)
    XCTAssertEqual(done.state, .succeeded)
    XCTAssertEqual(done.inferredSpeakerCount, 2)
    XCTAssertEqual(done.unknownCount, 1)
    XCTAssertEqual(done.ambiguousCount, 1)
    XCTAssertEqual(done.overlapTurnCount, 3, "All three turns overlap another (FR-011)")
    let stored = try await store.run(id: run.id)
    XCTAssertEqual(stored, done)
    XCTAssertEqual(stored?.windowCount, 1)
    XCTAssertEqual(stored?.audioMs, 3_000)
    XCTAssertEqual(stored?.turnCount, 3)
    XCTAssertEqual(stored?.overflowTurns, 1)
    XCTAssertEqual(stored?.uncertainReconciliations, 1)
    let row = try await store.diarization(meetingID: meeting.id)
    XCTAssertEqual(row?.acceptedRunID, run.id)
    XCTAssertNil(row?.currentRunID)
    let state = try await store.meetingState(meetingID: meeting.id)
    XCTAssertEqual(state, .succeeded)
    try await fixture.history.database.read { db in
      let speakers = try Row.fetchAll(
        db,
        sql:
          "SELECT id, source, color_index, label_ordinal, first_ms, speech_ms, engine_quality FROM meeting_speakers WHERE run_id=? ORDER BY first_ms",
        arguments: [run.id.uuidString])
      XCTAssertEqual(speakers.map { $0["id"] as String }, [remote.uuidString, local.uuidString])
      XCTAssertEqual(speakers.map { $0["color_index"] as Int }, [0, 1])
      XCTAssertEqual(speakers.map { $0["label_ordinal"] as Int }, [1, 1], "Per-source ordinals")
      XCTAssertEqual(speakers.map { $0["speech_ms"] as Int64 }, [1_500, 2_000])
      XCTAssertEqual(speakers[0]["engine_quality"] as Double?, 0.5)
      XCTAssertNil(speakers[1]["engine_quality"] as Double?, "No quality stays NULL (FR-012)")
    }
  }

  func testCompletionSupersedesThePreviousRunAndDeletesItsEvidence() async throws {
    let meeting = try await meeting()
    let first = try await accepted(meeting)
    let second = try await accepted(meeting)
    let old = try await store.run(id: first.id)
    XCTAssertEqual(old?.state, .superseded)
    let turns = try await count("speaker_turns", run: first.id)
    let assigned = try await count("speaker_assignments", run: first.id)
    XCTAssertEqual(turns, 0)
    XCTAssertEqual(assigned, 0)
    let newTurns = try await count("speaker_turns", run: second.id)
    XCTAssertEqual(newTurns, 3)
    let row = try await store.diarization(meetingID: meeting.id)
    XCTAssertEqual(row?.acceptedRunID, second.id)
  }

  func testFailedInterruptedAndCancelledRunsLeaveTheAcceptedRunByteIdentical() async throws {
    let meeting = try await meeting()
    let kept = try await accepted(meeting)
    let before = try await dump(kept.id)
    let segmentsBefore = try await transcripts.page(
      meetingID: meeting.id, finality: .provisional, after: nil, limit: 200)

    let failed = try await running(meeting)
    try await window(failed, keys: (5, 6))
    try await store.fail(
      runID: failed.id, category: .transcriptChanged, detail: "pass", now: 30)
    let failedRow = try await store.run(id: failed.id)
    XCTAssertEqual(failedRow?.state, .failed)
    XCTAssertEqual(failedRow?.failureCategory, .transcriptChanged)
    for table in ["meeting_speakers", "speaker_turns", "speaker_assignments"] {
      let rows = try await count(table, run: failed.id)
      XCTAssertEqual(rows, 0, table)
    }
    let failedState = try await store.meetingState(meetingID: meeting.id)
    XCTAssertEqual(failedState, .failed)

    let interrupted = try await running(meeting)
    try await window(interrupted, keys: (7, 8))
    try await store.interrupt(runID: interrupted.id, now: 31)
    let interruptedRow = try await store.run(id: interrupted.id)
    XCTAssertEqual(interruptedRow?.failureCategory, .interrupted)
    let interruptedTurns = try await count("speaker_turns", run: interrupted.id)
    XCTAssertEqual(interruptedTurns, 0)
    let interruptedState = try await store.meetingState(meetingID: meeting.id)
    XCTAssertEqual(interruptedState, .interrupted)

    let cancelled = try await running(meeting)
    try await window(cancelled, keys: (9, 10))
    try await store.cancel(runID: cancelled.id)
    let gone = try await store.run(id: cancelled.id)
    XCTAssertNil(gone)
    let cancelledSpeakers = try await count("meeting_speakers", run: cancelled.id)
    XCTAssertEqual(cancelledSpeakers, 0)

    let after = try await dump(kept.id)
    XCTAssertEqual(after, before)
    let row = try await store.diarization(meetingID: meeting.id)
    XCTAssertEqual(row?.acceptedRunID, kept.id)
    XCTAssertNil(row?.currentRunID)
    let segmentsAfter = try await transcripts.page(
      meetingID: meeting.id, finality: .provisional, after: nil, limit: 200)
    XCTAssertEqual(segmentsAfter, segmentsBefore)
  }

  func testRequeueRestartsFromNothingAndCountsThePreemption() async throws {
    let meeting = try await meeting()
    let run = try await running(meeting)
    try await window(run)
    try await store.requeue(runID: run.id)
    let requeued = try await store.run(id: run.id)
    XCTAssertEqual(requeued?.state, .pending)
    XCTAssertEqual(requeued?.preemptionCount, 1)
    XCTAssertEqual(requeued?.turnCount, 0)
    XCTAssertEqual(requeued?.windowCount, 0)
    XCTAssertNil(requeued?.startedAt)
    let speakers = try await count("meeting_speakers", run: run.id)
    XCTAssertEqual(speakers, 0)
    let restarted = try await store.start(runID: run.id, now: 40)
    XCTAssertEqual(restarted.preemptionCount, 1)
  }

  // MARK: Cascades and bounds

  func testMeetingDeletionAndDiscardPassCascade() async throws {
    let meeting = try await meeting()
    let run = try await accepted(meeting)
    try await transcripts.discardPass(meetingID: meeting.id, passID: meeting.pass)
    let assigned = try await count("speaker_assignments", run: run.id)
    XCTAssertEqual(assigned, 0, "discardPass removes the pass's assignments")
    let turns = try await count("speaker_turns", run: run.id)
    XCTAssertEqual(turns, 3, "Machine evidence is not tied to segments")

    try await fixture.history.database.write { db in
      try db.execute(sql: "DELETE FROM meetings WHERE id=?", arguments: [meeting.id.uuidString])
    }
    for table in [
      "meeting_diarization", "diarization_runs", "meeting_speakers", "speaker_turns",
      "speaker_assignments", "speaker_corrections",
    ] {
      let rows = try await count(table)
      XCTAssertEqual(rows, 0, table)
    }
  }

  func testTheHundredThousandthTurnIsTheLastAccepted() async throws {
    let meeting = try await meeting()
    let run = try await running(meeting)
    try await fixture.history.database.write { db in
      try db.execute(
        sql: "UPDATE diarization_runs SET turn_count=? WHERE id=?",
        arguments: [DiarizationConstants.turnsPerRun - 1, run.id.uuidString])
    }
    let turn = TurnDraft(speakerID: nil, track: .system, startMs: 0, endMs: 10, quality: nil)
    do {
      try await store.appendWindow(runID: run.id, speakers: [], turns: [turn, turn], audioMs: 10)
      XCTFail("Capacity exceeded")
    } catch { XCTAssertEqual(error as? SpeakerStore.Error, .capacityExceeded) }
    let stored = try await count("speaker_turns", run: run.id)
    XCTAssertEqual(stored, 0, "Nothing of a refused window is written")
    try await store.appendWindow(runID: run.id, speakers: [], turns: [turn], audioMs: 10)
    try await store.fail(runID: run.id, category: .persistenceCapacity, detail: nil, now: 50)
    let row = try await store.diarization(meetingID: meeting.id)
    XCTAssertNil(row?.acceptedRunID, "Nothing is adopted")
  }

  func testWindowsRejectForeignSpeakersAndInvalidTurnsWithoutWriting() async throws {
    let meeting = try await meeting()
    let run = try await running(meeting)
    let invalid: [[TurnDraft]] = [
      [TurnDraft(speakerID: UUID(), track: .system, startMs: 0, endMs: 1, quality: nil)],
      [TurnDraft(speakerID: nil, track: .system, startMs: 5, endMs: 5, quality: nil)],
      [TurnDraft(speakerID: nil, track: .system, startMs: -1, endMs: 5, quality: nil)],
    ]
    for turns in invalid {
      do {
        try await store.appendWindow(runID: run.id, speakers: [], turns: turns, audioMs: 1)
        XCTFail("Invalid window accepted")
      } catch { XCTAssertNotNil(error as? SpeakerStore.Error) }
    }
    let stored = try await store.run(id: run.id)
    XCTAssertEqual(stored?.windowCount, 0)
  }

  func testTurnPagesReturnOverlapsInStartOrder() async throws {
    let meeting = try await meeting()
    let run = try await running(meeting)
    let speaker = SpeakerDraft(
      id: UUID(), clusterKey: 0, track: .system, reconciliation: .confident)
    let turns = (0..<25).map {
      TurnDraft(
        speakerID: speaker.id, track: .system, startMs: Int64($0) * 1_000,
        endMs: Int64($0) * 1_000 + 1_500, quality: nil)
    }
    try await store.appendWindow(runID: run.id, speakers: [speaker], turns: turns, audioMs: 30_000)
    var cursor: TurnCursor?
    var seen: [Int64] = []
    repeat {
      let page = try await store.turns(
        runID: run.id, overlapping: 5_200..<12_000, after: cursor, limit: 3)
      seen += page.map(\.startMs)
      cursor = page.last.map { TurnCursor(startMs: $0.startMs, id: $0.id) }
      if page.count < 3 { break }
    } while true
    // Turn 4 (4.0–5.5 s) reaches into the range; turn 12 starts at its end.
    XCTAssertEqual(seen, (4...11).map { Int64($0) * 1_000 })
  }

  // MARK: Naming (T047)

  private func names(_ run: UUID) async throws -> [String?] {
    try await fixture.history.database.read { db in
      try Optional<String>.fetchAll(
        db, sql: "SELECT display_name FROM meeting_speakers WHERE run_id=? ORDER BY first_ms",
        arguments: [run.uuidString])
    }
  }

  /// The dump with every `display_name` blanked, so a rename can be diffed away.
  private static func withoutNames(_ dump: String) -> String {
    dump.replacingOccurrences(
      of: #"display_name:"[^"]*""#, with: "display_name:NULL", options: .regularExpression)
  }

  private func corrections(_ meeting: UUID) async throws -> [Row] {
    try await fixture.history.database.read { db in
      try Row.fetchAll(
        db, sql: "SELECT * FROM speaker_corrections WHERE meeting_id=? ORDER BY created_at, rowid",
        arguments: [meeting.uuidString])
    }
  }

  func testSaveNamesUpdatesEveryNameWithOneRenameCorrectionEachAndTouchesNothingElse()
    async throws
  {
    let meeting = try await meeting()
    let run = try await accepted(meeting)
    let summaries = try await store.speakerSummaries(meetingID: meeting.id)
    XCTAssertEqual(summaries.map(\.anonymousLabel), ["Speaker 1", "You"])
    XCTAssertEqual(summaries.map(\.speechMs), [1_500, 2_000])
    let (remote, local) = (summaries[0].id, summaries[1].id)
    let before = try await dump(run.id)
    let beforeSegments = try await transcripts.page(
      meetingID: meeting.id, finality: .provisional, after: nil, limit: 200)
    try await store.saveNames(
      meetingID: meeting.id, names: [remote: "Ana", local: "  Oliver  "], now: 30)
    let stored = try await names(run.id)
    XCTAssertEqual(stored, ["Ana", "Oliver"], "trimmed")
    let rows = try await corrections(meeting.id)
    XCTAssertEqual(rows.count, 2)
    XCTAssertEqual(rows.map { $0["kind"] as String }, ["rename", "rename"])
    XCTAssertEqual(Set(rows.map { $0["new_value"] as String }), ["Ana", "Oliver"])
    XCTAssertTrue(rows.allSatisfy { ($0["previous_value"] as String?) == nil })
    XCTAssertEqual(rows.map { $0["run_id"] as String }, [run.id.uuidString, run.id.uuidString])
    // Names live on the speaker row only: turns, assignments, clusters and segments are unchanged.
    let after = try await dump(run.id)
    XCTAssertNotEqual(after, before)
    XCTAssertEqual(Self.withoutNames(after), Self.withoutNames(before))
    let afterSegments = try await transcripts.page(
      meetingID: meeting.id, finality: .provisional, after: nil, limit: 200)
    XCTAssertEqual(afterSegments, beforeSegments)
    let diarization = try await store.diarization(meetingID: meeting.id)
    XCTAssertNil(diarization?.currentRunID, "a rename starts no run")
    XCTAssertEqual(diarization?.acceptedRunID, run.id)
    let state = try await store.meetingState(meetingID: meeting.id)
    XCTAssertEqual(state, .succeeded)
    // Unchanged names add no corrections; a blank restores the anonymous label.
    try await store.saveNames(meetingID: meeting.id, names: [remote: "Ana", local: "   "], now: 31)
    let restored = try await names(run.id)
    XCTAssertEqual(restored, ["Ana", nil])
    let more = try await corrections(meeting.id)
    XCTAssertEqual(more.count, 3)
    XCTAssertEqual(more.last?["previous_value"] as String?, "Oliver")
    XCTAssertNil(more.last?["new_value"] as String?)
    let relabeled = try await store.speakerSummaries(meetingID: meeting.id)
    XCTAssertEqual(relabeled.map(\.displayName), ["Ana", nil])
  }

  func testSaveNamesRefusesInvalidNamesAndForeignSpeakersWithoutWriting() async throws {
    let meeting = try await meeting()
    let run = try await accepted(meeting)
    let remote = try await store.speakerSummaries(meetingID: meeting.id)[0].id
    for bad in [String(repeating: "x", count: 81), "Ana\u{7}"] {
      do {
        try await store.saveNames(meetingID: meeting.id, names: [remote: bad], now: 30)
        XCTFail("accepted \(bad.debugDescription)")
      } catch { XCTAssertEqual(error as? SpeakerStore.Error, .invalidDraft("name")) }
    }
    do {
      try await store.saveNames(
        meetingID: meeting.id, names: [remote: "Ana", UUID(): "Bob"], now: 30)
      XCTFail("accepted a speaker of another run")
    } catch { XCTAssertEqual(error as? SpeakerStore.Error, .missingRow) }
    let stored = try await names(run.id)
    XCTAssertEqual(stored, [nil, nil])
    let rows = try await corrections(meeting.id)
    XCTAssertTrue(rows.isEmpty)
  }

  func testNamesPersistAcrossAReopenedStore() async throws {
    let meeting = try await meeting()
    _ = try await accepted(meeting)
    let remote = try await store.speakerSummaries(meetingID: meeting.id)[0].id
    try await store.saveNames(meetingID: meeting.id, names: [remote: "Ana"], now: 30)
    let reopened = SpeakerStore(database: fixture.history.database)
    let summaries = try await reopened.speakerSummaries(meetingID: meeting.id)
    XCTAssertEqual(summaries.map(\.displayName), ["Ana", nil])
  }

  func testNameSuggestionsAreDistinctAcrossMeetingsMostRecentFirst() async throws {
    let first = try await meeting()
    _ = try await accepted(first)
    // One meeting is active at a time; end the first before creating the second.
    try await fixture.store.transition(id: first.id, to: .failed, now: 25, effects: [])
    let second = try await meeting()
    _ = try await accepted(second)
    let firstIDs = try await store.speakerSummaries(meetingID: first.id).map(\.id)
    let secondIDs = try await store.speakerSummaries(meetingID: second.id).map(\.id)
    try await store.saveNames(
      meetingID: first.id, names: [firstIDs[0]: "Ana", firstIDs[1]: "Anders"], now: 30)
    try await store.saveNames(
      meetingID: second.id, names: [secondIDs[0]: "Ana", secondIDs[1]: "Ben"], now: 40)
    let suggestions = try await store.nameSuggestions(prefix: "An", limit: 8)
    XCTAssertEqual(suggestions, ["Ana", "Anders"], "Ana was used again at 40; distinct")
    let none = try await store.nameSuggestions(prefix: "Zed", limit: 8)
    XCTAssertTrue(none.isEmpty)
    let wildcard = try await store.nameSuggestions(prefix: "%", limit: 8)
    XCTAssertTrue(wildcard.isEmpty, "LIKE wildcards are literal")
    let limited = try await store.nameSuggestions(prefix: "", limit: 1)
    XCTAssertEqual(limited, ["Ana"], "most recent first; Ana and Ben tie at 40, then by name")
  }

  func testTheCorrectionCapacityRefusesTheSaveAndWritesNothing() async throws {
    let meeting = try await meeting()
    let run = try await accepted(meeting)
    let remote = try await store.speakerSummaries(meetingID: meeting.id)[0].id
    try await fixture.history.database.write { db in
      let insert = try db.cachedStatement(
        sql: """
          INSERT INTO speaker_corrections (id, meeting_id, run_id, kind, speaker_id, new_value, created_at)
          VALUES (?,?,?,'rename',?,'x',?)
          """)
      for index in 0..<(SpeakerStore.correctionsPerMeeting - 1) {
        try insert.execute(arguments: [
          UUID().uuidString, meeting.id.uuidString, run.id.uuidString, remote.uuidString, index,
        ])
      }
    }
    // One slot left: one change fits, two do not.
    let ids = try await store.speakerSummaries(meetingID: meeting.id).map(\.id)
    do {
      try await store.saveNames(
        meetingID: meeting.id, names: [ids[0]: "Ana", ids[1]: "Ben"], now: 30)
      XCTFail("exceeded the capacity")
    } catch { XCTAssertEqual(error as? SpeakerStore.Error, .correctionCapacity) }
    let stored = try await names(run.id)
    XCTAssertEqual(stored, [nil, nil], "nothing written")
    let untouched = try await count("speaker_corrections")
    XCTAssertEqual(untouched, SpeakerStore.correctionsPerMeeting - 1)
    try await store.saveNames(meetingID: meeting.id, names: [ids[0]: "Ana"], now: 31)
    let full = try await count("speaker_corrections")
    XCTAssertEqual(full, SpeakerStore.correctionsPerMeeting)
    do {
      try await store.saveNames(meetingID: meeting.id, names: [ids[1]: "Ben"], now: 32)
      XCTFail("exceeded the capacity")
    } catch { XCTAssertEqual(error as? SpeakerStore.Error, .correctionCapacity) }
  }

  // MARK: Merge and segment corrections (T056)

  /// Turn, assignment and automatic-assignment evidence, which corrections never touch.
  private func evidence(_ run: UUID) async throws -> String {
    try await fixture.history.database.read { db in
      let turns = try Row.fetchAll(
        db, sql: "SELECT * FROM speaker_turns WHERE run_id=? ORDER BY id",
        arguments: [run.uuidString]
      ).map(\.description).joined(separator: "\n")
      let auto = try Row.fetchAll(
        db,
        sql: """
          SELECT segment_id, auto_kind, auto_speaker_id, top_speaker_id, second_speaker_id,
            top_coverage, second_coverage FROM speaker_assignments WHERE run_id=? ORDER BY segment_id
          """, arguments: [run.uuidString]
      ).map(\.description).joined(separator: "\n")
      return turns + "\n" + auto
    }
  }

  private func speakerRow(_ id: UUID) async throws -> Row {
    try await fixture.history.database.read { db in
      try Row.fetchOne(
        db, sql: "SELECT * FROM meeting_speakers WHERE id=?", arguments: [id.uuidString])!
    }
  }

  func testMergeSetsMergedIntoAtDepthOneAndUnmergeRestoresTheSection() async throws {
    let meeting = try await meeting()
    let run = try await accepted(meeting)
    let ids = try await store.speakerSummaries(meetingID: meeting.id).map(\.id)
    let (remote, local) = (ids[0], ids[1])
    try await store.saveNames(meetingID: meeting.id, names: [local: "Oliver"], now: 29)
    let before = try await evidence(run.id)
    try await store.merge(meetingID: meeting.id, speakerID: local, into: remote, now: 30)
    var row = try await speakerRow(local)
    XCTAssertEqual(row["merged_into"] as String?, remote.uuidString)
    XCTAssertEqual(row["display_name"] as String?, "Oliver", "the name stays on the row")
    XCTAssertEqual(row["color_index"] as Int, 1)
    var summaries = try await store.speakerSummaries(meetingID: meeting.id)
    XCTAssertEqual(summaries.map(\.id), [remote])
    XCTAssertEqual(summaries[0].includes.map(\.id), [local])
    XCTAssertEqual(summaries[0].includes.map(\.anonymousLabel), ["You"])
    var rows = try await corrections(meeting.id)
    XCTAssertEqual(rows.map { $0["kind"] as String }, ["rename", "merge"])
    XCTAssertEqual(rows[1]["speaker_id"] as String?, local.uuidString)
    XCTAssertEqual(rows[1]["target_speaker_id"] as String?, remote.uuidString)
    // A merge into a merged speaker lands on its root, so chains stay at depth 1.
    try await store.correctSegment(
      meetingID: meeting.id, segmentID: meeting.segments[1], to: .newSpeaker, now: 31)
    let manual = try await store.speakerSummaries(meetingID: meeting.id).map(\.id)
      .first { $0 != remote }!
    try await store.merge(meetingID: meeting.id, speakerID: remote, into: manual, now: 32)
    for id in [remote, local] {
      let moved = try await speakerRow(id)
      XCTAssertEqual(moved["merged_into"] as String?, manual.uuidString, "depth 1")
    }
    summaries = try await store.speakerSummaries(meetingID: meeting.id)
    XCTAssertEqual(summaries.map(\.id), [manual])
    XCTAssertEqual(summaries[0].includes.map(\.id), [local, remote], "local first, then remote")
    do {
      try await store.merge(meetingID: meeting.id, speakerID: manual, into: local, now: 33)
      XCTFail("merged a root into its own member")
    } catch { XCTAssertEqual(error as? SpeakerStore.Error, .invalidDraft("merge")) }
    // Unmerge clears only that speaker and marks its merge correction undone.
    try await store.unmerge(meetingID: meeting.id, speakerID: local, now: 40)
    row = try await speakerRow(local)
    XCTAssertNil(row["merged_into"] as String?)
    XCTAssertEqual(row["display_name"] as String?, "Oliver")
    XCTAssertEqual(row["color_index"] as Int, 1, "the earlier name and color are back")
    summaries = try await store.speakerSummaries(meetingID: meeting.id)
    XCTAssertEqual(Set(summaries.map(\.id)), [manual, local])
    rows = try await corrections(meeting.id)
    XCTAssertEqual(rows.last?["kind"] as String?, "unmerge")
    XCTAssertEqual(rows.last?["target_speaker_id"] as String?, manual.uuidString)
    let undone = rows.filter { ($0["undone_at"] as Int64?) != nil }
    XCTAssertEqual(undone.map { $0["speaker_id"] as String? }, [local.uuidString])
    do {
      try await store.unmerge(meetingID: meeting.id, speakerID: local, now: 41)
      XCTFail("unmerged a root")
    } catch { XCTAssertEqual(error as? SpeakerStore.Error, .invalidDraft("unmerge")) }
    let after = try await evidence(run.id)
    XCTAssertEqual(after, before, "turns and automatic assignments never change")
    let diarization = try await store.diarization(meetingID: meeting.id)
    XCTAssertNil(diarization?.currentRunID, "no run was started")
  }

  func testSegmentCorrectionsSetManualColumnsAndKeepTheAutomaticAssignment() async throws {
    let meeting = try await meeting()
    let run = try await accepted(meeting)
    let ids = try await store.speakerSummaries(meetingID: meeting.id).map(\.id)
    let (remote, local) = (ids[0], ids[1])
    let before = try await evidence(run.id)
    // Segment 0 was Speaker 1: move it to You, then Unknown, then a new speaker.
    let toLocal = try await store.correctSegment(
      meetingID: meeting.id, segmentID: meeting.segments[0], to: .speaker(local), now: 30)
    XCTAssertEqual(toLocal, local)
    let toUnknown = try await store.correctSegment(
      meetingID: meeting.id, segmentID: meeting.segments[0], to: .unknown, now: 31)
    XCTAssertNil(toUnknown)
    let created = try await store.correctSegment(
      meetingID: meeting.id, segmentID: meeting.segments[2], to: .newSpeaker, now: 32)
    let new = try XCTUnwrap(created)
    let manual = try await speakerRow(new)
    XCTAssertNil(manual["run_id"] as String?)
    XCTAssertEqual(manual["origin"] as String, "manual")
    XCTAssertNil(manual["track"] as String?)
    XCTAssertEqual(manual["source"] as String, "remote")
    XCTAssertEqual(manual["label_ordinal"] as Int, 2, "after Speaker 1")
    XCTAssertEqual(manual["color_index"] as Int, 2, "after the run's two colors")
    XCTAssertEqual(manual["first_ms"] as Int64, 2_000)
    XCTAssertEqual(manual["speech_ms"] as Int64, 0, "no turn evidence")
    let assignments = try await fixture.history.database.read { db in
      try Row.fetchAll(
        db,
        sql: """
          SELECT a.auto_kind, a.auto_speaker_id, a.manual_kind, a.manual_speaker_id, a.manual_at
          FROM speaker_assignments a JOIN transcript_segments s ON s.id=a.segment_id
          WHERE a.run_id=? ORDER BY s.ordinal
          """, arguments: [run.id.uuidString])
    }
    XCTAssertEqual(assignments[0]["auto_kind"] as String, "speaker")
    XCTAssertEqual(assignments[0]["auto_speaker_id"] as String?, remote.uuidString)
    XCTAssertEqual(assignments[0]["manual_kind"] as String?, "unknown")
    XCTAssertNil(assignments[0]["manual_speaker_id"] as String?)
    XCTAssertEqual(assignments[0]["manual_at"] as Int64?, 31)
    XCTAssertNil(assignments[1]["manual_kind"] as String?, "the ambiguous row is untouched")
    XCTAssertEqual(assignments[2]["auto_kind"] as String, "unknown")
    XCTAssertEqual(assignments[2]["manual_kind"] as String?, "speaker")
    XCTAssertEqual(assignments[2]["manual_speaker_id"] as String?, new.uuidString)
    let rows = try await corrections(meeting.id)
    XCTAssertEqual(rows.map { $0["kind"] as String }, ["segment", "segment", "segment"])
    XCTAssertEqual(rows[0]["segment_id"] as String?, meeting.segments[0].uuidString)
    XCTAssertEqual(rows[0]["speaker_id"] as String?, remote.uuidString, "what it showed before")
    XCTAssertEqual(rows[0]["target_speaker_id"] as String?, local.uuidString)
    XCTAssertEqual(rows[1]["speaker_id"] as String?, local.uuidString)
    XCTAssertNil(rows[1]["target_speaker_id"] as String?)
    XCTAssertEqual(rows[1]["new_value"] as String?, "unknown")
    XCTAssertEqual(rows[2]["previous_value"] as String?, "unknown")
    XCTAssertEqual(rows[2]["target_speaker_id"] as String?, new.uuidString)
    let after = try await evidence(run.id)
    XCTAssertEqual(after, before, "turns and automatic assignments never change")
    // The transcript shows the manual label with the Edited marker, and the header
    // counts the new speaker; a reopened store sees all of it (SC-007).
    let reopened = TranscriptStore(database: fixture.history.database)
    let labels = try await reopened.labeledPage(
      meetingID: meeting.id, finality: .provisional, after: nil, limit: 200)
    XCTAssertTrue(labels.allSatisfy { $0.label == nil }, "provisional rows carry no labels")
    let speakers = try await SpeakerStore(database: fixture.history.database).speakerSummaries(
      meetingID: meeting.id)
    XCTAssertEqual(speakers.map(\.id), [remote, local, new])
    XCTAssertEqual(speakers[2].anonymousLabel, "Speaker 2")
    do {
      try await store.correctSegment(
        meetingID: meeting.id, segmentID: UUID(), to: .unknown, now: 33)
      XCTFail("corrected a row without an assignment")
    } catch { XCTAssertEqual(error as? SpeakerStore.Error, .missingRow) }
    do {
      try await store.correctSegment(
        meetingID: meeting.id, segmentID: meeting.segments[0], to: .speaker(UUID()), now: 33)
      XCTFail("assigned a speaker of another meeting")
    } catch { XCTAssertEqual(error as? SpeakerStore.Error, .missingRow) }
  }
}
