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
    migrator.registerMigration("quality-v2") { db in
      try db.create(table: "transcription_quality") { t in
        t.column("transcription_id", .text).notNull().primaryKey()
          .references("transcriptions", onDelete: .cascade)
        t.column("schema_version", .integer).notNull().check(sql: "schema_version = 1")
        t.column("detail_json", .text).notNull()
          .check(sql: "length(cast(detail_json AS blob)) <= 262144")
        t.column("content_hash", .text).notNull().check(sql: "length(content_hash) = 64")
      }
      try db.create(table: "vocabulary_entries") { t in
        t.column("id", .text).notNull().primaryKey()
        t.column("canonical_text", .text).notNull()
          .check(sql: "length(cast(canonical_text AS blob)) BETWEEN 1 AND 256")
        t.column("aliases_json", .text).notNull()
        t.column("enabled", .boolean).notNull()
      }
      try db.create(table: "vocabulary_state") { t in
        t.column("id", .integer).primaryKey().check(sql: "id = 1")
        t.column("schema_version", .integer).notNull().check(sql: "schema_version = 1")
        t.column("revision", .integer).notNull().check(sql: "revision >= 0")
        t.column("content_hash", .text).notNull().check(sql: "length(content_hash) = 64")
        t.column("payload_bytes", .integer).notNull().check(
          sql: "payload_bytes BETWEEN 0 AND 1048576")
      }
      try db.execute(
        sql: "INSERT INTO vocabulary_state VALUES (1, 1, 0, ?, 0)",
        arguments: [TranscriptionQualityDetail.emptyVocabularyHash])
    }
    migrator.registerMigration("vocabulary-v3") { db in
      // Learned entries record when an observed correction created them; manual rows stay NULL.
      try db.alter(table: "vocabulary_entries") { t in
        t.add(column: "learned_at", .integer).check(sql: "learned_at IS NULL OR learned_at >= 0")
      }
    }
    migrator.registerMigration("rewrite-v4") { db in
      // One row per admitted rewrite attempt; cascades with its dictation. The
      // failure_category check admits exactly the twelve post-admission codes.
      let categories = RewriteFailureCategory.persisted.map { "'\($0.rawValue)'" }
        .joined(separator: ",")
      let spanColumns = [
        "duration_ms", "first_byte_ms", "network_ms", "server_queue_ms",
        "backend_first_token_ms", "backend_ms", "request_bytes", "response_bytes",
      ]
      let identityColumns = ["server_name", "server_version", "backend_kind", "backend_model"]
      try db.create(table: "rewrite_attempts") { t in
        t.column("id", .text).notNull().primaryKey()
        t.column("transcription_id", .text).notNull()
          .references("transcriptions", onDelete: .cascade)
        t.column("ordinal", .integer).notNull().check(sql: "ordinal BETWEEN 1 AND 10")
        t.column("mode", .text).notNull().check(sql: "mode IN ('clean','polished','concise')")
        t.column("state", .text).notNull()
          .check(sql: "state IN ('pending','succeeded','failed','cancelled','timed_out')")
        t.column("input_text", .text).notNull()
          .check(sql: "length(cast(input_text AS blob)) BETWEEN 1 AND 65536")
        t.column("input_hash", .text).notNull().check(sql: "length(input_hash) = 64")
        t.column("output_text", .text)
          .check(sql: "output_text IS NULL OR length(cast(output_text AS blob)) <= 65536")
        t.column("output_hash", .text)
          .check(sql: "output_hash IS NULL OR length(output_hash) = 64")
        t.column("unchanged", .integer).notNull().defaults(to: 0).check(sql: "unchanged IN (0,1)")
        t.column("failure_category", .text)
          .check(sql: "failure_category IS NULL OR failure_category IN (\(categories))")
        t.column("stale", .integer).notNull().defaults(to: 0).check(sql: "stale IN (0,1)")
        t.column("started_at", .integer).notNull().check(sql: "started_at >= 0")
        for column in spanColumns {
          t.column(column, .integer).check(sql: "\(column) IS NULL OR \(column) >= 0")
        }
        t.column("protocol_version", .integer).notNull().check(sql: "protocol_version = 1")
        for column in identityColumns {
          t.column(column, .text)
            .check(sql: "\(column) IS NULL OR length(cast(\(column) AS blob)) BETWEEN 1 AND 128")
        }
        t.column("prompt_version", .integer)
          .check(sql: "prompt_version IS NULL OR prompt_version >= 0")
        t.column("shield_version", .integer)
          .check(sql: "shield_version IS NULL OR shield_version >= 0")
        t.column("endpoint_origin", .text).notNull()
          .check(sql: "length(cast(endpoint_origin AS blob)) BETWEEN 1 AND 255")
        t.column("insecure_override", .integer).notNull().defaults(to: 0)
          .check(sql: "insecure_override IN (0,1)")
        t.column("delivered", .integer).notNull().defaults(to: 0).check(sql: "delivered IN (0,1)")
        t.check(sql: "(state = 'succeeded') = (output_text IS NOT NULL)")
        t.check(sql: "(output_text IS NULL) = (output_hash IS NULL)")
        t.check(sql: "(state IN ('failed','timed_out')) = (failure_category IS NOT NULL)")
        t.check(sql: "state != 'timed_out' OR failure_category = 'timeout'")
      }
      try db.execute(
        sql:
          "CREATE UNIQUE INDEX rewrite_attempts_transcription_ordinal ON rewrite_attempts(transcription_id, ordinal)"
      )
      try db.execute(
        sql:
          "CREATE INDEX rewrite_attempts_state ON rewrite_attempts(state) WHERE state = 'pending'"
      )
      // Legacy rows read not_requested without backfill; revision is untouched.
      try db.alter(table: "transcriptions") { t in
        t.add(column: "rewrite_state", .text).notNull().defaults(to: "not_requested")
          .check(
            sql:
              "rewrite_state IN ('not_requested','pending','succeeded','failed','cancelled','timed_out')"
          )
        t.add(column: "delivered_source", .text)
          .check(sql: "delivered_source IS NULL OR delivered_source IN ('faithful','rewrite')")
        t.add(column: "delivered_rewrite_attempt_id", .text)
          .references("rewrite_attempts", onDelete: .setNull)
      }
    }
    return migrator
  }
}
