import CryptoKit
import XCTest

@testable import LocalFlow
@testable import LocalFlowCore

/// A scripted flowd for dictation: it cuts contiguous 239,360-sample windows from the
/// audio it receives and answers each with a `window_result`.
final class FakeFlowdDictation: @unchecked Sendable {
  enum Behavior {
    case normal
    /// Every `dictation_start` gets this error code.
    case startError(String)
    /// The first hello gets `token_expired`.
    case expireFirstHello
    /// After `dictation_end`, nothing more.
    case silentAfterEnd
    /// After `dictation_end`, `progress` frames only.
    case progressAfterEnd
    /// A window whose evidence disagrees with its sample count.
    case badWindow
  }
  let lock = NSLock()
  var behavior: Behavior = .normal
  private(set) var received: [[Float]] = []
  private(set) var ends: [Int] = []
  private(set) var hellos = 0
  private(set) var tokens: [String?] = []
  var transports: [FakeRemoteTransport] = []

  func transport(server: FakeRemoteServer = FakeRemoteServer()) -> FakeRemoteTransport {
    var samples: [Float] = []
    var windowsSent = 0
    var accepted = false
    let transport = FakeRemoteTransport(server: server)
    transport.setHandler { [self] event in
      lock.withLock {
        switch event {
        case .hello(_, let token, _):
          hellos += 1
          tokens.append(token)
          if case .expireFirstHello = behavior, hellos == 1 {
            return [.message(["type": "error", "code": "token_expired"])]
          }
          return [.message(["type": "ready"])]
        case .control(let object):
          switch object["type"] as? String {
          case "dictation_start":
            received.append([])
            if case .startError(let code) = behavior {
              return [.message(["type": "error", "op": 1, "code": code])]
            }
            accepted = true
            return [
              .message([
                "type": "dictation_accepted", "op": 1, "window_samples": 239_360,
                "model": [
                  "engine": "FluidAudio", "model_id": "m", "model_revision": "r",
                  "manifest_hash": "h", "sdk": "0.15.7",
                ],
              ])
            ]
          case "dictation_end":
            let total = object["total_samples"] as? Int ?? -1
            ends.append(total)
            switch behavior {
            case .silentAfterEnd: return []
            case .progressAfterEnd:
              return [.message(["type": "progress", "op": 1, "state": "recognizing"])]
            default: break
            }
            var replies: [FakeServerReply] = []
            let tail = samples.count - windowsSent * 239_360
            if tail > 0 { replies.append(window(index: windowsSent, count: tail)) }
            windowsSent += tail > 0 ? 1 : 0
            replies.append(
              .message(["type": "dictation_complete", "op": 1, "windows": windowsSent]))
            return replies
          case "dictation_cancel":
            return [.message(["type": "cancelled", "op": 1])]
          default:
            return []
          }
        case .audio(let frame):
          guard accepted else { return [.close(1008)] }
          samples += frame
          received[received.count - 1] += frame
          var replies: [FakeServerReply] = []
          while samples.count >= (windowsSent + 1) * 239_360 {
            replies.append(window(index: windowsSent, count: 239_360))
            windowsSent += 1
          }
          return replies
        }
      }
    }
    lock.withLock { transports.append(transport) }
    return transport
  }

  private func window(index: Int, count: Int) -> FakeServerReply {
    let evidenceSamples: Int
    if case .badWindow = behavior { evidenceSamples = count + 1 } else { evidenceSamples = count }
    return .message([
      "type": "window_result", "op": 1, "index": index, "sample_start": index * 239_360,
      "sample_count": count, "text": "window \(index)", "tokens": [],
      "evidence": [
        "text": "window \(index)", "samples": evidenceSamples,
        "padded_samples": max(4_800, evidenceSamples), "timings_available": false,
        "tokens": [],
      ],
      "recognition_ms": 50,
    ])
  }
}

final class FakeSessionCredentials: RemoteSessionCredentials, @unchecked Sendable {
  let lock = NSLock()
  var token: String? = "lfa_1"
  var fresh: String? = "lfa_2"
  private(set) var refreshed = 0
  private(set) var errors: [RemoteErrorCode] = []
  private(set) var pinMismatches = 0
  func sessionAccessToken() async -> String? { lock.withLock { token } }
  func sessionAccessTokenExpired() async -> String? {
    lock.withLock {
      refreshed += 1
      token = fresh
      return fresh
    }
  }
  func sessionServerError(_ code: RemoteErrorCode) async { lock.withLock { errors.append(code) } }
  func sessionPinMismatch() async { lock.withLock { pinMismatches += 1 } }
}

/// Recorded samples as the capture adapter reports them; the test grows it.
final class RecordingProgress: @unchecked Sendable {
  private let lock = NSLock()
  private var value = 0
  var samples: Int {
    get { lock.withLock { value } }
    set { lock.withLock { value = newValue } }
  }
  static func sample(_ index: Int) -> Float { Float(index % 1_000) / 1_000 }
}

final class RemoteDictationSessionTests: XCTestCase {
  private var clock: ManualRemoteClock!
  private var flowd: FakeFlowdDictation!
  private var credentials: FakeSessionCredentials!
  private var progress: RecordingProgress!

  override func setUp() {
    clock = ManualRemoteClock()
    flowd = FakeFlowdDictation()
    credentials = FakeSessionCredentials()
    progress = RecordingProgress()
  }

  private func session(
    threshold: Duration = .milliseconds(1_500),
    opener: FakeRemoteTransportOpener? = nil
  ) -> RemoteDictationSession {
    let flowd = flowd!
    let progress = progress!
    return RemoteDictationSession(
      configuration: .init(
        channelURL: URL(string: "wss://mini.example.com/v1/remote/channel")!,
        serverKey: FakeRemoteServer.serverKey.publicKey.rawRepresentation,
        boost: RemoteBoost(terms: [.init(entryID: "z", canonical: "Zabbix")], governed: ["zabbix"]),
        threshold: threshold),
      transports: opener ?? FakeRemoteTransportOpener { _ in flowd.transport() },
      credentials: credentials, clock: clock,
      read: { start, count in (start..<start + count).map(RecordingProgress.sample) },
      recorded: { progress.samples })
  }

  /// Advances the pump one 200 ms tick and lets the tasks run.
  private func tick(_ times: Int = 1) async {
    for _ in 0..<times {
      try? await Task.sleep(for: .milliseconds(10))
      clock.advance(by: .milliseconds(200))
      try? await Task.sleep(for: .milliseconds(10))
    }
  }

  private func waitForState(
    _ session: RemoteDictationSession, _ expected: RemoteDictationSession.State
  ) async -> Bool {
    await eventually { await session.state == expected }
  }

  func testStreamsDuringRecordingAndCompletes() async throws {
    let session = session()
    let initial = await session.state
    XCTAssertEqual(initial, .connecting)
    await session.start()
    let streaming = await waitForState(session, .streaming)
    XCTAssertTrue(streaming)
    progress.samples = 20_000
    await tick()
    let firstFrames = await eventually { self.flowd.received.first?.count == 20_000 }
    XCTAssertTrue(firstFrames)
    // Frames never exceed 16,000 samples.
    let frameSizes = flowd.transports[0].receivedEvents.compactMap { event -> Int? in
      if case .audio(let samples) = event { return samples.count }
      return nil
    }
    XCTAssertEqual(frameSizes, [16_000, 4_000])
    // A full window is recognized while recording continues.
    progress.samples = 300_000
    await tick()
    let windowZero = await eventually { self.flowd.received.first?.count == 300_000 }
    XCTAssertTrue(windowZero)
    let result = await session.finish(totalSamples: 312_000)
    guard case .success(let remote) = result else { return XCTFail("\(result)") }
    XCTAssertEqual(flowd.ends, [312_000])
    XCTAssertEqual(Set(remote.windows.keys), [0, 239_360])
    XCTAssertEqual(remote.windows[239_360]?.window.text, "window 1")
    XCTAssertEqual(remote.windows[0]?.recognitionSeconds, 0.05)
    XCTAssertEqual(remote.nextOp, 2)
    XCTAssertEqual(flowd.received.first?.first, RecordingProgress.sample(0))
    XCTAssertEqual(flowd.received.first?.last, RecordingProgress.sample(311_999))
    XCTAssertEqual(flowd.tokens, ["lfa_1"])
    let final = await session.state
    XCTAssertEqual(final, .complete)
  }

  func testAWholeRecordingFlushedAtReleaseReachesTheServer() async throws {
    // A retry: 20 s of audio already recorded, sent at once over a socket that is slower
    // than the loop that queues frames.
    let flowd = flowd!
    let session = session(
      opener: FakeRemoteTransportOpener { _ in
        let transport = flowd.transport()
        transport.sendDelay = .milliseconds(1)
        return transport
      })
    await session.start()
    let streaming = await waitForState(session, .streaming)
    XCTAssertTrue(streaming)
    let result = await session.finish(totalSamples: 320_000)
    guard case .success(let remote) = result else { return XCTFail("\(result)") }
    XCTAssertEqual(flowd.ends, [320_000])
    XCTAssertEqual(flowd.received.first?.count, 320_000)
    XCTAssertEqual(Set(remote.windows.keys), [0, 239_360])
  }

  func testBusyFailsAtOnce() async throws {
    flowd.behavior = .startError("busy")
    let session = session()
    await session.start()
    let failed = await waitForState(session, .failed(.busy))
    XCTAssertTrue(failed)
    // No threshold wait: the result is there before the clock moves.
    let result = await session.finish(totalSamples: 100)
    guard case .failure(.busy) = result else { return XCTFail("\(result)") }
  }

  func testEveryServerErrorCodeMapsToItsReason() async throws {
    let expected: [String: RemoteFailureReason] = [
      "unauthorized": .unauthorized, "not_approved": .notApproved, "revoked": .revoked,
      "busy": .busy, "invalid_message": .protocolError, "unsupported_version": .protocolError,
      "limit_exceeded": .limitExceeded, "worker_unavailable": .workerUnavailable,
      "internal": .protocolError,
    ]
    for (code, reason) in expected {
      flowd = FakeFlowdDictation()
      credentials = FakeSessionCredentials()
      flowd.behavior = .startError(code)
      let session = session()
      await session.start()
      let result = await session.finish(totalSamples: 10)
      guard case .failure(let got) = result else { return XCTFail(code) }
      XCTAssertEqual(got, reason, code)
      XCTAssertEqual(credentials.errors.map(\.rawValue), [code], code)
    }
  }

  func testConnectionFailureIsUnreachableAfterOneRetry() async throws {
    let opener = FakeRemoteTransportOpener { _ in nil }
    let session = session(opener: opener)
    await session.start()
    let failed = await waitForState(session, .failed(.unreachable))
    XCTAssertTrue(failed)
    XCTAssertEqual(opener.openCount, 2)
  }

  func testPinMismatchAndMissingTokenAreReported() async throws {
    let other = FakeRemoteTransportOpener { _ in
      self.flowd.transport(server: FakeRemoteServer(privateKey: .init()))
    }
    let mismatched = session(opener: other)
    await mismatched.start()
    let pin = await waitForState(mismatched, .failed(.pinMismatch))
    XCTAssertTrue(pin)
    XCTAssertEqual(credentials.pinMismatches, 1)
    credentials.token = nil
    let unauthenticated = session()
    await unauthenticated.start()
    let unauthorized = await waitForState(unauthenticated, .failed(.unauthorized))
    XCTAssertTrue(unauthorized)
  }

  func testSilenceAfterReleaseTimesOutAtTheThreshold() async throws {
    flowd.behavior = .silentAfterEnd
    let session = session()
    await session.start()
    _ = await waitForState(session, .streaming)
    progress.samples = 1_000
    let finishing = Task { await session.finish(totalSamples: 1_000) }
    let ending = await waitForState(session, .ending)
    XCTAssertTrue(ending)
    clock.advance(by: .milliseconds(1_400))
    try await Task.sleep(for: .milliseconds(20))
    let stillEnding = await session.state
    XCTAssertEqual(stillEnding, .ending)
    clock.advance(by: .milliseconds(100))
    let result = await finishing.value
    guard case .failure(.timeout) = result else { return XCTFail("\(result)") }
  }

  func testProgressResetsTheThresholdAndTheDevOverrideApplies() async throws {
    flowd.behavior = .progressAfterEnd
    let session = session(threshold: .milliseconds(800))
    await session.start()
    _ = await waitForState(session, .streaming)
    let finishing = Task { await session.finish(totalSamples: 1_000) }
    _ = await waitForState(session, .ending)
    // The progress frame arrived after release, so the 800 ms run from it.
    try await Task.sleep(for: .milliseconds(20))
    clock.advance(by: .milliseconds(700))
    try await Task.sleep(for: .milliseconds(20))
    flowd.transports[0].deliver(.message(["type": "progress", "op": 1, "state": "queued"]))
    try await Task.sleep(for: .milliseconds(20))
    clock.advance(by: .milliseconds(700))
    try await Task.sleep(for: .milliseconds(20))
    let alive = await session.state
    XCTAssertEqual(alive, .ending)
    clock.advance(by: .milliseconds(100))
    let result = await finishing.value
    guard case .failure(.timeout) = result else { return XCTFail("\(result)") }
  }

  func testAnInadmissibleWindowIsAProtocolError() async throws {
    flowd.behavior = .badWindow
    let session = session()
    await session.start()
    _ = await waitForState(session, .streaming)
    let result = await session.finish(totalSamples: 1_000)
    guard case .failure(.protocolError) = result else { return XCTFail("\(result)") }
  }

  func testChannelFailureBeforeReleaseRestartsFromSampleZero() async throws {
    let session = session()
    await session.start()
    _ = await waitForState(session, .streaming)
    progress.samples = 20_000
    await tick()
    _ = await eventually { self.flowd.received.first?.count == 20_000 }
    flowd.transports[0].deliver(.close(1006))
    let restarted = await eventually { self.flowd.transports.count == 2 }
    XCTAssertTrue(restarted)
    _ = await waitForState(session, .streaming)
    progress.samples = 30_000
    await tick()
    let result = await session.finish(totalSamples: 30_000)
    guard case .success(let remote) = result else { return XCTFail("\(result)") }
    XCTAssertEqual(flowd.received.count, 2)
    XCTAssertEqual(flowd.received[1].count, 30_000)
    XCTAssertEqual(flowd.received[1].first, RecordingProgress.sample(0))
    XCTAssertEqual(remote.windows.count, 1)
  }

  func testChannelFailureAfterReleaseFails() async throws {
    flowd.behavior = .silentAfterEnd
    let session = session()
    await session.start()
    _ = await waitForState(session, .streaming)
    let finishing = Task { await session.finish(totalSamples: 500) }
    _ = await waitForState(session, .ending)
    flowd.transports[0].deliver(.close(1006))
    let result = await finishing.value
    guard case .failure(.unreachable) = result else { return XCTFail("\(result)") }
    XCTAssertEqual(flowd.transports.count, 1)
  }

  func testSleepAbandonsTheSessionAndSendsNothingMore() async throws {
    let session = session()
    await session.start()
    _ = await waitForState(session, .streaming)
    progress.samples = 16_000
    await tick()
    _ = await eventually { self.flowd.received.first?.count == 16_000 }
    let before = flowd.transports[0].receivedEvents.count
    await session.systemWillSleep()
    progress.samples = 64_000
    await tick(3)
    let result = await session.finish(totalSamples: 64_000)
    guard case .failure(.unreachable) = result else { return XCTFail("\(result)") }
    XCTAssertEqual(flowd.transports[0].receivedEvents.count, before)
  }

  func testExpiredTokenAtStartRefreshesAndRetriesOnce() async throws {
    flowd.behavior = .expireFirstHello
    let session = session()
    await session.start()
    let streaming = await waitForState(session, .streaming)
    XCTAssertTrue(streaming)
    XCTAssertEqual(credentials.refreshed, 1)
    XCTAssertEqual(flowd.tokens, ["lfa_1", "lfa_2"])
    let result = await session.finish(totalSamples: 100)
    guard case .success = result else { return XCTFail("\(result)") }
  }

  func testFailureIsObservedOnceForEarlyLocalAcquisition() async throws {
    flowd.behavior = .startError("worker_unavailable")
    let session = session()
    let seen = FailureLog()
    await session.onFailure { seen.append($0) }
    await session.start()
    _ = await waitForState(session, .failed(.workerUnavailable))
    XCTAssertEqual(seen.items, [.workerUnavailable])
  }
}

final class FailureLog: @unchecked Sendable {
  private let lock = NSLock()
  private var values: [RemoteFailureReason] = []
  func append(_ value: RemoteFailureReason) { lock.withLock { values.append(value) } }
  var items: [RemoteFailureReason] { lock.withLock { values } }
}
