import XCTest

@testable import LocalFlow

final class ADTSValidatorTests: XCTestCase {
  private var directory: URL!

  override func setUpWithError() throws {
    directory = FileManager.default.temporaryDirectory.appendingPathComponent("adts-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  }
  override func tearDown() { try? FileManager.default.removeItem(at: directory) }

  private func scan(_ bytes: [UInt8]) throws -> ADTSValidator.ScanResult {
    let url = directory.appendingPathComponent("\(UUID()).aac.part")
    try Data(bytes).write(to: url)
    return try ADTSValidator.scan(url: url)
  }

  func testCompleteFileReportsEveryFrameAndNoTrailingBytes() throws {
    let bytes = ADTSFixtures.completeFrames(500, payloadBytes: 300)
    let result = try scan(bytes)
    XCTAssertEqual(result.completeFrames, 500)
    XCTAssertEqual(result.completeBytes, bytes.count)
    XCTAssertEqual(result.trailingBytes, 0)
    XCTAssertEqual(result.sampleRate, 48_000)
    XCTAssertEqual(result.channels, 1)
    XCTAssertEqual(result.durationMs, 500 * 1_024 * 1_000 / 48_000)
  }

  func testCutMidFrameReportsLastCompleteBoundaryAndTrailingCount() throws {
    let result = try scan(ADTSFixtures.truncatedMidFrame(40, payloadBytes: 200, cut: 90))
    XCTAssertEqual(result.completeFrames, 40)
    XCTAssertEqual(result.completeBytes, 40 * 207)
    XCTAssertEqual(result.trailingBytes, 90)
  }

  func testCorruptHeaderInTheMiddleStopsAtThatFrame() throws {
    let bytes = ADTSFixtures.corruptHeaderAt(index: 25, of: 60, payloadBytes: 100)
    let result = try scan(bytes)
    XCTAssertEqual(result.completeFrames, 25)
    XCTAssertEqual(result.completeBytes, 25 * 107)
    XCTAssertEqual(result.trailingBytes, bytes.count - 25 * 107)
  }

  func testThreeByteFileHasZeroCompleteFrames() throws {
    let result = try scan([0xFF, 0xF1, 0x4C])
    XCTAssertEqual(result.completeFrames, 0)
    XCTAssertEqual(result.completeBytes, 0)
    XCTAssertEqual(result.trailingBytes, 3)
    XCTAssertEqual(try scan([]).completeFrames, 0)
  }

  func testHeaderMetadataComesFromTheFirstFrameAndStereoIsRead() throws {
    let result = try scan(ADTSFixtures.completeFrames(3, payloadBytes: 50, channels: 2))
    XCTAssertEqual(result.channels, 2)
    XCTAssertEqual(result.sampleRate, 48_000)
    // A frame whose channel count changes is treated as inconsistent.
    var mixed = ADTSFixtures.completeFrames(2, payloadBytes: 50, channels: 2)
    mixed += ADTSFixtures.completeFrames(1, payloadBytes: 50, channels: 1)
    XCTAssertEqual(try scan(mixed).completeFrames, 2)
  }

  /// The scan reads in 64 KiB windows: a 1 MiB file is served by a counting read
  /// double in chunks of at most 64 KiB and never asks for more at once.
  func testScanReadsInBoundedWindows() throws {
    let bytes = ADTSFixtures.completeFrames(5_000, payloadBytes: 200)  // ~1 MiB
    XCTAssertGreaterThan(bytes.count, 1_000_000)
    var offset = 0
    var reads = 0
    var largestRequest = 0
    let result = try ADTSValidator.scan { buffer, count in
      reads += 1
      largestRequest = max(largestRequest, count)
      let n = min(count, bytes.count - offset)
      if n > 0 {
        bytes.withUnsafeBytes { source in
          buffer.copyMemory(from: source.baseAddress!.advanced(by: offset), byteCount: n)
        }
      }
      offset += n
      return n
    }
    XCTAssertEqual(result.completeFrames, 5_000)
    XCTAssertEqual(result.trailingBytes, 0)
    XCTAssertLessThanOrEqual(largestRequest, ADTSValidator.windowBytes)
    XCTAssertGreaterThanOrEqual(reads, bytes.count / ADTSValidator.windowBytes)
    XCTAssertEqual(result.reads, reads)
  }

  func testProductionEncoderOutputValidatesFrameForFrame() throws {
    let bytes = try ADTSFixtures.encodedTone(blocks: 12)
    let result = try scan(bytes)
    XCTAssertGreaterThan(result.completeFrames, 40)
    XCTAssertEqual(result.completeBytes, bytes.count)
    XCTAssertEqual(result.trailingBytes, 0)
    XCTAssertEqual(try scan(Array(bytes.dropLast(5))).completeFrames, result.completeFrames - 1)
  }
}
