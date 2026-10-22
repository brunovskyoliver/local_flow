import CryptoKit
import XCTest

@testable import LocalFlowCore
@testable import LocalFlowSpeech

/// Parakeet Ultra as an optional pinned model (audit fix 01): the bundled manifests, the
/// factory's version branch, switching through the lifecycle and the recorded identity.
/// No test here loads or downloads model weights.
final class SpeechModelSelectionTests: XCTestCase {
  private var roots: [URL] = []

  override func tearDownWithError() throws {
    for root in roots { try? FileManager.default.removeItem(at: root) }
  }

  private static let modelsDirectory = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("apps/macos/LocalFlow/Resources/Models", isDirectory: true)

  private func bundled(_ choice: SpeechModelChoice) throws -> (ModelDescriptor, Data) {
    let data = try Data(
      contentsOf: Self.modelsDirectory.appendingPathComponent(choice.resourceName + ".json"))
    return (try JSONDecoder().decode(ModelDescriptor.self, from: data), data)
  }

  private func root() throws -> URL {
    // realpath: the provisioner walks from / with O_NOFOLLOW and /var is a symlink, which
    // Foundation's resolvingSymlinksInPath maps back to.
    let temporary = try XCTUnwrap(realpath(NSTemporaryDirectory(), nil))
    defer { free(temporary) }
    let url = URL(fileURLWithPath: String(cString: temporary), isDirectory: true)
      .appendingPathComponent("speech-selection-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    roots.append(url)
    return url
  }

  // MARK: Descriptors

  func testBundledManifestsAreCompleteAndPinTheirChoice() throws {
    for choice in SpeechModelChoice.allCases {
      let (descriptor, _) = try bundled(choice)
      XCTAssertNoThrow(try descriptor.validate(), choice.rawValue)
      XCTAssertTrue(descriptor.complete)
      XCTAssertEqual(descriptor.license, "cc-by-4.0")
      XCTAssertEqual(SpeechModelChoice(pinned: descriptor), choice)
    }
  }

  func testUltraManifestListsTheV3LayoutWithTheV3Tokenizer() throws {
    let (ultra, _) = try bundled(.parakeetUltra)
    let (v3, _) = try bundled(.parakeetV3)
    XCTAssertEqual(ultra.modelID, "FluidInference/parakeet-ultra-coreml")
    XCTAssertEqual(ultra.sourceRevision, "95eaa59a39d4394f047a4dc5cce480388a60d1b6")
    XCTAssertEqual(ultra.sdkCompatibility, "0.17.7")
    XCTAssertTrue(ultra.automaticLanguage)
    let paths = Set(ultra.files.map(\.path))
    for component in ["Preprocessor", "Encoder", "Decoder", "JointDecisionv3"] {
      for file in ["coremldata.bin", "model.mil", "weights/weight.bin"] {
        XCTAssertTrue(paths.contains("\(component).mlmodelc/\(file)"), "\(component)/\(file)")
      }
    }
    // Byte-identical vocabulary: Ultra keeps v3's tokenizer, so the booster's text side holds.
    let vocabulary = { (d: ModelDescriptor) in d.files.first { $0.path == "parakeet_vocab.json" } }
    XCTAssertEqual(vocabulary(ultra), vocabulary(v3))
    XCTAssertEqual(
      ultra.files.first { $0.path == "Encoder.mlmodelc/weights/weight.bin" }?.size, 594_211_328)
    XCTAssertEqual(ultra.files.reduce(0) { $0 + $1.size }, 632_162_964)
  }

  func testOnlyExactPinsSelectAModel() throws {
    let (ultra, _) = try bundled(.parakeetUltra)
    func altered(
      modelID: String? = nil, revision: String? = nil, sdk: String? = nil, automatic: Bool = true
    ) -> ModelDescriptor {
      ModelDescriptor(
        schemaVersion: 1, modelID: modelID ?? ultra.modelID,
        sourceRevision: revision ?? ultra.sourceRevision,
        sdkCompatibility: sdk ?? ultra.sdkCompatibility, automaticLanguage: automatic,
        license: ultra.license, files: ultra.files, complete: true)
    }
    XCTAssertEqual(SpeechModelChoice(pinned: altered()), .parakeetUltra)
    XCTAssertNil(SpeechModelChoice(pinned: altered(revision: String(repeating: "a", count: 40))))
    XCTAssertNil(SpeechModelChoice(pinned: altered(sdk: "0.15.7")))
    XCTAssertNil(
      SpeechModelChoice(pinned: altered(modelID: "FluidInference/parakeet-redux-coreml")))
    XCTAssertNil(SpeechModelChoice(pinned: altered(automatic: false)))
  }

  func testStoredPreferenceDefaultsToV3() {
    XCTAssertEqual(SpeechModelChoice(storedValue: nil), .parakeetV3)
    XCTAssertEqual(SpeechModelChoice(storedValue: "parakeet-redux"), .parakeetV3)
    XCTAssertEqual(SpeechModelChoice(storedValue: "parakeet-ultra"), .parakeetUltra)
    XCTAssertEqual(SpeechModelChoice.defaultChoice, .parakeetV3)
  }

  // MARK: Factory

  /// Both pins pass the version branch and reach the direct local load, which fails on an
  /// empty directory; a near miss stops at the pin check before touching any file.
  func testFactoryAcceptsBothPinsAndLoadsOnlyFromTheGivenDirectory() async throws {
    let empty = try root()
    for choice in SpeechModelChoice.allCases {
      let (descriptor, _) = try bundled(choice)
      let factory = FluidAudioEngineFactory(
        descriptor: LocalModelDescriptor(descriptor: descriptor, rootURL: empty),
        englishWords: { _ in [] })
      do {
        _ = try await factory.makeRuntime()
        XCTFail("loaded \(choice) from an empty directory")
      } catch let failure as DictationFailure {
        XCTAssertNotEqual(failure, .modelUnavailable, "\(choice) failed its pin check")
      } catch {}
    }
    let (ultra, _) = try bundled(.parakeetUltra)
    let nearMiss = ModelDescriptor(
      schemaVersion: 1, modelID: ultra.modelID, sourceRevision: ultra.sourceRevision,
      sdkCompatibility: "0.15.7", automaticLanguage: true, license: ultra.license,
      files: ultra.files, complete: true)
    do {
      _ = try await FluidAudioEngineFactory(
        descriptor: LocalModelDescriptor(descriptor: nearMiss, rootURL: empty),
        englishWords: { _ in [] }
      ).makeRuntime()
      XCTFail("loaded a descriptor with the wrong SDK pin")
    } catch {
      XCTAssertEqual(error as? DictationFailure, .modelUnavailable)
    }
  }

  // MARK: Switching

  private actor Events {
    private(set) var log: [String] = []
    func append(_ event: String) { log.append(event) }
  }

  private struct FakeRuntime: TranscriptionRuntime {
    let choice: SpeechModelChoice
    let events: Events
    func transcribe(_ samples: [Float]) async throws -> TranscriptionWindow {
      .init(text: choice.rawValue, tokens: [])
    }
    func shutdown() async { await events.append("release \(choice.rawValue)") }
  }

  /// A tiny installed model whose manifest carries `choice`'s exact pin.
  private func installedModel(_ choice: SpeechModelChoice, under base: URL) async throws
    -> SpeechModelSelection.Model
  {
    let source = base.appendingPathComponent("source-\(choice.rawValue)", isDirectory: true)
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    let bytes = Data(choice.rawValue.utf8)
    try bytes.write(to: source.appendingPathComponent("weights.bin"))
    let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    let descriptor = ModelDescriptor(
      schemaVersion: 1, modelID: choice.modelID, sourceRevision: choice.sourceRevision,
      sdkCompatibility: choice.manifestSDK, automaticLanguage: true, license: "cc-by-4.0",
      files: [.init(path: "weights.bin", size: Int64(bytes.count), sha256: digest)],
      complete: true)
    let rootURL = base.appendingPathComponent(choice.resourceName, isDirectory: true)
    let provisioner = ModelProvisioner(descriptor: descriptor, rootURL: rootURL)
    _ = try await provisioner.install(from: source)
    let manifest = try JSONEncoder().encode(descriptor)
    return .init(
      choice: choice, descriptor: descriptor, provisioner: provisioner, rootURL: rootURL,
      identity: try TranscriptionPipelineIdentity(
        descriptor: descriptor, manifestHash: TranscriptionQualityDetail.hash(manifest),
        build: "test", languageHint: FluidAudioRuntime.languageHint))
  }

  func testSwitchingReleasesTheResidentModelAndProvenanceFollows() async throws {
    let base = try root()
    let selection = try SpeechModelSelection(
      models: [
        try await installedModel(.parakeetV3, under: base),
        try await installedModel(.parakeetUltra, under: base),
      ], selected: .parakeetV3)
    let events = Events()
    let lifecycle = ModelLifecycleCoordinator {
      let model = selection.current
      _ = try await model.provisioner.verifiedLocalDescriptor()
      await events.append("load \(model.choice.rawValue)")
      return FakeRuntime(choice: model.choice, events: events)
    }
    let transcriptIdentity = TranscriptionPipelineIdentity(following: selection.identity)
    XCTAssertEqual(
      transcriptIdentity.provenance(sampleCount: 0, recognition: 0, assembly: 0).modelID,
      SpeechModelChoice.parakeetV3.modelID)

    try await lifecycle.loadIfIdle()
    var snapshot = await lifecycle.snapshot()
    XCTAssertTrue(snapshot.loaded)

    // A held lease blocks the switch; nothing changes.
    let lease = try await lifecycle.acquire(session: UUID())
    do {
      try await selection.select(.parakeetUltra, lifecycle: lifecycle)
      XCTFail("switched while a lease was held")
    } catch {
      XCTAssertEqual(error as? DictationFailure, .busy)
    }
    XCTAssertEqual(selection.currentChoice, .parakeetV3)
    try await lifecycle.finish(lease)

    try await selection.select(.parakeetUltra, lifecycle: lifecycle)
    XCTAssertEqual(selection.currentChoice, .parakeetUltra)
    snapshot = await lifecycle.snapshot()
    XCTAssertFalse(snapshot.loaded, "the previous model must not stay resident")
    var log = await events.log
    XCTAssertEqual(log, ["load parakeet-v3", "release parakeet-v3"])

    let provenance = transcriptIdentity.provenance(sampleCount: 16_000, recognition: 0, assembly: 0)
    XCTAssertEqual(provenance.modelID, "FluidInference/parakeet-ultra-coreml")
    XCTAssertEqual(provenance.modelRevision, "95eaa59a39d4394f047a4dc5cce480388a60d1b6")
    XCTAssertEqual(provenance.sdkVersion, FluidAudioSDK.version)
    XCTAssertEqual(provenance.artifactHashes.keys.sorted(), ["weights.bin"])
    XCTAssertNoThrow(try provenance.validate())

    let next = try await lifecycle.acquire(session: UUID())
    let window = try await lifecycle.transcribe(next, samples: [Float](repeating: 0, count: 16_000))
    XCTAssertEqual(window.text, "parakeet-ultra")
    try await lifecycle.finish(next)

    // Rollback: back to v3 the same way.
    try await selection.select(.parakeetV3, lifecycle: lifecycle)
    log = await events.log
    XCTAssertEqual(
      log,
      ["load parakeet-v3", "release parakeet-v3", "load parakeet-ultra", "release parakeet-ultra"])
    XCTAssertEqual(
      transcriptIdentity.provenance(sampleCount: 0, recognition: 0, assembly: 0).modelID,
      SpeechModelChoice.parakeetV3.modelID)
  }

  func testSwitchingToAModelThatIsNotInstalledKeepsTheCurrentOne() async throws {
    let base = try root()
    let v3 = try await installedModel(.parakeetV3, under: base)
    let ultra = try await installedModel(.parakeetUltra, under: base)
    try FileManager.default.removeItem(at: ultra.rootURL)
    let selection = try SpeechModelSelection(models: [v3, ultra], selected: .parakeetV3)
    let lifecycle = ModelLifecycleCoordinator { throw DictationFailure.modelUnavailable }
    do {
      try await selection.select(.parakeetUltra, lifecycle: lifecycle)
      XCTFail("selected a model with no installed files")
    } catch {}
    XCTAssertEqual(selection.currentChoice, .parakeetV3)
    XCTAssertEqual(
      selection.identity.current.provenance(sampleCount: 0, recognition: 0, assembly: 0).modelID,
      SpeechModelChoice.parakeetV3.modelID)
  }

  func testAStoredChoiceWithoutAManifestFallsBackToV3() async throws {
    let base = try root()
    let selection = try SpeechModelSelection(
      models: [try await installedModel(.parakeetV3, under: base)], selected: .parakeetUltra)
    XCTAssertEqual(selection.currentChoice, .parakeetV3)
    XCTAssertThrowsError(try SpeechModelSelection(models: [], selected: .parakeetV3))
  }
}
