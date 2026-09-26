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
      try createRewriteAttempts(
        db, named: "rewrite_attempts",
        categories: RewriteFailureCategory.persisted.filter { $0 != .contextCopied },
        contextHash: false)
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
    migrator.registerMigration("transcripts-v6") { db in
      try db.execute(
        sql: """
          CREATE TABLE meeting_transcriptions (
            meeting_id TEXT PRIMARY KEY NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
            state TEXT NOT NULL CHECK(state IN ('not_requested','pending','live','finalizing','final','failed','interrupted')),
            live_requested INTEGER NOT NULL CHECK(live_requested IN (0,1)),
            live_state TEXT CHECK(live_state IN ('live','catching_up','degraded','suspended','stopped')),
            pass_id TEXT, pass_kind TEXT CHECK(pass_kind IN ('live','final')),
            engine TEXT, model_id TEXT, model_revision TEXT,
            model_manifest_hash TEXT CHECK(model_manifest_hash IS NULL OR (length(model_manifest_hash)=64 AND model_manifest_hash NOT GLOB '*[^0-9a-fA-F]*')),
            pipeline_version TEXT CHECK(length(CAST(pipeline_version AS BLOB))<=256), planner_version TEXT,
            vocabulary_revision INTEGER CHECK(vocabulary_revision>=0),
            vocabulary_hash TEXT CHECK(vocabulary_hash IS NULL OR (length(vocabulary_hash)=64 AND vocabulary_hash NOT GLOB '*[^0-9a-fA-F]*')),
            analysis_descriptor_json TEXT CHECK(length(CAST(analysis_descriptor_json AS BLOB))<=16384),
            started_at INTEGER, live_started_at INTEGER, finalization_started_at INTEGER, finalized_at INTEGER,
            progress_sequence INTEGER CHECK(progress_sequence>=1), progress_sample INTEGER CHECK(progress_sample>=0),
            covered_ms INTEGER NOT NULL DEFAULT 0 CHECK(covered_ms>=0),
            recorded_ms_at_pass INTEGER NOT NULL DEFAULT 0 CHECK(recorded_ms_at_pass>=0),
            replaced_provisional_count INTEGER NOT NULL DEFAULT 0 CHECK(replaced_provisional_count>=0),
            model_reload_count INTEGER NOT NULL DEFAULT 0 CHECK(model_reload_count>=0),
            failure_category TEXT CHECK(failure_category IN ('model_unavailable','model_provisioning','model_load_failure','audio_decode_failure','analysis_stream_failure','runtime_failure','finalization_interrupted','persistence_failure','persistence_capacity')),
            failure_detail TEXT CHECK(length(CAST(failure_detail AS BLOB))<=512),
            segment_count INTEGER NOT NULL DEFAULT 0 CHECK(segment_count>=0),
            text_bytes INTEGER NOT NULL DEFAULT 0 CHECK(text_bytes>=0),
            updated_at INTEGER NOT NULL, revision INTEGER NOT NULL DEFAULT 0 CHECK(revision>=0),
            CHECK(live_state IS NULL OR state='live'),
            CHECK((failure_category IS NOT NULL)=(state IN ('failed','interrupted')))
          );
          CREATE INDEX meeting_transcriptions_active ON meeting_transcriptions(state) WHERE state IN ('pending','live','finalizing');
          CREATE TABLE transcript_segments (
            id TEXT PRIMARY KEY NOT NULL, meeting_id TEXT NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
            pass_id TEXT NOT NULL, finality TEXT NOT NULL CHECK(finality IN ('provisional','final')),
            ordinal INTEGER NOT NULL CHECK(ordinal>=0), stretch_sequence INTEGER NOT NULL CHECK(stretch_sequence>=1),
            start_ms INTEGER NOT NULL CHECK(start_ms>=0), end_ms INTEGER NOT NULL CHECK(end_ms>start_ms),
            window_index INTEGER NOT NULL CHECK(window_index>=0), timing_basis TEXT NOT NULL CHECK(timing_basis IN ('word','window')),
            raw_text TEXT NOT NULL CHECK(length(CAST(raw_text AS BLOB))<=4096),
            assembled_text TEXT NOT NULL CHECK(length(CAST(assembled_text AS BLOB))<=4096),
            normalized_text TEXT NOT NULL CHECK(length(CAST(normalized_text AS BLOB))<=4096),
            engine TEXT NOT NULL, model_id TEXT NOT NULL, model_revision TEXT NOT NULL,
            pipeline_version TEXT NOT NULL CHECK(length(CAST(pipeline_version AS BLOB))<=256),
            analysis_tracks TEXT NOT NULL CHECK(analysis_tracks IN ('mic','system','both')),
            speaker TEXT NOT NULL DEFAULT 'unassigned' CHECK(speaker='unassigned'), created_at INTEGER NOT NULL,
            UNIQUE(meeting_id,pass_id,ordinal)
          );
          CREATE INDEX transcript_segments_page ON transcript_segments(meeting_id,finality,ordinal);
          CREATE INDEX transcript_segments_pass ON transcript_segments(pass_id);
          CREATE TABLE transcript_live_gaps (
            id TEXT PRIMARY KEY NOT NULL, meeting_id TEXT NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
            pass_id TEXT NOT NULL, stretch_sequence INTEGER NOT NULL CHECK(stretch_sequence>=1),
            start_ms INTEGER NOT NULL CHECK(start_ms>=0), end_ms INTEGER NOT NULL CHECK(end_ms>start_ms),
            reason TEXT NOT NULL CHECK(reason IN ('backpressure','suspended','tap_overflow','pause_drain','stop_drain','model_reload')),
            covered_by_final INTEGER NOT NULL DEFAULT 0 CHECK(covered_by_final IN (0,1)), created_at INTEGER NOT NULL
          );
          CREATE TABLE transcript_usage (
            id INTEGER PRIMARY KEY CHECK(id=1), text_bytes INTEGER NOT NULL CHECK(text_bytes>=0),
            segment_rows INTEGER NOT NULL CHECK(segment_rows>=0), schema_version INTEGER NOT NULL CHECK(schema_version=1)
          );
          INSERT INTO transcript_usage VALUES(1,0,0,1);
          INSERT INTO meeting_transcriptions(meeting_id,state,live_requested,updated_at)
            SELECT id,'not_requested',0,updated_at FROM meetings;
          """)
    }
    // Feature 007: new tables only; transcript_segments is not altered and final
    // segment rows are never updated. Run pointers null out when a run row is removed.
    migrator.registerMigration("speakers-v7") { db in
      let hex64 = "length(model_manifest_hash)=64 AND model_manifest_hash NOT GLOB '*[^0-9a-f]*'"
      let categories = DiarizationFailureCategory.allCases.map { "'\($0.rawValue)'" }
        .joined(separator: ",")
      try db.execute(
        sql: """
          CREATE TABLE diarization_runs (
            id TEXT PRIMARY KEY NOT NULL,
            meeting_id TEXT NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
            transcript_pass_id TEXT NOT NULL,
            state TEXT NOT NULL CHECK(state IN ('pending','running','succeeded','failed','interrupted','superseded')),
            "trigger" TEXT NOT NULL CHECK("trigger" IN ('automatic','manual','retry','in_room_change')),
            in_room INTEGER NOT NULL CHECK(in_room IN (0,1)),
            engine TEXT NOT NULL, model_id TEXT NOT NULL, model_revision TEXT NOT NULL,
            model_manifest_hash TEXT NOT NULL CHECK(\(hex64)),
            pipeline_version TEXT NOT NULL CHECK(length(CAST(pipeline_version AS BLOB)) BETWEEN 1 AND 256),
            created_at INTEGER NOT NULL, started_at INTEGER, completed_at INTEGER,
            failure_category TEXT CHECK(failure_category IS NULL OR failure_category IN (\(categories))),
            failure_detail TEXT CHECK(failure_detail IS NULL OR length(CAST(failure_detail AS BLOB))<=512),
            inferred_speaker_count INTEGER NOT NULL DEFAULT 0 CHECK(inferred_speaker_count>=0),
            audio_ms INTEGER NOT NULL DEFAULT 0 CHECK(audio_ms>=0),
            window_count INTEGER NOT NULL DEFAULT 0 CHECK(window_count>=0),
            turn_count INTEGER NOT NULL DEFAULT 0 CHECK(turn_count>=0),
            overlap_turn_count INTEGER NOT NULL DEFAULT 0 CHECK(overlap_turn_count>=0),
            unknown_count INTEGER NOT NULL DEFAULT 0 CHECK(unknown_count>=0),
            ambiguous_count INTEGER NOT NULL DEFAULT 0 CHECK(ambiguous_count>=0),
            uncertain_reconciliations INTEGER NOT NULL DEFAULT 0 CHECK(uncertain_reconciliations>=0),
            overflow_turns INTEGER NOT NULL DEFAULT 0 CHECK(overflow_turns>=0),
            preemption_count INTEGER NOT NULL DEFAULT 0 CHECK(preemption_count>=0),
            CHECK((failure_category IS NOT NULL) = (state IN ('failed','interrupted')))
          );
          CREATE INDEX diarization_runs_meeting ON diarization_runs(meeting_id, created_at);
          CREATE UNIQUE INDEX diarization_runs_active ON diarization_runs(meeting_id)
            WHERE state IN ('pending','running');
          CREATE TABLE meeting_diarization (
            meeting_id TEXT PRIMARY KEY NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
            accepted_run_id TEXT REFERENCES diarization_runs(id) ON DELETE SET NULL,
            current_run_id TEXT REFERENCES diarization_runs(id) ON DELETE SET NULL,
            in_room INTEGER NOT NULL DEFAULT 0 CHECK(in_room IN (0,1)),
            updated_at INTEGER NOT NULL,
            revision INTEGER NOT NULL DEFAULT 0 CHECK(revision>=0)
          );
          CREATE TABLE meeting_speakers (
            id TEXT PRIMARY KEY NOT NULL,
            meeting_id TEXT NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
            run_id TEXT REFERENCES diarization_runs(id) ON DELETE CASCADE,
            cluster_key INTEGER NOT NULL CHECK(cluster_key>=0),
            source TEXT NOT NULL CHECK(source IN ('local','remote')),
            track TEXT CHECK(track IS NULL OR track IN ('microphone','system')),
            origin TEXT NOT NULL CHECK(origin IN ('engine','manual')),
            label_ordinal INTEGER NOT NULL DEFAULT 1 CHECK(label_ordinal>=1),
            color_index INTEGER NOT NULL DEFAULT 0 CHECK(color_index BETWEEN 0 AND 7),
            display_name TEXT CHECK(display_name IS NULL OR (
              length(display_name) BETWEEN 1 AND 80 AND display_name = trim(display_name)
              AND display_name NOT GLOB ('*[' || char(1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31,127) || ']*'))),
            merged_into TEXT REFERENCES meeting_speakers(id) ON DELETE SET NULL,
            reconciliation TEXT NOT NULL DEFAULT 'confident' CHECK(reconciliation IN ('confident','uncertain')),
            first_ms INTEGER NOT NULL DEFAULT 0 CHECK(first_ms>=0),
            speech_ms INTEGER NOT NULL DEFAULT 0 CHECK(speech_ms>=0),
            engine_quality REAL,
            CHECK((origin = 'manual') = (run_id IS NULL)),
            CHECK((origin = 'manual') = (track IS NULL)),
            CHECK(merged_into IS NULL OR merged_into <> id)
          );
          CREATE UNIQUE INDEX meeting_speakers_cluster ON meeting_speakers(run_id, cluster_key)
            WHERE run_id IS NOT NULL;
          CREATE INDEX meeting_speakers_meeting ON meeting_speakers(meeting_id);
          CREATE TABLE speaker_turns (
            id INTEGER PRIMARY KEY,
            run_id TEXT NOT NULL REFERENCES diarization_runs(id) ON DELETE CASCADE,
            speaker_id TEXT REFERENCES meeting_speakers(id) ON DELETE CASCADE,
            track TEXT NOT NULL CHECK(track IN ('microphone','system')),
            start_ms INTEGER NOT NULL CHECK(start_ms>=0),
            end_ms INTEGER NOT NULL CHECK(end_ms>start_ms),
            engine_quality REAL,
            overlapped INTEGER NOT NULL DEFAULT 0 CHECK(overlapped IN (0,1))
          );
          CREATE INDEX speaker_turns_run_start ON speaker_turns(run_id, start_ms);
          CREATE INDEX speaker_turns_speaker ON speaker_turns(speaker_id);
          CREATE TABLE speaker_assignments (
            run_id TEXT NOT NULL REFERENCES diarization_runs(id) ON DELETE CASCADE,
            segment_id TEXT NOT NULL REFERENCES transcript_segments(id) ON DELETE CASCADE,
            auto_kind TEXT NOT NULL CHECK(auto_kind IN ('speaker','unknown','ambiguous')),
            auto_speaker_id TEXT REFERENCES meeting_speakers(id),
            top_speaker_id TEXT, second_speaker_id TEXT,
            top_coverage REAL NOT NULL DEFAULT 0 CHECK(top_coverage BETWEEN 0 AND 1),
            second_coverage REAL NOT NULL DEFAULT 0 CHECK(second_coverage BETWEEN 0 AND 1),
            manual_kind TEXT CHECK(manual_kind IS NULL OR manual_kind IN ('speaker','unknown')),
            manual_speaker_id TEXT REFERENCES meeting_speakers(id),
            manual_at INTEGER,
            PRIMARY KEY(run_id, segment_id),
            CHECK((auto_speaker_id IS NOT NULL) = (auto_kind = 'speaker')),
            CHECK((manual_speaker_id IS NOT NULL) = (manual_kind IS 'speaker')),
            CHECK((manual_at IS NOT NULL) = (manual_kind IS NOT NULL))
          ) WITHOUT ROWID;
          CREATE INDEX speaker_assignments_segment ON speaker_assignments(segment_id);
          CREATE TABLE speaker_corrections (
            id TEXT PRIMARY KEY NOT NULL,
            meeting_id TEXT NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
            run_id TEXT NOT NULL REFERENCES diarization_runs(id) ON DELETE CASCADE,
            kind TEXT NOT NULL CHECK(kind IN ('rename','merge','unmerge','segment')),
            speaker_id TEXT, target_speaker_id TEXT,
            segment_id TEXT CHECK((segment_id IS NOT NULL) = (kind = 'segment')),
            previous_value TEXT CHECK(previous_value IS NULL OR length(previous_value)<=80),
            new_value TEXT CHECK(new_value IS NULL OR length(new_value)<=80),
            needs_review INTEGER NOT NULL DEFAULT 0 CHECK(needs_review IN (0,1)),
            created_at INTEGER NOT NULL, undone_at INTEGER
          );
          CREATE INDEX speaker_corrections_meeting ON speaker_corrections(meeting_id, created_at);
          INSERT INTO meeting_diarization(meeting_id, in_room, updated_at, revision)
            SELECT id, 0, updated_at, 0 FROM meetings;
          """)
    }
    // Feature 010: identity tables only; no 004–007 table is altered. Vectors are 1 KB
    // BLOBs (dimension × 4 bytes, little-endian Float32). Every meeting-scoped table
    // cascades from `meetings`; every per-cluster table from `meeting_speakers`.
    migrator.registerMigration("identities-v8") { db in
      let hex64 = "length(model_manifest_hash)=64 AND model_manifest_hash NOT GLOB '*[^0-9a-f]*'"
      let name = """
        length(display_name) BETWEEN 1 AND 80 AND display_name = trim(display_name)
        AND display_name NOT GLOB ('*[' || char(1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31,127) || ']*')
        """
      let categories = IdentificationFailureCategory.allCases.map { "'\($0.rawValue)'" }
        .joined(separator: ",")
      let triggers = IdentificationTrigger.allCases.map { "'\($0.rawValue)'" }
        .joined(separator: ",")
      let states = IdentityState.allCases.map { "'\($0.rawValue)'" }.joined(separator: ",")
      let origins = IdentityOrigin.allCases.map { "'\($0.rawValue)'" }.joined(separator: ",")
      let consents = SampleConsent.allCases.map { "'\($0.rawValue)'" }.joined(separator: ",")
      let tiers = CandidateTier.allCases.map { "'\($0.rawValue)'" }.joined(separator: ",")
      try db.execute(
        sql: """
          CREATE TABLE known_speakers (
            id TEXT PRIMARY KEY NOT NULL,
            display_name TEXT NOT NULL CHECK(\(name)),
            is_local_user INTEGER NOT NULL DEFAULT 0 CHECK(is_local_user IN (0,1)),
            recognition_enabled INTEGER NOT NULL DEFAULT 1 CHECK(recognition_enabled IN (0,1)),
            created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL,
            revision INTEGER NOT NULL DEFAULT 0 CHECK(revision>=0)
          );
          CREATE UNIQUE INDEX known_speakers_local_user ON known_speakers(is_local_user)
            WHERE is_local_user = 1;
          CREATE TABLE voice_samples (
            id TEXT PRIMARY KEY NOT NULL,
            known_speaker_id TEXT NOT NULL REFERENCES known_speakers(id) ON DELETE CASCADE,
            engine TEXT NOT NULL, model_id TEXT NOT NULL, model_revision TEXT NOT NULL,
            model_manifest_hash TEXT NOT NULL CHECK(\(hex64)),
            dimension INTEGER NOT NULL CHECK(dimension BETWEEN 1 AND 4096),
            pipeline_version TEXT NOT NULL CHECK(length(CAST(pipeline_version AS BLOB)) BETWEEN 1 AND 256),
            vector BLOB NOT NULL CHECK(length(vector) = dimension * 4),
            quality_label TEXT NOT NULL CHECK(quality_label IN ('good','fair')),
            quality_score REAL NOT NULL CHECK(quality_score BETWEEN 0 AND 1),
            engine_quality REAL,
            speech_ms INTEGER NOT NULL CHECK(speech_ms>0),
            track TEXT NOT NULL CHECK(track IN ('microphone','system')),
            start_ms INTEGER NOT NULL CHECK(start_ms>=0),
            end_ms INTEGER NOT NULL CHECK(end_ms>start_ms),
            source_meeting_id TEXT REFERENCES meetings(id) ON DELETE SET NULL,
            source_speaker_id TEXT REFERENCES meeting_speakers(id) ON DELETE SET NULL,
            consent TEXT NOT NULL CHECK(consent IN (\(consents))),
            active INTEGER NOT NULL DEFAULT 1 CHECK(active IN (0,1)),
            created_at INTEGER NOT NULL,
            retired_at INTEGER,
            CHECK((retired_at IS NOT NULL) = (active = 0))
          );
          CREATE INDEX voice_samples_speaker_active ON voice_samples(known_speaker_id, active);
          CREATE INDEX voice_samples_source_meeting ON voice_samples(source_meeting_id);
          CREATE INDEX voice_samples_source_speaker ON voice_samples(source_speaker_id);
          CREATE TABLE identification_runs (
            id TEXT PRIMARY KEY NOT NULL,
            meeting_id TEXT NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
            diarization_run_id TEXT NOT NULL REFERENCES diarization_runs(id) ON DELETE CASCADE,
            state TEXT NOT NULL CHECK(state IN ('pending','running','succeeded','failed','interrupted','superseded')),
            "trigger" TEXT NOT NULL CHECK("trigger" IN (\(triggers))),
            engine TEXT NOT NULL, model_id TEXT NOT NULL, model_revision TEXT NOT NULL,
            model_manifest_hash TEXT NOT NULL CHECK(\(hex64)),
            dimension INTEGER NOT NULL CHECK(dimension BETWEEN 1 AND 4096),
            pipeline_version TEXT NOT NULL CHECK(length(CAST(pipeline_version AS BLOB)) BETWEEN 1 AND 256),
            threshold_policy TEXT NOT NULL CHECK(length(CAST(threshold_policy AS BLOB)) BETWEEN 1 AND 128),
            created_at INTEGER NOT NULL, started_at INTEGER, completed_at INTEGER,
            failure_category TEXT CHECK(failure_category IS NULL OR failure_category IN (\(categories))),
            failure_detail TEXT CHECK(failure_detail IS NULL OR length(CAST(failure_detail AS BLOB))<=512),
            cluster_count INTEGER NOT NULL DEFAULT 0 CHECK(cluster_count>=0),
            candidate_count INTEGER NOT NULL DEFAULT 0 CHECK(candidate_count>=0),
            region_count INTEGER NOT NULL DEFAULT 0 CHECK(region_count>=0),
            rejected_region_count INTEGER NOT NULL DEFAULT 0 CHECK(rejected_region_count>=0),
            comparison_count INTEGER NOT NULL DEFAULT 0 CHECK(comparison_count>=0),
            recognized_count INTEGER NOT NULL DEFAULT 0 CHECK(recognized_count>=0),
            suggested_count INTEGER NOT NULL DEFAULT 0 CHECK(suggested_count>=0),
            unknown_count INTEGER NOT NULL DEFAULT 0 CHECK(unknown_count>=0),
            preserved_manual_count INTEGER NOT NULL DEFAULT 0 CHECK(preserved_manual_count>=0),
            preemption_count INTEGER NOT NULL DEFAULT 0 CHECK(preemption_count>=0),
            CHECK((failure_category IS NOT NULL) = (state IN ('failed','interrupted')))
          );
          CREATE INDEX identification_runs_meeting ON identification_runs(meeting_id, created_at);
          CREATE UNIQUE INDEX identification_runs_active ON identification_runs(meeting_id)
            WHERE state IN ('pending','running');
          CREATE TABLE meeting_identification (
            meeting_id TEXT PRIMARY KEY NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
            accepted_run_id TEXT REFERENCES identification_runs(id) ON DELETE SET NULL,
            current_run_id TEXT REFERENCES identification_runs(id) ON DELETE SET NULL,
            updated_at INTEGER NOT NULL
          );
          CREATE TABLE identity_assignments (
            id TEXT PRIMARY KEY NOT NULL,
            meeting_id TEXT NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
            meeting_speaker_id TEXT NOT NULL REFERENCES meeting_speakers(id) ON DELETE CASCADE,
            scope TEXT NOT NULL CHECK(scope IN ('self','merged')),
            known_speaker_id TEXT REFERENCES known_speakers(id) ON DELETE CASCADE,
            state TEXT NOT NULL CHECK(state IN (\(states))),
            origin TEXT NOT NULL CHECK(origin IN (\(origins))),
            run_id TEXT REFERENCES identification_runs(id) ON DELETE SET NULL,
            score REAL CHECK(score IS NULL OR score BETWEEN -1 AND 1),
            engine TEXT, model_id TEXT, model_revision TEXT, threshold_policy TEXT,
            second_known_speaker_id TEXT REFERENCES known_speakers(id) ON DELETE SET NULL,
            confirmed_at INTEGER, corrected_at INTEGER,
            created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL,
            UNIQUE(meeting_speaker_id, scope),
            CHECK((state IN ('recognized','possible','confirmed')) = (known_speaker_id IS NOT NULL)),
            CHECK(state NOT IN ('recognized','possible') OR origin = 'automatic_match'),
            CHECK(state <> 'confirmed' OR origin IN ('user_confirmation','manual_profile_selection','new_profile_created','manual_correction')),
            CHECK(state <> 'rejected_unknown' OR origin = 'kept_unknown'),
            CHECK((confirmed_at IS NOT NULL) = (state = 'confirmed')),
            CHECK(state NOT IN ('recognized','possible') OR (score IS NOT NULL AND run_id IS NOT NULL)),
            CHECK(score IS NULL OR (engine IS NOT NULL AND model_id IS NOT NULL AND model_revision IS NOT NULL AND threshold_policy IS NOT NULL))
          );
          CREATE INDEX identity_assignments_known ON identity_assignments(known_speaker_id);
          CREATE INDEX identity_assignments_meeting ON identity_assignments(meeting_id);
          CREATE TABLE match_candidates (
            run_id TEXT NOT NULL REFERENCES identification_runs(id) ON DELETE CASCADE,
            meeting_speaker_id TEXT NOT NULL REFERENCES meeting_speakers(id) ON DELETE CASCADE,
            known_speaker_id TEXT NOT NULL REFERENCES known_speakers(id) ON DELETE CASCADE,
            score REAL NOT NULL CHECK(score BETWEEN -1 AND 1),
            tier TEXT NOT NULL CHECK(tier IN (\(tiers))),
            reasons TEXT NOT NULL DEFAULT '' CHECK(length(CAST(reasons AS BLOB))<=128),
            sample_count INTEGER NOT NULL DEFAULT 0 CHECK(sample_count>=0),
            support_count INTEGER NOT NULL DEFAULT 0 CHECK(support_count>=0),
            PRIMARY KEY(run_id, meeting_speaker_id, known_speaker_id)
          ) WITHOUT ROWID;
          CREATE INDEX match_candidates_known ON match_candidates(known_speaker_id);
          CREATE INDEX match_candidates_speaker ON match_candidates(meeting_speaker_id);
          CREATE TABLE rejected_candidates (
            meeting_speaker_id TEXT NOT NULL REFERENCES meeting_speakers(id) ON DELETE CASCADE,
            known_speaker_id TEXT NOT NULL REFERENCES known_speakers(id) ON DELETE CASCADE,
            rejected_at INTEGER NOT NULL,
            PRIMARY KEY(meeting_speaker_id, known_speaker_id)
          ) WITHOUT ROWID;
          CREATE INDEX rejected_candidates_known ON rejected_candidates(known_speaker_id);
          INSERT INTO meeting_identification(meeting_id, updated_at)
            SELECT id, updated_at FROM meetings;
          """)
    }
    // Feature 011: seven analysis tables; no 001–010 table is altered. Run rows
    // are content-free (no summary or item text); content rows cascade from
    // `analysis_runs`; overlays survive a regeneration through set-null.
    migrator.registerMigration("intelligence-v9") { db in
      let hex64 = "length(%@)=64 AND %@ NOT GLOB '*[^0-9a-f]*'"
      let ev = String(format: hex64, "evidence_version", "evidence_version")
      let aev = String(format: hex64, "accepted_evidence_version", "accepted_evidence_version")
      let nh = String(format: hex64, "note_hash", "note_hash")
      let categories = AnalysisFailureCategory.allCases.map { "'\($0.rawValue)'" }
        .joined(separator: ",")
      let states = AnalysisRunState.allCases.map { "'\($0.rawValue)'" }.joined(separator: ",")
      let triggers = AnalysisTrigger.allCases.map { "'\($0.rawValue)'" }.joined(separator: ",")
      let languages = AnalysisLanguage.allCases.map { "'\($0.rawValue)'" }.joined(separator: ",")
      let itemKinds = AnalysisItemKind.allCases.map { "'\($0.rawValue)'" }.joined(separator: ",")
      let ownerCertainties = ["confirmed", "recognized", "local_name", "local_user"]
        .map { "'\($0)'" }.joined(separator: ",")
      let ownerKinds = ["participant", "mentioned", "none"].map { "'\($0)'" }
        .joined(separator: ",")
      let ownershipStates = ["explicit", "supported", "unresolved"].map { "'\($0)'" }
        .joined(separator: ",")
      let dueStates = ["explicit_absolute", "explicit_relative_resolved", "unresolved", "absent"]
        .map { "'\($0)'" }.joined(separator: ",")
      let overlayFields = OverlayField.allCases.map { "'\($0.rawValue)'" }
        .joined(separator: ",")
      let counters = [
        "chunk_count", "request_count", "retry_count", "preemption_count", "input_bytes",
        "output_bytes", "item_count", "dropped_literal_count", "dropped_unsupported_count",
        "identity_downgrade_count", "unresolved_owner_count", "duration_ms",
      ]
      try db.execute(
        sql: """
          CREATE TABLE analysis_runs (
            id TEXT PRIMARY KEY NOT NULL,
            meeting_id TEXT NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
            state TEXT NOT NULL CHECK(state IN (\(states))),
            "trigger" TEXT NOT NULL CHECK("trigger" IN (\(triggers))),
            evidence_version TEXT NOT NULL CHECK(\(ev)),
            transcript_pass_id TEXT,
            server_version TEXT CHECK(server_version IS NULL OR length(CAST(server_version AS BLOB))<=64),
            protocol_version INTEGER NOT NULL CHECK(protocol_version=1),
            schema_version INTEGER NOT NULL CHECK(schema_version=1),
            backend_kind TEXT CHECK(backend_kind IS NULL OR length(CAST(backend_kind AS BLOB))<=128),
            backend_model TEXT CHECK(backend_model IS NULL OR length(CAST(backend_model AS BLOB))<=128),
            prompt_versions TEXT CHECK(prompt_versions IS NULL OR length(CAST(prompt_versions AS BLOB))<=128),
            pipeline_version TEXT CHECK(pipeline_version IS NULL OR length(CAST(pipeline_version AS BLOB))<=64),
            language_policy TEXT CHECK(language_policy IS NULL OR language_policy IN (\(languages))),
            request_config_json TEXT CHECK(request_config_json IS NULL OR length(CAST(request_config_json AS BLOB))<=2048),
            created_at INTEGER NOT NULL, started_at INTEGER, completed_at INTEGER,
            failure_category TEXT CHECK(failure_category IS NULL OR failure_category IN (\(categories))),
            failure_detail TEXT CHECK(failure_detail IS NULL OR length(CAST(failure_detail AS BLOB))<=512),
            \(counters.map { "\($0) INTEGER NOT NULL DEFAULT 0 CHECK(\($0)>=0)" }.joined(separator: ", ")),
            CHECK((failure_category IS NOT NULL) = (state IN ('failed','timed_out','interrupted')))
          );
          CREATE INDEX analysis_runs_meeting ON analysis_runs(meeting_id, created_at);
          CREATE UNIQUE INDEX analysis_runs_active ON analysis_runs(meeting_id)
            WHERE state IN ('pending','running');
          CREATE TABLE meeting_analysis (
            meeting_id TEXT PRIMARY KEY NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
            accepted_run_id TEXT REFERENCES analysis_runs(id) ON DELETE SET NULL,
            current_run_id TEXT REFERENCES analysis_runs(id) ON DELETE SET NULL,
            accepted_evidence_version TEXT CHECK(accepted_evidence_version IS NULL OR \(aev)),
            auto_restarted_at INTEGER,
            updated_at INTEGER NOT NULL,
            revision INTEGER NOT NULL DEFAULT 0 CHECK(revision>=0)
          );
          CREATE TABLE analysis_summaries (
            run_id TEXT PRIMARY KEY NOT NULL REFERENCES analysis_runs(id) ON DELETE CASCADE,
            meeting_id TEXT NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
            text TEXT NOT NULL CHECK(length(CAST(text AS BLOB)) BETWEEN 1 AND 4000),
            language TEXT NOT NULL CHECK(language IN (\(languages))),
            whole_meeting INTEGER NOT NULL CHECK(whole_meeting IN (0,1))
          );
          CREATE TABLE analysis_topics (
            id TEXT PRIMARY KEY NOT NULL,
            run_id TEXT NOT NULL REFERENCES analysis_runs(id) ON DELETE CASCADE,
            meeting_id TEXT NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
            ordinal INTEGER NOT NULL CHECK(ordinal>=0),
            title TEXT NOT NULL CHECK(length(CAST(title AS BLOB)) BETWEEN 1 AND 200),
            summary TEXT NOT NULL CHECK(length(CAST(summary AS BLOB))<=2000),
            bullets_json TEXT NOT NULL CHECK(length(CAST(bullets_json AS BLOB))<=8192),
            UNIQUE(run_id, ordinal)
          );
          CREATE TABLE analysis_items (
            id TEXT PRIMARY KEY NOT NULL,
            run_id TEXT NOT NULL REFERENCES analysis_runs(id) ON DELETE CASCADE,
            meeting_id TEXT NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
            kind TEXT NOT NULL CHECK(kind IN (\(itemKinds))),
            ordinal INTEGER NOT NULL CHECK(ordinal>=0),
            text TEXT NOT NULL CHECK(length(CAST(text AS BLOB)) BETWEEN 1 AND 1000),
            evidence_class TEXT CHECK(evidence_class IS NULL OR evidence_class IN ('explicit','implied')),
            topic_id TEXT REFERENCES analysis_topics(id) ON DELETE SET NULL,
            owner_kind TEXT CHECK(owner_kind IS NULL OR owner_kind IN (\(ownerKinds))),
            owner_speaker_id TEXT REFERENCES meeting_speakers(id) ON DELETE SET NULL,
            owner_known_speaker_id TEXT REFERENCES known_speakers(id) ON DELETE SET NULL,
            owner_name TEXT CHECK(owner_name IS NULL OR length(CAST(owner_name AS BLOB)) BETWEEN 1 AND 80),
            owner_certainty TEXT CHECK(owner_certainty IS NULL OR owner_certainty IN (\(ownerCertainties))),
            ownership_state TEXT CHECK(ownership_state IS NULL OR ownership_state IN (\(ownershipStates))),
            due_state TEXT CHECK(due_state IS NULL OR due_state IN (\(dueStates))),
            due_date TEXT CHECK(due_date IS NULL OR due_date GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]'),
            due_original TEXT CHECK(due_original IS NULL OR length(CAST(due_original AS BLOB))<=80),
            due_source_segment_id TEXT,
            due_source_note_ordinal INTEGER CHECK(due_source_note_ordinal IS NULL OR due_source_note_ordinal>=1),
            UNIQUE(run_id, kind, ordinal),
            CHECK(kind<>'action_item' OR (
              owner_kind IS NOT NULL AND ownership_state IS NOT NULL AND due_state IS NOT NULL)),
            CHECK(kind='action_item' OR (
              owner_kind IS NULL AND owner_speaker_id IS NULL AND owner_known_speaker_id IS NULL
              AND owner_name IS NULL AND owner_certainty IS NULL AND ownership_state IS NULL
              AND due_state IS NULL AND due_date IS NULL AND due_original IS NULL
              AND due_source_segment_id IS NULL AND due_source_note_ordinal IS NULL)),
            CHECK((owner_kind='participant') = (owner_speaker_id IS NOT NULL)),
            CHECK(owner_known_speaker_id IS NULL OR owner_kind='participant'),
            CHECK((owner_name IS NULL) = (owner_kind IS NULL OR owner_kind<>'mentioned')),
            CHECK((owner_certainty IS NULL) = (owner_kind IS NULL OR owner_kind<>'participant')),
            CHECK(owner_kind IS NULL OR owner_kind<>'mentioned' OR ownership_state IN ('supported','unresolved')),
            CHECK(owner_kind IS NULL OR owner_kind<>'none' OR ownership_state='unresolved'),
            CHECK((due_date IS NOT NULL) = (due_state IN ('explicit_absolute','explicit_relative_resolved'))),
            CHECK((due_original IS NULL) = (due_state IS NULL OR due_state='absent')),
            CHECK((due_state='absent') = (due_source_segment_id IS NULL AND due_source_note_ordinal IS NULL)),
            CHECK(due_source_segment_id IS NULL OR due_source_note_ordinal IS NULL)
          );
          CREATE TABLE analysis_sources (
            run_id TEXT NOT NULL REFERENCES analysis_runs(id) ON DELETE CASCADE,
            meeting_id TEXT NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
            target_kind TEXT NOT NULL CHECK(target_kind IN ('summary','topic','item')),
            target_id TEXT NOT NULL,
            ordinal INTEGER NOT NULL CHECK(ordinal>=0),
            source_kind TEXT NOT NULL CHECK(source_kind IN ('segment','note')),
            segment_id TEXT REFERENCES transcript_segments(id) ON DELETE CASCADE,
            note_ordinal INTEGER CHECK(note_ordinal IS NULL OR note_ordinal>=1),
            note_hash TEXT CHECK(note_hash IS NULL OR \(nh)),
            PRIMARY KEY(target_kind, target_id, ordinal),
            CHECK((source_kind='segment') = (segment_id IS NOT NULL)),
            CHECK((source_kind='note') = (note_ordinal IS NOT NULL)),
            CHECK((note_hash IS NOT NULL) = (source_kind='note'))
          ) WITHOUT ROWID;
          CREATE INDEX analysis_sources_run ON analysis_sources(run_id);
          CREATE TABLE analysis_overlays (
            id TEXT PRIMARY KEY NOT NULL,
            meeting_id TEXT NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
            item_id TEXT REFERENCES analysis_items(id) ON DELETE SET NULL,
            target_kind TEXT NOT NULL CHECK(target_kind IN ('summary','item')),
            item_kind TEXT CHECK(item_kind IS NULL OR item_kind IN (\(itemKinds))),
            field TEXT NOT NULL CHECK(field IN (\(overlayFields))),
            user_value TEXT NOT NULL CHECK(length(CAST(user_value AS BLOB))<=4000),
            ai_value_snapshot TEXT CHECK(ai_value_snapshot IS NULL OR length(CAST(ai_value_snapshot AS BLOB))<=4000),
            item_text_snapshot TEXT CHECK(item_text_snapshot IS NULL OR length(CAST(item_text_snapshot AS BLOB))<=1000),
            source_key TEXT CHECK(source_key IS NULL OR length(CAST(source_key AS BLOB))<=1024),
            created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL,
            orphaned_at INTEGER,
            CHECK(target_kind='summary' OR item_kind IS NOT NULL),
            CHECK(target_kind='item' OR (item_kind IS NULL AND item_id IS NULL))
          );
          CREATE UNIQUE INDEX analysis_overlays_item_field ON analysis_overlays(item_id, field)
            WHERE item_id IS NOT NULL;
          CREATE UNIQUE INDEX analysis_overlays_summary ON analysis_overlays(meeting_id)
            WHERE target_kind='summary';
          CREATE INDEX analysis_overlays_meeting ON analysis_overlays(meeting_id);
          INSERT INTO meeting_analysis(meeting_id, updated_at, revision)
            SELECT id, updated_at, 0 FROM meetings;
          """)
    }
    // Feature 009: the language a meeting's final transcript is decoded in, chosen on
    // the meeting; NULL means the Meeting language in Settings.
    migrator.registerMigration("meeting-language-v10") { db in
      // The values when v10 shipped, so every database reaches the same schema. Czech
      // was removed later; `meeting-language-en-sk-v12` clears stored Czech rows.
      let languages = "'automatic','slovak','czech','english'"
      try db.execute(
        sql: """
          ALTER TABLE meetings ADD COLUMN language TEXT
            CHECK(language IS NULL OR language IN (\(languages)));
          """)
    }
    // Feature 012: one context row per dictation, and the attempt table rebuilt
    // for protocol version 2. SQLite cannot widen a CHECK in place, so the table is
    // created, copied, dropped and renamed under GRDB's deferred foreign-key check.
    migrator.registerMigration("app-context-v11") { db in
      let outcomes = ContextOutcome.allCases.map { "'\($0.rawValue)'" }.joined(separator: ",")
      try db.execute(
        sql: """
          CREATE TABLE dictation_contexts (
            transcription_id TEXT NOT NULL PRIMARY KEY
              REFERENCES transcriptions(id) ON DELETE CASCADE,
            outcome TEXT NOT NULL CHECK(outcome IN (\(outcomes))),
            capture_ms INTEGER CHECK(capture_ms IS NULL OR capture_ms >= 0),
            app_bundle_id TEXT CHECK(app_bundle_id IS NULL
              OR length(cast(app_bundle_id AS blob)) BETWEEN 1 AND 255),
            snapshot_json TEXT CHECK(snapshot_json IS NULL
              OR length(cast(snapshot_json AS blob)) <= 8192),
            snapshot_hash TEXT CHECK(snapshot_hash IS NULL OR \(hex64("snapshot_hash"))),
            pre_spelling_text TEXT CHECK(pre_spelling_text IS NULL
              OR length(cast(pre_spelling_text AS blob)) <= 65536),
            spelling_changes_json TEXT CHECK(spelling_changes_json IS NULL
              OR length(cast(spelling_changes_json AS blob)) <= 32768),
            speller_version INTEGER CHECK(speller_version IS NULL OR speller_version >= 1),
            rewrite_note TEXT CHECK(rewrite_note IS NULL OR rewrite_note = 'server_unsupported'),
            CHECK((snapshot_json IS NULL) = (snapshot_hash IS NULL)),
            CHECK((pre_spelling_text IS NULL) = (spelling_changes_json IS NULL)),
            CHECK(outcome NOT IN ('used','timed_out') OR snapshot_json IS NOT NULL),
            CHECK(outcome != 'off' OR (snapshot_json IS NULL AND app_bundle_id IS NULL
              AND capture_ms IS NULL AND pre_spelling_text IS NULL))
          )
          """)
      let columns = try db.columns(in: "rewrite_attempts").map { "\"\($0.name)\"" }
        .joined(separator: ",")
      try createRewriteAttempts(
        db, named: "rewrite_attempts_v11", categories: RewriteFailureCategory.persisted,
        contextHash: true)
      try db.execute(
        sql: """
          INSERT INTO rewrite_attempts_v11 (\(columns)) SELECT \(columns) FROM rewrite_attempts;
          DROP TABLE rewrite_attempts;
          ALTER TABLE rewrite_attempts_v11 RENAME TO rewrite_attempts;
          CREATE UNIQUE INDEX rewrite_attempts_transcription_ordinal
            ON rewrite_attempts(transcription_id, ordinal);
          CREATE INDEX rewrite_attempts_state ON rewrite_attempts(state) WHERE state = 'pending';
          """)
    }
    // LocalFlow supports English and Slovak only. SQLite cannot narrow v10's CHECK in
    // place; a meeting that chose a removed language (Czech) falls back to NULL, the
    // Meeting language in Settings, and the app has no value that could write one.
    migrator.registerMigration("meeting-language-en-sk-v12") { db in
      let languages = MeetingLanguage.allCases.map { "'\($0.rawValue)'" }.joined(separator: ",")
      try db.execute(
        sql: """
          UPDATE meetings SET language = NULL
            WHERE language IS NOT NULL AND language NOT IN (\(languages));
          """)
    }
    // Every foreign-key child column gets an index whose leading column is that column.
    // Without one, deleting or re-keying a parent row makes SQLite scan the whole child
    // table (e.g. each deleted transcript segment scanned all of analysis_sources).
    // Partial indexes do not count: SQLite cannot use them for foreign-key lookups.
    migrator.registerMigration("foreign-key-indexes-v13") { db in
      let indexes: [(table: String, column: String)] = [
        ("analysis_items", "meeting_id"),
        ("analysis_items", "owner_known_speaker_id"),
        ("analysis_items", "owner_speaker_id"),
        ("analysis_items", "topic_id"),
        ("analysis_overlays", "item_id"),
        ("analysis_sources", "meeting_id"),
        ("analysis_sources", "segment_id"),
        ("analysis_summaries", "meeting_id"),
        ("analysis_topics", "meeting_id"),
        ("identification_runs", "diarization_run_id"),
        ("identity_assignments", "run_id"),
        ("identity_assignments", "second_known_speaker_id"),
        ("meeting_analysis", "accepted_run_id"),
        ("meeting_analysis", "current_run_id"),
        ("meeting_diarization", "accepted_run_id"),
        ("meeting_diarization", "current_run_id"),
        ("meeting_identification", "accepted_run_id"),
        ("meeting_identification", "current_run_id"),
        ("meeting_pauses", "meeting_id"),
        ("meeting_speakers", "merged_into"),
        ("meeting_speakers", "run_id"),
        ("speaker_assignments", "auto_speaker_id"),
        ("speaker_assignments", "manual_speaker_id"),
        ("speaker_corrections", "run_id"),
        ("transcript_live_gaps", "meeting_id"),
        ("transcriptions", "delivered_rewrite_attempt_id"),
      ]
      for index in indexes {
        try db.execute(
          sql:
            "CREATE INDEX \(index.table)_fk_\(index.column) ON \(index.table)(\(index.column))")
      }
    }
    // Feature 013: corrections the scorer only suggested, and suggestions the user
    // dismissed. Context sightings are counted from dictation_contexts, not stored.
    migrator.registerMigration("term-suggestions-v14") { db in
      try db.execute(
        sql: """
          CREATE TABLE term_suggestions (
            canonical TEXT NOT NULL CHECK(length(cast(canonical AS blob)) BETWEEN 1 AND 256),
            alias TEXT NOT NULL CHECK(length(cast(alias AS blob)) <= 256),
            sightings INTEGER NOT NULL CHECK(sightings >= 0),
            dismissed INTEGER NOT NULL CHECK(dismissed IN (0,1)),
            last_seen INTEGER NOT NULL,
            PRIMARY KEY(canonical, alias)
          ) WITHOUT ROWID
          """)
    }
    return migrator
  }

  /// The Feature 003 attempt table. `app-context-v11` recreates it with protocol
  /// version 2, `context_copied` and `context_hash`.
  private static func createRewriteAttempts(
    _ db: Database, named name: String, categories persisted: [RewriteFailureCategory],
    contextHash: Bool
  ) throws {
    let categories = persisted.map { "'\($0.rawValue)'" }.joined(separator: ",")
    let spanColumns = [
      "duration_ms", "first_byte_ms", "network_ms", "server_queue_ms",
      "backend_first_token_ms", "backend_ms", "request_bytes", "response_bytes",
    ]
    let identityColumns = ["server_name", "server_version", "backend_kind", "backend_model"]
    try db.create(table: name) { t in
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
      t.column("protocol_version", .integer).notNull()
        .check(sql: contextHash ? "protocol_version IN (1,2)" : "protocol_version = 1")
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
      if contextHash {
        t.column("context_hash", .text).check(
          sql: "context_hash IS NULL OR \(hex64("context_hash"))")
        t.check(sql: "(protocol_version = 2) = (context_hash IS NOT NULL)")
      }
    }
  }

  private static func hex64(_ column: String) -> String {
    "(length(\(column)) = 64 AND \(column) NOT GLOB '*[^0-9a-f]*')"
  }
}
