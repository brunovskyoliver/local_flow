import XCTest

@testable import LocalFlow

/// Latency capture, bucket boundaries and the SC-011 report verdicts.
final class RewriteLatencyTests: XCTestCase {
  func testSpansDeriveFromTheFiveInstants() {
    let clock = ContinuousClock()
    let start = clock.now
    var instants = RewriteInstants(committed: start)
    instants.sent = start.advanced(by: .milliseconds(40))
    instants.firstByte = start.advanced(by: .milliseconds(240))
    instants.terminal = start.advanced(by: .milliseconds(900))
    XCTAssertEqual(instants.durationMilliseconds, 900, "terminal counts until hand-off exists")
    XCTAssertEqual(instants.firstByteMilliseconds, 200)
    XCTAssertEqual(instants.networkMilliseconds, 860)
    instants.handedOff = start.advanced(by: .milliseconds(1_180))
    XCTAssertEqual(instants.durationMilliseconds, 1_180)
    let spans = instants.spans(requestBytes: 120, responseBytes: 340)
    XCTAssertEqual(spans.durationMilliseconds, 1_180)
    XCTAssertEqual(spans.firstByteMilliseconds, 200)
    XCTAssertEqual(spans.networkMilliseconds, 860)
    XCTAssertEqual(spans.requestBytes, 120)
    XCTAssertEqual(spans.responseBytes, 340)
    let partial = RewriteInstants(committed: start, terminal: start.advanced(by: .milliseconds(5)))
    XCTAssertNil(partial.firstByteMilliseconds)
    XCTAssertNil(partial.networkMilliseconds)
    XCTAssertEqual(partial.durationMilliseconds, 5)
    XCTAssertNil(RewriteInstants.milliseconds(from: start.advanced(by: .seconds(1)), to: start))
  }

  func testBucketBoundariesUseWhitespaceTokensOfTheInput() {
    func words(_ count: Int) -> String { (0..<count).map { "w\($0)" }.joined(separator: " ") }
    XCTAssertEqual(RewriteInputBucket.bucket(for: words(1)), .short)
    XCTAssertEqual(RewriteInputBucket.bucket(for: words(25)), .short)
    XCTAssertEqual(RewriteInputBucket.bucket(for: words(26)), .ordinary)
    XCTAssertEqual(RewriteInputBucket.bucket(for: words(90)), .ordinary)
    XCTAssertEqual(RewriteInputBucket.bucket(for: words(91)), .long)
    XCTAssertEqual(RewriteInputBucket.bucket(for: "  one\ttwo\nthree  "), .short)
    XCTAssertEqual(RewriteInputBucket.wordCount("  one\ttwo\nthree  "), 3)
    XCTAssertEqual(RewriteInputBucket.bucket(for: ""), .short)
  }

  private func samples(_ totals: [Int], bucket: RewriteInputBucket, identity: String = "qwen+p1+s1")
    -> [RewriteLatencySample]
  {
    totals.map {
      RewriteLatencySample(
        bucket: bucket, identity: identity, totalMilliseconds: $0, firstByteMilliseconds: $0 / 4,
        backendFirstTokenMilliseconds: $0 / 5, backendMilliseconds: $0 * 3 / 4)
    }
  }

  func testUnmeasuredBelowFiveSamplesAndGroupedByIdentity() {
    let four = samples([100, 200, 300, 400], bucket: .short)
    let groups = RewriteLatencyReport.groups(four)
    XCTAssertEqual(groups.count, 1)
    XCTAssertFalse(groups[0].measured)
    XCTAssertNil(groups[0].totalMedian)
    XCTAssertEqual(groups[0].shortGate, .unmeasured)
    XCTAssertTrue(RewriteLatencyReport.render(four).contains("unmeasured"))
    let mixed =
      samples([900, 950, 1_000, 1_050, 1_100], bucket: .short, identity: "qwen+p1+s1")
      + samples([2_000, 2_100, 2_200, 2_300, 2_400], bucket: .short, identity: "llama+p2+s0")
    let grouped = RewriteLatencyReport.groups(mixed)
    XCTAssertEqual(grouped.map(\.identity), ["llama+p2+s0", "qwen+p1+s1"])
    XCTAssertEqual(grouped[1].totalMedian, 1_000)
    XCTAssertEqual(grouped[1].shortGate, .pass)
    XCTAssertEqual(grouped[1].shortTarget, .achieved)
    XCTAssertEqual(grouped[0].shortGate, .fail)
    XCTAssertEqual(grouped[0].shortTarget, .notAchieved)
    XCTAssertEqual(grouped[0].dominantSpan, "backend")
    let rendered = RewriteLatencyReport.render(mixed)
    XCTAssertTrue(rendered.contains("short llama+p2+s0 n=5"))
    XCTAssertTrue(rendered.contains("FAIL dominant span: backend"))
    XCTAssertTrue(rendered.contains("NOT ACHIEVED"))
  }

  func testShortGatePassesAtMedianOneEighteenWhileTargetIsNotAchieved() {
    let group = RewriteLatencyReport.groups(
      samples([1_000, 1_100, 1_180, 1_300, 1_400], bucket: .short))[0]
    XCTAssertEqual(group.totalMedian, 1_180)
    XCTAssertEqual(group.shortGate, .pass)
    XCTAssertEqual(group.shortTarget, .notAchieved)
    XCTAssertEqual(group.ordinaryGate, .unmeasured, "the ordinary gate does not apply to short")
    let edge = RewriteLatencyReport.groups(
      samples([1_500, 1_500, 1_500, 1_500, 1_500], bucket: .short))[0]
    XCTAssertEqual(edge.shortGate, .pass)
    let miss = RewriteLatencyReport.groups(
      samples([1_501, 1_501, 1_501, 1_501, 1_501], bucket: .short))[0]
    XCTAssertEqual(miss.shortGate, .fail)
  }

  func testOrdinaryGateUsesP95() {
    let pass = RewriteLatencyReport.groups(
      samples([1_000, 1_500, 2_000, 2_500, 3_000], bucket: .ordinary))[0]
    XCTAssertEqual(pass.totalP95, 3_000)
    XCTAssertEqual(pass.ordinaryGate, .pass)
    XCTAssertEqual(pass.shortGate, .unmeasured)
    let fail = RewriteLatencyReport.groups(
      samples([1_000, 1_500, 2_000, 2_500, 3_001], bucket: .ordinary))[0]
    XCTAssertEqual(fail.ordinaryGate, .fail)
    let long = RewriteLatencyReport.groups(
      samples([9_000, 9_000, 9_000, 9_000, 9_000], bucket: .long))[0]
    XCTAssertEqual(long.ordinaryGate, .unmeasured)
    XCTAssertTrue(
      RewriteLatencyReport.render(samples([9_000, 9_000, 9_000, 9_000, 9_000], bucket: .long))
        .contains("no gate"))
  }

  func testMedianAndP95() {
    XCTAssertEqual(RewriteLatencyReport.median([3, 1, 2]), 2)
    XCTAssertEqual(RewriteLatencyReport.median([4, 1, 2, 3]), 3)
    XCTAssertNil(RewriteLatencyReport.median([]))
    XCTAssertEqual(RewriteLatencyReport.p95(Array(1...100)), 95)
    XCTAssertEqual(RewriteLatencyReport.p95([7]), 7)
    XCTAssertEqual(RewriteLatencyReport.p95(Array(1...20)), 19)
  }
}

/// In-process HTTP stub. Scripts are keyed by URL path; bodies stream in chunks
/// so byte caps, line caps and cancellation are exercised for real.
final class RewriteStubURLProtocol: URLProtocol, @unchecked Sendable {
  struct Script: Sendable {
    var status = 200
    var headers: [String: String] = ["Content-Type": "application/x-ndjson"]
    var chunks: [Data] = []
    var hang = false
    var transportError: URLError.Code? = nil
  }
  nonisolated(unsafe) static var scripts: [String: Script] = [:]
  nonisolated(unsafe) static var seenRequests: [URLRequest] = []
  nonisolated(unsafe) static var seenBodies: [Data] = []
  nonisolated(unsafe) static var stoppedCount = 0
  static let lock = NSLock()
  private var cancelled = false

  static func reset() {
    lock.withLock {
      scripts = [:]
      seenRequests = []
      seenBodies = []
      stoppedCount = 0
    }
  }
  static func script(_ script: Script, path: String) { lock.withLock { scripts[path] = script } }

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    var body = Data()
    if let stream = request.httpBodyStream {
      stream.open()
      let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
      defer { buffer.deallocate() }
      while stream.hasBytesAvailable {
        let read = stream.read(buffer, maxLength: 4096)
        if read <= 0 { break }
        body.append(buffer, count: read)
      }
      stream.close()
    } else if let direct = request.httpBody {
      body = direct
    }
    let script: Script? = Self.lock.withLock {
      Self.seenRequests.append(request)
      Self.seenBodies.append(body)
      return Self.scripts[request.url?.path ?? ""]
    }
    guard let script else {
      client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
      return
    }
    if let code = script.transportError {
      client?.urlProtocol(self, didFailWithError: URLError(code))
      return
    }
    if script.hang { return }
    let response = HTTPURLResponse(
      url: request.url!, statusCode: script.status, httpVersion: "HTTP/1.1",
      headerFields: script.headers)!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    for chunk in script.chunks {
      if cancelled { return }
      client?.urlProtocol(self, didLoad: chunk)
    }
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {
    cancelled = true
    Self.lock.withLock { Self.stoppedCount += 1 }
  }
}

final class RewriteClientTests: XCTestCase {
  private let requestID = UUID(uuidString: "6F9619FF-8B86-D011-B42D-00C04FC964FF")!
  private let endpoint = RewriteEndpoint(
    url: URL(string: "https://rewrite.example.net")!, origin: "https://rewrite.example.net:443")

  override func setUp() {
    super.setUp()
    RewriteStubURLProtocol.reset()
  }

  private func makeClient(
    credential: String? = nil, clock: any DictationClock = SystemDictationClock()
  ) -> (RewriteClient, FakeRewriteCredentialStore) {
    let store = FakeRewriteCredentialStore()
    if let credential { try? store.write(origin: endpoint.origin, secret: credential) }
    let client = RewriteClient(credentials: store, clock: clock) { configuration in
      configuration.protocolClasses = [RewriteStubURLProtocol.self]
    }
    return (client, store)
  }

  private func request(text: String = "peter can you move the deployment") throws -> RewriteRequest
  {
    try RewriteRequest(requestID: requestID, mode: .clean, text: text)
  }

  private func resultLine(text: String = "Peter, can you move the deployment?") -> Data {
    let id = requestID.uuidString
    return Data(
      #"{"event":"result","schema_version":1,"request_id":"\#(id)","mode":"clean","text":"\#(text)","unchanged":false,"server":{"name":"flowd","version":"0.2.0"},"backend":{"kind":"openai-compatible","model":"qwen"},"prompt_version":1,"shield":{"version":1,"placeholders":0,"restored":0},"timing":{"queue_ms":3}}"#
        .utf8) + Data("\n".utf8)
  }

  private func category(_ error: Error?) -> RewriteFailureCategory? {
    (error as? RewriteFailure)?.category
  }

  @MainActor
  func testCorpusAcceptanceLogsAndMetricExportExcludeTextAndCredential() async throws {
    var root = URL(fileURLWithPath: #filePath)
    for _ in 0..<4 { root.deleteLastPathComponent() }
    let corpusData = try Data(
      contentsOf: root.appendingPathComponent("fixtures/rewrite/corpus-v1.json"))
    let corpus = try XCTUnwrap(JSONSerialization.jsonObject(with: corpusData) as? [String: Any])
    let items = try XCTUnwrap(corpus["items"] as? [[String: Any]])
    let texts = try items.map { try XCTUnwrap($0["text"] as? String) }
    XCTAssertEqual(texts.count, 40)
    let secret = "phase-eleven-private-credential"
    let suite = "LocalFlow-privacy-\(UUID())"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let preferences = AppPreferences(defaults: defaults)
    preferences.rewriteEnabled = true
    preferences.rewriteEndpoint = endpoint.origin
    let credentials = FakeRewriteCredentialStore()
    try credentials.write(origin: endpoint.origin, secret: secret)
    let transport = FakeRewriteTransport(defaultScript: .succeed(text: "Rewritten."))
    let ids = texts.map { _ in UUID() }
    let store = FakeRewriteAttemptStore(known: ids)
    let coordinator = RewriteCoordinator(
      preferences: preferences, credentials: credentials, transport: transport, store: store)
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "rewrite-privacy-\(UUID())")
    defer { try? FileManager.default.removeItem(at: directory) }
    let writer = DispatchQueue(label: "rewrite-privacy-export")
    let recorder = try ResourceRecorder(
      directory: directory,
      identity: .init(
        build: "test", model: "fake-model", hardware: "test", os: "test", conditions: .development),
      writerQueue: writer)
    coordinator.metricRecorded = { metric in
      writer.sync {
        switch metric {
        case .attempt(let record): recorder.record(rewrite: record)
        case .refusal(let reason, let bucket): recorder.record(refusal: reason, bucket: bucket)
        }
      }
    }
    var capturedLogs: [String] = []
    for (index, text) in texts.enumerated() {
      transport.setDefault(.succeed(text: text))
      let success = await coordinator.rewrite(dictation: ids[index], text: text)
      guard case .rewritten = success else { return XCTFail("Expected corpus success") }
      capturedLogs.append(contentsOf: coordinator.recentDiagnostics)
      transport.setDefault(.httpStatus(401, code: "unauthorized"))
      let failure = await coordinator.retry(
        dictation: ids[index], faithfulText: text, mode: .polished, origin: .history)
      XCTAssertEqual(failure, .fallback(faithful: text, category: .authenticationFailed))
      capturedLogs.append(contentsOf: coordinator.recentDiagnostics)
      _ = await recorder.flush()
    }
    let report = try await recorder.close()
    XCTAssertTrue(report.complete)
    XCTAssertGreaterThan(report.samplesWritten, 0)
    XCTAssertFalse(capturedLogs.isEmpty)
    let export = try report.files.map { try String(contentsOf: $0, encoding: .utf8) }.joined()
    let logs = capturedLogs.joined(separator: "\n")
    XCTAssertTrue(export.contains("rewriteOutcome"))
    XCTAssertTrue(export.contains("authentication_failed"))
    XCTAssertTrue(export.contains("unknown+punknown+sunknown"))
    for forbidden in texts + [secret] {
      XCTAssertFalse(logs.contains(forbidden), "Content leaked into captured log messages")
      XCTAssertFalse(export.contains(forbidden), "Content leaked into metric export")
    }
  }

  func testRequestCarriesExactlySixFieldsAndBearerOnlyWithCredential() async throws {
    RewriteStubURLProtocol.script(
      .init(chunks: [
        Data(#"{"event":"accepted","request_id":"\#(requestID.uuidString)"}"#.utf8)
          + Data("\n".utf8), resultLine(),
      ]),
      path: "/v1/rewrite")
    let (client, _) = makeClient(credential: "top-secret")
    let request = try request()
    let outcome = await collectItems(
      client.rewrite(request: request, endpoint: endpoint, timeout: .seconds(20)))
    XCTAssertNil(outcome.error)
    let sent = try XCTUnwrap(RewriteStubURLProtocol.seenRequests.first)
    XCTAssertEqual(sent.url?.path, "/v1/rewrite")
    XCTAssertEqual(sent.httpMethod, "POST")
    XCTAssertEqual(sent.value(forHTTPHeaderField: "Authorization"), "Bearer top-secret")
    XCTAssertEqual(sent.timeoutInterval, 20)
    let body = try XCTUnwrap(RewriteStubURLProtocol.seenBodies.first)
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
    XCTAssertEqual(
      Set(object.keys),
      ["schema_version", "request_id", "mode", "text", "language_hints", "stream_deltas"])
    XCTAssertEqual(outcome.items.first, .firstByte)
    XCTAssertEqual(outcome.items.count, 4)
    guard case .completed(let requestBytes, let responseBytes) = outcome.items.last else {
      return XCTFail("stream must end with completed")
    }
    XCTAssertEqual(requestBytes, body.count)
    XCTAssertEqual(
      responseBytes,
      RewriteStubURLProtocol.scripts["/v1/rewrite"]!.chunks.reduce(0) { $0 + $1.count })

    RewriteStubURLProtocol.reset()
    RewriteStubURLProtocol.script(.init(chunks: [resultLine()]), path: "/v1/rewrite")
    let (anonymous, _) = makeClient()
    _ = await collectItems(
      anonymous.rewrite(request: request, endpoint: endpoint, timeout: .seconds(20)))
    XCTAssertNil(
      RewriteStubURLProtocol.seenRequests.first?.value(forHTTPHeaderField: "Authorization"))
  }

  func testReadStopsAtResponseCapBeforeParsing() async throws {
    let request = try request(text: "abc")
    let cap = RewriteBounds.maximumResponseBytes(inputBytes: 3)
    XCTAssertEqual(cap, 8_204)
    // A stream of harmless progress lines that never terminates and passes the cap.
    let line =
      Data(
        #"{"event":"progress","request_id":"\#(requestID.uuidString)","generated_chars":1}"#.utf8)
      + Data("\n".utf8)
    let chunks = (0..<(cap / line.count + 2)).map { _ in line }
    RewriteStubURLProtocol.script(.init(chunks: chunks), path: "/v1/rewrite")
    let (client, _) = makeClient()
    let outcome = await collectItems(
      client.rewrite(request: request, endpoint: endpoint, timeout: .seconds(20)))
    XCTAssertEqual(category(outcome.error), .oversizedResponse)
    XCTAssertLessThanOrEqual(outcome.items.count - 1, cap / line.count)
    // Unparsable garbage past the cap is never decoded: the cap wins.
    RewriteStubURLProtocol.reset()
    RewriteStubURLProtocol.script(
      .init(chunks: [Data(repeating: UInt8(ascii: "x"), count: cap + 1)]), path: "/v1/rewrite")
    let garbage = await collectItems(
      client.rewrite(request: request, endpoint: endpoint, timeout: .seconds(20)))
    XCTAssertEqual(category(garbage.error), .oversizedResponse)
  }

  /// The rewrite cap counts the whole stream, as the contract says; flowd keeps
  /// its auxiliary events under 3,800 bytes and its whole response under the
  /// same cap, so a full auxiliary budget plus the largest result still fits.
  func testFullProgressBudgetPlusLargestResultFitsTheCap() async throws {
    // 16,384 four-byte scalars: the largest input the request allows.
    let largest = String(repeating: "\u{1F600}", count: RewriteBounds.maximumInputBytes / 4)
    for text in ["abc", largest] {
      RewriteStubURLProtocol.reset()
      let request = try request(text: text)
      let result = resultLine(
        text: String(
          repeating: "b",
          count: RewriteBounds.maximumResultBytes(inputBytes: request.inputBytes)))
      let progress =
        Data(
          #"{"event":"progress","request_id":"\#(requestID.uuidString)","generated_chars":12345}"#
            .utf8) + Data("\n".utf8)
      let lines = Array(repeating: progress, count: 3_800 / progress.count + 1) + [result]
      XCTAssertLessThanOrEqual(
        lines.reduce(0) { $0 + $1.count },
        RewriteBounds.maximumResponseBytes(inputBytes: request.inputBytes))
      RewriteStubURLProtocol.script(.init(chunks: lines), path: "/v1/rewrite")
      let (client, _) = makeClient()
      let outcome = await collectItems(
        client.rewrite(request: request, endpoint: endpoint, timeout: .seconds(20)))
      XCTAssertNil(outcome.error, "input \(text.utf8.count) bytes")
    }
  }

  func testNonResultLineOverEightKiBIsMalformed() async throws {
    let request = try request(text: String(repeating: "a", count: 20_000))
    let padding = String(repeating: "p", count: 8_200)
    let line =
      Data(
        #"{"event":"progress","request_id":"\#(requestID.uuidString)","generated_chars":1,"pad":"\#(padding)"}"#
          .utf8) + Data("\n".utf8)
    RewriteStubURLProtocol.script(.init(chunks: [line, resultLine()]), path: "/v1/rewrite")
    let (client, _) = makeClient()
    let outcome = await collectItems(
      client.rewrite(request: request, endpoint: endpoint, timeout: .seconds(20)))
    XCTAssertEqual(category(outcome.error), .malformedResponse)
    // A result line of the same size is allowed.
    RewriteStubURLProtocol.reset()
    RewriteStubURLProtocol.script(.init(chunks: [resultLine(text: padding)]), path: "/v1/rewrite")
    let large = await collectItems(
      client.rewrite(request: request, endpoint: endpoint, timeout: .seconds(20)))
    XCTAssertNil(large.error)
  }

  func testMalformedLineFailsBeforeAnyResult() async throws {
    RewriteStubURLProtocol.script(
      .init(chunks: [Data("not json\n".utf8), resultLine()]), path: "/v1/rewrite")
    let (client, _) = makeClient()
    let outcome = await collectItems(
      client.rewrite(request: try request(), endpoint: endpoint, timeout: .seconds(20)))
    XCTAssertEqual(category(outcome.error), .malformedResponse)
  }

  func testTimeoutFiresWithinToleranceOnFakeClock() async throws {
    RewriteStubURLProtocol.script(.init(hang: true), path: "/v1/rewrite")
    let clock = FakeRewriteClock()
    let (client, _) = makeClient(clock: clock)
    let stream = client.rewrite(request: try request(), endpoint: endpoint, timeout: .seconds(7))
    let started = ContinuousClock.now
    let consumer = Task { await collectItems(stream) }
    await clock.waitForSleepers()
    await clock.advance(by: .seconds(6))
    try await Task.sleep(for: .milliseconds(50))
    XCTAssertEqual(RewriteStubURLProtocol.stoppedCount, 0, "nothing ends before the timeout")
    await clock.advance(by: .seconds(1))
    let outcome = await consumer.value
    let elapsed = ContinuousClock.now - started
    XCTAssertEqual(category(outcome.error), .timeout)
    XCTAssertLessThan(
      elapsed, .milliseconds(500), "client-side handling must stay within the tolerance")
    // `stopLoading` lands on URLSession's own queue after the task is cancelled,
    // so the count is polled rather than read on the same turn.
    var stopped = RewriteStubURLProtocol.stoppedCount
    let stopDeadline = ContinuousClock.now.advanced(by: .seconds(2))
    while stopped == 0, ContinuousClock.now < stopDeadline {
      try await Task.sleep(for: .milliseconds(10))
      stopped = RewriteStubURLProtocol.stoppedCount
    }
    XCTAssertEqual(stopped, 1, "the request is cancelled on timeout")
    let sleeps = await clock.sleepCount
    XCTAssertEqual(sleeps, 1)
  }

  func testCancellationStopsReadingAndEndsTheStream() async throws {
    RewriteStubURLProtocol.script(.init(hang: true), path: "/v1/rewrite")
    let (client, _) = makeClient()
    let stream = client.rewrite(request: try request(), endpoint: endpoint, timeout: .seconds(20))
    let consumer = Task { await collectItems(stream) }
    for _ in 0..<200 {
      if RewriteStubURLProtocol.seenRequests.count == 1 { break }
      try await Task.sleep(for: .milliseconds(5))
    }
    consumer.cancel()
    let outcome = await consumer.value
    // Cancelling the consumer ends the stream (nil) and cancels the producer.
    XCTAssertTrue(
      outcome.error == nil || outcome.error is CancellationError,
      "\(String(describing: outcome.error))")
    XCTAssertTrue(outcome.items.isEmpty)
    for _ in 0..<200 {
      if RewriteStubURLProtocol.stoppedCount == 1 { break }
      try await Task.sleep(for: .milliseconds(5))
    }
    XCTAssertEqual(RewriteStubURLProtocol.stoppedCount, 1)
  }

  func testNonTwoHundredBodyIsBoundedAndOnlyItsCodeIsUsed() async throws {
    let (client, _) = makeClient()
    let big = Data(repeating: UInt8(ascii: "z"), count: 70_000)
    let cases: [(Int, Data, RewriteFailureCategory)] = [
      (
        400, Data(#"{"error":{"code":"unsupported_version","message":"x"}}"#.utf8),
        .unsupportedSchemaVersion
      ),
      (
        400, Data(#"{"error":{"code":"invalid_request","message":"x"}}"#.utf8),
        .serverValidationFailed
      ),
      (401, Data(), .authenticationFailed),
      (403, big, .authenticationFailed),
      (413, Data(#"{"error":{"code":"too_large","message":"x"}}"#.utf8), .serverValidationFailed),
      (429, Data(#"{"error":{"code":"server_busy","message":"x"}}"#.utf8), .backendUnavailable),
      (503, big, .backendUnavailable),
      (500, Data("<html>".utf8), .transportError),
    ]
    for (status, body, expected) in cases {
      RewriteStubURLProtocol.reset()
      RewriteStubURLProtocol.script(
        .init(status: status, headers: ["Content-Type": "application/json"], chunks: [body]),
        path: "/v1/rewrite")
      let outcome = await collectItems(
        client.rewrite(request: try request(), endpoint: endpoint, timeout: .seconds(20)))
      XCTAssertEqual(category(outcome.error), expected, "status \(status)")
      XCTAssertTrue(outcome.error is RewriteFailure)
    }
  }

  func testTransportErrorsMapToUnreachableOrTransportError() async throws {
    let (client, _) = makeClient()
    for (code, expected) in [
      (URLError.Code.cannotConnectToHost, RewriteFailureCategory.serverUnreachable),
      (.dnsLookupFailed, .serverUnreachable), (.secureConnectionFailed, .transportError),
      (.badServerResponse, .transportError), (.timedOut, .timeout),
    ] {
      RewriteStubURLProtocol.reset()
      RewriteStubURLProtocol.script(.init(transportError: code), path: "/v1/rewrite")
      let outcome = await collectItems(
        client.rewrite(request: try request(), endpoint: endpoint, timeout: .seconds(20)))
      XCTAssertEqual(category(outcome.error), expected, "\(code)")
    }
  }

  func testFirstByteIsYieldedBeforeAnyEvent() async throws {
    RewriteStubURLProtocol.script(.init(chunks: [resultLine()]), path: "/v1/rewrite")
    let (client, _) = makeClient()
    let outcome = await collectItems(
      client.rewrite(request: try request(), endpoint: endpoint, timeout: .seconds(20)))
    XCTAssertEqual(outcome.items.first, .firstByte)
    XCTAssertEqual(outcome.items.filter { $0 == .firstByte }.count, 1)
    guard case .event(.result) = outcome.items[1] else { return XCTFail("result expected second") }
  }

  func testHealthMapsEveryObservationToItsCategory() async throws {
    let (client, _) = makeClient(credential: "c")
    func probe(_ script: RewriteStubURLProtocol.Script) async -> RewriteConnectionCategory {
      RewriteStubURLProtocol.reset()
      RewriteStubURLProtocol.script(script, path: "/v1/rewrite/health")
      do {
        return RewriteConnectionCategory.evaluate(try await client.health(endpoint: endpoint))
      } catch let failure as RewriteConnectionFailure {
        return failure.category
      } catch {
        XCTFail("\(error)")
        return .serverUnreachable
      }
    }
    func health(
      service: String = "localflow-rewrite", versions: [Int] = [1], state: String = "ready"
    ) -> Data {
      Data(
        #"{"schema_version":1,"service":"\#(service)","protocol_versions":\#(versions),"server":{"name":"flowd","version":"0.2.0"},"modes":["clean"],"backend":{"state":"\#(state)","kind":"openai-compatible","model":"qwen"},"prompt_versions":{"clean":1},"shield_version":1}"#
          .utf8)
    }
    let json = ["Content-Type": "application/json"]
    let connected = await probe(.init(headers: json, chunks: [health()]))
    XCTAssertEqual(connected, .connected)
    XCTAssertEqual(
      RewriteStubURLProtocol.seenRequests.first?.value(forHTTPHeaderField: "Authorization"),
      "Bearer c")
    XCTAssertEqual(RewriteStubURLProtocol.seenRequests.first?.httpMethod, "GET")
    XCTAssertEqual(RewriteStubURLProtocol.seenRequests.first?.timeoutInterval, 10)
    let unreachable = await probe(.init(transportError: .cannotConnectToHost))
    XCTAssertEqual(unreachable, .serverUnreachable)
    let tls = await probe(.init(transportError: .secureConnectionFailed))
    XCTAssertEqual(tls, .serverUnreachable)
    let unauthorized = await probe(.init(status: 401, headers: json, chunks: []))
    XCTAssertEqual(unauthorized, .authenticationFailed)
    let forbidden = await probe(.init(status: 403, headers: json, chunks: []))
    XCTAssertEqual(forbidden, .authenticationFailed)
    let missing = await probe(.init(status: 404, headers: json, chunks: []))
    XCTAssertEqual(missing, .rewriteServiceUnavailable)
    let html = await probe(
      .init(headers: ["Content-Type": "text/html"], chunks: [Data("<html>".utf8)]))
    XCTAssertEqual(html, .rewriteServiceUnavailable)
    let other = await probe(.init(headers: json, chunks: [health(service: "something-else")]))
    XCTAssertEqual(other, .rewriteServiceUnavailable)
    let version = await probe(.init(headers: json, chunks: [health(versions: [2])]))
    XCTAssertEqual(version, .incompatibleVersion)
    let loading = await probe(.init(headers: json, chunks: [health(state: "loading")]))
    XCTAssertEqual(loading, .backendUnavailable)
    let down = await probe(
      .init(
        status: 503, headers: json,
        chunks: [Data(#"{"error":{"code":"backend_unavailable","message":"m"}}"#.utf8)]))
    XCTAssertEqual(down, .backendUnavailable)
    // Pre-request categories come from the settings snapshot and send nothing.
    let blocked = RewriteSettings(
      enabled: true, mode: .clean, endpoint: URL(string: "http://10.0.0.2:8080"),
      endpointOrigin: "http://10.0.0.2:8080", timeoutSeconds: 20, insecureOverride: false,
      credentialPresent: true)
    XCTAssertEqual(RewriteConnectionCategory.preflight(blocked), .insecureEndpointBlocked)
    let noCredential = RewriteSettings(
      enabled: true, mode: .clean, endpoint: URL(string: "https://h.example"),
      endpointOrigin: "https://h.example:443", timeoutSeconds: 20, insecureOverride: false,
      credentialPresent: false)
    XCTAssertEqual(RewriteConnectionCategory.preflight(noCredential), .missingCredential)
    let ok = RewriteSettings(
      enabled: true, mode: .clean, endpoint: URL(string: "https://h.example"),
      endpointOrigin: "https://h.example:443", timeoutSeconds: 20, insecureOverride: false,
      credentialPresent: true)
    XCTAssertNil(RewriteConnectionCategory.preflight(ok))
  }

  func testSessionIsEphemeralAndInvalidatable() throws {
    let configuration = RewriteClient.makeConfiguration()
    XCTAssertNil(configuration.urlCache)
    XCTAssertNil(configuration.httpCookieStorage)
    XCTAssertNil(configuration.urlCredentialStorage)
    XCTAssertFalse(configuration.waitsForConnectivity)
    XCTAssertFalse(configuration.httpShouldSetCookies)
    XCTAssertEqual(configuration.requestCachePolicy, .reloadIgnoringLocalAndRemoteCacheData)
    let (client, _) = makeClient()
    XCTAssertFalse(client.hasSession, "the session is created lazily")
    RewriteStubURLProtocol.script(.init(chunks: [resultLine()]), path: "/v1/rewrite")
    let expectation = expectation(description: "request")
    let stream = client.rewrite(request: try request(), endpoint: endpoint, timeout: .seconds(20))
    Task {
      _ = await collectItems(stream)
      expectation.fulfill()
    }
    wait(for: [expectation], timeout: 5)
    XCTAssertTrue(client.hasSession)
    client.invalidate()
    XCTAssertFalse(client.hasSession)
  }
}

func collectItems(_ stream: AsyncThrowingStream<RewriteTransportItem, Error>) async
  -> (items: [RewriteTransportItem], error: Error?)
{
  var items: [RewriteTransportItem] = []
  do {
    for try await item in stream { items.append(item) }
    return (items, nil)
  } catch {
    return (items, error)
  }
}

extension RewriteClientTests {
  func testHealthRejectsOversizedBodyRatherThanAcceptingValidPrefix() async throws {
    let (client, _) = makeClient()
    let body = Data(("{}" + String(repeating: " ", count: 8_192)).utf8)
    RewriteStubURLProtocol.script(.init(chunks: [body]), path: "/v1/rewrite/health")
    do {
      _ = try await client.health(endpoint: endpoint)
      XCTFail("Oversized health must fail before decoding")
    } catch let failure as RewriteConnectionFailure {
      XCTAssertEqual(failure.category, .rewriteServiceUnavailable)
      XCTAssertEqual(failure.diagnostic, "health_too_large")
    }
  }
}

// MARK: - Analysis transport (T030)

extension RewriteClientTests {
  private func makeAnalysisClient(
    credential: String? = nil, clock: any DictationClock = SystemDictationClock()
  ) -> AnalysisClient {
    let store = FakeRewriteCredentialStore()
    if let credential { try? store.write(origin: endpoint.origin, secret: credential) }
    return AnalysisClient(credentials: store, clock: clock) { configuration in
      configuration.protocolClasses = [RewriteStubURLProtocol.self]
    }
  }

  private func analysisHealth(
    service: String = "localflow-analysis", resultSchema: Int? = 1
  ) -> Data {
    let version = resultSchema.map { "\($0)" } ?? "null"
    return Data(
      #"{"schema_version":1,"service":"\#(service)","protocol_versions":[1],"server":{"name":"flowd","version":"0.3.0"},"stages":["full","chunk","synthesis"],"backend":{"state":"ready","kind":"openai-compatible","model":"qwen","json_schema":true},"prompt_versions":{"full":1,"chunk":1,"synthesis":1},"result_schema_version":\#(version),"limits":{"input_bytes":98304,"output_bytes":98304,"context_tokens":32768,"concurrency":1},"caps":{"sources_per_item":10,"topics":10,"decisions":10,"action_items":15,"next_steps":15,"open_questions":15,"risks":15}}"#
        .utf8)
  }

  private func analysisProbe(_ script: RewriteStubURLProtocol.Script) async -> (
    health: AnalysisHealth?, failure: AnalysisFailureCategory?, detail: String?
  ) {
    RewriteStubURLProtocol.reset()
    RewriteStubURLProtocol.script(script, path: "/v1/analysis/health")
    do {
      return (try await makeAnalysisClient(credential: "c").health(endpoint: endpoint), nil, nil)
    } catch let failure as AnalysisFailure {
      return (nil, failure.category, failure.detail)
    } catch {
      return (nil, nil, "\(error)")
    }
  }

  func testAnalysisHealthMapsEveryObservation() async throws {
    let json = ["Content-Type": "application/json"]

    let (ok, _, _) = await analysisProbe(.init(headers: json, chunks: [analysisHealth()]))
    let health = try XCTUnwrap(ok)
    XCTAssertEqual(health.service, "localflow-analysis")
    XCTAssertEqual(health.resultSchemaVersion, 1)
    XCTAssertEqual(health.limits?.inputBytes, 98_304)
    XCTAssertEqual(health.caps?.actionItems, 15)
    XCTAssertEqual(
      RewriteStubURLProtocol.seenRequests.first?.value(forHTTPHeaderField: "Authorization"),
      "Bearer c")
    XCTAssertEqual(RewriteStubURLProtocol.seenRequests.first?.url?.path, "/v1/analysis/health")

    // A flowd without the analysis service → server_unavailable + fixed message.
    let missing = await analysisProbe(.init(status: 404, headers: json, chunks: []))
    XCTAssertEqual(missing.failure, .serverUnavailable)
    XCTAssertEqual(missing.detail, AnalysisClient.unavailableMessage)
    let other = await analysisProbe(
      .init(headers: json, chunks: [analysisHealth(service: "something-else")]))
    XCTAssertEqual(other.failure, .serverUnavailable)
    XCTAssertEqual(other.detail, AnalysisClient.unavailableMessage)
    let html = await analysisProbe(
      .init(headers: ["Content-Type": "text/html"], chunks: [Data("<html>".utf8)]))
    XCTAssertEqual(html.failure, .serverUnavailable)

    // A mismatched result schema → unsupported_version.
    let version = await analysisProbe(
      .init(headers: json, chunks: [analysisHealth(resultSchema: 2)]))
    XCTAssertEqual(version.failure, .unsupportedVersion)
    let absent = await analysisProbe(
      .init(headers: json, chunks: [analysisHealth(resultSchema: nil)]))
    XCTAssertEqual(absent.failure, .unsupportedVersion)

    // The shared status mappings still apply.
    let unauthorized = await analysisProbe(.init(status: 401, headers: json, chunks: []))
    XCTAssertEqual(unauthorized.failure, .authenticationFailed)
    let busy = await analysisProbe(.init(status: 503, headers: json, chunks: []))
    XCTAssertEqual(busy.failure, .backendUnavailable)
    let unreachable = await analysisProbe(.init(transportError: .cannotConnectToHost))
    XCTAssertEqual(unreachable.failure, .serverUnreachable)
  }

  /// The analysis mapping must not have disturbed the rewrite mapping.
  func testRewriteHealthUnchangedByAnalysisClient() async throws {
    let json = ["Content-Type": "application/json"]
    let (client, _) = makeClient(credential: "c")
    let body = Data(
      #"{"schema_version":1,"service":"localflow-rewrite","protocol_versions":[1],"server":{"name":"flowd","version":"0.2.0"},"modes":["clean"],"backend":{"state":"ready","kind":"openai-compatible","model":"qwen"},"prompt_versions":{"clean":1},"shield_version":1}"#
        .utf8)
    RewriteStubURLProtocol.script(.init(headers: json, chunks: [body]), path: "/v1/rewrite/health")
    let health = try await client.health(endpoint: endpoint)
    XCTAssertEqual(RewriteConnectionCategory.evaluate(health), .connected)
    XCTAssertEqual(RewriteStubURLProtocol.seenRequests.first?.url?.path, "/v1/rewrite/health")
  }

  func testAnalysisStreamStopsAtLineCap() async throws {
    let client = makeAnalysisClient()
    let accepted =
      Data(
        #"{"type":"accepted","schema_version":1,"request_id":"r1"}"#.utf8) + Data("\n".utf8)
    let oversized = Data(String(repeating: "x", count: AnalysisBounds.maxLineBytes + 1).utf8)
    RewriteStubURLProtocol.script(
      .init(chunks: [accepted, oversized]), path: "/v1/analysis/meeting")
    var outcome: (items: [AnalysisTransportItem], error: Error?) = ([], nil)
    do {
      for try await item in client.analyze(
        request: analysisRequest(), endpoint: endpoint, timeout: .seconds(20))
      { outcome.items.append(item) }
    } catch { outcome.error = error }
    XCTAssertEqual(
      (outcome.error as? AnalysisFailure)?.category, .oversizedResponse)
    XCTAssertEqual(
      RewriteStubURLProtocol.seenRequests.first?.url?.path, "/v1/analysis/meeting")
    XCTAssertEqual(
      RewriteStubURLProtocol.seenRequests.first?.value(forHTTPHeaderField: "Accept"),
      "application/x-ndjson")
  }

  private func analysisProgressLine(chars: Int) -> Data {
    Data(
      #"{"type":"progress","schema_version":1,"request_id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","stage":"synthesis","chars":\#(chars)}"#
        .utf8) + Data("\n".utf8)
  }

  private func collectAnalysis(_ client: AnalysisClient, endpoint: RewriteEndpoint? = nil)
    async -> (items: [AnalysisTransportItem], error: Error?)
  {
    var outcome: (items: [AnalysisTransportItem], error: Error?) = ([], nil)
    do {
      for try await item in client.analyze(
        request: analysisRequest(), endpoint: endpoint ?? self.endpoint, timeout: .seconds(20))
      { outcome.items.append(item) }
    } catch { outcome.error = error }
    return outcome
  }

  /// A long generation streams a progress line every 250 ms: a full 300 s
  /// request carries ~1,200 of them, well past one line's 98,304 bytes. The
  /// line cap is per line; only the stream cap bounds the total.
  func testAnalysisProgressBeyondOneLineCapIsAccepted() async throws {
    let client = makeAnalysisClient()
    let lines = (0..<1_200).map { analysisProgressLine(chars: $0 * 40) }
    let streamBytes = lines.reduce(0) { $0 + $1.count }
    XCTAssertGreaterThan(streamBytes, AnalysisBounds.maxLineBytes)
    // Leave room for the largest result line after a full-timeout run.
    XCTAssertLessThan(streamBytes + AnalysisBounds.maxLineBytes, AnalysisBounds.maxStreamBytes / 2)
    RewriteStubURLProtocol.script(.init(chunks: lines), path: "/v1/analysis/meeting")
    let outcome = await collectAnalysis(client)
    XCTAssertNil(outcome.error)
    guard case .completed(_, let responseBytes) = outcome.items.last else {
      return XCTFail("completed expected last")
    }
    XCTAssertEqual(responseBytes, streamBytes)
    XCTAssertEqual(outcome.items.count, 1 + 1_200 + 1)
  }

  func testAnalysisStreamStopsAtTotalStreamCap() async throws {
    let client = makeAnalysisClient()
    let line = analysisProgressLine(chars: 1)
    let lines = Array(repeating: line, count: AnalysisBounds.maxStreamBytes / line.count + 2)
    RewriteStubURLProtocol.script(.init(chunks: lines), path: "/v1/analysis/meeting")
    let outcome = await collectAnalysis(client)
    XCTAssertEqual((outcome.error as? AnalysisFailure)?.category, .oversizedResponse)
    XCTAssertEqual((outcome.error as? AnalysisFailure)?.detail, "stream_bytes")
    XCTAssertLessThanOrEqual(outcome.items.count - 1, AnalysisBounds.maxStreamBytes / line.count)
  }

  /// The summary-server headers are fixed when the endpoint is pinned (at
  /// admission); a Settings change mid-run does not reach later requests.
  func testPinnedSummaryHeadersSurviveASettingsChange() async throws {
    let suite = "LocalFlow-analysis-pin-\(UUID())"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(SummaryServer.remote.rawValue, forKey: SummaryServer.defaultsKey)
    defaults.set("https://first.example/v1", forKey: SummaryServer.urlKey)
    defaults.set("model-a", forKey: SummaryServer.modelKey)
    let store = FakeRewriteCredentialStore()
    try store.write(origin: SummaryServer.credentialAccount, secret: "key-a")
    let client = AnalysisClient(credentials: store, defaults: defaults) { configuration in
      configuration.protocolClasses = [RewriteStubURLProtocol.self]
    }
    let pinned = client.pinned(endpoint)
    XCTAssertNotEqual(
      pinned.summaryBackendKey, endpoint.summaryBackendKey, "the backend is part of the key")
    XCTAssertFalse(pinned.summaryBackendKey.contains("key-a"), "never the credential")

    defaults.set("https://second.example/v1", forKey: SummaryServer.urlKey)
    defaults.set("model-b", forKey: SummaryServer.modelKey)
    try store.write(origin: SummaryServer.credentialAccount, secret: "key-b")
    RewriteStubURLProtocol.script(.init(chunks: []), path: "/v1/analysis/meeting")
    _ = await collectAnalysis(client, endpoint: pinned)
    let sent = try XCTUnwrap(RewriteStubURLProtocol.seenRequests.first)
    XCTAssertEqual(
      sent.value(forHTTPHeaderField: SummaryServer.primaryURLHeader), "https://first.example/v1")
    XCTAssertEqual(sent.value(forHTTPHeaderField: SummaryServer.primaryModelHeader), "model-a")
    XCTAssertEqual(sent.value(forHTTPHeaderField: SummaryServer.primaryKeyHeader), "key-a")

    // An unpinned endpoint (the Settings connection test) reads the current choice.
    RewriteStubURLProtocol.reset()
    RewriteStubURLProtocol.script(.init(chunks: []), path: "/v1/analysis/meeting")
    _ = await collectAnalysis(client)
    XCTAssertEqual(
      RewriteStubURLProtocol.seenRequests.first?.value(
        forHTTPHeaderField: SummaryServer.primaryModelHeader), "model-b")
  }

  func testAnalysisTLSFailuresCarryATLSDetail() async throws {
    let client = makeAnalysisClient()
    for (code, detail) in [
      (URLError.Code.serverCertificateUntrusted, "tls_failure"),
      (.secureConnectionFailed, "tls_failure"), (.badServerResponse, "transport_error"),
      (.cannotConnectToHost, nil),
    ] {
      RewriteStubURLProtocol.reset()
      RewriteStubURLProtocol.script(.init(transportError: code), path: "/v1/analysis/meeting")
      let outcome = await collectAnalysis(client)
      let failure = outcome.error as? AnalysisFailure
      XCTAssertEqual(failure?.category, .serverUnreachable, "\(code)")
      XCTAssertEqual(failure?.detail, detail, "\(code)")
    }
  }

  func testAnalysisStreamYieldsEventsAndCompletion() async throws {
    let client = makeAnalysisClient()
    let lines = [
      #"{"type":"accepted","schema_version":1,"request_id":"r1","server":{"name":"flowd","version":"0.3.0"}}"#,
      #"{"type":"progress","schema_version":1,"request_id":"r1","stage":"full","chars":12}"#,
    ].map { Data($0.utf8) + Data("\n".utf8) }
    RewriteStubURLProtocol.script(.init(chunks: lines), path: "/v1/analysis/meeting")
    var items: [AnalysisTransportItem] = []
    for try await item in client.analyze(
      request: analysisRequest(), endpoint: endpoint, timeout: .seconds(20))
    { items.append(item) }
    XCTAssertEqual(items.first, .firstByte)
    guard case .event(.accepted) = items[1] else { return XCTFail("accepted expected") }
    guard case .event(.progress(_, let stage, let chars)) = items[2] else {
      return XCTFail("progress expected")
    }
    XCTAssertEqual(stage, "full")
    XCTAssertEqual(chars, 12)
    guard case .completed = items.last else { return XCTFail("completed expected last") }
  }

  func testAnalysisSessionIsEphemeralAndInvalidatable() async throws {
    let client = makeAnalysisClient()
    XCTAssertFalse(client.hasSession)
    RewriteStubURLProtocol.script(
      .init(chunks: [analysisHealth()]), path: "/v1/analysis/health")
    _ = try await client.health(endpoint: endpoint)
    XCTAssertTrue(client.hasSession)
    client.invalidate()
    XCTAssertFalse(client.hasSession)
  }

  private func analysisRequest() -> AnalysisRequest {
    AnalysisRequest(
      requestID: UUID(), runID: UUID(), stage: .full, chunk: nil,
      meeting: AnalysisRequest.Meeting(
        id: UUID(), title: "Test", startedAt: "2026-09-20T09:00:00Z",
        durationMs: 60_000, timeZone: "UTC",
        languagePolicy: AnalysisRequest.LanguagePolicyValue(
          output: .en, preserveTerms: true)),
      participants: [], segments: [], notes: [], partials: nil)
  }
}

/// Feature 012: the one-entry protocol-version cache (ADR 0023).
extension RewriteClientTests {
  private func versionsHealth(_ versions: [Int]) -> RewriteStubURLProtocol.Script {
    .init(
      headers: ["Content-Type": "application/json"],
      chunks: [
        Data(
          #"{"schema_version":1,"service":"localflow-rewrite","protocol_versions":\#(versions),"server":{"name":"flowd","version":"0.3.0"},"modes":["clean"],"backend":{"state":"ready","kind":"openai-compatible","model":"qwen"},"prompt_versions":{"clean":5},"shield_version":1}"#
            .utf8)
      ])
  }
  private var healthProbes: Int {
    RewriteStubURLProtocol.lock.withLock {
      RewriteStubURLProtocol.seenRequests.filter { $0.url?.path == "/v1/rewrite/health" }.count
    }
  }

  func testProtocolVersionsAreFetchedOncePerOrigin() async throws {
    RewriteStubURLProtocol.script(versionsHealth([1, 2]), path: "/v1/rewrite/health")
    let client = RewriteClient(credentials: FakeRewriteCredentialStore()) { configuration in
      configuration.protocolClasses = [RewriteStubURLProtocol.self]
    }
    let local = RewriteEndpoint(
      url: URL(string: "http://127.0.0.1:8080")!, origin: "http://127.0.0.1:8080")
    let versions = await client.protocolVersions(endpoint: local)
    XCTAssertEqual(versions, [1, 2])
    let versions1 = await client.protocolVersions(endpoint: local)
    XCTAssertEqual(versions1, [1, 2])
    XCTAssertEqual(healthProbes, 1, "cached for the app run")
    XCTAssertEqual(client.cachedProtocolVersions.origin, local.origin)
  }

  func testAnotherOriginReplacesTheSingleEntry() async throws {
    RewriteStubURLProtocol.script(versionsHealth([1, 2]), path: "/v1/rewrite/health")
    let client = RewriteClient(credentials: FakeRewriteCredentialStore()) { configuration in
      configuration.protocolClasses = [RewriteStubURLProtocol.self]
    }
    let first = RewriteEndpoint(
      url: URL(string: "http://127.0.0.1:8080")!, origin: "http://127.0.0.1:8080")
    let second = RewriteEndpoint(
      url: URL(string: "http://127.0.0.1:9090")!, origin: "http://127.0.0.1:9090")
    _ = await client.protocolVersions(endpoint: first)
    RewriteStubURLProtocol.script(versionsHealth([1]), path: "/v1/rewrite/health")
    let versions2 = await client.protocolVersions(endpoint: second)
    XCTAssertEqual(versions2, [1])
    XCTAssertEqual(client.cachedProtocolVersions.origin, second.origin)
    XCTAssertEqual(healthProbes, 2)
    // Back to the first origin: the entry was replaced, so health is asked again.
    RewriteStubURLProtocol.script(versionsHealth([1, 2]), path: "/v1/rewrite/health")
    let versions3 = await client.protocolVersions(endpoint: first)
    XCTAssertEqual(versions3, [1, 2])
    XCTAssertEqual(healthProbes, 3)
  }

  func testFailedHealthIsNotCached() async throws {
    let client = RewriteClient(credentials: FakeRewriteCredentialStore()) { configuration in
      configuration.protocolClasses = [RewriteStubURLProtocol.self]
    }
    let local = RewriteEndpoint(
      url: URL(string: "http://127.0.0.1:8080")!, origin: "http://127.0.0.1:8080")
    let versions4 = await client.protocolVersions(endpoint: local)
    XCTAssertNil(versions4)
    RewriteStubURLProtocol.script(versionsHealth([1, 2]), path: "/v1/rewrite/health")
    let versions5 = await client.protocolVersions(endpoint: local)
    XCTAssertEqual(versions5, [1, 2])
    XCTAssertEqual(healthProbes, 2)
  }

  func testA400ToAV2RequestDiscardsTheEntry() async throws {
    RewriteStubURLProtocol.script(versionsHealth([1, 2]), path: "/v1/rewrite/health")
    let (client, _) = makeClient(credential: "c")
    _ = await client.protocolVersions(endpoint: endpoint)
    XCTAssertEqual(client.cachedProtocolVersions.origin, endpoint.origin)
    RewriteStubURLProtocol.script(
      .init(
        status: 400, headers: ["Content-Type": "application/json"],
        chunks: [Data(#"{"error":{"code":"invalid_request","message":"x"}}"#.utf8)]),
      path: "/v1/rewrite")
    // A 400 to a v1 request keeps the entry.
    let v1 = try RewriteRequest(requestID: UUID(), mode: .clean, text: "hello")
    _ = await collectItems(client.rewrite(request: v1, endpoint: endpoint, timeout: .seconds(5)))
    XCTAssertEqual(client.cachedProtocolVersions.origin, endpoint.origin)
    let snapshot = AppContextSnapshot.make(.init(appName: "Mail", windowTitle: "Hello"))
    let v2 = try RewriteRequest(
      requestID: UUID(), mode: .clean, text: "hello", context: snapshot.canonicalJSON())
    let outcome = await collectItems(
      client.rewrite(request: v2, endpoint: endpoint, timeout: .seconds(5)))
    XCTAssertEqual((outcome.error as? RewriteFailure)?.category, .serverValidationFailed)
    XCTAssertNil(client.cachedProtocolVersions.origin)
    // The v2 body carried the stored bytes verbatim.
    let body = try XCTUnwrap(RewriteStubURLProtocol.seenBodies.last)
    XCTAssertTrue(String(decoding: body, as: UTF8.self).contains(snapshot.canonicalString))
  }
}
