import GRDB
import XCTest

@testable import LocalFlow

final class MeetingStoreTests: XCTestCase {
  private var fixture: MeetingTestStore!
  private var store: MeetingStore { fixture.store }
  private let now: Int64 = 1_700_000_000_000

  override func setUpWithError() throws { fixture = try MeetingTestStore.make() }
  override func tearDown() { fixture.cleanup() }

  // MARK: Helpers

  private func tracks(for meeting: UUID) -> [MeetingTrack] {
    [
      MeetingTrack(
        id: UUID(), meetingID: meeting, kind: .microphone, channelCount: 1,
        bitrate: MeetingTrackKind.microphone.bitrate),
      MeetingTrack(
        id: UUID(), meetingID: meeting, kind: .system, channelCount: 2,
        bitrate: MeetingTrackKind.system.bitrate),
    ]
  }

  private func segment(
    _ track: MeetingTrack, sequence: Int = 1, offset: Int64 = 0, reason: SegmentOpenReason = .start,
    at: Int64? = nil
  ) -> MeetingSegment {
    MeetingSegment(
      id: UUID(), trackID: track.id, sequence: sequence,
      relativePath: SegmentHandle.relativePath(
        meetingID: track.meetingID, kind: track.kind, sequence: sequence, open: true),
      startOffsetMs: offset, startedAt: at ?? now, hostStartNs: 1, openReason: reason)
  }

  /// created → preparing with two tracks; returns the meeting and its tracks.
  @discardableResult
  private func makePreparing(at time: Int64? = nil) async throws -> (Meeting, [MeetingTrack]) {
    let created = try await store.create(now: time ?? now)
    let tracks = tracks(for: created.id)
    let meeting = try await store.transition(
      id: created.id, to: .preparing, now: time ?? now, effects: [.insertTracks(tracks)])
    return (meeting, tracks)
  }

  /// A full start → stop with open + finalized segments per track.
  private func makeCompleted(at time: Int64? = nil, seconds: Int64 = 60) async throws -> Meeting {
    let start = time ?? now
    let (meeting, tracks) = try await makePreparing(at: start)
    let mic = segment(tracks[0], at: start)
    let sys = segment(tracks[1], at: start)
    try await store.transition(
      id: meeting.id, to: .recording, now: start,
      effects: [.setStartedAt(start), .openSegment(mic), .openSegment(sys)])
    let stop = start + seconds * 1_000
    try await store.transition(
      id: meeting.id, to: .finalizing, now: stop, effects: [.setStoppedAt(stop)])
    for (segment, track) in [(mic, tracks[0]), (sys, tracks[1])] {
      try await store.finalizeSegment(
        id: segment.id, durationMs: seconds * 1_000, byteSize: 1_000,
        relativePath: String(segment.relativePath.dropLast(5)), closeReason: .stop,
        droppedFrames: 0, now: stop)
      try await store.markTrackFinalized(id: track.id, now: stop)
    }
    return try await store.transition(
      id: meeting.id, to: .completed, now: stop,
      effects: [.setCompletedAt(stop), .finalizationStage(.both), .computeDurationWarnings])
  }

  // MARK: Migration

  func testMigrationCreatesSixTablesWithoutTouchingEarlierTables() throws {
    try fixture.history.database.read { db in
      for table in [
        "meetings", "meeting_tracks", "meeting_segments", "meeting_pauses", "meeting_notes",
        "meeting_recovery_outcomes",
      ] {
        XCTAssertTrue(try db.tableExists(table), table)
      }
      // Feature 001–003 tables keep their columns.
      XCTAssertEqual(
        Set(try db.columns(in: "transcriptions").map(\.name)).isSuperset(of: [
          "id", "text", "created_at", "rewrite_state", "delivered_source",
        ]), true)
      XCTAssertEqual(try db.columns(in: "vocabulary_entries").count, 5)
      let meetingColumns = try db.columns(in: "meetings").map(\.name)
      XCTAssertEqual(
        meetingColumns,
        [
          "id", "state", "title", "created_at", "started_at", "stopped_at", "completed_at",
          "wall_clock_ms", "recorded_ms", "finalization_stage", "failure_reason", "failure_detail",
          "updated_at", "revision", "language",
        ])
      let indexes = try String.fetchAll(
        db, sql: "SELECT name FROM sqlite_master WHERE type='index' AND tbl_name LIKE 'meeting%'")
      for name in [
        "meetings_created_at_id", "meetings_active", "meeting_pauses_open",
        "meeting_tracks_meeting_type", "meeting_segments_track_sequence",
      ] {
        XCTAssertTrue(indexes.contains(name), name)
      }
      // No BLOB column anywhere in the meeting tables (media lives in files).
      for table in [
        "meetings", "meeting_tracks", "meeting_segments", "meeting_pauses", "meeting_notes",
        "meeting_recovery_outcomes",
      ] {
        for column in try db.columns(in: table) {
          XCTAssertNotEqual(column.type.uppercased(), "BLOB", "\(table).\(column.name)")
        }
      }
      // Cascades on every child.
      for table in [
        "meeting_tracks", "meeting_pauses", "meeting_notes", "meeting_recovery_outcomes",
      ] {
        let keys = try db.foreignKeys(on: table)
        XCTAssertEqual(keys.first?.destinationTable, "meetings", table)
      }
      XCTAssertEqual(
        try db.foreignKeys(on: "meeting_segments").first?.destinationTable, "meeting_tracks")
      let cascades = try Int.fetchOne(
        db,
        sql:
          "SELECT count(*) FROM sqlite_master WHERE type='table' AND name IN ('meeting_tracks','meeting_segments','meeting_pauses','meeting_notes','meeting_recovery_outcomes') AND sql LIKE '%ON DELETE CASCADE%'"
      )
      XCTAssertEqual(cascades, 5)
    }
  }

  func testPre004DatabaseOpensAndListsZeroMeetings() async throws {
    let path = fixture.directory.appendingPathComponent("old.sqlite").path
    do {
      let old = try TranscriptionStore(path: path)
      try await old.database.write { db in
        for table in [
          "analysis_overlays", "analysis_sources", "analysis_items", "analysis_topics",
          "analysis_summaries", "meeting_analysis", "analysis_runs",
          "rejected_candidates", "match_candidates", "identity_assignments",
          "meeting_identification", "identification_runs", "voice_samples", "known_speakers",
          "speaker_corrections", "speaker_assignments", "speaker_turns", "meeting_speakers",
          "meeting_diarization", "diarization_runs",
          "transcript_live_gaps", "transcript_segments", "meeting_transcriptions",
          "transcript_usage",
          "meeting_recovery_outcomes", "meeting_notes", "meeting_pauses", "meeting_segments",
          "meeting_tracks", "meetings",
        ] {
          try db.drop(table: table)
        }
        try db.execute(
          sql:
            "DELETE FROM grdb_migrations WHERE identifier IN ('meetings-v5','transcripts-v6','speakers-v7','identities-v8','intelligence-v9')"
        )
      }
    }
    let reopened = try TranscriptionStore(path: path)
    let store = MeetingStore(history: reopened, root: fixture.root)
    let page = try await store.page(before: nil, limit: 20)
    XCTAssertEqual(page.count, 0)
    let active = try await store.activeMeeting()
    XCTAssertNil(active)
    let rows = try await store.activeStateRows()
    XCTAssertEqual(rows.count, 0)
  }

  /// Czech was removed from the meeting languages: migration v12 clears a stored
  /// 'czech' to NULL (the Settings language) and keeps the supported ones.
  func testRemovedMeetingLanguageMigratesToSettingsDefault() async throws {
    let path = fixture.directory.appendingPathComponent("czech.sqlite").path
    let queue = try DatabaseQueue(path: path)
    try HistoryMigrations.migrator().migrate(queue, upTo: "app-context-v11")
    let czech = UUID()
    let slovak = UUID()
    try await queue.write { db in
      for (id, language) in [(czech, "czech"), (slovak, "slovak")] {
        try db.execute(
          sql: """
            INSERT INTO meetings (id,state,created_at,updated_at,language)
            VALUES (?,'completed',1,1,?)
            """, arguments: [id.uuidString, language])
      }
    }
    try queue.close()
    let reopened = try TranscriptionStore(path: path)
    let store = MeetingStore(history: reopened, root: fixture.root)
    let czechMeeting = try await store.meeting(id: czech)
    XCTAssertNotNil(czechMeeting)
    XCTAssertNil(czechMeeting?.language)
    let slovakMeeting = try await store.meeting(id: slovak)
    XCTAssertEqual(slovakMeeting?.language, .slovak)
    let stored = try await reopened.database.read { db in
      try String.fetchAll(db, sql: "SELECT language FROM meetings WHERE language IS NOT NULL")
    }
    XCTAssertEqual(stored, ["slovak"])
    XCTAssertNil(MeetingLanguage(storedValue: "czech"))
    XCTAssertEqual(MeetingLanguage(storedValue: "english"), .english)
  }

  // MARK: Create and transition

  func testCreateInsertsCreatedRowWithEmptyNotesAndRefusesASecondActive() async throws {
    let meeting = try await store.create(now: now)
    XCTAssertEqual(meeting.state, .created)
    XCTAssertEqual(meeting.createdAt, now)
    let notes = try await store.notes(meetingID: meeting.id)
    XCTAssertEqual(notes?.text, "")
    XCTAssertEqual(notes?.revision, 0)
    try await fixture.history.database.read { db in
      XCTAssertEqual(
        try String.fetchOne(
          db, sql: "SELECT author FROM meeting_notes WHERE meeting_id=?",
          arguments: [meeting.id.uuidString]),
        "user")
    }
    do {
      _ = try await store.create(now: now + 1)
      XCTFail("second active meeting")
    } catch { XCTAssertEqual(error as? MeetingStore.Error, .alreadyActive(meeting.id)) }
    // Two concurrent creates yield exactly one row.
    let second = MeetingStore(history: fixture.history, root: fixture.root)
    let other = MeetingStore(history: fixture.history, root: fixture.root)
    try await store.transition(id: meeting.id, to: .failed, now: now, effects: [])
    let base = now
    async let a = second.create(now: base + 2)
    async let b = other.create(now: base + 3)
    var created = 0
    do {
      _ = try await a
      created += 1
    } catch {}
    do {
      _ = try await b
      created += 1
    } catch {}
    XCTAssertEqual(created, 1)
    let page = try await store.page(before: nil, limit: 20)
    XCTAssertEqual(page.count, 2)
  }

  func testCreateInsertsTheDiarizationRowWithTheMeeting() async throws {
    let meeting = try await store.create(now: now)
    let now = now
    try await fixture.history.database.read { db in
      let row = try XCTUnwrap(
        Row.fetchOne(
          db, sql: "SELECT * FROM meeting_diarization WHERE meeting_id=?",
          arguments: [meeting.id.uuidString]))
      XCTAssertNil(row["accepted_run_id"] as String?)
      XCTAssertNil(row["current_run_id"] as String?)
      XCTAssertEqual(row["in_room"] as Int?, 0)
      XCTAssertEqual(row["updated_at"] as Int64?, now)
      XCTAssertEqual(row["revision"] as Int64?, 0)
    }
    // A refused create writes neither row.
    _ = try? await store.create(now: now + 1)
    let rows = try await fixture.history.database.read { db in
      try Int.fetchOne(db, sql: "SELECT count(*) FROM meeting_diarization")
    }
    XCTAssertEqual(rows, 1)
  }

  /// Feature 010 (T017): the `meeting_identification` row is created in the same
  /// transaction as the meeting, with no run pointers.
  func testCreateInsertsTheIdentificationRowWithTheMeeting() async throws {
    let meeting = try await store.create(now: now)
    let now = now
    try await fixture.history.database.read { db in
      let row = try XCTUnwrap(
        Row.fetchOne(
          db, sql: "SELECT * FROM meeting_identification WHERE meeting_id=?",
          arguments: [meeting.id.uuidString]))
      XCTAssertNil(row["accepted_run_id"] as String?)
      XCTAssertNil(row["current_run_id"] as String?)
      XCTAssertEqual(row["updated_at"] as Int64?, now)
    }
    _ = try? await store.create(now: now + 1)
    let rows = try await fixture.history.database.read { db in
      try Int.fetchOne(db, sql: "SELECT count(*) FROM meeting_identification")
    }
    XCTAssertEqual(rows, 1)
  }

  /// Feature 011 (T021): the `meeting_analysis` row is created in the same
  /// transaction as the meeting, with no run pointers.
  func testCreateInsertsTheAnalysisRowWithTheMeeting() async throws {
    let meeting = try await store.create(now: now)
    let now = now
    try await fixture.history.database.read { db in
      let row = try XCTUnwrap(
        Row.fetchOne(
          db, sql: "SELECT * FROM meeting_analysis WHERE meeting_id=?",
          arguments: [meeting.id.uuidString]))
      XCTAssertNil(row["accepted_run_id"] as String?)
      XCTAssertNil(row["current_run_id"] as String?)
      XCTAssertNil(row["accepted_evidence_version"] as String?)
      XCTAssertNil(row["auto_restarted_at"] as Int64?)
      XCTAssertEqual(row["updated_at"] as Int64?, now)
      XCTAssertEqual(row["revision"] as Int64?, 0)
    }
    _ = try? await store.create(now: now + 1)
    let rows = try await fixture.history.database.read { db in
      try Int.fetchOne(db, sql: "SELECT count(*) FROM meeting_analysis")
    }
    XCTAssertEqual(rows, 1)
  }

  func testTransitionAppliesSideEffectsInOneWriteAndRejectsInvalidPairsWithoutWriting() async throws
  {
    let (meeting, tracks) = try await makePreparing()
    XCTAssertEqual(meeting.state, .preparing)
    let loaded = try await store.detail(id: meeting.id)
    let detail = try XCTUnwrap(loaded)
    XCTAssertEqual(detail.tracks.map(\.track.kind), [.microphone, .system])
    XCTAssertEqual(detail.tracks.map(\.track.codec), ["aac_lc", "aac_lc"])
    XCTAssertEqual(detail.tracks.map(\.track.container), ["adts", "adts"])
    XCTAssertEqual(detail.tracks.map(\.track.sampleRate), [48_000, 48_000])
    XCTAssertEqual(detail.tracks.map(\.track.channelCount), [1, 2])
    XCTAssertEqual(detail.tracks.map(\.track.bitrate), [64_000, 96_000])
    do {
      try await store.transition(
        id: meeting.id, to: .completed, now: now, effects: [.setCompletedAt(now)])
      XCTFail("preparing → completed")
    } catch {
      XCTAssertEqual(
        error as? MeetingStore.Error, .invalidTransition(from: .preparing, to: .completed))
    }
    let unchangedRow = try await store.meeting(id: meeting.id)
    let unchanged = try XCTUnwrap(unchangedRow)
    XCTAssertEqual(unchanged.state, .preparing)
    XCTAssertNil(unchanged.completedAt)
    XCTAssertEqual(unchanged.updatedAt, now)
    // A third track violates the unique (meeting_id, type) constraint.
    do {
      try await store.transition(
        id: meeting.id, to: .recording, now: now,
        effects: [.insertTracks([tracks[0]])])
      XCTFail("duplicate track")
    } catch {}
    let still = try await store.meeting(id: meeting.id)
    XCTAssertEqual(still?.state, .preparing)
  }

  #if DEBUG
    func testFailedWriteInsideTransitionLeavesTheRowUnchanged() async throws {
      let (meeting, _) = try await makePreparing()
      do {
        try await store.transition(
          id: meeting.id, to: .recording, now: now + 5,
          effects: [.setStartedAt(now + 5), .injectedFailure])
        XCTFail("injected failure")
      } catch { XCTAssertEqual(error as? MeetingStore.Error, .injectedFailure) }
      let unchangedRow = try await store.meeting(id: meeting.id)
      let unchanged = try XCTUnwrap(unchangedRow)
      XCTAssertEqual(unchanged.state, .preparing)
      XCTAssertNil(unchanged.startedAt)
      XCTAssertEqual(unchanged.updatedAt, now)
    }
  #endif

  // MARK: Segments

  func testOpenSegmentRefusesSecondOpenPerTrackAndBadPaths() async throws {
    let (_, tracks) = try await makePreparing()
    let first = try await store.openSegment(segment(tracks[0]), now: now)
    XCTAssertEqual(first.state, .open)
    do {
      _ = try await store.openSegment(segment(tracks[0], sequence: 2), now: now)
      XCTFail("second open segment")
    } catch { XCTAssertEqual(error as? MeetingStore.Error, .segmentAlreadyOpen) }
    for bad in ["/abs/mic-0001.aac.part", "../x/mic-0001.aac.part", "a/../b.aac", ""] {
      var invalid = segment(tracks[1])
      invalid.relativePath = bad
      do {
        _ = try await store.openSegment(invalid, now: now)
        XCTFail(bad)
      } catch { XCTAssertEqual(error as? MeetingStore.Error, .invalidPath, bad) }
    }
  }

  func testProgressAndFinalizeUpdateSegmentAndTrackTotals() async throws {
    let (meeting, tracks) = try await makePreparing()
    let mic = try await store.openSegment(segment(tracks[0]), now: now)
    try await store.transition(
      id: meeting.id, to: .recording, now: now, effects: [.setStartedAt(now)])
    try await store.progressSegment(
      id: mic.id, durationMs: 5_000, byteSize: 40_000, droppedFrames: 3, now: now + 5_000)
    var loaded = try await store.detail(id: meeting.id)
    var detail = try XCTUnwrap(loaded)
    var segment = try XCTUnwrap(detail.tracks[0].segments.first)
    XCTAssertEqual(segment.durationMs, 5_000)
    XCTAssertEqual(segment.byteSize, 40_000)
    XCTAssertEqual(segment.droppedFrames, 3)
    XCTAssertEqual(detail.tracks[0].track.droppedFrames, 3)
    XCTAssertEqual(detail.tracks[0].track.totalDurationMs, 0, "open segments do not count")
    XCTAssertEqual(detail.meeting.wallClockMs, 5_000)
    XCTAssertEqual(detail.meeting.recordedMs, 5_000)
    XCTAssertEqual(detail.meeting.updatedAt, now + 5_000)
    try await store.finalizeSegment(
      id: mic.id, durationMs: 9_000, byteSize: 70_000,
      relativePath: String(mic.relativePath.dropLast(5)), closeReason: .stop, droppedFrames: 4,
      now: now + 9_000)
    loaded = try await store.detail(id: meeting.id)
    detail = try XCTUnwrap(loaded)
    segment = try XCTUnwrap(detail.tracks[0].segments.first)
    XCTAssertEqual(segment.state, .finalized)
    XCTAssertTrue(segment.relativePath.hasSuffix("mic-0001.aac"), segment.relativePath)
    XCTAssertEqual(segment.closeReason, .stop)
    XCTAssertEqual(detail.tracks[0].track.totalDurationMs, 9_000)
    XCTAssertEqual(detail.tracks[0].track.totalBytes, 70_000)
    XCTAssertEqual(detail.tracks[0].track.droppedFrames, 4)
  }

  func testCaptureLossWarnsEvenWhenTrackDurationMatchesMeeting() async throws {
    let (meeting, tracks) = try await makePreparing()
    let mic = segment(tracks[0])
    let sys = segment(tracks[1])
    try await store.transition(
      id: meeting.id, to: .recording, now: now,
      effects: [.setStartedAt(now), .openSegment(mic), .openSegment(sys)])
    let stop = now + 60_000
    try await store.transition(
      id: meeting.id, to: .finalizing, now: stop, effects: [.setStoppedAt(stop)])
    for (segment, droppedFrames) in [(mic, Int64(1)), (sys, Int64(0))] {
      try await store.finalizeSegment(
        id: segment.id, durationMs: 60_000, byteSize: 1_000,
        relativePath: String(segment.relativePath.dropLast(5)), closeReason: .stop,
        droppedFrames: droppedFrames, now: stop)
    }
    try await store.transition(
      id: meeting.id, to: .completed, now: stop,
      effects: [.setCompletedAt(stop), .computeDurationWarnings])
    let loaded = try await store.detail(id: meeting.id)
    let detail = try XCTUnwrap(loaded)
    let microphone = try XCTUnwrap(detail.tracks.first { $0.track.kind == .microphone })
    let system = try XCTUnwrap(detail.tracks.first { $0.track.kind == .system })
    XCTAssertEqual(microphone.track.totalDurationMs, detail.meeting.recordedMs)
    XCTAssertTrue(microphone.track.durationWarning, "Even one lost frame must remain visible")
    XCTAssertFalse(system.track.durationWarning)
  }

  func testLateProgressPreservesFinalizedSegmentAndTrackTotals() async throws {
    let meeting = try await makeCompleted()
    let beforeLoaded = try await store.detail(id: meeting.id)
    let before = try XCTUnwrap(beforeLoaded)
    let microphone = try XCTUnwrap(before.tracks.first { $0.track.kind == .microphone })
    let segment = try XCTUnwrap(microphone.segments.first)
    try await store.progressSegment(
      id: segment.id, durationMs: 5_000, byteSize: 40, droppedFrames: 100,
      now: now + 120_000)
    let afterLoaded = try await store.detail(id: meeting.id)
    let after = try XCTUnwrap(afterLoaded)
    let afterMic = try XCTUnwrap(after.tracks.first { $0.track.kind == .microphone })
    let afterSegment = try XCTUnwrap(afterMic.segments.first)
    XCTAssertEqual(afterSegment.state, .finalized)
    XCTAssertEqual(afterSegment.durationMs, segment.durationMs)
    XCTAssertEqual(afterSegment.byteSize, segment.byteSize)
    XCTAssertEqual(afterSegment.droppedFrames, segment.droppedFrames)
    XCTAssertEqual(afterSegment.relativePath, segment.relativePath)
    XCTAssertEqual(afterMic.track.totalDurationMs, microphone.track.totalDurationMs)
    XCTAssertEqual(afterMic.track.totalBytes, microphone.track.totalBytes)
    XCTAssertEqual(afterMic.track.droppedFrames, microphone.track.droppedFrames)
    XCTAssertEqual(after.meeting.recordedMs, before.meeting.recordedMs)
    XCTAssertEqual(after.meeting.state, .completed)
  }

  func testDurationWarningUsesMaxOnePercentOrTwoSecondsAtStop() async throws {
    // 60 s recorded; a 58.5 s track is inside 2 s, a 57 s track is not.
    let meeting = try await makeCompleted()
    let loaded = try await store.detail(id: meeting.id)
    let detail = try XCTUnwrap(loaded)
    XCTAssertEqual(detail.meeting.recordedMs, 60_000)
    XCTAssertFalse(detail.tracks[0].track.durationWarning)
    let (second, tracks) = try await makePreparing(at: now + 100_000)
    let start = now + 100_000
    let mic = segment(tracks[0], at: start)
    let sys = segment(tracks[1], at: start)
    try await store.transition(
      id: second.id, to: .recording, now: start,
      effects: [.setStartedAt(start), .openSegment(mic), .openSegment(sys)])
    try await store.transition(
      id: second.id, to: .finalizing, now: start + 60_000, effects: [.setStoppedAt(start + 60_000)])
    try await store.finalizeSegment(
      id: mic.id, durationMs: 58_500, byteSize: 1,
      relativePath: String(mic.relativePath.dropLast(5)),
      closeReason: .stop, droppedFrames: 0, now: start + 60_000)
    try await store.finalizeSegment(
      id: sys.id, durationMs: 57_000, byteSize: 1,
      relativePath: String(sys.relativePath.dropLast(5)),
      closeReason: .stop, droppedFrames: 0, now: start + 60_000)
    try await store.transition(
      id: second.id, to: .completed, now: start + 60_000,
      effects: [.setCompletedAt(start + 60_000), .computeDurationWarnings])
    let afterLoaded = try await store.detail(id: second.id)
    let after = try XCTUnwrap(afterLoaded)
    XCTAssertFalse(after.tracks[0].track.durationWarning)
    XCTAssertTrue(after.tracks[1].track.durationWarning)
    // Above 200 s the 1 % rule is wider than 2 s: 300 s recorded tolerates 2.9 s.
    let long = try await makeCompleted(at: now + 1_000_000, seconds: 300)
    let longLoaded = try await store.detail(id: long.id)
    XCTAssertEqual(longLoaded?.meeting.recordedMs, 300_000)
  }

  // MARK: Pauses

  func testOpenPauseRefusesSecondAndClosePauseRecordsClosedBy() async throws {
    let (meeting, _) = try await makePreparing()
    try await store.transition(
      id: meeting.id, to: .recording, now: now, effects: [.setStartedAt(now)])
    let pause = try await store.openPause(meetingID: meeting.id, reason: .user, at: now + 10_000)
    do {
      _ = try await store.openPause(meetingID: meeting.id, reason: .systemSleep, at: now + 11_000)
      XCTFail("second open pause")
    } catch { XCTAssertEqual(error as? MeetingStore.Error, .pauseAlreadyOpen) }
    try await store.closePause(id: pause.id, at: now + 40_000, closedBy: .resume)
    let loaded = try await store.detail(id: meeting.id)
    let detail = try XCTUnwrap(loaded)
    XCTAssertEqual(detail.pauses.count, 1)
    XCTAssertEqual(detail.pauses[0].endedAt, now + 40_000)
    XCTAssertEqual(detail.pauses[0].closedBy, .resume)
    XCTAssertEqual(detail.pauses[0].reason, .user)
    XCTAssertEqual(detail.meeting.wallClockMs, 40_000)
    XCTAssertEqual(detail.meeting.recordedMs, 10_000)
  }

  // MARK: Notes and title

  func testSaveNotesEnforcesSizeRevisionAndBumpsRevision() async throws {
    let meeting = try await store.create(now: now)
    let first = try await store.saveNotes(
      meetingID: meeting.id, text: "hello", revision: 0, now: now + 1)
    XCTAssertEqual(first, 1)
    do {
      _ = try await store.saveNotes(meetingID: meeting.id, text: "stale", revision: 0, now: now + 2)
      XCTFail("stale revision")
    } catch { XCTAssertEqual(error as? MeetingStore.Error, .staleRevision) }
    let notesRow = try await store.notes(meetingID: meeting.id)
    let notes = try XCTUnwrap(notesRow)
    XCTAssertEqual(notes.text, "hello")
    XCTAssertEqual(notes.updatedAt, now + 1)
    let huge = String(repeating: "x", count: MeetingNotes.maximumBytes + 1)
    do {
      _ = try await store.saveNotes(meetingID: meeting.id, text: huge, revision: 1, now: now + 3)
      XCTFail("notes too large")
    } catch { XCTAssertEqual(error as? MeetingStore.Error, .notesTooLarge) }
    let exact = String(repeating: "y", count: MeetingNotes.maximumBytes)
    let exactRevision = try await store.saveNotes(
      meetingID: meeting.id, text: exact, revision: 1, now: now + 4)
    XCTAssertEqual(exactRevision, 2)
  }

  func testSetTitleEnforcesByteLimitAndRevision() async throws {
    let meeting = try await store.create(now: now)
    let revision = try await store.setTitle(
      meetingID: meeting.id, title: "Standup", revision: 0, now: now)
    XCTAssertEqual(revision, 1)
    let titled = try await store.meeting(id: meeting.id)
    XCTAssertEqual(titled?.title, "Standup")
    do {
      _ = try await store.setTitle(
        meetingID: meeting.id, title: String(repeating: "é", count: 129), revision: 1, now: now)
      XCTFail("title too large")
    } catch { XCTAssertEqual(error as? MeetingStore.Error, .titleTooLarge) }
    do {
      _ = try await store.setTitle(meetingID: meeting.id, title: "x", revision: 0, now: now)
      XCTFail("stale revision")
    } catch { XCTAssertEqual(error as? MeetingStore.Error, .staleRevision) }
    let cleared = try await store.setTitle(
      meetingID: meeting.id, title: "   ", revision: 1, now: now)
    XCTAssertEqual(cleared, 2)
    let untitled = try await store.meeting(id: meeting.id)
    XCTAssertNil(untitled?.title)
  }

  // MARK: Paging and detail

  func testPageIsNewestFirstClampedToTwentyAndStableAcrossEqualCreatedAt() async throws {
    var ids: [UUID] = []
    for index in 0..<45 {
      let created = try await store.create(now: now + Int64(index / 3))  // three per timestamp
      try await store.transition(id: created.id, to: .failed, now: now, effects: [])
      ids.append(created.id)
    }
    let first = try await store.page(before: nil, limit: 100)
    XCTAssertEqual(first.count, 20)
    var seen: [UUID] = first.map(\.id)
    var cursor = MeetingCursor(createdAt: first.last!.createdAt, id: first.last!.id)
    while true {
      let page = try await store.page(before: cursor, limit: 20)
      guard let last = page.last else { break }
      seen.append(contentsOf: page.map(\.id))
      cursor = MeetingCursor(createdAt: last.createdAt, id: last.id)
    }
    XCTAssertEqual(seen.count, 45)
    XCTAssertEqual(Set(seen).count, 45, "every row exactly once across equal created_at boundaries")
    let ordered = try await store.page(before: nil, limit: 5)
    for pair in zip(ordered, ordered.dropFirst()) {
      XCTAssertTrue(
        pair.0.createdAt > pair.1.createdAt
          || (pair.0.createdAt == pair.1.createdAt && pair.0.id.uuidString > pair.1.id.uuidString))
    }
  }

  func testDetailRoundTripsEveryColumnAndActiveRowsListExactlyActiveStates() async throws {
    let (meeting, tracks) = try await makePreparing()
    let mic = segment(tracks[0])
    try await store.transition(
      id: meeting.id, to: .recording, now: now + 1,
      effects: [.setStartedAt(now + 1), .openSegment(mic)])
    let pause = try await store.openPause(
      meetingID: meeting.id, reason: .systemSleep, at: now + 5_000)
    _ = try await store.saveNotes(
      meetingID: meeting.id, text: "note", revision: 0, now: now + 6_000)
    _ = try await store.setTitle(
      meetingID: meeting.id, title: "Title", revision: 0, now: now + 6_000)
    try await store.markSegmentUnrecoverable(
      id: mic.id, reason: .unrecoverableMedia, note: "bytes=3", now: now + 7_000)
    try await store.markTrackFailed(id: tracks[1].id, reason: .streamStopped, at: now + 8_000)
    let outcome = RecoveryOutcome(
      meetingID: meeting.id, ranAt: now + 9_000, foundState: .recording, foundStage: .mic,
      segmentsRecovered: 1, segmentsUnrecoverable: 2, segmentsMissing: 3, pauseClosed: true,
      bytesTruncated: 17, summary: "summary")
    try await store.recordOutcome(outcome)
    let activeRows = try await store.activeStateRows()
    XCTAssertEqual(activeRows.map(\.id), [meeting.id])
    let loaded = try await store.detail(id: meeting.id)
    let detail = try XCTUnwrap(loaded)
    XCTAssertEqual(detail.meeting.title, "Title")
    XCTAssertEqual(detail.meeting.startedAt, now + 1)
    XCTAssertEqual(detail.meeting.state, .recording)
    XCTAssertEqual(detail.meeting.revision, 1)
    XCTAssertEqual(detail.notes.text, "note")
    XCTAssertEqual(detail.notes.revision, 1)
    XCTAssertEqual(
      detail.pauses,
      [
        PauseInterval(
          id: pause.id, meetingID: meeting.id, startedAt: now + 5_000, endedAt: nil,
          reason: .systemSleep, closedBy: nil)
      ])
    let micDetail = try XCTUnwrap(detail.track(.microphone))
    XCTAssertEqual(micDetail.segments.count, 1)
    XCTAssertEqual(micDetail.segments[0].state, .unrecoverable)
    XCTAssertEqual(micDetail.segments[0].failureReason, .unrecoverableMedia)
    XCTAssertEqual(micDetail.segments[0].recoveryNote, "bytes=3")
    XCTAssertEqual(micDetail.segments[0].openReason, .start)
    XCTAssertEqual(micDetail.segments[0].hostStartNs, 1)
    XCTAssertEqual(micDetail.segments[0].startedAt, now)
    let sysDetail = try XCTUnwrap(detail.track(.system))
    XCTAssertEqual(sysDetail.track.health, .failed)
    XCTAssertEqual(sysDetail.track.failureReason, .streamStopped)
    XCTAssertEqual(sysDetail.track.failedAt, now + 8_000)
    XCTAssertEqual(detail.outcomes, [outcome])
    // Terminal rows are not active.
    try await store.transition(
      id: meeting.id, to: .interrupted, now: now + 10_000,
      effects: [.failure(.notRunningAtLastState, detail: nil), .setStoppedAt(now + 10_000)])
    let noneActive = try await store.activeStateRows()
    XCTAssertEqual(noneActive.count, 0)
    let afterLoaded = try await store.detail(id: meeting.id)
    let after = try XCTUnwrap(afterLoaded)
    XCTAssertEqual(after.meeting.failureReason, .notRunningAtLastState)
    XCTAssertEqual(after.meeting.wallClockMs, 9_999)
    XCTAssertEqual(after.meeting.recordedMs, 4_999, "the open pause is clamped to stopped_at")
  }

  func testRelativePathsNeverContainTheRootAndResolveAgainstAnotherRoot() async throws {
    let meeting = try await makeCompleted()
    let loaded = try await store.detail(id: meeting.id)
    let detail = try XCTUnwrap(loaded)
    let other = MeetingStorageRoot(url: URL(fileURLWithPath: "/Volumes/Other/Meetings"))
    for track in detail.tracks {
      for segment in track.segments {
        XCTAssertFalse(segment.relativePath.hasPrefix("/"))
        XCTAssertFalse(segment.relativePath.contains(fixture.root.url.path))
        XCTAssertTrue(segment.relativePath.hasPrefix(meeting.id.uuidString + "/"))
        XCTAssertEqual(
          other.resolve(relativePath: segment.relativePath)?.path,
          "/Volumes/Other/Meetings/" + segment.relativePath)
      }
    }
    XCTAssertNil(other.resolve(relativePath: "../escape.aac"))
    XCTAssertNil(other.resolve(relativePath: "/abs.aac"))
  }

  // MARK: Deletion

  func testDeleteConfirmedRemovesFilesFirstThenRowAndKeepsOtherMeetings() async throws {
    let writer = FileSegmentWriter(root: fixture.root)
    let keep = try await makeCompleted(at: now)
    let victim = try await makeCompleted(at: now + 200_000)
    var keepFiles: [URL: String] = [:]
    for meeting in [keep, victim] {
      let loaded = try await store.detail(id: meeting.id)
      let detail = try XCTUnwrap(loaded)
      for track in detail.tracks {
        let handle = try writer.open(meetingID: meeting.id, kind: track.track.kind, sequence: 1)
        try writer.append(handle, frames: [ADTSFrame(bytes: ADTSFixtures.completeFrames(3))])
        _ = try writer.finalize(handle)
        if meeting.id == keep.id {
          let url = try XCTUnwrap(
            fixture.root.resolve(relativePath: track.segments[0].relativePath))
          keepFiles[url] = try sha256(of: url)
        }
      }
    }
    let stray = fixture.root.meetingDirectory(victim.id).appendingPathComponent("stray.txt")
    try Data("x".utf8).write(to: stray)
    do {
      _ = try await store.deleteConfirmed(id: victim.id, revision: 99)
      XCTFail("stale revision")
    } catch { XCTAssertEqual(error as? MeetingStore.Error, .staleRevision) }
    let outcome = try await store.deleteConfirmed(id: victim.id, revision: 0)
    XCTAssertTrue(outcome.complete)
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: fixture.root.meetingDirectory(victim.id).path))
    let gone = try await store.detail(id: victim.id)
    XCTAssertNil(gone)
    try await fixture.history.database.read { db in
      for table in [
        "meeting_tracks", "meeting_pauses", "meeting_notes", "meeting_recovery_outcomes",
      ] {
        XCTAssertEqual(
          try Int.fetchOne(
            db, sql: "SELECT count(*) FROM \(table) WHERE meeting_id=?",
            arguments: [victim.id.uuidString]), 0, table)
      }
      XCTAssertEqual(
        try Int.fetchOne(
          db,
          sql:
            "SELECT count(*) FROM meeting_segments s JOIN meeting_tracks t ON t.id=s.track_id WHERE t.meeting_id=?",
          arguments: [victim.id.uuidString]), 0)
    }
    for (url, hash) in keepFiles { XCTAssertEqual(try sha256(of: url), hash) }
    let kept = try await store.detail(id: keep.id)
    XCTAssertNotNil(kept)
    // An active meeting is refused; a directory that is already gone still deletes the row.
    let active = try await store.create(now: now + 400_000)
    do {
      _ = try await store.deleteConfirmed(id: active.id, revision: 0)
      XCTFail("active")
    } catch { XCTAssertEqual(error as? MeetingStore.Error, .meetingActive) }
    try await store.transition(id: active.id, to: .failed, now: now, effects: [])
    let activeOutcome = try await store.deleteConfirmed(id: active.id, revision: 0)
    XCTAssertTrue(activeOutcome.complete)
  }

  func testDeleteConfirmedReportsUnremovableFilesAndKeepsTheRow() async throws {
    let writer = FileSegmentWriter(root: fixture.root)
    let meeting = try await makeCompleted()
    let loaded = try await store.detail(id: meeting.id)
    let detail = try XCTUnwrap(loaded)
    for track in detail.tracks {
      let handle = try writer.open(meetingID: meeting.id, kind: track.track.kind, sequence: 1)
      try writer.append(handle, frames: [ADTSFrame(bytes: ADTSFixtures.completeFrames(1))])
      _ = try writer.finalize(handle)
    }
    let directory = fixture.root.meetingDirectory(meeting.id)
    // A read-only directory refuses unlink for the files inside it.
    XCTAssertEqual(chmod(directory.path, 0o500), 0)
    defer { chmod(directory.path, 0o700) }
    let outcome = try await store.deleteConfirmed(id: meeting.id, revision: 0)
    XCTAssertFalse(outcome.complete)
    XCTAssertFalse(outcome.rowDeleted)
    XCTAssertEqual(outcome.remainingPaths.count, 3)
    XCTAssertTrue(outcome.remainingPaths.allSatisfy { $0.hasPrefix(meeting.id.uuidString) })
    let kept = try await store.detail(id: meeting.id)
    XCTAssertNotNil(kept)
    XCTAssertEqual(chmod(directory.path, 0o700), 0)
    let retry = try await store.deleteConfirmed(id: meeting.id, revision: 0)
    XCTAssertTrue(retry.complete)
  }
  func testTranscriptPreparationRollbackAndDeletionUsage() async throws {
    let created = try await store.create(now: now)
    do {
      try await store.transition(
        id: created.id, to: .preparing, now: now,
        effects: [
          .insertTranscription(liveRequested: true), .insertTranscription(liveRequested: true),
        ])
      XCTFail("Duplicate transcript insertion must roll back preparation")
    } catch {}
    let transcripts = TranscriptStore(database: fixture.history.database)
    let absent = try await transcripts.transcription(meetingID: created.id)
    XCTAssertNil(absent)
    let original = try await store.meeting(id: created.id)
    XCTAssertEqual(original?.state, .created)
    try await store.transition(
      id: created.id, to: .preparing, now: now, effects: [.insertTranscription(liveRequested: true)]
    )
    let pass = UUID()
    try await transcripts.transition(
      meetingID: created.id, to: .live, now: now, effects: [.setPass(id: pass, kind: .live)])
    let draft = TranscriptSegmentDraft(
      ordinal: 0, stretchSequence: 1, startMs: 0, endMs: 10, coveredMs: 10, windowIndex: 0,
      timingBasis: .window, rawText: "a", assembledText: "a", normalizedText: "a",
      analysisTracks: .mic)
    _ = try await transcripts.appendSegments(
      meetingID: created.id, passID: pass, drafts: [draft], progress: nil, now: now)
    try await transcripts.appendGap(
      .init(
        meetingID: created.id, passID: pass, stretchSequence: 1, startMs: 10, endMs: 20,
        reason: .stopDrain, createdAt: now))
    let failed = try await store.transition(
      id: created.id, to: .failed, now: now, effects: [.failure(.storageWriteFailed, detail: nil)])
    let deletion = try await store.deleteConfirmed(id: created.id, revision: failed.revision)
    XCTAssertTrue(deletion.rowDeleted)
    let usage = try await transcripts.usage()
    XCTAssertEqual(usage, .init(textBytes: 0, segmentRows: 0))
    let deleted = try await transcripts.transcription(meetingID: created.id)
    XCTAssertNil(deleted)
    let gaps = try await transcripts.gaps(meetingID: created.id)
    XCTAssertTrue(gaps.isEmpty)
    let segments = try await transcripts.page(
      meetingID: created.id, finality: .provisional, after: nil, limit: 200)
    XCTAssertTrue(segments.isEmpty)
  }

}
