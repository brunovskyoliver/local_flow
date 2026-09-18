import Foundation
import GRDB
import XCTest

@testable import LocalFlow

final class VocabularyStoreTests: XCTestCase {
  private var directories: [URL] = []

  override func tearDown() {
    for directory in directories { try? FileManager.default.removeItem(at: directory) }
    directories.removeAll()
  }

  private func makeHistory(path: String? = nil) throws -> TranscriptionStore {
    let file: String
    if let path {
      file = path
    } else {
      let directory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("LocalFlowVocabulary-\(UUID().uuidString)", isDirectory: true)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      directories.append(directory)
      file = directory.appendingPathComponent("history.sqlite").path
    }
    return try TranscriptionStore(path: file)
  }

  private func code(_ body: () async throws -> Void) async -> VocabularyEditError? {
    do {
      try await body()
      return nil
    } catch {
      return error as? VocabularyEditError
    }
  }

  func testInitialStateIsExplicitEmptyIdentity() async throws {
    let store = VocabularyStore(history: try makeHistory())
    let contents = try await store.contents()
    XCTAssertEqual(contents.state.revision, 0)
    XCTAssertEqual(contents.state.contentHash, TranscriptionQualityDetail.emptyVocabularyHash)
    XCTAssertEqual(contents.state.payloadBytes, 0)
    XCTAssertTrue(contents.entries.isEmpty)
    let snapshot = try await store.snapshot()
    XCTAssertEqual(snapshot, .empty)
  }

  func testTermValidationCodesAndFields() async throws {
    let store = VocabularyStore(history: try makeHistory())
    let cases: [(String, VocabularyEditError.Code)] = [
      ("", .empty), ("a\nb", .multiline), ("a\rb", .multiline), ("a\u{0001}b", .control),
      ("a\u{200B}b", .control), (" a", .edgeWhitespace), ("a ", .edgeWhitespace),
      ("a  b", .spacing), ("a\tb", .control),
      ("a\u{00A0}b", .spacing), (String(repeating: "é", count: 129), .tooManyBytes),
      (String(repeating: "a", count: 65), .tooManyScalars),
      ("c\u{030C}au", .notCanonicalForm), ("a , b", .unstableFormatting),
    ]
    for (term, expected) in cases {
      let canonical = await code { try await store.save(VocabularyEntry(canonical: term)) }
      XCTAssertEqual(canonical, VocabularyEditError(field: .canonical, code: expected), term)
      if expected != .unstableFormatting {
        let alias = await code {
          try await store.save(VocabularyEntry(canonical: "ok", aliases: ["fine", term]))
        }
        XCTAssertEqual(alias, VocabularyEditError(field: .alias(1), code: expected), term)
      }
    }
    // Aliases need not be formatting-stable; the canonical target must be.
    try await store.save(VocabularyEntry(canonical: "ok", aliases: ["a , b"]))
    let state = try await store.contents().state
    XCTAssertEqual(state.revision, 0 + 1)
    let invalidID = await code {
      try await store.save(VocabularyEntry(id: "", canonical: "x"))
    }
    XCTAssertEqual(invalidID?.code, .invalidID)
  }

  func testExactLimitsAndOneOver() async throws {
    let store = VocabularyStore(history: try makeHistory())
    // 64 four-byte scalars is exactly 256 bytes; the byte cap cannot exceed the scalar cap.
    let exactBytes = String(repeating: "😀", count: 64)
    let exactScalars = String(repeating: "a", count: 64)
    try await store.save(VocabularyEntry(canonical: exactBytes, aliases: [exactScalars]))
    let eightAliases = (0..<8).map { "alias \($0)" }
    try await store.save(VocabularyEntry(canonical: "eight", aliases: eightAliases))
    let nine = await code {
      try await store.save(VocabularyEntry(canonical: "nine", aliases: eightAliases + ["alias 8"]))
    }
    XCTAssertEqual(nine, VocabularyEditError(field: .aliases, code: .tooManyAliases))
    let observed1 = try await store.contents().entries.count
    XCTAssertEqual(observed1, 2)
  }

  func testEntryCountAndPayloadCapacityRejectWithoutEviction() async throws {
    let store = VocabularyStore(history: try makeHistory())
    for index in 0..<510 {
      try await store.save(VocabularyEntry(id: "small-\(index)", canonical: "small \(index)"))
    }
    // Two large entries approach the payload ceiling before the row ceiling.
    let big = String(repeating: "😀", count: 60)
    let bigAliases = (0..<8).map { "\(big)\($0)" }
    try await store.save(VocabularyEntry(id: "big-0", canonical: "\(big)x", aliases: bigAliases))
    var contents = try await store.contents()
    XCTAssertEqual(contents.entries.count, 511)
    XCTAssertLessThanOrEqual(contents.state.payloadBytes, VocabularyStore.maximumPayloadBytes)
    try await store.save(VocabularyEntry(id: "small-511", canonical: "small 511"))
    contents = try await store.contents()
    XCTAssertEqual(contents.entries.count, 512)
    let overCount = await code {
      try await store.save(VocabularyEntry(id: "small-512", canonical: "small 512"))
    }
    XCTAssertEqual(overCount, VocabularyEditError(field: .entry, code: .tooManyEntries))
    let after = try await store.contents()
    XCTAssertEqual(after, contents)
    // Editing an existing entry within the count limit is still allowed.
    try await store.save(VocabularyEntry(id: "small-0", canonical: "small zero"))
    let observed2 = try await store.contents().entries.count
    XCTAssertEqual(observed2, 512)
  }

  func testPayloadCeilingIsEnforcedBelowEntryCeiling() async throws {
    let history = try makeHistory()
    let store = VocabularyStore(history: history)
    // Seed the largest set that fits directly, as the store itself would have written it.
    let big = String(repeating: "😀", count: 59)
    var entries: [VocabularyEntry] = []
    var payload = 0
    while true {
      let padded = String(format: "%03d", entries.count)
      let candidate = VocabularyEntry(
        id: "big-\(padded)", canonical: "\(big)\(padded)c",
        aliases: (0..<8).map { "\(big)\(padded)a\($0)" })
      let addition =
        VocabularyValidation.payloadBytes(try VocabularyValidation.serialize([candidate]))
        + (entries.isEmpty ? 0 : 1)
      guard payload + addition <= VocabularyStore.maximumPayloadBytes else { break }
      payload += addition
      entries.append(candidate)
    }
    XCTAssertLessThan(entries.count, VocabularyStore.maximumEntries)
    let seededEntries = entries
    let serialized = try VocabularyValidation.serialize(entries)
    XCTAssertEqual(VocabularyValidation.payloadBytes(serialized), payload)
    try await history.database.write { db in
      for entry in seededEntries {
        try db.execute(
          sql: "INSERT INTO vocabulary_entries VALUES (?,?,?,?,NULL)",
          arguments: [
            entry.id, entry.canonical, VocabularyValidation.encodeAliases(entry.aliases),
            entry.enabled,
          ])
      }
      try db.execute(
        sql: "UPDATE vocabulary_state SET revision=?, content_hash=?, payload_bytes=? WHERE id=1",
        arguments: [
          seededEntries.count, TranscriptionQualityDetail.hash(serialized),
          VocabularyValidation.payloadBytes(serialized),
        ])
    }
    let seeded = try await store.contents()
    XCTAssertEqual(seeded.entries.count, entries.count)
    let padded = String(format: "%03d", entries.count)
    let overflow = await code {
      try await store.save(
        VocabularyEntry(
          id: "big-\(padded)", canonical: "\(big)\(padded)c",
          aliases: (0..<8).map { "\(big)\(padded)a\($0)" }))
    }
    XCTAssertEqual(overflow, VocabularyEditError(field: .entry, code: .payloadCapacity))
    let after = try await store.contents()
    XCTAssertEqual(after, seeded)
    // A small entry still fits under the same ceiling; the limit is bytes, not rows.
    try await store.save(VocabularyEntry(id: "tiny", canonical: "tiny"))
    let final = try await store.contents()
    XCTAssertEqual(final.entries.count, entries.count + 1)
    XCTAssertLessThanOrEqual(final.state.payloadBytes, VocabularyStore.maximumPayloadBytes)
    XCTAssertEqual(final.state.revision, Int64(entries.count + 1))
  }

  func testConflictsIncludeDisabledEntriesAndTargetChains() async throws {
    let store = VocabularyStore(history: try makeHistory())
    try await store.save(VocabularyEntry(id: "x", canonical: "X", aliases: ["shared"]))
    let folded = await code {
      try await store.save(VocabularyEntry(id: "y", canonical: "Y", aliases: ["SHARED"]))
    }
    XCTAssertEqual(
      folded,
      VocabularyEditError(field: .alias(0), code: .conflictingSource, conflictingEntryID: "x"))
    let canonicalConflict = await code {
      try await store.save(VocabularyEntry(id: "y", canonical: "Shared"))
    }
    XCTAssertEqual(
      canonicalConflict,
      VocabularyEditError(field: .canonical, code: .conflictingSource, conflictingEntryID: "x"))
    let chain = await code {
      try await store.save(VocabularyEntry(id: "y", canonical: "Y", aliases: ["x"]))
    }
    XCTAssertEqual(
      chain, VocabularyEditError(field: .alias(0), code: .targetChain, conflictingEntryID: "x"))
    let duplicate = await code {
      try await store.save(VocabularyEntry(id: "y", canonical: "Y", aliases: ["why", "WHY"]))
    }
    XCTAssertEqual(duplicate, VocabularyEditError(field: .alias(1), code: .duplicateAlias))
    let selfAlias = await code {
      try await store.save(VocabularyEntry(id: "y", canonical: "Y", aliases: ["y"]))
    }
    XCTAssertEqual(selfAlias, VocabularyEditError(field: .alias(0), code: .duplicateAlias))
    // Disabling does not release the key: re-enabling could otherwise expose a hidden conflict.
    try await store.setEnabled(id: "x", enabled: false)
    let stillConflicting = await code {
      try await store.save(VocabularyEntry(id: "y", canonical: "Y", aliases: ["shared"]))
    }
    XCTAssertEqual(stillConflicting?.code, .conflictingSource)
    // Re-saving the same entry with its own keys is not a self-conflict.
    try await store.save(VocabularyEntry(id: "x", canonical: "X", aliases: ["shared", "more"]))
    let contents = try await store.contents()
    XCTAssertEqual(contents.entries.count, 1)
    XCTAssertEqual(contents.entries[0].aliases, ["shared", "more"])
    XCTAssertTrue(contents.entries[0].enabled)
  }

  func testAtomicFailureNoOpAndRevisionBehavior() async throws {
    let store = VocabularyStore(history: try makeHistory())
    let first = try await store.save(VocabularyEntry(id: "a", canonical: "Alpha"))
    XCTAssertEqual(first.revision, 1)
    let repeated = try await store.save(VocabularyEntry(id: "a", canonical: "Alpha"))
    XCTAssertEqual(repeated, first)
    let observed3 = try await store.contents().state
    XCTAssertEqual(observed3, first)
    let disabled = try await store.setEnabled(id: "a", enabled: false)
    XCTAssertEqual(disabled.revision, 2)
    XCTAssertNotEqual(disabled.contentHash, first.contentHash)
    let observed4 = try await store.setEnabled(id: "a", enabled: false).revision
    XCTAssertEqual(observed4, 2)
    let edited = try await store.save(
      VocabularyEntry(id: "a", canonical: "Alpha", aliases: ["alfa"], enabled: false))
    XCTAssertEqual(edited.revision, 3)
    let failed = await code {
      try await store.save(VocabularyEntry(id: "b", canonical: "Beta", aliases: ["alfa"]))
    }
    XCTAssertEqual(failed?.code, .conflictingSource)
    let afterFailure = try await store.contents()
    XCTAssertEqual(afterFailure.state, edited)
    XCTAssertEqual(afterFailure.entries.map(\.id), ["a"])
    let stale = await code {
      try await store.save(VocabularyEntry(id: "b", canonical: "Beta"), expectedRevision: 2)
    }
    XCTAssertEqual(stale, VocabularyEditError(field: .store, code: .staleRevision))
    let observed5 = try await store.contents().state
    XCTAssertEqual(observed5, edited)
    let deleted = try await store.delete(id: "a", expectedRevision: 3)
    XCTAssertEqual(deleted.revision, 4)
    XCTAssertEqual(deleted.contentHash, TranscriptionQualityDetail.emptyVocabularyHash)
    XCTAssertEqual(deleted.payloadBytes, 0)
    let missing = await code { try await store.delete(id: "a") }
    XCTAssertEqual(missing, VocabularyEditError(field: .entry, code: .missingEntry))
    let observed6 = try await store.contents().state.revision
    XCTAssertEqual(observed6, 4)
    let missingToggle = await code { try await store.setEnabled(id: "a", enabled: true) }
    XCTAssertEqual(missingToggle?.code, .missingEntry)
  }

  func testDeterministicHashesAndRestart() async throws {
    let history = try makeHistory()
    let path = history.database.path
    let store = VocabularyStore(history: history)
    try await store.save(VocabularyEntry(id: "b", canonical: "Beta", aliases: ["beta two"]))
    try await store.save(VocabularyEntry(id: "a", canonical: "Alpha", enabled: false))
    let state = try await store.contents().state
    let expected = TranscriptionQualityDetail.hash(
      Data(
        "localflow-vocabulary-v1:[{\"aliases\":[],\"canonical\":\"Alpha\",\"enabled\":false,\"id\":\"a\"},{\"aliases\":[\"beta two\"],\"canonical\":\"Beta\",\"enabled\":true,\"id\":\"b\"}]"
          .utf8))
    XCTAssertEqual(state.contentHash, expected)
    XCTAssertEqual(state.payloadBytes, 153 - 26)
    let other = VocabularyStore(history: try makeHistory())
    try await other.save(VocabularyEntry(id: "a", canonical: "Alpha", enabled: false))
    try await other.save(VocabularyEntry(id: "b", canonical: "Beta", aliases: ["beta two"]))
    let observed7 = try await other.contents().state.contentHash
    XCTAssertEqual(observed7, expected)
    let observed8 = try await other.contents().state.revision
    XCTAssertEqual(observed8, 2)
    let snapshot = try await store.snapshot()
    XCTAssertEqual(snapshot.revision, 2)
    XCTAssertEqual(snapshot.hash, expected)
    XCTAssertEqual(snapshot.entries.map(\.id), ["b"])

    let reopened = VocabularyStore(history: try makeHistory(path: path))
    let restored = try await reopened.contents()
    XCTAssertEqual(restored.state, state)
    XCTAssertEqual(restored.entries.map(\.id), ["a", "b"])
    let observed9 = try await reopened.snapshot()
    XCTAssertEqual(observed9, snapshot)
  }

  func testDamagedRowsBlockSnapshotAndEditor() async throws {
    let history = try makeHistory()
    let store = VocabularyStore(history: history)
    try await store.save(VocabularyEntry(id: "x", canonical: "X", aliases: ["shared"]))
    try await history.database.write { db in
      try db.execute(
        sql: "INSERT INTO vocabulary_entries VALUES ('y','Y','[\"shared\"]',1,NULL)")
    }
    let snapshot = await code { _ = try await store.snapshot() }
    XCTAssertEqual(snapshot, VocabularyEditError(field: .store, code: .damaged))
    let contents = await code { _ = try await store.contents() }
    XCTAssertEqual(contents?.code, .damaged)
    let edit = await code { try await store.save(VocabularyEntry(id: "z", canonical: "Z")) }
    XCTAssertEqual(edit?.code, .damaged)
    let rows = try await history.database.read {
      try Int.fetchOne($0, sql: "SELECT count(*) FROM vocabulary_entries")
    }
    XCTAssertEqual(rows, 2)
    // Removing the foreign row restores the recorded hash and the store works again.
    try await history.database.write { db in
      try db.execute(sql: "DELETE FROM vocabulary_entries WHERE id='y'")
    }
    let observed10 = try await store.snapshot().entries.map(\.id)
    XCTAssertEqual(observed10, ["x"])
    try await history.database.write { db in
      try db.execute(
        sql: "UPDATE vocabulary_state SET content_hash=? WHERE id=1",
        arguments: [String(repeating: "0", count: 64)])
    }
    let hashMismatch = await code { _ = try await store.snapshot() }
    XCTAssertEqual(hashMismatch?.code, .damaged)
  }

  func testLearnedMarkerRoundTripsAndChangesOnlyLearnedHashes() async throws {
    let history = try makeHistory()
    let store = VocabularyStore(history: history)
    try await store.save(VocabularyEntry(id: "m", canonical: "Manual"))
    let manualOnly = try await store.contents().state
    try await store.save(
      VocabularyEntry(
        id: "l", canonical: "Learned", aliases: ["lerned"], learnedAt: 1_700_000_000_000))
    let contents = try await store.contents()
    XCTAssertEqual(contents.entries.map(\.isLearned), [true, false])
    XCTAssertEqual(contents.entries[0].learnedAt, 1_700_000_000_000)
    let serialized = try VocabularyValidation.serialize(contents.entries)
    XCTAssertTrue(
      String(decoding: serialized, as: UTF8.self).contains("\"learned_at\":1700000000000"))
    XCTAssertEqual(
      TranscriptionQualityDetail.hash(try VocabularyValidation.serialize([contents.entries[1]])),
      TranscriptionQualityDetail.hash(
        Data(
          "localflow-vocabulary-v1:[{\"aliases\":[],\"canonical\":\"Manual\",\"enabled\":true,\"id\":\"m\"}]"
            .utf8)))
    XCTAssertNotEqual(manualOnly.contentHash, contents.state.contentHash)
    // Disabling keeps the marker; a reopened store reads it back.
    try await store.setEnabled(id: "l", enabled: false)
    let reopened = VocabularyStore(history: try makeHistory(path: history.database.path))
    let restored = try await reopened.contents()
    XCTAssertEqual(restored.entries[0].learnedAt, 1_700_000_000_000)
    XCTAssertFalse(restored.entries[0].enabled)
    let currentState = try await store.contents().state
    XCTAssertEqual(restored.state, currentState)
    let snapshot = try await reopened.snapshot()
    XCTAssertEqual(snapshot.entries.map(\.id), ["m"])
  }

  func testHistoryDetailKeepsItsOriginalVocabularyIdentity() async throws {
    let history = try makeHistory()
    let store = VocabularyStore(history: history)
    let reservation = try await history.reserve()
    let envelope = try makeQualityEnvelope()
    _ = try await history.commit(reservation: reservation, envelope: envelope)
    try await store.save(VocabularyEntry(id: "a", canonical: "Assembled"))
    let detail = try await history.qualityDetail(envelope.entry.id)
    XCTAssertEqual(detail?.vocabularyRevision, 0)
    XCTAssertEqual(detail?.vocabularyHash, TranscriptionQualityDetail.emptyVocabularyHash)
    XCTAssertEqual(detail?.appliedEntryIDs, [])
    let observed11 = try await history.get(envelope.entry.id)?.text
    XCTAssertEqual(observed11, "assembled")
  }
}
