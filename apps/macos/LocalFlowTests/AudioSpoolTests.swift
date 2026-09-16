import Darwin
import XCTest

@testable import LocalFlow

final class AudioSpoolTests: XCTestCase {
  func testAppInstanceLockExcludesSecondOwnerUntilRelease() throws {
    let root = try makeSpoolRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    var first: AppInstanceLock? = try AppInstanceLock(directory: root)
    XCTAssertNotNil(first)
    XCTAssertThrowsError(try AppInstanceLock(directory: root)) {
      XCTAssertEqual($0 as? AudioSpoolError, .alreadyInUse)
    }
    first = nil
    let next = try AppInstanceLock(directory: root)
    try withExtendedLifetime(next) {
      XCTAssertThrowsError(try AppInstanceLock(directory: root))
    }
  }

  func testAppendsAndReadsBoundedWindowsThenCleansUp() throws {
    let root = try temporaryRoot()
    let spool = try AudioSpool(rootDirectory: root)
    let samples = (0..<1_600).map { Float($0) / 1_600 }
    try spool.append(normalizedSamples: samples)
    XCTAssertEqual(spool.bytesWritten, 1_600 * MemoryLayout<Float>.stride)
    XCTAssertEqual(try spool.readWindow(startSample: 100, count: 20), Array(samples[100..<120]))
    try spool.cleanup()
    XCTAssertNoThrow(try spool.cleanup())
    XCTAssertThrowsError(try spool.append(normalizedSamples: [0])) {
      XCTAssertEqual($0 as? AudioSpoolError, .closed)
    }
  }

  func testSecondOwnerIsRejectedUntilCleanup() throws {
    let root = try temporaryRoot()
    let first = try AudioSpool(rootDirectory: root)
    XCTAssertThrowsError(try AudioSpool(rootDirectory: root)) {
      XCTAssertEqual($0 as? AudioSpoolError, .alreadyInUse)
    }
    try first.cleanup()
    XCTAssertNoThrow(try AudioSpool(rootDirectory: root).cleanup())
  }

  func testRejectsOversizedOrUnnormalizedInput() throws {
    let spool = try AudioSpool(rootDirectory: temporaryRoot())
    XCTAssertThrowsError(try spool.append(normalizedSamples: Array(repeating: 0, count: 1_601)))
    XCTAssertNoThrow(try spool.append(normalizedSamples: [1.01]))
    XCTAssertThrowsError(try spool.readWindow(startSample: 0, count: 239_361))
    try spool.cleanup()
  }

  func testRestartRemovesOnlyStaleSessionDirectories() throws {
    let root = try temporaryRoot()
    let stale = root.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: stale, withIntermediateDirectories: true)
    try Data([1, 2, 3]).write(to: stale.appendingPathComponent("audio.pcm"))
    let unrelated = root.appendingPathComponent("keep.txt")
    try Data([4]).write(to: unrelated)
    let spool = try AudioSpool(rootDirectory: root)
    XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path))
    XCTAssertEqual(try Data(contentsOf: unrelated), Data([4]))
    try spool.cleanup()
  }

  func testCleanupFailureKeepsLockAndRejectsAudioUntilRetry() throws {
    let root = try temporaryRoot()
    let session = UUID()
    let directory = root.appendingPathComponent(session.uuidString)
    let spool = try AudioSpool(rootDirectory: root, sessionID: session)
    try spool.append(normalizedSamples: [0])
    XCTAssertEqual(chmod(directory.path, 0o500), 0)
    defer { chmod(directory.path, 0o700) }
    XCTAssertThrowsError(try spool.cleanup()) {
      XCTAssertEqual($0 as? AudioSpoolError, .ioFailure)
    }
    XCTAssertThrowsError(try spool.append(normalizedSamples: [0])) {
      XCTAssertEqual($0 as? AudioSpoolError, .failed)
    }
    XCTAssertThrowsError(try AudioSpool(rootDirectory: root)) {
      XCTAssertEqual($0 as? AudioSpoolError, .alreadyInUse)
    }
    XCTAssertEqual(chmod(directory.path, 0o700), 0)
    try spool.cleanup()
    XCTAssertNoThrow(try AudioSpool(rootDirectory: root).cleanup())
  }

  func testSpoolCapacityRejectsAppendWithoutLosingAcceptedSamples() throws {
    let spool = try AudioSpool(rootDirectory: temporaryRoot())
    let block = Array(repeating: Float(0.25), count: AudioSpool.maximumAppendSamples)
    let maximumSamples = AudioSpool.maximumBytes / MemoryLayout<Float>.stride
    for _ in 0..<(maximumSamples / block.count) {
      try spool.append(normalizedSamples: block)
    }
    let tail = maximumSamples % block.count
    if tail > 0 { try spool.append(normalizedSamples: Array(block.prefix(tail))) }
    XCTAssertEqual(spool.bytesWritten, AudioSpool.maximumBytes)
    XCTAssertThrowsError(try spool.append(normalizedSamples: [0])) {
      XCTAssertEqual($0 as? AudioSpoolError, .capacityExceeded)
    }
    XCTAssertEqual(try spool.readWindow(startSample: maximumSamples - 1, count: 1), [0.25])
    try spool.cleanup()
  }

  private func temporaryRoot() throws -> URL {
    let url = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: url) }
    return url
  }
}
