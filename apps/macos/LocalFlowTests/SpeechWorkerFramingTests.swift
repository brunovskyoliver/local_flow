import XCTest

@testable import LocalFlow

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
}
