import Darwin
import Foundation
import GRDB
import OSLog

/// Every meeting-table write goes through this actor. It shares the history
/// `DatabaseQueue` (one file, one journal, one page ceiling), bumps
/// `updated_at` on every write, recomputes `recorded_ms`/`wall_clock_ms` on
/// each persisted change and logs counts and codes only.
actor MeetingStore: MeetingStoring {
  enum Error: Swift.Error, Equatable, Sendable {
    case alreadyActive(UUID)
    case invalidTransition(from: MeetingState, to: MeetingState)
    case segmentAlreadyOpen
    case pauseAlreadyOpen
    case staleRevision
    case missingMeeting
    case missingRow
    case notesTooLarge
    case titleTooLarge
    case damagedDatabase
    case invalidPath
    case meetingActive
    case unimplemented
    #if DEBUG
      case injectedFailure
    #endif
  }

  static let pageLimit = 20
  nonisolated let database: DatabaseQueue
  let root: MeetingStorageRoot
  private let logger = Logger(subsystem: "org.localflow.LocalFlow", category: "meetings")

  init(database: DatabaseQueue, root: MeetingStorageRoot) {
    self.database = database
    self.root = root
  }

  init(history: TranscriptionStore, root: MeetingStorageRoot) {
    self.init(database: history.database, root: root)
  }

  // MARK: Meetings

  func activeMeeting() throws -> Meeting? {
    try database.read { db in
      try Row.fetchOne(
        db,
        sql:
          "SELECT * FROM meetings WHERE state IN (\(Self.activeList)) ORDER BY created_at LIMIT 1"
      ).flatMap(Self.meeting)
    }
  }

  func create(now: Int64) throws -> Meeting {
    try database.write { db in
      if let row = try Row.fetchOne(
        db, sql: "SELECT id FROM meetings WHERE state IN (\(Self.activeList)) LIMIT 1"),
        let id = UUID(uuidString: row["id"])
      {
        throw Error.alreadyActive(id)
      }
      let id = UUID()
      try db.execute(
        sql: """
          INSERT INTO meetings (id, state, created_at, wall_clock_ms, recorded_ms, updated_at, revision)
          VALUES (?, 'created', ?, 0, 0, ?, 0)
          """, arguments: [id.uuidString, now, now])
      try db.execute(
        sql:
          "INSERT INTO meeting_notes (meeting_id, text, author, updated_at, revision) VALUES (?, '', 'user', ?, 0)",
        arguments: [id.uuidString, now])
      logger.notice("Meeting created")
      guard let meeting = try Self.fetchMeeting(id, db: db) else { throw Error.damagedDatabase }
      return meeting
    }
  }

  @discardableResult
  func transition(id: UUID, to: MeetingState, now: Int64, effects: [MeetingTransitionEffect])
    throws -> Meeting
  {
    let meeting: Meeting = try database.write { db in
      guard let current = try Self.fetchMeeting(id, db: db) else { throw Error.missingMeeting }
      do {
        try MeetingLifecycle.transition(from: current.state, to: to)
      } catch MeetingLifecycle.Error.invalidTransition(let from, let to) {
        throw Error.invalidTransition(from: from, to: to)
      }
      try db.execute(
        sql: "UPDATE meetings SET state=?, updated_at=? WHERE id=?",
        arguments: [to.rawValue, now, id.uuidString])
      for effect in effects { try Self.apply(effect, meetingID: id, now: now, db: db) }
      try Self.recomputeDurations(id, now: now, db: db)
      guard let updated = try Self.fetchMeeting(id, db: db) else { throw Error.damagedDatabase }
      return updated
    }
    logger.notice("Meeting transition to \(to.rawValue, privacy: .public)")
    return meeting
  }

  func meeting(id: UUID) throws -> Meeting? {
    try database.read { db in try Self.fetchMeeting(id, db: db) }
  }

  func setTitle(meetingID: UUID, title: String?, revision: Int64, now: Int64) throws -> Int64 {
    let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines)
    let stored = (trimmed?.isEmpty ?? true) ? nil : trimmed
    if let stored, stored.utf8.count > Meeting.maximumTitleBytes { throw Error.titleTooLarge }
    return try database.write { db in
      guard let current = try Self.fetchMeeting(meetingID, db: db) else {
        throw Error.missingMeeting
      }
      guard current.revision == revision else { throw Error.staleRevision }
      try db.execute(
        sql: "UPDATE meetings SET title=?, revision=revision+1, updated_at=? WHERE id=?",
        arguments: [stored, now, meetingID.uuidString])
      return revision + 1
    }
  }

  // MARK: Segments

  func openSegment(_ segment: MeetingSegment, now: Int64) throws -> MeetingSegment {
    try database.write { db in
      try Self.insertSegment(segment, now: now, db: db)
      return segment
    }
  }

  func progressSegment(
    id: UUID, durationMs: Int64, byteSize: Int64, droppedFrames: Int64, now: Int64
  )
    throws
  {
    try database.write { db in
      try db.execute(
        sql:
          "UPDATE meeting_segments SET duration_ms=?, byte_size=?, dropped_frames=? WHERE id=? AND state='open'",
        arguments: [max(0, durationMs), max(0, byteSize), max(0, droppedFrames), id.uuidString])
      guard let trackID = try Self.trackID(ofSegment: id, db: db),
        let meetingID = try Self.meetingID(ofTrack: trackID, db: db)
      else { throw Error.missingRow }
      try Self.recomputeTrackTotals(trackID, db: db)
      try Self.touch(meetingID, now: now, db: db)
      try Self.recomputeDurations(meetingID, now: now, db: db)
    }
  }

  func finalizeSegment(
    id: UUID, durationMs: Int64, byteSize: Int64, relativePath: String,
    closeReason: SegmentCloseReason, droppedFrames: Int64, now: Int64
  ) throws {
    try database.write { db in
      try Self.apply(
        .finalizeSegment(
          id: id, durationMs: durationMs, byteSize: byteSize, relativePath: relativePath,
          closeReason: closeReason, droppedFrames: droppedFrames),
        meetingID: nil, now: now, db: db)
    }
  }

  func markSegmentUnrecoverable(id: UUID, reason: MeetingFailureReason, note: String?, now: Int64)
    throws
  {
    try database.write { db in
      try Self.apply(
        .markSegmentUnrecoverable(id: id, reason: reason, note: note), meetingID: nil, now: now,
        db: db)
    }
  }

  // MARK: Tracks

  /// Recovery only: no segment of the track could be validated.
  func markTrackUnrecoverable(id: UUID, reason: MeetingFailureReason, at: Int64) throws {
    try database.write { db in
      try db.execute(
        sql: """
          UPDATE meeting_tracks SET health='unrecoverable', failure_reason=COALESCE(failure_reason, ?),
            failed_at=COALESCE(failed_at, ?) WHERE id=?
          """, arguments: [reason.rawValue, at, id.uuidString])
      if let owner = try Self.meetingID(ofTrack: id, db: db) {
        try Self.touch(owner, now: at, db: db)
      }
    }
  }

  /// Recovery only: a content-free note on a segment that was truncated and kept.
  func noteSegmentRecovery(id: UUID, note: String, now: Int64) throws {
    try database.write { db in
      try db.execute(
        sql: "UPDATE meeting_segments SET recovery_note=? WHERE id=?",
        arguments: [String(note.utf8.prefix(MeetingSegment.maximumNoteBytes)) ?? "", id.uuidString])
    }
  }

  func markTrackFailed(id: UUID, reason: MeetingFailureReason, at: Int64) throws {
    try database.write { db in
      try Self.apply(
        .markTrackFailed(id: id, reason: reason, at: at), meetingID: nil, now: at, db: db)
    }
  }

  func markTrackFinalized(id: UUID, now: Int64) throws {
    try database.write { db in
      try Self.apply(.markTrackFinalized(id: id), meetingID: nil, now: now, db: db)
    }
  }

  // MARK: Pauses

  func openPause(meetingID: UUID, reason: PauseReason, at: Int64) throws -> PauseInterval {
    let pause = PauseInterval(id: UUID(), meetingID: meetingID, startedAt: at, reason: reason)
    try database.write { db in
      try Self.apply(.openPause(pause), meetingID: meetingID, now: at, db: db)
      try Self.recomputeDurations(meetingID, now: at, db: db)
    }
    return pause
  }

  func closePause(id: UUID, at: Int64, closedBy: PauseClosedBy) throws {
    try database.write { db in
      guard
        let row = try Row.fetchOne(
          db, sql: "SELECT meeting_id, started_at FROM meeting_pauses WHERE id=?",
          arguments: [id.uuidString]), let meetingID = UUID(uuidString: row["meeting_id"])
      else { throw Error.missingRow }
      let started: Int64 = row["started_at"]
      try db.execute(
        sql: "UPDATE meeting_pauses SET ended_at=?, closed_by=? WHERE id=? AND ended_at IS NULL",
        arguments: [max(started, at), closedBy.rawValue, id.uuidString])
      try Self.touch(meetingID, now: at, db: db)
      try Self.recomputeDurations(meetingID, now: at, db: db)
    }
  }

  // MARK: Notes

  func saveNotes(meetingID: UUID, text: String, revision: Int64, now: Int64) throws -> Int64 {
    guard text.utf8.count <= MeetingNotes.maximumBytes else { throw Error.notesTooLarge }
    let saved: Int64 = try database.write { db in
      guard
        let row = try Row.fetchOne(
          db, sql: "SELECT revision FROM meeting_notes WHERE meeting_id=?",
          arguments: [meetingID.uuidString])
      else { throw Error.missingMeeting }
      let current: Int64 = row["revision"]
      guard current == revision else { throw Error.staleRevision }
      try db.execute(
        sql: "UPDATE meeting_notes SET text=?, updated_at=?, revision=? WHERE meeting_id=?",
        arguments: [text, now, revision + 1, meetingID.uuidString])
      try Self.touch(meetingID, now: now, db: db)
      return revision + 1
    }
    logger.notice("Notes saved; bytes=\(text.utf8.count)")
    return saved
  }

  func notes(meetingID: UUID) throws -> MeetingNotes? {
    try database.read { db in try Self.fetchNotes(meetingID, db: db) }
  }

  /// Persisted after each track finalizes so a crash mid-stop is recoverable.
  func setFinalizationStage(meetingID: UUID, stage: FinalizationStage, now: Int64) throws {
    try database.write { db in
      try Self.apply(.finalizationStage(stage), meetingID: meetingID, now: now, db: db)
    }
  }

  // MARK: Reads

  func page(before: MeetingCursor?, limit: Int) throws -> [MeetingSummary] {
    let limit = max(1, min(limit, Self.pageLimit))
    return try database.read { db in
      var sql = """
        SELECT m.id, m.title, m.created_at, m.state, m.recorded_ms, m.revision,
          EXISTS(SELECT 1 FROM meeting_tracks t WHERE t.meeting_id = m.id
                 AND t.health IN ('failed','unrecoverable')) AS warning
        FROM meetings m
        """
      var arguments: StatementArguments = []
      if let before {
        sql += " WHERE (m.created_at, m.id) < (?, ?)"
        arguments += [before.createdAt, before.id.uuidString]
      }
      sql += " ORDER BY m.created_at DESC, m.id DESC LIMIT ?"
      arguments += [limit]
      return try Row.fetchAll(db, sql: sql, arguments: arguments).compactMap { row in
        guard let id = UUID(uuidString: row["id"]),
          let state = MeetingState(rawValue: row["state"])
        else { return nil }
        return MeetingSummary(
          id: id, title: row["title"], createdAt: row["created_at"], state: state,
          recordedMs: row["recorded_ms"], hasTrackWarning: (row["warning"] as Int) == 1,
          revision: row["revision"])
      }
    }
  }

  func detail(id: UUID) throws -> MeetingDetail? {
    try database.read { db in
      guard let meeting = try Self.fetchMeeting(id, db: db) else { return nil }
      let tracks = try Row.fetchAll(
        db,
        sql:
          "SELECT * FROM meeting_tracks WHERE meeting_id=? ORDER BY CASE type WHEN 'microphone' THEN 0 ELSE 1 END",
        arguments: [id.uuidString]
      ).compactMap(Self.track)
      var details: [MeetingTrackDetail] = []
      for track in tracks {
        let segments = try Row.fetchAll(
          db, sql: "SELECT * FROM meeting_segments WHERE track_id=? ORDER BY sequence",
          arguments: [track.id.uuidString]
        ).compactMap(Self.segment)
        details.append(MeetingTrackDetail(track: track, segments: segments))
      }
      let pauses = try Row.fetchAll(
        db, sql: "SELECT * FROM meeting_pauses WHERE meeting_id=? ORDER BY started_at, id",
        arguments: [id.uuidString]
      ).compactMap(Self.pause)
      guard let notes = try Self.fetchNotes(id, db: db) else { throw Error.damagedDatabase }
      let outcomes = try Row.fetchAll(
        db, sql: "SELECT * FROM meeting_recovery_outcomes WHERE meeting_id=? ORDER BY ran_at, id",
        arguments: [id.uuidString]
      ).compactMap(Self.outcome)
      return MeetingDetail(
        meeting: meeting, tracks: details, pauses: pauses, notes: notes, outcomes: outcomes)
    }
  }

  func activeStateRows() throws -> [Meeting] {
    try database.read { db in
      try Row.fetchAll(
        db,
        sql: "SELECT * FROM meetings WHERE state IN (\(Self.activeList)) ORDER BY created_at, id"
      ).compactMap(Self.meeting)
    }
  }

  func allMeetingIDs() throws -> Set<UUID> {
    try database.read { db in
      Set(
        try String.fetchAll(db, sql: "SELECT id FROM meetings").compactMap(UUID.init(uuidString:)))
    }
  }

  func recordOutcome(_ outcome: RecoveryOutcome) throws {
    try database.write { db in
      try db.execute(
        sql: """
          INSERT INTO meeting_recovery_outcomes (id, meeting_id, ran_at, found_state, found_stage,
            segments_recovered, segments_unrecoverable, segments_missing, pause_closed, bytes_truncated, summary)
          VALUES (?,?,?,?,?,?,?,?,?,?,?)
          """,
        arguments: [
          outcome.id.uuidString, outcome.meetingID.uuidString, outcome.ranAt,
          outcome.foundState.rawValue, outcome.foundStage?.rawValue, outcome.segmentsRecovered,
          outcome.segmentsUnrecoverable, outcome.segmentsMissing, outcome.pauseClosed ? 1 : 0,
          outcome.bytesTruncated,
          String(outcome.summary.utf8.prefix(RecoveryOutcome.maximumSummaryBytes)) ?? "",
        ])
      try Self.touch(outcome.meetingID, now: outcome.ranAt, db: db)
    }
  }

  /// Reconciliation of an orphan directory: one `interrupted` meeting with its
  /// tracks, segments, an empty notes row and the outcome, in one write.
  func insertRecovered(
    meeting: Meeting, tracks: [MeetingTrack], segments: [MeetingSegment], outcome: RecoveryOutcome
  ) throws {
    try database.write { db in
      try db.execute(
        sql: """
          INSERT INTO meetings (id, state, title, created_at, started_at, stopped_at, completed_at,
            wall_clock_ms, recorded_ms, finalization_stage, failure_reason, failure_detail, updated_at, revision)
          VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,0)
          """,
        arguments: [
          meeting.id.uuidString, meeting.state.rawValue, meeting.title, meeting.createdAt,
          meeting.startedAt, meeting.stoppedAt, meeting.completedAt, meeting.wallClockMs,
          meeting.recordedMs, meeting.finalizationStage?.rawValue, meeting.failureReason?.rawValue,
          meeting.failureDetail, meeting.updatedAt,
        ])
      try db.execute(
        sql:
          "INSERT INTO meeting_notes (meeting_id, text, author, updated_at, revision) VALUES (?, '', 'user', ?, 0)",
        arguments: [meeting.id.uuidString, meeting.updatedAt])
      try Self.insertTracks(tracks, db: db)
      for segment in segments { try Self.insertSegment(segment, now: meeting.updatedAt, db: db) }
      for track in tracks { try Self.recomputeTrackTotals(track.id, db: db) }
      try db.execute(
        sql: """
          INSERT INTO meeting_recovery_outcomes (id, meeting_id, ran_at, found_state, found_stage,
            segments_recovered, segments_unrecoverable, segments_missing, pause_closed, bytes_truncated, summary)
          VALUES (?,?,?,?,?,?,?,?,?,?,?)
          """,
        arguments: [
          outcome.id.uuidString, outcome.meetingID.uuidString, outcome.ranAt,
          outcome.foundState.rawValue, outcome.foundStage?.rawValue, outcome.segmentsRecovered,
          outcome.segmentsUnrecoverable, outcome.segmentsMissing, outcome.pauseClosed ? 1 : 0,
          outcome.bytesTruncated, outcome.summary,
        ])
    }
  }

  // MARK: Deletion

  /// Files first, row last. A path that cannot be removed keeps the row and is
  /// reported; another meeting's files and rows are never touched.
  func deleteConfirmed(id: UUID, revision: Int64) throws -> DeletionOutcome {
    let paths: [String] = try database.read { db in
      guard let meeting = try Self.fetchMeeting(id, db: db) else { throw Error.missingMeeting }
      guard meeting.revision == revision else { throw Error.staleRevision }
      guard !meeting.state.isActive else { throw Error.meetingActive }
      return try String.fetchAll(
        db,
        sql: """
          SELECT s.relative_path FROM meeting_segments s
          JOIN meeting_tracks t ON t.id = s.track_id WHERE t.meeting_id = ? ORDER BY s.sequence
          """, arguments: [id.uuidString])
    }
    var remaining: [String] = []
    var attempted: Set<String> = []
    for path in paths {
      attempted.insert(path)
      guard let url = root.resolve(relativePath: path), path.hasPrefix(id.uuidString + "/") else {
        remaining.append(path)
        continue
      }
      if unlink(url.path) != 0, errno != ENOENT { remaining.append(path) }
    }
    let directory = root.meetingDirectory(id)
    var info = stat()
    if lstat(directory.path, &info) == 0 {
      guard (info.st_mode & S_IFMT) == S_IFDIR else {
        return DeletionOutcome(remainingPaths: [id.uuidString], rowDeleted: false)
      }
      let entries = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
      for entry in entries where !attempted.contains(id.uuidString + "/" + entry) {
        let url = directory.appendingPathComponent(entry)
        do { try FileManager.default.removeItem(at: url) } catch {
          if (error as NSError).code != NSFileNoSuchFileError {
            remaining.append(id.uuidString + "/" + entry)
          }
        }
      }
      if rmdir(directory.path) != 0, errno != ENOENT { remaining.append(id.uuidString) }
    }
    guard remaining.isEmpty else {
      logger.error("Meeting deletion incomplete; remaining=\(remaining.count)")
      return DeletionOutcome(remainingPaths: remaining, rowDeleted: false)
    }
    try database.write { db in
      guard let meeting = try Self.fetchMeeting(id, db: db), meeting.revision == revision else {
        throw Error.staleRevision
      }
      try db.execute(sql: "DELETE FROM meetings WHERE id=?", arguments: [id.uuidString])
    }
    logger.notice("Meeting deleted")
    return DeletionOutcome(remainingPaths: [], rowDeleted: true)
  }

  // MARK: - Transaction helpers

  static let activeList = MeetingState.allCases.filter(\.isActive).map { "'\($0.rawValue)'" }
    .joined(separator: ",")

  private static func apply(
    _ effect: MeetingTransitionEffect, meetingID: UUID?, now: Int64, db: Database
  ) throws {
    switch effect {
    case .insertTracks(let tracks):
      try insertTracks(tracks, db: db)
    case .setStartedAt(let value):
      try update(meetingID, "started_at", value, now: now, db: db)
    case .setStoppedAt(let value):
      try update(meetingID, "stopped_at", value, now: now, db: db)
    case .setCompletedAt(let value):
      try update(meetingID, "completed_at", value, now: now, db: db)
    case .failure(let reason, let detail):
      guard let meetingID else { throw Error.missingMeeting }
      let bounded = detail.map { String($0.utf8.prefix(Meeting.maximumDetailBytes)) ?? "" }
      try db.execute(
        sql: "UPDATE meetings SET failure_reason=?, failure_detail=?, updated_at=? WHERE id=?",
        arguments: [reason.rawValue, bounded, now, meetingID.uuidString])
    case .finalizationStage(let stage):
      guard let meetingID else { throw Error.missingMeeting }
      try db.execute(
        sql: "UPDATE meetings SET finalization_stage=?, updated_at=? WHERE id=?",
        arguments: [stage.rawValue, now, meetingID.uuidString])
    case .openSegment(let segment):
      try insertSegment(segment, now: now, db: db)
    case .finalizeSegment(let id, let durationMs, let byteSize, let path, let reason, let dropped):
      guard MeetingStorageRoot.isValid(relativePath: path) else { throw Error.invalidPath }
      try db.execute(
        sql: """
          UPDATE meeting_segments SET state='finalized', duration_ms=?, byte_size=?, relative_path=?,
            close_reason=?, dropped_frames=? WHERE id=?
          """,
        arguments: [
          max(0, durationMs), max(0, byteSize), path, reason.rawValue, max(0, dropped),
          id.uuidString,
        ])
      guard let trackID = try trackID(ofSegment: id, db: db),
        let owner = try self.meetingID(ofTrack: trackID, db: db)
      else { throw Error.missingRow }
      try recomputeTrackTotals(trackID, db: db)
      try touch(owner, now: now, db: db)
    case .markSegmentUnrecoverable(let id, let reason, let note):
      let bounded = note.map { String($0.utf8.prefix(MeetingSegment.maximumNoteBytes)) ?? "" }
      try db.execute(
        sql:
          "UPDATE meeting_segments SET state='unrecoverable', failure_reason=?, recovery_note=? WHERE id=?",
        arguments: [reason.rawValue, bounded, id.uuidString])
      guard let trackID = try trackID(ofSegment: id, db: db),
        let owner = try self.meetingID(ofTrack: trackID, db: db)
      else { throw Error.missingRow }
      try recomputeTrackTotals(trackID, db: db)
      try touch(owner, now: now, db: db)
    case .markTrackFailed(let id, let reason, let at):
      // A failed track keeps its first reason; unrecoverable is only set by recovery.
      try db.execute(
        sql: """
          UPDATE meeting_tracks SET health=CASE WHEN health='unrecoverable' THEN health ELSE 'failed' END,
            failure_reason=COALESCE(failure_reason, ?), failed_at=COALESCE(failed_at, ?)
          WHERE id=? AND health != 'failed'
          """, arguments: [reason.rawValue, at, id.uuidString])
      if let owner = try self.meetingID(ofTrack: id, db: db) { try touch(owner, now: now, db: db) }
    case .markTrackFinalized(let id):
      try db.execute(
        sql: "UPDATE meeting_tracks SET health='finalized' WHERE id=? AND health='healthy'",
        arguments: [id.uuidString])
      if let owner = try self.meetingID(ofTrack: id, db: db) { try touch(owner, now: now, db: db) }
    case .openPause(let pause):
      if try Row.fetchOne(
        db, sql: "SELECT 1 FROM meeting_pauses WHERE meeting_id=? AND ended_at IS NULL",
        arguments: [pause.meetingID.uuidString]) != nil
      {
        throw Error.pauseAlreadyOpen
      }
      try db.execute(
        sql:
          "INSERT INTO meeting_pauses (id, meeting_id, started_at, ended_at, reason, closed_by) VALUES (?,?,?,?,?,?)",
        arguments: [
          pause.id.uuidString, pause.meetingID.uuidString, pause.startedAt, pause.endedAt,
          pause.reason.rawValue, pause.closedBy?.rawValue,
        ])
      try touch(pause.meetingID, now: now, db: db)
    case .closeOpenPause(let at, let closedBy):
      guard let meetingID else { throw Error.missingMeeting }
      try db.execute(
        sql:
          "UPDATE meeting_pauses SET ended_at=MAX(started_at, ?), closed_by=? WHERE meeting_id=? AND ended_at IS NULL",
        arguments: [at, closedBy.rawValue, meetingID.uuidString])
      try touch(meetingID, now: now, db: db)
    case .computeDurationWarnings:
      guard let meetingID else { throw Error.missingMeeting }
      try recomputeDurations(meetingID, now: now, db: db)
      guard let meeting = try fetchMeeting(meetingID, db: db) else { throw Error.missingMeeting }
      let tolerance = max(meeting.recordedMs / 100, 2_000)
      try db.execute(
        sql: """
          UPDATE meeting_tracks SET duration_warning = CASE WHEN abs(total_duration_ms - ?) > ? THEN 1 ELSE 0 END
          WHERE meeting_id=?
          """, arguments: [meeting.recordedMs, tolerance, meetingID.uuidString])
    #if DEBUG
      case .injectedFailure:
        throw Error.injectedFailure
    #endif
    }
  }

  private static func update(
    _ meetingID: UUID?, _ column: String, _ value: Int64, now: Int64, db: Database
  )
    throws
  {
    guard let meetingID else { throw Error.missingMeeting }
    try db.execute(
      sql: "UPDATE meetings SET \(column)=?, updated_at=? WHERE id=?",
      arguments: [value, now, meetingID.uuidString])
  }

  private static func touch(_ meetingID: UUID, now: Int64, db: Database) throws {
    try db.execute(
      sql: "UPDATE meetings SET updated_at=MAX(updated_at, ?) WHERE id=?",
      arguments: [now, meetingID.uuidString])
  }

  private static func insertTracks(_ tracks: [MeetingTrack], db: Database) throws {
    for track in tracks {
      try db.execute(
        sql: """
          INSERT INTO meeting_tracks (id, meeting_id, type, codec, container, sample_rate, channel_count,
            bitrate, health, failure_reason, failed_at, total_duration_ms, total_bytes, duration_warning, dropped_frames)
          VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
          """,
        arguments: [
          track.id.uuidString, track.meetingID.uuidString, track.kind.rawValue, track.codec,
          track.container, track.sampleRate, track.channelCount, track.bitrate,
          track.health.rawValue, track.failureReason?.rawValue, track.failedAt,
          track.totalDurationMs, track.totalBytes, track.durationWarning ? 1 : 0,
          track.droppedFrames,
        ])
    }
  }

  private static func insertSegment(_ segment: MeetingSegment, now: Int64, db: Database) throws {
    guard MeetingStorageRoot.isValid(relativePath: segment.relativePath) else {
      throw Error.invalidPath
    }
    if segment.state == .open,
      try Row.fetchOne(
        db, sql: "SELECT 1 FROM meeting_segments WHERE track_id=? AND state='open'",
        arguments: [segment.trackID.uuidString]) != nil
    {
      throw Error.segmentAlreadyOpen
    }
    try db.execute(
      sql: """
        INSERT INTO meeting_segments (id, track_id, sequence, relative_path, state, start_offset_ms,
          duration_ms, byte_size, started_at, host_start_ns, open_reason, close_reason, dropped_frames,
          recovery_note, failure_reason)
        VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
        """,
      arguments: [
        segment.id.uuidString, segment.trackID.uuidString, segment.sequence, segment.relativePath,
        segment.state.rawValue, segment.startOffsetMs, segment.durationMs, segment.byteSize,
        segment.startedAt, segment.hostStartNs, segment.openReason.rawValue,
        segment.closeReason?.rawValue, segment.droppedFrames, segment.recoveryNote,
        segment.failureReason?.rawValue,
      ])
    if let owner = try meetingID(ofTrack: segment.trackID, db: db) {
      try touch(owner, now: now, db: db)
    }
  }

  private static func recomputeTrackTotals(_ trackID: UUID, db: Database) throws {
    try db.execute(
      sql: """
        UPDATE meeting_tracks SET
          total_duration_ms = (SELECT COALESCE(SUM(duration_ms),0) FROM meeting_segments WHERE track_id=? AND state='finalized'),
          total_bytes = (SELECT COALESCE(SUM(byte_size),0) FROM meeting_segments WHERE track_id=?),
          dropped_frames = (SELECT COALESCE(SUM(dropped_frames),0) FROM meeting_segments WHERE track_id=?)
        WHERE id=?
        """,
      arguments: [trackID.uuidString, trackID.uuidString, trackID.uuidString, trackID.uuidString])
  }

  /// `wall_clock_ms = (stopped_at ?? now) − started_at`; `recorded_ms` subtracts every
  /// pause clamped to that window, including an open one.
  static func recomputeDurations(_ meetingID: UUID, now: Int64, db: Database) throws {
    guard let meeting = try fetchMeeting(meetingID, db: db) else { throw Error.missingMeeting }
    guard let started = meeting.startedAt else { return }
    let end = max(started, meeting.stoppedAt ?? now)
    let wall = end - started
    var paused: Int64 = 0
    for row in try Row.fetchAll(
      db, sql: "SELECT started_at, ended_at FROM meeting_pauses WHERE meeting_id=?",
      arguments: [meetingID.uuidString])
    {
      let pauseStart: Int64 = row["started_at"]
      let pauseEnd: Int64 = (row["ended_at"] as Int64?) ?? end
      paused += max(0, min(pauseEnd, end) - max(pauseStart, started))
    }
    try db.execute(
      sql: "UPDATE meetings SET wall_clock_ms=?, recorded_ms=? WHERE id=?",
      arguments: [wall, max(0, wall - paused), meetingID.uuidString])
  }

  private static func trackID(ofSegment id: UUID, db: Database) throws -> UUID? {
    try String.fetchOne(
      db, sql: "SELECT track_id FROM meeting_segments WHERE id=?", arguments: [id.uuidString]
    ).flatMap(UUID.init(uuidString:))
  }

  private static func meetingID(ofTrack id: UUID, db: Database) throws -> UUID? {
    try String.fetchOne(
      db, sql: "SELECT meeting_id FROM meeting_tracks WHERE id=?", arguments: [id.uuidString]
    ).flatMap(UUID.init(uuidString:))
  }

  // MARK: - Row mapping

  static func fetchMeeting(_ id: UUID, db: Database) throws -> Meeting? {
    try Row.fetchOne(db, sql: "SELECT * FROM meetings WHERE id=?", arguments: [id.uuidString])
      .flatMap(meeting)
  }

  private static func fetchNotes(_ id: UUID, db: Database) throws -> MeetingNotes? {
    try Row.fetchOne(
      db, sql: "SELECT * FROM meeting_notes WHERE meeting_id=?", arguments: [id.uuidString]
    ).map { row in
      MeetingNotes(
        meetingID: id, text: row["text"], updatedAt: row["updated_at"], revision: row["revision"])
    }
  }

  static func meeting(_ row: Row) -> Meeting? {
    guard let id = UUID(uuidString: row["id"]), let state = MeetingState(rawValue: row["state"])
    else { return nil }
    return Meeting(
      id: id, state: state, title: row["title"], createdAt: row["created_at"],
      startedAt: row["started_at"], stoppedAt: row["stopped_at"], completedAt: row["completed_at"],
      wallClockMs: row["wall_clock_ms"], recordedMs: row["recorded_ms"],
      finalizationStage: (row["finalization_stage"] as String?).flatMap(FinalizationStage.init),
      failureReason: (row["failure_reason"] as String?).flatMap(MeetingFailureReason.init),
      failureDetail: row["failure_detail"], updatedAt: row["updated_at"], revision: row["revision"])
  }

  static func track(_ row: Row) -> MeetingTrack? {
    guard let id = UUID(uuidString: row["id"]), let meetingID = UUID(uuidString: row["meeting_id"]),
      let kind = MeetingTrackKind(rawValue: row["type"]),
      let health = TrackHealth(rawValue: row["health"])
    else { return nil }
    return MeetingTrack(
      id: id, meetingID: meetingID, kind: kind, codec: row["codec"], container: row["container"],
      sampleRate: row["sample_rate"], channelCount: row["channel_count"], bitrate: row["bitrate"],
      health: health,
      failureReason: (row["failure_reason"] as String?).flatMap(MeetingFailureReason.init),
      failedAt: row["failed_at"], totalDurationMs: row["total_duration_ms"],
      totalBytes: row["total_bytes"], durationWarning: (row["duration_warning"] as Int) == 1,
      droppedFrames: row["dropped_frames"])
  }

  static func segment(_ row: Row) -> MeetingSegment? {
    guard let id = UUID(uuidString: row["id"]), let trackID = UUID(uuidString: row["track_id"]),
      let state = SegmentState(rawValue: row["state"]),
      let openReason = SegmentOpenReason(rawValue: row["open_reason"])
    else { return nil }
    return MeetingSegment(
      id: id, trackID: trackID, sequence: row["sequence"], relativePath: row["relative_path"],
      state: state, startOffsetMs: row["start_offset_ms"], durationMs: row["duration_ms"],
      byteSize: row["byte_size"], startedAt: row["started_at"], hostStartNs: row["host_start_ns"],
      openReason: openReason,
      closeReason: (row["close_reason"] as String?).flatMap(SegmentCloseReason.init),
      droppedFrames: row["dropped_frames"], recoveryNote: row["recovery_note"],
      failureReason: (row["failure_reason"] as String?).flatMap(MeetingFailureReason.init))
  }

  static func pause(_ row: Row) -> PauseInterval? {
    guard let id = UUID(uuidString: row["id"]), let meetingID = UUID(uuidString: row["meeting_id"]),
      let reason = PauseReason(rawValue: row["reason"])
    else { return nil }
    return PauseInterval(
      id: id, meetingID: meetingID, startedAt: row["started_at"], endedAt: row["ended_at"],
      reason: reason, closedBy: (row["closed_by"] as String?).flatMap(PauseClosedBy.init))
  }

  static func outcome(_ row: Row) -> RecoveryOutcome? {
    guard let id = UUID(uuidString: row["id"]), let meetingID = UUID(uuidString: row["meeting_id"]),
      let state = MeetingState(rawValue: row["found_state"])
    else { return nil }
    return RecoveryOutcome(
      id: id, meetingID: meetingID, ranAt: row["ran_at"], foundState: state,
      foundStage: (row["found_stage"] as String?).flatMap(FinalizationStage.init),
      segmentsRecovered: row["segments_recovered"],
      segmentsUnrecoverable: row["segments_unrecoverable"],
      segmentsMissing: row["segments_missing"], pauseClosed: (row["pause_closed"] as Int) == 1,
      bytesTruncated: row["bytes_truncated"], summary: row["summary"])
  }
}
