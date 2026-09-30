import Foundation
import LocalFlowSpeech

/// Pinned application/model identity, captured before dictation. The lifecycle factory
/// verifies these same model artifacts before granting a lease.
public struct TranscriptionPipelineIdentity: Sendable {
  private var windowSamples = 239_360
  private var engine = "unrecorded_runtime"
  private var descriptor: ModelDescriptor?
  private var manifestHash: String?
  private var build: String?
  /// What the runtime was told about language; nil means automatic with no hint.
  private var languageHint: String?
  private let operatingSystem = ProcessInfo.processInfo.operatingSystemVersionString
  private let foldingRuntime =
    "Foundation-on-" + ProcessInfo.processInfo.operatingSystemVersionString

  /// Feature 014: the server worker's model, from `dictation_accepted`. Its manifest hash
  /// stands for the artifact hashes the app would list for its own descriptor. Values that
  /// would not validate are recorded as unavailable rather than failing the transcript.
  private var remoteSDK: String?
  private var remoteModelID: String?
  private var remoteRevision: String?

  public init() {}

  public init(remote model: RemoteModelIdentity, build: String?) {
    func valid(_ value: String) -> String? {
      (try? TranscriptionQualityDetail.validateID(value)) == nil ? nil : value
    }
    engine = valid(model.engine) ?? "remote_worker"
    remoteSDK = valid(model.sdk)
    remoteModelID = valid(model.modelID)
    remoteRevision = valid(model.modelRevision)
    manifestHash = TranscriptionQualityDetail.isHash(model.manifestHash) ? model.manifestHash : nil
    self.build = build
  }

  var recordedBuild: String? { build }

  public init(
    descriptor: ModelDescriptor, manifestHash: String, build: String?,
    engine: String = "FluidAudio", windowSamples: Int = 239_360, languageHint: String? = nil
  ) throws {
    try descriptor.validate()
    self.engine = engine
    self.languageHint = languageHint
    self.windowSamples = windowSamples
    self.descriptor = descriptor
    self.manifestHash = manifestHash
    self.build = build
    // Reject an identity that cannot fit the immutable detail before recording starts.
    try provenance(sampleCount: 0, recognition: 0, assembly: 0).validate()
  }

  public func provenance(sampleCount: Int, recognition: Double, assembly: Double)
    -> TranscriptionProvenance
  {
    var missing: [TranscriptionProvenance.Unavailable] = [
      .init(field: "dirty", reason: .notRecorded),
      .init(field: "normalization_duration", reason: .notRecorded),
    ]
    if descriptor == nil {
      let remoteFields = [
        ("sdk_version", remoteSDK), ("model_id", remoteModelID),
        ("model_revision", remoteRevision), ("artifact_hashes", nil),
      ]
      for (field, value) in remoteFields where value == nil {
        missing.append(.init(field: field, reason: .notRecorded))
      }
    }
    if manifestHash == nil {
      missing.append(.init(field: "model_manifest_hash", reason: .notRecorded))
    }
    if build == nil { missing.append(.init(field: "build", reason: .notRecorded)) }
    return TranscriptionProvenance(
      engine: engine, sdkVersion: descriptor?.sdkCompatibility ?? remoteSDK,
      modelID: descriptor?.modelID ?? remoteModelID,
      modelRevision: descriptor?.sourceRevision ?? remoteRevision,
      modelManifestHash: manifestHash,
      artifactHashes: Dictionary(
        uniqueKeysWithValues: (descriptor?.files ?? []).map { ($0.path, $0.sha256) }),
      build: build, dirty: nil, languageHint: languageHint,
      automaticLanguage: languageHint == nil,
      sampleRate: 16_000, channels: 1, inputSamples: sampleCount,
      inputDurationSeconds: Double(sampleCount) / 16_000, inputSampleFormat: "float32_pcm",
      windowSamples: windowSamples, overlapSamples: 0, strideSamples: windowSamples,
      minimumPaddedSamples: 4_800,
      operatingSystem: operatingSystem, foldingRuntime: foldingRuntime,
      stageDurations: ["recognition": recognition, "assembly": assembly],
      unavailableMetadata: missing)
  }
}
