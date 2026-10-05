import GRDB
import XCTest

@testable import LocalFlow
@testable import LocalFlowCore
@testable import LocalFlowSpeech

/// A handed-off meeting's slice goes out, the server's own finalizer runs on it, and the
/// result merges back with the capacity counter exact.
final class MeetingHandoffTests: XCTestCase {
  func testExportedSliceProcessedElsewhereMergesBack() async throws {
    let fixture = try MeetingTestStore.make()
    defer { fixture.cleanup() }
    let meeting = try await TranscriptMeetingFixture.make(in: fixture)
    let id = meeting.meetingID
    let handoff = MeetingHandoff(
      pool: RemoteChannelPool(open: { throw RemoteChannelError.unreachable }),
      database: fixture.history.database, root: fixture.root,
      eligible: { _ in true }, defaultLanguage: { .defaultLanguage })
    let bundle = fixture.directory.appendingPathComponent("handoff/bundle.sqlite")
    let exported = try await handoff.export(id, to: bundle)
    XCTAssertTrue(exported)

    // What flowd-meeting does on the server: the app's finalizer over the slice.
    let remote = try TranscriptionStore(path: bundle.path)
    let transcripts = TranscriptStore(database: remote.database)
    let finalizer = MeetingFinalizer(
      store: transcripts, meetings: MeetingStore(history: remote, root: fixture.root),
      storageRoot: fixture.root,
      lifecycle: ModelLifecycleCoordinator { FakeTranscriptionRuntime() },
      vocabulary: EmptyVocabularyProvider(), clock: FakeMeetingClock())
    let rowValue = try await transcripts.transcription(meetingID: id)
    let row = try XCTUnwrap(rowValue)
    let outcome = try await finalizer.run(meetingID: id, revision: row.revision)
    XCTAssertEqual(outcome.row.state, .final)
    try await remote.database.writeWithoutTransaction { db in
      try db.execute(sql: "PRAGMA wal_checkpoint(TRUNCATE)")
    }

    let labeled = try await handoff.merge(id, from: bundle)
    XCTAssertFalse(labeled)
    let local = TranscriptStore(database: fixture.history.database)
    let mergedValue = try await local.transcription(meetingID: id)
    let merged = try XCTUnwrap(mergedValue)
    XCTAssertEqual(merged.state, .final)
    XCTAssertEqual(merged.passID, outcome.row.passID)
    try await fixture.history.database.read { db in
      XCTAssertEqual(
        try String.fetchOne(
          db, sql: "SELECT inference_path FROM meeting_transcriptions WHERE meeting_id=?",
          arguments: [id.uuidString]), "server")
      let segments = try Int.fetchOne(
        db, sql: "SELECT COUNT(*) FROM transcript_segments WHERE meeting_id=?",
        arguments: [id.uuidString])
      XCTAssertEqual(segments, merged.segmentCount)
      XCTAssertGreaterThan(merged.segmentCount, 0)
      // The counter equals the sum it tracks.
      let usage = try Row.fetchOne(db, sql: "SELECT * FROM transcript_usage WHERE id=1")
      let sums = try Row.fetchOne(
        db, sql: "SELECT SUM(text_bytes) AS t, SUM(segment_count) AS s FROM meeting_transcriptions")
      XCTAssertEqual(usage?["text_bytes"] as Int?, sums?["t"] as Int?)
      XCTAssertEqual(usage?["segment_rows"] as Int?, sums?["s"] as Int?)
    }

    // A meeting with labels or a summary is never handed off.
    _ = try await SpeakerStore(history: fixture.history).admit(
      meetingID: id, transcriptPassID: try XCTUnwrap(merged.passID), trigger: .automatic,
      identity: DiarizationIdentity(
        engine: "fluidaudio_offline_diarizer", modelID: FluidAudioDiarizerFactory.modelID,
        modelRevision: FluidAudioDiarizerFactory.revision,
        manifestHash: String(repeating: "0", count: 64),
        pipelineVersion: DiarizationPipelineVersion.current),
      expectedRevision: nil, now: 2)
    let again = try await handoff.export(
      id, to: fixture.directory.appendingPathComponent("handoff2/bundle.sqlite"))
    XCTAssertFalse(again)
  }

  /// Feature 020: the slice goes up while the meeting records, a partial run transcribes
  /// what is finished, newer rows arrive as `rows.sqlite` and replace the bundle's without
  /// touching the transcript, and the final run completes the same pass.
  func testRowsFileReplacesMeetingRowsBetweenPartialAndFinalRuns() async throws {
    let fixture = try MeetingTestStore.make()
    defer { fixture.cleanup() }
    let meeting = try await TranscriptMeetingFixture.make(in: fixture)
    let id = meeting.meetingID
    let setOpen = { (state: String, segments: String) async throws in
      try await fixture.history.database.write { db in
        try db.execute(
          sql: "UPDATE meetings SET state=? WHERE id=?", arguments: [state, id.uuidString])
        try db.execute(
          sql: """
            UPDATE meeting_segments SET state=? WHERE sequence=2 AND track_id IN
              (SELECT id FROM meeting_tracks WHERE meeting_id=?)
            """, arguments: [segments, id.uuidString])
      }
    }
    try await setOpen("recording", "open")
    let handoff = MeetingHandoff(
      pool: RemoteChannelPool(open: { throw RemoteChannelError.unreachable }),
      database: fixture.history.database, root: fixture.root,
      eligible: { _ in true }, defaultLanguage: { .defaultLanguage })
    let directory = fixture.directory.appendingPathComponent("handoff")
    let bundle = directory.appendingPathComponent("bundle.sqlite")
    let refused = try await handoff.export(id, to: bundle)
    XCTAssertFalse(refused, "a recording meeting goes up only as a live export")
    let exported = try await handoff.export(id, to: bundle, recording: true)
    XCTAssertTrue(exported)

    let remote = try TranscriptionStore(path: bundle.path)
    let transcripts = TranscriptStore(database: remote.database)
    let finalizer = MeetingFinalizer(
      store: transcripts, meetings: MeetingStore(history: remote, root: fixture.root),
      storageRoot: fixture.root,
      lifecycle: ModelLifecycleCoordinator { FakeTranscriptionRuntime() },
      vocabulary: EmptyVocabularyProvider(), clock: FakeMeetingClock())
    let rowValue = try await transcripts.transcription(meetingID: id)
    let partial = try await finalizer.run(
      meetingID: id, revision: try XCTUnwrap(rowValue).revision, partial: true)
    XCTAssertEqual(partial.row.state, .finalizing)
    XCTAssertEqual(partial.row.progressSequence, 1)
    let partialRows = partial.row.segmentCount
    XCTAssertGreaterThan(partialRows, 0)

    // Stop on the phone; its newer rows replace the bundle's.
    try await setOpen("completed", "finalized")
    let rows = directory.appendingPathComponent("rows.sqlite")
    try await handoff.exportRows(id, to: rows)
    try await handoff.exportRows(id, to: rows)
    try await MeetingHandoff.importRows(from: rows, into: remote.database)
    try await remote.database.read { db in
      XCTAssertEqual(
        try String.fetchOne(
          db, sql: "SELECT state FROM meetings WHERE id=?", arguments: [id.uuidString]),
        "completed")
      XCTAssertEqual(
        try Int.fetchOne(
          db, sql: "SELECT COUNT(*) FROM meeting_segments WHERE state='finalized'"), 4)
      XCTAssertEqual(
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM transcript_segments"), partialRows,
        "replacing the meeting row cascades to nothing")
      XCTAssertEqual(try Int.fetchOne(db, sql: "PRAGMA foreign_keys"), 1)
    }
    let final = try await finalizer.run(meetingID: id, revision: partial.row.revision)
    XCTAssertEqual(final.row.state, .final)
    XCTAssertEqual(final.row.passID, partial.row.passID)
    XCTAssertGreaterThan(final.row.segmentCount, partialRows)
  }
}
