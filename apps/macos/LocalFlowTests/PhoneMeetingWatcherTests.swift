import XCTest

@testable import LocalFlow
@testable import LocalFlowCore

/// Feature 020: the server pushes phone meetings to the Mac over a watch channel of its own.
final class PhoneMeetingWatcherTests: XCTestCase {
  private final class Probe: @unchecked Sendable {
    private let lock = NSLock()
    private var importCount = 0
    private var pushedValues: [Bool] = []
    var imports: Int { lock.withLock { importCount } }
    var pushed: [Bool] { lock.withLock { pushedValues } }
    func imported() { lock.withLock { importCount += 1 } }
    func push(_ value: Bool) { lock.withLock { pushedValues.append(value) } }
  }

  private static let meeting = UUID(uuidString: "5F1C3A2E-9B4D-4E21-8A7C-0D6B2F8E1A93")!

  private static func entry(_ id: UUID = meeting) -> [String: Any] {
    ["meeting": id.uuidString, "state": "done", "copy": true, "released": true]
  }

  /// `replies[i]` answers the i-th channel's watch (nil: never answers); a nil transport
  /// is a server that can't be reached.
  private func makeWatcher(
    ops: [String] = ["handoff", "handoff_watch"], clock: ManualRemoteClock,
    transport: @escaping (Int) -> [[String: Any]]??
  ) -> (PhoneMeetingWatcher, FakeRemoteTransportOpener, Probe) {
    let transports = FakeRemoteTransportOpener { index in
      guard let replies = transport(index) else { return nil }
      return FakeRemoteTransport { event in
        switch event {
        case .hello:
          return [.message(["type": "ready", "capabilities": ["ops": ops, "meeting_jobs": []]])]
        case .control(let object) where object["action"] as? String == "watch":
          guard let meetings = replies else { return [] }
          return [.message(["type": "handoff_reply", "op": object["op"]!, "meetings": meetings])]
        default: return []
        }
      }
    }
    let probe = Probe()
    let watcher = PhoneMeetingWatcher(
      open: {
        let transport = try await transports.open(URL(string: "wss://mini.example.com")!)
        let fake = transport as! FakeRemoteTransport
        let channel = try RemoteChannel(transport: fake, serverKey: fake.server.publicKey)
        try await channel.open(purpose: .session, accessToken: "lfa_1")
        return channel
      },
      importMeetings: { probe.imported() }, pushed: { probe.push($0) }, clock: clock)
    return (watcher, transports, probe)
  }

  /// A waiting meeting is imported as soon as the watch answers; the next watch then
  /// waits, with no timer and no other channel.
  func testAnAnsweredWatchImportsAndWatchesAgain() async throws {
    let clock = ManualRemoteClock()
    let (watcher, transports, probe) = makeWatcher(clock: clock) { index in
      index == 0 ? .some([Self.entry()]) : .some(nil)
    }
    await watcher.start()
    let watching = await eventually { transports.openCount == 2 && probe.imports == 1 }
    XCTAssertTrue(watching)
    XCTAssertEqual(probe.pushed.first, true)
    let first = transports.opened[0]
    XCTAssertEqual(first.controlTypes, ["handoff"])
    guard case .control(let watch) = first.receivedEvents.last else { return XCTFail("no watch") }
    XCTAssertEqual(watch["action"] as? String, "watch")
    XCTAssertEqual(watch["op"] as? Int, 1)
    XCTAssertNil(watch["meeting"])
    XCTAssertNotNil(first.closedWith, "each watch channel is closed after its answer")
    XCTAssertEqual(clock.sleeperCount, 0)

    // Stopping closes the waiting watch channel and reconnects nothing.
    await watcher.stop()
    let closed = await eventually { transports.opened[1].closedWith != nil }
    XCTAssertTrue(closed)
    XCTAssertEqual(probe.pushed.last, false)
    try await Task.sleep(for: .milliseconds(50))
    XCTAssertEqual(transports.openCount, 2)
    let running = await watcher.isRunning
    XCTAssertFalse(running)
  }

  /// The server's empty answer after its timeout is a success: the next watch opens at once.
  func testAnEmptyAnswerWatchesAgainAtOnce() async throws {
    let clock = ManualRemoteClock()
    let (watcher, transports, probe) = makeWatcher(clock: clock) { index in
      index < 2 ? .some([]) : .some(nil)
    }
    await watcher.start()
    let watching = await eventually { transports.openCount == 3 }
    XCTAssertTrue(watching)
    XCTAssertEqual(probe.imports, 0)
    await watcher.stop()
  }

  /// A server without handoff_watch leaves the timer import in charge and is asked again
  /// after `notOfferedRecheck`; no watch is sent.
  func testAServerWithoutTheWatchFallsBackToTheTimer() async throws {
    let clock = ManualRemoteClock()
    let (watcher, transports, probe) = makeWatcher(ops: ["handoff"], clock: clock) { _ in
      .some(nil)
    }
    await watcher.start()
    let waiting = await eventually { clock.sleeperCount == 1 }
    XCTAssertTrue(waiting)
    XCTAssertEqual(probe.pushed, [false])
    XCTAssertEqual(transports.opened[0].controlTypes, [])
    XCTAssertNotNil(transports.opened[0].closedWith)
    clock.advance(by: PhoneMeetingWatcher.notOfferedRecheck)
    let rechecked = await eventually { transports.openCount == 2 }
    XCTAssertTrue(rechecked)
    await watcher.stop()
  }

  /// An unreachable server is retried after 5 s, then 10 s; a nudge (network change)
  /// retries at once and starts the backoff again.
  func testAnUnreachableServerBacksOffAndANudgeRetriesAtOnce() async throws {
    let clock = ManualRemoteClock()
    let (watcher, transports, _) = makeWatcher(clock: clock) { index in
      index < 3 ? nil : .some(nil)
    }
    await watcher.start()
    var ok = await eventually { transports.openCount == 1 && clock.sleeperCount == 1 }
    XCTAssertTrue(ok)
    clock.advance(by: .seconds(4))
    XCTAssertEqual(transports.openCount, 1)
    clock.advance(by: .seconds(1))
    ok = await eventually { transports.openCount == 2 && clock.sleeperCount == 1 }
    XCTAssertTrue(ok)
    clock.advance(by: .seconds(9))
    try await Task.sleep(for: .milliseconds(30))
    XCTAssertEqual(transports.openCount, 2, "the second wait is 10 s")
    clock.advance(by: .seconds(1))
    ok = await eventually { transports.openCount == 3 && clock.sleeperCount == 1 }
    XCTAssertTrue(ok)
    await watcher.nudge()
    ok = await eventually { transports.openCount == 4 }
    XCTAssertTrue(ok, "a nudge ends the wait")
    await watcher.stop()
  }

  /// A meeting the last import left on the server is imported again only after a wait,
  /// so a meeting that never imports can't spin the watcher.
  func testAMeetingOfferedAgainWaitsBeforeTheNextImport() async throws {
    let clock = ManualRemoteClock()
    let (watcher, transports, probe) = makeWatcher(clock: clock) { index in
      index < 2 ? .some([Self.entry()]) : .some(nil)
    }
    await watcher.start()
    var ok = await eventually { probe.imports == 1 && clock.sleeperCount == 1 }
    XCTAssertTrue(ok)
    XCTAssertEqual(transports.openCount, 2)
    clock.advance(by: PhoneMeetingWatcher.firstRetry)
    ok = await eventually { probe.imports == 2 && transports.openCount == 3 }
    XCTAssertTrue(ok)
    await watcher.stop()
  }
}
