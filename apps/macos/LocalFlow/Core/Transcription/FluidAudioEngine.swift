import CoreML
import FluidAudio
import Foundation

/// Constructs the pinned Parakeet v3 runtime only from a previously verified local model.
/// The lifecycle coordinator owns the returned runtime and is the only caller of this factory.
struct FluidAudioEngineFactory: Sendable {
  let descriptor: LocalModelDescriptor
  var evidenceObserver: (@Sendable (RecognitionEvidence) async throws -> Void)? = nil

  func makeRuntime() async throws -> any TranscriptionRuntime {
    try descriptor.descriptor.validate()
    guard descriptor.descriptor.modelID == "FluidInference/parakeet-tdt-0.6b-v3-coreml",
      descriptor.descriptor.sourceRevision == "7dd20fe6b1797d35f5e3307e8b1732d9a178edfe",
      descriptor.descriptor.sdkCompatibility == "0.15.7", descriptor.descriptor.automaticLanguage
    else { throw DictationFailure.modelUnavailable }
    let configuration = MLModelConfiguration()
    configuration.computeUnits = .all
    // Direct local URLs only: never use a download-capable convenience loader.
    func load(_ name: String) throws -> MLModel {
      try Task.checkCancellation()
      return try MLModel(
        contentsOf: descriptor.rootURL.appendingPathComponent(name), configuration: configuration)
    }
    let vocabularyURL = descriptor.rootURL.appendingPathComponent("parakeet_vocab.json")
    let vocabularySize =
      try vocabularyURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
    guard vocabularySize <= 1_048_576 else { throw DictationFailure.invalidResult }
    let raw = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: vocabularyURL))
    guard raw.count <= 16_384 else { throw DictationFailure.invalidResult }
    var vocabulary: [Int: String] = [:]
    for (key, value) in raw {
      guard let id = Int(key), id >= 0 else { throw DictationFailure.invalidResult }
      vocabulary[id] = value
    }
    let models = try AsrModels(
      encoder: load("Encoder.mlmodelc"),
      preprocessor: load("Preprocessor.mlmodelc"), decoder: load("Decoder.mlmodelc"),
      joint: load("JointDecisionv3.mlmodelc"), configuration: configuration,
      vocabulary: vocabulary, version: .v3)
    let manager = AsrManager(
      config: ASRConfig(sampleRate: 16_000, parallelChunkConcurrency: 1), models: models)
    return FluidAudioRuntime(manager: manager, evidenceObserver: evidenceObserver)
  }
}

actor FluidAudioRuntime: TranscriptionRuntime {
  private let manager: AsrManager

  private let evidenceObserver: (@Sendable (RecognitionEvidence) async throws -> Void)?

  init(
    manager: AsrManager,
    evidenceObserver: (@Sendable (RecognitionEvidence) async throws -> Void)? = nil
  ) {
    self.manager = manager
    self.evidenceObserver = evidenceObserver
  }

  func transcribe(_ samples: [Float]) async throws -> TranscriptionWindow {
    let actualCount = samples.count
    let bounded = try Self.paddedWindow(samples)
    var decoderState = TdtDecoderState.make(decoderLayers: AsrModelVersion.v3.decoderLayers)
    let result = try await manager.transcribe(bounded, decoderState: &decoderState, language: nil)
    guard result.text.utf8.count <= 65_536, (result.tokenTimings?.count ?? 0) <= 16_384,
      (result.tokenTimings ?? []).reduce(0, { min(65_537, $0 + min(65_537, $1.token.utf8.count)) })
        <= 65_536
    else { throw DictationFailure.invalidResult }
    let evidence = RecognitionEvidence(
      text: result.text, samples: actualCount, paddedSamples: bounded.count,
      timingsAvailable: result.tokenTimings != nil,
      tokens: (result.tokenTimings ?? []).map {
        .init(text: $0.token, start: .init($0.startTime), end: .init($0.endTime))
      })
    try await evidenceObserver?(evidence)
    let timings = try buildWordTimings(from: result.tokenTimings ?? []).map { timing in
      try Self.clampedToken(
        text: timing.word, start: timing.startTime, end: timing.endTime, sampleCount: actualCount)
    }
    guard result.text.utf8.count <= 65_536 else { throw DictationFailure.invalidResult }
    return TranscriptionWindow(text: result.text, tokens: Array(timings), evidence: evidence)
  }

  nonisolated static func clampedToken(text: String, start: Double, end: Double, sampleCount: Int)
    throws -> TranscriptionToken
  {
    guard start.isFinite, end.isFinite, end >= start, sampleCount > 0, sampleCount <= 239_360 else {
      throw DictationFailure.invalidResult
    }
    let duration = Double(sampleCount) / 16_000
    return .init(text: text, start: max(0, min(start, duration)), end: max(0, min(end, duration)))
  }

  nonisolated static func paddedWindow(_ samples: [Float]) throws -> [Float] {
    guard !samples.isEmpty, samples.count <= 239_360, samples.allSatisfy(\.isFinite) else {
      throw DictationFailure.invalidAudio
    }
    if samples.count >= 4_800 { return samples }
    return samples + repeatElement(0, count: 4_800 - samples.count)
  }

  func shutdown() async {
    await manager.cleanup()
  }
}

/// Immutable SDK evidence, captured before word building/clamping.
struct RecognitionEvidence: Codable, Sendable {
  struct Timing: Codable, Sendable {
    let value: Double?
    let invalid: String?
    init(_ value: Double) {
      self.value = value.isFinite ? value : nil
      invalid =
        value.isFinite
        ? nil : (value.isNaN ? "nan" : (value > 0 ? "positive_infinity" : "negative_infinity"))
    }
  }
  struct Token: Codable, Sendable {
    let text: String
    let start: Timing
    let end: Timing
  }
  let text: String
  let samples: Int
  let paddedSamples: Int
  let timingsAvailable: Bool
  let tokens: [Token]
}
