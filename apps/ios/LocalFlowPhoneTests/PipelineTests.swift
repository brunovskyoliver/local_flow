import GRDB
import XCTest

@testable import LocalFlow
@testable import LocalFlowCore
@testable import LocalFlowSpeech

@MainActor
final class PipelineTests: XCTestCase {
  private var harness: PhoneHarness!

  override func setUp() async throws { harness = try PhoneHarness() }
  override func tearDown() async throws { harness = nil }

  private func spool(samples: Int = 16_000) throws -> AudioSpool {
    let spool = try AudioSpool(
      rootDirectory: harness.spoolRoot, sessionID: UUID(), maximumBytes: PhoneServices.spoolBytes)
    try spool.append(normalizedSamples: [Float](repeating: 0.1, count: min(samples, 1_600)))
    return spool
  }

  func testSpoolBecomesTextAndIsDeleted() async throws {
    let spool = try spool()
    let output = try await harness.pipeline.run(
      spool: spool, sampleCount: 1_600, dictationID: UUID(), stopReason: .keyRelease)
    XCTAssertEqual(output.text, "hello from the phone")
    XCTAssertEqual(output.quality, .complete)
    XCTAssertNotNil(output.detail)
    XCTAssertFalse(FileManager.default.fileExists(atPath: spool.audioFileURL.path))
  }

  func testSilenceGivesEmptyText() async throws {
    await harness.runtime.set(text: "   ")
    let output = try await harness.pipeline.run(
      spool: try spool(), sampleCount: 1_600, dictationID: UUID(), stopReason: .keyRelease)
    XCTAssertEqual(output.text, "")
    XCTAssertNil(output.detail)
  }

  func testLimitAndOverflowMarkTheResult() async throws {
    let limited = try await harness.pipeline.run(
      spool: try spool(), sampleCount: 1_600, dictationID: UUID(), stopReason: .durationLimit)
    XCTAssertEqual(limited.quality, .durationLimited)
    let overflow = try await harness.pipeline.run(
      spool: try spool(), sampleCount: 1_600, dictationID: UUID(), stopReason: .overflow)
    XCTAssertEqual(overflow.quality, .incomplete)
    XCTAssertEqual(overflow.text, "hello from the phone", "captured audio is still transcribed")
  }

  func testFailureDeletesTheSpool() async throws {
    await harness.runtime.set(fails: true)
    let spool = try spool()
    let output = try? await harness.pipeline.run(
      spool: spool, sampleCount: 1_600, dictationID: UUID(), stopReason: .keyRelease)
    XCTAssertTrue(output?.text.isEmpty ?? true)
    XCTAssertFalse(FileManager.default.fileExists(atPath: spool.audioFileURL.path))
  }

  // MARK: Orphans

  private func leaveOrphan() throws -> OrphanSpoolRecovery {
    let folder = harness.spoolRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let samples = [Float](repeating: 0.2, count: 3_200)
    try samples.withUnsafeBufferPointer { Data(buffer: $0) }
      .write(to: folder.appendingPathComponent("audio.pcm"))
    let recovery = OrphanSpoolRecovery(root: harness.spoolRoot)
    recovery.adopt()
    XCTAssertTrue(recovery.hasOrphan)
    XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
    return recovery
  }

  func testOrphanIsRecoveredForReview() async throws {
    let recovery = try leaveOrphan()
    await recovery.recover(pipeline: harness.pipeline, store: harness.dictations)
    XCTAssertFalse(recovery.hasOrphan)
    let rows = try await harness.dictations.list()
    XCTAssertEqual(rows.count, 1)
    XCTAssertEqual(rows.first?.endDetail, .recoveredAfterTermination)
    XCTAssertEqual(rows.first?.entry.recoveryState, .needsReview)
  }

  func testFailingOrphanIsDeleted() async throws {
    await harness.runtime.set(fails: true)
    let recovery = try leaveOrphan()
    await recovery.recover(pipeline: harness.pipeline, store: harness.dictations)
    XCTAssertFalse(recovery.hasOrphan)
    XCTAssertEqual(try harness.rowCount(), 0)
  }

  func testOrphanWaitsForTheModelAndSurvivesANewSpool() async throws {
    let recovery = try leaveOrphan()
    // A new dictation's spool clears UUID folders; the parked orphan stays.
    _ = try spool()
    XCTAssertTrue(recovery.hasOrphan)
    await recovery.recover(pipeline: harness.pipeline, store: harness.dictations)
    XCTAssertEqual(try harness.rowCount(), 1)
  }

  /// Regression: recovery transcribing through the first model load (37–50 s after an
  /// install) held the spool lock, so a dictation started then failed `alreadyInUse`.
  func testADictationCanStartWhileAnOrphanIsTranscribed() async throws {
    await harness.runtime.set(loadDelay: .milliseconds(300))
    let recovery = try leaveOrphan()
    let recovering = Task {
      await recovery.recover(pipeline: harness.pipeline, store: harness.dictations)
    }
    try await Task.sleep(for: .milliseconds(50))
    XCTAssertNoThrow(try spool())
    await recovering.value
    XCTAssertEqual(try harness.rowCount(), 1)
  }

  func testDeletingAWaitingOrphan() throws {
    let recovery = try leaveOrphan()
    recovery.delete()
    XCTAssertFalse(recovery.hasOrphan)
  }
}
