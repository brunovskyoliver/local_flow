import Foundation
import GRDB
import OSLog

/// Feature 015. What each Dictionary key did in real dictations and whether the user kept
/// it. Rows hold identifiers, digests, counts and times only (FR-017). Shares the history
/// database file; every call is one transaction.
actor DictionaryUsageStore {
  struct KeyUsage: Equatable, Sendable {
    let entryID: String
    let keyID: String
    var state: KeyState
    var applied = 0
    var kept = 0
    var reverted = 0
    var lastUsedAt: Int64?
    var retiredAt: Int64?
    var noticeShown = false
  }

  struct RetiredKey: Hashable, Sendable {
    let entryID: String
    let keyID: String
  }

  /// What the snapshot needs on every press: retired keys and use per entry.
  struct Summary: Equatable, Sendable {
    var revision: Int64 = 0
    var retired: Set<RetiredKey> = []
    /// Latest use of any key and total applied, per entry.
    var use: [String: (lastUsedAt: Int64, applied: Int)] = [:]

    static func == (lhs: Self, rhs: Self) -> Bool {
      lhs.revision == rhs.revision && lhs.retired == rhs.retired
        && lhs.use.keys == rhs.use.keys
        && lhs.use.allSatisfy { key, value in
          rhs.use[key].map { $0.lastUsedAt == value.lastUsedAt && $0.applied == value.applied }
            ?? false
        }
    }
  }

  private let database: DatabasePool

  init(history: TranscriptionStore) { database = history.database }

  /// Counts one dictation's changes as applied. A key without a row starts provisional
  /// when its entry was learned, established otherwise. Entries deleted since the
  /// dictation began are skipped.
  func recordApplied(dictationID: UUID, changes: [DictionaryChange], now: Int64) throws {
    guard !changes.isEmpty else { return }
    try database.write { db in
      for change in changes {
        try db.execute(
          sql: """
            INSERT INTO dictionary_key_usage (entry_id, key_id, state, applied, last_used_at)
            SELECT id, ?, CASE WHEN learned_at IS NULL THEN 'established' ELSE 'provisional' END, 1, ?
            FROM vocabulary_entries WHERE id = ?
            ON CONFLICT(entry_id, key_id) DO UPDATE SET applied = applied + 1,
              last_used_at = excluded.last_used_at
            """, arguments: [change.keyID, now, change.entryID])
        guard db.changesCount > 0 else { continue }
        try db.execute(
          sql: """
            INSERT OR IGNORE INTO dictionary_usage_events (dictation_id, entry_id, key_id, outcome, at)
            VALUES (?, ?, ?, 'applied', ?)
            """, arguments: [dictationID.uuidString, change.entryID, change.keyID, now])
      }
      try Self.pruneEvents(db)
    }
  }

  /// Records what the user did with each change and applies the retirement rules.
  /// Returns keys that became retired. A change is counted at most once per dictation.
  func classify(
    dictationID: UUID, outcomes: [(DictionaryChange, UsageOutcome)], now: Int64
  ) throws -> [RetiredKey] {
    guard !outcomes.isEmpty else { return [] }
    return try database.write { db in
      var retired: [RetiredKey] = []
      var stateChanged = false
      for (change, outcome) in outcomes {
        try db.execute(
          sql: """
            UPDATE dictionary_usage_events SET outcome = ?, at = ?
            WHERE dictation_id = ? AND entry_id = ? AND key_id = ? AND outcome = 'applied'
            """,
          arguments: [
            outcome.rawValue, now, dictationID.uuidString, change.entryID, change.keyID,
          ])
        guard db.changesCount > 0, outcome != .unclassified,
          var usage = try Self.usage(db, entryID: change.entryID, keyID: change.keyID),
          usage.state != .retired
        else { continue }
        if outcome == .kept { usage.kept += 1 } else { usage.reverted += 1 }
        let next = DictionaryUsagePolicy.state(
          after: usage.state, kept: usage.kept, reverted: usage.reverted)
        let from = usage.state
        try db.execute(
          sql: """
            UPDATE dictionary_key_usage SET kept = ?, reverted = ?, state = ?,
              retired_at = ?, retired_from = ?, notice_shown = 0
            WHERE entry_id = ? AND key_id = ?
            """,
          arguments: [
            usage.kept, usage.reverted, next.rawValue, next == .retired ? now : nil,
            next == .retired ? from.rawValue : nil, change.entryID, change.keyID,
          ])
        if next != from {
          stateChanged = true
          if next == .retired {
            retired.append(RetiredKey(entryID: change.entryID, keyID: change.keyID))
          }
        }
      }
      if stateChanged { try Self.bumpRevision(db) }
      return retired
    }
  }

  /// Makes a retired key active again, trusted, with its revert count started over.
  func restore(entryID: String, keyID: String) throws {
    try database.write { db in
      try db.execute(
        sql: """
          UPDATE dictionary_key_usage SET state = 'established', reverted = 0,
            retired_at = NULL, retired_from = NULL, notice_shown = 0
          WHERE entry_id = ? AND key_id = ? AND state = 'retired'
          """, arguments: [entryID, keyID])
      if db.changesCount > 0 { try Self.bumpRevision(db) }
    }
    Logger(subsystem: "org.localflow.LocalFlow", category: "dictionary").notice(
      "Dictionary key restored")
  }

  func markNoticeShown(entryID: String, keyID: String) throws {
    try database.write { db in
      try db.execute(
        sql: "UPDATE dictionary_key_usage SET notice_shown = 1 WHERE entry_id = ? AND key_id = ?",
        arguments: [entryID, keyID])
    }
  }

  /// Every usage row, grouped by entry.
  func usage() throws -> [String: [KeyUsage]] {
    try database.read { db in
      var result: [String: [KeyUsage]] = [:]
      for row in try Row.fetchAll(db, sql: "SELECT * FROM dictionary_key_usage") {
        let usage = Self.decode(row)
        result[usage.entryID, default: []].append(usage)
      }
      return result
    }
  }

  func summary() throws -> Summary { try database.read(Self.summary) }

  // MARK: Shared with VocabularyStore (same database, its own transactions)

  static func summary(_ db: Database) throws -> Summary {
    var summary = Summary()
    summary.revision = try revision(db)
    summary.retired = try retired(db)
    summary.use = try use(db)
    return summary
  }

  static func revision(_ db: Database) throws -> Int64 {
    try Int64.fetchOne(db, sql: "SELECT revision FROM dictionary_usage_state WHERE id = 1") ?? 0
  }

  static func retired(_ db: Database) throws -> Set<RetiredKey> {
    Set(
      try Row.fetchAll(
        db, sql: "SELECT entry_id, key_id FROM dictionary_key_usage WHERE state = 'retired'"
      ).map { RetiredKey(entryID: $0["entry_id"], keyID: $0["key_id"]) })
  }

  /// Latest use and applied total per entry that has been used.
  static func use(_ db: Database) throws -> [String: (lastUsedAt: Int64, applied: Int)] {
    var use: [String: (lastUsedAt: Int64, applied: Int)] = [:]
    for row in try Row.fetchAll(
      db,
      sql: """
        SELECT entry_id, max(last_used_at) AS last, sum(applied) AS applied
        FROM dictionary_key_usage WHERE last_used_at IS NOT NULL GROUP BY entry_id
        """)
    {
      use[row["entry_id"]] = (row["last"], row["applied"])
    }
    return use
  }

  /// A save from the Dictionary editor trusts every key of the entry (FR-007); a save
  /// from the correction learner makes them provisional. Rows of keys the entry no
  /// longer has are removed (FR-019).
  static func entrySaved(_ db: Database, entry: VocabularyEntry, state: KeyState) throws {
    let keys = Set(([entry.canonical] + entry.aliases).map(DictionaryChange.keyID(for:)))
      .union([DictionaryChange.boostKeyID])
    let existing = try String.fetchAll(
      db, sql: "SELECT key_id FROM dictionary_key_usage WHERE entry_id = ?", arguments: [entry.id])
    for key in existing where !keys.contains(key) {
      try db.execute(
        sql: "DELETE FROM dictionary_key_usage WHERE entry_id = ? AND key_id = ?",
        arguments: [entry.id, key])
    }
    for key in keys {
      try db.execute(
        sql: """
          INSERT INTO dictionary_key_usage (entry_id, key_id, state) VALUES (?, ?, ?)
          ON CONFLICT(entry_id, key_id) DO UPDATE SET state = excluded.state,
            reverted = CASE WHEN state = 'retired' THEN 0 ELSE reverted END,
            retired_at = NULL, retired_from = NULL, notice_shown = 0
          """, arguments: [entry.id, key, state.rawValue])
    }
    try bumpRevision(db)
  }

  /// Usage rows cascade with the entry; its events are removed here (FR-019).
  static func entryDeleted(_ db: Database, entryID: String) throws {
    try db.execute(
      sql: "DELETE FROM dictionary_usage_events WHERE entry_id = ?", arguments: [entryID])
    try bumpRevision(db)
  }

  // MARK: Private

  private static func usage(_ db: Database, entryID: String, keyID: String) throws -> KeyUsage? {
    try Row.fetchOne(
      db, sql: "SELECT * FROM dictionary_key_usage WHERE entry_id = ? AND key_id = ?",
      arguments: [entryID, keyID]
    ).map(decode)
  }

  private static func decode(_ row: Row) -> KeyUsage {
    KeyUsage(
      entryID: row["entry_id"], keyID: row["key_id"],
      state: KeyState(rawValue: row["state"]) ?? .established, applied: row["applied"],
      kept: row["kept"], reverted: row["reverted"], lastUsedAt: row["last_used_at"],
      retiredAt: row["retired_at"], noticeShown: row["notice_shown"])
  }

  private static func bumpRevision(_ db: Database) throws {
    try db.execute(sql: "UPDATE dictionary_usage_state SET revision = revision + 1 WHERE id = 1")
  }

  private static func pruneEvents(_ db: Database) throws {
    try db.execute(
      sql: """
        DELETE FROM dictionary_usage_events
        WHERE id <= (SELECT max(id) FROM dictionary_usage_events) - ?
        """, arguments: [DictionaryUsagePolicy.maximumEvents])
  }
}
