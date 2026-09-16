import Darwin
import XCTest

@testable import LocalFlow

final class ResourceRecorderTests: XCTestCase {
  private func identity() throws -> ResourceRecorder.Identity {
    try .init(
      build: "test-build", model: "parakeet-v3", hardware: "test-host", os: "test-os",
      conditions: .development)
  }
  private func directory() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("metrics-\(UUID())")
  }

  func testPrivateFixedSchemaAndActualRSS() async throws {
    let directory = directory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let recorder = try ResourceRecorder(directory: directory, identity: identity())
    XCTAssertTrue(
      recorder.record(
        phase: .recording, cycleID: UUID(), rssBytes: 123, queueSource: .controlMailbox,
        queueDepth: 2, queueCapacity: 32,
        queueHighWater: 5))
    let report = try await recorder.close()
    XCTAssertTrue(report.complete)
    let footer = try completion(in: report.files)
    XCTAssertEqual(footer["complete"] as? Bool, true)
    XCTAssertEqual(footer["lostSamples"] as? Int, 0)
    XCTAssertEqual(report.samplesWritten, 1)
    let data = try Data(contentsOf: report.files[0])
    let lines = data.split(separator: 10)
    XCTAssertEqual(lines.count, 3)
    for line in lines {
      XCTAssertLessThanOrEqual(line.count + 1, 1024)
      let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line)) as? [String: Any])
      XCTAssertNil(object["text"])
      XCTAssertNil(object["audio"])
      XCTAssertNil(object["target"])
      XCTAssertNil(object["error"])
    }
    let permissions =
      try FileManager.default.attributesOfItem(atPath: report.files[0].path)[.posixPermissions]
      as? NSNumber
    XCTAssertEqual(permissions?.intValue, 0o600)
    let directoryPermissions =
      try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions]
      as? NSNumber
    XCTAssertEqual(directoryPermissions?.intValue, 0o700)
    XCTAssertGreaterThan(try XCTUnwrap(ResourceRecorder.residentBytes()), 0)
  }

  func testOverflowIsBoundedAndInvalidatesExport() async throws {
    let directory = directory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let queue = DispatchQueue(label: "metrics-test-paused")
    queue.suspend()
    let recorder = try ResourceRecorder(
      directory: directory, identity: identity(), writerQueue: queue)
    for _ in 0..<256 { XCTAssertTrue(recorder.record(phase: .idle)) }
    XCTAssertFalse(recorder.record(phase: .idle))
    queue.resume()
    let flushed = await recorder.flush()
    XCTAssertEqual(flushed.samplesWritten, 256)
    XCTAssertEqual(flushed.lostSamples, 1)
    XCTAssertFalse(flushed.complete)
    do {
      _ = try await recorder.close()
      XCTFail("Acceptance export cannot conceal lost samples")
    } catch { XCTAssertEqual(error as? ResourceRecorder.Failure, .incomplete) }
    let footer = try completion(in: flushed.files)
    XCTAssertEqual(footer["complete"] as? Bool, false)
    XCTAssertEqual(footer["lostSamples"] as? Int, 1)
  }

  func testHardwareIdentifierComesFromHostAndFitsIdentity() throws {
    let identifier = try XCTUnwrap(ResourceRecorder.hardwareIdentifier())
    var byteCount = 0
    XCTAssertEqual(sysctlbyname("hw.model", nil, &byteCount, nil, 0), 0)
    var bytes = [CChar](repeating: 0, count: byteCount)
    XCTAssertEqual(sysctlbyname("hw.model", &bytes, &byteCount, nil, 0), 0)
    let raw = String(decoding: bytes.dropLast().map { UInt8(bitPattern: $0) }, as: UTF8.self)
    XCTAssertEqual(identifier, raw.replacingOccurrences(of: ",", with: "-"))
    XCTAssertNoThrow(
      try ResourceRecorder.Identity(
        build: "test", model: "test", hardware: identifier, os: "test", conditions: .development))
  }

  func testRejectsUnboundedAndContentLikeIdentity() throws {
    for invalid in [
      "", String(repeating: "a", count: 129), "a\ntranscript", "spoken words", "../secret",
    ] {
      XCTAssertThrowsError(
        try ResourceRecorder.Identity(
          build: invalid, model: "model", hardware: "hardware", os: "os", conditions: .development))
    }
  }

  func testRotationNeverExceedsTwoFilesOrConfiguredBound() async throws {
    let directory = directory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let recorder = try ResourceRecorder(directory: directory, identity: identity(), fileLimit: 2048)
    for _ in 0..<40 {
      XCTAssertTrue(recorder.record(phase: .recording, rssBytes: 120_000_000))
      _ = await recorder.flush()
    }
    let report = await recorder.flush()
    XCTAssertFalse(report.complete)
    XCTAssertGreaterThan(report.overwrittenSamples, 0)
    for url in report.files {
      XCTAssertLessThanOrEqual(try Data(contentsOf: url).count, 2048)
    }
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).count, 2)
    do {
      _ = try await recorder.close()
      XCTFail("Rotated-away samples invalidate acceptance")
    } catch { XCTAssertEqual(error as? ResourceRecorder.Failure, .incomplete) }
    let footer = try completion(in: report.files)
    XCTAssertEqual(footer["complete"] as? Bool, false)
    XCTAssertGreaterThan(try XCTUnwrap(footer["overwrittenSamples"] as? Int), 0)
    for url in report.files {
      XCTAssertLessThanOrEqual(try Data(contentsOf: url).count, 2048)
    }
  }

  func testInvalidQueueMeasurementsAreCountedAsLoss() async throws {
    let directory = directory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let recorder = try ResourceRecorder(directory: directory, identity: identity())
    XCTAssertFalse(
      recorder.record(
        phase: .idle, queueSource: .controlMailbox, queueDepth: 3, queueCapacity: 2,
        queueHighWater: 3))
    let report = await recorder.flush()
    XCTAssertEqual(report.lostSamples, 1)
    do {
      _ = try await recorder.close()
      XCTFail("Invalid metrics invalidate export")
    } catch { XCTAssertEqual(error as? ResourceRecorder.Failure, .incomplete) }
  }
  private func completion(in files: [URL]) throws -> [String: Any] {
    var found: [[String: Any]] = []
    for file in files {
      for line in try Data(contentsOf: file).split(separator: 10) {
        let value = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line)) as? [String: Any])
        if value["kind"] as? String == "completion" { found.append(value) }
      }
    }
    XCTAssertEqual(found.count, 1)
    return try XCTUnwrap(found.first)
  }

}
