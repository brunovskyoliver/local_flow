import CryptoKit
import Foundation
import GRDB
import LocalFlowCore
import LocalFlowSpeech

/// Hands a stopped meeting to the server whole: its audio files and its slice of the
/// history database go up once, the server's `flowd-meeting` runs the same finalizer,
/// diarizer and analyzer there while this Mac may be offline, and the processed slice
/// comes back and is merged in one transaction. Speaker identification stays here,
/// where the voiceprints are.
///
/// Each `step` advances one stage and returns; the transcription queue calls it again
/// through its server waits. A meeting is handed off while `Handoff/<id>/bundle.sqlite`
/// exists; the file is the exact upload, so a resumed upload continues byte for byte.
actor MeetingHandoff {
  enum Step: Sendable, Equatable {
    /// Not eligible, or the server failed it: finalize the usual way.
    case notHandedOff
    /// Uploaded or processing, or the server is unreachable; ask again later.
    case waiting(String)
    /// Merged. `labeled`: the server's diarization succeeded.
    case merged(labeled: Bool)
  }

  static let chunkBytes = 48_000

  private let pool: RemoteChannelPool
  private let database: DatabasePool
  private let root: MeetingStorageRoot
  private let directory: URL
  /// Server routing, the `handoff` op, and no **Run on this Mac**.
  private let eligible: @Sendable (UUID) async -> Bool
  private let defaultLanguage: @Sendable () async -> MeetingLanguage

  init(
    pool: RemoteChannelPool, database: DatabasePool, root: MeetingStorageRoot,
    eligible: @escaping @Sendable (UUID) async -> Bool,
    defaultLanguage: @escaping @Sendable () async -> MeetingLanguage
  ) {
    self.pool = pool
    self.database = database
    self.root = root
    directory = root.url.deletingLastPathComponent().appendingPathComponent(
      "Handoff", isDirectory: true)
    self.eligible = eligible
    self.defaultLanguage = defaultLanguage
  }

  func step(_ id: UUID) async -> Step {
    let bundle = bundleURL(id)
    if !FileManager.default.fileExists(atPath: bundle.path) {
      guard await eligible(id), (try? await export(id, to: bundle)) == true else {
        return .notHandedOff
      }
    } else if await runsLocally(id) {
      // **Run on this Mac** after the upload began: the server's copy is dropped.
      await abandon(id)
      return .notHandedOff
    }
    do {
      let list = try await call(.init(action: .list))
      switch list.meetings?.first(where: { $0.meeting == id })?.state ?? .missing {
      case .missing, .receiving:
        try await upload(id)
        _ = try await call(.init(action: .start, meeting: id))
        return .waiting("queued")
      case .queued: return .waiting("queued")
      case .processing: return .waiting("processing")
      case .done:
        let labeled = try await merge(id, from: try await download(id))
        _ = try? await call(.init(action: .delete, meeting: id))
        forget(id)
        return .merged(labeled: labeled)
      case .failed:
        await abandon(id)
        return .notHandedOff
      }
    } catch is RemoteMeetingNotOffered {
      forget(id)
      return .notHandedOff
    } catch DictationFailure.invalidResult, RemoteChannelError.protocolError {
      // The server refused the meeting (no finished audio, the per-user limit) or sent
      // a result that does not merge: asking again gets the same answer.
      await abandon(id)
      return .notHandedOff
    } catch let waiting as RemoteMeetingWaiting {
      return .waiting(waiting.code)
    } catch {
      return .waiting("unreachable")
    }
  }

  private func abandon(_ id: UUID) async {
    _ = try? await call(.init(action: .delete, meeting: id))
    forget(id)
  }

  private func runsLocally(_ id: UUID) async -> Bool {
    (try? await database.read { db in
      try Bool.fetchOne(
        db, sql: "SELECT run_locally FROM meetings WHERE id=?", arguments: [id.uuidString])
    }) == true
  }

  /// The meeting was deleted here; the server's copy goes too when it can.
  func meetingWillDelete(id: UUID) async {
    guard FileManager.default.fileExists(atPath: bundleURL(id).path) else { return }
    forget(id)
    _ = try? await call(.init(action: .delete, meeting: id))
  }

  // MARK: Wire

  private func call(_ request: RemoteHandoffRequest) async throws -> RemoteHandoffReply {
    try await RemoteMeetingJobs.exchange(
      pool: pool, role: .background, request: { .handoff(op: $0, request: request) },
      samples: [], cancel: nil,
      answer: { message, op in
        guard case .handoffReply(op, let reply) = message else {
          throw RemoteChannelError.protocolError
        }
        return reply
      })
  }

  /// Every finalized track file, then the bundle; each resumes at the server's size.
  private func upload(_ id: UUID) async throws {
    var files = try await database.read { db in
      try String.fetchAll(
        db,
        sql: """
          SELECT s.relative_path FROM meeting_segments s JOIN meeting_tracks t ON t.id=s.track_id
          WHERE t.meeting_id=? AND s.state='finalized' ORDER BY s.relative_path
          """, arguments: [id.uuidString])
    }.compactMap { path in root.resolve(relativePath: path).map { ($0.lastPathComponent, $0) } }
    files.append(("bundle.sqlite", bundleURL(id)))
    for (name, url) in files { try await upload(id, name: name, url: url) }
  }

  private func upload(_ id: UUID, name: String, url: URL) async throws {
    let data = try Data(contentsOf: url, options: .mappedIfSafe)
    let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    // An offset the server does not have yet writes nothing and returns its size.
    var offset =
      try await call(.init(action: .put, meeting: id, name: name, offset: 0))
      .offset ?? 0
    guard offset <= data.count else { throw RemoteChannelError.protocolError }
    repeat {
      try Task.checkCancellation()
      let end = min(data.count, offset + Self.chunkBytes)
      let last = end == data.count
      let reply = try await call(
        .init(
          action: .put, meeting: id, name: name, offset: offset,
          data: end > offset ? data.subdata(in: offset..<end) : nil, sha256: last ? hash : nil))
      guard let next = reply.offset, reply.state == .receiving else {
        throw RemoteChannelError.protocolError
      }
      // A hash mismatch truncates the file on the server: send it again.
      if last && next == 0 && !data.isEmpty {
        offset = 0
        continue
      }
      guard next == end else { throw RemoteChannelError.protocolError }
      if last { return }
      offset = next
    } while true
  }

  private func download(_ id: UUID) async throws -> URL {
    let url = directory.appendingPathComponent(id.uuidString, isDirectory: true)
      .appendingPathComponent("result.sqlite")
    var data = Data()
    var expected: (size: Int, sha256: String)?
    repeat {
      let reply = try await call(.init(action: .get, meeting: id, offset: data.count))
      guard reply.state == .done, let size = reply.size, let sha256 = reply.sha256,
        reply.offset == data.count, size <= 1 << 30
      else { throw RemoteChannelError.protocolError }
      expected = (size, sha256)
      if let chunk = reply.data { data.append(chunk) } else { break }
    } while data.count < expected!.size
    let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    guard let expected, data.count == expected.size, hash == expected.sha256 else {
      throw RemoteChannelError.protocolError
    }
    try data.write(to: url, options: .atomic)
    return url
  }

  // MARK: Database slices

  private func bundleURL(_ id: UUID) -> URL {
    directory.appendingPathComponent(id.uuidString, isDirectory: true)
      .appendingPathComponent("bundle.sqlite")
  }

  private func forget(_ id: UUID) {
    try? FileManager.default.removeItem(
      at: directory.appendingPathComponent(id.uuidString, isDirectory: true))
  }

  /// Rows the server's pipeline reads, with the Dictionary. A meeting that already has
  /// labels or a summary stays here: merging would replace edits made to them.
  private static let inputs: [(table: String, filter: String)] = [
    ("meetings", "id=?"),
    ("meeting_tracks", "meeting_id=?"),
    ("meeting_segments", "track_id IN (SELECT id FROM meeting_tracks WHERE meeting_id=?)"),
    ("meeting_pauses", "meeting_id=?"),
    ("meeting_notes", "meeting_id=?"),
    ("meeting_transcriptions", "meeting_id=?"),
    ("transcript_segments", "meeting_id=?"),
    ("transcript_live_gaps", "meeting_id=?"),
    ("meeting_diarization", "meeting_id=?"),
    ("meeting_analysis", "meeting_id=?"),
    ("vocabulary_entries", "1 OR ?"),
    ("vocabulary_state", "1 OR ?"),
  ]

  /// What comes back, parents first; deleted children first.
  private static let outputs: [(table: String, filter: String)] = [
    ("meeting_transcriptions", "meeting_id=?"),
    ("transcript_segments", "meeting_id=?"),
    ("transcript_live_gaps", "meeting_id=?"),
    ("diarization_runs", "meeting_id=?"),
    ("meeting_speakers", "meeting_id=?"),
    ("meeting_diarization", "meeting_id=?"),
    ("speaker_turns", "run_id IN (SELECT id FROM %@.diarization_runs WHERE meeting_id=?)"),
    ("speaker_assignments", "run_id IN (SELECT id FROM %@.diarization_runs WHERE meeting_id=?)"),
    ("speaker_corrections", "meeting_id=?"),
    ("analysis_runs", "meeting_id=?"),
    ("meeting_analysis", "meeting_id=?"),
    ("analysis_summaries", "meeting_id=?"),
    ("analysis_topics", "meeting_id=?"),
    ("analysis_items", "meeting_id=?"),
    ("analysis_sources", "meeting_id=?"),
    ("analysis_overlays", "meeting_id=?"),
  ]

  func export(_ id: UUID, to url: URL) async throws -> Bool {
    let language = await defaultLanguage()
    let eligible = try await database.read { db -> Bool in
      let terminal =
        try Bool.fetchOne(
          db, sql: "SELECT state IN ('completed','interrupted','failed') FROM meetings WHERE id=?",
          arguments: [id.uuidString]) ?? false
      let labeled =
        try Bool.fetchOne(
          db,
          sql: """
            SELECT EXISTS(SELECT 1 FROM meeting_diarization WHERE meeting_id=?1
                AND (accepted_run_id IS NOT NULL OR current_run_id IS NOT NULL))
              OR EXISTS(SELECT 1 FROM meeting_analysis WHERE meeting_id=?1
                AND (accepted_run_id IS NOT NULL OR current_run_id IS NOT NULL))
            """, arguments: [id.uuidString]) ?? true
      return terminal && !labeled
    }
    guard eligible else { return false }
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    let staging = url.deletingLastPathComponent().appendingPathComponent("staging.sqlite")
    try? FileManager.default.removeItem(at: staging)
    // Same migrations as this database, so every table exists with its constraints.
    _ = try TranscriptionStore(path: staging.path)
    try await database.writeWithoutTransaction { db in
      try db.execute(sql: "ATTACH DATABASE ? AS bundle", arguments: [staging.path])
      defer { try? db.execute(sql: "DETACH DATABASE bundle") }
      try db.inTransaction {
        for (table, filter) in Self.inputs {
          let columns = try Self.columns(db, table, "main", "bundle")
          try db.execute(
            sql:
              "INSERT OR REPLACE INTO bundle.\(table)(\(columns)) SELECT \(columns) FROM main.\(table) WHERE \(filter)",
            arguments: [id.uuidString])
        }
        try db.execute(
          sql: "UPDATE bundle.meetings SET language=? WHERE id=? AND language IS NULL",
          arguments: [language.rawValue, id.uuidString])
        // The bundle's capacity counter covers only this meeting.
        try db.execute(
          sql: """
            UPDATE bundle.transcript_usage SET
              text_bytes=COALESCE((SELECT text_bytes FROM bundle.meeting_transcriptions),0),
              segment_rows=COALESCE((SELECT segment_count FROM bundle.meeting_transcriptions),0)
            """)
        return .commit
      }
    }
    let staged = try DatabaseQueue(path: staging.path)
    try await staged.writeWithoutTransaction { db in
      try db.execute(sql: "PRAGMA wal_checkpoint(TRUNCATE)")
      try db.execute(sql: "PRAGMA journal_mode=DELETE")
    }
    try staged.close()
    try FileManager.default.moveItem(at: staging, to: url)
    return true
  }

  /// Replaces this meeting's transcript, labels and summary with the server's rows in
  /// one transaction, keeping the capacity counter exact. Returns whether a diarization
  /// run was accepted.
  func merge(_ id: UUID, from url: URL) async throws -> Bool {
    try await database.writeWithoutTransaction { db in
      try db.execute(sql: "ATTACH DATABASE ? AS result", arguments: [url.path])
      defer { try? db.execute(sql: "DETACH DATABASE result") }
      var labeled = false
      try db.inTransaction {
        let key = id.uuidString
        guard
          try Bool.fetchOne(
            db,
            sql: "SELECT state='final' FROM result.meeting_transcriptions WHERE meeting_id=?",
            arguments: [key]) == true,
          try Bool.fetchOne(db, sql: "SELECT 1 FROM main.meetings WHERE id=?", arguments: [key])
            == true
        else { throw RemoteChannelError.protocolError }
        try db.execute(sql: "PRAGMA defer_foreign_keys=ON")
        try db.execute(
          sql: """
            UPDATE main.transcript_usage SET
              text_bytes=text_bytes
                -COALESCE((SELECT text_bytes FROM main.meeting_transcriptions WHERE meeting_id=?1),0)
                +(SELECT text_bytes FROM result.meeting_transcriptions WHERE meeting_id=?1),
              segment_rows=segment_rows
                -COALESCE((SELECT segment_count FROM main.meeting_transcriptions WHERE meeting_id=?1),0)
                +(SELECT segment_count FROM result.meeting_transcriptions WHERE meeting_id=?1)
            WHERE id=1
            """, arguments: [key])
        for (table, filter) in Self.outputs.reversed() {
          try db.execute(
            sql:
              "DELETE FROM main.\(table) WHERE \(filter.replacingOccurrences(of: "%@", with: "main"))",
            arguments: [key])
        }
        for (table, filter) in Self.outputs {
          var columns = try Self.columns(db, table, "main", "result")
          // speaker_turns has an integer key; this database numbers its own rows.
          if table == "speaker_turns" {
            columns = columns.split(separator: ",").filter { $0 != "id" }.joined(separator: ",")
          }
          try db.execute(
            sql:
              "INSERT INTO main.\(table)(\(columns)) SELECT \(columns) FROM result.\(table) WHERE \(filter.replacingOccurrences(of: "%@", with: "result"))",
            arguments: [key])
        }
        // The server ran these stages for this Mac.
        for table in ["meeting_transcriptions", "diarization_runs", "analysis_runs"]
        where try Self.columns(db, table, "main", "main").split(separator: ",")
          .contains("inference_path")
        {
          try db.execute(
            sql: "UPDATE main.\(table) SET inference_path='server' WHERE meeting_id=?",
            arguments: [key])
        }
        labeled =
          try Bool.fetchOne(
            db,
            sql:
              "SELECT accepted_run_id IS NOT NULL FROM main.meeting_diarization WHERE meeting_id=?",
            arguments: [key]) ?? false
        return .commit
      }
      return labeled
    }
  }

  /// The columns both schemas have, comma-separated, in `left`'s order.
  private static func columns(_ db: Database, _ table: String, _ left: String, _ right: String)
    throws -> String
  {
    let theirs = Set(
      try String.fetchAll(
        db, sql: "SELECT name FROM \(right).pragma_table_info(?)", arguments: [table]))
    return try String.fetchAll(
      db, sql: "SELECT name FROM \(left).pragma_table_info(?)", arguments: [table]
    ).filter(theirs.contains).joined(separator: ",")
  }
}
