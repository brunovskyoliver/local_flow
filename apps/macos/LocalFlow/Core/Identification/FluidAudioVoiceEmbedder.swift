import FluidAudio
import Foundation

/// Research R1: voice embeddings come from the provisioned diarization models
/// (WeSpeaker ResNet34-LM, 256-d) through FluidAudio's single-speaker offline pipeline.
/// The factory verifies the same pinned descriptor `FluidAudioDiarizerFactory` does,
/// loads from the local directory only and never calls a download path. The lifecycle
/// coordinator owns the returned runtime and is the only caller.
struct FluidAudioVoiceEmbedderFactory: Sendable {
  static let engine = IdentificationThresholds.wespeakerEngine

  let descriptor: LocalModelDescriptor
  var offlineMode: @Sendable () -> Bool = { ModelHub.offlineMode }
  var operatingSystem = ProcessInfo.processInfo.operatingSystemVersion

  /// The identity stored with every sample and run this embedder produces.
  static func identity(descriptor: ModelDescriptor?, manifestHash: String) -> VoiceModelIdentity {
    VoiceModelIdentity(
      engine: engine, modelID: descriptor?.modelID ?? FluidAudioDiarizerFactory.modelID,
      modelRevision: descriptor?.sourceRevision ?? FluidAudioDiarizerFactory.revision,
      manifestHash: manifestHash, dimension: VoiceEmbedding.dimension)
  }

  func makeRuntime() async throws -> any VoiceEmbeddingRuntime {
    guard offlineMode() else { throw IdentificationFailureCategory.modelUnavailable }
    // macOS 14 BNNS crash in Core ML predictions (FluidAudio #878).
    guard operatingSystem.majorVersion >= 15 else {
      throw IdentificationFailureCategory.osUnsupported
    }
    let pinned = descriptor.descriptor
    guard (try? pinned.validate()) != nil, pinned.modelID == FluidAudioDiarizerFactory.modelID,
      pinned.sourceRevision == FluidAudioDiarizerFactory.revision,
      pinned.sdkCompatibility == "0.15.7", pinned.effectiveCapability == .speakerDiarization,
      !pinned.automaticLanguage,
      descriptor.rootURL.lastPathComponent == FluidAudioDiarizerFactory.folderName
    else { throw IdentificationFailureCategory.modelUnavailable }
    let models: OfflineDiarizerModels
    do {
      // Never `prepareModels()`: it purges and re-downloads after a failed load.
      models = try await OfflineDiarizerModels.load(
        from: descriptor.rootURL.deletingLastPathComponent())
    } catch is CancellationError {
      throw CancellationError()
    } catch let error as DownloadError {
      if case .modelMissing = error { throw IdentificationFailureCategory.modelUnavailable }
      throw IdentificationFailureCategory.modelLoadFailure
    } catch {
      throw IdentificationFailureCategory.modelLoadFailure
    }
    try Task.checkCancellation()
    return FluidAudioVoiceEmbedder(models: models)
  }
}

/// One single-speaker `OfflineDiarizerManager` over the loaded models. Unchecked:
/// `ModelLifecycleCoordinator.embed` admits one region at a time.
final class FluidAudioVoiceEmbedder: VoiceEmbeddingRuntime, @unchecked Sendable {
  private let manager: OfflineDiarizerManager

  init(models: OfflineDiarizerModels) {
    var config = OfflineDiarizerConfig(exposeChunkEmbeddings: true)
    config.postProcessing.exclusiveSegments = false
    config.clustering.numSpeakers = 1
    manager = OfflineDiarizerManager(config: config)
    manager.initialize(models: models)
  }

  func embed(_ request: VoiceRegionRequest) async throws -> VoiceEmbedding {
    let result: DiarizationResult
    do {
      result = try await manager.process(audio: request.samples)
    } catch OfflineDiarizationError.noSpeechDetected {
      throw VoiceEmbeddingFailure.noSpeech
    }
    guard let embedding = Self.reduce(result) else { throw VoiceEmbeddingFailure.noSpeech }
    return embedding
  }

  /// The duration-weighted, L2-normalized mean of the dominant cluster's chunk
  /// embeddings; the cluster with the most segment time wins. Nil when there is no
  /// speech or no embedding.
  static func reduce(_ result: DiarizationResult) -> VoiceEmbedding? {
    var speech: [String: Double] = [:]
    for segment in result.segments {
      let length = Double(segment.endTimeSeconds) - Double(segment.startTimeSeconds)
      if length.isFinite, length > 0 { speech[segment.speakerId, default: 0] += length }
    }
    guard
      let dominant = speech.max(by: { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key }
      )
    else { return nil }
    var sum = [Float](repeating: 0, count: VoiceEmbedding.dimension)
    var weight: Float = 0
    for chunk in result.chunkEmbeddings ?? [] where chunk.speakerId == dominant.key {
      guard chunk.embedding256.count == VoiceEmbedding.dimension else { continue }
      let length = Float(max(0, chunk.endTimeSeconds - chunk.startTimeSeconds))
      let factor = length > 0 ? length : 1
      for index in sum.indices { sum[index] += chunk.embedding256[index] * factor }
      weight += factor
    }
    guard weight > 0 else { return nil }
    let norm = sum.reduce(Float(0)) { $0 + $1 * $1 }.squareRoot()
    guard norm.isFinite, norm > 0 else { return nil }
    let embedding = VoiceEmbedding(vector: sum.map { $0 / norm }, speechSeconds: dominant.value)
    return embedding.isValid ? embedding : nil
  }

  func shutdown() async {
    // The manager holds only Core ML models; dropping the runtime releases them.
  }
}
