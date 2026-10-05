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
      now: { clock.nowMilliseconds })
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
    // Ready meetings are left alone.
    server.clearLog()
    _ = await uploader.pass()
    XCTAssertTrue(server.requests.isEmpty)
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

  func testAnOlderServerGetsNoCopyAndADelete() async throws {
    let id = try await record()
    server.old = true
    let uploader = uploader()
    _ = await uploader.pass()
    XCTAssertEqual(try stage(id), "processing")
    XCTAssertEqual(try row(id)?["copy_to_mac"] as Bool?, false)
    try complete(id)
    _ = await uploader.pass()
    XCTAssertEqual(try stage(id), "ready")
    XCTAssertNil(server.stored[id])
    XCTAssertEqual(server.requests.last?.action, .delete)
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
}
