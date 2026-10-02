import Foundation
import GRDB
import LocalFlowCore

/// Phone dictations: a shared `transcriptions` row plus one `phone_dictations` row,
/// always written together (data-model.md §1). The phone writes only `not_inserted` and
/// `confirmed`, never `attempting`, so the shared launch repair never touches its rows.
actor PhoneDictationStore {
  enum Source: String, Sendable { case keyboard, app, control }
  enum Delivery: String, Sendable {
    case inserted, offered
    case savedOnly = "saved_only"
    /// A `control` dictation put on the clipboard (Feature 017).
    case copied

    var deliveryState: TranscriptionEntry.DeliveryState {
      self == .inserted ? .confirmed : .notInserted
    }
  }
  enum EndDetail: String, Sendable {
    case limitReached = "limit_reached"
    case interrupted
    case recoveredAfterTermination = "recovered_after_termination"
  }

  struct Dictation: Sendable {
    var id: UUID
    var text: String
    var createdAt: Date
    var source: Source
    var durationMilliseconds: Int
    var quality: TranscriptionEntry.Quality
    var stopReason: TranscriptionEntry.StopReason
    var endDetail: EndDetail?
    var sessionID: UUID?
    var detail: TranscriptionQualityDetail?
  }

  struct Row: Sendable, Identifiable {
    let entry: TranscriptionEntry
    let source: Source
    let durationMilliseconds: Int
    let delivery: Delivery
    let endDetail: EndDetail?
    var id: UUID { entry.id }
  }

  enum Error: Swift.Error { case emptyText }

  let history: TranscriptionStore

  init(history: TranscriptionStore) {
    self.history = history
  }

  /// Saves both rows in one transaction with `delivery = saved_only`. Empty text is
  /// not saved. A recovered orphan is marked for review.
  @discardableResult
  func save(_ dictation: Dictation) async throws -> TranscriptionEntry {
    guard !dictation.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw Error.emptyText
    }
    let entry = try TranscriptionEntry(
      id: dictation.id, text: dictation.text,
      createdAtMilliseconds: Handoff.milliseconds(dictation.createdAt),
      quality: dictation.quality, stopReason: dictation.stopReason)
    let reservation = try await history.reserve()
    let recovery = dictation.endDetail == .recoveredAfterTermination ? "needs_review" : "resolved"
    let phone: StatementArguments = [
      dictation.id.uuidString, dictation.source.rawValue,
      min(max(dictation.durationMilliseconds, 0), 300_000), Delivery.savedOnly.rawValue,
      dictation.endDetail?.rawValue, dictation.sessionID?.uuidString,
    ]
    do {
      return try await history.commit(
        reservation: reservation,
        envelope: TranscriptionEnvelope(entry: entry, detail: dictation.detail)
      ) { db in
        try db.execute(
          sql:
            "UPDATE transcriptions SET delivery_state='not_inserted', recovery_state=? WHERE id=?",
          arguments: [recovery, dictation.id.uuidString])
        try db.execute(
          sql: """
            INSERT INTO phone_dictations (transcription_id,source,duration_ms,delivery,end_detail,session_id)
            VALUES (?,?,?,?,?,?)
            """, arguments: phone)
      }
    } catch {
      await history.releaseReservation(reservation)
      throw error
    }
  }

  /// Sets the phone delivery and the shared delivery state together.
  func markDelivery(dictationID: UUID, _ delivery: Delivery) async throws {
    try await history.database.write { db in
      try db.execute(
        sql: "UPDATE phone_dictations SET delivery=? WHERE transcription_id=?",
        arguments: [delivery.rawValue, dictationID.uuidString])
      guard db.changesCount == 1 else { return }
      try db.execute(
        sql: "UPDATE transcriptions SET delivery_state=?, revision=revision+1 WHERE id=?",
        arguments: [delivery.deliveryState.rawValue, dictationID.uuidString])
    }
  }

  /// A `control` dictation whose clipboard write took. The shared state stays
  /// `not_inserted`. Any other source is left alone: Copy works for every dictation, but
  /// only a control row records it.
  func markCopied(dictationID: UUID) async throws {
    try await history.database.write { db in
      try db.execute(
        sql:
          "UPDATE phone_dictations SET delivery='copied' WHERE transcription_id=? AND source='control'",
        arguments: [dictationID.uuidString])
      guard db.changesCount == 1 else { return }
      try db.execute(
        sql:
          "UPDATE transcriptions SET delivery_state='not_inserted', revision=revision+1 WHERE id=?",
        arguments: [dictationID.uuidString])
    }
  }

  /// The newest dictation, for Copy after a relaunch emptied `lastResult`.
  func newestTranscript() async throws -> (id: UUID, text: String)? {
    try await list(limit: 1).first.map { ($0.id, $0.entry.text) }
  }

  /// Deletes through the shared store, which keeps the usage counters; the phone row
  /// goes with the cascade.
  func delete(id: UUID) async throws {
    guard let entry = try await history.get(id) else { return }
    try await history.deleteConfirmed(id: id, revision: entry.revision)
  }

  func list(limit: Int = 200) async throws -> [Row] {
    let entries = try await history.recent(limit: limit)
    let phone = try await history.database.read { db in
      try PhoneColumns.fetchAll(
        db,
        sql: "SELECT transcription_id,source,duration_ms,delivery,end_detail FROM phone_dictations")
    }
    let byID = Dictionary(uniqueKeysWithValues: phone.map { ($0.id, $0) })
    return entries.compactMap { entry in
      guard let row = byID[entry.id.uuidString], let source = Source(rawValue: row.source),
        let delivery = Delivery(rawValue: row.delivery)
      else { return nil }
      return Row(
        entry: entry, source: source, durationMilliseconds: row.duration,
        delivery: delivery, endDetail: row.endDetail.flatMap(EndDetail.init(rawValue:)))
    }
  }

  private struct PhoneColumns: FetchableRecord {
    let id: String
    let source: String
    let duration: Int
    let delivery: String
    let endDetail: String?

    init(row: GRDB.Row) {
      id = row[0]
      source = row[1]
      duration = row[2]
      delivery = row[3]
      endDetail = row[4]
    }
  }
}
