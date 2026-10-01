import Foundation
import GRDB

/// One request flowd logged: the service, how long it took, its result code and, for
/// analysis backend calls, the model that answered. Never content.
struct RequestRecord: Codable, Equatable, FetchableRecord, PersistableRecord, Sendable {
  static let databaseTableName = "request"
  static let analysisCall = "analysis call"

  var day: String  // local yyyy-MM-dd
  var service: String
  var durationMS: Int?
  var code: String
  var model: String?

  enum CodingKeys: String, CodingKey {
    case day, service, code, model
    case durationMS = "duration_ms"
  }

  var failed: Bool { !LogLine.okCodes.contains(code) }

  /// The client-facing operations (`remote dictation|rewrite|analysis|meeting|live …`)
  /// and the analysis handler's per-stage backend calls, which name the answering model.
  /// Remote refusals without a duration still count as requests.
  init?(_ line: LogLine) {
    guard let date = line.date, let code = line.code else { return nil }
    let service: String
    let operations: Set<LogLine.Service> = [.dictation, .rewrite, .analysis, .meeting, .live]
    if line.subject.hasPrefix("remote "), operations.contains(line.service) {
      service = line.service.rawValue
    } else if line.subject.isEmpty, line["stage"] != nil {
      service = Self.analysisCall
    } else {
      return nil
    }
    self.init(
      day: Self.day(date), service: service, durationMS: line.durationMS, code: code,
      model: service == Self.analysisCall ? line["model"] : nil)
  }

  init(day: String, service: String, durationMS: Int?, code: String, model: String?) {
    (self.day, self.service, self.durationMS, self.code, self.model) =
      (day, service, durationMS, code, model)
  }

  static func day(_ date: Date) -> String {
    let parts = Calendar.current.dateComponents([.year, .month, .day], from: date)
    return String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
  }
}

/// Requests per service per day, with median and p95 duration and the failures.
struct ServiceDay: Identifiable, Equatable, Sendable {
  var day: String
  var service: String
  var requests: Int
  var medianMS: Int?
  var p95MS: Int?
  var failures: Int
  var id: String { day + "/" + service }

  static func summarize(_ records: [RequestRecord]) -> [ServiceDay] {
    Dictionary(grouping: records) { [$0.day, $0.service] }
      .map { key, group in
        let durations = group.compactMap(\.durationMS).sorted()
        return ServiceDay(
          day: key[0], service: key[1], requests: group.count,
          medianMS: percentile(durations, 0.5), p95MS: percentile(durations, 0.95),
          failures: group.filter(\.failed).count)
      }
      .sorted { ($0.day, $0.service) > ($1.day, $1.service) }
  }

  /// Nearest-rank percentile of sorted values.
  static func percentile(_ sorted: [Int], _ p: Double) -> Int? {
    guard !sorted.isEmpty else { return nil }
    let rank = Int((p * Double(sorted.count)).rounded(.up))
    return sorted[max(0, min(sorted.count - 1, rank - 1))]
  }
}

/// The history behind the Stats tab, in the app's own SQLite file so it outlives
/// flowd's 1 MiB log rotation. Ingests by inode and offset; rows older than
/// `retentionDays` are dropped.
final class StatsStore: Sendable {
  static let retentionDays = 90
  private let database: DatabaseQueue

  init(path: String) throws {
    database = try DatabaseQueue(path: path)
    var migrator = DatabaseMigrator()
    migrator.registerMigration("v1") { db in
      try db.create(table: "request") { t in
        t.autoIncrementedPrimaryKey("id")
        t.column("day", .text).notNull().indexed()
        t.column("service", .text).notNull()
        t.column("duration_ms", .integer)
        t.column("code", .text).notNull()
        t.column("model", .text)
      }
      try db.create(table: "cursor") { t in
        t.primaryKey("id", .integer).check { $0 == 1 }
        t.column("inode", .integer)
        t.column("offset", .integer).notNull()
      }
    }
    try migrator.migrate(database)
  }

  /// Reads what flowd logged since the last call and stores its requests together with
  /// the new file position, in one transaction. Returns the number of new requests.
  @discardableResult
  func ingest(log: URL, rotated: URL, now: Date = .now) throws -> Int {
    try database.write { db in
      var reader = LogReader.fromStart(log: log, rotated: rotated)
      if let row = try Row.fetchOne(db, sql: "SELECT inode, offset FROM cursor WHERE id = 1") {
        reader = LogReader(
          inode: (row["inode"] as Int64?).map { UInt64($0) }, offset: row["offset"])
      }
      let records = reader.read(log: log, rotated: rotated).compactMap {
        RequestRecord(LogLine($0))
      }
      for record in records { try record.insert(db) }
      try db.execute(
        sql: "INSERT OR REPLACE INTO cursor (id, inode, offset) VALUES (1, ?, ?)",
        arguments: [reader.inode.map { Int64($0) }, Int64(reader.offset)])
      let oldest = Calendar.current.date(byAdding: .day, value: -Self.retentionDays, to: now)!
      try db.execute(
        sql: "DELETE FROM request WHERE day < ?", arguments: [RequestRecord.day(oldest)])
      return records.count
    }
  }

  func records(days: Int, now: Date = .now) throws -> [RequestRecord] {
    let first = Calendar.current.date(byAdding: .day, value: -(days - 1), to: now)!
    return try database.read { db in
      try RequestRecord.filter(Column("day") >= RequestRecord.day(first)).fetchAll(db)
    }
  }
}
