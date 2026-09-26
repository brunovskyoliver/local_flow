import Foundation
import GRDB

/// Feature 013. Corrections the scorer only suggested, the suggestions the user dismissed,
/// and the context terms of recent dictations. Shares the history database file.
actor TermSuggestionStore {
  static let maximumRows = 500
  /// Recent dictations whose context terms are counted.
  static let contextDictations = 1_000

  struct Correction: Equatable, Sendable {
    let canonical: String
    let alias: String
    let sightings: Int
  }
  struct Contents: Equatable, Sendable {
    var corrections: [Correction] = []
    /// `TermSuggestion.id` of every dismissed suggestion.
    var dismissed: Set<String> = []
    /// One list of distinct terms per dictation, newest first.
    var contextTerms: [[String]] = []
  }

  private let database: DatabasePool

  init(history: TranscriptionStore) { database = history.database }

  func recordCorrection(canonical: String, alias: String, now: Int64) throws {
    guard Self.valid(canonical), alias.isEmpty || Self.valid(alias) else { return }
    try database.write { db in
      try db.execute(
        sql: """
          INSERT INTO term_suggestions (canonical, alias, sightings, dismissed, last_seen)
          VALUES (?, ?, 1, 0, ?)
          ON CONFLICT(canonical, alias) DO UPDATE SET sightings=sightings+1, last_seen=excluded.last_seen
          """, arguments: [canonical, alias, now])
      try Self.prune(db)
    }
  }

  func dismiss(_ suggestion: TermSuggestion, now: Int64) throws {
    guard Self.valid(suggestion.canonical), suggestion.alias.isEmpty || Self.valid(suggestion.alias)
    else { return }
    try database.write { db in
      try db.execute(
        sql: """
          INSERT INTO term_suggestions (canonical, alias, sightings, dismissed, last_seen)
          VALUES (?, ?, 0, 1, ?)
          ON CONFLICT(canonical, alias) DO UPDATE SET dismissed=1, last_seen=excluded.last_seen
          """, arguments: [suggestion.canonical, suggestion.alias, now])
      try Self.prune(db)
    }
  }

  func contents() throws -> Contents {
    try database.read { db in
      var contents = Contents()
      for row in try Row.fetchAll(
        db, sql: "SELECT canonical, alias, sightings, dismissed FROM term_suggestions")
      {
        let correction = Correction(
          canonical: row["canonical"], alias: row["alias"], sightings: row["sightings"])
        if row["dismissed"] as Bool {
          contents.dismissed.insert(
            TermSuggestion.id(canonical: correction.canonical, alias: correction.alias))
        } else {
          contents.corrections.append(correction)
        }
      }
      let snapshots = try String.fetchAll(
        db,
        sql: """
          SELECT c.snapshot_json FROM dictation_contexts c
          JOIN transcriptions t ON t.id = c.transcription_id
          WHERE c.snapshot_json IS NOT NULL ORDER BY t.created_at DESC LIMIT ?
          """, arguments: [Self.contextDictations])
      let decoder = JSONDecoder()
      contents.contextTerms = snapshots.compactMap { json in
        // A damaged snapshot only loses its sightings.
        guard let snapshot = try? decoder.decode(AppContextSnapshot.self, from: Data(json.utf8))
        else { return nil }
        var seen = Set<String>()
        return snapshot.terms.map(\.text).filter { seen.insert($0).inserted }
      }
      return contents
    }
  }

  private static func valid(_ term: String) -> Bool {
    VocabularyValidation.termCode(term) == nil
  }

  /// Oldest rows go first once the table is full, dismissed or not.
  private static func prune(_ db: Database) throws {
    try db.execute(
      sql: """
        DELETE FROM term_suggestions WHERE (canonical, alias) IN (
          SELECT canonical, alias FROM term_suggestions ORDER BY last_seen DESC LIMIT -1 OFFSET ?)
        """, arguments: [maximumRows])
  }
}
