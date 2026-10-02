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
    return migrator
  }
}
