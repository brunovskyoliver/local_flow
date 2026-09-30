import XCTest

@testable import LocalFlow
@testable import LocalFlowCore

/// Feature 014 R14: rewrite over the remote channel yields what the HTTP client yields.
final class RemoteRewriteTransportTests: XCTestCase {
  private let endpoint = RewriteEndpoint(
    url: URL(string: "https://mini.example.com")!, origin: "https://mini.example.com")

  private func request() throws -> RewriteRequest {
    try RewriteRequest(requestID: UUID(), mode: .clean, text: "peter can you move the deployment")
  }

  /// A flowd session channel that answers `rewrite` with the NDJSON events of the HTTP route.
  private func session(
    reply: @escaping ([String: Any]) -> [FakeServerReply]
  ) -> FakeRemoteTransport {
    FakeRemoteTransport { event in
      switch event {
      case .hello: return [.message(["type": "ready"])]
      case .control(let object) where object["type"] as? String == "rewrite": return reply(object)
      default: return []
      }
    }
  }

  private func events(op: Int, requestID: String, text: String) -> [FakeServerReply] {
    [
      .message([
        "type": "rewrite_event", "op": op,
        "event": ["event": "accepted", "request_id": requestID],
      ]),
      .message([
        "type": "rewrite_event", "op": op,
        "event": [
          "event": "result", "schema_version": 1, "request_id": requestID, "mode": "clean",
          "text": text, "unchanged": false, "server": ["name": "flowd", "version": "0.14.0"],
          "backend": ["kind": "openai-compatible", "model": "qwen"], "prompt_version": 1,
          "shield": ["version": 1, "placeholders": 0, "restored": 0], "timing": ["queue_ms": 3],
        ],
      ]),
    ]
  }

  private func collect(_ stream: AsyncThrowingStream<RewriteTransportItem, Error>) async
    -> ([RewriteTransportItem], (any Error)?)
  {
    var items: [RewriteTransportItem] = []
    do {
      for try await item in stream { items.append(item) }
      return (items, nil)
    } catch { return (items, error) }
  }

  func testTheDictationChannelCarriesTheUnchangedRequest() async throws {
    var seen: [String: Any] = [:]
    let transport = session { object in
      seen = object
      let request = object["request"] as! [String: Any]
      return self.events(
        op: object["op"] as! Int, requestID: request["request_id"] as! String,
        text: "Peter, can you move the deployment?")
    }
    let channel = try RemoteChannel(transport: transport, serverKey: transport.server.publicKey)
    try await channel.open(purpose: .session, accessToken: "lfa_1")
    let channels = RemoteRewriteChannels {
      XCTFail("no new channel expected")
      throw RemoteChannelError.closed
    }
    await channels.park(
      RemoteDictationResult(
        windows: [:],
        model: .init(
          engine: "FluidAudio", modelID: "m", modelRevision: "r", manifestHash: "h", sdk: "s",
          booster: nil, workerBuild: nil), channel: channel, nextOp: 2))
    let rewrite = RemoteRewriteTransport(channels: channels)
    let request = try request()
    let (items, error) = await collect(
      rewrite.rewrite(request: request, endpoint: endpoint, timeout: .seconds(5)))
    XCTAssertNil(error)
    XCTAssertEqual(items.first, .firstByte)
    guard items.count == 4, case .event(.accepted) = items[1], case .event(.result) = items[2],
      case .completed(let requestBytes, _) = items[3]
    else { return XCTFail("\(items)") }
    XCTAssertEqual(requestBytes, try request.httpBody().count)
    XCTAssertEqual(seen["op"] as? Int, 2)
    let sent = try XCTUnwrap(seen["request"] as? [String: Any])
    let expected = try XCTUnwrap(
      JSONSerialization.jsonObject(with: request.httpBody()) as? [String: Any])
    XCTAssertEqual(sent as NSDictionary, expected as NSDictionary)
    XCTAssertNotNil(transport.closedWith)
  }

  func testAParkedChannelOlderThanTheServerIdleTimeoutIsNotUsed() async throws {
    let stale = session { _ in
      XCTFail("the stale channel must not carry the rewrite")
      return []
    }
    let parked = try RemoteChannel(transport: stale, serverKey: stale.server.publicKey)
    try await parked.open(purpose: .session, accessToken: "lfa_1")
    let fresh = session { object in
      let request = object["request"] as! [String: Any]
      return self.events(
        op: object["op"] as! Int, requestID: request["request_id"] as! String, text: "Done.")
    }
    let time = ManualRemoteClock()
    let channels = RemoteRewriteChannels(
      open: {
        let channel = try RemoteChannel(transport: fresh, serverKey: fresh.server.publicKey)
        try await channel.open(purpose: .session, accessToken: "lfa_1")
        return channel
      }, now: { time.now() })
    await channels.park(
      RemoteDictationResult(
        windows: [:],
        model: .init(
          engine: "FluidAudio", modelID: "m", modelRevision: "r", manifestHash: "h", sdk: "s",
          booster: nil, workerBuild: nil), channel: parked, nextOp: 2))
    time.advance(by: RemoteRewriteChannels.maximumParkedAge + .seconds(1))
    let (items, error) = await collect(
      RemoteRewriteTransport(channels: channels).rewrite(
        request: try request(), endpoint: endpoint, timeout: .seconds(5)))
    XCTAssertNil(error)
    XCTAssertEqual(items.count, 4)
    XCTAssertNotNil(stale.closedWith)
  }

  func testWithoutADictationChannelANewSessionIsOpened() async throws {
    let transport = session { object in
      let request = object["request"] as! [String: Any]
      return self.events(
        op: object["op"] as! Int, requestID: request["request_id"] as! String, text: "Done.")
    }
    let channels = RemoteRewriteChannels {
      let channel = try RemoteChannel(transport: transport, serverKey: transport.server.publicKey)
      try await channel.open(purpose: .session, accessToken: "lfa_1")
      return channel
    }
    let (items, error) = await collect(
      RemoteRewriteTransport(channels: channels).rewrite(
        request: try request(), endpoint: endpoint, timeout: .seconds(5)))
    XCTAssertNil(error)
    XCTAssertEqual(items.count, 4)
    let versions = await RemoteRewriteTransport(channels: channels).protocolVersions(
      endpoint: endpoint)
    XCTAssertEqual(versions, [1, 2])
  }

  func testChannelFailuresMapToTheFeature003Categories() async throws {
    let cases: [(FakeServerReply, RewriteFailureCategory)] = [
      (.close(1006), .serverUnreachable),
      (.message(["type": "error", "op": 1, "code": "busy"]), .backendUnavailable),
      (.message(["type": "error", "op": 1, "code": "revoked"]), .authenticationFailed),
      (.raw(Data(repeating: 1, count: 50)), .malformedResponse),
    ]
    for (reply, category) in cases {
      let transport = session { _ in [reply] }
      let channels = RemoteRewriteChannels {
        let channel = try RemoteChannel(transport: transport, serverKey: transport.server.publicKey)
        try await channel.open(purpose: .session, accessToken: "lfa_1")
        return channel
      }
      let (_, error) = await collect(
        RemoteRewriteTransport(channels: channels).rewrite(
          request: try request(), endpoint: endpoint, timeout: .seconds(5)))
      XCTAssertEqual((error as? RewriteFailure)?.category, category, "\(reply)")
    }
    // Nothing to connect to at all.
    let unreachable = RemoteRewriteChannels { throw RemoteTransportError.unreachable }
    let (_, error) = await collect(
      RemoteRewriteTransport(channels: unreachable).rewrite(
        request: try request(), endpoint: endpoint, timeout: .seconds(5)))
    XCTAssertEqual((error as? RewriteFailure)?.category, .serverUnreachable)
  }

  func testTheTimeoutAppliesInsideTheTransport() async throws {
    let transport = session { _ in [] }
    let channels = RemoteRewriteChannels {
      let channel = try RemoteChannel(transport: transport, serverKey: transport.server.publicKey)
      try await channel.open(purpose: .session, accessToken: "lfa_1")
      return channel
    }
    let (_, error) = await collect(
      RemoteRewriteTransport(channels: channels).rewrite(
        request: try request(), endpoint: endpoint, timeout: .milliseconds(50)))
    XCTAssertEqual((error as? RewriteFailure)?.category, .timeout)
  }
}
