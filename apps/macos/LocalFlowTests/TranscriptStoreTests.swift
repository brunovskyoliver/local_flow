import GRDB
import XCTest

@testable import LocalFlow

final class TranscriptStoreTests: XCTestCase {
  private var fixture: MeetingTestStore!
  private var store: TranscriptStore!
  override func setUpWithError() throws {
    fixture = try MeetingTestStore.make()
    store = TranscriptStore(database: fixture.history.database)
  }
  override func tearDown() { fixture.cleanup() }
  private func pending() async throws -> UUID {
    let meeting = try await fixture.store.create(now: 1)
    try await fixture.store.transition(
      id: meeting.id, to: .preparing, now: 2, effects: [.insertTranscription(liveRequested: true)])
    return meeting.id
  }
  private func draft(_ ordinal: Int = 0) -> TranscriptSegmentDraft {
    TranscriptSegmentDraft(
      ordinal: ordinal, stretchSequence: 1, startMs: Int64(ordinal) * 100,
      endMs: Int64(ordinal + 1) * 100, coveredMs: 10_000, windowIndex: 0, timingBasis: .window,
      rawText: "raw", assembledText: "raw", normalizedText: "Raw", analysisTracks: .mic)
  }
  func testRejectsInvalidTimingOrdinalsAndBackwardStretchAtomically() async throws {
    let id = try await pending()
    let pass = UUID()
    try await store.transition(
      meetingID: id, to: .live, now: 3,
      effects: [.setPass(id: pass, kind: .live)])
    var first = draft()
    first.stretchSequence = 2
    _ = try await store.appendSegments(
      meetingID: id, passID: pass,
      drafts: [first], progress: nil, now: 4)
    var invalids: [TranscriptSegmentDraft] = []
    var next = draft(1)
    next.stretchSequence = 2
    var invalid = next
    invalid.startMs = invalid.endMs
    invalids.append(invalid)
    invalid = next
    invalid.endMs = invalid.coveredMs + 1
    invalids.append(invalid)
    invalid = next
    invalid.ordinal = 3
    invalids.append(invalid)
    invalid = next
    invalid.stretchSequence = 1
    invalids.append(invalid)
    let before = try await store.transcription(meetingID: id)
    for invalid in invalids {
      do {
        _ = try await store.appendSegments(
          meetingID: id, passID: pass,
          drafts: [invalid], progress: nil, now: 5)
        XCTFail("Invalid segment accepted")
      } catch {
        guard case TranscriptStore.Error.invalidSegment = error else { return XCTFail("\(error)") }
      }
      let after = try await store.transcription(meetingID: id)
      XCTAssertEqual(after, before)
    }
  }

  func testAdjacentGapsMergeAndLiveMetadataDoesNotChangeState() async throws {
    let id = try await pending()
    let pass = UUID()
    try await store.transition(
      meetingID: id, to: .live, now: 3,
      effects: [.setPass(id: pass, kind: .live)])
    for start in [0, 100, 200] {
      try await store.appendGap(
        .init(
          meetingID: id, passID: pass, stretchSequence: 1,
          startMs: Int64(start), endMs: Int64(start + 100), reason: .suspended, createdAt: 4))
    }
    let gaps = try await store.gaps(meetingID: id)
    XCTAssertEqual(gaps.count, 1)
    XCTAssertEqual(gaps.first?.startMs, 0)
    XCTAssertEqual(gaps.first?.endMs, 300)
    let before = try await store.transcription(meetingID: id)
    let descriptor = AnalysisStreamDescriptor(
      source: .livePCMTee,
      stretches: [.init(sequence: 1, lengthMs: 300, tracks: .mic)])
    let after = try await store.updateLiveMetadata(
      meetingID: id, descriptor: descriptor,
      incrementModelReloads: true, now: 5)
    XCTAssertEqual(after.state, .live)
    XCTAssertEqual(after.revision, (before?.revision ?? 0) + 1)
    XCTAssertEqual(after.modelReloadCount, 1)
    XCTAssertEqual(after.analysisDescriptor, descriptor)
  }

  func testMigrationAndEmptyUsage() async throws {
    try await fixture.history.database.read { db in
      for table in [
        "meeting_transcriptions", "transcript_segments", "transcript_live_gaps", "transcript_usage",
      ] { XCTAssertTrue(try db.tableExists(table)) }
    }
    let usage = try await store.usage()
    XCTAssertEqual(usage, TranscriptUsage(textBytes: 0, segmentRows: 0))
  }
  func testRollbackInvalidTransitionAndEffects() async throws {
    let id = try await pending()
    do {
      try await store.transition(meetingID: id, to: .final, now: 3, effects: [])
      XCTFail()
    } catch {}
    do {
      try await store.transition(
        meetingID: id, to: .live, now: 3, effects: [.setTimestamps(expectedRevision: 99)])
      XCTFail()
    } catch { XCTAssertEqual(error as? TranscriptStore.Error, .staleRevision) }
    let row = try await store.transcription(meetingID: id)
    XCTAssertEqual(row?.state, .pending)
    XCTAssertEqual(row?.revision, 0)
  }
  func testBatchAtomicityFinalizationAndPaging() async throws {
    let id = try await pending()
    let pass = UUID()
    try await store.transition(
      meetingID: id, to: .live, now: 3, effects: [.setPass(id: pass, kind: .live)])
    _ = try await store.appendSegments(
      meetingID: id, passID: pass, drafts: [draft()], progress: nil, now: 4)
    var invalid = draft(1)
    invalid.rawText = String(repeating: "x", count: 4097)
    do {
      _ = try await store.appendSegments(
        meetingID: id, passID: pass, drafts: [draft(1), invalid], progress: nil, now: 5)
      XCTFail()
    } catch {}
    let usage = try await store.usage()
    XCTAssertEqual(usage.segmentRows, 1)
    XCTAssertEqual(usage.textBytes, 9)
    let page = try await store.page(meetingID: id, finality: .provisional, after: nil, limit: 500)
    XCTAssertEqual(page.count, 1)
    let finalPass = UUID()
    try await store.transition(
      meetingID: id, to: .finalizing, now: 6, effects: [.setPass(id: finalPass, kind: .final)])
    var final = draft()
    final.finality = .final
    _ = try await store.appendSegments(
      meetingID: id, passID: finalPass, drafts: [final], progress: .init(sequence: 1, sample: 1600),
      now: 7)
    let completed = try await store.completeFinalPass(
      meetingID: id, passID: finalPass, descriptor: .init(source: .decodedTracks), coveredMs: 100,
      now: 8)
    XCTAssertEqual(completed.state, .final)
    XCTAssertEqual(completed.replacedProvisionalCount, 1)
    XCTAssertEqual(completed.segmentCount, 1)
    try await store.discardPass(meetingID: id, passID: pass)
    let remaining = try await store.usage()
    XCTAssertEqual(remaining.segmentRows, 1)
  }
  func testValidationOrderCapacityRollbackAndProgress() async throws {
    let id = try await pending()
    let pass = UUID()
    try await store.transition(
      meetingID: id, to: .live, now: 3, effects: [.setPass(id: pass, kind: .live)])
    var bad = draft(9)
    bad.rawText = String(repeating: "é", count: 2049)
    bad.endMs = 0
    do {
      _ = try await store.appendSegments(
        meetingID: id, passID: pass, drafts: [bad], progress: nil, now: 4)
      XCTFail()
    } catch { XCTAssertEqual(error as? TranscriptStore.Error, .invalidSegment("text_bytes")) }
    bad.rawText = "a"
    do {
      _ = try await store.appendSegments(
        meetingID: id, passID: pass, drafts: [bad], progress: nil, now: 4)
      XCTFail()
    } catch { XCTAssertEqual(error as? TranscriptStore.Error, .invalidSegment("timing")) }
    bad.endMs = 1000
    do {
      _ = try await store.appendSegments(
        meetingID: id, passID: pass, drafts: [bad], progress: nil, now: 4)
      XCTFail()
    } catch { XCTAssertEqual(error as? TranscriptStore.Error, .invalidSegment("ordinal")) }
    for (column, value, capacity) in [
      ("segment_count", 20_000, TranscriptStore.Capacity.meetingSegments),
      ("text_bytes", 16 * 1024 * 1024, .meetingBytes),
    ] {
      try await fixture.history.database.write { db in
        try db.execute(
          sql: "UPDATE meeting_transcriptions SET segment_count=0,text_bytes=0 WHERE meeting_id=?",
          arguments: [id.uuidString])
        try db.execute(
          sql: "UPDATE meeting_transcriptions SET \(column)=? WHERE meeting_id=?",
          arguments: [value, id.uuidString])
      }
      let before = try await store.transcription(meetingID: id)
      do {
        _ = try await store.appendSegments(
          meetingID: id, passID: pass, drafts: [draft()], progress: nil, now: 4)
        XCTFail()
      } catch { XCTAssertEqual(error as? TranscriptStore.Error, .capacityExceeded(capacity)) }
      let after = try await store.transcription(meetingID: id)
      XCTAssertEqual(before, after)
    }
    try await fixture.history.database.write { db in
      try db.execute(
        sql: "UPDATE meeting_transcriptions SET segment_count=0,text_bytes=0 WHERE meeting_id=?",
        arguments: [id.uuidString])
      try db.execute(sql: "UPDATE transcript_usage SET text_bytes=50331648 WHERE id=1")
    }
    do {
      _ = try await store.appendSegments(
        meetingID: id, passID: pass, drafts: [draft()], progress: nil, now: 4)
      XCTFail()
    } catch { XCTAssertEqual(error as? TranscriptStore.Error, .capacityExceeded(.globalBytes)) }
    try await fixture.history.database.write {
      try $0.execute(sql: "UPDATE transcript_usage SET text_bytes=0 WHERE id=1")
    }
    _ = try await store.appendSegments(
      meetingID: id, passID: pass, drafts: (0..<50).map(draft),
      progress: .init(sequence: 1, sample: 80000), now: 5)
    let row = try await store.transcription(meetingID: id)
    XCTAssertEqual(row?.progressSample, 80000)
    XCTAssertEqual(row?.segmentCount, 50)
  }
  func testFailureConstraintRollsBackTransitionAndLiveState() async throws {
    let id = try await pending()
    do {
      try await store.transition(meetingID: id, to: .failed, now: 3, effects: [])
      XCTFail()
    } catch {}
    let pending = try await store.transcription(meetingID: id)
    XCTAssertEqual(pending?.state, .pending)
    do {
      try await store.setLiveState(meetingID: id, liveState: .live, now: 4)
      XCTFail()
    } catch {}
    let failed = try await store.transition(
      meetingID: id, to: .failed, now: 5,
      effects: [.setFailure(category: .modelUnavailable, detail: nil)])
    XCTAssertEqual(failed.failureCategory, .modelUnavailable)
    let active = try await store.activeRows(limit: 100)
    XCTAssertTrue(active.isEmpty)
  }
  func testGapCapMergesAndCompletionDeletesGaps() async throws {
    let id = try await pending()
    let pass = UUID()
    try await store.transition(
      meetingID: id, to: .live, now: 3, effects: [.setPass(id: pass, kind: .live)])
    try await fixture.history.database.write { db in
      for i in 0..<10000 {
        try db.execute(
          sql:
            "INSERT INTO transcript_live_gaps(id,meeting_id,pass_id,stretch_sequence,start_ms,end_ms,reason,created_at) VALUES(?,?,?,1,?,?,'backpressure',1)",
          arguments: [UUID().uuidString, id.uuidString, pass.uuidString, i, i + 1])
      }
    }
    try await store.appendGap(
      .init(
        meetingID: id, passID: pass, stretchSequence: 1, startMs: 10000, endMs: 11000,
        reason: .suspended, createdAt: 4))
    let gaps = try await store.gaps(meetingID: id)
    XCTAssertEqual(gaps.count, 10000)
    XCTAssertEqual(gaps.last?.endMs, 11000)
    let final = UUID()
    try await store.transition(
      meetingID: id, to: .finalizing, now: 5, effects: [.setPass(id: final, kind: .final)])
    _ = try await store.completeFinalPass(
      meetingID: id, passID: final, descriptor: .init(source: .decodedTracks), coveredMs: 11000,
      now: 6)
    let remaining = try await store.gaps(meetingID: id)
    XCTAssertTrue(remaining.isEmpty)
  }
  func testOutcomePrefixAndDescriptorBound() async throws {
    let id = try await pending()
    try await store.recordOutcome(
      .init(
        meetingID: id, ranAt: 3, foundState: .preparing, foundStage: nil,
        summary: "pending_to_failed"))
    let summary = try await fixture.history.database.read {
      try String.fetchOne(
        $0, sql: "SELECT summary FROM meeting_recovery_outcomes WHERE meeting_id=?",
        arguments: [id.uuidString])
    }
    XCTAssertEqual(summary, "transcript:pending_to_failed")
    let descriptor = AnalysisStreamDescriptor(
      source: .decodedTracks,
      stretches: (1...201).map { .init(sequence: $0, lengthMs: 10, tracks: .mic) })
    XCTAssertEqual(descriptor.stretches.count, 200)
    XCTAssertTrue(descriptor.stretchesTruncated)
    XCTAssertEqual(
      try JSONDecoder().decode(
        AnalysisStreamDescriptor.self, from: JSONEncoder().encode(descriptor)), descriptor)
  }

  func testDatabaseAbortRollsBackInsertedBatchAndCounters() async throws {
    let id = try await pending()
    let pass = UUID()
    try await store.transition(
      meetingID: id, to: .live, now: 3, effects: [.setPass(id: pass, kind: .live)])
    try await fixture.history.database.write { db in
      try db.execute(
        sql:
          "CREATE TRIGGER reject_second_segment BEFORE INSERT ON transcript_segments WHEN NEW.ordinal=1 BEGIN SELECT RAISE(ABORT,'injected_failure'); END"
      )
    }
    let before = try await store.transcription(meetingID: id)
    do {
      _ = try await store.appendSegments(
        meetingID: id, passID: pass, drafts: [draft(0), draft(1)],
        progress: .init(sequence: 1, sample: 3200), now: 4)
      XCTFail()
    } catch {}
    let after = try await store.transcription(meetingID: id)
    XCTAssertEqual(before, after)
    let usage = try await store.usage()
    XCTAssertEqual(usage, .init(textBytes: 0, segmentRows: 0))
    let page = try await store.page(meetingID: id, finality: .provisional, after: nil, limit: 200)
    XCTAssertTrue(page.isEmpty)
  }
  func testPagingLimitAndFinalRowsCannotBeAppendedAfterCompletion() async throws {
    let id = try await pending()
    let pass = UUID()
    try await store.transition(
      meetingID: id, to: .finalizing, now: 3, effects: [.setPass(id: pass, kind: .final)])
    for batch in 0..<5 {
      let drafts = (0..<50).map { index in
        var d = draft(batch * 50 + index)
        d.finality = .final
        d.coveredMs = 30000
        return d
      }
      _ = try await store.appendSegments(
        meetingID: id, passID: pass, drafts: drafts, progress: nil, now: 4)
    }
    let page = try await store.page(meetingID: id, finality: .final, after: nil, limit: 1000)
    XCTAssertEqual(page.count, 200)
    let next = try await store.page(
      meetingID: id, finality: .final, after: page.last?.ordinal, limit: 200)
    XCTAssertEqual(next.count, 50)
    XCTAssertEqual(next.first?.ordinal, 200)
    _ = try await store.completeFinalPass(
      meetingID: id, passID: pass, descriptor: .init(source: .decodedTracks), coveredMs: 25000,
      now: 5)
    do {
      _ = try await store.appendSegments(
        meetingID: id, passID: pass, drafts: [draft(0)], progress: nil, now: 6)
      XCTFail()
    } catch { XCTAssertEqual(error as? TranscriptStore.Error, .passMismatch) }
  }

  func testSchemaClosedValuesAndIndexes() async throws {
    let id = try await pending()
    try await fixture.history.database.write { db in
      for update in [
        "state='unknown'", "live_state='unknown'", "live_state='live'", "pass_kind='unknown'",
        "failure_category='runtime_failure'", "revision=-1",
        "analysis_descriptor_json='" + String(repeating: "x", count: 16385) + "'",
      ] {
        XCTAssertThrowsError(
          try db.execute(
            sql: "UPDATE meeting_transcriptions SET \(update) WHERE meeting_id=?",
            arguments: [id.uuidString]))
      }
      XCTAssertThrowsError(try db.execute(sql: "INSERT INTO transcript_usage VALUES(2,0,0,1)"))
      XCTAssertThrowsError(
        try db.execute(sql: "UPDATE transcript_usage SET schema_version=2 WHERE id=1"))
      let indexes = Set(
        try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type='index'"))
      XCTAssertTrue(
        indexes.isSuperset(of: [
          "meeting_transcriptions_active", "transcript_segments_page", "transcript_segments_pass",
        ]))
      for field in ["finality", "timing_basis", "analysis_tracks", "speaker"] {
        let base =
          "INSERT INTO transcript_segments(id,meeting_id,pass_id,finality,ordinal,stretch_sequence,start_ms,end_ms,window_index,timing_basis,raw_text,assembled_text,normalized_text,engine,model_id,model_revision,pipeline_version,analysis_tracks,speaker,created_at) VALUES('s',?,'p','provisional',0,1,0,1,0,'word','','','','e','m','r','v','mic','unassigned',0)"
        let values = [
          "finality": "provisional", "timing_basis": "word", "analysis_tracks": "mic",
          "speaker": "unassigned",
        ]
        let invalid = base.replacingOccurrences(of: "'" + values[field]! + "'", with: "'unknown'")
        XCTAssertThrowsError(try db.execute(sql: invalid, arguments: [id.uuidString]))
      }
      XCTAssertThrowsError(
        try db.execute(
          sql:
            "INSERT INTO transcript_live_gaps(id,meeting_id,pass_id,stretch_sequence,start_ms,end_ms,reason,created_at) VALUES('g',?,'p',1,0,1,'unknown',0)",
          arguments: [id.uuidString]))
      XCTAssertThrowsError(
        try db.execute(
          sql:
            "INSERT INTO transcript_live_gaps(id,meeting_id,pass_id,stretch_sequence,start_ms,end_ms,reason,created_at) VALUES('g',?,'p',1,1,1,'backpressure',0)",
          arguments: [id.uuidString]))
    }
  }
  func testPre005DatabaseOpensWithZeroTranscriptRows() async throws {
    let path = fixture.directory.appendingPathComponent("pre005.sqlite").path
    do {
      let old = try TranscriptionStore(path: path)
      try await old.database.write { db in
        for table in [
          "transcript_live_gaps", "transcript_segments", "meeting_transcriptions",
          "transcript_usage",
        ] { try db.drop(table: table) }
        try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier='transcripts-v6'")
      }
    }
    let reopened = try TranscriptionStore(path: path)
    let transcripts = TranscriptStore(history: reopened)
    let usage = try await transcripts.usage()
    XCTAssertEqual(usage, .init(textBytes: 0, segmentRows: 0))
    let count = try await reopened.database.read {
      try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM meeting_transcriptions")
    }
    XCTAssertEqual(count, 0)
  }

}
