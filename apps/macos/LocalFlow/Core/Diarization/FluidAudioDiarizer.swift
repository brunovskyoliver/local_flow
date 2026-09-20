import FluidAudio
import Foundation

/// Builds the pinned offline diarizer from a verified local model only. The lifecycle
/// coordinator owns the returned runtime and is the only caller.
struct FluidAudioDiarizerFactory: Sendable {
  static let modelID = "FluidInference/speaker-diarization-coreml"
  static let revision = "1ed7a662fdc7109e36d822db793ee6eebdaf8594"
  /// ModelHub appends `Repo.diarizer.folderName` (the repository name without
  /// "-coreml") to the directory it is given.
  static let folderName = "speaker-diarization"

  let descriptor: LocalModelDescriptor
  var offlineMode: @Sendable () -> Bool = { ModelHub.offlineMode }
  var operatingSystem = ProcessInfo.processInfo.operatingSystemVersion

  /// Set once at launch (AppServices) so no FluidAudio path can reach the network.
  static func enableOfflineMode() { ModelHub.offlineMode = true }

  /// `<models>/speaker-diarization-offline/speaker-diarization`: the provisioner owns the
  /// leaf, and the loader is given its parent.
  static func installRoot(models: URL) -> URL {
    models.appendingPathComponent("speaker-diarization-offline", isDirectory: true)
      .appendingPathComponent(folderName, isDirectory: true)
  }

  func makeRuntime() async throws -> any DiarizationRuntime {
    // Offline mode is what stops ModelHub from downloading or purging (research R2).
    guard offlineMode() else { throw DiarizationFailureCategory.modelUnavailable }
    // macOS 14 BNNS crash in Core ML predictions (FluidAudio #878).
    guard operatingSystem.majorVersion >= 15 else { throw DiarizationFailureCategory.osUnsupported }
    let pinned = descriptor.descriptor
    guard (try? pinned.validate()) != nil, pinned.modelID == Self.modelID,
      pinned.sourceRevision == Self.revision, pinned.sdkCompatibility == "0.15.7",
      pinned.effectiveCapability == .speakerDiarization, !pinned.automaticLanguage,
      descriptor.rootURL.lastPathComponent == Self.folderName
    else { throw DiarizationFailureCategory.modelUnavailable }
    let models: OfflineDiarizerModels
    do {
      // Never `prepareModels()`: it purges and re-downloads after a failed load.
      models = try await OfflineDiarizerModels.load(
        from: descriptor.rootURL.deletingLastPathComponent())
    } catch is CancellationError {
      throw CancellationError()
    } catch let error as DownloadError {
      if case .modelMissing = error { throw DiarizationFailureCategory.modelUnavailable }
      throw DiarizationFailureCategory.modelLoadFailure
    } catch {
      throw DiarizationFailureCategory.modelLoadFailure
    }
    try Task.checkCancellation()
    return FluidAudioDiarizer(models: models)
  }
}

/// `OfflineDiarizerManager` fixes its config at construction, so the one-speaker
/// microphone constraint gets its own manager over the same loaded models.
/// Unchecked: `ModelLifecycleCoordinator.diarize` admits one window at a time.
final class FluidAudioDiarizer: DiarizationRuntime, @unchecked Sendable {
  // ponytail: two managers share one OfflineDiarizerModels; no second model load.
  private let unconstrained: OfflineDiarizerManager
  private let singleSpeaker: OfflineDiarizerManager

  init(models: OfflineDiarizerModels) {
    var config = OfflineDiarizerConfig(exposeChunkEmbeddings: true)
    config.postProcessing.exclusiveSegments = false
    unconstrained = OfflineDiarizerManager(config: config)
    config.clustering.numSpeakers = 1
    singleSpeaker = OfflineDiarizerManager(config: config)
    unconstrained.initialize(models: models)
    singleSpeaker.initialize(models: models)
  }

  func diarize(_ request: DiarizationWindowRequest) async throws -> DiarizationWindowResult {
    guard request.numSpeakers == nil || request.numSpeakers == 1 else {
      throw DictationFailure.invalidAudio
    }
    let manager = request.numSpeakers == 1 ? singleSpeaker : unconstrained
    do {
      return try Self.map(try await manager.process(audio: request.samples))
    } catch OfflineDiarizationError.noSpeechDetected {
      return .empty
    }
  }

  /// "S1…" become clusters 0…; centroids are the L2-normalized means of each cluster's
  /// chunk embeddings. A cluster without chunk embeddings gets no centroid.
  static func map(_ result: DiarizationResult) throws -> DiarizationWindowResult {
    guard result.segments.count <= DiarizationWindowResult.maxTurns else {
      throw DictationFailure.invalidResult
    }
    let turns = try result.segments.compactMap { segment -> DiarizationWindowResult.Turn? in
      guard let cluster = cluster(segment.speakerId) else { throw DictationFailure.invalidResult }
      let start = max(0, Double(segment.startTimeSeconds))
      let end = Double(segment.endTimeSeconds)
      guard start.isFinite, end.isFinite else { throw DictationFailure.invalidResult }
      // An empty span carries no speech; dropping it is not a lost turn.
      guard end > start else { return nil }
      return .init(
        cluster: cluster, startSeconds: start, endSeconds: end,
        quality: segment.qualityScore.isFinite ? segment.qualityScore : nil)
    }
    var sums: [Int: [Float]] = [:]
    for chunk in result.chunkEmbeddings ?? [] {
      guard let cluster = cluster(chunk.speakerId), !chunk.embedding256.isEmpty else { continue }
      guard var sum = sums[cluster] else {
        sums[cluster] = chunk.embedding256
        continue
      }
      guard sum.count == chunk.embedding256.count else { throw DictationFailure.invalidResult }
      for index in sum.indices { sum[index] += chunk.embedding256[index] }
      sums[cluster] = sum
    }
    let used = Set(turns.map(\.cluster))
    var centroids: [Int: [Float]] = [:]
    for (cluster, sum) in sums where used.contains(cluster) {
      let norm = sum.reduce(0) { $0 + $1 * $1 }.squareRoot()
      guard norm.isFinite, norm > 0 else { continue }
      centroids[cluster] = sum.map { $0 / norm }
    }
    let mapped = DiarizationWindowResult(turns: turns, centroids: centroids)
    guard mapped.isValid else { throw DictationFailure.invalidResult }
    return mapped
  }

  static func cluster(_ speakerID: String) -> Int? {
    guard speakerID.hasPrefix("S"), let value = Int(speakerID.dropFirst()), value >= 1,
      value <= 10_000
    else { return nil }
    return value - 1
  }

  func shutdown() async {
    // The managers hold only Core ML models; dropping the runtime releases them.
  }
}
