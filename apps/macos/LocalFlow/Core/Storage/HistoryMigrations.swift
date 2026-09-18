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
    migrator.registerMigration("meetings-v5") { db in
      // Feature 004: six tables, cascades, closed value sets. No earlier table changes.
      let states = MeetingState.allCases.map { "'\($0.rawValue)'" }.joined(separator: ",")
      let activeStates = MeetingState.allCases.filter(\.isActive).map { "'\($0.rawValue)'" }
        .joined(separator: ",")
      let reasons = MeetingFailureReason.allCases.map { "'\($0.rawValue)'" }
        .joined(separator: ",")
      try db.create(table: "meetings") { t in
        t.column("id", .text).notNull().primaryKey()
        t.column("state", .text).notNull().check(sql: "state IN (\(states))")
        t.column("title", .text)
          .check(sql: "title IS NULL OR length(cast(title AS blob)) BETWEEN 1 AND 256")
        t.column("created_at", .integer).notNull()
        t.column("started_at", .integer)
        t.column("stopped_at", .integer)
        t.column("completed_at", .integer)
        t.column("wall_clock_ms", .integer).notNull().defaults(to: 0).check(
          sql: "wall_clock_ms >= 0")
        t.column("recorded_ms", .integer).notNull().defaults(to: 0).check(sql: "recorded_ms >= 0")
        t.column("finalization_stage", .text)
          .check(
            sql:
              "finalization_stage IS NULL OR finalization_stage IN ('none','mic','system','both')")
        t.column("failure_reason", .text)
          .check(sql: "failure_reason IS NULL OR failure_reason IN (\(reasons))")
        t.column("failure_detail", .text)
          .check(sql: "failure_detail IS NULL OR length(cast(failure_detail AS blob)) <= 512")
        t.column("updated_at", .integer).notNull()
        t.column("revision", .integer).notNull().defaults(to: 0).check(sql: "revision >= 0")
        t.check(sql: "failure_reason IS NULL OR state IN ('interrupted','failed')")
      }
      try db.execute(
        sql: "CREATE INDEX meetings_created_at_id ON meetings(created_at DESC, id DESC)")
      try db.execute(
        sql: "CREATE INDEX meetings_active ON meetings(state) WHERE state IN (\(activeStates))")
      try db.create(table: "meeting_tracks") { t in
        t.column("id", .text).notNull().primaryKey()
        t.column("meeting_id", .text).notNull().references("meetings", onDelete: .cascade)
        t.column("type", .text).notNull().check(sql: "type IN ('microphone','system')")
        t.column("codec", .text).notNull().check(sql: "codec = 'aac_lc'")
        t.column("container", .text).notNull().check(sql: "container = 'adts'")
        t.column("sample_rate", .integer).notNull().check(sql: "sample_rate > 0")
        t.column("channel_count", .integer).notNull().check(sql: "channel_count IN (1,2)")
        t.column("bitrate", .integer).notNull().check(sql: "bitrate > 0")
        t.column("health", .text).notNull()
          .check(sql: "health IN ('healthy','failed','finalized','unrecoverable')")
        t.column("failure_reason", .text)
          .check(sql: "failure_reason IS NULL OR failure_reason IN (\(reasons))")
        t.column("failed_at", .integer)
        t.column("total_duration_ms", .integer).notNull().defaults(to: 0)
          .check(sql: "total_duration_ms >= 0")
        t.column("total_bytes", .integer).notNull().defaults(to: 0).check(sql: "total_bytes >= 0")
        t.column("duration_warning", .integer).notNull().defaults(to: 0)
          .check(sql: "duration_warning IN (0,1)")
        t.column("dropped_frames", .integer).notNull().defaults(to: 0)
          .check(sql: "dropped_frames >= 0")
        t.check(sql: "(failure_reason IS NOT NULL) = (health IN ('failed','unrecoverable'))")
      }
      try db.execute(
        sql: "CREATE UNIQUE INDEX meeting_tracks_meeting_type ON meeting_tracks(meeting_id, type)")
      try db.create(table: "meeting_segments") { t in
        t.column("id", .text).notNull().primaryKey()
        t.column("track_id", .text).notNull().references("meeting_tracks", onDelete: .cascade)
        t.column("sequence", .integer).notNull().check(sql: "sequence >= 1")
        t.column("relative_path", .text).notNull()
          .check(sql: "length(cast(relative_path AS blob)) BETWEEN 1 AND 255")
        t.column("state", .text).notNull().check(
          sql: "state IN ('open','finalized','unrecoverable')")
        t.column("start_offset_ms", .integer).notNull().check(sql: "start_offset_ms >= 0")
        t.column("duration_ms", .integer).notNull().defaults(to: 0).check(sql: "duration_ms >= 0")
        t.column("byte_size", .integer).notNull().defaults(to: 0).check(sql: "byte_size >= 0")
        t.column("started_at", .integer).notNull()
        t.column("host_start_ns", .integer).notNull().check(sql: "host_start_ns >= 0")
        t.column("open_reason", .text).notNull()
          .check(sql: "open_reason IN ('start','resume','device_changed')")
        t.column("close_reason", .text)
          .check(
            sql:
              "close_reason IS NULL OR close_reason IN ('pause','system_sleep','stop','source_failed','storage_failed','device_changed','recovered')"
          )
        t.column("dropped_frames", .integer).notNull().defaults(to: 0)
          .check(sql: "dropped_frames >= 0")
        t.column("recovery_note", .text)
          .check(sql: "recovery_note IS NULL OR length(cast(recovery_note AS blob)) <= 512")
        t.column("failure_reason", .text)
          .check(sql: "failure_reason IS NULL OR failure_reason IN (\(reasons))")
        t.check(sql: "(failure_reason IS NOT NULL) = (state = 'unrecoverable')")
      }
      try db.execute(
        sql:
          "CREATE UNIQUE INDEX meeting_segments_track_sequence ON meeting_segments(track_id, sequence)"
      )
      try db.create(table: "meeting_pauses") { t in
        t.column("id", .text).notNull().primaryKey()
        t.column("meeting_id", .text).notNull().references("meetings", onDelete: .cascade)
        t.column("started_at", .integer).notNull()
        t.column("ended_at", .integer).check(sql: "ended_at IS NULL OR ended_at >= started_at")
        t.column("reason", .text).notNull().check(sql: "reason IN ('user','system_sleep')")
        t.column("closed_by", .text)
          .check(sql: "closed_by IS NULL OR closed_by IN ('resume','stop','reconciliation')")
        t.check(sql: "(ended_at IS NULL) = (closed_by IS NULL)")
      }
      try db.execute(
        sql:
          "CREATE UNIQUE INDEX meeting_pauses_open ON meeting_pauses(meeting_id) WHERE ended_at IS NULL"
      )
      try db.create(table: "meeting_notes") { t in
        t.column("meeting_id", .text).notNull().primaryKey()
          .references("meetings", onDelete: .cascade)
        t.column("text", .text).notNull().check(sql: "length(cast(text AS blob)) <= 1048576")
        t.column("author", .text).notNull().check(sql: "author = 'user'")
        t.column("updated_at", .integer).notNull()
        t.column("revision", .integer).notNull().defaults(to: 0).check(sql: "revision >= 0")
      }
      try db.create(table: "meeting_recovery_outcomes") { t in
        t.column("id", .text).notNull().primaryKey()
        t.column("meeting_id", .text).notNull().references("meetings", onDelete: .cascade)
        t.column("ran_at", .integer).notNull()
        t.column("found_state", .text).notNull().check(sql: "found_state IN (\(states))")
        t.column("found_stage", .text)
          .check(sql: "found_stage IS NULL OR found_stage IN ('none','mic','system','both')")
        t.column("segments_recovered", .integer).notNull().defaults(to: 0)
          .check(sql: "segments_recovered >= 0")
        t.column("segments_unrecoverable", .integer).notNull().defaults(to: 0)
          .check(sql: "segments_unrecoverable >= 0")
        t.column("segments_missing", .integer).notNull().defaults(to: 0)
          .check(sql: "segments_missing >= 0")
        t.column("pause_closed", .integer).notNull().defaults(to: 0)
          .check(sql: "pause_closed IN (0,1)")
        t.column("bytes_truncated", .integer).notNull().defaults(to: 0)
          .check(sql: "bytes_truncated >= 0")
        t.column("summary", .text).notNull().check(sql: "length(cast(summary AS blob)) <= 512")
      }
      try db.execute(
        sql:
          "CREATE INDEX meeting_recovery_outcomes_meeting ON meeting_recovery_outcomes(meeting_id)")
    }
    return migrator
  }
}
