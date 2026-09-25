import Foundation
import GRDB

#if canImport(Darwin)
  import Darwin
#endif

public actor TranscriptionStore {
  public static let maximumRows = 10_000
  public static let maximumPayloadBytes = 33_554_432
  /// Text, quality detail and (Feature 012) the context row: snapshot 8 KiB,
  /// pre-spelling text 64 KiB and spelling changes 32 KiB.
  public static let reservationBytes = 393_216 + 106_496
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
    case invalidContext
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

  /// Shared with every history store; all use one file, one WAL and one page ceiling.
  /// One writer connection serializes writes; readers see the last committed state.
  nonisolated let database: DatabasePool
  private let databaseURL: URL
  private var reservations: [UUID: Reservation] = [:]

  /// After a checkpoint the WAL is truncated to this size, so the file beside the
  /// database stays small between large meeting transactions.
  static let journalSizeLimitBytes = 4 * 1024 * 1024
  private static let matchLocale = Locale(identifier: "en_US_POSIX")

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
    // Create the database privately before SQLite creates its WAL and shared-memory
    // files; SQLite gives both the database file's permissions.
    let fd = open(path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard fd >= 0 else { throw Error.damagedDatabase }
    guard fchmod(fd, 0o600) == 0 else {
      close(fd)
      throw Error.damagedDatabase
    }
    close(fd)
    var configuration = Configuration()
    // Two readers are enough for history and meeting pages beside one writer.
    configuration.maximumReaderCount = 2
    configuration.prepareDatabase { db in
      let locale = Self.matchLocale
      db.add(
        function: DatabaseFunction("history_matches", argumentCount: 2, pure: true) { values in
          guard let text = String.fromDatabaseValue(values[0]),
            let query = String.fromDatabaseValue(values[1]), text.utf8.count <= 65_536
          else { return false }
          // At most 64 KiB input; canonical composition and case matching use bounded row scratch.
          return text.precomposedStringWithCanonicalMapping.range(
            of: query, options: [.caseInsensitive, .literal], locale: locale) != nil
        })
      // WAL with synchronous=FULL and full fsyncs keeps every commit as durable as the
      // rollback journal did, while readers no longer wait for a long meeting write.
      if !db.configuration.readonly {
        try db.execute(sql: "PRAGMA journal_mode=WAL")
      }
      try db.execute(sql: "PRAGMA synchronous=FULL")
      try db.execute(sql: "PRAGMA fullfsync=ON")
      try db.execute(sql: "PRAGMA checkpoint_fullfsync=ON")
      try db.execute(sql: "PRAGMA mmap_size=0")
      try db.execute(sql: "PRAGMA cache_size=-2048")
      guard let pageSize = try Int.fetchOne(db, sql: "PRAGMA page_size"), pageSize > 0 else {
        throw Error.damagedDatabase
      }
      let cap = maximumDatabaseBytes / pageSize
      guard cap > 0 else { throw Error.databaseLimitExceeded }
      guard try Int.fetchOne(db, sql: "PRAGMA max_page_count=\(cap)") == cap,
        try Int.fetchOne(db, sql: "PRAGMA journal_size_limit=\(Self.journalSizeLimitBytes)")
          == Self.journalSizeLimitBytes,
        try String.fetchOne(db, sql: "PRAGMA journal_mode") == "wal",
        try Self.hasDurableSync(db),
        try Int.fetchOne(db, sql: "PRAGMA mmap_size") == 0,
        try Int.fetchOne(db, sql: "PRAGMA cache_size") == -2048
      else { throw Error.databaseLimitExceeded }
    }
    self.database = try DatabasePool(path: path, configuration: configuration)
    // GRDB lowers the writer to synchronous=NORMAL when it enables WAL; restore FULL
    // before the first migration or history write.
    try database.writeWithoutTransaction { db in
      try db.execute(sql: "PRAGMA synchronous=FULL")
      guard try Self.hasDurableSync(db) else { throw Error.databaseLimitExceeded }
    }
    try Self.verifyDatabaseBounds(database)
    let migrator = HistoryMigrations.migrator()
    let migrationsPending = try database.read { try !migrator.hasCompletedMigrations($0) }
    try migrator.migrate(database)
    try Self.verifyDatabaseBounds(database)
    // Launch reads first and writes only when something needs repair, so an ordinary
    // start neither rescans every payload nor pays for an empty fsynced transaction.
    let repair = try database.read { db in
      try StartupRepair(
        attempting: Bool.fetchOne(
          db, sql: "SELECT EXISTS(SELECT 1 FROM transcriptions WHERE delivery_state='attempting')")
          ?? false,
        pendingAttempts: Self.hasPendingAttempts(db),
        reconcile: migrationsPending || Self.usageDrifted(db))
    }
    guard repair.attempting || repair.pendingAttempts || repair.reconcile else { return }
    try database.write { db in
      if repair.attempting {
        try db.execute(
          sql:
            "UPDATE transcriptions SET delivery_state='uncertain', recovery_state='needs_review', revision=revision+1 WHERE delivery_state='attempting'"
        )
      }
      // A rewrite left pending by a crash or quit is interrupted, never resumed.
      _ = try Self.interruptPendingAttempts(db)
      if repair.reconcile { try Self.reconcileUsage(db) }
    }
  }

  private struct StartupRepair {
    let attempting: Bool
    let pendingAttempts: Bool
    let reconcile: Bool
  }

  private static func hasDurableSync(_ db: Database) throws -> Bool {
    try Int.fetchOne(db, sql: "PRAGMA synchronous") == 2
      && Int.fetchOne(db, sql: "PRAGMA fullfsync") == 1
      && Int.fetchOne(db, sql: "PRAGMA checkpoint_fullfsync") == 1
  }

  private static func hasPendingAttempts(_ db: Database) throws -> Bool {
    try Bool.fetchOne(
      db, sql: "SELECT EXISTS(SELECT 1 FROM rewrite_attempts WHERE state='pending')") ?? false
  }

  /// Every write updates `history_usage` in the same transaction as the rows it counts,
  /// so a crash cannot make the counters drift. A full rescan runs after a migration
  /// (which may change what is counted) or when the cheap row-count check disagrees,
  /// which only an out-of-band edit can cause.
  private static func usageDrifted(_ db: Database) throws -> Bool {
    try Bool.fetchOne(
      db,
      sql: """
        SELECT row_count <> (SELECT count(*) FROM transcriptions) OR payload_bytes < 0
        FROM history_usage WHERE id=1
        """) ?? true
  }

  /// Usage counts transcript text, quality detail and every attempt's input plus output.
  private static func reconcileUsage(_ db: Database) throws {
    try db.execute(
      sql: """
        UPDATE history_usage SET row_count=(SELECT count(*) FROM transcriptions),
          payload_bytes=(SELECT coalesce(sum(length(cast(text AS blob))),0) FROM transcriptions)
            + (SELECT coalesce(sum(length(cast(detail_json AS blob))),0) FROM transcription_quality)
            + (SELECT coalesce(sum(length(cast(input_text AS blob)) + length(cast(coalesce(output_text,'') AS blob))),0) FROM rewrite_attempts)
            + (SELECT coalesce(sum(\(contextBytesSQL)),0) FROM dictation_contexts)
        WHERE id=1
        """)
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
    try commit(reservation: reservation, envelope: TranscriptionEnvelope(entry: entry, detail: nil))
  }

  @discardableResult
  func commit(reservation: Reservation, envelope: TranscriptionEnvelope) throws
    -> TranscriptionEntry
  {
    guard reservations[reservation.id] == reservation else { throw Error.invalidReservation }
    try envelope.validate()
    let entry = envelope.entry
    let detailData = try envelope.detail?.serialized()
    let detailJSON = detailData.map { String(decoding: $0, as: UTF8.self) }
    let entryBytes =
      entry.text.utf8.count + (detailData?.count ?? 0) + (envelope.context?.payloadBytes ?? 0)
    guard entryBytes <= reservation.bytes else { throw Error.capacityExceeded }
    let saved = try database.write { db -> TranscriptionEntry in
      let usage = try Self.usage(db)
      if let existing = try Self.fetch(entry.id, db: db) {
        let existingHash = try String.fetchOne(
          db,
          sql: "SELECT content_hash FROM transcription_quality WHERE transcription_id=?",
          arguments: [entry.id.uuidString])
        guard existing.text.utf8.elementsEqual(entry.text.utf8),
          existingHash == envelope.detail?.contentHash,
          existing.quality == entry.quality, existing.stopReason == entry.stopReason,
          existing.createdAtMilliseconds == entry.createdAtMilliseconds,
          existing.targetBundleID == entry.targetBundleID
        else { throw Error.conflictingContent }
        // Also validate the persisted bytes rather than trusting an orphaned hash column.
        if let detail = envelope.detail {
          let stored = try Self.fetchDetail(entry.id, normalizedText: existing.text, db: db)
          guard stored?.contentHash == detail.contentHash else { throw Error.conflictingContent }
        }
        guard try Self.fetchContext(entry.id, db: db) == envelope.context else {
          throw Error.conflictingContent
        }
        return existing
      }
      let otherReservations = reservations.values.filter { $0.id != reservation.id }
      guard usage.count + otherReservations.count + 1 <= Self.maximumRows,
        usage.bytes + otherReservations.reduce(0, { $0 + $1.bytes }) + entryBytes
          <= Self.maximumPayloadBytes
      else {
        throw Error.capacityExceeded
      }
      let normalized = try TranscriptionEntry(
        id: entry.id, text: entry.text, createdAtMilliseconds: entry.createdAtMilliseconds,
        deliveryState: .notAttempted, recoveryState: .needsReview, quality: entry.quality,
        stopReason: entry.stopReason, targetBundleID: entry.targetBundleID, revision: 0,
        hasQualityDetail: envelope.detail != nil)
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
      if let detailJSON, let detail = envelope.detail {
        try db.execute(
          sql:
            "INSERT INTO transcription_quality (transcription_id,schema_version,detail_json,content_hash) VALUES (?,1,?,?)",
          arguments: [entry.id.uuidString, detailJSON, detail.contentHash])
      }
      if let context = envelope.context {
        try db.execute(
          sql: """
            INSERT INTO dictation_contexts (transcription_id,outcome,capture_ms,app_bundle_id,snapshot_json,snapshot_hash,pre_spelling_text,spelling_changes_json,speller_version,rewrite_note)
            VALUES (?,?,?,?,?,?,?,?,?,?)
            """,
          arguments: [
            entry.id.uuidString, context.outcome.rawValue, context.captureMs, context.appBundleID,
            context.snapshotJSON, context.snapshotHash, context.preSpellingText,
            context.spellingChangesJSON, context.spellerVersion, context.rewriteNote,
          ])
      }
      try db.execute(
        sql:
          "UPDATE history_usage SET row_count=row_count+1, payload_bytes=payload_bytes+? WHERE id=1",
        arguments: [entryBytes])
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

  /// One consistent parent/detail snapshot, read only for the selected history item.
  func selectedEnvelope(_ id: UUID) throws -> TranscriptionEnvelope {
    try Task.checkCancellation()
    return try database.read { db in
      guard let entry = try Self.fetch(id, db: db) else { throw Error.missingEntry }
      try Task.checkCancellation()
      let detail = try Self.fetchDetail(id, normalizedText: entry.text, db: db)
      try Task.checkCancellation()
      return TranscriptionEnvelope(
        entry: entry, detail: detail, context: try Self.fetchContext(id, db: db))
    }
  }

  /// Call only for the selected record; legacy detail remains absent.
  func qualityDetail(_ id: UUID) throws -> TranscriptionQualityDetail? {
    try database.read { db in
      guard let entry = try Self.fetch(id, db: db) else { throw Error.missingEntry }
      return try Self.fetchDetail(id, normalizedText: entry.text, db: db)
    }
  }

  /// Feature 012: the dictation's context row; nil for a legacy entry ("not recorded").
  func context(for id: UUID) throws -> DictationContextRecord? {
    try database.read { try Self.fetchContext(id, db: $0) }
  }

  /// Records or clears the rewrite context note for the latest attempt only.
  func recordRewriteNote(_ note: String?, for id: UUID) throws {
    guard note == nil || note == DictationContextRecord.serverUnsupported else {
      throw Error.invalidContext
    }
    try database.write { db in
      try db.execute(
        sql: "UPDATE dictation_contexts SET rewrite_note=? WHERE transcription_id=?",
        arguments: [note, id.uuidString])
    }
  }

  private static let contextBytesSQL =
    "length(cast(coalesce(snapshot_json,'') AS blob)) + length(cast(coalesce(pre_spelling_text,'') AS blob)) + length(cast(coalesce(spelling_changes_json,'') AS blob))"

  private static func fetchContext(_ id: UUID, db: Database) throws -> DictationContextRecord? {
    guard
      let row = try Row.fetchOne(
        db, sql: "SELECT * FROM dictation_contexts WHERE transcription_id=?",
        arguments: [id.uuidString])
    else { return nil }
    let outcomeString: String = row["outcome"]
    guard let outcome = ContextOutcome(rawValue: outcomeString) else { throw Error.damagedDatabase }
    let record = DictationContextRecord(
      outcome: outcome, captureMs: row["capture_ms"], appBundleID: row["app_bundle_id"],
      snapshotJSON: row["snapshot_json"], preSpellingText: row["pre_spelling_text"],
      spellingChangesJSON: row["spelling_changes_json"], spellerVersion: row["speller_version"],
      rewriteNote: row["rewrite_note"])
    let hash: String? = row["snapshot_hash"]
    guard hash == record.snapshotHash else { throw Error.damagedDatabase }
    return record
  }

  private static func fetchDetail(_ id: UUID, normalizedText: String, db: Database) throws
    -> TranscriptionQualityDetail?
  {
    if let bytes = try Int.fetchOne(
      db,
      sql:
        "SELECT length(CAST(detail_json AS BLOB)) FROM transcription_quality WHERE transcription_id=?",
      arguments: [id.uuidString]), bytes > TranscriptionQualityDetail.maximumSerializedBytes
    {
      throw Error.damagedDatabase
    }
    guard
      let row = try Row.fetchOne(
        db,
        sql:
          "SELECT schema_version,detail_json,content_hash FROM transcription_quality WHERE transcription_id=?",
        arguments: [id.uuidString])
    else { return nil }
    let schema: Int = row["schema_version"]
    let json: String = row["detail_json"]
    let hash: String = row["content_hash"]
    guard schema == 1, json.utf8.count <= TranscriptionQualityDetail.maximumSerializedBytes else {
      throw Error.damagedDatabase
    }
    let detail = try TranscriptionQualityDetail.decode(
      Data(json.utf8), normalizedText: normalizedText)
    guard detail.contentHash == hash else { throw Error.damagedDatabase }
    return detail
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
      let wanted = 20 - found.count
      // One read per batch: SQLite normalizes one bounded payload at a time and returns
      // a match bit, then full rows are loaded only for the matches this page still
      // needs, from the same snapshot. Never retain a second batch of full text.
      let batch: [(cursor: HistoryCursor, matches: Bool, entry: TranscriptionEntry?)] =
        try await database.read { db in
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
          let rows: [(cursor: HistoryCursor, matches: Bool)] = try Row.fetchAll(
            db, sql: sql, arguments: arguments
          ).map { row in
            (HistoryCursor(timestamp: row["created_at"], id: row["id"]), row["matched"])
          }
          let ids = rows.filter(\.matches).prefix(wanted).map(\.cursor.id)
          var entries: [UUID: TranscriptionEntry] = [:]
          if !ids.isEmpty {
            let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
            for entry in try Self.fetchAll(
              db, sql: "SELECT * FROM transcriptions WHERE id IN (\(placeholders))",
              arguments: StatementArguments(ids))
            {
              entries[entry.id] = entry
            }
          }
          return rows.map { row in
            (row.cursor, row.matches, UUID(uuidString: row.cursor.id).flatMap { entries[$0] })
          }
        }
      for match in batch where match.matches {
        try Task.checkCancellation()
        if found.count == 20 {
          return HistoryPage(
            entries: direction == .older ? found : found.reversed(), watermark: ceiling,
            hasMore: true)
        }
        guard UUID(uuidString: match.cursor.id) != nil else { throw Error.damagedDatabase }
        if let entry = match.entry { found.append(entry) }
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
        revision: revision + 1, hasQualityDetail: current.hasQualityDetail,
        rewriteState: current.rewriteState, deliveredSource: current.deliveredSource,
        deliveredRewriteAttemptID: current.deliveredRewriteAttemptID)
      try Self.update(next, db: db)
      return next
    }
    return Attempt(id: attemptID, entry: entry)
  }

  public func recordOutcome(id: UUID, revision: Int64, attemptID: UUID, outcome: Outcome) throws
    -> TranscriptionEntry
  {
    try recordOutcome(
      id: id, revision: revision, attemptID: attemptID, outcome: outcome, delivery: .faithful)
  }

  /// The delivery record and the rewrite attempt it delivered are written in one
  /// transaction, so they can never disagree.
  func recordOutcome(
    id: UUID, revision: Int64, attemptID: UUID, outcome: Outcome, delivery: RewriteDelivery
  ) throws -> TranscriptionEntry {
    try database.write { db in
      guard let current = try Self.fetch(id, db: db), current.revision == revision,
        current.attemptID == attemptID, current.deliveryState == .attempting
      else { throw Error.invalidAttempt }
      let state: TranscriptionEntry.DeliveryState =
        outcome == .confirmed ? .confirmed : outcome == .notInserted ? .notInserted : .uncertain
      let recovery: TranscriptionEntry.RecoveryState =
        outcome == .confirmed ? .resolved : .needsReview
      let deliveredAttempt = delivery.source == .rewrite ? delivery.attemptID : nil
      if let deliveredAttempt {
        try Self.markDelivered(
          deliveredAttempt, transcriptionID: id,
          durationMilliseconds: delivery.durationMilliseconds,
          db: db)
      }
      let next = try TranscriptionEntry(
        id: current.id, text: current.text, createdAtMilliseconds: current.createdAtMilliseconds,
        deliveryState: state, recoveryState: recovery, quality: current.quality,
        stopReason: current.stopReason, targetBundleID: current.targetBundleID,
        attemptID: current.attemptID,
        attemptStartedAtMilliseconds: current.attemptStartedAtMilliseconds, revision: revision + 1,
        hasQualityDetail: current.hasQualityDetail, rewriteState: current.rewriteState,
        deliveredSource: delivery.source, deliveredRewriteAttemptID: deliveredAttempt)
      try Self.update(next, db: db)
      try db.execute(
        sql:
          "UPDATE transcriptions SET delivered_source=?, delivered_rewrite_attempt_id=? WHERE id=?",
        arguments: [delivery.source.rawValue, deliveredAttempt?.uuidString, id.uuidString])
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
        attemptStartedAtMilliseconds: current.attemptStartedAtMilliseconds, revision: revision + 1,
        hasQualityDetail: current.hasQualityDetail, rewriteState: current.rewriteState,
        deliveredSource: current.deliveredSource,
        deliveredRewriteAttemptID: current.deliveredRewriteAttemptID)
      try Self.update(next, db: db)
      return next
    }
  }

  public func deleteConfirmed(id: UUID, revision: Int64) throws {
    try database.write { db in
      guard let current = try Self.fetch(id, db: db), current.revision == revision else {
        throw Error.staleRevision
      }
      guard current.deliveryState != .attempting, current.rewriteState != .pending else {
        throw Error.busy
      }
      let detailBytes =
        try Int.fetchOne(
          db,
          sql:
            "SELECT length(cast(detail_json AS blob)) FROM transcription_quality WHERE transcription_id=?",
          arguments: [id.uuidString]) ?? 0
      // Attempts cascade with the row; their bytes leave the quota with it.
      let attemptBytes =
        try Int.fetchOne(
          db,
          sql:
            "SELECT coalesce(sum(length(cast(input_text AS blob)) + length(cast(coalesce(output_text,'') AS blob))),0) FROM rewrite_attempts WHERE transcription_id=?",
          arguments: [id.uuidString]) ?? 0
      // The context row cascades too (Feature 012).
      let contextBytes =
        try Int.fetchOne(
          db,
          sql: "SELECT \(Self.contextBytesSQL) FROM dictation_contexts WHERE transcription_id=?",
          arguments: [id.uuidString]) ?? 0
      try db.execute(
        sql: "DELETE FROM transcriptions WHERE id=? AND revision=?",
        arguments: [id.uuidString, revision])
      try db.execute(
        sql:
          "UPDATE history_usage SET row_count=row_count-1, payload_bytes=payload_bytes-? WHERE id=1",
        arguments: [current.text.utf8.count + detailBytes + attemptBytes + contextBytes])
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
    // One association bit per summary, never the detail payload.
    let summarySQL = sql.replacingOccurrences(
      of: "SELECT * FROM transcriptions",
      with:
        "SELECT transcriptions.*, EXISTS(SELECT 1 FROM transcription_quality q WHERE q.transcription_id=transcriptions.id) AS has_quality_detail FROM transcriptions"
    )
    return try Row.fetchAll(db, sql: summarySQL, arguments: arguments).map { row in
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
      let rewriteString: String? = row["rewrite_state"]
      let deliveredString: String? = row["delivered_source"]
      let deliveredAttemptString: String? = row["delivered_rewrite_attempt_id"]
      guard let rewriteState = TranscriptionEntry.RewriteState(rawValue: rewriteString ?? "") else {
        throw Error.damagedDatabase
      }
      return try TranscriptionEntry(
        id: id, text: text, createdAtMilliseconds: createdAt, deliveryState: delivery,
        recoveryState: recovery, quality: quality, stopReason: stop, targetBundleID: targetBundleID,
        attemptID: attemptString.flatMap(UUID.init(uuidString:)),
        attemptStartedAtMilliseconds: attemptStartedAt, revision: revision,
        hasQualityDetail: row["has_quality_detail"], rewriteState: rewriteState,
        deliveredSource: deliveredString.flatMap(DeliveredSource.init(rawValue:)),
        deliveredRewriteAttemptID: deliveredAttemptString.flatMap(UUID.init(uuidString:)))
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

  // MARK: Rewrite attempts

  /// Admission. One transaction re-checks the attempt limit and the in-flight
  /// rules, assigns the ordinal, reserves quota, inserts the pending row and
  /// mirrors `rewrite_state`. Any refusal throws before anything is written.
  func begin(_ admission: RewriteAdmission) throws -> RewriteAttempt {
    let id = UUID()
    let startedAt = Int64(Date().timeIntervalSince1970 * 1000)
    let reservedBytes = admission.reservedBytes
    let reservedByDictation = reservations.values.reduce(0) { $0 + $1.bytes }
    let inputBytes = admission.inputText.utf8.count
    guard admission.mode.sendsRequest else { throw RewriteFailure(.invalidSettings) }
    guard inputBytes >= 1, inputBytes <= Self.maximumTextBytes,
      admission.inputText.unicodeScalars.count <= RewriteBounds.maximumInputScalars
    else { throw RewriteFailure(.inputTooLarge) }
    return try database.write { db in
      guard try Self.fetch(admission.transcriptionID, db: db) != nil else {
        throw Error.missingEntry
      }
      let transcription = admission.transcriptionID.uuidString
      let count =
        try Int.fetchOne(
          db, sql: "SELECT count(*) FROM rewrite_attempts WHERE transcription_id=?",
          arguments: [transcription]) ?? 0
      guard count < RewriteAttempt.maximumPerDictation else {
        throw RewriteFailure(.attemptLimit)
      }
      let pendingHere =
        try Int.fetchOne(
          db,
          sql: "SELECT count(*) FROM rewrite_attempts WHERE transcription_id=? AND state='pending'",
          arguments: [transcription]) ?? 0
      let pendingOverall =
        try Int.fetchOne(db, sql: "SELECT count(*) FROM rewrite_attempts WHERE state='pending'")
        ?? 0
      guard pendingHere == 0, pendingOverall < RewriteAttempt.maximumPendingOverall else {
        throw RewriteFailure(.concurrencyLimit)
      }
      let usage = try Self.usage(db)
      guard usage.bytes + reservedByDictation + reservedBytes <= Self.maximumPayloadBytes else {
        throw RewriteFailure(.capacityExceeded)
      }
      let ordinal =
        (try Int.fetchOne(
          db, sql: "SELECT max(ordinal) FROM rewrite_attempts WHERE transcription_id=?",
          arguments: [transcription]) ?? 0) + 1
      try db.execute(
        sql: """
          INSERT INTO rewrite_attempts (id, transcription_id, ordinal, mode, state, input_text, input_hash,
            started_at, protocol_version, endpoint_origin, insecure_override, context_hash)
          VALUES (?,?,?,?,'pending',?,?,?,?,?,?,?)
          """,
        arguments: [
          id.uuidString, transcription, ordinal, admission.mode.rawValue, admission.inputText,
          TranscriptionQualityDetail.hash(admission.inputText), startedAt,
          admission.protocolVersion, admission.endpointOrigin, admission.insecureOverride ? 1 : 0,
          admission.contextHash,
        ])
      try db.execute(
        sql: "UPDATE history_usage SET payload_bytes=payload_bytes+? WHERE id=1",
        arguments: [reservedBytes])
      try Self.mirrorRewriteState(admission.transcriptionID, db: db)
      guard let attempt = try Self.fetchAttempt(id, db: db) else { throw Error.damagedDatabase }
      return attempt
    }
  }

  func recordResult(id: UUID, result: RewriteResult, spans: RewriteSpans) throws -> RewriteAttempt {
    try database.write { db in
      let current = try Self.pendingAttempt(id, db: db)
      let outputBytes = result.text.utf8.count
      guard outputBytes <= Self.maximumTextBytes else { throw RewriteFailure(.oversizedResponse) }
      try db.execute(
        sql: """
          UPDATE rewrite_attempts SET state='succeeded', output_text=?, output_hash=?, unchanged=?,
            duration_ms=?, first_byte_ms=?, network_ms=?, request_bytes=?, response_bytes=?,
            server_queue_ms=?, backend_first_token_ms=?, backend_ms=?,
            server_name=?, server_version=?, backend_kind=?, backend_model=?, prompt_version=?, shield_version=?
          WHERE id=?
          """,
        arguments: [
          result.text, TranscriptionQualityDetail.hash(result.text),
          result.text.utf8.elementsEqual(current.inputText.utf8) ? 1 : 0,
          spans.durationMilliseconds, spans.firstByteMilliseconds, spans.networkMilliseconds,
          spans.requestBytes, spans.responseBytes, result.serverQueueMilliseconds,
          result.backendFirstTokenMilliseconds, result.backendMilliseconds,
          result.serverName, result.serverVersion, result.backendKind, result.backendModel,
          result.promptVersion, result.shieldVersion, id.uuidString,
        ])
      // Replace the output reservation with the actual output size.
      let reserved = RewriteBounds.maximumResultBytes(inputBytes: current.inputText.utf8.count)
      try db.execute(
        sql: "UPDATE history_usage SET payload_bytes=payload_bytes-?+? WHERE id=1",
        arguments: [reserved, outputBytes])
      try Self.mirrorRewriteState(current.transcriptionID, db: db)
      guard let attempt = try Self.fetchAttempt(id, db: db) else { throw Error.damagedDatabase }
      return attempt
    }
  }

  func recordFailure(id: UUID, category: RewriteFailureCategory, spans: RewriteSpans) throws
    -> RewriteAttempt
  {
    try terminate(
      id, state: category == .timeout ? .timedOut : .failed, category: category, spans: spans)
  }

  func recordCancelled(id: UUID, spans: RewriteSpans) throws -> RewriteAttempt {
    try terminate(id, state: .cancelled, category: nil, spans: spans)
  }

  private func terminate(
    _ id: UUID, state: RewriteAttemptState, category: RewriteFailureCategory?, spans: RewriteSpans
  ) throws -> RewriteAttempt {
    try database.write { db in
      let current = try Self.pendingAttempt(id, db: db)
      try db.execute(
        sql: """
          UPDATE rewrite_attempts SET state=?, failure_category=?, duration_ms=?, first_byte_ms=?,
            network_ms=?, request_bytes=?, response_bytes=? WHERE id=?
          """,
        arguments: [
          state.rawValue, category?.rawValue, spans.durationMilliseconds,
          spans.firstByteMilliseconds, spans.networkMilliseconds, spans.requestBytes,
          spans.responseBytes, id.uuidString,
        ])
      try Self.releaseOutputReservation(for: current, db: db)
      try Self.mirrorRewriteState(current.transcriptionID, db: db)
      guard let attempt = try Self.fetchAttempt(id, db: db) else { throw Error.damagedDatabase }
      return attempt
    }
  }

  /// A late response for a non-pending or non-newest attempt: flag only, never a state change.
  func markStale(id: UUID) throws {
    try database.write { db in
      try db.execute(
        sql: "UPDATE rewrite_attempts SET stale=1 WHERE id=?", arguments: [id.uuidString])
    }
  }

  func attempts(for transcriptionID: UUID) throws -> [RewriteAttempt] {
    try database.read { db in
      try Self.fetchAttempts(
        db, sql: "SELECT * FROM rewrite_attempts WHERE transcription_id=? ORDER BY ordinal",
        arguments: [transcriptionID.uuidString])
    }
  }

  /// Startup: every `pending` row becomes `failed` with `interrupted`. Also runs
  /// in `init`, so a crash never leaves a resumable request behind.
  @discardableResult
  func cancelPendingOnStartup() throws -> Int {
    // `init` already interrupted them; skip the empty fsynced write in the usual case.
    guard try database.read(Self.hasPendingAttempts) else { return 0 }
    return try database.write { db in try Self.interruptPendingAttempts(db) }
  }

  /// Explicit insertion of one attempt's text from history.
  func recordDelivered(attemptID: UUID) throws {
    try database.write { db in
      guard let attempt = try Self.fetchAttempt(attemptID, db: db) else { throw Error.missingEntry }
      try Self.markDelivered(
        attemptID, transcriptionID: attempt.transcriptionID, durationMilliseconds: nil, db: db)
      try db.execute(
        sql:
          "UPDATE transcriptions SET delivered_source='rewrite', delivered_rewrite_attempt_id=? WHERE id=?",
        arguments: [attemptID.uuidString, attempt.transcriptionID.uuidString])
    }
  }

  private static func interruptPendingAttempts(_ db: Database) throws -> Int {
    let pending = try fetchAttempts(db, sql: "SELECT * FROM rewrite_attempts WHERE state='pending'")
    for attempt in pending {
      try db.execute(
        sql:
          "UPDATE rewrite_attempts SET state='failed', failure_category='interrupted' WHERE id=?",
        arguments: [attempt.id.uuidString])
      try releaseOutputReservation(for: attempt, db: db)
      try mirrorRewriteState(attempt.transcriptionID, db: db)
    }
    return pending.count
  }

  private static func markDelivered(
    _ attemptID: UUID, transcriptionID: UUID, durationMilliseconds: Int?, db: Database
  ) throws {
    guard let attempt = try fetchAttempt(attemptID, db: db),
      attempt.transcriptionID == transcriptionID, attempt.state == .succeeded
    else { throw Error.invalidAttempt }
    try db.execute(
      sql:
        "UPDATE rewrite_attempts SET delivered=1, duration_ms=coalesce(?, duration_ms) WHERE id=?",
      arguments: [durationMilliseconds, attemptID.uuidString])
  }

  private static func releaseOutputReservation(for attempt: RewriteAttempt, db: Database) throws {
    let reserved = RewriteBounds.maximumResultBytes(inputBytes: attempt.inputText.utf8.count)
    try db.execute(
      sql: "UPDATE history_usage SET payload_bytes=max(0, payload_bytes-?) WHERE id=1",
      arguments: [reserved])
  }

  private static func mirrorRewriteState(_ transcriptionID: UUID, db: Database) throws {
    try db.execute(
      sql: """
        UPDATE transcriptions SET rewrite_state=coalesce(
          (SELECT state FROM rewrite_attempts WHERE transcription_id=? ORDER BY ordinal DESC LIMIT 1),
          'not_requested') WHERE id=?
        """,
      arguments: [transcriptionID.uuidString, transcriptionID.uuidString])
  }

  private static func pendingAttempt(_ id: UUID, db: Database) throws -> RewriteAttempt {
    guard let current = try fetchAttempt(id, db: db) else { throw Error.missingEntry }
    guard current.state == .pending else { throw Error.invalidAttempt }
    return current
  }

  private static func fetchAttempt(_ id: UUID, db: Database) throws -> RewriteAttempt? {
    try fetchAttempts(
      db, sql: "SELECT * FROM rewrite_attempts WHERE id=?", arguments: [id.uuidString]
    ).first
  }

  private static func fetchAttempts(
    _ db: Database, sql: String, arguments: StatementArguments = []
  ) throws -> [RewriteAttempt] {
    try Row.fetchAll(db, sql: sql, arguments: arguments).map { row in
      let idString: String = row["id"]
      let transcriptionString: String = row["transcription_id"]
      let modeString: String = row["mode"]
      let stateString: String = row["state"]
      let categoryString: String? = row["failure_category"]
      guard let id = UUID(uuidString: idString),
        let transcriptionID = UUID(uuidString: transcriptionString),
        let mode = RewriteMode(rawValue: modeString),
        let state = RewriteAttemptState(rawValue: stateString)
      else { throw Error.damagedDatabase }
      let category = categoryString.map(RewriteFailureCategory.init(rawValue:))
      if categoryString != nil, category == nil { throw Error.damagedDatabase }
      let unchanged: Int = row["unchanged"]
      let stale: Int = row["stale"]
      let insecure: Int = row["insecure_override"]
      let delivered: Int = row["delivered"]
      return RewriteAttempt(
        id: id, transcriptionID: transcriptionID, ordinal: row["ordinal"], mode: mode, state: state,
        inputText: row["input_text"], inputHash: row["input_hash"], outputText: row["output_text"],
        outputHash: row["output_hash"], unchanged: unchanged == 1, failureCategory: category ?? nil,
        stale: stale == 1, startedAtMilliseconds: row["started_at"],
        spans: RewriteSpans(
          durationMilliseconds: row["duration_ms"], firstByteMilliseconds: row["first_byte_ms"],
          networkMilliseconds: row["network_ms"], requestBytes: row["request_bytes"],
          responseBytes: row["response_bytes"]),
        serverQueueMilliseconds: row["server_queue_ms"],
        backendFirstTokenMilliseconds: row["backend_first_token_ms"],
        backendMilliseconds: row["backend_ms"], protocolVersion: row["protocol_version"],
        identity: RewriteIdentity(
          serverName: row["server_name"], serverVersion: row["server_version"],
          backendKind: row["backend_kind"], backendModel: row["backend_model"],
          promptVersion: row["prompt_version"], shieldVersion: row["shield_version"]),
        endpointOrigin: row["endpoint_origin"], insecureOverride: insecure == 1,
        delivered: delivered == 1, contextHash: row["context_hash"])
    }
  }

  private static func verifyDatabaseBounds(_ db: some DatabaseReader) throws {
    try db.read { database in
      let pageSize: Int = try Int.fetchOne(database, sql: "PRAGMA page_size") ?? 0
      let pageCount: Int = try Int.fetchOne(database, sql: "PRAGMA page_count") ?? 0
      guard pageSize > 0, pageCount * pageSize <= 128 * 1024 * 1024 else {
        throw Error.databaseLimitExceeded
      }
    }
  }
}
