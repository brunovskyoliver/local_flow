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
    coordinator.generate(meetingID: fixture.id)
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
    coordinator.generate(meetingID: meetingID)
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
    transport.script(.full, [
      .hold(gate, lines: FakeAnalysisTransport.Lines(value: batch)),
      .lines(FakeAnalysisTransport.Lines(value: batch)),
    ])
    coordinator.generate(meetingID: fixture.id)
    await gate.waitUntilStarted()

    // A second meeting admits pending while the first holds the single slot.
    let second = UUID()
    coordinator.generate(meetingID: second)
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
    transport.script(.full, [
      .hold(gate, lines: FakeAnalysisTransport.Lines(value: batch)),
      .lines(FakeAnalysisTransport.Lines(value: batch)),
    ])
    var notices: [String] = []
    coordinator.noticePublished = { notices.append($0) }

    coordinator.generate(meetingID: fixture.id)
    await gate.waitUntilStarted()
    // 1 running + 99 queued + admissions in flight fills the 100 bound.
    for _ in 0..<99 {
      coordinator.generate(meetingID: UUID())
    }
    await waitUntil { coordinator.queuedCount == 99 }
    coordinator.generate(meetingID: UUID())
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
    transport.script(.full, [
      .hold(gate, lines: FakeAnalysisTransport.Lines(value: batch)),
      .lines(FakeAnalysisTransport.Lines(value: batch)),
    ])
    coordinator.generate(meetingID: fixture.id)
    await gate.waitUntilStarted()

    let second = UUID()
    coordinator.generate(meetingID: second)
    await waitUntil { coordinator.queuedCount == 1 }
    await coordinator.cancel(meetingID: second)
    let run = try await store.latestRun(meetingID: second)
    XCTAssertEqual(run?.state, .cancelled)
    let status = await coordinator.observe(meetingID: second)
    XCTAssertEqual(status.state, .cancelled)
    await gate.open()
  }

  // MARK: Helpers

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
