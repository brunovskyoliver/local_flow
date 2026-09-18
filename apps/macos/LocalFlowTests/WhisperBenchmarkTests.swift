import Foundation
import XCTest

@testable import LocalFlow

/// Opt-in Feature 002 engine comparison. This test never changes the app's
/// default engine or writes to the transcription store. It writes only private
/// benchmark artifacts supplied by the caller.
final class WhisperBenchmarkTests: XCTestCase {
  private struct Receipt: Codable {
    let schemaVersion: Int
    let engine: String
    let language: String
    let model: String
    let shortRun: String
    let longRun: String
    let loadSeconds: Double?
    let peakResidentBytes: UInt64?
    let peakEngineResidentBytes: UInt64?
    let peakHostResidentBytes: UInt64?
    let hardware: String
    let operatingSystem: String
    let power: String
    let manifestShortSHA256: String
    let manifestLongSHA256: String
    let pipeline: [String: String]
  }

  private struct NativeCorpusStats: Codable {
    let fixtureCount: Int
    let completedFixtureCount: Int
    let failedFixtureCount: Int
    let audioSeconds: Double
    let recognitionSeconds: Double
    let wallSeconds: Double
    let firstRecognitionSeconds: Double?
    let firstWallSeconds: Double?
    let warmRecognitionSeconds: Double?
    let warmWallSeconds: Double?
    let realTimeFactor: Double?
  }

  private struct NativeReceipt: Codable {
    let schemaVersion: Int
    let engine: String
    let language: String
    let model: String
    let modelRevision: String
    let modelSHA256: String
    let whisperRuntime: String
    let shortRun: String
    let longRun: String
    let short: NativeCorpusStats
    let long: NativeCorpusStats
    let loadSeconds: Double?
    let peakResidentBytes: UInt64?
    let peakEngineResidentBytes: UInt64?
    let peakHostResidentBytes: UInt64?
    let hardware: String
    let operatingSystem: String
    let power: String
    let manifestShortSHA256: String
    let manifestLongSHA256: String
    let pipeline: [String: String]
  }

  private struct NativeEvidence: Codable {
    let fixtureID: String
    let durationSeconds: Double
    let elapsedSeconds: Double
    let detectedLanguage: String
    let languageProbability: Double?
    let segmentation: String
    let context: String
    let segments: [WhisperBenchmarkRuntime.NativeSegment]
  }

  private struct NativeAccumulator {
    var fixtureCount = 0
    var completedFixtureCount = 0
    var audioSeconds = 0.0
    var recognitionSeconds = 0.0
    var wallSeconds = 0.0
    var recognitionSamples: [Double] = []
    var wallSamples: [Double] = []

    mutating func append(audio: Double, recognition: Double, wall: Double) {
      fixtureCount += 1
      completedFixtureCount += 1
      audioSeconds += audio
      recognitionSeconds += recognition
      wallSeconds += wall
      recognitionSamples.append(recognition)
      wallSamples.append(wall)
    }

    mutating func appendFailure(audio: Double) {
      fixtureCount += 1
      audioSeconds += audio
    }

    func stats() -> NativeCorpusStats {
      NativeCorpusStats(
        fixtureCount: fixtureCount,
        completedFixtureCount: completedFixtureCount,
        failedFixtureCount: fixtureCount - completedFixtureCount,
        audioSeconds: audioSeconds,
        recognitionSeconds: recognitionSeconds,
        wallSeconds: wallSeconds,
        firstRecognitionSeconds: recognitionSamples.first,
        firstWallSeconds: wallSamples.first,
        warmRecognitionSeconds: recognitionSamples.dropFirst().isEmpty
          ? nil
          : recognitionSamples.dropFirst().reduce(0, +)
            / Double(recognitionSamples.dropFirst().count),
        warmWallSeconds: wallSamples.dropFirst().isEmpty
          ? nil
          : wallSamples.dropFirst().reduce(0, +) / Double(wallSamples.dropFirst().count),
        realTimeFactor: audioSeconds > 0 ? recognitionSeconds / audioSeconds : nil)
    }
  }

  private actor NativeRuntimeBox {
    enum Failure: Error { case unavailable }
    private var runtime: WhisperBenchmarkRuntime?

    func set(_ runtime: WhisperBenchmarkRuntime) { self.runtime = runtime }

    func transcribeFile(at path: URL) async throws -> WhisperBenchmarkRuntime.NativeTranscription {
      guard let runtime else { throw Failure.unavailable }
      return try await runtime.transcribeFile(at: path)
    }

    func helperVersion() async -> String? { await runtime?.helperVersion() }

    func clear() { runtime = nil }
  }

  func testOptInWhisperLargeV3TurboFrozenCorpusBenchmark() async throws {
    let env = ProcessInfo.processInfo.environment
    guard let outputPath = env["LOCALFLOW_WHISPER_BENCHMARK_OUTPUT"],
      let shortRootPath = env["LOCALFLOW_WHISPER_SHORT_ROOT"],
      let longRootPath = env["LOCALFLOW_WHISPER_LONG_ROOT"],
      let helperPath = env["LOCALFLOW_WHISPER_HELPER"],
      let whisperModelPath = env["LOCALFLOW_WHISPER_MODEL"],
      let whisperVADPath = env["LOCALFLOW_WHISPER_VAD_MODEL"]
    else {
      throw XCTSkip("Set the explicit Whisper benchmark inputs and output directory.")
    }

    let output = URL(fileURLWithPath: outputPath, isDirectory: true)
    guard !FileManager.default.fileExists(atPath: output.path) else {
      throw XCTSkip("Benchmark output already exists; choose a fresh directory.")
    }
    try QualityArtifacts.directory(output)

    let shortRoot = URL(fileURLWithPath: shortRootPath, isDirectory: true)
    let longRoot = URL(fileURLWithPath: longRootPath, isDirectory: true)
    let shortManifest = shortRoot.appendingPathComponent("manifest.json")
    let longManifest = longRoot.appendingPathComponent("manifest.json")
    let shortHash = try QualityArtifacts.hashFile(shortManifest)
    let longHash = try QualityArtifacts.hashFile(longManifest)
    XCTAssertEqual(
      shortHash, "10b9873c6b3f05fcb1b22a96a014a08c7a7f60566e8176ad2b799a1adbbd988b")
    XCTAssertEqual(
      longHash, "53b0a220bc53b7fba807e7667ca64488274cb42f77e187ffd749047399a75f97")

    let hardware = env["LOCALFLOW_QUALITY_HARDWARE"] ?? "unknown_not_supplied"
    let power = env["LOCALFLOW_QUALITY_POWER"] ?? "unknown_not_supplied"
    let modes = (env["LOCALFLOW_WHISPER_MODES"] ?? "auto,sk,en")
      .split(separator: ",").map(String.init)
    guard !modes.isEmpty, modes.allSatisfy(["auto", "sk", "en"].contains) else {
      XCTFail("invalid_whisper_modes")
      return
    }

    let descriptorURL = try XCTUnwrap(
      Bundle.main.url(forResource: "parakeet-v3", withExtension: "json"))
    let descriptor = try JSONDecoder().decode(
      ModelDescriptor.self, from: Data(contentsOf: descriptorURL))
    let parakeetSource = env["LOCALFLOW_MODEL_PROBE_ROOT"].map {
      URL(fileURLWithPath: $0, isDirectory: true)
    }

    if env["LOCALFLOW_WHISPER_INCLUDE_BASELINE"] != "0", let parakeetSource {
      let receipt = try await runParakeet(
        descriptor: descriptor, source: parakeetSource,
        shortManifest: shortManifest, shortRoot: shortRoot,
        longManifest: longManifest, longRoot: longRoot,
        output: output.appendingPathComponent("parakeet-auto"), hardware: hardware, power: power)
      try write(receipt, to: output.appendingPathComponent("parakeet-auto.json"))
    }

    for mode in modes {
      let receipt = try await runWhisper(
        language: mode, helper: URL(fileURLWithPath: helperPath),
        model: URL(fileURLWithPath: whisperModelPath),
        vadModel: URL(fileURLWithPath: whisperVADPath),
        shortManifest: shortManifest, shortRoot: shortRoot,
        longManifest: longManifest, longRoot: longRoot,
        output: output.appendingPathComponent("whisper-" + mode), hardware: hardware, power: power)
      try write(receipt, to: output.appendingPathComponent("whisper-" + mode + ".json"))
    }
  }

  /// Fair long-form comparison. Whisper receives one complete fixture per request and keeps
  /// whisper.cpp's internal 30-second segmentation and rolling context. This is separate from
  /// the historical fixed-window control above and never changes the production engine.
  func testOptInWhisperNativeFrozenCorpusBenchmark() async throws {
    let env = ProcessInfo.processInfo.environment
    guard let outputPath = env["LOCALFLOW_WHISPER_BENCHMARK_OUTPUT"],
      let shortRootPath = env["LOCALFLOW_WHISPER_SHORT_ROOT"],
      let longRootPath = env["LOCALFLOW_WHISPER_LONG_ROOT"],
      let helperPath = env["LOCALFLOW_WHISPER_HELPER"],
      let whisperModelPath = env["LOCALFLOW_WHISPER_MODEL"],
      let whisperVADPath = env["LOCALFLOW_WHISPER_VAD_MODEL"]
    else {
      throw XCTSkip("Set the explicit native Whisper benchmark inputs and output directory.")
    }
    let output = URL(fileURLWithPath: outputPath, isDirectory: true)
    guard !FileManager.default.fileExists(atPath: output.path) else {
      throw XCTSkip("Benchmark output already exists; choose a fresh directory.")
    }
    try QualityArtifacts.directory(output)

    let shortRoot = URL(fileURLWithPath: shortRootPath, isDirectory: true)
    let longRoot = URL(fileURLWithPath: longRootPath, isDirectory: true)
    let shortManifest = shortRoot.appendingPathComponent("manifest.json")
    let longManifest = longRoot.appendingPathComponent("manifest.json")
    let shortHash = try QualityArtifacts.hashFile(shortManifest)
    let longHash = try QualityArtifacts.hashFile(longManifest)
    XCTAssertEqual(
      shortHash, "10b9873c6b3f05fcb1b22a96a014a08c7a7f60566e8176ad2b799a1adbbd988b")
    XCTAssertEqual(
      longHash, "53b0a220bc53b7fba807e7667ca64488274cb42f77e187ffd749047399a75f97")

    let hardware = env["LOCALFLOW_QUALITY_HARDWARE"] ?? "unknown_not_supplied"
    let power = env["LOCALFLOW_QUALITY_POWER"] ?? "unknown_not_supplied"
    let model = env["LOCALFLOW_WHISPER_MODEL_ID"] ?? "whisper-large-v3-turbo"
    let modelRevision = env["LOCALFLOW_WHISPER_MODEL_REVISION"] ?? "unknown_model_revision"
    let modelSHA256 = env["LOCALFLOW_WHISPER_MODEL_SHA256"] ?? "unknown_model_sha256"
    let runtimeRevision = env["LOCALFLOW_WHISPER_RUNTIME_REVISION"] ?? "unknown_runtime_revision"
    guard modelRevision != "unknown_model_revision", modelSHA256.count == 64,
      modelSHA256.allSatisfy(\.isHexDigit), runtimeRevision != "unknown_runtime_revision"
    else {
      XCTFail("native Whisper benchmark needs pinned model and runtime identities")
      return
    }
    let modes = (env["LOCALFLOW_WHISPER_MODES"] ?? "auto,sk,en")
      .split(separator: ",").map(String.init)
    guard !modes.isEmpty, modes.allSatisfy(["auto", "sk", "en"].contains) else {
      XCTFail("invalid_whisper_modes")
      return
    }

    let descriptorURL = try XCTUnwrap(
      Bundle.main.url(forResource: "parakeet-v3", withExtension: "json"))
    let descriptor = try JSONDecoder().decode(
      ModelDescriptor.self, from: Data(contentsOf: descriptorURL))
    let parakeetSource = env["LOCALFLOW_MODEL_PROBE_ROOT"].map {
      URL(fileURLWithPath: $0, isDirectory: true)
    }
    if env["LOCALFLOW_WHISPER_INCLUDE_BASELINE"] != "0", let parakeetSource {
      let receipt = try await runParakeet(
        descriptor: descriptor, source: parakeetSource,
        shortManifest: shortManifest, shortRoot: shortRoot,
        longManifest: longManifest, longRoot: longRoot,
        output: output.appendingPathComponent("parakeet-auto"), hardware: hardware, power: power)
      try write(receipt, to: output.appendingPathComponent("parakeet-auto.json"))
    }

    for mode in modes {
      let receipt = try await runNativeWhisper(
        language: mode, modelID: model, modelRevision: modelRevision, modelSHA256: modelSHA256,
        runtimeRevision: runtimeRevision, helper: URL(fileURLWithPath: helperPath),
        model: URL(fileURLWithPath: whisperModelPath),
        vadModel: URL(fileURLWithPath: whisperVADPath), shortManifest: shortManifest,
        shortRoot: shortRoot, longManifest: longManifest, longRoot: longRoot,
        output: output.appendingPathComponent(model + "-" + mode), hardware: hardware, power: power)
      try write(receipt, to: output.appendingPathComponent(model + "-" + mode + ".json"))
    }
  }

  private func runParakeet(
    descriptor: ModelDescriptor, source: URL,
    shortManifest: URL, shortRoot: URL, longManifest: URL, longRoot: URL,
    output: URL, hardware: String, power: String
  ) async throws -> Receipt {
    try descriptor.validate()
    let installRoot = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
      "LocalFlowTests-whisper-parakeet-" + UUID().uuidString, isDirectory: true)
    let provisioner = ModelProvisioner(descriptor: descriptor, rootURL: installRoot)
    let local = try await provisioner.install(from: source)
    defer { try? FileManager.default.removeItem(at: installRoot) }
    let probe = WhisperBenchmarkProbe()
    await probe.attach(processID: getpid())
    let recorder = ChunkEvidenceRecorder()
    let started = DispatchTime.now().uptimeNanoseconds
    let lifecycle = ModelLifecycleCoordinator {
      let runtime = try await FluidAudioEngineFactory(
        descriptor: local,
        evidenceObserver: { evidence in try await recorder.append(evidence) }
      ).makeRuntime()
      await probe.recordLoad(DispatchTime.now().uptimeNanoseconds &- started)
      await probe.observe()
      return runtime
    }
    do {
      try await runCorpus(
        lifecycle: lifecycle, recorder: recorder, shortManifest: shortManifest,
        shortRoot: shortRoot, longManifest: longManifest, longRoot: longRoot,
        output: output, engine: "FluidAudio", language: "automatic_no_hint",
        hardware: hardware, power: power)
      try await lifecycle.shutdownIfIdle()
    } catch {
      try? await lifecycle.shutdownIfIdle()
      throw error
    }
    return try await receipt(
      probe: probe, engine: "FluidAudio", language: "automatic_no_hint", output: output,
      shortManifest: shortManifest, longManifest: longManifest, hardware: hardware, power: power)
  }

  private func runWhisper(
    language: String, helper: URL, model: URL, vadModel: URL,
    shortManifest: URL, shortRoot: URL, longManifest: URL, longRoot: URL,
    output: URL, hardware: String, power: String
  ) async throws -> Receipt {
    let probe = WhisperBenchmarkProbe()
    let recorder = ChunkEvidenceRecorder()
    let lifecycle = ModelLifecycleCoordinator {
      try await WhisperBenchmarkRuntime.make(
        executable: helper, model: model, vadModel: vadModel,
        language: language, probe: probe,
        evidenceObserver: { evidence in try await recorder.append(evidence) })
    }
    do {
      try await runCorpus(
        lifecycle: lifecycle, recorder: recorder, shortManifest: shortManifest,
        shortRoot: shortRoot, longManifest: longManifest, longRoot: longRoot,
        output: output, engine: "whisper.cpp", language: language,
        hardware: hardware, power: power)
      try await lifecycle.shutdownIfIdle()
    } catch {
      try? await lifecycle.shutdownIfIdle()
      throw error
    }
    return try await receipt(
      probe: probe, engine: "whisper.cpp", language: language, output: output,
      shortManifest: shortManifest, longManifest: longManifest, hardware: hardware, power: power)
  }

  private func runNativeWhisper(
    language: String, modelID: String, modelRevision: String, modelSHA256: String,
    runtimeRevision: String, helper: URL, model: URL, vadModel: URL,
    shortManifest: URL, shortRoot: URL, longManifest: URL, longRoot: URL,
    output: URL, hardware: String, power: String
  ) async throws -> NativeReceipt {
    let probe = WhisperBenchmarkProbe()
    let box = NativeRuntimeBox()
    try QualityArtifacts.directory(output)
    let lifecycle = ModelLifecycleCoordinator {
      let runtime = try await WhisperBenchmarkRuntime.make(
        executable: helper, model: model, vadModel: vadModel, language: language, probe: probe)
      await box.set(runtime)
      return runtime
    }
    do {
      let short = try await runNativeCorpus(
        lifecycle: lifecycle, box: box, manifest: shortManifest, fixtureRoot: shortRoot,
        output: output.appendingPathComponent("short"), language: language, modelID: modelID,
        modelRevision: modelRevision, modelSHA256: modelSHA256, runtimeRevision: runtimeRevision,
        hardware: hardware, power: power)
      let long = try await runNativeCorpus(
        lifecycle: lifecycle, box: box, manifest: longManifest, fixtureRoot: longRoot,
        output: output.appendingPathComponent("long"), language: language, modelID: modelID,
        modelRevision: modelRevision, modelSHA256: modelSHA256, runtimeRevision: runtimeRevision,
        hardware: hardware, power: power)
      try await lifecycle.shutdownIfIdle()
      let measurements = await probe.snapshot()
      let runtimeName = await box.helperVersion() ?? "unknown_runtime"
      await box.clear()
      return NativeReceipt(
        schemaVersion: 2, engine: "whisper.cpp", language: language, model: modelID,
        modelRevision: modelRevision, modelSHA256: modelSHA256, whisperRuntime: runtimeName,
        shortRun: output.appendingPathComponent("short").path,
        longRun: output.appendingPathComponent("long").path, short: short, long: long,
        loadSeconds: measurements.loadNanoseconds.map { Double($0) / 1_000_000_000 },
        peakResidentBytes: measurements.peakResidentBytes,
        peakEngineResidentBytes: measurements.peakEngineResidentBytes,
        peakHostResidentBytes: measurements.peakHostResidentBytes, hardware: hardware,
        operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString, power: power,
        manifestShortSHA256: try QualityArtifacts.hashFile(shortManifest),
        manifestLongSHA256: try QualityArtifacts.hashFile(longManifest),
        pipeline: [
          "audio_request": "one complete fixture WAV per request",
          "segmentation": "whisper_full internal 30-second seeks and native segments",
          "context":
            "rolling internal prompt context within each request; fresh whisper_state per fixture",
          "production_chunk_planner": "not used",
          "assembly": "native_passthrough_v1",
          "normalization": TranscriptNormalizer.version,
          "vocabulary": "VocabularySnapshot.empty",
          "persistence": "unchanged; benchmark does not write the store",
        ])
    } catch {
      try? await lifecycle.shutdownIfIdle()
      await box.clear()
      throw error
    }
  }

  private func runNativeCorpus(
    lifecycle: ModelLifecycleCoordinator, box: NativeRuntimeBox,
    manifest manifestURL: URL, fixtureRoot: URL, output: URL, language: String,
    modelID: String, modelRevision: String, modelSHA256: String, runtimeRevision: String,
    hardware: String, power: String
  ) async throws -> NativeCorpusStats {
    let manifest = try QualityArtifacts.read(QualityManifest.self, from: manifestURL)
    try manifest.validate(root: fixtureRoot)
    let manifestHash = try QualityArtifacts.hashFile(manifestURL, limit: QualityArtifacts.small)
    for fixture in manifest.fixtures {
      let audioURL = try fixture.audioURL(root: fixtureRoot)
      guard try QualityArtifacts.hashFile(audioURL) == fixture.sha256 else {
        throw QualityArtifacts.Failure.invalid
      }
    }
    try QualityArtifacts.directory(output)
    let results = output.appendingPathComponent("results", isDirectory: true)
    let segments = output.appendingPathComponent("native-segments", isDirectory: true)
    try QualityArtifacts.directory(results)
    try QualityArtifacts.directory(segments)
    let config: [String: String] = [
      "engine": "whisper.cpp",
      "sdk": "whisper.cpp@" + runtimeRevision,
      "model": modelID,
      "model_revision": modelRevision,
      "model_sha256": modelSHA256,
      "language": language,
      "window_samples": "not_applicable_native_complete_fixture",
      "overlap_samples": "not_applicable_native",
      "padding_minimum": "not_applicable_native",
      "segmentation": "whisper_full_internal_30s_seek_segments_v1",
      "context": "rolling_internal_prompt_context_with_fresh_state_per_fixture",
      "production_chunk_planner": "not_used",
      "assembly": "native_passthrough_v1",
      "normalization": TranscriptNormalizer.version,
      "vocabulary": "VocabularySnapshot.empty",
      "persistence": "not_written_evaluation_only",
      "hardware": hardware,
      "power": power,
      "os": ProcessInfo.processInfo.operatingSystemVersionString,
    ]
    let configData = try QualityArtifacts.encode(config, limit: QualityArtifacts.small)
    var run = QualityRun(
      runId: UUID().uuidString, manifestSha256: manifestHash, config: config,
      configSha256: QualityArtifacts.hash(configData),
      ledger: manifest.fixtures.map { .init(id: $0.id) })
    let ledger = output.appendingPathComponent("run.json")
    try persist(run, to: ledger, replace: false)
    let active = try await lifecycle.acquire(session: UUID())
    var accumulator = NativeAccumulator()
    do {
      for index in manifest.fixtures.indices {
        let fixture = manifest.fixtures[index]
        run.status = "running"
        run.ledger[index].status = "running"
        try persist(run, to: ledger)
        let audioURL = try fixture.audioURL(root: fixtureRoot)
        let wallStart = DispatchTime.now().uptimeNanoseconds
        do {
          let native = try await box.transcribeFile(at: audioURL)
          let wallSeconds = Double(DispatchTime.now().uptimeNanoseconds - wallStart) / 1_000_000_000
          guard abs(native.durationSeconds - fixture.durationSeconds) < 0.01 else {
            throw WhisperBenchmarkRuntime.Failure.invalidResponse
          }
          let normalizationStart = DispatchTime.now().uptimeNanoseconds
          let normalized = TranscriptNormalizer(vocabulary: .empty).normalize(native.text)
          let normalizationSeconds =
            Double(DispatchTime.now().uptimeNanoseconds - normalizationStart) / 1_000_000_000
          let evidence = RecognitionEvidence(
            text: native.text, samples: fixture.numSamples, paddedSamples: fixture.numSamples,
            timingsAvailable: false, tokens: [])
          let window = QualityResult.Window(
            sequence: 0, sampleStart: 0, evidence: evidence, text: native.text,
            sha256: QualityArtifacts.hash(Data(native.text.utf8)), tokens: [])
          let reasons = normalized.reasons.map(\.rawValue)
          let result = QualityResult(
            id: fixture.id, status: "completed", incomplete: normalized.incomplete,
            reasons: reasons,
            windows: [window],
            stages: [
              "raw": .init(text: native.text, identity: "whisper_full_native_segments"),
              "assembled": .init(text: native.text, identity: "native_passthrough_v1"),
              "normalized": .init(text: normalized.text, identity: TranscriptNormalizer.version),
            ],
            measurements: [
              "audio_seconds": .init(
                value: native.durationSeconds, unit: "seconds", reason: "measured_fixture_duration"),
              "recognition_seconds": .init(
                value: native.elapsedSeconds, unit: "seconds", reason: "helper_reported"),
              "wall_seconds": .init(value: wallSeconds, unit: "seconds", reason: "measured"),
              "real_time_factor": .init(
                value: native.elapsedSeconds / native.durationSeconds,
                unit: "ratio", reason: "recognition_seconds_divided_by_audio_seconds"),
              "native_segment_count": .init(
                value: Double(native.segments.count), unit: "count", reason: "helper_reported"),
              "normalization_seconds": .init(
                value: normalizationSeconds, unit: "seconds", reason: "measured"),
              "rss": .init(unit: "bytes", reason: "recorded_in_receipt"),
            ])
          let data = try QualityArtifacts.encode(result)
          try QualityArtifacts.write(
            data, to: results.appendingPathComponent(fixture.id + ".json"), replace: false)
          let nativeData = try QualityArtifacts.encode(
            NativeEvidence(
              fixtureID: fixture.id, durationSeconds: native.durationSeconds,
              elapsedSeconds: native.elapsedSeconds, detectedLanguage: native.detectedLanguage,
              languageProbability: native.languageProbability, segmentation: native.segmentation,
              context: native.context, segments: native.segments))
          try QualityArtifacts.write(
            nativeData, to: segments.appendingPathComponent(fixture.id + ".json"), replace: false)
          run.ledger[index].resultSha256 = QualityArtifacts.hash(data)
          run.ledger[index].status = "completed"
          accumulator.append(
            audio: native.durationSeconds, recognition: native.elapsedSeconds, wall: wallSeconds)
        } catch {
          let result = QualityResult(
            id: fixture.id, status: "failed", incomplete: true, reasons: ["decode_failed"],
            windows: [],
            stages: [
              "raw": .init(unavailable: "native_decode_failed"),
              "assembled": .init(unavailable: "native_decode_failed"),
              "normalized": .init(unavailable: "native_decode_failed"),
            ],
            measurements: [
              "audio_seconds": .init(
                value: fixture.durationSeconds, unit: "seconds", reason: "manifest_duration"),
              "wall_seconds": .init(
                value: Double(DispatchTime.now().uptimeNanoseconds - wallStart) / 1_000_000_000,
                unit: "seconds", reason: "measured_until_failure"),
            ])
          let data = try QualityArtifacts.encode(result)
          try QualityArtifacts.write(
            data, to: results.appendingPathComponent(fixture.id + ".json"), replace: false)
          run.ledger[index].resultSha256 = QualityArtifacts.hash(data)
          run.ledger[index].status = "failed"
          accumulator.appendFailure(audio: fixture.durationSeconds)
        }
        try persist(run, to: ledger)
      }
      try await lifecycle.finish(active)
      await lifecycle.releaseIfIdle(generation: active.generation)
    } catch {
      await lifecycle.cancelAndJoin(active)
      throw error
    }
    run.status = "complete"
    try persist(run, to: ledger)
    return accumulator.stats()
  }

  private func runCorpus(
    lifecycle: ModelLifecycleCoordinator, recorder: ChunkEvidenceRecorder,
    shortManifest: URL, shortRoot: URL, longManifest: URL, longRoot: URL,
    output: URL, engine: String, language: String, hardware: String, power: String
  ) async throws {
    try QualityArtifacts.directory(output)
    let strategy = QualityChunkExperiment.Strategy(
      id: "contiguous-fixed", overlapSamples: 0, silenceSearchStart: 0,
      maximumSpeechProbability: nil, normalize: true)
    let baseConfig: [String: String] = [
      "engine": engine,
      "language": language,
      "model": engine == "whisper.cpp" ? "whisper-large-v3-turbo" : "parakeet-tdt-0.6b-v3",
      "window_samples": "239360",
      "overlap_samples": "0",
      "assembly": TranscriptAssembler.version,
      "normalization": TranscriptNormalizer.version,
      "vocabulary": "empty_snapshot_for_recognition_comparison",
      "persistence": "not_written_evaluation_only",
      "hardware": hardware,
      "power": power,
      "os": ProcessInfo.processInfo.operatingSystemVersionString,
    ]
    try await QualityChunkExperiment(
      lifecycle: lifecycle, recorder: recorder, strategy: strategy
    ).run(
      manifestURL: shortManifest, fixtureRoot: shortRoot,
      output: output.appendingPathComponent("short"), config: baseConfig)
    try await QualityChunkExperiment(
      lifecycle: lifecycle, recorder: recorder, strategy: strategy
    ).run(
      manifestURL: longManifest, fixtureRoot: longRoot,
      output: output.appendingPathComponent("long"), config: baseConfig)
  }

  private func receipt(
    probe: WhisperBenchmarkProbe, engine: String, language: String, output: URL,
    shortManifest: URL, longManifest: URL, hardware: String, power: String
  ) async throws -> Receipt {
    let measurements = await probe.snapshot()
    func seconds(_ nanoseconds: UInt64?) -> Double? {
      nanoseconds.map { Double($0) / 1_000_000_000 }
    }
    return Receipt(
      schemaVersion: 1, engine: engine, language: language,
      model: engine == "whisper.cpp" ? "whisper-large-v3-turbo" : "parakeet-tdt-0.6b-v3",
      shortRun: output.appendingPathComponent("short").path,
      longRun: output.appendingPathComponent("long").path,
      loadSeconds: seconds(measurements.loadNanoseconds),
      peakResidentBytes: measurements.peakResidentBytes,
      peakEngineResidentBytes: measurements.peakEngineResidentBytes,
      peakHostResidentBytes: measurements.peakHostResidentBytes,
      hardware: hardware, operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
      power: power, manifestShortSHA256: try QualityArtifacts.hashFile(shortManifest),
      manifestLongSHA256: try QualityArtifacts.hashFile(longManifest),
      pipeline: [
        "chunking": "ChunkPlanner contiguous-fixed 239360/0",
        "assembly": TranscriptAssembler.version,
        "normalization": TranscriptNormalizer.version,
        "vocabulary": "VocabularySnapshot.empty",
        "persistence": "unchanged; benchmark does not write the store",
      ])
  }

  private func write(_ receipt: Receipt, to url: URL) throws {
    let data = try QualityArtifacts.encode(receipt, limit: QualityArtifacts.small)
    try QualityArtifacts.write(data, to: url, replace: false, limit: QualityArtifacts.small)
  }

  private func write(_ receipt: NativeReceipt, to url: URL) throws {
    let data = try QualityArtifacts.encode(receipt, limit: QualityArtifacts.small)
    try QualityArtifacts.write(data, to: url, replace: false, limit: QualityArtifacts.small)
  }

  private func persist(_ run: QualityRun, to url: URL, replace: Bool = true) throws {
    try QualityArtifacts.write(
      QualityArtifacts.encode(run, limit: QualityArtifacts.small), to: url, replace: replace,
      limit: QualityArtifacts.small)
  }
}
