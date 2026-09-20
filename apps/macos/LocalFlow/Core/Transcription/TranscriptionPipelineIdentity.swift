import Foundation

/// Pinned application/model identity, captured before dictation. The lifecycle factory
/// verifies these same model artifacts before granting a lease.
struct TranscriptionPipelineIdentity: Sendable {
  private var windowSamples = 239_360
  private var engine = "unrecorded_runtime"
  private var descriptor: ModelDescriptor?
  private var manifestHash: String?
  private var build: String?
  private let operatingSystem = ProcessInfo.processInfo.operatingSystemVersionString
  private let foldingRuntime =
    "Foundation-on-" + ProcessInfo.processInfo.operatingSystemVersionString

  init() {}

  init(
    descriptor: ModelDescriptor, manifestHash: String, build: String?,
    engine: String = "FluidAudio", windowSamples: Int = 239_360
  ) throws {
    try descriptor.validate()
    self.engine = engine
    self.windowSamples = windowSamples
    self.descriptor = descriptor
    self.manifestHash = manifestHash
    self.build = build
    // Reject an identity that cannot fit the immutable detail before recording starts.
    try provenance(sampleCount: 0, recognition: 0, assembly: 0).validate()
  }

  func provenance(sampleCount: Int, recognition: Double, assembly: Double)
    -> TranscriptionProvenance
  {
    var missing: [TranscriptionProvenance.Unavailable] = [
      .init(field: "dirty", reason: .notRecorded),
      .init(field: "normalization_duration", reason: .notRecorded),
    ]
    if descriptor == nil {
      for field in ["sdk_version", "model_id", "model_revision", "artifact_hashes"] {
        missing.append(.init(field: field, reason: .notRecorded))
      }
    }
    if manifestHash == nil {
      missing.append(.init(field: "model_manifest_hash", reason: .notRecorded))
    }
    if build == nil { missing.append(.init(field: "build", reason: .notRecorded)) }
    return TranscriptionProvenance(
      engine: engine, sdkVersion: descriptor?.sdkCompatibility, modelID: descriptor?.modelID,
      modelRevision: descriptor?.sourceRevision, modelManifestHash: manifestHash,
      artifactHashes: Dictionary(
        uniqueKeysWithValues: (descriptor?.files ?? []).map { ($0.path, $0.sha256) }),
      build: build, dirty: nil, languageHint: nil, automaticLanguage: true,
      sampleRate: 16_000, channels: 1, inputSamples: sampleCount,
      inputDurationSeconds: Double(sampleCount) / 16_000, inputSampleFormat: "float32_pcm",
      windowSamples: windowSamples, overlapSamples: 0, strideSamples: windowSamples,
      minimumPaddedSamples: 4_800,
      operatingSystem: operatingSystem, foldingRuntime: foldingRuntime,
      stageDurations: ["recognition": recognition, "assembly": assembly],
      unavailableMetadata: missing)
  }
}
