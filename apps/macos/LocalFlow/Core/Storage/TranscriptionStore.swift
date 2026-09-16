import Foundation
import GRDB

#if canImport(Darwin)
  import Darwin
#endif

public actor TranscriptionStore {
  public static let maximumRows = 10_000
  public static let maximumPayloadBytes = 33_554_432
  public static let reservationBytes = 65_536
  public static let maximumTextBytes = 65_536

  public enum Error: Swift.Error, Equatable, Sendable {
    case invalidQuery
    case invalidText
    case invalidTargetBundleID
    case invalidRevision
    case invalidReservation
    case reservationBusy
    case capacityExceeded
    case conflictingContent
    case missingEntry
    case staleRevision
    case invalidAttempt
    case busy
    case damagedDatabase
    case databaseLimitExceeded
  }

  public struct Reservation: Sendable, Equatable {
    fileprivate let id: UUID
    fileprivate let bytes: Int
  }

  public struct Attempt: Sendable, Equatable {
    public let id: UUID
    public let entry: TranscriptionEntry
  }

  public enum Outcome: Sendable, Equatable {
    case confirmed
    case notInserted
    case uncertain
  }

  private let database: DatabaseQueue
  private let databaseURL: URL
  private var reservations: [UUID: Reservation] = [:]

  public func verifyWritable() async throws {
    try await database.write { db in
      // Exercise the durable write path without changing history or admission counts.
      try db.execute(sql: "UPDATE history_usage SET row_count = row_count WHERE id = 1")
    }
  }

  public init(path: String, maximumDatabaseBytes: Int = 128 * 1024 * 1024) throws {
    guard maximumDatabaseBytes > 0, maximumDatabaseBytes <= 128 * 1024 * 1024 else {
      throw Error.databaseLimitExceeded
    }
    databaseURL = URL(fileURLWithPath: path)
    // Create the database privately before SQLite creates its rollback journal.
    let fd = open(path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard fd >= 0 else { throw Error.damagedDatabase }
    guard fchmod(fd, 0o600) == 0 else {
      close(fd)
      throw Error.damagedDatabase
    }
    close(fd)
    var configuration = Configuration()
    configuration.prepareDatabase { db in
      db.add(
        function: DatabaseFunction("history_matches", argumentCount: 2, pure: true) { values in
          guard let text = String.fromDatabaseValue(values[0]),
            let query = String.fromDatabaseValue(values[1]), text.utf8.count <= 65_536
          else { return false }
          // At most 64 KiB input; canonical composition and case matching use bounded row scratch.
          return text.precomposedStringWithCanonicalMapping.range(
            of: query, options: [.caseInsensitive, .literal],
            locale: Locale(identifier: "en_US_POSIX")) != nil
        })
      try db.execute(sql: "PRAGMA journal_mode=DELETE")
      try db.execute(sql: "PRAGMA synchronous=FULL")
      try db.execute(sql: "PRAGMA fullfsync=ON")
      try db.execute(sql: "PRAGMA mmap_size=0")
      try db.execute(sql: "PRAGMA cache_size=-2048")
      guard let pageSize = try Int.fetchOne(db, sql: "PRAGMA page_size"), pageSize > 0 else {
        throw Error.damagedDatabase
      }
      let cap = maximumDatabaseBytes / pageSize
      guard cap > 0 else { throw Error.databaseLimitExceeded }
      guard try Int.fetchOne(db, sql: "PRAGMA max_page_count=\(cap)") == cap,
        try String.fetchOne(db, sql: "PRAGMA journal_mode") == "delete",
        try Int.fetchOne(db, sql: "PRAGMA synchronous") == 2,
        try Int.fetchOne(db, sql: "PRAGMA fullfsync") == 1,
        try Int.fetchOne(db, sql: "PRAGMA mmap_size") == 0,
        try Int.fetchOne(db, sql: "PRAGMA cache_size") == -2048
      else { throw Error.databaseLimitExceeded }
    }
    self.database = try DatabaseQueue(path: path, configuration: configuration)
    try Self.verifyDatabaseBounds(database)
    try HistoryMigrations.migrator().migrate(database)
    try Self.verifyDatabaseBounds(database)
    try database.write { db in
      try db.execute(
        sql:
          "UPDATE transcriptions SET delivery_state='uncertain', recovery_state='needs_review', revision=revision+1 WHERE delivery_state='attempting'"
      )
      try db.execute(
        sql:
          "UPDATE history_usage SET row_count=(SELECT count(*) FROM transcriptions), payload_bytes=(SELECT coalesce(sum(length(cast(text AS blob))),0) FROM transcriptions) WHERE id=1"
      )
    }
  }

  public func reserve(maxBytes: Int = reservationBytes) throws -> Reservation {
    guard maxBytes > 0, maxBytes <= Self.reservationBytes else { throw Error.invalidReservation }
    guard reservations.isEmpty else { throw Error.reservationBusy }
    let available =
      try FileManager.default.attributesOfFileSystem(
        forPath: databaseURL.deletingLastPathComponent().path)[.systemFreeSize] as? NSNumber
    guard let available, available.int64Value >= 129 * 1024 * 1024 + Int64(Self.reservationBytes)
    else {
      throw Error.databaseLimitExceeded
    }
    let reservation = Reservation(id: UUID(), bytes: Self.reservationBytes)
    let reservedRows = reservations.count
    let reservedBytes = reservations.values.reduce(0) { $0 + $1.bytes }
    try database.read { db in
      let usage = try Self.usage(db)
      guard usage.count + reservedRows + 1 <= Self.maximumRows,
        usage.bytes + reservedBytes + reservation.bytes <= Self.maximumPayloadBytes
      else {
        throw Error.capacityExceeded
      }
    }
    reservations[reservation.id] = reservation
    return reservation
  }

  public func releaseReservation(_ reservation: Reservation) {
    reservations.removeValue(forKey: reservation.id)
  }

  @discardableResult
  public func commit(reservation: Reservation, entry: TranscriptionEntry) throws
    -> TranscriptionEntry
  {
    guard reservations[reservation.id] != nil else { throw Error.invalidReservation }
    let saved = try database.write { db -> TranscriptionEntry in
      let usage = try Self.usage(db)
      if let existing = try Self.fetch(entry.id, db: db) {
        guard existing.text == entry.text else { throw Error.conflictingContent }
        return existing
      }
      let otherReservations = reservations.values.filter { $0.id != reservation.id }
      let entryBytes = entry.text.data(using: .utf8)?.count ?? Int.max
      guard usage.count + otherReservations.count + 1 <= Self.maximumRows,
        usage.bytes + otherReservations.reduce(0, { $0 + $1.bytes }) + entryBytes
          <= Self.maximumPayloadBytes
      else {
        throw Error.capacityExceeded
      }
      let normalized = try TranscriptionEntry(
        id: entry.id, text: entry.text, createdAtMilliseconds: entry.createdAtMilliseconds,
        deliveryState: .notAttempted, recoveryState: .needsReview, quality: entry.quality,
        stopReason: entry.stopReason, targetBundleID: entry.targetBundleID, revision: 0)
      try db.execute(
        sql: """
          INSERT INTO transcriptions (id,text,created_at,delivery_state,recovery_state,quality,stop_reason,target_bundle_id,attempt_id,attempt_started_at,revision)
          VALUES (?,?,?,?,?,?,?,?,?,?,?)
          """,
        arguments: [
          normalized.id.uuidString, normalized.text, normalized.createdAtMilliseconds,
          normalized.deliveryState.rawValue, normalized.recoveryState.rawValue,
          normalized.quality.rawValue,
          normalized.stopReason.rawValue, normalized.targetBundleID, nil, nil, normalized.revision,
        ])
      try db.execute(
        sql:
          "UPDATE history_usage SET row_count=row_count+1, payload_bytes=payload_bytes+? WHERE id=1",
        arguments: [entry.text.data(using: .utf8)!.count])
      return normalized
    }
    reservations.removeValue(forKey: reservation.id)
    return saved
  }

  public func hasRecovery() throws -> Bool {
    try database.read { db in
      try Bool.fetchOne(
        db,
        sql: "SELECT EXISTS(SELECT 1 FROM transcriptions WHERE recovery_state = 'needs_review')")
        ?? false
    }
  }

  public func get(_ id: UUID) throws -> TranscriptionEntry? {
    try database.read { try Self.fetch(id, db: $0) }
  }

  public func recent(limit: Int = 20) throws -> [TranscriptionEntry] {
    let count = min(max(limit, 0), 20)
    return try database.read { db in
      try Self.fetchAll(
        db, sql: "SELECT * FROM transcriptions ORDER BY created_at DESC, id DESC LIMIT ?",
        arguments: [count])
    }
  }

  public struct HistoryCursor: Sendable, Equatable {
    public let timestamp: Int64
    public let id: String
    public init(_ entry: TranscriptionEntry) {
      timestamp = entry.createdAtMilliseconds
      id = entry.id.uuidString
    }
    fileprivate init(timestamp: Int64, id: String) {
      self.timestamp = timestamp
      self.id = id
    }
  }

  public enum HistoryDirection: Sendable { case older, newer }

  public struct HistoryPage: Sendable {
    public let entries: [TranscriptionEntry]
    public let watermark: HistoryCursor?
    public let hasMore: Bool
  }

  public static func validatedQuery(_ query: String) throws -> String {
    guard query.unicodeScalars.count <= 256, query.utf8.count <= 1024 else {
      throw Error.invalidQuery
    }
    return query.precomposedStringWithCanonicalMapping
  }

  /// Each read visits at most 20 rows. Yielding between reads lets durable writes run
  /// ahead of a long search and bounds cancellation latency to one small batch.
  public func page(
    query: String = "", cursor: HistoryCursor? = nil,
    direction: HistoryDirection = .older,
    watermark: HistoryCursor? = nil
  ) async throws -> HistoryPage {
    let query = try Self.validatedQuery(query)
    let ceiling: HistoryCursor?
    if let watermark {
      ceiling = watermark
    } else {
      ceiling = try await database.read { db in
        guard
          let row = try Row.fetchOne(
            db,
            sql: "SELECT created_at,id FROM transcriptions ORDER BY created_at DESC,id DESC LIMIT 1"
          )
        else { return nil }
        return HistoryCursor(timestamp: row["created_at"], id: row["id"])
      }
    }
    guard let ceiling else { return HistoryPage(entries: [], watermark: nil, hasMore: false) }
    var boundary = cursor
    var found: [TranscriptionEntry] = []
    while true {
      try Task.checkCancellation()
      let batchBoundary = boundary
      // Metadata only: SQLite normalizes one bounded payload at a time and
      // returns just a match bit. Never retain a second batch of full text.
      let batch: [(cursor: HistoryCursor, matches: Bool)] = try await database.read { db in
        let matchSQL = query.isEmpty ? "1" : "history_matches(text,?)"
        var sql =
          "SELECT created_at,id,\(matchSQL) AS matched FROM transcriptions WHERE (created_at,id) <= (?,?)"
        var arguments: StatementArguments = query.isEmpty ? [] : [query]
        arguments += [ceiling.timestamp, ceiling.id]
        if let boundary = batchBoundary {
          sql +=
            direction == .older ? " AND (created_at,id) < (?,?)" : " AND (created_at,id) > (?,?)"
          arguments += [boundary.timestamp, boundary.id]
        }
        sql +=
          direction == .older
          ? " ORDER BY created_at DESC,id DESC LIMIT 20"
          : " ORDER BY created_at ASC,id ASC LIMIT 20"
        return try Row.fetchAll(db, sql: sql, arguments: arguments).map { row in
          (HistoryCursor(timestamp: row["created_at"], id: row["id"]), row["matched"])
        }
      }
      for match in batch where match.matches {
        try Task.checkCancellation()
        if found.count == 20 {
          return HistoryPage(
            entries: direction == .older ? found : found.reversed(), watermark: ceiling,
            hasMore: true)
        }
        guard let id = UUID(uuidString: match.cursor.id) else { throw Error.damagedDatabase }
        if let entry = try await database.read({ db in try Self.fetch(id, db: db) }) {
          found.append(entry)
        }
      }
      guard batch.count == 20, let last = batch.last else {
        return HistoryPage(
          entries: direction == .older ? found : found.reversed(), watermark: ceiling,
          hasMore: false)
      }
      boundary = last.cursor
      await Task.yield()
    }
  }

  public func beginAttempt(id: UUID, revision: Int64) throws -> Attempt {
    let attemptID = UUID()
    let entry = try database.write { db -> TranscriptionEntry in
      guard let current = try Self.fetch(id, db: db) else { throw Error.missingEntry }
      guard current.revision == revision else { throw Error.staleRevision }
      guard current.deliveryState != .attempting else { throw Error.busy }
      let next = try TranscriptionEntry(
        id: current.id, text: current.text, createdAtMilliseconds: current.createdAtMilliseconds,
        deliveryState: .attempting, recoveryState: .needsReview, quality: current.quality,
        stopReason: current.stopReason, targetBundleID: current.targetBundleID,
        attemptID: attemptID,
        attemptStartedAtMilliseconds: Int64(Date().timeIntervalSince1970 * 1000),
        revision: revision + 1)
      try Self.update(next, db: db)
      return next
    }
    return Attempt(id: attemptID, entry: entry)
  }

  public func recordOutcome(id: UUID, revision: Int64, attemptID: UUID, outcome: Outcome) throws
    -> TranscriptionEntry
  {
    try database.write { db in
      guard let current = try Self.fetch(id, db: db), current.revision == revision,
        current.attemptID == attemptID, current.deliveryState == .attempting
      else { throw Error.invalidAttempt }
      let state: TranscriptionEntry.DeliveryState =
        outcome == .confirmed ? .confirmed : outcome == .notInserted ? .notInserted : .uncertain
      let recovery: TranscriptionEntry.RecoveryState =
        outcome == .confirmed ? .resolved : .needsReview
      let next = try TranscriptionEntry(
        id: current.id, text: current.text, createdAtMilliseconds: current.createdAtMilliseconds,
        deliveryState: state, recoveryState: recovery, quality: current.quality,
        stopReason: current.stopReason, targetBundleID: current.targetBundleID,
        attemptID: current.attemptID,
        attemptStartedAtMilliseconds: current.attemptStartedAtMilliseconds, revision: revision + 1)
      try Self.update(next, db: db)
      return next
    }
  }

  public func dismissRecovery(id: UUID, revision: Int64) throws -> TranscriptionEntry {
    try database.write { db in
      guard let current = try Self.fetch(id, db: db), current.revision == revision else {
        throw Error.staleRevision
      }
      guard current.deliveryState != .attempting else { throw Error.busy }
      let next = try TranscriptionEntry(
        id: current.id, text: current.text, createdAtMilliseconds: current.createdAtMilliseconds,
        deliveryState: current.deliveryState, recoveryState: .resolved, quality: current.quality,
        stopReason: current.stopReason, targetBundleID: current.targetBundleID,
        attemptID: current.attemptID,
        attemptStartedAtMilliseconds: current.attemptStartedAtMilliseconds, revision: revision + 1)
      try Self.update(next, db: db)
      return next
    }
  }

  public func deleteConfirmed(id: UUID, revision: Int64) throws {
    try database.write { db in
      guard let current = try Self.fetch(id, db: db), current.revision == revision else {
        throw Error.staleRevision
      }
      guard current.deliveryState != .attempting else { throw Error.busy }
      try db.execute(
        sql: "DELETE FROM transcriptions WHERE id=? AND revision=?",
        arguments: [id.uuidString, revision])
      try db.execute(
        sql:
          "UPDATE history_usage SET row_count=row_count-1, payload_bytes=payload_bytes-? WHERE id=1",
        arguments: [current.text.data(using: .utf8)!.count])
    }
  }

  private static func usage(_ db: Database) throws -> (count: Int, bytes: Int) {
    let row = try Row.fetchOne(
      db, sql: "SELECT row_count, payload_bytes FROM history_usage WHERE id=1")
    guard let row else { throw Error.damagedDatabase }
    return (row["row_count"], row["payload_bytes"])
  }

  private static func fetch(_ id: UUID, db: Database) throws -> TranscriptionEntry? {
    try fetchAll(db, sql: "SELECT * FROM transcriptions WHERE id=?", arguments: [id.uuidString])
      .first
  }

  private static func fetchAll(_ db: Database, sql: String, arguments: StatementArguments = [])
    throws -> [TranscriptionEntry]
  {
    try Row.fetchAll(db, sql: sql, arguments: arguments).map { row in
      let idString: String? = row["id"]
      let deliveryString: String? = row["delivery_state"]
      let recoveryString: String? = row["recovery_state"]
      let qualityString: String? = row["quality"]
      let stopString: String? = row["stop_reason"]
      let attemptString: String? = row["attempt_id"]
      guard let idString, let id = UUID(uuidString: idString),
        let delivery = deliveryString.flatMap(TranscriptionEntry.DeliveryState.init(rawValue:)),
        let recovery = recoveryString.flatMap(TranscriptionEntry.RecoveryState.init(rawValue:)),
        let quality = qualityString.flatMap(TranscriptionEntry.Quality.init(rawValue:)),
        let stop = stopString.flatMap(TranscriptionEntry.StopReason.init(rawValue:))
      else { throw Error.damagedDatabase }
      let text: String = row["text"]
      let createdAt: Int64 = row["created_at"]
      let targetBundleID: String? = row["target_bundle_id"]
      let attemptStartedAt: Int64? = row["attempt_started_at"]
      let revision: Int64 = row["revision"]
      return try TranscriptionEntry(
        id: id, text: text, createdAtMilliseconds: createdAt, deliveryState: delivery,
        recoveryState: recovery, quality: quality, stopReason: stop, targetBundleID: targetBundleID,
        attemptID: attemptString.flatMap(UUID.init(uuidString:)),
        attemptStartedAtMilliseconds: attemptStartedAt, revision: revision)
    }
  }

  private static func update(_ entry: TranscriptionEntry, db: Database) throws {
    try db.execute(
      sql:
        "UPDATE transcriptions SET delivery_state=?, recovery_state=?, attempt_id=?, attempt_started_at=?, revision=? WHERE id=?",
      arguments: [
        entry.deliveryState.rawValue, entry.recoveryState.rawValue, entry.attemptID?.uuidString,
        entry.attemptStartedAtMilliseconds, entry.revision, entry.id.uuidString,
      ])
  }

  private static func verifyDatabaseBounds(_ db: DatabaseQueue) throws {
    try db.read { database in
      let pageSize: Int = try Int.fetchOne(database, sql: "PRAGMA page_size") ?? 0
      let pageCount: Int = try Int.fetchOne(database, sql: "PRAGMA page_count") ?? 0
      guard pageSize > 0, pageCount * pageSize <= 128 * 1024 * 1024 else {
        throw Error.databaseLimitExceeded
      }
    }
  }
}
