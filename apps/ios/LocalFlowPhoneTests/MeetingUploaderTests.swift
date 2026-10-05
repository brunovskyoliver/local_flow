import Foundation
import GRDB
import XCTest
import os

@testable import LocalFlow
@testable import LocalFlowCore

/// T030: the server queue against `FakeHandoffServer`. Waits with the right reason,
/// resumes from the server's size, never resends a confirmed segment, one meeting at a
/// time, backoff, an all-or-nothing merge, release after merge, Retry, and a meeting the
/// server lost is sent again.
@MainActor
final class MeetingUploaderTests: XCTestCase {
  private var harness: MeetingHarness!
  private var server: FakeHandoffServer!
  private let gate = OSAllocatedUnfairLock(initialState: MeetingUploader.Gate.open())
  private let summaries = OSAllocatedUnfairLock(initialState: [UUID]())
  private let summary = OSAllocatedUnfairLock(initialState: MeetingSummarizer.Outcome.adopted)

  override func setUp() async throws {
    // About 17 s per segment: more than one 48,000-byte chunk each.
    harness = try MeetingHarness(limits: .init(segmentFrames: 800))
    server = FakeHandoffServer()
  }

  override func tearDown() async throws {
    harness = nil
    server = nil
  }

  private let events = OSAllocatedUnfairLock(initialState: [MeetingUploader.Event]())

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
      summarize: { [summaries, summary] id in
        summaries.withLock { $0.append(id) }
        return summary.withLock { $0 }
      },
      now: { clock.nowMilliseconds },
      onChange: { [events] event in events.withLock { $0.append(event) } })
  }

  /// A stopped meeting with `seconds` of audio.
  private func record(seconds: Double = 20) async throws -> UUID {
    await harness.coordinator.start()
    let id = try XCTUnwrap(harness.coordinator.meetingID)
    harness.engine.feed(seconds: seconds, into: harness.recorder)
    await harness.coordinator.stop()
    try await harness.assertState(id, .completed)
    harness.clock.advance(ms: 60_000)
    return id
  }

  private func row(_ id: UUID) throws -> Row? {
    try harness.rows("SELECT * FROM phone_meeting_uploads WHERE meeting_id=?", [id.uuidString])
      .first
  }

  private func stage(_ id: UUID) throws -> String? { try row(id)?["stage"] }
  private func detail(_ id: UUID) throws -> String? { try row(id)?["detail"] }

  private func segmentPaths(_ id: UUID) throws -> [String] {
    try harness.segments(id).map { $0["relative_path"] as String }
  }

  private func segmentNames(_ id: UUID) throws -> [String] {
    try segmentPaths(id).map { URL(fileURLWithPath: $0).lastPathComponent }
  }

  private func local(_ path: String) throws -> Data {
    try Data(contentsOf: XCTUnwrap(harness.root.resolve(relativePath: path)))
  }

  private func puts(_ name: String) -> [RemoteHandoffRequest] {
    server.requests.filter { $0.action == .put && $0.name == name }
  }

  private func finalSegments(_ id: UUID) throws -> Int {
    try harness.rows(
      "SELECT count(*) AS n FROM transcript_segments WHERE meeting_id=? AND finality='final'",
      [id.uuidString]
    ).first?["n"] ?? 0
  }

  private func complete(_ id: UUID, final: Bool = true) throws {
    try server.complete(id) {
      try FakeHandoffServer.processed(
        $0, meeting: id, texts: ["We agreed to ship on Friday.", "Anna writes the notes."],
        final: final)
    }
  }

  // MARK: Waiting

  func testWaitsWithTheReasonAndSendsNothingWhileTheGateIsClosed() async throws {
    let id = try await record()
    let uploader = uploader()
    for reason in ["not_signed_in", "pending", "revoked", "processing_off", "identity_changed"] {
      gate.withLock { $0 = .closed(reason) }
      let next = await uploader.pass()
      XCTAssertNil(next, "a closed gate waits for a kick")
      XCTAssertEqual(try stage(id), "waiting")
      XCTAssertEqual(try detail(id), reason)
    }
    XCTAssertTrue(server.requests.isEmpty)
    XCTAssertEqual(try row(id)?["attempts"] as Int?, 0)
  }

  func testServerAnswersBecomeReasons() async throws {
    let id = try await record()
    let uploader = uploader()
    let cases: [(FakeHandoffServer) -> Void] = [
      { $0.unreachable = true }, { $0.refuse = .busy }, { $0.refuse = .notOffered },
      { $0.refuse = .revoked }, { $0.maximumMeetings = 0 },
    ]
    let expected = ["unreachable", "server_busy", "server_outdated", "revoked", "server_limit"]
    for (setUp, reason) in zip(cases, expected) {
      server = FakeHandoffServer()
      setUp(server)
      let fresh = self.uploader()
      _ = await fresh.pass(ignoringBackoff: true)
      XCTAssertEqual(try stage(id), "waiting", reason)
      XCTAssertEqual(try detail(id), reason)
    }
    _ = uploader
    XCTAssertEqual(try row(id)?["attempts"] as Int?, expected.count)
  }

  // MARK: The whole way

  func testUploadProcessMergeSummaryRelease() async throws {
    let id = try await record(seconds: 40)
    let paths = try segmentPaths(id)
    XCTAssertEqual(paths.count, 3)
    let uploader = uploader()

    let next = await uploader.pass()
    XCTAssertEqual(next, MeetingUploader.pollInterval)
    XCTAssertEqual(try stage(id), "processing")
    let stored = try XCTUnwrap(server.stored[id])
    XCTAssertEqual(stored.state, .queued)
    XCTAssertTrue(stored.copy, "Copy meetings to my Mac is on by default")
    for path in paths {
      XCTAssertEqual(stored.files[URL(fileURLWithPath: path).lastPathComponent], try local(path))
    }
    XCTAssertEqual(try row(id)?["bundle_uploaded"] as Bool?, true)
    XCTAssertEqual(try row(id)?["copy_to_mac"] as Bool?, true)

    server.setState(id, .processing, progress: 40)
    _ = await uploader.pass()
    XCTAssertEqual(try row(id)?["server_progress"] as Int?, 40)

    try complete(id)
    server.clearLog()
    let done = await uploader.pass()
    XCTAssertNil(done)
    XCTAssertEqual(try stage(id), "ready")
    XCTAssertEqual(try finalSegments(id), 2)
    XCTAssertEqual(summaries.withLock { $0 }, [id])
    // Release comes after the result is merged and before the summary.
    let actions = server.requests.map(\.action)
    XCTAssertEqual(actions.last, .release)
    XCTAssertLessThan(actions.lastIndex(of: .get)!, actions.lastIndex(of: .release)!)
    XCTAssertNotNil(try row(id)?["released_at"] as Int64?)
    XCTAssertEqual(try row(id)?["mac_copy"] as String?, "waiting")
    let handoff = harness.phone.root.appendingPathComponent("Handoff/\(id.uuidString)")
    XCTAssertFalse(FileManager.default.fileExists(atPath: handoff.path))
    // A ready meeting only has its Mac copy looked up.
    server.clearLog()
    _ = await uploader.pass()
    XCTAssertEqual(server.requests.map(\.action), [.list])
  }

  func testWithoutTheMacCopyTheServerCopyIsDeleted() async throws {
    let id = try await record()
    gate.withLock { $0 = .open(copyToMac: false) }
    let uploader = uploader()
    _ = await uploader.pass()
    XCTAssertEqual(server.stored[id]?.copy, false)
    try complete(id)
    _ = await uploader.pass()
    XCTAssertEqual(try stage(id), "ready")
    XCTAssertNil(server.stored[id])
    XCTAssertEqual(try row(id)?["mac_copy"] as String?, "none")
  }

  // MARK: Mac copy (User Story 6)

  /// A ready meeting with its copy released.
  private func readyWithMacCopy(_ uploader: MeetingUploader) async throws -> UUID {
    let id = try await record()
    _ = await uploader.pass()
    try complete(id)
    _ = await uploader.pass()
    XCTAssertEqual(try stage(id), "ready")
    XCTAssertEqual(try row(id)?["mac_copy"] as String?, "waiting")
    XCTAssertEqual(server.stored[id]?.released, true)
    XCTAssertEqual(server.stored[id]?.state, .done)
    return id
  }

  private func line(_ id: UUID) throws -> MeetingUploadLine? {
    try harness.phone.history.database.read { try MeetingUploadLine.fetch([id], db: $0)[id] }
  }

  func testMacCopyWaitsUntilTheMacTakesItThenShowsDelivered() async throws {
    let uploader = uploader()
    let id = try await readyWithMacCopy(uploader)
    XCTAssertEqual(try line(id)?.macCopyText, "Waiting for Mac")
    // Still on the server: still waiting.
    harness.clock.advance(ms: 3_600_000)
    _ = await uploader.pass()
    XCTAssertEqual(try row(id)?["mac_copy"] as String?, "waiting")
    // The Mac imported it and deleted the server copy.
    server.drop(id)
    _ = await uploader.pass()
    XCTAssertEqual(try row(id)?["mac_copy"] as String?, "delivered")
    XCTAssertEqual(try line(id)?.macCopyText, "Sent to Mac")
    XCTAssertEqual(try line(id)?.canSendToMacAgain, false)
    server.clearLog()
    _ = await uploader.pass()
    XCTAssertTrue(server.requests.isEmpty, "a delivered copy is not looked up again")
  }

  func testMacCopyExpiresAndSendToMacAgainUploadsItForTheMacOnly() async throws {
    let uploader = uploader()
    let id = try await readyWithMacCopy(uploader)
    // Nobody took it for longer than the server keeps it.
    harness.clock.advance(ms: MeetingUploader.macCopyRetentionMilliseconds + 60_000)
    server.drop(id)
    _ = await uploader.pass()
    XCTAssertEqual(try row(id)?["mac_copy"] as String?, "expired")
    XCTAssertEqual(try line(id)?.macCopyText, "Not delivered to Mac")
    XCTAssertEqual(try line(id)?.canSendToMacAgain, true)

    // The setting is off now; Send to Mac again still asks for the copy.
    gate.withLock { $0 = .open(copyToMac: false) }
    try await uploader.sendToMacAgain(id)
    XCTAssertEqual(try line(id)?.ready, true, "the phone keeps showing its result")
    XCTAssertEqual(try line(id)?.text, "Ready")
    server.clearLog()
    _ = await uploader.pass(ignoringBackoff: true)
    XCTAssertEqual(try stage(id), "processing")
    let stored = try XCTUnwrap(server.stored[id])
    XCTAssertTrue(stored.copy)
    XCTAssertTrue(server.requests.contains { $0.action == .start && $0.copy })
    for path in try segmentPaths(id) {
      XCTAssertEqual(stored.files[URL(fileURLWithPath: path).lastPathComponent], try local(path))
    }
    // The bundle carries the recording, not the phone's transcript.
    let bundle = FileManager.default.temporaryDirectory.appendingPathComponent(
      "again-\(UUID().uuidString).sqlite")
    defer { try? FileManager.default.removeItem(at: bundle) }
    try XCTUnwrap(stored.files["bundle.sqlite"]).write(to: bundle)
    let queue = try DatabaseQueue(path: bundle.path)
    try await queue.read { db in
      XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM meetings"), 1)
      XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM transcript_segments"), 0)
      XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM meeting_transcriptions"), 0)
    }
    try queue.close()

    // Processed for the Mac: released, never downloaded or merged here.
    try server.complete(id) {
      try FakeHandoffServer.processed(
        $0, meeting: id, texts: ["Something else entirely."], final: true)
    }
    server.clearLog()
    _ = await uploader.pass()
    XCTAssertFalse(server.requests.contains { $0.action == .get })
    XCTAssertEqual(server.requests.filter { $0.action == .release }.count, 1)
    XCTAssertEqual(try stage(id), "ready")
    XCTAssertEqual(try row(id)?["mac_copy"] as String?, "waiting")
    XCTAssertNotNil(try row(id)?["released_at"] as Int64?)
    XCTAssertEqual(try finalSegments(id), 2, "the phone's transcript is untouched")
    XCTAssertEqual(server.stored[id]?.released, true)
    XCTAssertEqual(summaries.withLock { $0 }, [id], "summarized once, the first time")
  }

  func testAFailedSendToMacAgainLeavesTheMeetingReadyAndNotDelivered() async throws {
    let uploader = uploader()
    let id = try await readyWithMacCopy(uploader)
    harness.clock.advance(ms: MeetingUploader.macCopyRetentionMilliseconds + 60_000)
    server.drop(id)
    _ = await uploader.pass()
    try await uploader.sendToMacAgain(id)
    _ = await uploader.pass(ignoringBackoff: true)
    XCTAssertEqual(try stage(id), "processing")
    server.setState(id, .failed, detail: "exit_70")
    _ = await uploader.pass()
    XCTAssertEqual(try stage(id), "ready")
    XCTAssertEqual(try row(id)?["mac_copy"] as String?, "expired")
    XCTAssertNil(server.stored[id], "the failed copy goes")
    XCTAssertEqual(try finalSegments(id), 2)
  }

  // MARK: Resume

  func testResumesFromTheServerSizeAndNeverResendsAConfirmedSegment() async throws {
    let id = try await record(seconds: 40)
    let paths = try segmentPaths(id)
    let names = try segmentNames(id)
    XCTAssertGreaterThan(try local(paths[1]).count, MeetingHandoff.chunkBytes)
    let uploader = uploader()
    // The network goes after the second file's first chunk.
    server.failWhen = { [names] in
      $0.name == names[1] && ($0.offset ?? 0) > 0 ? .unreachable : nil
    }
    let next = await uploader.pass()
    XCTAssertEqual(next, .seconds(60))
    XCTAssertEqual(try stage(id), "waiting")
    XCTAssertEqual(try detail(id), "unreachable")
    XCTAssertEqual(try row(id)?["confirmed_segments"] as String?, paths[0])
    let partial = try XCTUnwrap(server.stored[id]?.files[names[1]])
    XCTAssertEqual(partial.count, MeetingHandoff.chunkBytes)

    server.clearLog()
    harness.clock.advance(ms: 60_000)
    _ = await uploader.pass()
    XCTAssertEqual(try stage(id), "processing")
    XCTAssertTrue(puts(names[0]).isEmpty, "a confirmed segment is not sent again")
    let resumed = puts(names[1]).filter { $0.data != nil }
    XCTAssertEqual(resumed.first?.offset, MeetingHandoff.chunkBytes)
    let second = try local(paths[1])
    XCTAssertEqual(
      resumed.reduce(0) { $0 + ($1.data?.count ?? 0) }, second.count - MeetingHandoff.chunkBytes)
    XCTAssertEqual(server.stored[id]?.files[names[1]], second)
  }

  func testBackoffWaitsBeforeTheNextAttempt() async throws {
    let id = try await record()
    server.unreachable = true
    let uploader = uploader()
    let first = await uploader.pass()
    XCTAssertEqual(first, .seconds(60))
    XCTAssertEqual(try row(id)?["attempts"] as Int?, 1)
    server.clearLog()
    harness.clock.advance(ms: 59_000)
    let early = await uploader.pass()
    XCTAssertEqual(early, .seconds(1))
    XCTAssertTrue(server.requests.isEmpty)
    harness.clock.advance(ms: 1_000)
    let second = await uploader.pass()
    XCTAssertEqual(second, .seconds(120))
    XCTAssertFalse(server.requests.isEmpty)
    XCTAssertEqual(try row(id)?["attempts"] as Int?, 2)
    // A kick (foreground, Stop) does not wait.
    server.clearLog()
    _ = await uploader.pass(ignoringBackoff: true)
    XCTAssertFalse(server.requests.isEmpty)
    XCTAssertEqual(MeetingUploader.backoffMilliseconds(attempts: 0), 30_000)
    XCTAssertEqual(MeetingUploader.backoffMilliseconds(attempts: 4), 480_000)
    XCTAssertEqual(MeetingUploader.backoffMilliseconds(attempts: 9), 600_000)
  }

  // MARK: Queue order

  func testOneMeetingAtATimeOldestFirst() async throws {
    let older = try await record(seconds: 3)
    let newer = try await record(seconds: 3)
    let uploader = uploader()
    _ = await uploader.pass()
    XCTAssertEqual(try stage(older), "processing")
    XCTAssertEqual(try stage(newer), "waiting")
    XCTAssertTrue(server.requests.allSatisfy { $0.meeting == nil || $0.meeting == older })

    try complete(older)
    _ = await uploader.pass()
    XCTAssertEqual(try stage(older), "ready")
    XCTAssertEqual(try stage(newer), "processing")
  }

  // MARK: Result

  func testABadChecksumIsDownloadedAgain() async throws {
    let id = try await record(seconds: 3)
    let uploader = uploader()
    _ = await uploader.pass()
    try complete(id)
    server.corruptNextGets(1)
    _ = await uploader.pass()
    XCTAssertEqual(try stage(id), "ready")
    XCTAssertEqual(try finalSegments(id), 2)
  }

  func testAResultThatDoesNotMergeLeavesNothingAndFails() async throws {
    let id = try await record(seconds: 3)
    let uploader = uploader()
    _ = await uploader.pass()
    try complete(id, final: false)
    _ = await uploader.pass()
    XCTAssertEqual(try stage(id), "failed")
    XCTAssertEqual(try detail(id), "merge_failed")
    XCTAssertEqual(try finalSegments(id), 0)
    XCTAssertNotEqual(
      try harness.rows(
        "SELECT state FROM meeting_transcriptions WHERE meeting_id=?", [id.uuidString]
      ).first?["state"] as String?, "final")
    XCTAssertEqual(server.requests.filter { $0.action == .get && $0.offset == 0 }.count, 2)
    XCTAssertTrue(summaries.withLock { $0 }.isEmpty)
    XCTAssertNotNil(server.stored[id], "nothing released")
    // The recording is untouched.
    XCTAssertEqual(try segmentNames(id).count, 1)
  }

  // MARK: Failure and Retry

  func testAServerFailureShowsFailedAndRetrySendsItAgain() async throws {
    let id = try await record(seconds: 3)
    let name = try XCTUnwrap(segmentNames(id).first)
    let uploader = uploader()
    _ = await uploader.pass()
    server.setState(id, .failed, detail: "processor_failed")
    _ = await uploader.pass()
    XCTAssertEqual(try stage(id), "failed")
    XCTAssertEqual(try detail(id), "processor_failed")
    // Failed stays failed until Retry.
    server.clearLog()
    _ = await uploader.pass(ignoringBackoff: true)
    XCTAssertTrue(server.requests.isEmpty)

    try await uploader.retry(id)
    XCTAssertEqual(try stage(id), "waiting")
    _ = await uploader.pass()
    XCTAssertEqual(try stage(id), "processing")
    XCTAssertTrue(server.requests.contains { $0.action == .delete })
    XCTAssertEqual(puts(name).first(where: { $0.data != nil })?.offset, 0)
    XCTAssertEqual(server.stored[id]?.state, .queued)
  }

  func testAMeetingTheServerLostIsUploadedAgain() async throws {
    let id = try await record(seconds: 3)
    let name = try XCTUnwrap(segmentNames(id).first)
    let uploader = uploader()
    _ = await uploader.pass()
    XCTAssertEqual(try stage(id), "processing")
    server.drop(id)
    server.clearLog()
    _ = await uploader.pass()
    XCTAssertEqual(try stage(id), "processing")
    XCTAssertFalse(puts(name).filter { $0.data != nil }.isEmpty)
    XCTAssertFalse(puts("bundle.sqlite").filter { $0.data != nil }.isEmpty)
    XCTAssertEqual(server.stored[id]?.state, .queued)
  }

  func testASummaryThatCannotReachTheServerWaits() async throws {
    let id = try await record(seconds: 3)
    summary.withLock { $0 = .waiting }
    let uploader = uploader()
    _ = await uploader.pass()
    try complete(id)
    let next = await uploader.pass()
    XCTAssertEqual(next, .seconds(60))
    XCTAssertEqual(try stage(id), "summarizing")
    XCTAssertEqual(try finalSegments(id), 2)
    // Signing out now keeps the merged stage: the server's copy is already released.
    gate.withLock { $0 = .closed("not_signed_in") }
    _ = await uploader.pass()
    XCTAssertEqual(try stage(id), "summarizing")
    XCTAssertEqual(try detail(id), "not_signed_in")
    gate.withLock { $0 = .open() }
    summary.withLock { $0 = .adopted }
    server.clearLog()
    _ = await uploader.pass(ignoringBackoff: true)
    XCTAssertEqual(try stage(id), "ready")
    XCTAssertFalse(server.requests.contains { $0.action == .release }, "released once")
  }

  func testOnlyStoppedPhoneMeetingsWithAudioAreQueued() async throws {
    await harness.coordinator.start()
    let recording = try XCTUnwrap(harness.coordinator.meetingID)
    harness.engine.feed(seconds: 3, into: harness.recorder)
    let uploader = uploader()
    _ = await uploader.pass()
    XCTAssertNil(try row(recording))
    await harness.coordinator.stop()
    _ = await uploader.pass()
    XCTAssertEqual(try stage(recording), "processing")
  }

  // MARK: While recording (User Story 3)

  /// Starts a meeting and records until `finished` segments are finalized.
  private func startRecording(finished: Int) async throws -> UUID {
    await harness.coordinator.start()
    let id = try XCTUnwrap(harness.coordinator.meetingID)
    try await keepRecording(id, finished: finished)
    return id
  }

  private func keepRecording(_ id: UUID, finished: Int) async throws {
    while try finishedPaths(id).count < finished {
      harness.engine.feed(seconds: 5, into: harness.recorder)
      try await Task.sleep(for: .milliseconds(20))
    }
  }

  private func finishedPaths(_ id: UUID) throws -> [String] {
    try harness.segments(id).filter { $0["state"] == "finalized" }.map { $0["relative_path"] }
  }

  private func firstIndex(_ matches: (RemoteHandoffRequest) -> Bool) -> Int? {
    server.requests.firstIndex(where: matches)
  }

  /// The meeting row in the stored `rows.sqlite`.
  private func storedRowsState(_ id: UUID) throws -> String? {
    let data = try XCTUnwrap(server.stored[id]?.files["rows.sqlite"])
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
      "rows-\(UUID().uuidString).sqlite")
    defer { try? FileManager.default.removeItem(at: url) }
    try data.write(to: url)
    let queue = try DatabaseQueue(path: url.path)
    defer { try? queue.close() }
    return try queue.read {
      try String.fetchOne($0, sql: "SELECT state FROM meetings WHERE id=?", arguments: [id.uuidString])
    }
  }

  func testFinishedSegmentsGoUpInOrderThenRowsThenAPartialRun() async throws {
    let id = try await startRecording(finished: 2)
    let finished = try finishedPaths(id)
    let names = finished.map { URL(fileURLWithPath: $0).lastPathComponent }
    let uploader = uploader()

    let next = await uploader.pass()
    XCTAssertEqual(next, MeetingUploader.livePollInterval)
    let segment0 = try XCTUnwrap(firstIndex { $0.name == names[0] })
    let segment1 = try XCTUnwrap(firstIndex { $0.name == names[1] })
    let rows = try XCTUnwrap(firstIndex { $0.name == "rows.sqlite" })
    let bundle = try XCTUnwrap(firstIndex { $0.name == "bundle.sqlite" })
    let start = try XCTUnwrap(firstIndex { $0.action == .start })
    XCTAssertLessThan(segment0, segment1)
    XCTAssertLessThan(server.requests.lastIndex { $0.name == names[1] }!, rows)
    XCTAssertLessThan(rows, bundle)
    XCTAssertLessThan(server.requests.lastIndex { $0.name == "bundle.sqlite" }!, start)
    XCTAssertTrue(server.requests[start].partial)
    XCTAssertFalse(server.requests[start].copy)
    let stored = try XCTUnwrap(server.stored[id])
    XCTAssertEqual(stored.state, .queued)
    XCTAssertTrue(stored.partial)
    for path in finished {
      XCTAssertEqual(stored.files[URL(fileURLWithPath: path).lastPathComponent], try local(path))
    }
    XCTAssertEqual(try storedRowsState(id), "recording")
    XCTAssertEqual(try stage(id), "uploading")
    XCTAssertEqual(try row(id)?["confirmed_segments"] as String?, finished.joined(separator: ","))
    XCTAssertEqual(try row(id)?["bundle_uploaded"] as Bool?, true)
    XCTAssertTrue(harness.coordinator.isRecording, "recording goes on")

    // The server is busy with the partial run: nothing is sent, the phone waits.
    server.clearLog()
    _ = await uploader.pass()
    XCTAssertEqual(server.requests.map(\.action), [.list])

    // The run is done: "Transcribed up to" comes back; no new segment, no new run.
    server.finishPartial(id, transcribedMS: 34_000)
    server.clearLog()
    _ = await uploader.pass()
    XCTAssertEqual(server.requests.map(\.action), [.list])
    XCTAssertEqual(try row(id)?["transcribed_ms"] as Int?, 34_000)
    XCTAssertTrue(events.withLock { $0.contains(.transcribed(id, 34_000)) })
    harness.coordinator.transcribed(id, ms: 34_000)
    XCTAssertEqual(harness.coordinator.transcribedMs, 34_000)
    XCTAssertEqual(harness.activity.states.last?.transcribedMs, 34_000)

    // The next finished segment: it, the rows and another partial run; the bundle stays.
    try await keepRecording(id, finished: 3)
    let third = try XCTUnwrap(try finishedPaths(id).last)
    server.clearLog()
    _ = await uploader.pass()
    XCTAssertEqual(
      puts(URL(fileURLWithPath: third).lastPathComponent).last?.sha256,
      FakeHandoffServer.hex(try local(third)))
    XCTAssertTrue(puts("bundle.sqlite").isEmpty, "the bundle goes up once")
    XCTAssertFalse(puts("rows.sqlite").isEmpty)
    XCTAssertEqual(server.stored[id]?.partialRuns, 2)

    // Stop while that run is going: the queue waits for it, then sends what is left.
    await harness.coordinator.stop()
    try await harness.assertState(id, .completed)
    XCTAssertNil(harness.coordinator.transcribedMs)
    _ = await uploader.pass()
    XCTAssertEqual(try stage(id), "processing")
    XCTAssertEqual(server.stored[id]?.partial, true)
    server.finishPartial(id, transcribedMS: 52_000)
    server.clearLog()
    _ = await uploader.pass()
    XCTAssertEqual(try stage(id), "processing")
    let after = try XCTUnwrap(server.stored[id])
    XCTAssertEqual(after.state, .queued)
    XCTAssertFalse(after.partial, "the last start is the final run")
    for path in try segmentPaths(id) {
      XCTAssertEqual(after.files[URL(fileURLWithPath: path).lastPathComponent], try local(path))
    }
    XCTAssertTrue(puts("bundle.sqlite").isEmpty)
    XCTAssertEqual(try storedRowsState(id), "completed", "the rows after Stop")
    XCTAssertLessThan(
      server.requests.lastIndex { $0.name == "rows.sqlite" }!,
      server.requests.lastIndex { $0.action == .start }!)
    try complete(id)
    _ = await uploader.pass()
    XCTAssertEqual(try stage(id), "ready")
  }

  func testLiveUploadCatchesUpAfterADisconnectAndNeverBlocksRecording() async throws {
    let id = try await startRecording(finished: 1)
    server.unreachable = true
    let uploader = uploader()
    _ = await uploader.pass()
    XCTAssertTrue(server.stored.isEmpty)
    try await keepRecording(id, finished: 3)
    _ = await uploader.pass()
    XCTAssertTrue(harness.coordinator.isRecording)
    XCTAssertEqual(try row(id)?["attempts"] as Int?, 0, "no backoff while recording")

    server.unreachable = false
    server.clearLog()
    _ = await uploader.pass()
    let names = try finishedPaths(id).map { URL(fileURLWithPath: $0).lastPathComponent }
    let order = server.requests.filter { $0.action == .put && $0.data != nil }.compactMap(\.name)
      .filter { $0.hasSuffix(".aac") }
    XCTAssertEqual(Array(NSOrderedSet(array: order)) as? [String], names)
    XCTAssertEqual(server.stored[id]?.partialRuns, 1, "one run for everything that caught up")
    XCTAssertEqual(try row(id)?["confirmed_segments"] as String?, try finishedPaths(id).joined(separator: ","))
    await harness.coordinator.stop()
  }

  func testAServerWithoutPartialRunsGetsTheMeetingAfterStop() async throws {
    let id = try await startRecording(finished: 1)
    server.noPartial = true
    let uploader = uploader()
    _ = await uploader.pass()
    XCTAssertNil(server.stored[id]?.files["bundle.sqlite"], "no bundle without a partial run")
    XCTAssertFalse(server.requests.contains { $0.action == .start })
    try await keepRecording(id, finished: 2)
    server.clearLog()
    _ = await uploader.pass()
    XCTAssertFalse(server.requests.contains { $0.name == "rows.sqlite" }, "asked once")

    await harness.coordinator.stop()
    server.clearLog()
    _ = await uploader.pass()
    XCTAssertEqual(try stage(id), "processing")
    XCTAssertEqual(server.stored[id]?.state, .queued)
    XCTAssertFalse(server.requests.contains { $0.name == "rows.sqlite" })
    XCTAssertFalse(puts("bundle.sqlite").filter { $0.data != nil }.isEmpty)
  }
}
