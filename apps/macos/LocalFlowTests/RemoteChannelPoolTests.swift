import XCTest

@testable import LocalFlow
@testable import LocalFlowCore

/// Feature 018 T017 (research R6): one op at a time per role, three roles per device.
final class RemoteChannelPoolTests: XCTestCase {
  private func opener() -> (RemoteRewriteChannels.Opener, FakeRemoteTransportOpener) {
    let transports = FakeRemoteTransportOpener { _ in
      FakeRemoteTransport { event in
        guard case .hello = event else { return [] }
        return [.message(["type": "ready"])]
      }
    }
    let open: RemoteRewriteChannels.Opener = {
      let transport = try await transports.open(URL(string: "wss://mini.example.com")!)
      let fake = transport as! FakeRemoteTransport
      let channel = try RemoteChannel(transport: fake, serverKey: fake.server.publicKey)
      try await channel.open(purpose: .session, accessToken: "lfa_1")
      return channel
    }
    return (open, transports)
  }

  func testEachRoleServesOneCallerAtATimeAndReusesItsChannel() async throws {
    let (open, transports) = opener()
    let pool = RemoteChannelPool(open: open)
    let (background, firstOp) = try await pool.lease(.background)
    XCTAssertEqual(firstOp, 1)
    // The live role is independent of a busy background role.
    let (live, _) = try await pool.lease(.live)
    XCTAssertFalse(live === background)
    let second = Task { try await pool.lease(.background) }
    try await Task.sleep(for: .milliseconds(50))
    XCTAssertEqual(transports.openCount, 2, "the second background caller waits")
    await pool.release(.background, channel: background, nextOp: 2)
    let (reused, nextOp) = try await second.value
    XCTAssertTrue(reused === background)
    XCTAssertEqual(nextOp, 2)
    XCTAssertEqual(transports.openCount, 2)
    // A failed op's channel is closed, so the next lease opens a new one.
    await pool.release(.background, channel: reused, nextOp: nil)
    let (fresh, op) = try await pool.lease(.background)
    XCTAssertFalse(fresh === background)
    XCTAssertEqual(op, 1)
    await pool.release(.background, channel: fresh, nextOp: 2)
    await pool.release(.live, channel: live, nextOp: 2)
  }

  func testAStaleParkedChannelIsClosedAndReplaced() async throws {
    let (open, transports) = opener()
    let time = ManualRemoteClock()
    let pool = RemoteChannelPool(open: open, now: { time.now() })
    let (first, _) = try await pool.lease(.background)
    await pool.release(.background, channel: first, nextOp: 2)
    time.advance(by: RemoteRewriteChannels.maximumParkedAge + .seconds(1))
    let (second, op) = try await pool.lease(.background)
    XCTAssertFalse(first === second)
    XCTAssertEqual(op, 1)
    XCTAssertNotNil(transports.opened[0].closedWith)
    await pool.release(.background, channel: second, nextOp: nil)
  }

  func testTheInteractiveRoleIsFeature014sParkedChannel() async throws {
    let (open, transports) = opener()
    let pool = RemoteChannelPool(open: open)
    let (channel, op) = try await pool.interactive.take()
    XCTAssertEqual(op, 1)
    await pool.interactive.park(
      RemoteDictationResult(
        windows: [:],
        model: .init(
          engine: "FluidAudio", modelID: "m", modelRevision: "r", manifestHash: "h", sdk: "s",
          booster: nil, workerBuild: nil), channel: channel, nextOp: 2))
    let (background, _) = try await pool.lease(.background)
    await pool.release(.background, channel: background, nextOp: 2)
    await pool.closeAll()
    XCTAssertEqual(transports.opened.count, 2)
    XCTAssertTrue(transports.opened.allSatisfy { $0.closedWith != nil })
  }

  func testAFailedOpenFreesTheRole() async throws {
    let pool = RemoteChannelPool(open: { throw RemoteChannelError.unreachable })
    do {
      _ = try await pool.lease(.background)
      XCTFail("expected unreachable")
    } catch {}
    do {
      _ = try await pool.lease(.background)
      XCTFail("expected unreachable")
    } catch {
      XCTAssertEqual(error as? RemoteChannelError, .unreachable)
    }
  }
}
