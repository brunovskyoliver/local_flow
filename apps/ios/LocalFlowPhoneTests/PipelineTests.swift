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

  private func writeAudio(to url: URL, samples: Int = 3_200) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let values = [Float](repeating: 0.2, count: samples)
    try values.withUnsafeBufferPointer { Data(buffer: $0) }.write(to: url)
  }

  private func leaveOrphan() throws -> OrphanSpoolRecovery {
    let folder = harness.spoolRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try writeAudio(to: folder.appendingPathComponent("audio.pcm"))
    let recovery = OrphanSpoolRecovery(root: harness.spoolRoot)
    recovery.adopt()
    XCTAssertTrue(recovery.hasOrphan)
    XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
    return recovery
  }

  private func blockSaves(_ blocked: Bool) throws {
    try harness.history.database.write { db in
      try db.execute(
        sql: blocked
          ? "CREATE TRIGGER locked BEFORE INSERT ON phone_dictations BEGIN SELECT RAISE(ABORT, 'locked'); END"
          : "DROP TRIGGER locked")
    }
  }

  private func recoveryFolders(_ recovery: OrphanSpoolRecovery) -> [String] {
    (try? FileManager.default.contentsOfDirectory(atPath: recovery.recoveryDirectory.path))?
      .filter { UUID(uuidString: $0) != nil } ?? []
  }

  func testOrphanIsRecoveredForReview() async throws {
    let recovery = try leaveOrphan()
    let id = try XCTUnwrap(recovery.parked.first).deletingPathExtension().lastPathComponent
    await recovery.recover(pipeline: harness.pipeline, store: harness.dictations)
    XCTAssertFalse(recovery.hasOrphan)
    XCTAssertTrue(recoveryFolders(recovery).isEmpty)
    let rows = try await harness.dictations.list()
    XCTAssertEqual(rows.count, 1)
    XCTAssertEqual(rows.first?.id.uuidString, id, "the parked file name is the stable ID")
    XCTAssertEqual(rows.first?.endDetail, .recoveredAfterTermination)
    XCTAssertEqual(rows.first?.entry.recoveryState, .needsReview)
  }

  /// Audit item 1: a model failure used to delete the only copy.
  func testAModelFailureKeepsTheOrphanForARetry() async throws {
    await harness.runtime.set(fails: true)
    let recovery = try leaveOrphan()
    await recovery.recover(pipeline: harness.pipeline, store: harness.dictations)
    XCTAssertTrue(recovery.hasOrphan)
    XCTAssertEqual(try harness.rowCount(), 0)
    XCTAssertTrue(recoveryFolders(recovery).isEmpty, "the working copy is cleaned")
    await harness.runtime.set(fails: false)
    await recovery.recover(pipeline: harness.pipeline, store: harness.dictations)
    XCTAssertFalse(recovery.hasOrphan)
    XCTAssertEqual(try harness.rowCount(), 1)
  }

  func testAModelLoadFailureKeepsTheOrphan() async throws {
    await harness.runtime.set(loadFails: true)
    let recovery = try leaveOrphan()
    await recovery.recover(pipeline: harness.pipeline, store: harness.dictations)
    XCTAssertTrue(recovery.hasOrphan)
    XCTAssertEqual(try harness.rowCount(), 0)
  }

  func testAFailedHistorySaveKeepsTheOrphanForARetry() async throws {
    let recovery = try leaveOrphan()
    try blockSaves(true)
    await recovery.recover(pipeline: harness.pipeline, store: harness.dictations)
    XCTAssertTrue(recovery.hasOrphan)
    XCTAssertEqual(try harness.rowCount(), 0)
    try blockSaves(false)
    await recovery.recover(pipeline: harness.pipeline, store: harness.dictations)
    await recovery.recover(pipeline: harness.pipeline, store: harness.dictations)
    XCTAssertFalse(recovery.hasOrphan)
    XCTAssertEqual(try harness.rowCount(), 1, "exactly one review item")
  }

  func testCancellingRecoveryKeepsTheOrphan() async throws {
    await harness.runtime.set(loadDelay: .milliseconds(300))
    let recovery = try leaveOrphan()
    let recovering = Task {
      await recovery.recover(pipeline: harness.pipeline, store: harness.dictations)
    }
    try await Task.sleep(for: .milliseconds(50))
    recovering.cancel()
    await recovering.value
    XCTAssertTrue(recovery.hasOrphan)
    XCTAssertEqual(try harness.rowCount(), 0)
    await harness.runtime.set(loadDelay: .zero)
    await recovery.recover(pipeline: harness.pipeline, store: harness.dictations)
    XCTAssertEqual(try harness.rowCount(), 1)
  }

  /// A process death after the History commit but before cleanup: the retry finds the
  /// row by the parked ID and only cleans up.
  func testARetryAfterACommittedSaveDoesNotDuplicate() async throws {
    let recovery = try leaveOrphan()
    let url = try XCTUnwrap(recovery.parked.first)
    let id = try XCTUnwrap(UUID(uuidString: url.deletingPathExtension().lastPathComponent))
    try await harness.dictations.save(
      .init(
        id: id, text: "already saved", createdAt: Date(), source: .keyboard,
        durationMilliseconds: 200, quality: .incomplete, stopReason: .failure,
        endDetail: .recoveredAfterTermination, sessionID: nil, detail: nil))
    await recovery.recover(pipeline: harness.pipeline, store: harness.dictations)
    XCTAssertFalse(recovery.hasOrphan)
    XCTAssertEqual(try harness.rowCount(), 1)
  }

  /// A process death during transcription leaves the parked file and its working copy.
  func testAdoptDropsARedundantRecoveryCopy() async throws {
    let recovery = try leaveOrphan()
    let url = try XCTUnwrap(recovery.parked.first)
    let id = url.deletingPathExtension().lastPathComponent
    try writeAudio(
      to: recovery.recoveryDirectory.appendingPathComponent(id).appendingPathComponent(
        "audio.pcm"))
    recovery.adopt()
    XCTAssertEqual(recovery.orphanCount, 1)
    XCTAssertTrue(recoveryFolders(recovery).isEmpty)
    await recovery.recover(pipeline: harness.pipeline, store: harness.dictations)
    XCTAssertEqual(try harness.rowCount(), 1)
  }

  /// Builds before this fix deleted the parked file before inference, leaving only the
  /// recovery folder after a process death.
  func testAdoptParksAnInterruptedRecoveryFolder() async throws {
    let recovery = OrphanSpoolRecovery(root: harness.spoolRoot)
    let id = UUID()
    try writeAudio(
      to: recovery.recoveryDirectory.appendingPathComponent(id.uuidString)
        .appendingPathComponent("audio.pcm"))
    recovery.adopt()
    XCTAssertEqual(recovery.parked.first?.lastPathComponent, "\(id.uuidString).pcm")
    XCTAssertTrue(recoveryFolders(recovery).isEmpty)
    await recovery.recover(pipeline: harness.pipeline, store: harness.dictations)
    XCTAssertNotNil(try harness.row(id))
    XCTAssertFalse(recovery.hasOrphan)
  }

  func testAdoptParksTheLegacyOrphanFile() async throws {
    let recovery = OrphanSpoolRecovery(root: harness.spoolRoot)
    try writeAudio(to: recovery.legacyParked)
    recovery.adopt()
    XCTAssertFalse(FileManager.default.fileExists(atPath: recovery.legacyParked.path))
    XCTAssertEqual(recovery.orphanCount, 1)
  }

  /// A second left-over recording used to be deleted when one was already parked.
  func testAdoptKeepsEveryLeftOverRecording() async throws {
    let recovery = try leaveOrphan()
    try writeAudio(
      to: harness.spoolRoot.appendingPathComponent(UUID().uuidString)
        .appendingPathComponent("audio.pcm"))
    recovery.adopt()
    XCTAssertEqual(recovery.orphanCount, 2)
    await recovery.recover(pipeline: harness.pipeline, store: harness.dictations)
    XCTAssertEqual(try harness.rowCount(), 2)
    XCTAssertFalse(recovery.hasOrphan)
  }

  func testAdoptKeepsTheNewestWithinCapacity() throws {
    let recovery = OrphanSpoolRecovery(root: harness.spoolRoot)
    var newest: UUID?
    for index in 0..<(OrphanSpoolRecovery.capacity + 2) {
      let id = UUID()
      try writeAudio(to: recovery.file(for: id))
      try FileManager.default.setAttributes(
        [.creationDate: Date(timeIntervalSince1970: 1_000 + Double(index))],
        ofItemAtPath: recovery.file(for: id).path)
      newest = id
    }
    recovery.adopt()
    XCTAssertEqual(recovery.orphanCount, OrphanSpoolRecovery.capacity)
    XCTAssertTrue(FileManager.default.fileExists(atPath: recovery.file(for: newest!).path))
  }

  func testACleanSilentOrphanIsRemoved() async throws {
    await harness.runtime.set(text: "   ")
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
