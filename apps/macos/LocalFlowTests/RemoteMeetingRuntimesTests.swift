import LocalFlowCore
import LocalFlowSpeech
import XCTest

@testable import LocalFlow

/// Feature 018 T070: the meeting runtimes over a fake background channel.
final class RemoteMeetingRuntimesTests: XCTestCase {
  private static var model: [String: Any] {
    [
      "engine": "whisper.cpp", "model_id": "whisper-large-v3-turbo", "model_revision": "r1",
      "manifest_hash": String(repeating: "a", count: 64),
    ]
  }

  private static func result(_ op: Int, kind: String, _ result: [String: Any]) -> FakeServerReply {
    .message([
      "type": "meeting_result", "op": op, "kind": kind, "result": result, "processing_ms": 12,
      "model": model,
    ])
  }

  /// A server that answers each `meeting_job` once all its samples have arrived.
  private func server(
    reply: @escaping (Int, [String: Any]) -> [FakeServerReply]
  ) -> (RemoteChannelPool, FakeRemoteTransportOpener) {
    let pending = Pending()
    let transports = FakeRemoteTransportOpener { _ in
      FakeRemoteTransport { event in
        switch event {
        case .hello: return [.message(["type": "ready"])]
        case .control(let object) where object["type"] as? String == "meeting_job":
          pending.start(object)
          return []
        case .control(let object) where object["type"] as? String == "meeting_cancel":
          return [.message(["type": "cancelled", "op": object["op"] as! Int])]
        case .s16(let samples):
          guard let job = pending.receive(samples.count) else { return [] }
          return reply(job["op"] as! Int, job)
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

  private final class Pending: @unchecked Sendable {
    private let lock = NSLock()
    private var job: [String: Any]?
    private var remaining = 0

    func start(_ object: [String: Any]) {
      lock.withLock {
        job = object
        remaining = object["sample_count"] as! Int
      }
    }

    func receive(_ count: Int) -> [String: Any]? {
      lock.withLock {
        remaining -= count
        return remaining == 0 ? job : nil
      }
    }
  }

  private static func ramp(_ count: Int) -> [Float] {
    (0..<count).map { Float($0 % 200 - 100) / 128 }
  }

  func testTranscriptionSendsTheWindowAndTermsAndReturnsTheWindow() async throws {
    let (pool, transports) = server { op, _ in
      [
        .message(["type": "meeting_progress", "op": op, "state": "running"]),
        Self.result(
          op, kind: "transcribe",
          [
            "text": "Ahoj LocalFlow", "tokens": [["text": "Ahoj", "start": 0, "end": 0.5]],
            "language": "sk", "retry_depth": 0,
          ]),
      ]
    }
    let samples = Self.ramp(70_000)
    let runtime = RemoteTranscriptionRuntime(
      jobs: RemoteMeetingJobs(pool: pool), language: .slovak, terms: ["LocalFlow", ""])
    let window = try await runtime.transcribe(samples)
    XCTAssertEqual(window.text, "Ahoj LocalFlow")
    let transport = try XCTUnwrap(transports.opened.first)
    let job = try XCTUnwrap(
      transport.receivedEvents.compactMap { event -> [String: Any]? in
        if case .control(let object) = event, object["type"] as? String == "meeting_job" {
          return object
        }
        return nil
      }.first)
    XCTAssertEqual(job["kind"] as? String, "transcribe")
    XCTAssertEqual(job["language"] as? String, "sk")
    XCTAssertEqual(job["vocabulary_terms"] as? [String], ["LocalFlow"])
    XCTAssertEqual(job["sample_count"] as? Int, 70_000)
    // The samples a local runtime gets, as s16le in frames of at most 32,000.
    XCTAssertEqual(transport.s16Samples.count, 70_000)
    XCTAssertEqual(
      transport.receivedEvents.filter { if case .s16 = $0 { true } else { false } }.count, 3)
    let expected = samples.map { Int16(max(-1, min(1, $0)) * 32_767) }
    XCTAssertEqual(
      zip(transport.s16Samples, expected).filter { abs(Int($0) - Int($1)) > 1 }.count, 0)
  }

  func testDiarizationAndEmbeddingReturnTheLocalTypes() async throws {
    let vector = [Float](repeating: 0.0625, count: 256)
    let (pool, _) = server { op, job in
      switch job["kind"] as? String {
      case "diarize":
        XCTAssertEqual(job["num_speakers"] as? Int, 2)
        return [
          Self.result(
            op, kind: "diarize",
            [
              "turns": [["cluster": 0, "start": 0.0, "end": 2.0, "quality": 0.9]],
              "centroids": [["cluster": 0, "vector": vector]],
            ])
        ]
      default:
        return [Self.result(op, kind: "embed", ["vector": vector, "speech_seconds": 3.0])]
      }
    }
    let jobs = RemoteMeetingJobs(pool: pool)
    let diarized = try await RemoteDiarizationRuntime(jobs: jobs).diarize(
      .init(samples: Self.ramp(32_000), numSpeakers: 2))
    XCTAssertEqual(diarized.turns.count, 1)
    XCTAssertEqual(diarized.centroids[0]?.count, 256)
    let embedding = try await RemoteVoiceEmbeddingRuntime(jobs: jobs).embed(
      .init(samples: Self.ramp(48_000)))
    XCTAssertEqual(embedding.vector.count, 256)
    XCTAssertEqual(embedding.speechSeconds, 3.0)
  }

  func testARegionWithoutSpeechIsNoSpeechAndKeepsTheChannel() async throws {
    let (pool, transports) = server { op, _ in
      [Self.result(op, kind: "embed", ["vector": [Float](), "speech_seconds": 0.0])]
    }
    let runtime = RemoteVoiceEmbeddingRuntime(jobs: RemoteMeetingJobs(pool: pool))
    for _ in 0..<2 {
      do {
        _ = try await runtime.embed(.init(samples: Self.ramp(48_000)))
        XCTFail("expected noSpeech")
      } catch VoiceEmbeddingFailure.noSpeech {}
      await Task.yield()
      try await Task.sleep(for: .milliseconds(20))
    }
    XCTAssertEqual(transports.opened.count, 1, "one channel for both regions")
  }

  func testServerRefusalsWaitForTheServer() async throws {
    for code in ["busy", "worker_unavailable", "revoked"] {
      let (pool, _) = server { op, _ in [.message(["type": "error", "op": op, "code": code])] }
      do {
        _ = try await RemoteDiarizationRuntime(jobs: RemoteMeetingJobs(pool: pool)).diarize(
          .init(samples: Self.ramp(16_000), numSpeakers: nil))
        XCTFail(code)
      } catch let waiting as RemoteMeetingWaiting {
        XCTAssertEqual(waiting.code, code == "revoked" ? "unreachable" : code)
      }
    }
    let unreachable = RemoteChannelPool(open: { throw RemoteChannelError.unreachable })
    do {
      _ = try await RemoteTranscriptionRuntime(
        jobs: RemoteMeetingJobs(pool: unreachable), language: .english, terms: []
      ).transcribe(Self.ramp(16_000))
      XCTFail("unreachable")
    } catch let waiting as RemoteMeetingWaiting {
      XCTAssertEqual(waiting.code, "unreachable")
    }
  }

  func testNotOfferedDropsTheCapability() async throws {
    let (pool, _) = server { op, _ in
      [.message(["type": "error", "op": op, "code": "not_offered"])]
    }
    let dropped = Dropped()
    let jobs = RemoteMeetingJobs(pool: pool, notOffered: { await dropped.add($0) })
    do {
      _ = try await RemoteVoiceEmbeddingRuntime(jobs: jobs).embed(.init(samples: Self.ramp(48_000)))
      XCTFail("not offered")
    } catch is RemoteMeetingNotOffered {}
    let kinds = await dropped.kinds
    XCTAssertEqual(kinds, [.embed])
  }

  private actor Dropped {
    var kinds: [RemoteMeetingJob.Kind] = []
    func add(_ kind: RemoteMeetingJob.Kind) { kinds.append(kind) }
  }

  func testCancellationSendsMeetingCancel() async throws {
    let (pool, transports) = server { _, _ in [] }
    let runtime = RemoteTranscriptionRuntime(
      jobs: RemoteMeetingJobs(pool: pool), language: .english, terms: [])
    let task = Task { try await runtime.transcribe(Self.ramp(16_000)) }
    for _ in 0..<200 where transports.opened.first?.s16Samples.count != 16_000 {
      try await Task.sleep(for: .milliseconds(5))
    }
    task.cancel()
    do {
      _ = try await task.value
      XCTFail("expected cancellation")
    } catch is CancellationError {}
    for _ in 0..<200
    where !(transports.opened.first?.controlTypes.contains("meeting_cancel") ?? false) {
      try await Task.sleep(for: .milliseconds(5))
    }
    XCTAssertTrue(transports.opened.first?.controlTypes.contains("meeting_cancel") ?? false)
  }

  func testTermsAreBoundedToOneControlMessage() {
    let long = String(repeating: "x", count: 200)
    XCTAssertEqual(RemoteTranscriptionRuntime.bounded(Array(repeating: long, count: 300)).count, 81)
    XCTAssertEqual(RemoteTranscriptionRuntime.bounded(Array(repeating: "a", count: 300)).count, 256)
  }
}
