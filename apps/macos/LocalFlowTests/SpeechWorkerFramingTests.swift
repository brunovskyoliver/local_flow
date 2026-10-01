import LocalFlowSpeech
import XCTest

@testable import LocalFlow
@testable import LocalFlowCore

/// Feature 014: the worker framing in `SpeechWorker/WorkerFraming.swift` against the byte
/// fixtures flowd's Go side generated (`fixtures/remote/worker-frames/`).
final class SpeechWorkerFramingTests: XCTestCase {
  private struct Manifest: Decodable {
    struct Entry: Decodable {
      let file: String
      let valid: Bool
      let direction: String
      let headerJson: String?
      let payloadHex: String?
      let samples: [Float]?
      let error: String?
    }
    let maxHeaderBytes: Int
    let maxSampleCount: Int
    let frames: [Entry]
  }

  private var directory: URL { remoteFixturesURL().appendingPathComponent("worker-frames") }

  private func manifest() throws -> Manifest {
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    return try decoder.decode(
      Manifest.self, from: Data(contentsOf: directory.appendingPathComponent("manifest.json")))
  }

  private func reader(_ data: Data) -> (Int) -> Data {
    var offset = 0
    return { count in
      let end = min(data.count, offset + count)
      defer { offset = end }
      return data.subdata(in: offset..<end)
    }
  }

  func testLimitsMatchTheContract() throws {
    let manifest = try manifest()
    XCTAssertEqual(WorkerFraming.maximumHeaderBytes, manifest.maxHeaderBytes)
    XCTAssertEqual(WorkerFraming.maximumSampleCount, manifest.maxSampleCount)
    XCTAssertEqual(WorkerFraming.maximumSampleCount, WindowedTranscriber.productionWindowSamples)
  }

  func testValidFramesDecodeAndWorkerFramesEncodeByteForByte() throws {
    for entry in try manifest().frames where entry.valid {
      let bytes = try Data(contentsOf: directory.appendingPathComponent(entry.file))
      let read = reader(bytes)
      let frame = try XCTUnwrap(try WorkerFraming.read(read), entry.file)
      XCTAssertNil(try WorkerFraming.read(read), "one frame per file: \(entry.file)")
      let expected = try XCTUnwrap(
        JSONSerialization.jsonObject(with: Data(try XCTUnwrap(entry.headerJson).utf8))
          as? [String: Any])
      XCTAssertEqual(frame.header as NSDictionary, expected as NSDictionary, entry.file)
      XCTAssertEqual(frame.payload, Data(hex: entry.payloadHex ?? ""), entry.file)
      if let samples = entry.samples {
        XCTAssertEqual(WorkerFraming.samples(frame.payload), samples, entry.file)
        XCTAssertEqual(frame.integer("sample_count"), samples.count)
      }
      // What the worker writes, it writes exactly as flowd does. Fractional numbers are
      // printed differently by the two JSON encoders, so those headers compare decoded.
      let encoded = try WorkerFraming.encode(frame.header, payload: frame.payload)
      if Self.hasFraction(frame.header) {
        let again = try XCTUnwrap(try WorkerFraming.read(reader(encoded)))
        XCTAssertEqual(again.header as NSDictionary, expected as NSDictionary, entry.file)
        XCTAssertEqual(again.payload, frame.payload, entry.file)
      } else {
        XCTAssertEqual(encoded, bytes, entry.file)
      }
    }
  }

  private static func hasFraction(_ value: Any) -> Bool {
    switch value {
    case let object as [String: Any]: object.values.contains(where: hasFraction)
    case let array as [Any]: array.contains(where: hasFraction)
    case let number as NSNumber:
      CFGetTypeID(number) != CFBooleanGetTypeID()
        && number.doubleValue.rounded() != number.doubleValue
    default: false
    }
  }

  func testMalformedFramesAreFatal() throws {
    let expected: [String: WorkerFraming.Failure] = [
      "header_too_large": .headerTooLarge, "short_read": .shortRead,
      "payload_length_mismatch": .payloadLengthMismatch,
      "sample_count_out_of_range": .sampleCountOutOfRange,
    ]
    var seen = 0
    for entry in try manifest().frames where !entry.valid {
      let bytes = try Data(contentsOf: directory.appendingPathComponent(entry.file))
      XCTAssertThrowsError(try WorkerFraming.read(reader(bytes)), entry.file) {
        XCTAssertEqual($0 as? WorkerFraming.Failure, expected[entry.error ?? ""], entry.file)
      }
      seen += 1
    }
    XCTAssertEqual(seen, 4)
  }

  func testRecognizePayloadIsFourBytesPerSample() throws {
    let samples: [Float] = [0.25, -1, 0.5]
    let payload = samples.withUnsafeBufferPointer { Data(buffer: $0) }
    let frame = try WorkerFraming.encode(
      ["type": "recognize", "job": 3, "sample_count": 3], payload: payload)
    let decoded = try XCTUnwrap(try WorkerFraming.read(reader(frame)))
    XCTAssertEqual(WorkerFraming.samples(decoded.payload), samples)
    // A truncated stream between frames is a clean end; inside a frame it is fatal.
    XCTAssertNil(try WorkerFraming.read(reader(Data())))
    XCTAssertThrowsError(try WorkerFraming.read(reader(frame.prefix(frame.count - 1))))
    XCTAssertThrowsError(
      try WorkerFraming.encode(["type": "x", "pad": String(repeating: "a", count: 65_537)]))
  }

  // MARK: Feature 018: the meeting worker (contracts/meeting-worker-ipc.md)

  private func job(
    _ type: String, count: Int, payloadSamples: Int? = nil, extra: [String: Any] = [:]
  )
    throws -> Data
  {
    var header: [String: Any] = ["type": type, "job": 7, "sample_count": count]
    header.merge(extra) { $1 }
    return try WorkerFraming.encode(
      header, payload: Data(count: (payloadSamples ?? count) * 4))
  }

  /// Each meeting job kind has its own sample range; outside it the frame is fatal.
  func testMeetingJobSampleRanges() throws {
    let ranges: [(String, ClosedRange<Int>)] = [
      ("transcribe", 1...1_920_000), ("diarize", 1...9_600_000), ("embed", 48_000...320_000),
    ]
    for (type, range) in ranges {
      XCTAssertEqual(WorkerFraming.sampleRange(type), range, type)
      let low = try XCTUnwrap(
        try WorkerFraming.read(reader(job(type, count: range.lowerBound))), type)
      XCTAssertEqual(low.payload.count, range.lowerBound * 4, type)
      for count in [range.lowerBound - 1, range.upperBound + 1] {
        XCTAssertThrowsError(
          try WorkerFraming.read(reader(job(type, count: count, payloadSamples: 0))),
          "\(type) \(count)"
        ) { XCTAssertEqual($0 as? WorkerFraming.Failure, .sampleCountOutOfRange) }
      }
      XCTAssertThrowsError(
        try WorkerFraming.read(
          reader(job(type, count: range.lowerBound, payloadSamples: range.lowerBound + 1))),
        type
      ) { XCTAssertEqual($0 as? WorkerFraming.Failure, .payloadLengthMismatch) }
    }
    // A full transcription window, with its options.
    let window = try XCTUnwrap(
      try WorkerFraming.read(
        reader(
          job(
            "transcribe", count: 1_920_000,
            extra: [
              "language": "auto", "vocabulary_terms": ["SAPGUI"],
              "pipeline": "per_track_fixed1920000_turbo_level_v2",
            ]))))
    XCTAssertEqual(window.header["vocabulary_terms"] as? [String], ["SAPGUI"])
    XCTAssertEqual(window.integer("sample_count"), 1_920_000)
    let diarize = try XCTUnwrap(
      try WorkerFraming.read(reader(job("diarize", count: 16_000, extra: ["num_speakers": 1]))))
    XCTAssertEqual(diarize.integer("num_speakers"), 1)
  }

  /// What the meeting worker sends: every message flowd reads from it, round-tripped.
  func testMeetingWorkerMessagesRoundTrip() throws {
    let identity: [String: Any] = [
      "engine": "whisper.cpp", "model_id": "m", "model_revision": "r",
      "manifest_hash": String(repeating: "a", count: 64),
    ]
    let messages: [[String: Any]] =
      [
        MeetingWorkerMessages.ready(
          transcription: identity, diarization: identity,
          voice: identity.merging(["dimension": 256]) { $1 }),
        MeetingWorkerMessages.unavailable(missing: ["whisper-large-v3-turbo", "helper"]),
        MeetingWorkerMessages.result(
          job: 3, kind: "embed", result: ["vector": [Float(0.5)], "speech_seconds": 3.5],
          processingMs: 12),
        MeetingWorkerMessages.state("loading"),
      ] + MeetingWorkerMessages.errorCodes.map { MeetingWorkerMessages.error(job: 4, code: $0) }
    XCTAssertEqual(
      MeetingWorkerMessages.errorCodes,
      ["model_unavailable", "invalid_audio", "repetition", "failed"])
    for message in messages {
      let read = try XCTUnwrap(try WorkerFraming.read(reader(WorkerFraming.encode(message))))
      XCTAssertEqual(read.type, message["type"] as? String)
      XCTAssertTrue(read.payload.isEmpty)
    }
    let ready = messages[0]
    XCTAssertEqual(ready["protocol"] as? Int, 1)
    XCTAssertEqual(
      ((ready["models"] as? [String: Any])?["voice"] as? [String: Any])?["dimension"] as? Int, 256)
    XCTAssertEqual(messages[1]["reason"] as? String, "model_missing")
  }

  /// Results are compact: a Float written as its shortest decimal reads back as the same
  /// Float, so a centroid costs about 11 bytes per value, not 20.
  func testMeetingResultFloatsRoundTripExactly() throws {
    let values: [Float] = [0.012345679, -0.70710677, 1, 0, 3.4028235e38]
    let encoded = try WorkerFraming.encode([
      "type": "x", "v": MeetingWorkerMessages.compact(values),
    ])
    let read = try XCTUnwrap(try WorkerFraming.read(reader(encoded)))
    let decoded = (read.header["v"] as? [NSNumber])?.map(\.floatValue)
    XCTAssertEqual(decoded, values)
    XCTAssertLessThan(encoded.count, 80)
  }

  func testDiarizationAndTranscriptionResultsMatchTheClientDecoder() throws {
    let diarized = MeetingWorkerMessages.diarization(
      DiarizationWindowResult(
        turns: [.init(cluster: 0, startSeconds: 0.5, endSeconds: 2, quality: 0.9)],
        centroids: [0: [Float](repeating: 0.0625, count: 256)]))
    guard case .diarization(let result) = try RemoteMeetingResult.decode(kind: .diarize, diarized)
    else { return XCTFail("not a diarization") }
    XCTAssertEqual(result.turns.first?.endSeconds, 2)
    XCTAssertEqual(result.centroids[0]?.count, 256)
    let transcribed = MeetingWorkerMessages.transcription(
      TranscriptionWindow(text: "ahoj", tokens: [.init(text: "ahoj", start: 0, end: 0.4)]),
      language: "sk")
    guard
      case .transcription(let window, let language, let depth) = try RemoteMeetingResult.decode(
        kind: .transcribe, transcribed)
    else { return XCTFail("not a transcription") }
    XCTAssertEqual(window.text, "ahoj")
    XCTAssertEqual(language, "sk")
    XCTAssertEqual(depth, 0)
    // No speech in a voice region travels as an empty vector.
    XCTAssertEqual(MeetingWorkerMessages.noSpeech["vector"] as? [Float], [])
  }
}
