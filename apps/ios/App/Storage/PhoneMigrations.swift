import GRDB
import LocalFlowCore

/// The shared migrator with the phone's one table after it (data-model.md §1). Only the
/// phone registers `phone-dictations-v1`, so the Mac database never gains it. GRDB applies
/// any registered migration not yet applied, so a later shared migration registered
/// before this one still runs on a phone that already has it (research R5).
enum PhoneMigrations {
  static let identifier = "phone-dictations-v1"

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
    return migrator
  }
}
