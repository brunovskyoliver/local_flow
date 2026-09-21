import Foundation
import XCTest

@testable import LocalFlow

@MainActor
final class MeetingIntelligenceCoordinatorTests: XCTestCase {

  // MARK: T033 / FR-035 — automatic vs manual

  func testFinalizedTranscriptEnqueuesAutomaticRun() async throws {
    let fixture = try IntelligenceFixtures.meeting("deployment")
    let (coordinator, store, _, _) = try makeCoordinator(fixture: fixture)
    coordinator.meetingTranscriptDidFinalize(id: fixture.id)
    await waitUntil { store.adoptCalls == 1 }
    let run = try await store.latestRun(meetingID: fixture.id)
    XCTAssertEqual(run?.state, .succeeded)
    XCTAssertEqual(run?.trigger, .automatic)
  }

  func testFinalizedTranscriptDoesNothingWhenAutomaticOff() async throws {
    let fixture = try IntelligenceFixtures.meeting("deployment")
    let (coordinator, store, _, _) = try makeCoordinator(
      fixture: fixture, automatic: false)
    coordinator.meetingTranscriptDidFinalize(id: fixture.id)
    try await Task.sleep(for: .milliseconds(100))
    XCTAssertEqual(store.admitCalls, 0)
    XCTAssertEqual(coordinator.queuedCount, 0)
  }

  func testManualGenerateWorksWhenAutomaticOff() async throws {
    let fixture = try IntelligenceFixtures.meeting("deployment")
    let (coordinator, store, _, _) = try makeCoordinator(
      fixture: fixture, automatic: false)
    coordinator.requestRun(meetingID: fixture.id)
    await waitUntil { store.adoptCalls == 1 }
    let run = try await store.latestRun(meetingID: fixture.id)
    XCTAssertEqual(run?.state, .succeeded)
    XCTAssertEqual(run?.trigger, .manual)
  }

  func testNonFinalMeetingRefusedWithNoticeAndNoRow() async throws {
    let (coordinator, store, _, reader) = try makeCoordinator()
    let meetingID = UUID()
    reader.transcription = MeetingTranscription(
      meetingID: meetingID, state: .finalizing, liveRequested: false,
      passID: UUID(), updatedAt: 0)
    var notices: [String] = []
    coordinator.noticePublished = { notices.append($0) }
    coordinator.requestRun(meetingID: meetingID)
    await waitUntil { !notices.isEmpty }
    XCTAssertEqual(notices, ["The transcript is not finished yet."])
    let refusedRun = try await store.latestRun(meetingID: meetingID)
    XCTAssertNil(refusedRun)
    XCTAssertEqual(store.admitCalls, 0)
  }

  // MARK: T033 — admission ordering and capacity

  func testPendingRowWrittenBeforeQueuedStatusPublished() async throws {
    let fixture = try IntelligenceFixtures.meeting("deployment")
    let batch = try XCTUnwrap(
      IntelligenceFixtures.response("deployment-valid")[.full]?.first)
    let gate = PreparationGate()
    let (coordinator, store, transport, _) = try makeCoordinator(fixture: fixture)
    transport.script(
      .full,
      [
        .hold(gate, lines: FakeAnalysisTransport.Lines(value: batch)),
        .lines(FakeAnalysisTransport.Lines(value: batch)),
      ])
    coordinator.requestRun(meetingID: fixture.id)
    await gate.waitUntilStarted()

    // A second meeting admits pending while the first holds the single slot.
    let second = UUID()
    coordinator.requestRun(meetingID: second)
    await waitUntil { coordinator.queuedCount == 1 }
    let status = await coordinator.observe(meetingID: second)
    XCTAssertEqual(status.state, .pending)
    XCTAssertEqual(status.queuedPosition, 1)
    let run = try await store.latestRun(meetingID: second)
    XCTAssertEqual(run?.state, .pending)

    await gate.open()
    await waitUntil { store.adoptCalls == 2 }
    let done = try await store.latestRun(meetingID: second)
    XCTAssertEqual(done?.state, .succeeded)
  }

  func testQueueFullRefusesHundredAndFirst() async throws {
    let fixture = try IntelligenceFixtures.meeting("deployment")
    let batch = try XCTUnwrap(
      IntelligenceFixtures.response("deployment-valid")[.full]?.first)
    let gate = PreparationGate()
    let (coordinator, store, transport, _) = try makeCoordinator(fixture: fixture)
    transport.script(
      .full,
      [
        .hold(gate, lines: FakeAnalysisTransport.Lines(value: batch)),
        .lines(FakeAnalysisTransport.Lines(value: batch)),
      ])
    var notices: [String] = []
    coordinator.noticePublished = { notices.append($0) }

    coordinator.requestRun(meetingID: fixture.id)
    await gate.waitUntilStarted()
    // 1 running + 99 queued + admissions in flight fills the 100 bound.
    for _ in 0..<99 {
      coordinator.requestRun(meetingID: UUID())
    }
    await waitUntil { coordinator.queuedCount == 99 }
    coordinator.requestRun(meetingID: UUID())
    XCTAssertEqual(notices, [MeetingIntelligenceCoordinator.queueFullNotice])
    XCTAssertEqual(store.admitCalls, 100)
    await gate.open()
  }

  // MARK: T033 — cancel and observe

  func testCancelQueuedRunRemovesPendingRow() async throws {
    let fixture = try IntelligenceFixtures.meeting("deployment")
    let batch = try XCTUnwrap(
      IntelligenceFixtures.response("deployment-valid")[.full]?.first)
    let gate = PreparationGate()
    let (coordinator, store, transport, _) = try makeCoordinator(fixture: fixture)
    transport.script(
      .full,
      [
        .hold(gate, lines: FakeAnalysisTransport.Lines(value: batch)),
        .lines(FakeAnalysisTransport.Lines(value: batch)),
      ])
    coordinator.requestRun(meetingID: fixture.id)
    await gate.waitUntilStarted()

    let second = UUID()
    coordinator.requestRun(meetingID: second)
    await waitUntil { coordinator.queuedCount == 1 }
    await coordinator.cancel(meetingID: second)
    let run = try await store.latestRun(meetingID: second)
    XCTAssertEqual(run?.state, .cancelled)
    let status = await coordinator.observe(meetingID: second)
    XCTAssertEqual(status.state, .cancelled)
    await gate.open()
  }

  // MARK: T069 — cancel running, retry, delete

  /// `cancel` on the running meeting cancels the task, joins it, and the
  /// published status reads `cancelled` only after the store write.
  func testCancelRunningWritesCancelledBeforeStatus() async throws {
    let fixture = try IntelligenceFixtures.meeting("deployment")
    let batch = try XCTUnwrap(
      IntelligenceFixtures.response("deployment-valid")[.full]?.first)
    let gate = PreparationGate()
    let (coordinator, store, transport, _) = try makeCoordinator(fixture: fixture)
    transport.script(.full, [.hold(gate, lines: .init(value: batch))])
    coordinator.requestRun(meetingID: fixture.id)
    await gate.waitUntilStarted()

    await coordinator.cancel(meetingID: fixture.id)

    let run = try await store.latestRun(meetingID: fixture.id)
    XCTAssertEqual(run?.state, .cancelled)
    let status = await coordinator.observe(meetingID: fixture.id)
    XCTAssertEqual(status.state, .cancelled)
    await gate.open()
  }

  /// Retry on a failed run admits a new row and keeps the failed one.
  func testRetryOnFailedRunStartsNewRunKeepsOld() async throws {
    let fixture = try IntelligenceFixtures.meeting("deployment")
    let batch = try XCTUnwrap(
      IntelligenceFixtures.response("deployment-valid")[.full]?.first)
    let (coordinator, store, transport, _) = try makeCoordinator(fixture: fixture)
    transport.script(
      .full,
      [
        .failure(AnalysisFailure(.serverUnreachable)),
        .lines(.init(value: batch)),
      ])
    _ = await coordinator.observe(meetingID: fixture.id)
    coordinator.requestRun(meetingID: fixture.id)
    await waitUntil { coordinator.status?.state == .failed }

    coordinator.requestRun(meetingID: fixture.id, trigger: .retry)
    await waitUntil { store.adoptCalls == 1 }

    let rows = try await store.runs(meetingID: fixture.id, limit: 10)
    XCTAssertEqual(rows.count, 2)
    XCTAssertEqual(Set(rows.map(\.trigger)), [.manual, .retry])
    XCTAssertEqual(rows.first { $0.trigger == .retry }?.state, .succeeded)
    XCTAssertEqual(rows.first { $0.trigger == .manual }?.state, .failed)
  }

  /// `meetingWillDelete` cancels the running task and waits for it before
  /// returning; queued ids leave the queue so the cascade can proceed.
  func testMeetingWillDeleteCancelsAndJoins() async throws {
    let fixture = try IntelligenceFixtures.meeting("deployment")
    let batch = try XCTUnwrap(
      IntelligenceFixtures.response("deployment-valid")[.full]?.first)
    let gate = PreparationGate()
    let (coordinator, store, transport, _) = try makeCoordinator(fixture: fixture)
    transport.script(.full, [.hold(gate, lines: .init(value: batch))])
    coordinator.requestRun(meetingID: fixture.id)
    await gate.waitUntilStarted()
    let second = UUID()
    coordinator.requestRun(meetingID: second)
    await waitUntil { coordinator.queuedCount == 1 }

    await coordinator.meetingWillDelete(id: second)
    XCTAssertEqual(coordinator.queuedCount, 0)
    let queued = try await store.latestRun(meetingID: second)
    XCTAssertEqual(queued?.state, .cancelled)

    await coordinator.meetingWillDelete(id: fixture.id)
    let run = try await store.latestRun(meetingID: fixture.id)
    XCTAssertEqual(run?.state, .cancelled)
    await gate.open()
  }

  /// A failed run publishes the category so the header can pick the fixed
  /// message — never a generic failure.
  func testFailedStatusCarriesCategory() async throws {
    let fixture = try IntelligenceFixtures.meeting("deployment")
    let (coordinator, store, transport, _) = try makeCoordinator(fixture: fixture)
    transport.script(.full, [.failure(AnalysisFailure(.authenticationFailed))])
    _ = await coordinator.observe(meetingID: fixture.id)
    coordinator.requestRun(meetingID: fixture.id)
    await waitUntil { coordinator.status?.state == .failed }
    let status = await coordinator.observe(meetingID: fixture.id)
    XCTAssertEqual(status.state, .failed)
    XCTAssertEqual(status.failure, .authenticationFailed)
  }

  // MARK: Helpers

  // MARK: T076 — evidenceDidChange and the stale flag

  /// An evidence write recomputes the version through one paged read; when it
  /// differs from the accepted run's, `status.stale` flips. Nothing is queued.
  func testEvidenceDidChangeFlipsStaleWhenVersionDiffers() async throws {
    let fixture = try IntelligenceFixtures.meeting("deployment")
    let (coordinator, store, _, reader) = try makeCoordinator(fixture: fixture)
    coordinator.requestRun(meetingID: fixture.id)
    await waitUntil { store.adoptCalls == 1 }
    let observed = await coordinator.observe(meetingID: fixture.id)
    XCTAssertTrue(observed.hasAccepted)
    XCTAssertFalse(observed.stale)

    // A notes write changes the evidence; one paged read proves the drift.
    let pagesBefore = reader.pageRequests.count
    reader.noteRows.append(
      NoteParagraph(ordinal: 99, text: "Added later.", hash: String(repeating: "a", count: 64)))
    coordinator.evidenceDidChange(meetingID: fixture.id)
    await waitUntil { coordinator.status?.stale == true }
    XCTAssertEqual(coordinator.status?.stale, true)
    XCTAssertGreaterThan(reader.pageRequests.count, pagesBefore)
    XCTAssertEqual(coordinator.queuedCount, 0, "staleness never enqueues a run")
  }

  /// A display-name-only rename leaves the version alone: participant names
  /// are hashed out, so the flag stays down and nothing is queued.
  func testRenameOnlyLeavesStaleFalse() async throws {
    let fixture = try IntelligenceFixtures.meeting("deployment")
    let (coordinator, store, _, reader) = try makeCoordinator(fixture: fixture)
    coordinator.requestRun(meetingID: fixture.id)
    await waitUntil { store.adoptCalls == 1 }
    _ = await coordinator.observe(meetingID: fixture.id)

    reader.participantRows[0].name = "Martin"
    coordinator.evidenceDidChange(meetingID: fixture.id)
    try await Task.sleep(for: .milliseconds(150))
    XCTAssertEqual(coordinator.status?.stale, false)
    XCTAssertEqual(coordinator.queuedCount, 0)
  }

  private func makeCoordinator(
    fixture: IntelligenceFixture? = nil, automatic: Bool = true
  ) throws -> (
    MeetingIntelligenceCoordinator, FakeAnalysisStore, FakeAnalysisTransport,
    FakeEvidenceReader
  ) {
    let reader = FakeEvidenceReader(fixture: fixture)
    let store = FakeAnalysisStore()
    let transport = FakeAnalysisTransport(fixture: fixture)
    if fixture != nil { try transport.script(response: "deployment-valid") }
    let analyzer = MeetingAnalyzer(
      evidence: reader, transport: transport, store: store,
      clock: FakeMeetingClock(),
      endpoint: {
        RewriteEndpoint(url: URL(string: "http://127.0.0.1:8765")!, origin: "test")
      },
      settings: { nil })
    return (
      MeetingIntelligenceCoordinator(
        analyzer: analyzer, store: store,
        automaticEnabled: { automatic }, clock: FakeMeetingClock()),
      store, transport, reader
    )
  }

  private func waitUntil(
    timeout: Duration = .seconds(5),
    _ condition: @escaping @MainActor () -> Bool
  ) async {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while clock.now < deadline {
      if condition() { return }
      try? await Task.sleep(for: .milliseconds(5))
    }
  }
}
