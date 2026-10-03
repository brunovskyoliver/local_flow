import XCTest

@testable import LocalFlow
@testable import LocalFlowSpeech

/// Feature 014 control messages against the shared examples in `fixtures/remote/messages/`,
/// which the Go server and `scripts/validate-foundation.py` check too.
final class RemoteProtocolTests: XCTestCase {
  private let serverTypes: Set = [
    "ready", "enrolled", "tokens", "dictation_accepted", "window_result", "progress",
    "dictation_complete", "cancelled", "rewrite_event", "error",
    // Feature 018
    "analysis_event_part", "analysis_event", "live_result", "meeting_progress", "meeting_result",
    "handoff_reply",
  ]
  private let clientTypes: Set = [
    "enroll", "refresh", "dictation_start", "dictation_end", "dictation_cancel", "rewrite",
    // Feature 018
    "analysis_part", "analysis", "live_window", "meeting_job", "meeting_cancel", "handoff",
  ]

  private func messages(_ folder: String) throws -> [(name: String, data: Data)] {
    let directory = remoteFixturesURL().appendingPathComponent("messages/\(folder)")
    return try FileManager.default.contentsOfDirectory(atPath: directory.path).filter {
      $0.hasSuffix(".json")
    }.sorted().map { ($0, try Data(contentsOf: directory.appendingPathComponent($0))) }
  }

  private func object(_ data: Data) throws -> [String: Any] {
    try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
  }

  func testEveryValidServerMessageDecodes() throws {
    var seen = Set<String>()
    for (name, data) in try messages("valid") {
      guard let type = try object(data)["type"] as? String, serverTypes.contains(type) else {
        continue
      }
      seen.insert(type)
      XCTAssertNoThrow(try RemoteServerMessage.decode(data), name)
    }
    XCTAssertEqual(seen, serverTypes)
  }

  /// A processing meeting's percent done reaches the handoff step.
  func testHandoffListCarriesProgress() throws {
    let data = try XCTUnwrap(messages("valid").first { $0.name == "handoff_reply-list.json" }).data
    guard case .handoffReply(_, let reply) = try RemoteServerMessage.decode(data) else {
      return XCTFail("not a handoff_reply")
    }
    XCTAssertEqual(reply.meetings?.map(\.progress), [nil, 37])
  }

  /// Client messages the app builds come out as the fixture, field for field.
  func testEveryValidClientMessageRoundTrips() throws {
    var seen = Set<String>()
    for (name, data) in try messages("valid") {
      let fixture = try object(data)
      guard let type = fixture["type"] as? String, clientTypes.contains(type) else { continue }
      seen.insert(type)
      let op = try XCTUnwrap(fixture["op"] as? Int)
      let message: RemoteClientMessage
      switch type {
      case "enroll":
        message = .enroll(
          op: op, provider: IdentityProvider(rawValue: fixture["provider"] as! String)!,
          idToken: fixture["id_token"] as! String, deviceName: fixture["device_name"] as! String,
          deviceKey: Data(base64URL: fixture["device_key"] as! String)!,
          signature: Data(base64URL: fixture["signature"] as! String)!)
      case "refresh":
        message = .refresh(
          op: op, refreshToken: fixture["refresh_token"] as! String,
          signature: Data(base64URL: fixture["signature"] as! String)!)
      case "dictation_start":
        let boost = (fixture["boost"] as? [String: Any]).map { boost in
          RemoteBoost(
            terms: (boost["terms"] as! [[String: String]]).map {
              .init(entryID: $0["entry_id"]!, canonical: $0["canonical"]!)
            }, governed: boost["governed"] as! [String])
        }
        message = .dictationStart(op: op, boost: boost)
      case "dictation_end":
        message = .dictationEnd(op: op, totalSamples: fixture["total_samples"] as! Int)
      case "dictation_cancel": message = .dictationCancel(op: op)
      case "analysis_part":
        message = .analysisPart(
          op: op, index: fixture["index"] as! Int, data: fixture["data"] as! String)
      case "analysis":
        message = .analysis(
          op: op, parts: fixture["parts"] as! Int, bytes: fixture["bytes"] as! Int,
          sha256: fixture["sha256"] as! String)
      case "live_window":
        message = .liveWindow(
          op: op, sampleCount: fixture["sample_count"] as! Int,
          language: fixture["language"] as? String)
      case "meeting_job":
        message = .meetingJob(
          op: op,
          job: RemoteMeetingJob(
            kind: RemoteMeetingJob.Kind(rawValue: fixture["kind"] as! String)!,
            sampleCount: fixture["sample_count"] as! Int,
            language: fixture["language"] as? String,
            vocabularyTerms: fixture["vocabulary_terms"] as? [String],
            pipeline: fixture["pipeline"] as? String,
            numSpeakers: fixture["num_speakers"] as? Int))
      case "meeting_cancel": message = .meetingCancel(op: op)
      case "handoff":
        message = .handoff(
          op: op,
          request: RemoteHandoffRequest(
            action: RemoteHandoffRequest.Action(rawValue: fixture["action"] as! String)!,
            meeting: (fixture["meeting"] as? String).flatMap(UUID.init(uuidString:)),
            name: fixture["name"] as? String, offset: fixture["offset"] as? Int,
            data: (fixture["data"] as? String).flatMap { Data(base64URL: $0) },
            sha256: fixture["sha256"] as? String))
      default:
        message = .rewrite(
          op: op, request: try JSONSerialization.data(withJSONObject: fixture["request"]!))
      }
      let encoded = try object(message.encoded())
      XCTAssertEqual(encoded as NSDictionary, fixture as NSDictionary, name)
    }
    XCTAssertEqual(seen, clientTypes)
  }

  func testInvalidServerMessagesAreRefused() throws {
    // Unknown fields are tolerated for forward compatibility (the server is strict);
    // everything else the client could misread is refused.
    let tolerated: Set = ["ready-extra-field.json"]
    // Window geometry and admission are checked when the window is collected.
    let collected: Set = ["window_result-negative-start.json"]
    for (name, data) in try messages("invalid") {
      let type = (try? object(data))?["type"] as? String
      guard !clientTypes.contains(type ?? ""), !name.hasPrefix("hello"), !name.hasPrefix("identity")
      else { continue }
      if tolerated.contains(name) {
        XCTAssertNoThrow(try RemoteServerMessage.decode(data), name)
      } else if collected.contains(name) {
        guard case .windowResult(let result) = try RemoteServerMessage.decode(data) else {
          XCTFail(name)
          continue
        }
        var collector = RemoteWindowCollector(boostingRan: true)
        XCTAssertThrowsError(try collector.append(result), name)
      } else {
        XCTAssertThrowsError(try RemoteServerMessage.decode(data), name)
      }
    }
  }

  func testUnknownSchemaVersionIsUnsupported() throws {
    let data = Data(#"{"schema_version":2,"type":"ready"}"#.utf8)
    XCTAssertThrowsError(try RemoteServerMessage.decode(data)) {
      XCTAssertEqual($0 as? RemoteProtocolError, .unsupportedVersion)
    }
  }

  func testWindowResultMapsOntoTheLocalTypes() throws {
    let data = try Data(
      contentsOf: remoteFixturesURL().appendingPathComponent("messages/valid/window_result.json"))
    guard case .windowResult(let result) = try RemoteServerMessage.decode(data) else {
      return XCTFail("expected window_result")
    }
    let window = result.window()
    XCTAssertEqual(window.text, result.text)
    XCTAssertEqual(window.tokens.map(\.text), result.tokens.map(\.text))
    XCTAssertEqual(window.tokens.first?.start, 0.12)
    let evidence = try XCTUnwrap(window.evidence)
    XCTAssertEqual(evidence.samples, 239_360)
    XCTAssertEqual(evidence.paddedSamples, 239_360)
    XCTAssertTrue(evidence.timingsAvailable)
    XCTAssertEqual(evidence.tokens.first?.start.value, 0.12)
    XCTAssertEqual(evidence.tokens.last?.start.invalid, "nan")
    XCTAssertEqual(
      window.boostHints,
      [.init(source: "zabix", canonical: "Zabbix", entryID: "9B1D2C3E-0000-4000-8000-000000000001")]
    )
    XCTAssertEqual(result.recognitionSeconds, 0.142, accuracy: 1e-9)
    // Without a booster on the server no hint reaches normalization.
    XCTAssertTrue(result.window(boostingRan: false).boostHints.isEmpty)
    var collector = RemoteWindowCollector(boostingRan: true)
    XCTAssertNoThrow(try collector.append(result))
    XCTAssertEqual(collector.windows[0]?.window.text, result.text)
    XCTAssertTrue(collector.covers(239_360))
    XCTAssertFalse(collector.covers(239_361))
  }

  func testAbsentBoosterMeansBoostingDidNotRun() throws {
    var object = try object(
      Data(
        contentsOf: remoteFixturesURL().appendingPathComponent(
          "messages/valid/dictation_accepted.json")))
    var model = object["model"] as! [String: Any]
    model["booster"] = nil
    object["model"] = model
    guard
      case .dictationAccepted(_, 239_360, let identity) = try RemoteServerMessage.decode(
        JSONSerialization.data(withJSONObject: object))
    else { return XCTFail("expected dictation_accepted") }
    XCTAssertNil(identity.booster)
    XCTAssertFalse(identity.boostingRan)
  }

  func testMoreThanFourteenWindowsOrAnInadmissibleWindowIsAProtocolError() throws {
    func result(index: Int, count: Int = 239_360, evidenceSamples: Int? = nil) throws
      -> RemoteWindowResult
    {
      var object: [String: Any] = [
        "schema_version": 1, "type": "window_result", "op": 1, "index": index,
        "sample_start": index * 239_360, "sample_count": count, "text": "w", "tokens": [],
        "recognition_ms": 1,
      ]
      if let evidenceSamples {
        object["evidence"] = [
          "text": "w", "samples": evidenceSamples, "padded_samples": max(4_800, evidenceSamples),
          "timings_available": false, "tokens": [],
        ]
      }
      guard
        case .windowResult(let decoded) = try RemoteServerMessage.decode(
          JSONSerialization.data(withJSONObject: object))
      else { throw RemoteProtocolError.invalidMessage }
      return decoded
    }
    // 180 s is twelve full windows and a 7,680-sample tail; nothing can follow it.
    var collector = RemoteWindowCollector(boostingRan: true)
    for index in 0..<12 {
      XCTAssertNoThrow(try collector.append(try result(index: index)), "\(index)")
    }
    XCTAssertNoThrow(try collector.append(try result(index: 12, count: 7_680)))
    XCTAssertTrue(collector.covers(2_880_000))
    for index in [13, RemoteProtocol.maximumWindows] {
      XCTAssertThrowsError(try collector.append(try result(index: index, count: 1))) {
        XCTAssertEqual($0 as? RemoteProtocolError, .invalidResult)
      }
    }
    var mismatch = RemoteWindowCollector(boostingRan: true)
    XCTAssertThrowsError(try mismatch.append(try result(index: 0, evidenceSamples: 12))) {
      XCTAssertEqual($0 as? RemoteProtocolError, .invalidResult)
    }
    var gap = RemoteWindowCollector(boostingRan: true)
    XCTAssertThrowsError(try gap.append(try result(index: 1)))
  }

  func testIdentityRequiresAConsistentFingerprint() throws {
    let key = Data((0..<32).map { UInt8($0) })
    let good = RemoteServerIdentity(
      schemaVersion: 1, server: "flowd/0.14.0", protocolVersions: [1], suite: RemoteProtocol.suite,
      serverKey: key.base64URL, fingerprint: RemoteServerIdentity.fingerprint(of: key))
    XCTAssertEqual(good.validatedKey(), key)
    XCTAssertEqual(good.fingerprint.split(separator: "-").count, 8)
    XCTAssertTrue(good.fingerprint.split(separator: "-").allSatisfy { $0.count == 4 })
    let bad = RemoteServerIdentity(
      schemaVersion: 1, server: "flowd/0.14.0", protocolVersions: [1], suite: RemoteProtocol.suite,
      serverKey: key.base64URL, fingerprint: "0000-0000-0000-0000-0000-0000-0000-0000")
    XCTAssertNil(bad.validatedKey())
    let data = try Data(
      contentsOf: remoteFixturesURL().appendingPathComponent("messages/valid/identity.json"))
    XCTAssertNoThrow(try JSONDecoder().decode(RemoteServerIdentity.self, from: data))
  }

  func testBoostIsCutToTheWireLimits() {
    let long = String(repeating: "x", count: 129)
    let terms = VocabularyBoostTerms(
      terms: (0..<300).map { .init(entryID: "e\($0)", canonical: "t\($0)") }
        + [.init(entryID: "long", canonical: long)],
      key: "k", governed: Set((0..<1_100).map { "g\($0)" } + [long]))
    let boost = RemoteBoost(terms)
    XCTAssertEqual(boost?.terms.count, 256)
    XCTAssertEqual(boost?.governed.count, 1_024)
    XCTAssertFalse(boost?.terms.contains { $0.canonical == long } ?? true)
    XCTAssertNil(RemoteBoost(nil))
  }

  func testDeviceNameDropsControlCharactersAndFitsSixtyFourBytes() {
    XCTAssertEqual(RemoteClientMessage.deviceName("Mac\u{0007}Book\n"), "MacBook")
    let name = RemoteClientMessage.deviceName(String(repeating: "č", count: 40))
    XCTAssertLessThanOrEqual(name.utf8.count, 64)
    XCTAssertEqual(name.count, 32)
  }

  /// Feature 018 T009: results decode into the types the local runtimes return.
  func testMeetingAndLiveResultsMapToRuntimeTypes() throws {
    let valid = Dictionary(uniqueKeysWithValues: try messages("valid"))
    guard
      case .liveResult(7, let window, 88) = try RemoteServerMessage.decode(
        valid["live_result.json"]!)
    else { return XCTFail("live_result") }
    XCTAssertEqual(window.text, "zabix alerts are green")
    XCTAssertEqual(window.tokens.first, TranscriptionToken(text: "zabix", start: 0.12, end: 0.4))
    XCTAssertEqual(window.evidence?.samples, 96_000)
    guard
      case .meetingResult(9, .transcription(let final, "sk", 0), _, let model) =
        try RemoteServerMessage.decode(valid["meeting_result.json"]!)
    else { return XCTFail("transcribe") }
    XCTAssertEqual(final.text, "Zabbix hlási zelené alarmy.")
    XCTAssertEqual(final.tokens.count, 4)
    XCTAssertEqual(model.engine, "whisper.cpp")
    guard
      case .meetingResult(_, .diarization(let turns), _, _) = try RemoteServerMessage.decode(
        valid["meeting_result-diarize.json"]!)
    else { return XCTFail("diarize") }
    XCTAssertEqual(turns.turns.count, 2)
    XCTAssertEqual(turns.turns[0].quality, 0.82)
    XCTAssertNil(turns.turns[1].quality)
    XCTAssertEqual(turns.centroids[0]?.count, 256)
    guard
      case .meetingResult(_, .embedding(let embedding), _, let voice) =
        try RemoteServerMessage.decode(
          valid["meeting_result-embed.json"]!)
    else { return XCTFail("embed") }
    XCTAssertTrue(embedding.isValid)
    XCTAssertEqual(voice.dimension, 256)
    guard
      case .meetingProgress(_, "queued", _) = try RemoteServerMessage.decode(
        valid["meeting_progress.json"]!)
    else { return XCTFail("meeting_progress") }
  }

  func testS16FramesClampAndAreLittleEndian() {
    let payload = RemoteChannelCrypto.s16Payload([0, 1, -1, 2, -3, 0.5, .nan][...])
    let values = stride(from: 0, to: payload.count, by: 2).map {
      Int16(littleEndian: payload[$0..<$0 + 2].withUnsafeBytes { $0.loadUnaligned(as: Int16.self) })
    }
    XCTAssertEqual(values, [0, 32_767, -32_767, 32_767, -32_767, 16_384, 0])
    XCTAssertEqual(payload.prefix(4), Data([0x00, 0x00, 0xFF, 0x7F]))
  }
}
