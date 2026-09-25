import Foundation
import GRDB
import XCTest

@testable import LocalFlow

final class HistoryQueryTests: XCTestCase {
  private func makeStore() throws -> (TranscriptionStore, URL) {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
      "history-query-\(UUID()).sqlite")
    return (try TranscriptionStore(path: url.path), url)
  }

  private func save(_ text: String, at time: Int64 = 1, store: TranscriptionStore) async throws
    -> TranscriptionEntry
  {
    let entry = try TranscriptionEntry(
      id: UUID(), text: text, createdAtMilliseconds: time,
      quality: .complete, stopReason: .keyRelease)
    return try await store.commit(reservation: try await store.reserve(), entry: entry)
  }

  func testSearchUsesNormalizedParentAndSelectedStagesSurviveRestart() async throws {
    let (store, url) = try makeStore()
    defer { removeDatabase(at: url) }
    let source = try makeQualityEnvelope(raw: "raw_only e\u{301}", text: "assembled_only")
    let base = try XCTUnwrap(source.detail)
    let detail = try TranscriptionQualityDetail(
      rawWindows: base.rawWindows, assembledText: base.assembledText,
      normalizedText: "normalized_only",
      assemblyVersion: "test-assembly", normalizationVersion: "test-normalization",
      provenance: base.provenance)
    let entry = try TranscriptionEntry(
      id: source.entry.id, text: "normalized_only",
      createdAtMilliseconds: 1, quality: .complete, stopReason: .keyRelease)
    let saved = try await store.commit(
      reservation: try await store.reserve(),
      envelope: .init(entry: entry, detail: detail))
    let restarted = try TranscriptionStore(path: url.path)
    for query in ["raw_only", "assembled_only"] {
      let page = try await restarted.page(query: query)
      XCTAssertTrue(page.entries.isEmpty)
    }
    let page = try await restarted.page(query: "normalized_only")
    XCTAssertEqual(page.entries.map(\.text), ["normalized_only"])
    let selected = try await restarted.selectedEnvelope(saved.id)
    XCTAssertEqual(selected.detail?.contentHash, detail.contentHash)
    XCTAssertEqual(
      selected.detail?.rawWindows.first?.text.utf8.map { $0 },
      base.rawWindows.first?.text.utf8.map { $0 })
    XCTAssertEqual(selected.detail?.assembledText, "assembled_only")
    let cancelled = Task { try await restarted.selectedEnvelope(saved.id) }
    cancelled.cancel()
    do {
      _ = try await cancelled.value
      XCTFail("Cancelled detail read succeeded")
    } catch is CancellationError {}
    try await restarted.deleteConfirmed(id: saved.id, revision: saved.revision)
    do {
      _ = try await restarted.selectedEnvelope(saved.id)
      XCTFail("Deleted detail returned")
    } catch { XCTAssertEqual(error as? TranscriptionStore.Error, .missingEntry) }
  }

  func testRawDetailPreservesReceivedOrderOverlapAndInvalidTimingLabel() async throws {
    let (store, url) = try makeStore()
    defer { removeDatabase(at: url) }
    let source = try makeQualityEnvelope(text: "repeated words remain")
    let base = try XCTUnwrap(source.detail)
    let windows: [TranscriptionQualityDetail.RawWindow] = [
      .init(
        sequence: 0, sampleStart: 0, sampleCount: 12_000, paddedSampleCount: 12_000,
        text: "first repeated", timings: nil, timingValidation: .unavailable),
      .init(
        sequence: 1, sampleStart: 8_000, sampleCount: 8_000, paddedSampleCount: 8_000,
        text: "repeated second",
        timings: [.init(text: "repeated", start: .init(.nan), end: .init(0.5))],
        timingValidation: .invalid),
    ]
    let detail = try TranscriptionQualityDetail(
      rawWindows: windows, assembledText: base.assembledText,
      normalizedText: source.entry.text, assemblyVersion: "test-assembly",
      normalizationVersion: "identity-v1",
      provenance: base.provenance)
    let saved = try await store.commit(
      reservation: try await store.reserve(),
      envelope: .init(entry: source.entry, detail: detail))
    let selected = try await store.selectedEnvelope(saved.id)
    XCTAssertEqual(selected.detail?.rawWindows.map(\.text), ["first repeated", "repeated second"])
    XCTAssertEqual(
      selected.detail?.rawWindows.map(\.historyLabel),
      ["Window 1 · samples 0–12000", "Window 2 · samples 8000–16000"])
    XCTAssertEqual(selected.detail?.rawWindows.last?.timingValidation, .invalid)
    XCTAssertEqual(selected.detail?.rawWindows.last?.timings?.first?.start.invalid, .nan)
  }

  func testOversizedStoredDetailIsRejectedWithoutReturningAnEnvelope() async throws {
    let (store, url) = try makeStore()
    defer { removeDatabase(at: url) }
    let source = try makeQualityEnvelope()
    let saved = try await store.commit(reservation: try await store.reserve(), envelope: source)
    let database = try DatabaseQueue(path: url.path)
    try await database.write { db in
      // Simulate external corruption; normal writes already enforce the schema's byte cap.
      try db.execute(sql: "PRAGMA ignore_check_constraints=ON")
      defer { try? db.execute(sql: "PRAGMA ignore_check_constraints=OFF") }
      try db.execute(
        sql: "UPDATE transcription_quality SET detail_json=? WHERE transcription_id=?",
        arguments: [
          String(repeating: "x", count: TranscriptionQualityDetail.maximumSerializedBytes + 1),
          saved.id.uuidString,
        ])
    }
    do {
      _ = try await store.selectedEnvelope(saved.id)
      XCTFail("Oversized detail returned")
    } catch { XCTAssertEqual(error as? TranscriptionStore.Error, .damagedDatabase) }
    let summary = try await store.get(saved.id)
    XCTAssertEqual(summary?.text, source.entry.text)
  }

  func testTimestampTiesRoundTripAndWatermarkExcludesNewerRows() async throws {
    let (store, url) = try makeStore()
    defer { removeDatabase(at: url) }
    for index in 0..<45 { _ = try await save("row \(index)", store: store) }
    let first = try await store.page()
    XCTAssertEqual(first.entries.count, 20)
    XCTAssertTrue(first.hasMore)
    _ = try await save("new arrival", at: 2, store: store)
    let second = try await store.page(
      cursor: .init(try XCTUnwrap(first.entries.last)), watermark: first.watermark)
    let third = try await store.page(
      cursor: .init(try XCTUnwrap(second.entries.last)), watermark: first.watermark)
    XCTAssertEqual(third.entries.count, 5)
    XCTAssertFalse(third.hasMore)
    XCTAssertEqual(Set((first.entries + second.entries + third.entries).map(\.id)).count, 45)
    let back = try await store.page(
      cursor: .init(try XCTUnwrap(second.entries.first)), direction: .newer,
      watermark: first.watermark)
    XCTAssertEqual(back.entries, first.entries)
    XCTAssertFalse(back.hasMore)
    let newest = try await store.page()
    XCTAssertEqual(newest.entries.first?.text, "new arrival")
  }

  func testLiteralCanonicalCaseInsensitiveSearchAcrossUnloadedPagesPreservesDiacritics()
    async throws
  {
    let (store, url) = try makeStore()
    defer { removeDatabase(at: url) }
    _ = try await save("STARÉ cafe\u{301} 100% _ [x]", at: 1, store: store)
    for index in 0..<45 { _ = try await save("unrelated \(index)", at: 2, store: store) }
    for query in ["staré", "CAFÉ", "100% _ [x]"] {
      let page = try await store.page(query: query)
      XCTAssertEqual(page.entries.count, 1, query)
    }
    let diacritic = try await store.page(query: "cafe")
    XCTAssertTrue(diacritic.entries.isEmpty)
    let wildcard = try await store.page(query: "%unrelated%")
    XCTAssertTrue(wildcard.entries.isEmpty)
  }

  func testSearchBoundsAndEmptyStore() async throws {
    let (store, url) = try makeStore()
    defer { removeDatabase(at: url) }
    let page = try await store.page()
    XCTAssertTrue(page.entries.isEmpty)
    XCTAssertNil(page.watermark)
    XCTAssertThrowsError(try TranscriptionStore.validatedQuery(String(repeating: "a", count: 257)))
    XCTAssertNoThrow(try TranscriptionStore.validatedQuery(String(repeating: "😀", count: 256)))
  }

  func testCancelledScanDoesNotPreventSave() async throws {
    let (store, url) = try makeStore()
    defer { removeDatabase(at: url) }
    for index in 0..<60 { _ = try await save("entry \(index)", store: store) }
    let search = Task { try await store.page(query: "missing") }
    search.cancel()
    do {
      _ = try await search.value
      XCTFail("Cancelled search returned rows")
    } catch is CancellationError {}
    let saved = try await save("after cancellation", store: store)
    let retrieved = try await store.get(saved.id)
    XCTAssertEqual(retrieved?.text, saved.text)
  }

  func testTenThousandRowAdmissionAndExplicitDeleteFreesOneSlot() async throws {
    let (store, url) = try makeStore()
    defer { removeDatabase(at: url) }
    let database = try DatabaseQueue(path: url.path)
    try await database.write { db in
      for _ in 0..<10_000 {
        try db.execute(
          sql: """
            INSERT INTO transcriptions (id,text,created_at,delivery_state,recovery_state,quality,stop_reason,revision)
            VALUES (?,'x',1,'not_attempted','needs_review','complete','key_release',0)
            """, arguments: [UUID().uuidString])
      }
      try db.execute(sql: "UPDATE history_usage SET row_count=10000,payload_bytes=10000 WHERE id=1")
    }
    do {
      _ = try await store.reserve()
      XCTFail("Row capacity must block admission")
    } catch let error as TranscriptionStore.Error { XCTAssertEqual(error, .capacityExceeded) }
    let page = try await store.page()
    let selected = try XCTUnwrap(page.entries.first)
    _ = try await store.dismissRecovery(id: selected.id, revision: selected.revision)
    do {
      _ = try await store.reserve()
      XCTFail("Dismiss must not free capacity")
    } catch let error as TranscriptionStore.Error { XCTAssertEqual(error, .capacityExceeded) }
    try await store.deleteConfirmed(id: selected.id, revision: selected.revision + 1)
    let admission = try await store.reserve()
    await store.releaseReservation(admission)
  }

  func testDeleteStaleAndBusyPreserveText() async throws {
    let (store, url) = try makeStore()
    defer { removeDatabase(at: url) }
    let saved = try await save("keep me", store: store)
    let attempt = try await store.beginAttempt(id: saved.id, revision: saved.revision)
    do {
      try await store.deleteConfirmed(id: saved.id, revision: saved.revision)
      XCTFail("stale delete")
    } catch let error as TranscriptionStore.Error { XCTAssertEqual(error, .staleRevision) }
    do {
      try await store.deleteConfirmed(id: saved.id, revision: attempt.entry.revision)
      XCTFail("busy delete")
    } catch let error as TranscriptionStore.Error { XCTAssertEqual(error, .busy) }
    let remaining = try await store.get(saved.id)
    XCTAssertEqual(remaining?.text, "keep me")
  }
}
