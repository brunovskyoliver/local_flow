import AVFoundation
import XCTest

@testable import LocalFlow

final class QualityEvaluationTests: XCTestCase {
  /// Guard the evaluation entry and its private artifact helpers against diagnostic sinks.
  /// This source-level assertion does not claim to audit third-party SDK logging.
  func testEvaluatorHasNoTranscriptLoggingOrAttachments() throws {
    let tests = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    var sources = try [
      "QualityEvaluationRunner.swift", "QualityEvaluationArtifacts.swift",
      "QualityAssemblyReplay.swift", "QualityChunkExperiment.swift",
    ].map {
      try String(contentsOf: tests.appendingPathComponent("Support/" + $0), encoding: .utf8)
    }
    let runtime = try String(
      contentsOf: tests.appendingPathComponent("RuntimeCompatibilityTests.swift"), encoding: .utf8)
    let start = try XCTUnwrap(runtime.range(of: "  func testOptInQualityFixtures()"))
    let end = try XCTUnwrap(
      runtime.range(of: "  func testRuntimeFactoryDoesNotLoadWithoutVerifiedAssets()"))
    let entry = String(runtime[start.lowerBound..<end.lowerBound])
    sources.append(entry)
    let sinks = #"\b(print|debugPrint|dump|NSLog|os_log|Logger|XCTAttachment|record)\s*\("#
    for source in sources {
      XCTAssertTrue(
        source.range(of: sinks, options: .regularExpression) == nil,
        "quality evaluator must not emit logs or attachments")
    }
    XCTAssertTrue(
      entry.contains(#"XCTFail("quality_evaluation_failed; inspect private inputs and ledger")"#))
    let failureLines = entry.split(separator: "\n").filter { $0.contains("XCTFail(") }
    XCTAssertEqual(failureLines.count, 1)
    XCTAssertFalse(failureLines.contains { $0.contains(#"\("#) })
  }

  func testSafeIDsAndBudget() throws {
    XCTAssertNoThrow(try QualityArtifacts.validateID("fixture-01"))
    XCTAssertThrowsError(try QualityArtifacts.validateID("../private"))
    XCTAssertThrowsError(try QualityArtifacts.validateID(String(repeating: "a", count: 129)))
    XCTAssertNoThrow(try QualityArtifacts.reserve(count: 30))
    XCTAssertThrowsError(try QualityArtifacts.reserve(count: 256))
  }

  func testDurablePrivateWriteDoesNotOverwrite() throws {
    let root = try makeSpoolRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("result.json")
    try QualityArtifacts.write(Data("{}".utf8), to: url, replace: false)
    XCTAssertThrowsError(try QualityArtifacts.write(Data(), to: url, replace: false))
    let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
    XCTAssertEqual(mode, 0o600)
    XCTAssertEqual(try Data(contentsOf: url), Data("{}".utf8))
  }

  func testStageHashesAndUnavailableStage() throws {
    let stage = QualityStage(text: "c\u{030c}", identity: "test")
    XCTAssertNotEqual(stage.sha256, QualityArtifacts.hash(Data("č".utf8)))
    XCTAssertNil(QualityStage(unavailable: "historical_stage_absent").text)
  }
  private func fixture(_ root: URL) throws -> URL {
    let audioURL = root.appendingPathComponent("input.wav")
    let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
    var audio: AVAudioFile? = try AVAudioFile(forWriting: audioURL, settings: format.settings)
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1600)!
    buffer.frameLength = 1600
    buffer.floatChannelData![0].initialize(repeating: 0, count: 1600)
    try audio!.write(from: buffer)
    audio = nil
    let row = QualityFixture(
      id: "test-01", path: "input.wav",
      sha256: try QualityArtifacts.hashFile(audioURL), reference: "authored test",
      referenceSha256: QualityArtifacts.hash(Data("authored test".utf8)), sampleRate: 16000,
      numSamples: 1600, durationSeconds: 0.1, categories: ["test"], languages: ["en"],
      classification: "synthetic", partition: "tuning", source: "generated silence for unit test",
      rights: "authored test", consentBasis: "no human speech", derivations: [], switches: [],
      technicalTerms: [])
    let url = root.appendingPathComponent("manifest.json")
    try QualityArtifacts.write(
      QualityArtifacts.encode(
        QualityManifest(schemaVersion: 2, setVersion: "unit-test", fixtures: [row])), to: url,
      replace: false)
    return url
  }

  func testRunnerAndResultBeforeLedgerRecovery() async throws {
    let root = try makeSpoolRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let manifest = try fixture(root)
    let recorder = QualityEvidenceRecorder()
    let runtime = QualityFakeRuntime(recorder: recorder)
    let lifecycle = ModelLifecycleCoordinator { runtime }
    let output = root.appendingPathComponent("run")
    let runner = QualityEvaluationRunner(
      lifecycle: lifecycle, recorder: recorder,
      beforeCommit: { point in
        if point == "after_result" { throw QualityArtifacts.Failure.storage }
      })
    do {
      try await runner.run(manifestURL: manifest, fixtureRoot: root, output: output, config: [:])
      XCTFail("injected storage failure must stop the runner")
    } catch QualityArtifacts.Failure.storage {}
    let before = try QualityArtifacts.read(
      QualityRun.self, from: output.appendingPathComponent("run.json"))
    XCTAssertEqual(before.ledger.first?.status, "running")
    try QualityEvaluationRunner.recover(output: output)
    let after = try QualityArtifacts.read(
      QualityRun.self, from: output.appendingPathComponent("run.json"))
    XCTAssertEqual(after.status, "interrupted")
    XCTAssertEqual(after.ledger.first?.status, "completed")
    XCTAssertNotNil(after.ledger.first?.resultSha256)
    XCTAssertThrowsError(try QualityEvaluationRunner.recover(output: output))
    let calls = await runtime.calls
    let stopped = await runtime.stopped
    let state = await lifecycle.state
    XCTAssertEqual(calls, 1)
    XCTAssertTrue(stopped)
    XCTAssertEqual(state, .unloaded)
  }

  func testFailedWriteLeavesUnfinishedLedger() async throws {
    let root = try makeSpoolRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let manifest = try fixture(root)
    let recorder = QualityEvidenceRecorder()
    let lifecycle = ModelLifecycleCoordinator { QualityFakeRuntime(recorder: recorder) }
    let output = root.appendingPathComponent("run")
    let runner = QualityEvaluationRunner(
      lifecycle: lifecycle, recorder: recorder,
      beforeCommit: { _ in
        throw QualityArtifacts.Failure.storage
      })
    do {
      try await runner.run(manifestURL: manifest, fixtureRoot: root, output: output, config: [:])
      XCTFail("expected storage failure")
    } catch QualityArtifacts.Failure.storage {}
    try QualityEvaluationRunner.recover(output: output)
    let run = try QualityArtifacts.read(
      QualityRun.self, from: output.appendingPathComponent("run.json"))
    XCTAssertEqual(run.ledger.first?.status, "interrupted")
    XCTAssertNil(run.ledger.first?.resultSha256)
  }

  func testCancelledRunAccountsForPendingFixture() async throws {
    let root = try makeSpoolRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let manifest = try fixture(root)
    let recorder = QualityEvidenceRecorder()
    let runtime = QualityFakeRuntime(recorder: recorder)
    let lifecycle = ModelLifecycleCoordinator { runtime }
    let output = root.appendingPathComponent("run")
    let task = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      try await QualityEvaluationRunner(lifecycle: lifecycle, recorder: recorder).run(
        manifestURL: manifest, fixtureRoot: root, output: output, config: [:])
    }
    try await task.value
    let run = try QualityArtifacts.read(
      QualityRun.self, from: output.appendingPathComponent("run.json"))
    XCTAssertEqual(run.ledger.first?.status, "not_run")
    let calls = await runtime.calls
    XCTAssertEqual(calls, 0)
  }

  func testPreflightRejectsDuplicateAndEscapingPath() throws {
    let root = try makeSpoolRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let url = try fixture(root)
    let manifest = try QualityArtifacts.read(QualityManifest.self, from: url)
    let duplicate = QualityManifest(
      schemaVersion: 2, setVersion: "test", fixtures: manifest.fixtures + manifest.fixtures)
    XCTAssertThrowsError(try duplicate.validate(root: root))
    var object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
    var rows = object["fixtures"] as! [[String: Any]]
    rows[0]["path"] = "../outside.wav"
    object["fixtures"] = rows
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    let escaped = try decoder.decode(
      QualityManifest.self, from: JSONSerialization.data(withJSONObject: object))
    XCTAssertThrowsError(try escaped.validate(root: root))
  }

  func testObserverBoundsAndInvalidTimingEncoding() async throws {
    let recorder = QualityEvidenceRecorder()
    let evidence = RecognitionEvidence(
      text: "authored", samples: 1, paddedSamples: 4800,
      timingsAvailable: true,
      tokens: [.init(text: "test", start: .init(.nan), end: .init(.infinity))])
    for _ in 0..<32 { try await recorder.append(evidence) }
    do {
      try await recorder.append(evidence)
      XCTFail("trace must reject window 33")
    } catch QualityArtifacts.Failure.capacity {}
    let windows = await recorder.drain()
    XCTAssertEqual(windows.count, 32)
    XCTAssertNoThrow(try QualityArtifacts.encode(windows))
    XCTAssertNil(windows[0].tokens[0].start.value)
    XCTAssertEqual(windows[0].tokens[0].start.invalid, "nan")
  }

}

private actor QualityFakeRuntime: TranscriptionRuntime {
  let recorder: QualityEvidenceRecorder
  private(set) var calls = 0
  private(set) var stopped = false
  init(recorder: QualityEvidenceRecorder) { self.recorder = recorder }
  func transcribe(_ samples: [Float]) async throws -> TranscriptionWindow {
    calls += 1
    try await recorder.append(
      .init(
        text: "authored test", samples: samples.count,
        paddedSamples: max(4800, samples.count), timingsAvailable: false, tokens: []))
    return .init(text: "authored test", tokens: [])
  }
  func shutdown() async { stopped = true }
}
