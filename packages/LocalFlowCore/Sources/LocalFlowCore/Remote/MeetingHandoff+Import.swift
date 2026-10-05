import Foundation
import GRDB

/// Feature 020 (User Story 6, ADR 0034): a meeting recorded on the iPhone reaches the
/// owner's Mac once, through the server. The phone marks its upload `copy` and sends
/// `release` once it has its result; the Mac then downloads the processed bundle and every
/// AAC file, inserts the meeting in one transaction with `origin='iphone'`, and deletes the
/// server copy. Only the Mac calls this; it runs speaker identification and the summary
/// afterwards, as for its own meetings.
extension MeetingHandoff {
  public struct Imported: Sendable, Equatable {
    public let id: UUID
    /// The server's diarization was accepted.
    public let labeled: Bool

    public init(id: UUID, labeled: Bool) {
      self.id = id
      self.labeled = labeled
    }
  }

  /// The meeting's recording rows in a downloaded bundle; `%@` is the bundle's schema.
  private static let recordingRows: [(table: String, filter: String)] = [
    ("meetings", "id=?"),
    ("meeting_tracks", "meeting_id=?"),
    ("meeting_segments", "track_id IN (SELECT id FROM %@.meeting_tracks WHERE meeting_id=?)"),
    ("meeting_pauses", "meeting_id=?"),
    ("meeting_notes", "meeting_id=?"),
  ]

  /// Imports every finished phone meeting waiting for this Mac: sent by another device of
  /// the same user (`mine: false`), with a copy asked for, released by the phone, `done`.
  /// A meeting already here (its delete was lost) is not imported again; its server copy
  /// goes. A failed download, checksum or insert leaves this Mac unchanged and keeps the
  /// server copy for the next call.
  public func importPhoneMeetings() async -> [Imported] {
    guard let list = try? await call(.init(action: .list)) else { return [] }
    var imported: [Imported] = []
    for entry in list.meetings ?? []
    where !entry.mine && entry.copy && entry.released && entry.state == .done {
      let id = entry.meeting
      let folder = directory.appendingPathComponent("Import-\(id.uuidString)", isDirectory: true)
      defer { try? FileManager.default.removeItem(at: folder) }
      do {
        if let labeled = try await importMeeting(id, folder: folder) {
          imported.append(.init(id: id, labeled: labeled))
        }
      } catch {
        continue
      }
      _ = try? await call(.init(action: .delete, meeting: id))
    }
    return imported
  }

  /// Nil when the meeting is already here.
  private func importMeeting(_ id: UUID, folder: URL) async throws -> Bool? {
    let key = id.uuidString
    let present = try await database.read { db in
      try Bool.fetchOne(db, sql: "SELECT 1 FROM meetings WHERE id=?", arguments: [key]) ?? false
    }
    guard !present else { return nil }
    try? FileManager.default.removeItem(at: folder)
    try FileManager.default.createDirectory(
      at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let bundle = folder.appendingPathComponent("bundle.sqlite")
    try await fetch(id, name: nil, to: bundle)

    // Every finished segment file, downloaded and verified before anything is placed.
    let paths = try await database.writeWithoutTransaction { db in
      try db.execute(sql: "ATTACH DATABASE ? AS result", arguments: [bundle.path])
      defer { try? db.execute(sql: "DETACH DATABASE result") }
      return try String.fetchAll(
        db,
        sql: """
          SELECT s.relative_path FROM result.meeting_segments s
          JOIN result.meeting_tracks t ON t.id=s.track_id
          WHERE t.meeting_id=? AND s.state='finalized' ORDER BY s.relative_path
          """, arguments: [key])
    }
    var files: [(download: URL, target: URL)] = []
    for path in paths {
      guard path.hasPrefix(key + "/"), let target = root.resolve(relativePath: path),
        !FileManager.default.fileExists(atPath: target.path)
      else { throw RemoteChannelError.protocolError }
      let download = folder.appendingPathComponent(target.lastPathComponent)
      try await fetch(id, name: target.lastPathComponent, to: download)
      files.append((download, target))
    }

    var placed: [URL] = []
    do {
      for file in files {
        try FileManager.default.createDirectory(
          at: file.target.deletingLastPathComponent(), withIntermediateDirectories: true,
          attributes: [.posixPermissions: 0o700])
        try FileManager.default.moveItem(at: file.download, to: file.target)
        placed.append(file.target)
      }
      return try await insert(id, from: bundle)
    } catch {
      for url in placed { try? FileManager.default.removeItem(at: url) }
      if !placed.isEmpty {
        try? FileManager.default.removeItem(at: root.meetingDirectory(id))
      }
      throw error
    }
  }

  /// The bundle's meeting, its recording rows and its results in one transaction, with the
  /// capacity counter kept exact. Returns whether a diarization run was accepted.
  private func insert(_ id: UUID, from url: URL) async throws -> Bool {
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
          try Bool.fetchOne(
            db, sql: "SELECT state IN ('completed','interrupted') FROM result.meetings WHERE id=?",
            arguments: [key]) == true,
          try Bool.fetchOne(db, sql: "SELECT 1 FROM main.meetings WHERE id=?", arguments: [key])
            == nil
        else { throw RemoteChannelError.protocolError }
        try db.execute(sql: "PRAGMA defer_foreign_keys=ON")
        try db.execute(
          sql: """
            UPDATE main.transcript_usage SET
              text_bytes=text_bytes
                +(SELECT text_bytes FROM result.meeting_transcriptions WHERE meeting_id=?1),
              segment_rows=segment_rows
                +(SELECT segment_count FROM result.meeting_transcriptions WHERE meeting_id=?1)
            WHERE id=1
            """, arguments: [key])
        for (table, filter) in Self.recordingRows + Self.outputs {
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
        try db.execute(
          sql: "UPDATE main.meetings SET origin='iphone', run_locally=0 WHERE id=?",
          arguments: [key])
        // The server ran these stages.
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
}
