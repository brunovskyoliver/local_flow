import GRDB
import LocalFlowCore

/// The shared migrator with the phone's one table after it (data-model.md §1). Only the
/// phone registers the `phone-dictations-*` migrations, so the Mac database never gains
/// them. GRDB applies any registered migration not yet applied, so a later shared migration
/// registered before these still runs on a phone that already has them (research R5).
enum PhoneMigrations {
  static let identifier = "phone-dictations-v1"
  /// Feature 017: `control` and `copied`. SQLite cannot change a `CHECK` in place, so the
  /// table is rebuilt; GRDB runs each migration in one transaction. v1 created no indexes.
  static let identifierV2 = "phone-dictations-v2"
  /// Feature 020: `phone_meeting_uploads`, the phone's side of each server handoff
  /// (specs/020-ios-meeting-recording/data-model.md).
  static let identifierMeetings = "phone-meetings-v1"
  /// Feature 020 US5: `phone_meeting_server_deletes`, server copies of meetings deleted on
  /// the phone, sent with the next connection. No foreign key: the meeting is already gone.
  static let identifierMeetingsV2 = "phone-meetings-v2"

  static func migrator(shared: DatabaseMigrator = HistoryMigrations.migrator()) -> DatabaseMigrator
  {
    var migrator = shared
    migrator.registerMigration(identifier) { db in
      try db.execute(
        sql: """
          CREATE TABLE phone_dictations(
            transcription_id TEXT PRIMARY KEY REFERENCES transcriptions(id) ON DELETE CASCADE,
            source TEXT NOT NULL CHECK(source IN ('keyboard','app')),
            duration_ms INTEGER NOT NULL CHECK(duration_ms BETWEEN 0 AND 300000),
            delivery TEXT NOT NULL CHECK(delivery IN ('inserted','offered','saved_only')),
            end_detail TEXT CHECK(end_detail IS NULL OR end_detail IN ('limit_reached','interrupted','recovered_after_termination')),
            session_id TEXT,
            CHECK(source <> 'app' OR delivery = 'saved_only'))
          """)
    }
    migrator.registerMigration(identifierV2) { db in
      try db.execute(
        sql: """
          CREATE TABLE phone_dictations_new(
            transcription_id TEXT PRIMARY KEY REFERENCES transcriptions(id) ON DELETE CASCADE,
            source TEXT NOT NULL CHECK(source IN ('keyboard','app','control')),
            duration_ms INTEGER NOT NULL CHECK(duration_ms BETWEEN 0 AND 300000),
            delivery TEXT NOT NULL CHECK(delivery IN ('inserted','offered','saved_only','copied')),
            end_detail TEXT CHECK(end_detail IS NULL OR end_detail IN ('limit_reached','interrupted','recovered_after_termination')),
            session_id TEXT,
            CHECK(source <> 'app' OR delivery = 'saved_only'),
            CHECK(source <> 'control' OR delivery IN ('copied','saved_only')));
          INSERT INTO phone_dictations_new
            SELECT transcription_id,source,duration_ms,delivery,end_detail,session_id
            FROM phone_dictations;
          DROP TABLE phone_dictations;
          ALTER TABLE phone_dictations_new RENAME TO phone_dictations;
          """)
    }
    migrator.registerMigration(identifierMeetings) { db in
      try db.execute(
        sql: """
          CREATE TABLE phone_meeting_uploads(
            meeting_id TEXT PRIMARY KEY NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
            stage TEXT NOT NULL CHECK(stage IN ('waiting','uploading','processing','merging','summarizing','ready','failed')),
            detail TEXT CHECK(detail IS NULL OR length(CAST(detail AS BLOB))<=256),
            bundle_uploaded INTEGER NOT NULL DEFAULT 0 CHECK(bundle_uploaded IN (0,1)),
            confirmed_segments TEXT NOT NULL DEFAULT '',
            transcribed_ms INTEGER CHECK(transcribed_ms IS NULL OR transcribed_ms>=0),
            server_progress INTEGER CHECK(server_progress IS NULL OR server_progress BETWEEN 0 AND 100),
            copy_to_mac INTEGER NOT NULL DEFAULT 1 CHECK(copy_to_mac IN (0,1)),
            mac_copy TEXT NOT NULL DEFAULT 'none' CHECK(mac_copy IN ('none','waiting','delivered','expired')),
            released_at INTEGER,
            attempts INTEGER NOT NULL DEFAULT 0 CHECK(attempts>=0),
            updated_at INTEGER NOT NULL);
          CREATE INDEX phone_meeting_uploads_stage ON phone_meeting_uploads(stage);
          """)
    }
    migrator.registerMigration(identifierMeetingsV2) { db in
      try db.execute(
        sql: """
          CREATE TABLE phone_meeting_server_deletes(
            meeting_id TEXT PRIMARY KEY NOT NULL,
            queued_at INTEGER NOT NULL)
          """)
    }
    return migrator
  }
}
