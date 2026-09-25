import GRDB
import XCTest

@testable import LocalFlow

/// Feature 012 storage: migration `app-context-v11`, the context row in the entry's
/// commit transaction, cascade deletion and the `rewrite_attempts` rebuild.
final class AppContextStoreTests: XCTestCase {
  private var urls: [URL] = []

  override func tearDown() {
    for url in urls { removeDatabase(at: url) }
    urls = []
  }

  private func makeURL() -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
      "localflow-context-\(UUID().uuidString).sqlite")
    urls.append(url)
    return url
  }

  private func makeStore() throws -> (TranscriptionStore, URL) {
    let url = makeURL()
    return (try TranscriptionStore(path: url.path), url)
  }

  private func usedRecord() -> DictationContextRecord {
    let snapshot = AppContextSnapshot.make(
      .init(
        appName: "Mail", appCategory: .email, fieldKind: .multiLine, windowTitle: "Re: Kováčik",
        beforeCursor: "Hi Miroslav Kováčik,"))
    let changes = [
      ContextSpellingChange(
        original: "Kovacik", replacement: "Kováčik", sourcePart: .beforeCursor, start: 6,
        length: 7, match: .exactFold)
    ]
    return DictationContextRecord(
      outcome: .used, captureMs: 12, appBundleID: "com.apple.mail",
      snapshotJSON: snapshot.canonicalString, preSpellingText: "Thanks Kovacik",
      spellingChangesJSON: String(decoding: try! JSONEncoder().encode(changes), as: UTF8.self),
      spellerVersion: ContextSpeller.version)
  }

  private func envelope(text: String = "Thanks Kováčik", context: DictationContextRecord?) throws
    -> TranscriptionEnvelope
  {
    TranscriptionEnvelope(
      entry: try TranscriptionEntry(
        id: UUID(), text: text, createdAtMilliseconds: 1, quality: .complete,
        stopReason: .keyRelease),
      detail: nil, context: context)
  }

  private func usageBytes(_ store: TranscriptionStore) throws -> Int {
    try store.database.read {
      try Int.fetchOne($0, sql: "SELECT payload_bytes FROM history_usage WHERE id=1") ?? -1
    }
  }

  // MARK: Schema

  func testContextTableShapeAndCascade() throws {
    let (store, _) = try makeStore()
    try store.database.read { db in
      XCTAssertTrue(try db.tableExists("dictation_contexts"))
      XCTAssertEqual(
        try db.columns(in: "dictation_contexts").map(\.name),
        [
          "transcription_id", "outcome", "capture_ms", "app_bundle_id", "snapshot_json",
          "snapshot_hash", "pre_spelling_text", "spelling_changes_json", "speller_version",
          "rewrite_note",
        ])
      XCTAssertEqual(try db.primaryKey("dictation_contexts").columns, ["transcription_id"])
      let key = try Row.fetchOne(db, sql: "PRAGMA foreign_key_list(dictation_contexts)")
      XCTAssertEqual(key?["table"], "transcriptions")
      XCTAssertEqual(key?["on_delete"], "CASCADE")
      XCTAssertTrue(try db.indexes(on: "dictation_contexts").allSatisfy(\.isUnique))
    }
  }

  func testContextChecksRejectEveryOutOfBoundsValue() async throws {
    let (store, _) = try makeStore()
    let saved = try await store.commit(
      reservation: try await store.reserve(), envelope: try envelope(context: nil))
    let id = saved.id.uuidString
    let hash = String(repeating: "a", count: 64)
    let bad: [(String, StatementArguments)] = [
      ("outcome", ["bogus", nil, nil, nil, nil, nil, nil, nil, nil]),
      ("capture_ms", ["off", -1, nil, nil, nil, nil, nil, nil, nil]),
      ("empty bundle", ["no_target", nil, "", nil, nil, nil, nil, nil, nil]),
      (
        "long bundle",
        ["no_target", nil, String(repeating: "b", count: 256), nil, nil, nil, nil, nil, nil]
      ),
      (
        "big snapshot",
        ["used", nil, nil, String(repeating: "x", count: 8_193), hash, nil, nil, nil, nil]
      ),
      ("used without snapshot", ["used", nil, nil, nil, nil, nil, nil, nil, nil]),
      ("timed out without snapshot", ["timed_out", nil, nil, nil, nil, nil, nil, nil, nil]),
      ("hash without json", ["no_target", nil, nil, nil, hash, nil, nil, nil, nil]),
      ("json without hash", ["used", nil, nil, "{}", nil, nil, nil, nil, nil]),
      (
        "uppercase hash",
        ["used", nil, nil, "{}", String(repeating: "A", count: 64), nil, nil, nil, nil]
      ),
      ("short hash", ["used", nil, nil, "{}", "abc", nil, nil, nil, nil]),
      ("pre without changes", ["used", nil, nil, "{}", hash, "text", nil, nil, nil]),
      ("changes without pre", ["used", nil, nil, "{}", hash, nil, "[]", nil, nil]),
      (
        "big pre",
        ["used", nil, nil, "{}", hash, String(repeating: "p", count: 65_537), "[]", nil, nil]
      ),
      (
        "big changes",
        ["used", nil, nil, "{}", hash, "p", String(repeating: "c", count: 32_769), nil, nil]
      ),
      ("speller 0", ["used", nil, nil, "{}", hash, "p", "[]", 0, nil]),
      ("note", ["used", nil, nil, "{}", hash, nil, nil, nil, "other"]),
      ("off with data", ["off", 3, nil, nil, nil, nil, nil, nil, nil]),
    ]
    for (label, values) in bad {
      do {
        try await store.database.write { db in
          try db.execute(
            sql: """
              INSERT INTO dictation_contexts (transcription_id,outcome,capture_ms,app_bundle_id,snapshot_json,snapshot_hash,pre_spelling_text,spelling_changes_json,speller_version,rewrite_note)
              VALUES (?,?,?,?,?,?,?,?,?,?)
              """, arguments: [id] + values)
        }
        XCTFail("accepted \(label)")
      } catch let error as DatabaseError {
        XCTAssertEqual(error.resultCode, .SQLITE_CONSTRAINT, label)
      }
    }
    try await store.database.write { db in
      try db.execute(
        sql:
          "INSERT INTO dictation_contexts (transcription_id,outcome,snapshot_json,snapshot_hash,rewrite_note) VALUES (?,'used','{}',?,'server_unsupported')",
        arguments: [id, hash])
    }
  }

  func testRewriteAttemptChecksAcceptVersionTwoWithAHashOnly() async throws {
    let (store, _) = try makeStore()
    let saved = try await store.commit(
      reservation: try await store.reserve(), envelope: try envelope(context: nil))
    let hash = String(repeating: "b", count: 64)
    func insert(_ ordinal: Int, version: Int, hash: String?, category: String? = nil) async throws {
      try await store.database.write { db in
        try db.execute(
          sql: """
            INSERT INTO rewrite_attempts (id,transcription_id,ordinal,mode,state,input_text,input_hash,started_at,protocol_version,endpoint_origin,failure_category,context_hash)
            VALUES (?,?,?,'clean',?,'text',?,1,?,'http://127.0.0.1:8080',?,?)
            """,
          arguments: [
            UUID().uuidString, saved.id.uuidString, ordinal,
            category == nil ? "cancelled" : "failed",
            String(repeating: "c", count: 64), version, category, hash,
          ])
      }
    }
    try await insert(1, version: 1, hash: nil)
    try await insert(2, version: 2, hash: hash)
    try await insert(3, version: 2, hash: hash, category: "context_copied")
    for (label, version, value) in [
      ("v2 without hash", 2, nil), ("v1 with hash", 1, hash), ("v3", 3, hash),
      ("non-hex hash", 2, String(repeating: "z", count: 64)),
    ] as [(String, Int, String?)] {
      do {
        try await insert(9, version: version, hash: value)
        XCTFail("accepted \(label)")
      } catch let error as DatabaseError {
        XCTAssertEqual(error.resultCode, .SQLITE_CONSTRAINT, label)
      }
    }
    let attempts = try await store.attempts(for: saved.id)
    XCTAssertEqual(attempts.map(\.contextHash), [nil, hash, hash])
    XCTAssertEqual(attempts.last?.failureCategory, .contextCopied)
  }

  func testUpgradeCopiesAttemptsUnchangedAndLegacyEntriesReadNotRecorded() async throws {
    let url = makeURL()
    let queue = try DatabaseQueue(path: url.path)
    try HistoryMigrations.migrator().migrate(queue, upTo: "meeting-language-v10")
    let entryID = UUID().uuidString
    let attemptIDs = [UUID().uuidString, UUID().uuidString]
    try await queue.write { db in
      try db.execute(
        sql: """
          INSERT INTO transcriptions (id,text,created_at,delivery_state,recovery_state,quality,stop_reason,revision)
          VALUES (?,'legacy text',5,'confirmed','resolved','complete','key_release',2)
          """, arguments: [entryID])
      for (index, id) in attemptIDs.enumerated() {
        try db.execute(
          sql: """
            INSERT INTO rewrite_attempts (id,transcription_id,ordinal,mode,state,input_text,input_hash,output_text,output_hash,started_at,protocol_version,endpoint_origin,prompt_version)
            VALUES (?,?,?,'clean','succeeded','legacy text',?,'Legacy text.',?,?,1,'http://127.0.0.1:8080',1)
            """,
          arguments: [
            id, entryID, index + 1, String(repeating: "1", count: 64),
            String(repeating: "2", count: 64), 10 + index,
          ])
      }
      try db.execute(
        sql:
          "UPDATE transcriptions SET rewrite_state='succeeded', delivered_source='rewrite', delivered_rewrite_attempt_id=? WHERE id=?",
        arguments: [attemptIDs[1], entryID])
      try db.execute(sql: "UPDATE history_usage SET row_count=1 WHERE id=1")
    }
    let before = try await queue.read { db in
      try Row.fetchAll(db, sql: "SELECT * FROM rewrite_attempts ORDER BY ordinal").map { row in
        Dictionary(uniqueKeysWithValues: row.columnNames.map { ($0, row[$0] as DatabaseValue) })
      }
    }
    try queue.close()

    let store = try TranscriptionStore(path: url.path)
    let id = try XCTUnwrap(UUID(uuidString: entryID))
    try await store.database.read { db in
      let after = try Row.fetchAll(db, sql: "SELECT * FROM rewrite_attempts ORDER BY ordinal")
      XCTAssertEqual(after.count, 2)
      for (old, new) in zip(before, after) {
        for (column, value) in old {
          XCTAssertEqual(value, new[column] as DatabaseValue, column)
        }
        XCTAssertNil(new["context_hash"] as String?)
      }
      let delivered: String? = try String.fetchOne(
        db, sql: "SELECT delivered_rewrite_attempt_id FROM transcriptions WHERE id=?",
        arguments: [entryID])
      XCTAssertEqual(delivered, attemptIDs[1])
      XCTAssertTrue(try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").isEmpty)
      let indexes = try db.indexes(on: "rewrite_attempts")
      XCTAssertTrue(
        indexes.contains { $0.isUnique && $0.columns == ["transcription_id", "ordinal"] })
      XCTAssertTrue(indexes.contains { $0.name == "rewrite_attempts_state" })
    }
    let context = try await store.context(for: id)
    XCTAssertNil(context, "legacy entries have no row and read as not recorded")
    let envelope = try await store.selectedEnvelope(id)
    XCTAssertNil(envelope.context)
    // Deleting the entry still cascades its attempts after the rebuild.
    try await store.deleteConfirmed(id: id, revision: 2)
    let attempts = try await store.attempts(for: id)
    XCTAssertTrue(attempts.isEmpty)
  }

  // MARK: Commit and deletion

  func testContextRowCommitsWithTheEntryAndSurvivesReopen() async throws {
    let (store, url) = try makeStore()
    let record = usedRecord()
    let item = try envelope(context: record)
    let saved = try await store.commit(reservation: try await store.reserve(), envelope: item)
    let stored = try await store.context(for: saved.id)
    XCTAssertEqual(stored, record)
    XCTAssertEqual(stored?.snapshot?.windowTitle, "Re: Kováčik")
    XCTAssertEqual(stored?.spellingChanges.first?.replacement, "Kováčik")
    XCTAssertEqual(try usageBytes(store), item.entry.text.utf8.count + record.payloadBytes)
    try await store.recordRewriteNote(DictationContextRecord.serverUnsupported, for: saved.id)
    let reopened = try TranscriptionStore(path: url.path)
    let again = try await reopened.context(for: saved.id)
    XCTAssertEqual(again?.rewriteNote, "server_unsupported")
    XCTAssertEqual(again?.snapshotHash, record.snapshotHash)
    XCTAssertEqual(try usageBytes(reopened), item.entry.text.utf8.count + record.payloadBytes)
    let selected = try await reopened.selectedEnvelope(saved.id)
    XCTAssertEqual(selected.context?.outcome, .used)
  }

  func testOffRowCarriesNoOtherData() async throws {
    let (store, _) = try makeStore()
    let saved = try await store.commit(
      reservation: try await store.reserve(), envelope: try envelope(context: .off))
    let stored = try await store.context(for: saved.id)
    XCTAssertEqual(stored, DictationContextRecord(outcome: .off))
  }

  func testFailingContextWriteFailsTheWholeCommitAndTheSameRetrySucceeds() async throws {
    let (store, url) = try makeStore()
    let database = try DatabaseQueue(path: url.path)
    try await database.write {
      try $0.execute(
        sql:
          "CREATE TRIGGER fail_context BEFORE INSERT ON dictation_contexts BEGIN SELECT RAISE(ABORT, 'injected'); END"
      )
    }
    let item = try envelope(context: usedRecord())
    let reservation = try await store.reserve()
    do {
      _ = try await store.commit(reservation: reservation, envelope: item)
      XCTFail("a context failure must roll back the entry")
    } catch is DatabaseError {}
    let parent = try await store.get(item.entry.id)
    XCTAssertNil(parent)
    XCTAssertEqual(try usageBytes(store), 0)
    try await database.write { try $0.execute(sql: "DROP TRIGGER fail_context") }
    _ = try await store.commit(reservation: reservation, envelope: item)
    let stored = try await store.context(for: item.entry.id)
    XCTAssertEqual(stored, item.context)
  }

  func testInvalidContextIsRejectedBeforeAnyWrite() async throws {
    let (store, _) = try makeStore()
    var record = usedRecord()
    record.snapshotJSON = nil
    do {
      _ = try await store.commit(
        reservation: try await store.reserve(), envelope: try envelope(context: record))
      XCTFail("used without a snapshot must be rejected")
    } catch let error as TranscriptionStore.Error {
      XCTAssertEqual(error, .invalidContext)
    }
    let recent = try await store.recent()
    XCTAssertTrue(recent.isEmpty)
  }

  /// Story 3.5 (T029): deleting a dictation removes its context row and snapshot.
  func testDeletingTheEntryDeletesItsContext() async throws {
    let (store, _) = try makeStore()
    let saved = try await store.commit(
      reservation: try await store.reserve(), envelope: try envelope(context: usedRecord()))
    try await store.deleteConfirmed(id: saved.id, revision: saved.revision)
    let context = try await store.context(for: saved.id)
    XCTAssertNil(context)
    let rows = try await store.database.read {
      try Int.fetchOne($0, sql: "SELECT count(*) FROM dictation_contexts") ?? -1
    }
    XCTAssertEqual(rows, 0)
    XCTAssertEqual(try usageBytes(store), 0)
  }

  // MARK: Protocol v2 attempts (Story 2)

  func testBeginRecordsProtocolVersionTwoAndTheSnapshotHash() async throws {
    let (store, _) = try makeStore()
    let record = usedRecord()
    let saved = try await store.commit(
      reservation: try await store.reserve(), envelope: try envelope(context: record))
    let hash = try XCTUnwrap(record.snapshotHash)
    let v2 = try await store.begin(
      RewriteAdmission(
        transcriptionID: saved.id, mode: .clean, inputText: saved.text,
        endpointOrigin: "http://127.0.0.1:8080", insecureOverride: false, contextHash: hash))
    XCTAssertEqual(v2.protocolVersion, 2)
    XCTAssertEqual(v2.contextHash, hash)
    let failed = try await store.recordFailure(id: v2.id, category: .contextCopied, spans: .none)
    XCTAssertEqual(failed.failureCategory, .contextCopied)
    XCTAssertEqual(failed.contextHash, hash)
    let v1 = try await store.begin(
      RewriteAdmission(
        transcriptionID: saved.id, mode: .clean, inputText: saved.text,
        endpointOrigin: "http://127.0.0.1:8080", insecureOverride: false))
    XCTAssertEqual(v1.protocolVersion, 1)
    XCTAssertNil(v1.contextHash)
    let rows = try await store.attempts(for: saved.id)
    XCTAssertEqual(rows.map(\.protocolVersion), [2, 1])
  }
}
