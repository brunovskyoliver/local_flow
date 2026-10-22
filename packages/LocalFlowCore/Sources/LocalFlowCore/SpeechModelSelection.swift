import Foundation
import LocalFlowSpeech
import os

/// The bundled local speech models and the one dictation and live previews use. The
/// lifecycle factory reads `current` when it prepares a runtime; `select` changes it only
/// inside the lifecycle's install gate, which first releases the resident runtime. One
/// speech model is resident at a time, and a lease's provenance names the model it loaded.
public final class SpeechModelSelection: Sendable {
  public struct Model: Sendable {
    public let choice: SpeechModelChoice
    public let descriptor: ModelDescriptor
    public let provisioner: ModelProvisioner
    public let rootURL: URL
    /// Provenance for transcripts this model produces (model ID, revision, manifest and
    /// artifact hashes, linked SDK).
    public let identity: TranscriptionPipelineIdentity

    public init(
      choice: SpeechModelChoice, descriptor: ModelDescriptor, provisioner: ModelProvisioner,
      rootURL: URL, identity: TranscriptionPipelineIdentity
    ) {
      self.choice = choice
      self.descriptor = descriptor
      self.provisioner = provisioner
      self.rootURL = rootURL
      self.identity = identity
    }

    public var downloadBytes: Int64 {
      descriptor.files.reduce(0) { $0 + max(0, min($1.size, ModelProvisioner.maxPackageBytes)) }
    }
  }

  public let models: [SpeechModelChoice: Model]
  private let active: OSAllocatedUnfairLock<SpeechModelChoice>
  /// Every transcriber and meeting stage follows this source.
  public let identity: SpeechModelIdentitySource

  /// `models` must hold the default choice; a stored choice whose manifest is missing
  /// falls back to it.
  public init(models: [Model], selected: SpeechModelChoice) throws {
    let byChoice = Dictionary(
      models.map { ($0.choice, $0) }, uniquingKeysWith: { first, _ in first })
    guard let fallback = byChoice[.defaultChoice] else { throw DictationFailure.modelUnavailable }
    let initial = byChoice[selected] ?? fallback
    self.models = byChoice
    active = OSAllocatedUnfairLock(initialState: initial.choice)
    identity = SpeechModelIdentitySource(initial.identity)
  }

  public var currentChoice: SpeechModelChoice { active.withLock { $0 } }
  public var current: Model { models[currentChoice]! }

  /// Verifies `choice`'s installed files, then switches inside `lifecycle.installModel`:
  /// the resident runtime (if any) is released first, and no lease can start until the
  /// switch is recorded. Throws `busy` while any lease is held.
  public func select(_ choice: SpeechModelChoice, lifecycle: ModelLifecycleCoordinator)
    async throws
  {
    guard let model = models[choice] else { throw DictationFailure.modelUnavailable }
    try await lifecycle.installModel {
      _ = try await model.provisioner.verifiedLocalDescriptor()
      self.active.withLock { $0 = choice }
      self.identity.replace(with: model.identity)
    }
  }
}
