import Foundation
import GRDB
import LocalFlowCore
import OSLog

/// Feature 014: dictations whose remote recognition failed while no local speech model
/// was installed (FR-018). The audio moves from the spool into `PendingAudio/` and the
/// row is written in the same step; both go together. At most 20 rows. Rows are never
/// dropped silently: a full store refuses the next dictation so the app can ask the user.
actor PendingRemoteDictationStore {
  static let maximumRows = 20
  static let maximumAgeMilliseconds: Int64 = 24 * 60 * 60 * 1_000
  /// First retry 10 s after the failure; later ones follow `PendingRemoteRetrier`.
  static let firstRetryMilliseconds: Int64 = 10_000

  enum Failure: Error, Equatable, Sendable {
    case full
    case invalidAudio
    case missing
  }

  struct Item: Sendable, Equatable, Identifiable {
    let id: UUID
    /// A file name inside `PendingAudio/`, never a path.
    let audioFile: String
    let sampleCount: Int
    let createdAt: Int64
    let attempts: Int
    let nextAttemptAt: Int64
    let lastFailure: RemoteFailureReason?
    let targetBundleID: String?
    /// Feature 019: the microphone, copied into the final history row. Nil for rows
    /// queued before `input-device-v18`.
    var inputDevice: DictationInputDevice? = nil

    func isExpired(now: Int64) -> Bool {
      now - createdAt >= PendingRemoteDictationStore.maximumAgeMilliseconds
    }
  }

  nonisolated let directory: URL
  private let database: DatabasePool

  init(database: DatabasePool, directory: URL) throws {
    self.database = database
    self.directory = directory
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    guard chmod(directory.path, 0o700) == 0 else { throw CocoaError(.fileWriteNoPermission) }
  }

  static func isPlainFileName(_ name: String) -> Bool {
    !name.isEmpty && name != "." && name != ".." && !name.contains("/") && name.utf8.count <= 255
  }

  nonisolated func audioURL(_ item: Item) -> URL {
    directory.appendingPathComponent(item.audioFile, isDirectory: false)
  }

  /// Moves `audio` into `PendingAudio/` and writes the row; on a refusal the file stays
  /// where it was. Throws `full` when 20 dictations are already waiting.
  func add(
    id: UUID, audio: URL, sampleCount: Int, failure: RemoteFailureReason,
    targetBundleID: String?, inputDevice: DictationInputDevice? = nil, now: Int64
  ) throws -> Item {
    guard (1...RemoteProtocol.maximumSessionSamples).contains(sampleCount) else {
      throw Failure.invalidAudio
    }
    let count = try database.read {
      try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM pending_remote_dictations") ?? 0
    }
    guard count < Self.maximumRows else { throw Failure.full }
    let item = Item(
      id: id, audioFile: "\(id.uuidString).f32", sampleCount: sampleCount, createdAt: now,
      attempts: 0, nextAttemptAt: now + Self.firstRetryMilliseconds, lastFailure: failure,
      targetBundleID: targetBundleID, inputDevice: inputDevice)
    let destination = audioURL(item)
    try FileManager.default.moveItem(at: audio, to: destination)
    do {
      try database.write { db in
        let count =
          try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM pending_remote_dictations") ?? 0
        guard count < Self.maximumRows else { throw Failure.full }
        try db.execute(
          sql: """
            INSERT INTO pending_remote_dictations
              (id,audio_file,sample_count,created_at,attempts,next_attempt_at,last_failure,target_bundle_id,input_device_name,input_device_kind)
            VALUES (?,?,?,?,0,?,?,?,?,?)
            """,
          arguments: [
            id.uuidString, item.audioFile, sampleCount, now, item.nextAttemptAt, failure.rawValue,
            targetBundleID, inputDevice?.name, inputDevice?.kind.rawValue,
          ])
      }
    } catch {
      // The row did not commit: give the audio back to its owner.
      try? FileManager.default.moveItem(at: destination, to: audio)
      throw error
    }
    return item
  }

  func all() throws -> [Item] {
    try database.read { db in
      try Row.fetchAll(
        db, sql: "SELECT * FROM pending_remote_dictations ORDER BY created_at, id"
      ).compactMap(Self.item)
    }
  }

  func get(_ id: UUID) throws -> Item? {
    try database.read { db in
      try Row.fetchOne(
        db, sql: "SELECT * FROM pending_remote_dictations WHERE id=?", arguments: [id.uuidString]
      ).flatMap(Self.item)
    }
  }

  func recordAttempt(id: UUID, failure: RemoteFailureReason, nextAttemptAt: Int64) throws {
    try database.write { db in
      try db.execute(
        sql: """
          UPDATE pending_remote_dictations
          SET attempts = attempts + 1, last_failure = ?, next_attempt_at = ? WHERE id = ?
          """, arguments: [failure.rawValue, nextAttemptAt, id.uuidString])
      guard db.changesCount == 1 else { throw Failure.missing }
    }
  }

  /// Deletes the row and its audio file.
  func remove(id: UUID) throws {
    let item = try get(id)
    try database.write { db in
      try db.execute(
        sql: "DELETE FROM pending_remote_dictations WHERE id=?", arguments: [id.uuidString])
    }
    if let item, FileManager.default.fileExists(atPath: audioURL(item).path) {
      try FileManager.default.removeItem(at: audioURL(item))
    }
  }

  /// "Copy": writes the waiting audio as a 16 kHz mono Float32 WAV file the user chose.
  func exportWAV(id: UUID, to destination: URL) throws {
    guard let item = try get(id) else { throw Failure.missing }
    try Self.wav(fromFloat32: Data(contentsOf: audioURL(item))).write(
      to: destination, options: .atomic)
  }

  nonisolated static func wav(fromFloat32 samples: Data) -> Data {
    var data = Data()
    func append<T: FixedWidthInteger>(_ value: T) {
      withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }
    data.append(contentsOf: Array("RIFF".utf8))
    append(UInt32(36 + samples.count))
    data.append(contentsOf: Array("WAVEfmt ".utf8))
    append(UInt32(16))
    append(UInt16(3))  // IEEE float
    append(UInt16(1))
    append(UInt32(16_000))
    append(UInt32(16_000 * 4))
    append(UInt16(4))
    append(UInt16(32))
    data.append(contentsOf: Array("data".utf8))
    append(UInt32(samples.count))
    return data + samples
  }

  /// At startup: files without rows are deleted and rows without files are dropped.
  func reconcile() throws -> (removedFiles: Int, droppedRows: Int) {
    let items = try all()
    let names = Set(items.map(\.audioFile))
    var removedFiles = 0
    for name in (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
    where !names.contains(name) {
      try FileManager.default.removeItem(at: directory.appendingPathComponent(name))
      removedFiles += 1
    }
    var droppedRows = 0
    for item in items where !FileManager.default.fileExists(atPath: audioURL(item).path) {
      try database.write { db in
        try db.execute(
          sql: "DELETE FROM pending_remote_dictations WHERE id=?", arguments: [item.id.uuidString])
      }
      droppedRows += 1
    }
    if removedFiles + droppedRows > 0 {
      Logger(subsystem: "org.localflow.LocalFlow", category: "remote").notice(
        "Pending remote audio reconciled: files=\(removedFiles) rows=\(droppedRows)")
    }
    return (removedFiles, droppedRows)
  }

  private static func item(_ row: Row) -> Item? {
    let idString: String = row["id"]
    let name: String = row["audio_file"]
    guard let id = UUID(uuidString: idString), isPlainFileName(name) else { return nil }
    let failure: String? = row["last_failure"]
    return Item(
      id: id, audioFile: name, sampleCount: row["sample_count"], createdAt: row["created_at"],
      attempts: row["attempts"], nextAttemptAt: row["next_attempt_at"],
      lastFailure: failure.flatMap(RemoteFailureReason.init(rawValue:)),
      targetBundleID: row["target_bundle_id"],
      inputDevice: DictationInputDevice(
        storedName: row["input_device_name"], storedKind: row["input_device_kind"]))
  }
}
