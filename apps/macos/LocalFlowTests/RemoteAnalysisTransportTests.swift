import XCTest

@testable import LocalFlow
@testable import LocalFlowCore

/// Feature 018 T032 (research R8): summaries over the background channel.
final class RemoteAnalysisTransportTests: XCTestCase {
  private let endpoint: RewriteEndpoint = {
    var endpoint = RewriteEndpoint(
      url: URL(string: "https://mini.example.com")!, origin: "https://mini.example.com")
    endpoint.viaRemoteChannel = true
    return endpoint
  }()

  private func request(segments: Int = 0) -> AnalysisRequest {
    AnalysisRequest(
      requestID: UUID(), runID: UUID(), stage: .full, chunk: nil,
      meeting: AnalysisRequest.Meeting(
        id: UUID(), title: "Weekly", startedAt: "2026-09-20T09:00:00Z", durationMs: 60_000,
        timeZone: "UTC",
        languagePolicy: AnalysisRequest.LanguagePolicyValue(output: .en, preserveTerms: true)),
      participants: [],
      segments: (0..<segments).map {
        .init(
          id: UUID(), startMs: Int64($0) * 1_000, endMs: Int64($0) * 1_000 + 900, speakerID: nil,
          text: "Peter said \"ship it\" on Monday / Tuesday, \(String(repeating: "ž", count: 300))")
      }, notes: [], partials: nil)
  }

  private static func errorEvent(_ op: Int, code: String = "backend_timeout") -> FakeServerReply {
    .message([
      "type": "analysis_event", "op": op,
      "event": ["schema_version": 1, "type": "error", "request_id": "r", "code": code],
    ])
  }

  /// A server that assembles the fragments and answers with `reply(op, request)`.
  private func server(
    reply: @escaping (Int, Data) -> [FakeServerReply]
  ) -> (RemoteChannelPool, FakeRemoteTransportOpener, Assembled) {
    let assembled = Assembled()
    let transports = FakeRemoteTransportOpener { _ in
      FakeRemoteTransport { event in
        switch event {
        case .hello: return [.message(["type": "ready"])]
        case .control(let object) where object["type"] as? String == "analysis_part":
          assembled.add(object)
          return []
        case .control(let object) where object["type"] as? String == "analysis":
          assembled.close(object)
          return reply(object["op"] as! Int, assembled.body)
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
    return (pool, transports, assembled)
  }

  private static func collect(_ stream: AsyncThrowingStream<AnalysisTransportItem, Error>) async
    -> ([AnalysisTransportItem], (any Error)?)
  {
    var items: [AnalysisTransportItem] = []
    do {
      for try await item in stream { items.append(item) }
      return (items, nil)
    } catch { return (items, error) }
  }

  func testALargeRequestIsFragmentedHashedAndArrivesUnchanged() async throws {
    let (pool, transports, assembled) = server { op, _ in [Self.errorEvent(op)] }
    let transport = RemoteAnalysisTransport(pool: pool)
    let request = request(segments: 200)
    let body = try JSONEncoder().encode(request)
    XCTAssertGreaterThan(body.count, 2 * RemoteAnalysisTransport.maximumPartBytes)
    let (items, error) = await Self.collect(
      transport.analyze(request: request, endpoint: endpoint, timeout: .seconds(5)))
    XCTAssertNil(error)
    XCTAssertEqual(items.first, .firstByte)
    guard case .completed(let requestBytes, _) = items.last else { return XCTFail("\(items)") }
    XCTAssertEqual(requestBytes, body.count)
    // Same request; JSONEncoder's key order differs between encodings.
    XCTAssertEqual(
      try JSONSerialization.jsonObject(with: assembled.body) as? NSDictionary,
      try JSONSerialization.jsonObject(with: body) as? NSDictionary)
    XCTAssertGreaterThan(assembled.indexes.count, 2)
    XCTAssertEqual(assembled.indexes, Array(0..<assembled.indexes.count))
    XCTAssertEqual(assembled.closing?["parts"] as? Int, assembled.indexes.count)
    XCTAssertEqual(assembled.closing?["bytes"] as? Int, body.count)
    XCTAssertEqual(assembled.closing?["sha256"] as? String, SHA256Digest.hex(assembled.body))
    // A clean op keeps the channel for the next one.
    XCTAssertNil(transports.opened[0].closedWith)
  }

  func testEveryFragmentFitsOneControlMessage() throws {
    let awkward = Data(
      (String(repeating: "\"\\/\u{1}", count: 30_000) + String(repeating: "ž", count: 40_000)).utf8)
    let parts = RemoteAnalysisTransport.fragments(awkward)
    XCTAssertEqual(Data(parts.joined().utf8), awkward)
    for (index, part) in parts.enumerated() {
      XCTAssertLessThanOrEqual(part.utf8.count, RemoteAnalysisTransport.maximumPartBytes)
      XCTAssertNoThrow(
        try RemoteClientMessage.analysisPart(op: Int(Int32.max), index: index, data: part)
          .encoded())
    }
  }

  func testFragmentedEventsReassemble() async throws {
    let (pool, _, _) = server { op, _ in
      let line = Data(
        #"{"schema_version":1,"type":"progress","request_id":"r","stage":"full","chars":12}"#.utf8)
      let text = String(decoding: line, as: UTF8.self)
      let cut = text.index(text.startIndex, offsetBy: 30)
      return [
        .message([
          "type": "analysis_event_part", "op": op, "index": 0, "data": String(text[..<cut]),
        ]),
        .message([
          "type": "analysis_event_part", "op": op, "index": 1, "data": String(text[cut...]),
        ]),
        .message([
          "type": "analysis_event", "op": op, "parts": 2, "sha256": SHA256Digest.hex(line),
        ]),
        Self.errorEvent(op),
      ]
    }
    let (items, error) = await Self.collect(
      RemoteAnalysisTransport(pool: pool).analyze(
        request: request(), endpoint: endpoint, timeout: .seconds(5)))
    XCTAssertNil(error)
    guard items.count == 4, case .event(.progress(_, _, 12)) = items[1],
      case .event(.error(_, "backend_timeout")) = items[2]
    else { return XCTFail("\(items)") }
  }

  func testAMismatchedHashIsMalformed() async throws {
    let (pool, transports, _) = server { op, _ in
      [
        .message(["type": "analysis_event_part", "op": op, "index": 0, "data": "{}"]),
        .message([
          "type": "analysis_event", "op": op, "parts": 1,
          "sha256": String(repeating: "0", count: 64),
        ]),
      ]
    }
    let (_, error) = await Self.collect(
      RemoteAnalysisTransport(pool: pool).analyze(
        request: request(), endpoint: endpoint, timeout: .seconds(5)))
    XCTAssertEqual(error as? AnalysisFailure, AnalysisFailure(.malformedResponse))
    XCTAssertNotNil(transports.opened[0].closedWith)
  }

  func testBusyUnreachableAndAStoppedWorkerWaitForTheServer() async throws {
    for code in ["busy", "worker_unavailable"] {
      let (pool, _, _) = server { op, _ in [.message(["type": "error", "op": op, "code": code])] }
      let (_, error) = await Self.collect(
        RemoteAnalysisTransport(pool: pool).analyze(
          request: request(), endpoint: endpoint, timeout: .seconds(5)))
      XCTAssertEqual(
        error as? AnalysisFailure,
        AnalysisFailure(.serverUnreachable, detail: RemoteAnalysisTransport.waitingDetail), code)
    }
    let unreachable = RemoteChannelPool(open: { throw RemoteChannelError.unreachable })
    let (_, error) = await Self.collect(
      RemoteAnalysisTransport(pool: unreachable).analyze(
        request: request(), endpoint: endpoint, timeout: .seconds(5)))
    XCTAssertEqual(
      error as? AnalysisFailure,
      AnalysisFailure(.serverUnreachable, detail: RemoteAnalysisTransport.waitingDetail))
  }

  func testNotOfferedRemovesTheCapability() async throws {
    let (pool, _, _) = server { op, _ in
      [.message(["type": "error", "op": op, "code": "not_offered"])]
    }
    let dropped = Flag()
    let (_, error) = await Self.collect(
      RemoteAnalysisTransport(pool: pool, notOffered: { dropped.set() }).analyze(
        request: request(), endpoint: endpoint, timeout: .seconds(5)))
    XCTAssertEqual(
      error as? AnalysisFailure, AnalysisFailure(.serverUnavailable, detail: "not_offered"))
    XCTAssertTrue(dropped.value)
  }

  func testCancellingClosesTheChannelAndSendsNothingMore() async throws {
    let (pool, transports, _) = server { _, _ in [] }
    let stream = RemoteAnalysisTransport(pool: pool).analyze(
      request: request(), endpoint: endpoint, timeout: .seconds(30))
    let task = Task { await Self.collect(stream) }
    let sent = await eventually {
      transports.opened.first?.controlTypes.contains("analysis") == true
    }
    XCTAssertTrue(sent)
    task.cancel()
    _ = await task.value
    let closed = await eventually { transports.opened[0].closedWith != nil }
    XCTAssertTrue(closed)
    XCTAssertEqual(transports.opened[0].controlTypes.last, "analysis")
  }

  func testTheChannelNeverCarriesSummaryServerHeaders() {
    var endpoint = endpoint
    endpoint.summaryHeaders = [SummaryServer.primaryURLHeader: "http://ai-vm:8000/v1"]
    let transport = RemoteAnalysisTransport(
      pool: RemoteChannelPool(open: { throw CancellationError() }))
    XCTAssertEqual(transport.pinned(endpoint).summaryHeaders, [:])
  }

  func testRoutingFollowsTheAdmittedEndpoint() {
    let routing = RoutingAnalysisTransport(
      http: FakeAnalysisTransport(),
      remote: RemoteAnalysisTransport(pool: RemoteChannelPool(open: { throw CancellationError() })))
    var local = endpoint
    local.viaRemoteChannel = false
    XCTAssertEqual(routing.pinned(endpoint).summaryHeaders, [:])
    XCTAssertNil(routing.pinned(local).summaryHeaders)
  }
}

/// Feature 018 T052 (R9): a custom summaries server first, the channel when it fails
/// before any result.
final class CustomSummariesFallbackTests: XCTestCase {
  private let custom: RewriteEndpoint = {
    var endpoint = RewriteEndpoint(
      url: URL(string: "http://127.0.0.1:8091")!, origin: "http://127.0.0.1:8091")
    endpoint.summaryHeaders = [
      SummaryServer.primaryURLHeader: "http://ai-vm:8000/v1",
      SummaryServer.primaryModelHeader: "qwen", SummaryServer.primaryOnlyHeader: "1",
    ]
    endpoint.channelFallback = true
    return endpoint
  }()

  private static let accepted = AnalysisTransportItem.event(.accepted(requestID: nil, server: nil))
  private static let done = AnalysisTransportItem.completed(requestBytes: 1, responseBytes: 2)

  private func request() -> AnalysisRequest {
    AnalysisRequest(
      requestID: UUID(), runID: UUID(), stage: .full, chunk: nil,
      meeting: AnalysisRequest.Meeting(
        id: UUID(), title: "Weekly", startedAt: "2026-09-20T09:00:00Z", durationMs: 60_000,
        timeZone: "UTC",
        languagePolicy: AnalysisRequest.LanguagePolicyValue(output: .en, preserveTerms: true)),
      participants: [], segments: [], notes: [], partials: nil)
  }

  private func run(_ routing: RoutingAnalysisTransport, _ endpoint: RewriteEndpoint) async
    -> ([AnalysisTransportItem], (any Error)?)
  {
    var items: [AnalysisTransportItem] = []
    do {
      for try await item in routing.analyze(
        request: request(), endpoint: endpoint, timeout: .seconds(5))
      {
        items.append(item)
      }
      return (items, nil)
    } catch { return (items, error) }
  }

  func testAFailureBeforeAnyResultRetriesOverTheChannel() async {
    let failures: [Scripted] = [
      Scripted([.firstByte, Self.accepted], failure: AnalysisFailure(.serverUnreachable)),
      Scripted([.firstByte, .event(.error(requestID: nil, code: "backend_unavailable"))]),
    ]
    for http in failures {
      let remote = Scripted([.firstByte, Self.done])
      let (items, error) = await run(RoutingAnalysisTransport(http: http, remote: remote), custom)
      XCTAssertNil(error)
      XCTAssertEqual(items, [.fellBackToServer, .firstByte, Self.done])
      XCTAssertEqual(remote.endpoints.count, 1)
      XCTAssertEqual(remote.endpoints.first?.viaRemoteChannel, true)
      XCTAssertEqual(remote.endpoints.first?.summaryHeaders, [:], "never the custom server's key")
    }
  }

  func testAFailureAfterAPartialResultDoesNotRetry() async {
    let http = Scripted(
      [.firstByte, Self.accepted, .event(.progress(requestID: nil, stage: nil, chars: 40))],
      failure: AnalysisFailure(.serverUnreachable))
    let remote = Scripted([Self.done])
    let (items, error) = await run(RoutingAnalysisTransport(http: http, remote: remote), custom)
    XCTAssertEqual((error as? AnalysisFailure)?.category, .serverUnreachable)
    XCTAssertEqual(items.count, 3)
    XCTAssertEqual(remote.endpoints.count, 0)
  }

  func testWithoutChannelFallbackTheFailureStands() async {
    var endpoint = custom
    endpoint.channelFallback = false
    let http = Scripted([.firstByte], failure: AnalysisFailure(.serverUnreachable))
    let remote = Scripted([Self.done])
    let (_, error) = await run(RoutingAnalysisTransport(http: http, remote: remote), endpoint)
    XCTAssertNotNil(error)
    XCTAssertEqual(remote.endpoints.count, 0)
  }

  /// Both unreachable: the channel's waiting answer reaches the coordinator (FR-031).
  func testBothUnreachableWaitsForTheServer() async {
    let http = Scripted([], failure: AnalysisFailure(.serverUnreachable))
    let remote = Scripted(
      [],
      failure: AnalysisFailure(.serverUnreachable, detail: RemoteAnalysisTransport.waitingDetail))
    let (_, error) = await run(RoutingAnalysisTransport(http: http, remote: remote), custom)
    XCTAssertEqual((error as? AnalysisFailure)?.detail, RemoteAnalysisTransport.waitingDetail)
  }

  func testHealthFallsBackWhenTheCustomServerIsNotReady() async throws {
    let remote = Scripted([])
    let down = Scripted([], health: .failure(AnalysisFailure(.serverUnreachable)))
    var health = try await RoutingAnalysisTransport(http: down, remote: remote)
      .health(endpoint: custom)
    XCTAssertEqual(health.serverName, "remote")
    let stopped = Scripted([], health: .success(Scripted.health(state: "unavailable", name: "x")))
    health = try await RoutingAnalysisTransport(http: stopped, remote: remote)
      .health(endpoint: custom)
    XCTAssertEqual(health.serverName, "remote")
    let ready = Scripted([], health: .success(Scripted.health(state: "ready", name: "custom")))
    health = try await RoutingAnalysisTransport(http: ready, remote: remote)
      .health(endpoint: custom)
    XCTAssertEqual(health.serverName, "custom")
  }
}

/// A transport that yields `items`, then finishes or throws `failure`.
private final class Scripted: AnalysisTransporting, @unchecked Sendable {
  private let lock = NSLock()
  private let items: [AnalysisTransportItem]
  private let failure: (any Error)?
  private let healthResult: Result<AnalysisHealth, Error>
  private var seen: [RewriteEndpoint] = []
  var endpoints: [RewriteEndpoint] { lock.withLock { seen } }

  init(
    _ items: [AnalysisTransportItem], failure: (any Error)? = nil,
    health: Result<AnalysisHealth, Error> = .success(
      Scripted.health(state: "ready", name: "remote"))
  ) {
    self.items = items
    self.failure = failure
    healthResult = health
  }

  static func health(state: String, name: String) -> AnalysisHealth {
    AnalysisHealth(
      schemaVersion: 1, service: AnalysisHealth.serviceName, protocolVersions: [1],
      serverName: name, serverVersion: nil,
      backend: .init(state: state, kind: nil, model: nil, jsonSchema: true), promptVersions: [:],
      resultSchemaVersion: AnalysisBounds.schemaVersion, limits: nil, caps: nil)
  }

  func analyze(request: AnalysisRequest, endpoint: RewriteEndpoint, timeout: Duration)
    -> AsyncThrowingStream<AnalysisTransportItem, Error>
  {
    lock.withLock { seen.append(endpoint) }
    return AsyncThrowingStream { continuation in
      for item in items { continuation.yield(item) }
      continuation.finish(throwing: failure)
    }
  }

  func health(endpoint: RewriteEndpoint) async throws -> AnalysisHealth { try healthResult.get() }
  func invalidate() {}
}

private final class Assembled: @unchecked Sendable {
  private let lock = NSLock()
  private var parts: [(Int, String)] = []
  private var closed: [String: Any]?
  func add(_ object: [String: Any]) {
    lock.withLock { parts.append((object["index"] as! Int, object["data"] as! String)) }
  }
  func close(_ object: [String: Any]) { lock.withLock { closed = object } }
  var body: Data { lock.withLock { Data(parts.map(\.1).joined().utf8) } }
  var indexes: [Int] { lock.withLock { parts.map(\.0) } }
  var closing: [String: Any]? { lock.withLock { closed } }
}

private final class Flag: @unchecked Sendable {
  private let lock = NSLock()
  private var raised = false
  func set() { lock.withLock { raised = true } }
  var value: Bool { lock.withLock { raised } }
}
