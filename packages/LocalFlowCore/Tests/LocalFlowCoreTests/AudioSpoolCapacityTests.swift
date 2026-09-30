import XCTest

@testable import LocalFlowSpeech

final class AudioSpoolCapacityTests: XCTestCase {
  private var roots: [URL] = []

  override func tearDownWithError() throws {
    for root in roots { try? FileManager.default.removeItem(at: root) }
  }

  private func root() -> URL {
    // Behind the root-owned /var symlink, as every iOS container path is.
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("spool-capacity-\(UUID().uuidString)", isDirectory: true)
    roots.append(url)
    return url
  }

  func testDefaultCapacityIsSixteenMebibytes() throws {
    let spool = try AudioSpool(rootDirectory: root())
    XCTAssertEqual(spool.maximumBytes, 16 * 1_048_576)
    XCTAssertEqual(spool.maximumBytes, AudioSpool.maximumBytes)
    try spool.cleanup()
  }

  /// iOS: 5 minutes of 16 kHz Float32 (FR-014).
  func testPhoneCapacityStopsAtExactlyItsByteCount() throws {
    let spool = try AudioSpool(rootDirectory: root(), maximumBytes: 19_200_000)
    let block = Array(repeating: Float(0.5), count: AudioSpool.maximumAppendSamples)
    let samples = 19_200_000 / MemoryLayout<Float>.stride
    for _ in 0..<(samples / block.count) { try spool.append(normalizedSamples: block) }
    XCTAssertEqual(samples % block.count, 0)
    XCTAssertEqual(spool.bytesWritten, 19_200_000)
    XCTAssertThrowsError(try spool.append(normalizedSamples: [0])) {
      XCTAssertEqual($0 as? AudioSpoolError, .capacityExceeded)
    }
    XCTAssertEqual(spool.bytesWritten, 19_200_000)
    XCTAssertEqual(try spool.readWindow(startSample: samples - 1, count: 1), [0.5])
    try spool.cleanup()
  }

  func testAppendPastASmallCapIsRefusedWithoutWritingPart() throws {
    let spool = try AudioSpool(rootDirectory: root(), maximumBytes: 10 * 4)
    try spool.append(normalizedSamples: Array(repeating: 0.1, count: 8))
    XCTAssertThrowsError(try spool.append(normalizedSamples: Array(repeating: 0.1, count: 3))) {
      XCTAssertEqual($0 as? AudioSpoolError, .capacityExceeded)
    }
    XCTAssertEqual(spool.bytesWritten, 32)
    try spool.append(normalizedSamples: [0.2, 0.3])
    XCTAssertEqual(spool.bytesWritten, 40)
    try spool.cleanup()
  }
}
