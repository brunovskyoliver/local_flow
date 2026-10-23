import Foundation
import GRDB

/// Optional metadata in the history database. Its failure never rolls back saved text.
public actor UsageReportingStore {
  public struct State: Sendable {
    public let attribution: UsageAttribution?
    public let pending: UsageRequest.Action?
    public let incomplete: Bool
    public let lastReport: Int64?
  }
  public let database: DatabasePool
  public init(database: DatabasePool) { self.database = database }

  public static func migrate(_ db: Database) throws {
    try db.execute(
      sql: """
        ALTER TABLE pending_remote_dictations ADD COLUMN usage_attribution TEXT CHECK(length(usage_attribution)<=2048);
        CREATE TABLE usage_reporting_state (
          id INTEGER PRIMARY KEY CHECK(id=1), binding TEXT CHECK(length(binding)<=2048),
          enabled INTEGER NOT NULL DEFAULT 0 CHECK(enabled IN (0,1)),
          pending TEXT CHECK(pending IN ('withdraw','delete_device','delete_user')),
          incomplete INTEGER NOT NULL DEFAULT 0 CHECK(incomplete IN (0,1)), last_report INTEGER
        );
        INSERT INTO usage_reporting_state(id) VALUES(1);
        CREATE TABLE usage_reporting_days (
          day TEXT PRIMARY KEY CHECK(length(day)=10), revision INTEGER NOT NULL CHECK(revision>0),
          local_count INTEGER NOT NULL CHECK(local_count>=0), remote_count INTEGER NOT NULL CHECK(remote_count>=0),
          local_audio_ms INTEGER NOT NULL CHECK(local_audio_ms>=0), remote_audio_ms INTEGER NOT NULL CHECK(remote_audio_ms>=0),
          coverage TEXT NOT NULL CHECK(coverage IN ('complete','partial')), dirty INTEGER NOT NULL CHECK(dirty IN (0,1))
        );
        CREATE TABLE usage_reporting_completions (
          id TEXT PRIMARY KEY CHECK(length(id)=36), day TEXT NOT NULL CHECK(length(day)=10)
        );
        CREATE INDEX usage_reporting_completion_day ON usage_reporting_completions(day);
        """)
  }

  public func state() throws -> State {
    try database.read { db in
      let row = try Row.fetchOne(db, sql: "SELECT * FROM usage_reporting_state WHERE id=1")!
      let enabled: Bool = row["enabled"]
      let binding: String? = row["binding"]
      let pending: String? = row["pending"]
      return State(
        attribution: enabled
          ? binding.flatMap {
            try? JSONDecoder().decode(UsageAttribution.self, from: Data($0.utf8))
          } : nil,
        pending: pending.flatMap(UsageRequest.Action.init(rawValue:)),
        incomplete: row["incomplete"],
        lastReport: row["last_report"])
    }
  }

  /// Return the old binding for an outstanding withdrawal/deletion, even while disabled.
  public func binding() throws -> UsageAttribution? {
    try database.read { db in
      guard
        let value = try String.fetchOne(
          db, sql: "SELECT binding FROM usage_reporting_state WHERE id=1")
      else { return nil }
      return try JSONDecoder().decode(UsageAttribution.self, from: Data(value.utf8))
    }
  }

  public func enable(_ binding: UsageAttribution) throws {
    let encoded = try JSONEncoder().encode(binding)
    guard encoded.count <= 2048, binding.epoch > 0, UUID(uuidString: binding.grant) != nil else {
      throw UsageReportingError.invalidResponse
    }
    try database.write { db in
      guard
        try String.fetchOne(db, sql: "SELECT pending FROM usage_reporting_state WHERE id=1") == nil
      else {
        throw UsageReportingError.busy
      }
      let existing = try String.fetchOne(
        db, sql: "SELECT binding FROM usage_reporting_state WHERE id=1 AND enabled=1")
      if let existing,
        let old = try? JSONDecoder().decode(UsageAttribution.self, from: Data(existing.utf8)),
        old == binding
      {
        return
      }
      guard existing == nil else { throw UsageReportingError.busy }
      try db.execute(sql: "DELETE FROM usage_reporting_days")
      try db.execute(sql: "DELETE FROM usage_reporting_completions")
      try db.execute(
        sql:
          "UPDATE usage_reporting_state SET binding=?,enabled=1,incomplete=0,last_report=NULL WHERE id=1",
        arguments: [String(decoding: encoded, as: UTF8.self)])
    }
  }

  /// Persist control before returning. One coalesced command, with erasure taking priority.
  public func disable(_ action: UsageRequest.Action = .withdraw) throws {
    guard [.withdraw, .deleteDevice, .deleteUser].contains(action) else {
      throw UsageReportingError.invalidResponse
    }
    try database.write { db in
      guard
        try String.fetchOne(db, sql: "SELECT binding FROM usage_reporting_state WHERE id=1") != nil
      else { return }
      let old = try String.fetchOne(db, sql: "SELECT pending FROM usage_reporting_state WHERE id=1")
      let next =
        old == "delete_user" || (old == "delete_device" && action == .withdraw)
        ? old! : action.rawValue
      try db.execute(
        sql: "UPDATE usage_reporting_state SET enabled=0,pending=? WHERE id=1", arguments: [next])
      try db.execute(sql: "DELETE FROM usage_reporting_days")
      try db.execute(sql: "DELETE FROM usage_reporting_completions")
    }
  }

  public func acknowledgeControl(
    expected: UsageRequest.Action? = nil, binding: UsageAttribution? = nil
  ) throws {
    try database.write { db in
      let row = try Row.fetchOne(
        db, sql: "SELECT pending,binding FROM usage_reporting_state WHERE id=1")!
      if let expected, (row["pending"] as String?) != expected.rawValue { return }
      if let binding {
        guard let raw: String = row["binding"],
          let current = try? JSONDecoder().decode(UsageAttribution.self, from: Data(raw.utf8)),
          current == binding
        else { return }
      }
      let action: String? = row["pending"]
      if action == UsageRequest.Action.withdraw.rawValue {
        try db.execute(sql: "UPDATE usage_reporting_state SET pending=NULL WHERE id=1")
      } else {
        try db.execute(sql: "UPDATE usage_reporting_state SET pending=NULL,binding=NULL WHERE id=1")
      }
    }
  }

  public func days(now: Date = Date()) throws -> [UsageDay] {
    try database.write { db in
      try Self.prune(db, now: now)
      return try Row.fetchAll(
        db, sql: "SELECT * FROM usage_reporting_days WHERE dirty=1 ORDER BY day LIMIT 90"
      ).map(Self.day)
    }
  }

  public func acknowledge(_ rows: [UsageResponse.Acknowledgment], now: Date = Date()) throws {
    guard rows.count <= 100 else { throw UsageReportingError.invalidResponse }
    try database.write { db in
      for row in rows where ["accepted", "duplicate", "stale"].contains(row.status) {
        try db.execute(
          sql: "UPDATE usage_reporting_days SET dirty=0 WHERE day=? AND revision<=?",
          arguments: [row.day, row.revision])
      }
      try db.execute(
        sql: "UPDATE usage_reporting_state SET last_report=? WHERE id=1",
        arguments: [Int64(now.timeIntervalSince1970)])
    }
  }

  public func setPending(_ id: UUID, attribution: UsageAttribution) throws {
    let encoded = try JSONEncoder().encode(attribution)
    guard encoded.count <= 2048 else { throw UsageReportingError.invalidResponse }
    try database.write { db in
      try db.execute(
        sql: "UPDATE pending_remote_dictations SET usage_attribution=? WHERE id=?",
        arguments: [String(decoding: encoded, as: UTF8.self), id.uuidString])
    }
  }

  public func pending(_ id: UUID) throws -> UsageAttribution? {
    try database.read { db in
      guard
        let value = try String.fetchOne(
          db, sql: "SELECT usage_attribution FROM pending_remote_dictations WHERE id=?",
          arguments: [id.uuidString])
      else { return nil }
      return try JSONDecoder().decode(UsageAttribution.self, from: Data(value.utf8))
    }
  }

  public func markIncomplete() throws {
    try database.write { db in try Self.markIncomplete(db) }
  }

  /// Called only inside the first successful history insert transaction.
  static func record(_ contribution: UsageContribution, id: UUID, createdAt: Int64, db: Database) {
    do {
      try db.inSavepoint {
        guard contribution.audioMilliseconds >= 0,
          let row = try Row.fetchOne(
            db, sql: "SELECT binding,enabled FROM usage_reporting_state WHERE id=1"),
          row["enabled"] as Bool,
          let raw: String = row["binding"],
          let active = try? JSONDecoder().decode(UsageAttribution.self, from: Data(raw.utf8)),
          active == contribution.attribution
        else { return .commit }
        let now = Date(timeIntervalSince1970: Double(createdAt) / 1000)
        try prune(db, now: Date())
        let dayKey = dayString(now)
        guard dayKey >= dayString(Date().addingTimeInterval(-89 * 86400)),
          dayKey <= dayString(Date().addingTimeInterval(86400))
        else { throw UsageReportingError.invalidResponse }
        guard
          try Bool.fetchOne(
            db, sql: "SELECT EXISTS(SELECT 1 FROM usage_reporting_completions WHERE id=?)",
            arguments: [id.uuidString]) != true
        else { return .commit }
        guard
          (try Int.fetchOne(db, sql: "SELECT count(*) FROM usage_reporting_completions") ?? 0)
            < 10_000
        else { throw UsageReportingError.busy }
        let existing = try Row.fetchOne(
          db, sql: "SELECT * FROM usage_reporting_days WHERE day=?", arguments: [dayKey])
        let dayCount = try Int.fetchOne(db, sql: "SELECT count(*) FROM usage_reporting_days") ?? 0
        guard existing != nil || dayCount < 90
        else { throw UsageReportingError.busy }
        var day = existing.map(Self.day) ?? UsageDay(day: dayKey, revision: 0)
        func add(_ value: Int64, _ amount: Int64) throws -> Int64 {
          let (sum, overflow) = value.addingReportingOverflow(amount)
          guard !overflow else { throw UsageReportingError.busy }
          return sum
        }
        day.revision = try add(day.revision, 1)
        if contribution.remote {
          day.remoteCount = try add(day.remoteCount, 1)
          day.remoteAudioMs = try add(day.remoteAudioMs, contribution.audioMilliseconds)
        } else {
          day.localCount = try add(day.localCount, 1)
          day.localAudioMs = try add(day.localAudioMs, contribution.audioMilliseconds)
        }
        if try Bool.fetchOne(db, sql: "SELECT incomplete FROM usage_reporting_state WHERE id=1")
          == true
        {
          day.coverage = "partial"
        }
        try db.execute(
          sql: """
            INSERT INTO usage_reporting_days VALUES(?,?,?,?,?,?,?,1)
            ON CONFLICT(day) DO UPDATE SET revision=excluded.revision,local_count=excluded.local_count,
            remote_count=excluded.remote_count,local_audio_ms=excluded.local_audio_ms,
            remote_audio_ms=excluded.remote_audio_ms,coverage=excluded.coverage,dirty=1
            """,
          arguments: [
            day.day, day.revision, day.localCount, day.remoteCount, day.localAudioMs,
            day.remoteAudioMs, day.coverage,
          ])
        try db.execute(
          sql: "INSERT INTO usage_reporting_completions VALUES(?,?)",
          arguments: [id.uuidString, dayKey])
        return .commit
      }
    } catch {
      // Reporting is best-effort; even disk-full must not roll back the user's text.
      try? markIncomplete(db)
    }
  }

  private static func markIncomplete(_ db: Database) throws {
    try db.execute(sql: "UPDATE usage_reporting_state SET incomplete=1 WHERE id=1")
    try db.execute(
      sql:
        "UPDATE usage_reporting_days SET coverage='partial',dirty=1,revision=revision+1 WHERE revision<9223372036854775807 AND coverage!='partial'"
    )
  }

  private static func prune(_ db: Database, now: Date) throws {
    let cutoff = dayString(now.addingTimeInterval(-89 * 86400))
    if try Bool.fetchOne(
      db, sql: "SELECT EXISTS(SELECT 1 FROM usage_reporting_days WHERE day<? AND dirty=1)",
      arguments: [cutoff]) == true
    {
      try markIncomplete(db)
    }
    try db.execute(sql: "DELETE FROM usage_reporting_days WHERE day<?", arguments: [cutoff])
    try db.execute(sql: "DELETE FROM usage_reporting_completions WHERE day<?", arguments: [cutoff])
  }

  public static func dayString(_ date: Date) -> String {
    let calendar = Calendar(identifier: .gregorian)
    var utc = calendar
    utc.timeZone = TimeZone(secondsFromGMT: 0)!
    let parts = utc.dateComponents([.year, .month, .day], from: date)
    return String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
  }

  private static func day(_ row: Row) -> UsageDay {
    UsageDay(
      day: row["day"], revision: row["revision"], localCount: row["local_count"],
      remoteCount: row["remote_count"], localAudioMs: row["local_audio_ms"],
      remoteAudioMs: row["remote_audio_ms"], coverage: row["coverage"])
  }
}
