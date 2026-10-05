import Foundation
import GRDB
import XCTest
import os

@testable import LocalFlow
@testable import LocalFlowCore

/// T045: the meeting detail (User Story 5). Playing from a line starts in the segment that
/// holds it, speaker and meeting renames persist, Copy gives plain text, and Delete removes
/// files and rows and sends `delete` for a server copy, now or with the next connection.
@MainActor
final class MeetingDetailViewModelTests: XCTestCase {
  private var harness: MeetingHarness!
  private var server: FakeHandoffServer!
  private var player: FakeMeetingLinePlayer!
  private var pasteboard: FakePasteboard!
  private var busy = false
  private let gate = OSAllocatedUnfairLock(initialState: MeetingUploader.Gate.open())
  private let summary = OSAllocatedUnfairLock(initialState: MeetingSummarizer.Outcome.adopted)

  override func setUp() async throws {
    // About 17 s per segment, so a 40 s meeting has three.
    harness = try MeetingHarness(limits: .init(segmentFrames: 800))
    server = FakeHandoffServer()
    player = FakeMeetingLinePlayer()
    pasteboard = FakePasteboard()
    busy = false
  }

  override func tearDown() async throws {
    harness = nil
    server = nil
    player = nil
    pasteboard = nil
  }

  private func model(_ id: UUID) -> MeetingDetailViewModel {
    MeetingDetailViewModel(
      meetingID: id, store: harness.store, root: harness.root, uploads: MeetingUploadStatus(),
      player: player, pasteboard: pasteboard, audioBusy: { [unowned self] in busy },
      delete: { [harness] in await harness!.coordinator.delete($0) },
      now: { [clock = harness.clock] in clock.nowMilliseconds })
  }

  private func uploader() -> MeetingUploader {
    let database = harness.phone.history.database
    let pool = RemoteChannelPool(open: { throw RemoteChannelError.unreachable })
    let clock = harness.clock
    return MeetingUploader(
      database: database, root: harness.root,
      handoff: MeetingHandoff(
        pool: pool, database: database, root: harness.root, eligible: { _ in false },
        defaultLanguage: { .automatic }),
      channel: server, gate: { [gate] in gate.withLock { $0 } },
      summarize: { [summary] _ in summary.withLock { $0 } }, now: { clock.nowMilliseconds })
  }

  /// A stopped meeting with `seconds` of audio.
  private func record(seconds: Double = 40) async throws -> UUID {
    await harness.coordinator.start()
    let id = try XCTUnwrap(harness.coordinator.meetingID)
    harness.engine.feed(seconds: seconds, into: harness.recorder)
    await harness.coordinator.stop()
    try await harness.assertState(id, .completed)
    harness.clock.advance(ms: 60_000)
    return id
  }

  private func count(_ sql: String, _ id: UUID) throws -> Int {
    try harness.rows(sql, [id.uuidString]).first?[0] ?? 0
  }

  private func pendingDeletes() throws -> [String] {
    try harness.rows("SELECT meeting_id FROM phone_meeting_server_deletes").map { $0[0] }
  }

  /// A final transcript of three lines by two speakers, "Speaker 1" saying the first and
  /// last, as the server's diarization leaves it.
  @discardableResult
  private func transcript(_ id: UUID) async throws -> [UUID] {
    let pass = UUID().uuidString
    let run = UUID().uuidString
    let speakers = [UUID(), UUID()]
    let segments = [UUID(), UUID(), UUID()]
    let texts = ["We ship on Friday.", "Anna writes the notes.", "Then we are done."]
    try await harness.phone.history.database.write { db in
      for (index, text) in texts.enumerated() {
        try db.execute(
          sql: """
            INSERT INTO transcript_segments(id,meeting_id,pass_id,finality,ordinal,stretch_sequence,
              start_ms,end_ms,window_index,timing_basis,raw_text,assembled_text,normalized_text,
              engine,model_id,model_revision,pipeline_version,analysis_tracks,created_at)
            VALUES(?,?,?,'final',?,1,?,?,0,'window',?,?,?,'FluidAudio','m','r','p','mic',1)
            """,
          arguments: [
            segments[index].uuidString, id.uuidString, pass, index, index * 2_000,
            index * 2_000 + 1_900, text, text, text,
          ])
      }
      try db.execute(
        sql: """
          UPDATE meeting_transcriptions SET state='final', pass_id=?, pass_kind='final',
            segment_count=3, text_bytes=200, covered_ms=6000, finalized_at=1 WHERE meeting_id=?
          """, arguments: [pass, id.uuidString])
      try db.execute(
        sql: """
          INSERT INTO diarization_runs(id,meeting_id,transcript_pass_id,state,"trigger",in_room,
            engine,model_id,model_revision,model_manifest_hash,pipeline_version,created_at)
          VALUES(?,?,?,'succeeded','automatic',0,'e','m','r',?,'p',1)
          """, arguments: [run, id.uuidString, pass, String(repeating: "a", count: 64)])
      try db.execute(
        sql: """
          INSERT INTO meeting_diarization(meeting_id,accepted_run_id,updated_at) VALUES(?,?,1)
          ON CONFLICT(meeting_id) DO UPDATE SET accepted_run_id=excluded.accepted_run_id
          """, arguments: [id.uuidString, run])
      for (index, speaker) in speakers.enumerated() {
        try db.execute(
          sql: """
            INSERT INTO meeting_speakers(id,meeting_id,run_id,cluster_key,source,track,origin,
              label_ordinal,color_index) VALUES(?,?,?,?,'remote','microphone','engine',?,?)
            """,
          arguments: [speaker.uuidString, id.uuidString, run, index, index + 1, index])
      }
      for (segment, speaker) in zip(segments, [speakers[0], speakers[1], speakers[0]]) {
        try db.execute(
          sql: """
            INSERT INTO speaker_assignments(run_id,segment_id,auto_kind,auto_speaker_id)
            VALUES(?,?,'speaker',?)
            """, arguments: [run, segment.uuidString, speaker.uuidString])
      }
    }
    return speakers
  }

  private func line(at ms: Int64) -> MeetingDetailContent.Line {
    .init(id: UUID(), speaker: nil, startMs: ms, text: "")
  }

  // MARK: Playback

  func testPlayingFromALineStartsInTheSegmentThatHoldsIt() async throws {
    let id = try await record()
    let segments = try harness.segments(id)
    XCTAssertEqual(segments.count, 3)
    let urls = try segments.map {
      try XCTUnwrap(harness.root.resolve(relativePath: $0["relative_path"]))
    }
    let second: Int64 = segments[1]["start_offset_ms"]
    XCTAssertGreaterThan(second, 0)
    let model = model(id)

    await model.play(from: line(at: 0))
    XCTAssertEqual(player.plays.last?.urls, urls)
    XCTAssertEqual(player.plays.last?.offsetMs, 0)

    await model.play(from: line(at: second + 1_234))
    XCTAssertEqual(player.plays.last?.urls, Array(urls[1...]))
    XCTAssertEqual(player.plays.last?.offsetMs, 1_234)

    let third: Int64 = segments[2]["start_offset_ms"]
    let thirdLine = line(at: third + 500)
    await model.play(from: thirdLine)
    XCTAssertEqual(player.plays.last?.urls, [urls[2]])
    XCTAssertEqual(player.plays.last?.offsetMs, 500)
    XCTAssertEqual(model.playingLineID, thirdLine.id)

    // A second tap on the playing line stops; the end of the audio clears it too.
    let stops = player.stops
    await model.play(from: thirdLine)
    XCTAssertNil(model.playingLineID)
    XCTAssertEqual(player.stops, stops + 1)
    await model.play(from: thirdLine)
    player.finish()
    XCTAssertNil(model.playingLineID)
  }

  func testNoPlaybackWhileTheMicrophoneIsInUse() async throws {
    let id = try await record(seconds: 10)
    busy = true
    let model = model(id)
    await model.play(from: line(at: 0))
    XCTAssertTrue(player.plays.isEmpty)
    XCTAssertEqual(model.error, MeetingDetailViewModel.busy)
  }

  // MARK: Renaming

  func testRenamingASpeakerChangesEveryLineAndPersists() async throws {
    let id = try await record(seconds: 10)
    let speakers = try await transcript(id)
    let model = model(id)
    await model.load()
    XCTAssertEqual(model.content.lines.map(\.speaker), ["Speaker 1", "Speaker 2", "Speaker 1"])
    XCTAssertEqual(model.content.speakers.map(\.id), speakers)

    await model.rename(speaker: speakers[0], to: "  Anna ")
    XCTAssertEqual(model.content.lines.map(\.speaker), ["Anna", "Speaker 2", "Anna"])
    let reopened = self.model(id)
    await reopened.load()
    XCTAssertEqual(reopened.content.lines.map(\.speaker), ["Anna", "Speaker 2", "Anna"])

    // A blank name goes back to the label; a name over 80 characters is refused.
    await model.rename(speaker: speakers[0], to: " ")
    XCTAssertEqual(model.content.lines.first?.speaker, "Speaker 1")
    await model.rename(speaker: speakers[1], to: String(repeating: "x", count: 81))
    XCTAssertEqual(model.error, MeetingDetailViewModel.speakerNameInvalid)
    XCTAssertEqual(model.content.lines[1].speaker, "Speaker 2")
  }

  func testRenamingTheMeeting() async throws {
    let id = try await record(seconds: 10)
    let model = model(id)
    var changes = 0
    model.onChange = { changes += 1 }
    await model.load()
    let fallback = model.content.title
    await model.rename(title: "Planning")
    XCTAssertEqual(model.content.title, "Planning")
    let stored = try await harness.store.meeting(id: id)?.title
    XCTAssertEqual(stored, "Planning")
    XCTAssertEqual(changes, 1)
    await model.rename(title: "")
    XCTAssertEqual(model.content.title, fallback)
  }

  // MARK: Copy and Share

  func testCopyGivesTheSummaryAndTranscriptAsPlainText() async throws {
    let id = try await record(seconds: 10)
    try await transcript(id)
    let model = model(id)
    await model.load()
    await model.rename(title: "Planning")
    let text = model.plainText
    XCTAssertTrue(text.hasPrefix("Planning\n"))
    XCTAssertTrue(text.contains("Transcript\n[00:00] Speaker 1: We ship on Friday.\n"))
    XCTAssertTrue(text.hasSuffix("[00:04] Speaker 1: Then we are done."))
    XCTAssertFalse(text.contains("Summary"), "no summary yet")
    model.copy()
    XCTAssertEqual(pasteboard.string, text)
    XCTAssertTrue(model.copied)
  }

  // MARK: Summary and state

  func testAFailedSummaryOffersRetrySummaryThroughTheQueue() async throws {
    let id = try await record(seconds: 10)
    let uploader = uploader()
    summary.withLock { $0 = .failed(.malformedResponse) }
    _ = await uploader.pass()
    try server.complete(id) {
      try FakeHandoffServer.processed($0, meeting: id, texts: ["Hello there."])
    }
    _ = await uploader.pass()
    let model = model(id)
    model.retrySummary = { id in
      try? await uploader.retrySummary(id)
      _ = await uploader.pass(ignoringBackoff: true)
    }
    await model.load()
    XCTAssertEqual(model.content.upload?.ready, true)
    XCTAssertEqual(model.content.upload?.summaryFailed, true)
    XCTAssertEqual(model.content.lines.map(\.text), ["Hello there."], "the transcript shows")

    summary.withLock { $0 = .adopted }
    await model.retrySummary(id)
    await model.load()
    XCTAssertEqual(model.content.upload?.ready, true)
    XCTAssertEqual(model.content.upload?.summaryFailed, false)
  }

  func testARecoveredMeetingStaysMarkedAfterItEntersTheQueue() async throws {
    let id = try await record(seconds: 10)
    try await harness.phone.history.database.write { db in
      try db.execute(
        sql: "UPDATE meetings SET state='interrupted' WHERE id=?", arguments: [id.uuidString])
    }
    var item = MeetingsViewModel.Item(
      id: id, title: "", date: .now, durationMs: 0, state: .interrupted)
    XCTAssertEqual(item.label, "Recovered")
    gate.withLock { $0 = .closed(MeetingUploader.Detail.processingOff) }
    _ = await uploader().pass()
    item.upload = try await harness.phone.history.database.read {
      try MeetingUploadLine.fetch([id], db: $0)[id]
    }
    XCTAssertEqual(item.label, "Recovered · Waiting for server (processing is off)")
    let model = model(id)
    await model.load()
    XCTAssertEqual(model.content.state, .interrupted, "the detail shows Recovered too")
    item.upload = MeetingUploadLine(stage: .ready, detail: nil, serverProgress: nil)
    XCTAssertEqual(item.label, "Recovered · Ready")
  }

  // MARK: Deleting

  func testDeleteRemovesFilesRowsAndTheServerCopy() async throws {
    let id = try await record()
    let uploader = uploader()
    _ = await uploader.pass()
    XCTAssertNotNil(server.stored[id], "uploaded and processing")
    let folder = harness.root.meetingDirectory(id)
    XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path))
    let revision = harness.coordinator.revision

    let model = model(id)
    let deleted = await model.delete()
    XCTAssertTrue(deleted)
    XCTAssertTrue(model.deleted)
    XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
    XCTAssertEqual(try count("SELECT count(*) FROM meetings WHERE id=?", id), 0)
    XCTAssertEqual(
      try count(
        "SELECT count(*) FROM meeting_segments WHERE track_id IN (SELECT id FROM meeting_tracks WHERE meeting_id=?)",
        id), 0)
    XCTAssertEqual(
      try count("SELECT count(*) FROM phone_meeting_uploads WHERE meeting_id=?", id), 0)
    XCTAssertEqual(try pendingDeletes(), [id.uuidString])
    XCTAssertGreaterThan(harness.coordinator.revision, revision)

    server.clearLog()
    _ = await uploader.pass()
    XCTAssertNil(server.stored[id])
    XCTAssertEqual(server.requests.map(\.action), [.delete])
    XCTAssertEqual(try pendingDeletes(), [])
  }

  func testTheServerDeleteWaitsForTheNextConnection() async throws {
    let id = try await record()
    let uploader = uploader()
    _ = await uploader.pass()
    let deleted = await model(id).delete()
    XCTAssertTrue(deleted)

    gate.withLock { $0 = .closed(MeetingUploader.Detail.processingOff) }
    server.clearLog()
    let closed = await uploader.pass()
    XCTAssertNil(closed, "a closed gate waits for a kick")
    XCTAssertTrue(server.requests.isEmpty)
    gate.withLock { $0 = .open() }
    server.unreachable = true
    let offline = await uploader.pass()
    XCTAssertNotNil(offline, "an unreachable server is tried again")
    XCTAssertNotNil(server.stored[id])
    XCTAssertEqual(try pendingDeletes(), [id.uuidString])

    server.unreachable = false
    _ = await uploader.pass()
    XCTAssertNil(server.stored[id])
    XCTAssertEqual(try pendingDeletes(), [])
  }

  func testAMeetingNeverSentDeletesNothingOnTheServer() async throws {
    let id = try await record(seconds: 10)
    let deleted = await model(id).delete()
    XCTAssertTrue(deleted)
    XCTAssertEqual(try count("SELECT count(*) FROM meetings WHERE id=?", id), 0)
    XCTAssertEqual(try pendingDeletes(), [])
    _ = await uploader().pass()
    XCTAssertTrue(server.requests.isEmpty)
  }

  func testAReadyMeetingSendsDeleteOnlyWhileTheServerKeepsItForTheMac() async throws {
    for copy in [true, false] {
      server = FakeHandoffServer()
      gate.withLock { $0 = .open(copyToMac: copy) }
      let id = try await record(seconds: 10)
      let uploader = uploader()
      _ = await uploader.pass()
      try server.complete(id) {
        try FakeHandoffServer.processed($0, meeting: id, texts: ["Hello there."])
      }
      _ = await uploader.pass()
      XCTAssertEqual(
        try harness.rows(
          "SELECT stage FROM phone_meeting_uploads WHERE meeting_id=?", [id.uuidString]
        )
        .first?["stage"] as String?, "ready")
      XCTAssertEqual(server.stored[id] != nil, copy, "kept for the Mac only with the copy")
      let deleted = await model(id).delete()
      XCTAssertTrue(deleted)
      XCTAssertEqual(try pendingDeletes(), copy ? [id.uuidString] : [])
      _ = await uploader.pass()
      XCTAssertNil(server.stored[id])
      XCTAssertEqual(try pendingDeletes(), [])
    }
  }

  func testTheRecordingMeetingCannotBeDeleted() async throws {
    await harness.coordinator.start()
    let id = try XCTUnwrap(harness.coordinator.meetingID)
    let model = model(id)
    let deleted = await model.delete()
    XCTAssertFalse(deleted)
    XCTAssertEqual(model.error, PhoneMeetingCoordinator.deleteWhileRecording)
    try await harness.assertState(id, .recording)
    await harness.coordinator.stop()
  }
}
