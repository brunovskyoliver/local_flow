import Foundation
import LocalFlowCore
import LocalFlowSpeech
import os

/// Everything the phone app owns, built once at launch: History and the Dictionary in the
/// app container, the single model coordinator, and the model and orphan state.
@MainActor
final class PhoneServices {
  static let spoolBytes = 19_200_000

  let paths: LocalFlowPaths
  let history: TranscriptionStore
  let vocabulary: VocabularyStore
  let dictations: PhoneDictationStore
  let lifecycle: ModelLifecycleCoordinator
  let model: PhoneModelState
  let pipeline: PhoneDictationPipeline
  let orphans: OrphanSpoolRecovery
  let keepReady: KeepReady

  init(applicationSupport: URL, bundle: Bundle = .main) throws {
    paths = LocalFlowPaths(applicationSupport: try Self.physical(applicationSupport))
    let root = paths.database.deletingLastPathComponent()
    // New files inherit the folder's protection, so History stays writable while the
    // phone is locked after first unlock (research R5).
    try FileManager.default.createDirectory(
      at: root, withIntermediateDirectories: true,
      attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
    history = try TranscriptionStore(path: paths.database.path)
    try PhoneMigrations.migrator().migrate(history.database)
    vocabulary = VocabularyStore(history: history)
    dictations = PhoneDictationStore(history: history)

    let speechData = try Self.descriptorData("parakeet-v3", bundle: bundle)
    let speechDescriptor = try JSONDecoder().decode(ModelDescriptor.self, from: speechData)
    let modelsBase = paths.models
    let speechRoot = paths.models.appendingPathComponent("parakeet-v3", isDirectory: true)
    let boostRoot = paths.models.appendingPathComponent("parakeet-ctc-110m", isDirectory: true)
    let speech = ModelProvisioner(
      descriptor: speechDescriptor, rootURL: speechRoot, trustedBase: modelsBase)
    let boostDescriptor = (try? Self.descriptorData("parakeet-ctc-110m", bundle: bundle))
      .flatMap { try? JSONDecoder().decode(ModelDescriptor.self, from: $0) }
    let boost = boostDescriptor.map {
      ModelProvisioner(descriptor: $0, rootURL: boostRoot, trustedBase: modelsBase)
    }
    try FileManager.default.createDirectory(at: paths.models, withIntermediateDirectories: true)
    model = PhoneModelState(
      speech: speech, boost: boost,
      transport: ResumableModelDownloadTransport(
        resumeDirectory: paths.models.appendingPathComponent(".staging", isDirectory: true)),
      directories: [speechRoot, boostRoot],
      descriptors: [speechDescriptor] + (boostDescriptor.map { [$0] } ?? []))

    let log = Logger(subsystem: "org.localflow.LocalFlowPhone", category: "model")
    lifecycle = ModelLifecycleCoordinator(
      observe: { state, _, duration in
        if duration == 0 {
          log.notice("Model lifecycle: \(String(describing: state), privacy: .public)")
        }
      },
      factory: {
        let local = try await speech.verifiedLocalDescriptor()
        // The booster is optional: unverified means this load dictates without it.
        let boostModel = try? await boost?.verifiedLocalDescriptor()
        return try await FluidAudioEngineFactory(descriptor: local, boostModel: boostModel)
          .makeRuntime()
      })
    let identity = try TranscriptionPipelineIdentity(
      descriptor: speechDescriptor, manifestHash: TranscriptionQualityDetail.hash(speechData),
      build: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
      languageHint: FluidAudioRuntime.languageHint)
    pipeline = PhoneDictationPipeline(
      lifecycle: lifecycle,
      transcriber: WindowedTranscriber(lifecycle: lifecycle, identity: identity),
      vocabulary: vocabulary)
    orphans = OrphanSpoolRecovery(root: paths.temporaryAudio)
    keepReady = KeepReady(lifecycle: lifecycle)
  }

  /// The container path with its symlinks resolved. iOS hands out `/var/mobile/...`, and
  /// `/var` is a symlink to `/private/var`; the resolved models folder is the provisioner's
  /// `trustedBase`, which must be symlink-free. `URL.resolvingSymlinksInPath` strips
  /// `/private` again, so this uses `realpath`.
  static func physical(_ url: URL) throws -> URL {
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    guard let resolved = realpath(url.path, nil) else { throw CocoaError(.fileNoSuchFile) }
    defer { free(resolved) }
    return URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
  }

  private static func descriptorData(_ name: String, bundle: Bundle) throws -> Data {
    guard let url = bundle.url(forResource: name, withExtension: "json") else {
      throw DictationFailure.modelUnavailable
    }
    return try Data(contentsOf: url)
  }
}

/// Keeps the model resident while a listening session or the Dictate screen needs it.
/// Leases stay per dictation; this only drives `setKeepLoaded` (plan "Model ownership").
@MainActor
final class KeepReady {
  enum Holder: Hashable { case session, dictateScreen }

  private(set) var holders: Set<Holder> = []
  private let lifecycle: ModelLifecycleCoordinator
  private var chain: Task<Void, Never>?

  init(lifecycle: ModelLifecycleCoordinator) {
    self.lifecycle = lifecycle
  }

  func hold(_ holder: Holder) {
    let first = holders.isEmpty
    holders.insert(holder)
    guard first else { return }
    enqueue { lifecycle in
      await lifecycle.setKeepLoaded(true)
      try? await lifecycle.loadIfIdle()
    }
  }

  /// Session end unloads at once; the Dictate screen leaves it to the 30 s cooldown.
  func release(_ holder: Holder, unloadNow: Bool) {
    guard holders.remove(holder) != nil, holders.isEmpty else { return }
    enqueue { lifecycle in
      await lifecycle.setKeepLoaded(false)
      if unloadNow { try? await lifecycle.unloadIfIdle() }
    }
  }

  /// Memory warning while not recording.
  func dropAll() {
    holders.removeAll()
    enqueue { lifecycle in
      await lifecycle.setKeepLoaded(false)
      try? await lifecycle.unloadIfIdle()
    }
  }

  /// Runs in call order, so a quick hold and release cannot reorder.
  private func enqueue(_ work: @escaping @Sendable (ModelLifecycleCoordinator) async -> Void) {
    let previous = chain
    let lifecycle = lifecycle
    chain = Task {
      await previous?.value
      await work(lifecycle)
    }
  }

  func settle() async { await chain?.value }
}
