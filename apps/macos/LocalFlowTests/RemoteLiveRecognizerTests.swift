import XCTest

@testable import LocalFlow
@testable import LocalFlowSpeech

/// Feature 018 T072: the live preview on the server.
@MainActor
final class RemoteLiveRecognizerTests: XCTestCase {
  /// Answers each `live_window` with `reply(op)` once its samples have arrived.
  private func server(
    reply: @escaping @Sendable (Int) -> [FakeServerReply]
  ) -> (RemoteChannelPool, FakeRemoteTransportOpener) {
    let state = Expected()
    let transports = FakeRemoteTransportOpener { _ in
      FakeRemoteTransport { event in
        switch event {
        case .hello: return [.message(["type": "ready"])]
        case .control(let object) where object["type"] as? String == "live_window":
          state.start(op: object["op"] as! Int, count: object["sample_count"] as! Int)
          return []
        case .s16(let samples):
          guard let op = state.receive(samples.count) else { return [] }
          return reply(op)
        default: return []
        }
      }
    }
    let pool = RemoteChannelPool(open: {
      let fake =
        try await transports.open(URL(string: "wss://mini.example.com")!)
        as! FakeRemoteTransport
      let channel = try RemoteChannel(transport: fake, serverKey: fake.server.publicKey)
      try await channel.open(purpose: .session, accessToken: "lfa_1")
      return channel
    })
    return (pool, transports)
  }

  private final class Expected: @unchecked Sendable {
    private let lock = NSLock()
    private var op = 0
    private var remaining = 0
    func start(op: Int, count: Int) {
      lock.withLock {
        self.op = op
        remaining = count
      }
    }
    func receive(_ count: Int) -> Int? {
      lock.withLock {
        remaining -= count
        return remaining == 0 ? op : nil
      }
    }
  }

  nonisolated private static func result(_ op: Int, count _: Int) -> FakeServerReply {
    .message([
      "type": "live_result", "op": op, "recognition_ms": 40,
      "window": [
        "text": "hello there",
        "tokens": [
          ["text": "hello", "start": 0.1, "end": 0.4],
          ["text": " there", "start": 0.5, "end": 0.9],
        ],
      ],
    ])
  }

  private func recognizer(_ runtime: RemoteLiveRecognizer) async throws -> (
    LiveRecognizer, ModelLifecycleCoordinator, ModelLease
  ) {
    let lifecycle = ModelLifecycleCoordinator { runtime }
    let lease = try await lifecycle.acquire(session: UUID())
    return (LiveRecognizer(lifecycle: lifecycle, lease: lease, sequence: 1), lifecycle, lease)
  }

  func testLiveWindowsGoOverTheLiveRole() async throws {
    let (pool, transports) = server { op in [Self.result(op, count: 96_000)] }
    let (recognizer, lifecycle, lease) = try await recognizer(RemoteLiveRecognizer(pool: pool))
    recognizer.accept(Array(repeating: 0.25, count: 96_000), tracks: .mic, emittedAt: 0)
    let processed = try await recognizer.processNext()
    XCTAssertTrue(processed)
    XCTAssertFalse(recognizer.pendingBatch().isEmpty)
    XCTAssertEqual(recognizer.takeServerGaps(all: true), [])
    let transport = try XCTUnwrap(transports.opened.first)
    XCTAssertEqual(transport.controlTypes, ["live_window"])
    XCTAssertEqual(transport.s16Samples.count, 96_000)
    // The background role has its own channel: a long meeting job never blocks this.
    let (background, _) = try await pool.lease(.background)
    XCTAssertEqual(transports.opened.count, 2)
    await pool.release(.background, channel: background, nextOp: nil)
    try await lifecycle.finish(lease)
  }

  /// FR-020: an unserved window is a `server_unavailable` gap; the next one still runs and
  /// recording keeps accepting audio meanwhile.
  func testBusyAndUnreachableWindowsBecomeOneGap() async throws {
    let calls = Counter()
    let (pool, _) = server { op in
      calls.next() < 2
        ? [.message(["type": "error", "op": op, "code": "busy"])]
        : [Self.result(op, count: 96_000)]
    }
    let (recognizer, lifecycle, lease) = try await recognizer(RemoteLiveRecognizer(pool: pool))
    recognizer.accept(Array(repeating: 0.25, count: 288_000), tracks: .mic, emittedAt: 0)
    _ = try await recognizer.processNext()
    XCTAssertEqual(recognizer.takeServerGaps(all: false), [], "the outage is still going")
    _ = try await recognizer.processNext()
    XCTAssertEqual(
      recognizer.accept(Array(repeating: 0, count: 16_000), tracks: .mic, emittedAt: 0), 16_000)
    _ = try await recognizer.processNext()
    XCTAssertEqual(recognizer.takeServerGaps(all: false), [0..<192_000])
    XCTAssertFalse(recognizer.pendingBatch().isEmpty)
    XCTAssertLessThanOrEqual(recognizer.gapRangeCount, LiveRecognizer.maximumGapRanges)
    try await lifecycle.finish(lease)

    let unreachable = RemoteChannelPool(open: { throw RemoteChannelError.unreachable })
    let (other, otherLifecycle, otherLease) = try await self.recognizer(
      RemoteLiveRecognizer(pool: unreachable))
    other.accept(Array(repeating: 0.25, count: 96_000), tracks: .mic, emittedAt: 0)
    let processed = try await other.processNext()
    XCTAssertTrue(processed)
    XCTAssertEqual(other.takeServerGaps(all: true), [0..<96_000])
    try await otherLifecycle.finish(otherLease)
  }

  private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func next() -> Int {
      lock.withLock {
        defer { value += 1 }
        return value
      }
    }
  }
}
