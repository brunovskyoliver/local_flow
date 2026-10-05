import LocalFlowCore
import XCTest

@testable import LocalFlow

/// Feature 018 T078 (FR-031): meeting work that waits for the user's server.
@MainActor
final class WaitingForServerTests: XCTestCase {
  func testTheBackoffDoublesFromThirtySecondsToTenMinutes() {
    let delays = (0..<8).map { MeetingIntelligenceCoordinator.waitingDelay(attempt: $0) }
    XCTAssertEqual(
      delays, [30, 60, 120, 240, 480, 600, 600, 600].map { Duration.seconds($0) })
  }

  func testAWaitingItemRetriesAfterItsBackoffAndOnlyThen() async throws {
    let clock = FakeMeetingClock()
    var waits = ServerWaits()
    let id = UUID()
    var retried = 0
    waits.wait(id, clock: clock) { retried += 1 }
    XCTAssertEqual(waits.ids, [id])
    await clock.waitForSleepers(1)
    await clock.advance(by: .seconds(29))
    await Task.yield()
    XCTAssertEqual(retried, 0)
    await clock.advance(by: .seconds(1))
    for _ in 0..<20 where retried == 0 { await Task.yield() }
    XCTAssertEqual(retried, 1)
    XCTAssertEqual(waits.ids, [id], "waiting until the outcome is known")
    waits.retried(id)
    // A second failure waits twice as long.
    waits.wait(id, clock: clock) { retried += 1 }
    await clock.waitForSleepers(1)
    await clock.advance(by: .seconds(59))
    await Task.yield()
    XCTAssertEqual(retried, 1)
    XCTAssertTrue(waits.remove(id))
    await clock.advance(by: .seconds(1))
    await Task.yield()
    XCTAssertEqual(retried, 1, "a removed item never retries")
    XCTAssertEqual(waits.ids, [])
  }

  /// A channel opened or the network changed: retry now and start the backoff again.
  func testReachableRetriesNowAndResetsTheBackoff() async {
    let clock = FakeMeetingClock()
    var waits = ServerWaits()
    let id = UUID()
    for _ in 0..<3 { waits.wait(id, clock: clock) {} }
    XCTAssertEqual(waits.reachable(), [id])
    XCTAssertEqual(waits.reachable(), [], "already retried")
    var retried = false
    waits.wait(id, clock: clock) { retried = true }
    await clock.waitForSleepers(1)
    await clock.advance(by: .seconds(30))
    for _ in 0..<20 where !retried { await Task.yield() }
    XCTAssertTrue(retried, "attempt 0 again: 30 s")
  }

  /// A meeting the server is processing is asked again on a fixed interval, and a later
  /// failure backs off from 30 s again.
  func testAProcessingItemRetriesOnItsIntervalAndResetsTheBackoff() async {
    let clock = FakeMeetingClock()
    var waits = ServerWaits()
    let id = UUID()
    for _ in 0..<3 { waits.wait(id, clock: clock) {} }
    var retried = 0
    waits.wait(id, clock: clock, every: .seconds(10)) { retried += 1 }
    await clock.waitForSleepers(1)
    await clock.advance(by: .seconds(10))
    for _ in 0..<20 where retried == 0 { await Task.yield() }
    XCTAssertEqual(retried, 1)
    waits.retried(id)
    waits.wait(id, clock: clock) { retried += 1 }
    await clock.waitForSleepers(1)
    await clock.advance(by: .seconds(30))
    for _ in 0..<20 where retried == 1 { await Task.yield() }
    XCTAssertEqual(retried, 2, "attempt 0 again: 30 s")
  }

  /// Run on this Mac survives a restart: it is the meeting row's `run_locally`.
  func testRunOnThisMacIsStoredOnTheMeeting() async throws {
    let fixture = try MeetingTestStore.make()
    defer { fixture.cleanup() }
    let meeting = try await fixture.store.create(now: 1)
    let before = try await fixture.store.meeting(id: meeting.id)
    XCTAssertEqual(before?.runLocally, false)
    try await fixture.store.setRunLocally(meetingID: meeting.id, now: 2)
    let reopened = MeetingStore(history: fixture.history, root: fixture.root)
    let after = try await reopened.meeting(id: meeting.id)
    XCTAssertEqual(after?.runLocally, true)
    XCTAssertEqual(after?.revision, meeting.revision, "the meeting's own edits are not made stale")
  }
}
