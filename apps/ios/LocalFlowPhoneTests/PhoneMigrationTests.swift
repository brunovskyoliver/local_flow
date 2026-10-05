import GRDB
import XCTest

@testable import LocalFlow
@testable import LocalFlowCore

@MainActor
final class PhoneMigrationTests: XCTestCase {
  private var harness: PhoneHarness!

  override func setUp() async throws { harness = try PhoneHarness() }
  override func tearDown() async throws { harness = nil }

  private func applied(_ database: DatabasePool) throws -> [String] {
    try database.read { try String.fetchAll($0, sql: "SELECT identifier FROM grdb_migrations") }
  }

  private func dictation(
    source: PhoneDictationStore.Source = .keyboard, text: String = "Saved text."
  ) -> PhoneDictationStore.Dictation {
    .init(
      id: UUID(), text: text, createdAt: Date(), source: source, durationMilliseconds: 1_500,
      quality: .complete, stopReason: .keyRelease, endDetail: nil, sessionID: UUID(), detail: nil)
  }

  func testFreshDatabaseHasTheSharedMigrationsThenThePhoneTable() throws {
    let shared = HistoryMigrations.migrator().migrations
    XCTAssertEqual(shared.count, 19)
    let phone = [PhoneMigrations.identifier, PhoneMigrations.identifierV2]
    XCTAssertEqual(Set(try applied(harness.history.database)), Set(shared + phone))
    // Frozen: the list ends with the phone's two migrations, in order.
    XCTAssertEqual(PhoneMigrations.migrator().migrations, shared + phone)
    XCTAssertEqual(phone, ["phone-dictations-v1", "phone-dictations-v2"])
  }

  func testV2KeepsEveryV1RowAndValue() async throws {
    let path = harness.root.appendingPathComponent("v1.sqlite").path
    let store = try TranscriptionStore(path: path)
    try PhoneMigrations.migrator().migrate(store.database, upTo: PhoneMigrations.identifier)
    let dictations = PhoneDictationStore(history: store)
    let keyboard = try await dictations.save(dictation())
    _ = try await dictations.save(dictation(source: .app))
    try await dictations.markDelivery(dictationID: keyboard.id, .inserted)
    let select = "SELECT * FROM phone_dictations ORDER BY transcription_id"
    let before = try await store.database.read {
      try Row.fetchAll($0, sql: select).map(\.description)
    }
    try PhoneMigrations.migrator().migrate(store.database)
    let after = try await store.database.read {
      try Row.fetchAll($0, sql: select).map(\.description)
    }
    XCTAssertEqual(before.count, 2)
    XCTAssertEqual(after, before)
    XCTAssertTrue(try applied(store.database).contains(PhoneMigrations.identifierV2))
  }

  func testV2AcceptsControlDictationsOnlyAsCopiedOrSavedOnly() async throws {
    let saved = try await harness.dictations.save(dictation(source: .control))
    let id = saved.id.uuidString
    let database = harness.history.database
    try await database.write {
      try $0.execute(
        sql: "UPDATE phone_dictations SET delivery = 'copied' WHERE transcription_id = ?",
        arguments: [id])
    }
    for delivery in ["inserted", "offered"] {
      do {
        try await database.write {
          try $0.execute(
            sql: "UPDATE phone_dictations SET delivery = ? WHERE transcription_id = ?",
            arguments: [delivery, id])
        }
        XCTFail("control accepted \(delivery)")
      } catch {}
    }
    // `app` still requires `saved_only`, `copied` included.
    let note = try await harness.dictations.save(dictation(source: .app))
    do {
      try await database.write {
        try $0.execute(
          sql: "UPDATE phone_dictations SET delivery = 'copied' WHERE transcription_id = ?",
          arguments: [note.id.uuidString])
      }
      XCTFail("app accepted copied")
    } catch {}
  }

  func testMarkCopiedAndNewestTranscript() async throws {
    let older = try await harness.dictations.save(dictation(text: "Older."))
    let newer = try await harness.dictations.save(
      .init(
        id: UUID(), text: "Newer.", createdAt: Date().addingTimeInterval(5), source: .control,
        durationMilliseconds: 900, quality: .complete, stopReason: .keyRelease, endDetail: nil,
        sessionID: nil, detail: nil))
    try await harness.dictations.markCopied(dictationID: newer.id)
    let row = try XCTUnwrap(try harness.row(newer.id))
    XCTAssertEqual(row["delivery"] as String?, "copied")
    XCTAssertEqual(row["delivery_state"] as String?, "not_inserted")
    let newest = try await harness.dictations.newestTranscript()
    XCTAssertEqual(newest?.id, newer.id)
    XCTAssertEqual(newest?.text, "Newer.")
    XCTAssertNotEqual(newest?.id, older.id)
  }

  func testLaterSharedMigrationStillAppliesAfterThePhoneOne() throws {
    var shared = HistoryMigrations.migrator()
    shared.registerMigration("future-shared-v18") { db in
      try db.execute(sql: "CREATE TABLE future_shared(id INTEGER PRIMARY KEY)")
    }
    try PhoneMigrations.migrator(shared: shared).migrate(harness.history.database)
    XCTAssertTrue(try applied(harness.history.database).contains("future-shared-v18"))
    // The Mac's migrator opening the same file tolerates the phone's extra identifier.
    try HistoryMigrations.migrator().migrate(harness.history.database)
  }

  func testChecksRejectOutOfRangeValues() async throws {
    let saved = try await harness.dictations.save(dictation())
    let id = saved.id.uuidString
    let database = harness.history.database
    for sql in [
      "UPDATE phone_dictations SET duration_ms = 300001 WHERE transcription_id = ?",
      "UPDATE phone_dictations SET delivery = 'bogus' WHERE transcription_id = ?",
      "UPDATE phone_dictations SET end_detail = 'bogus' WHERE transcription_id = ?",
      "UPDATE phone_dictations SET source = 'app', delivery = 'inserted' WHERE transcription_id = ?",
    ] {
      do {
        try await database.write { try $0.execute(sql: sql, arguments: [id]) }
        XCTFail(sql)
      } catch {}
    }
  }

  func testAppNotesAreSavedOnly() async throws {
    let saved = try await harness.dictations.save(dictation(source: .app))
    let row = try XCTUnwrap(try harness.row(saved.id))
    XCTAssertEqual(row["delivery"] as String?, "saved_only")
    XCTAssertEqual(row["source"] as String?, "app")
  }

  func testDeletingATranscriptionRemovesItsPhoneRow() async throws {
    let saved = try await harness.dictations.save(dictation())
    try await harness.dictations.delete(id: saved.id)
    let phoneRows = try await harness.history.database.read {
      try Int.fetchOne($0, sql: "SELECT count(*) FROM phone_dictations") ?? -1
    }
    XCTAssertEqual(phoneRows, 0)
    XCTAssertEqual(try harness.rowCount(), 0)
  }

  func testMarkDeliveryWritesBothColumns() async throws {
    let saved = try await harness.dictations.save(dictation())
    try await harness.dictations.markDelivery(dictationID: saved.id, .inserted)
    var row = try XCTUnwrap(try harness.row(saved.id))
    XCTAssertEqual(row["delivery"] as String?, "inserted")
    XCTAssertEqual(row["delivery_state"] as String?, "confirmed")
    try await harness.dictations.markDelivery(dictationID: saved.id, .offered)
    row = try XCTUnwrap(try harness.row(saved.id))
    XCTAssertEqual(row["delivery"] as String?, "offered")
    XCTAssertEqual(row["delivery_state"] as String?, "not_inserted")
  }

  func testUnacknowledgedKeyboardRowSurvivesTheLaunchRepair() async throws {
    let saved = try await harness.dictations.save(dictation())
    let path = harness.root.appendingPathComponent("history.sqlite").path
    let reopened = try TranscriptionStore(path: path)
    let states = try await reopened.database.read { db in
      try Row.fetchOne(
        db, sql: "SELECT delivery_state, recovery_state FROM transcriptions WHERE id = ?",
        arguments: [saved.id.uuidString]
      ).map { [$0["delivery_state"] as String?, $0["recovery_state"] as String?] }
    }
    XCTAssertEqual(states, ["not_inserted", "resolved"])
  }

  func testEmptyTextIsNotSaved() async throws {
    do {
      try await harness.dictations.save(dictation(text: "  \n"))
      XCTFail("empty text saved")
    } catch {}
    XCTAssertEqual(try harness.rowCount(), 0)
  }
}
