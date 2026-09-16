import Foundation
import GRDB

enum HistoryMigrations {
  static let name = "history-v1"

  static func migrator() -> DatabaseMigrator {
    var migrator = DatabaseMigrator()
    migrator.registerMigration(name) { db in
      try db.create(table: "transcriptions") { t in
        t.column("id", .text).notNull().primaryKey()
        t.column("text", .text).notNull()
        t.column("created_at", .integer).notNull()
        t.column("delivery_state", .text).notNull()
        t.column("recovery_state", .text).notNull()
        t.column("quality", .text).notNull()
        t.column("stop_reason", .text).notNull()
        t.column("target_bundle_id", .text)
        t.column("attempt_id", .text)
        t.column("attempt_started_at", .integer)
        t.column("revision", .integer).notNull().defaults(to: 0)
        t.check(sql: "length(cast(text as blob)) BETWEEN 1 AND 65536")
        t.check(sql: "target_bundle_id IS NULL OR length(cast(target_bundle_id as blob)) <= 255")
        t.check(sql: "revision >= 0")
        t.check(
          sql:
            "delivery_state IN ('not_attempted','attempting','confirmed','not_inserted','uncertain')"
        )
        t.check(sql: "recovery_state IN ('needs_review','resolved')")
        t.check(sql: "quality IN ('complete','duration_limited','incomplete')")
        t.check(
          sql:
            "stop_reason IN ('key_release','duration_limit','cancel','overflow','device_loss','permission_revoked','sleep','failure')"
        )
      }
      try db.execute(
        sql: "CREATE INDEX transcriptions_created_at_id ON transcriptions(created_at DESC, id DESC)"
      )
      try db.create(table: "history_usage") { t in
        t.column("id", .integer).primaryKey().check(sql: "id = 1")
        t.column("row_count", .integer).notNull().check(sql: "row_count >= 0")
        t.column("payload_bytes", .integer).notNull().check(sql: "payload_bytes >= 0")
      }

      if try db.tableExists("pending_dictations") {
        let columns = try db.columns(in: "pending_dictations").map(\.name)
        guard columns.contains("id"), columns.contains("text"), columns.contains("created_at")
        else { throw TranscriptionStore.Error.damagedDatabase }
        let created = columns.contains("created_at") ? "created_at" : "0"
        let quality = columns.contains("quality") ? "quality" : "'incomplete'"
        let delivery = columns.contains("delivery_state") ? "delivery_state" : "'not_attempted'"
        let source = "pending_dictations"
        try db.execute(
          sql: """
            INSERT INTO transcriptions
              (id, text, created_at, delivery_state, recovery_state, quality, stop_reason,
               target_bundle_id, attempt_id, attempt_started_at, revision)
            SELECT CAST(id AS TEXT), text, \(created),
              CASE \(delivery) WHEN 'attempting' THEN 'uncertain' WHEN 'uncertain' THEN 'uncertain'
                ELSE 'not_attempted' END,
              'needs_review',
              CASE \(quality) WHEN 'complete' THEN 'complete' WHEN 'duration_limited' THEN 'duration_limited' ELSE 'incomplete' END,
              'failure', NULL, NULL, NULL, 0
            FROM \(source)
            """)
        try db.drop(table: "pending_dictations")
      }
      try db.execute(
        sql: """
          INSERT INTO history_usage (id, row_count, payload_bytes)
          SELECT 1, count(*), coalesce(sum(length(cast(text AS blob))), 0) FROM transcriptions
          """)
    }
    return migrator
  }
}
