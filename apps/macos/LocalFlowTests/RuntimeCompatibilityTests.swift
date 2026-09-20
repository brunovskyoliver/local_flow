import AVFoundation
import CryptoKit
import FluidAudio
import XCTest

@testable import LocalFlow

final class RuntimeCompatibilityTests: XCTestCase {
  /// Opt-in regression reproducer. Frozen speech stays local; assertions contain no transcript.
  func testOptInEmptyTailRecognition() async throws {
    let env = ProcessInfo.processInfo.environment
    guard let model = env["LOCALFLOW_EMPTY_TAIL_MODEL"],
      let corpus = env["LOCALFLOW_EMPTY_TAIL_CORPUS"]
    else { throw XCTSkip("Set the explicit empty-tail model and corpus variables.") }
    let corpusURL = URL(fileURLWithPath: corpus)
    let manifestURL = corpusURL.appendingPathComponent("manifest.json")
    XCTAssertEqual(
      try QualityArtifacts.hashFile(manifestURL),
      "10b9873c6b3f05fcb1b22a96a014a08c7a7f60566e8176ad2b799a1adbbd988b")
    let manifest = try QualityArtifacts.read(QualityManifest.self, from: manifestURL)
    let fixture = try XCTUnwrap(manifest.fixtures.first { $0.id == "public-da85b5ebc08e9db2f3ec" })
    let audioURL = try fixture.audioURL(root: corpusURL)
    XCTAssertEqual(try QualityArtifacts.hashFile(audioURL), fixture.sha256)
    let file = try AVAudioFile(
      forReading: audioURL, commonFormat: .pcmFormatFloat32, interleaved: false)
    XCTAssertEqual(file.length, 263_040)
    func samples(start: Int, count: Int) throws -> [Float] {
      file.framePosition = AVAudioFramePosition(start)
      let buffer = try XCTUnwrap(
        AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(count)))
      try file.read(into: buffer, frameCount: AVAudioFrameCount(count))
      XCTAssertEqual(Int(buffer.frameLength), count)
      return Array(
        UnsafeBufferPointer(start: try XCTUnwrap(buffer.floatChannelData?[0]), count: count))
    }
    let descriptorURL = try XCTUnwrap(
      Bundle.main.url(forResource: "parakeet-v3", withExtension: "json"))
    let descriptor = try JSONDecoder().decode(
      ModelDescriptor.self, from: Data(contentsOf: descriptorURL))
    let root = try makeSpoolRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let provisioner = ModelProvisioner(
      descriptor: descriptor, rootURL: root.appendingPathComponent("model"))
    _ = try await provisioner.install(from: URL(fileURLWithPath: model))
    let lifecycle = ModelLifecycleCoordinator {
      try await FluidAudioEngineFactory(descriptor: provisioner.verifiedLocalDescriptor())
        .makeRuntime()
    }
    let lease = try await lifecycle.acquire(session: UUID())
    do {
      if env["LOCALFLOW_EMPTY_TAIL_FRESH"] != "1" {
        let first = try await lifecycle.transcribe(
          lease, samples: samples(start: 0, count: 207_763))
        XCTAssertFalse(first.text.isEmpty)
      }
      let tail = try await lifecycle.transcribe(
        lease, samples: samples(start: 207_763, count: 55_277))
      XCTAssertFalse(tail.text.isEmpty, "Frozen speech-containing tail returned empty recognition")
      try await lifecycle.finish(lease)
      await lifecycle.releaseIfIdle(generation: lease.generation)
    } catch {
      await lifecycle.cancelAndJoin(lease)
      throw error
    }
  }

  /// Explicit network opt-in. Exercises the same bounded, hashed provisioner used by ASR while
  /// keeping the VAD capability in its own descriptor and installation directory.
  func testOptInProvisionVADModel() async throws {
    guard let path = ProcessInfo.processInfo.environment["LOCALFLOW_VAD_PROVISION_OUTPUT"],
      !path.isEmpty
    else { throw XCTSkip("Set TEST_RUNNER_LOCALFLOW_VAD_PROVISION_OUTPUT explicitly.") }
    let descriptorURL = try XCTUnwrap(
      Bundle.main.url(forResource: "silero-vad", withExtension: "json"))
    let descriptor = try JSONDecoder().decode(
      ModelDescriptor.self, from: Data(contentsOf: descriptorURL))
    XCTAssertEqual(descriptor.effectiveCapability, .voiceActivityDetection)
    let provisioner = ModelProvisioner(
      descriptor: descriptor, rootURL: URL(fileURLWithPath: path, isDirectory: true))
    let local = try await provisioner.download()
    XCTAssertEqual(local.descriptor, descriptor)
    _ = try await provisioner.verifiedLocalDescriptor()
  }

  func testOptInVADResourceProbe() async throws {
    let env = ProcessInfo.processInfo.environment
    let keys = [
      "LOCALFLOW_MODEL_PROBE_ROOT", "LOCALFLOW_VAD_MODEL_ROOT", "LOCALFLOW_VAD_RESOURCE_OUTPUT",
    ]
    guard keys.allSatisfy({ !(env[$0] ?? "").isEmpty }) else {
      throw XCTSkip("Set all three TEST_RUNNER_LOCALFLOW VAD resource variables.")
    }
    let asrURL = try XCTUnwrap(Bundle.main.url(forResource: "parakeet-v3", withExtension: "json"))
    let vadURL = try XCTUnwrap(Bundle.main.url(forResource: "silero-vad", withExtension: "json"))
    let asr = try JSONDecoder().decode(ModelDescriptor.self, from: Data(contentsOf: asrURL))
    let vad = try JSONDecoder().decode(ModelDescriptor.self, from: Data(contentsOf: vadURL))
    let root = try makeSpoolRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let asrProvisioner = ModelProvisioner(
      descriptor: asr, rootURL: root.appendingPathComponent("asr"))
    _ = try await asrProvisioner.install(from: URL(fileURLWithPath: env[keys[0]]!))
    let lifecycle = ModelLifecycleCoordinator {
      let local = try await asrProvisioner.verifiedLocalDescriptor()
      return try await FluidAudioEngineFactory(
        descriptor: local
      ).makeRuntime()
    }
    let baseline = try XCTUnwrap(ResourceRecorder.residentBytes())
    let lease = try await lifecycle.acquire(session: UUID())
    let asrActive = try XCTUnwrap(ResourceRecorder.residentBytes())
    let vadBase = root.appendingPathComponent("vad", isDirectory: true)
    let vadProvisioner = ModelProvisioner(
      descriptor: vad, rootURL: vadBase.appendingPathComponent("Models/silero-vad"))
    _ = try await vadProvisioner.install(from: URL(fileURLWithPath: env[keys[1]]!))
    ModelHub.offlineMode = true
    defer { ModelHub.offlineMode = false }
    let clock = ContinuousClock()
    let started = clock.now
    let manager = try await VadManager(config: VadConfig(), modelDirectory: vadBase)
    let loaded = clock.now
    _ = try await manager.process([Float](repeating: 0.001, count: VadManager.chunkSize))
    let exercised = try XCTUnwrap(ResourceRecorder.residentBytes())
    await lifecycle.cancelAndJoin(lease)
    let duration = started.duration(to: loaded).components
    let loadSeconds = Double(duration.seconds) + Double(duration.attoseconds) * 1e-18
    let body: [String: Any] = [
      "schema_version": 1,
      "vad_capability": vad.effectiveCapability.rawValue,
      "vad_model_id": vad.modelID,
      "vad_revision": vad.sourceRevision,
      "vad_descriptor_sha256": try QualityArtifacts.hashFile(vadURL),
      "vad_artifact_bytes": vad.files.reduce(Int64(0)) { $0 + $1.size },
      "baseline_rss_bytes": baseline,
      "asr_active_rss_bytes": asrActive,
      "asr_plus_vad_rss_bytes": exercised,
      "vad_rss_increment_while_asr_active_bytes": exercised >= asrActive
        ? exercised - asrActive : 0,
      "vad_load_seconds": loadSeconds,
      "offline_mode_during_load": true,
      "hardware": env["LOCALFLOW_QUALITY_HARDWARE"] ?? "unknown_not_supplied",
      "os": ProcessInfo.processInfo.operatingSystemVersionString,
    ]
    let data = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    try QualityArtifacts.write(
      data, to: URL(fileURLWithPath: env[keys[2]]!), replace: false,
      limit: QualityArtifacts.small)
  }

  /// Explicit opt-in only. Uses locally supplied weights and generated silence;
  /// ordinary repository checks must never load or download a speech model.
  func testOptInPinnedRuntimeLoadsDecodesAndReleases() async throws {
    guard let path = ProcessInfo.processInfo.environment["LOCALFLOW_MODEL_PROBE_ROOT"],
      !path.isEmpty
    else { throw XCTSkip("Set TEST_RUNNER_LOCALFLOW_MODEL_PROBE_ROOT to verified local assets.") }
    let source = URL(fileURLWithPath: path, isDirectory: true)
    let manifest = try XCTUnwrap(Bundle.main.url(forResource: "parakeet-v3", withExtension: "json"))
    let descriptor = try JSONDecoder().decode(
      ModelDescriptor.self, from: Data(contentsOf: manifest))
    let root = try makeSpoolRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let provisioner = ModelProvisioner(
      descriptor: descriptor, rootURL: root.appendingPathComponent("model"))
    _ = try await provisioner.install(from: source)
    let lifecycle = ModelLifecycleCoordinator {
      let local = try await provisioner.verifiedLocalDescriptor()
      return try await FluidAudioEngineFactory(descriptor: local).makeRuntime()
    }
    let clock = ContinuousClock()
    let started = clock.now
    let lease = try await lifecycle.acquire(session: UUID())
    let loaded = clock.now
    do {
      for count in [160, 239_360] {
        let result = try await lifecycle.transcribe(
          lease, samples: Array(repeating: 0, count: count))
        XCTAssertLessThanOrEqual(result.text.utf8.count, 65_536)
        XCTAssertTrue(
          result.tokens.allSatisfy { $0.start >= 0 && $0.end <= Double(count) / 16_000 })
      }
      try await lifecycle.finish(lease)
      await lifecycle.releaseIfIdle(generation: lease.generation)
    } catch {
      await lifecycle.cancelAndJoin(lease)
      throw error
    }
    let released = clock.now
    let state = await lifecycle.state
    XCTAssertEqual(state, .unloaded)
    let next = try await lifecycle.acquire(session: UUID())
    let inference = Task {
      try await lifecycle.transcribe(next, samples: Array(repeating: 0, count: 239_360))
    }
    await Task.yield()
    await lifecycle.cancelAndJoin(next)
    _ = await inference.result
    let finalState = await lifecycle.state
    XCTAssertEqual(finalState, .unloaded)
    let evidence =
      "Pinned local model verified; synthetic silence only. Load: \(started.duration(to: loaded)); decode and release: \(loaded.duration(to: released)). Reload/cancellation race joined. No RSS or speech-accuracy claim."
    let attachment = XCTAttachment(string: evidence)
    attachment.name = "Local runtime probe (no speech content)"
    attachment.lifetime = .keepAlways
    add(attachment)
  }

  private struct SpeechManifest: Decodable {
    let schemaVersion: Int
    let fixtures: [SpeechFixture]
  }

  private struct SpeechFixture: Decodable {
    let id: String
    let path: String
    let sha256: String
    let sampleRate: Int
    let numSamples: Int
  }

  private struct SpeechOutput: Encodable {
    let id: String
    let text: String
    let incomplete: Bool
    let samples: Int
    let windows: [RecordedSpeechWindow]
  }

  /// Licensed, locally supplied fixtures only. Speech text goes exclusively to
  /// the explicitly selected private JSON output, never test attachments/logs.
  func testOptInSpeechFixtures() async throws {
    let environment = ProcessInfo.processInfo.environment
    let keys = [
      "LOCALFLOW_MODEL_PROBE_ROOT", "LOCALFLOW_SPEECH_FIXTURE_ROOT",
      "LOCALFLOW_SPEECH_MANIFEST", "LOCALFLOW_ACCURACY_OUTPUT",
    ]
    guard keys.allSatisfy({ !(environment[$0] ?? "").isEmpty }) else {
      throw XCTSkip("Set all four TEST_RUNNER_LOCALFLOW model/speech/output variables.")
    }
    let fixtureRoot = URL(fileURLWithPath: environment[keys[1]]!).resolvingSymlinksInPath()
    let manifestURL = URL(fileURLWithPath: environment[keys[2]]!)
    guard try manifestURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0 <= 1_048_576
    else { throw DictationFailure.invalidResult }
    let fixtureDecoder = JSONDecoder()
    fixtureDecoder.keyDecodingStrategy = .convertFromSnakeCase
    let fixtures = try fixtureDecoder.decode(
      SpeechManifest.self, from: Data(contentsOf: manifestURL))
    guard fixtures.schemaVersion == 1, (1...30).contains(fixtures.fixtures.count),
      Set(fixtures.fixtures.map(\.id)).count == fixtures.fixtures.count
    else { throw DictationFailure.invalidResult }
    let descriptorURL = try XCTUnwrap(
      Bundle.main.url(forResource: "parakeet-v3", withExtension: "json"))
    let descriptor = try JSONDecoder().decode(
      ModelDescriptor.self, from: Data(contentsOf: descriptorURL))
    let root = try makeSpoolRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let provisioner = ModelProvisioner(
      descriptor: descriptor, rootURL: root.appendingPathComponent("model"))
    _ = try await provisioner.install(from: URL(fileURLWithPath: environment[keys[0]]!))
    let recorder = SpeechWindowRecorder()
    let lifecycle = ModelLifecycleCoordinator {
      let local = try await provisioner.verifiedLocalDescriptor()
      let runtime = try await FluidAudioEngineFactory(descriptor: local).makeRuntime()
      return RecordingSpeechRuntime(runtime: runtime, recorder: recorder)
    }
    var outputs: [SpeechOutput] = []
    var lastLease: ModelLease?
    do {
      for fixture in fixtures.fixtures {
        let url = fixtureRoot.appendingPathComponent(fixture.path).resolvingSymlinksInPath()
        guard url.path.hasPrefix(fixtureRoot.path + "/"), fixture.sampleRate == 16_000,
          (1...2_880_000).contains(fixture.numSamples), fixture.id.utf8.count <= 128,
          try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0 <= 16_777_216
        else { throw DictationFailure.invalidResult }
        let handle = try FileHandle(forReadingFrom: url)
        var digest = SHA256()
        var hashedBytes = 0
        do {
          while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
            hashedBytes += chunk.count
            guard hashedBytes <= 16_777_216 else { throw DictationFailure.invalidResult }
            digest.update(data: chunk)
          }
          try handle.close()
        } catch {
          try? handle.close()
          throw error
        }
        guard digest.finalize().map({ String(format: "%02x", $0) }).joined() == fixture.sha256
        else { throw DictationFailure.invalidResult }
        let file = try AVAudioFile(
          forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard file.processingFormat.sampleRate == 16_000, file.processingFormat.channelCount == 1,
          file.length == fixture.numSamples
        else { throw DictationFailure.invalidResult }
        let spool = try AudioSpool(rootDirectory: root.appendingPathComponent("audio"))
        defer { try? spool.cleanup() }
        let buffer = try XCTUnwrap(
          AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 1_600))
        var samples = 0
        while samples < fixture.numSamples {
          try file.read(
            into: buffer, frameCount: AVAudioFrameCount(min(1_600, fixture.numSamples - samples)))
          guard buffer.frameLength > 0, let channel = buffer.floatChannelData?[0] else {
            throw DictationFailure.invalidResult
          }
          try spool.append(
            normalizedSamples: Array(
              UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength))))
          samples += Int(buffer.frameLength)
        }
        let lease = try await lifecycle.acquire(session: UUID())
        lastLease = lease
        do {
          let result = await WindowedTranscriber(lifecycle: lifecycle, profile: .historical)
            .transcribe(
              spool: spool, lease: lease, sampleCount: samples)
          outputs.append(
            SpeechOutput(
              id: fixture.id, text: result.text, incomplete: result.incomplete, samples: samples,
              windows: await recorder.drain()))
          try await lifecycle.finish(lease)
          try spool.cleanup()
        } catch {
          await lifecycle.cancelAndJoin(lease)
          throw error
        }
        // Retain one loaded model between fixtures; release after the last lease.
        if outputs.count == fixtures.fixtures.count {
          await lifecycle.releaseIfIdle(generation: lease.generation)
        }
      }
    } catch {
      if let lastLease {
        await lifecycle.cancelAndJoin(lastLease)
        await lifecycle.releaseIfIdle(generation: lastLease.generation)
      }
      throw error
    }
    let output = URL(fileURLWithPath: environment[keys[3]]!)
    let data = try JSONEncoder().encode(outputs)
    let fd = open(output.path, O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW, 0o600)
    guard fd >= 0 else { throw AudioSpoolError.ioFailure }
    let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    guard fchmod(fd, 0o600) == 0 else {
      try? handle.close()
      throw AudioSpoolError.ioFailure
    }
    do {
      try handle.write(contentsOf: data)
      try handle.close()
    } catch {
      try? handle.close()
      throw error
    }
  }

  /// Explicitly provisioned inputs only. All speech stays in the private run directory.
  func testOptInQualityFixtures() async throws {
    let env = ProcessInfo.processInfo.environment
    let keys = [
      "LOCALFLOW_MODEL_PROBE_ROOT", "LOCALFLOW_SPEECH_FIXTURE_ROOT", "LOCALFLOW_SPEECH_MANIFEST",
      "LOCALFLOW_QUALITY_OUTPUT",
    ]
    guard keys.allSatisfy({ !(env[$0] ?? "").isEmpty }) else {
      throw XCTSkip("Set all four TEST_RUNNER_LOCALFLOW quality input/output variables.")
    }
    do {
      let descriptorURL = try XCTUnwrap(
        Bundle.main.url(forResource: "parakeet-v3", withExtension: "json"))
      let descriptor = try JSONDecoder().decode(
        ModelDescriptor.self, from: Data(contentsOf: descriptorURL))
      let root = try makeSpoolRoot()
      defer { try? FileManager.default.removeItem(at: root) }
      let provisioner = ModelProvisioner(
        descriptor: descriptor, rootURL: root.appendingPathComponent("model"))
      _ = try await provisioner.install(from: URL(fileURLWithPath: env[keys[0]]!))
      let recorder = QualityEvidenceRecorder()
      let lifecycle = ModelLifecycleCoordinator {
        let local = try await provisioner.verifiedLocalDescriptor()
        return try await FluidAudioEngineFactory(
          descriptor: local,
          evidenceObserver: { evidence in
            try await recorder.append(evidence)
          }
        ).makeRuntime()
      }
      let config = [
        "engine": "FluidAudio", "sdk": "0.15.7", "model_revision": descriptor.sourceRevision,
        "model_descriptor_sha256": try QualityArtifacts.hashFile(descriptorURL),
        "language": "automatic_no_hint", "window_samples": "239360", "overlap_samples": "32000",
        "padding_minimum": "4800", "assembly": "historical_window_assembly",
        "normalization": "unavailable_historical_stage_absent",
        "vocabulary": "unavailable_historical_stage_absent",
        "os": ProcessInfo.processInfo.operatingSystemVersionString,
        "hardware": env["LOCALFLOW_QUALITY_HARDWARE"] ?? "unknown_not_supplied",
        "power": env["LOCALFLOW_QUALITY_POWER"] ?? "unknown_not_supplied",
        "build": env["LOCALFLOW_QUALITY_BUILD"] ?? "unknown_not_supplied",
        "dirty": env["LOCALFLOW_QUALITY_DIRTY"] ?? "unknown_not_supplied",
        "resource_protocol": "not_measured",
      ]
      try await QualityEvaluationRunner(lifecycle: lifecycle, recorder: recorder).run(
        manifestURL: URL(fileURLWithPath: env[keys[2]]!),
        fixtureRoot: URL(fileURLWithPath: env[keys[1]]!),
        output: URL(fileURLWithPath: env[keys[3]]!), config: config)
    } catch {
      // Error descriptions from audio/JSON APIs may contain paths or transcript snippets.
      XCTFail("quality_evaluation_failed; inspect private inputs and ledger")
    }
  }

  func testRuntimeFactoryDoesNotLoadWithoutVerifiedAssets() async throws {
    let descriptor = ModelDescriptor(
      schemaVersion: 1, modelID: "test/model", sourceRevision: String(repeating: "a", count: 40),
      sdkCompatibility: "test", automaticLanguage: true, license: "test", files: [], complete: false
    )
    let local = LocalModelDescriptor(
      descriptor: descriptor, rootURL: URL(fileURLWithPath: "/tmp/missing-model"))
    do {
      _ = try await FluidAudioEngineFactory(descriptor: local).makeRuntime()
      XCTFail("missing model assets must fail before runtime construction")
    } catch ModelProvisioner.Error.incompleteManifest {
      // The manifest gate rejects the request before any CoreML model is opened.
    } catch {
      XCTFail("Unexpected error: \(error)")
    }
  }
}

// Evaluation-only traces stay in the opted-in private result JSON. No PCM is retained.
private struct RecordedSpeechWindow: Encodable, Sendable {
  struct Token: Encodable, Sendable {
    let text: String
    let start: Double
    let end: Double
  }
  let samples: Int
  let text: String
  let tokens: [Token]
}

private actor SpeechWindowRecorder {
  private var windows: [RecordedSpeechWindow] = []

  func append(_ result: TranscriptionWindow, samples: Int) throws {
    // A 180-second session has at most 14 windows at the production stride.
    guard windows.count < 14, result.text.utf8.count <= 65_536,
      result.tokens.count <= 16_384,
      result.tokens.reduce(0, { $0 + $1.text.utf8.count }) <= 65_536
    else { throw DictationFailure.invalidResult }
    windows.append(
      RecordedSpeechWindow(
        samples: samples, text: result.text,
        tokens: result.tokens.map { .init(text: $0.text, start: $0.start, end: $0.end) }))
  }

  func drain() -> [RecordedSpeechWindow] {
    defer { windows.removeAll(keepingCapacity: false) }
    return windows
  }
}

private actor RecordingSpeechRuntime: TranscriptionRuntime {
  let runtime: any TranscriptionRuntime
  let recorder: SpeechWindowRecorder

  init(runtime: any TranscriptionRuntime, recorder: SpeechWindowRecorder) {
    self.runtime = runtime
    self.recorder = recorder
  }

  func transcribe(_ samples: [Float]) async throws -> TranscriptionWindow {
    let result = try await runtime.transcribe(samples)
    try await recorder.append(result, samples: samples.count)
    return result
  }

  func shutdown() async { await runtime.shutdown() }
}

extension RuntimeCompatibilityTests {
  /// Opt-in chunk-geometry experiment. Requires a provisioned ASR model; the silence probe
  /// additionally requires a provisioned FluidAudio VAD directory. Nothing is downloaded.
  func testOptInChunkGeometryExperiment() async throws {
    let env = ProcessInfo.processInfo.environment
    let keys = [
      "LOCALFLOW_MODEL_PROBE_ROOT", "LOCALFLOW_SPEECH_FIXTURE_ROOT", "LOCALFLOW_SPEECH_MANIFEST",
      "LOCALFLOW_CHUNK_OUTPUT", "LOCALFLOW_CHUNK_STRATEGY",
    ]
    guard keys.allSatisfy({ !(env[$0] ?? "").isEmpty }) else {
      throw XCTSkip("Set all five TEST_RUNNER_LOCALFLOW chunk experiment variables.")
    }
    do {
      let overlap = Int(env["LOCALFLOW_CHUNK_OVERLAP"] ?? "32000") ?? 32_000
      let search = Int(env["LOCALFLOW_CHUNK_SEARCH_START"] ?? "0") ?? 0
      let threshold = Float(env["LOCALFLOW_CHUNK_VAD_THRESHOLD"] ?? "0.2") ?? 0.2
      let descriptorURL = try XCTUnwrap(
        Bundle.main.url(forResource: "parakeet-v3", withExtension: "json"))
      let descriptor = try JSONDecoder().decode(
        ModelDescriptor.self, from: Data(contentsOf: descriptorURL))
      let root = try makeSpoolRoot()
      defer { try? FileManager.default.removeItem(at: root) }
      let provisioner = ModelProvisioner(
        descriptor: descriptor, rootURL: root.appendingPathComponent("model"))
      _ = try await provisioner.install(from: URL(fileURLWithPath: env[keys[0]]!))
      let recorder = ChunkEvidenceRecorder()
      let lifecycle = ModelLifecycleCoordinator {
        let local = try await provisioner.verifiedLocalDescriptor()
        return try await FluidAudioEngineFactory(
          descriptor: local,
          evidenceObserver: { evidence in
            try await recorder.append(evidence)
          }
        ).makeRuntime()
      }
      // The production pipeline is fixed contiguous geometry plus the empty-vocabulary
      // normalizer; it is scored as a fourth strategy without changing the earlier three.
      let normalize = env["LOCALFLOW_CHUNK_NORMALIZE"] == "1"
      var experiment = QualityChunkExperiment(
        lifecycle: lifecycle, recorder: recorder,
        strategy: .init(
          id: env[keys[4]]!, overlapSamples: overlap, silenceSearchStart: search,
          maximumSpeechProbability: env[keys[4]] == "vad-preferred" ? threshold : nil,
          normalize: normalize))
      var vadIdentity = "unused"
      if search > 0 {
        let directory = try XCTUnwrap(env["LOCALFLOW_VAD_MODEL_ROOT"])
        let vadDescriptorURL = try XCTUnwrap(
          Bundle.main.url(forResource: "silero-vad", withExtension: "json"))
        let vadDescriptor = try JSONDecoder().decode(
          ModelDescriptor.self, from: Data(contentsOf: vadDescriptorURL))
        try vadDescriptor.validate()
        let vadBase = root.appendingPathComponent("vad", isDirectory: true)
        let vadProvisioner = ModelProvisioner(
          descriptor: vadDescriptor,
          rootURL: vadBase.appendingPathComponent("Models/silero-vad", isDirectory: true))
        _ = try await vadProvisioner.install(from: URL(fileURLWithPath: directory))
        _ = try await vadProvisioner.verifiedLocalDescriptor()
        ModelHub.offlineMode = true
        defer { ModelHub.offlineMode = false }
        let manager = try await VadManager(config: VadConfig(), modelDirectory: vadBase)
        vadIdentity = "fluidaudio_silero_vad_256ms@" + vadDescriptor.sourceRevision
        // `threshold` keeps the last region chunk under a fixed probability; `minimum` takes the
        // quietest region chunk regardless of level and never falls back.
        let mode = env["LOCALFLOW_CHUNK_VAD_MODE"] ?? "threshold"
        experiment.silence = { samples, start in
          // One bounded region only; the probe never sees more than a single chunk of audio.
          let results = try await manager.process(samples)
          var chosen: (index: Int, probability: Float)?
          if mode == "minimum" {
            var best = Float.infinity
            for (index, result) in results.enumerated() where result.probability <= best {
              best = result.probability
              chosen = (index, result.probability)
            }
          } else {
            for (index, result) in results.enumerated() where result.probability <= threshold {
              chosen = (index, result.probability)
            }
          }
          guard let chosen else { return nil }
          let index = chosen.index
          let base = index * VadManager.chunkSize
          guard mode == "minimum-refined" else {
            return .init(
              sample: start + base + VadManager.chunkSize / 2,
              speechProbability: chosen.probability)
          }
          // Refine inside the chosen 256 ms region to the quietest 32 ms sub-window.
          let step = 512
          var best = Float.infinity
          var offset = VadManager.chunkSize / 2
          var cursor = base
          while cursor + step <= min(base + VadManager.chunkSize, samples.count) {
            var energy: Float = 0
            for sample in samples[cursor..<(cursor + step)] { energy += sample * sample }
            if energy < best {
              best = energy
              offset = cursor - base + step / 2
            }
            cursor += step
          }
          return .init(
            sample: start + base + offset, speechProbability: chosen.probability)
        }
      }
      let config = [
        "engine": "FluidAudio", "sdk": "0.15.7", "model_revision": descriptor.sourceRevision,
        "model_descriptor_sha256": try QualityArtifacts.hashFile(descriptorURL),
        "language": "automatic_no_hint",
        "window_samples": String(ChunkPlanner.maximumSamples),
        "overlap_samples": String(overlap), "padding_minimum": "4800",
        "chunk_strategy": env[keys[4]]!, "silence_search_start": String(search),
        "silence_probe": vadIdentity,
        "silence_threshold": search > 0 ? String(threshold) : "unused",
        "vad_candidate_criterion": env[keys[4]] == "vad-preferred"
          ? "speech_probability_lte_0.2_else_nominal" : "minimum_probability_unconditional",
        "silence_mode": search > 0 ? (env["LOCALFLOW_CHUNK_VAD_MODE"] ?? "threshold") : "unused",
        "assembly": TranscriptAssembler.version,
        "normalization": normalize ? TranscriptNormalizer.version : "unavailable_not_requested",
        "vocabulary": normalize
          ? "empty_snapshot_" + TranscriptionQualityDetail.emptyVocabularyHash
          : "unavailable_not_requested",
        "os": ProcessInfo.processInfo.operatingSystemVersionString,
        "hardware": env["LOCALFLOW_QUALITY_HARDWARE"] ?? "unknown_not_supplied",
        "power": env["LOCALFLOW_QUALITY_POWER"] ?? "unknown_not_supplied",
        "build": env["LOCALFLOW_QUALITY_BUILD"] ?? "unknown_not_supplied",
        "dirty": env["LOCALFLOW_QUALITY_DIRTY"] ?? "unknown_not_supplied",
        "resource_protocol": "not_measured",
      ]
      try await experiment.run(
        manifestURL: URL(fileURLWithPath: env[keys[2]]!),
        fixtureRoot: URL(fileURLWithPath: env[keys[1]]!),
        output: URL(fileURLWithPath: env[keys[3]]!), config: config)
    } catch {
      XCTFail("chunk_experiment_failed; inspect private inputs and ledger")
    }
  }
}

// MARK: Feature 007 diarizer loading (T012)

extension RuntimeCompatibilityTests {
  private func diarizationManifest() throws -> ModelDescriptor {
    let url = try XCTUnwrap(
      Bundle.main.url(forResource: "speaker-diarization-offline", withExtension: "json"))
    return try JSONDecoder().decode(ModelDescriptor.self, from: Data(contentsOf: url))
  }

  private func withOfflineMode<T>(_ value: Bool, _ body: () async throws -> T) async rethrows
    -> T
  {
    let previous = ModelHub.offlineMode
    ModelHub.offlineMode = value
    defer { ModelHub.offlineMode = previous }
    return try await body()
  }

  private func expectFailure(
    _ expected: DiarizationFailureCategory, _ factory: FluidAudioDiarizerFactory
  ) async {
    do {
      _ = try await factory.makeRuntime()
      XCTFail("Expected \(expected)")
    } catch { XCTAssertEqual(error as? DiarizationFailureCategory, expected) }
  }

  func testDiarizerRefusesToLoadWhenOfflineModeIsOff() async throws {
    let root = try makeSpoolRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let local = LocalModelDescriptor(
      descriptor: try diarizationManifest(),
      rootURL: FluidAudioDiarizerFactory.installRoot(models: root))
    var factory = FluidAudioDiarizerFactory(descriptor: local)
    factory.offlineMode = { false }
    await expectFailure(.modelUnavailable, factory)
  }

  func testDiarizerOnMacOS14IsUnsupportedAndLoadsNothing() async throws {
    let root = try makeSpoolRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let local = LocalModelDescriptor(
      descriptor: try diarizationManifest(),
      rootURL: FluidAudioDiarizerFactory.installRoot(models: root))
    var factory = FluidAudioDiarizerFactory(descriptor: local)
    factory.offlineMode = { true }
    factory.operatingSystem = OperatingSystemVersion(
      majorVersion: 14, minorVersion: 7, patchVersion: 0)
    await expectFailure(.osUnsupported, factory)
    XCTAssertFalse(FileManager.default.fileExists(atPath: local.rootURL.path))
  }

  func testMissingDiarizerFilesFailAsModelUnavailableWithoutDownloading() async throws {
    guard ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 15 else {
      throw XCTSkip("Diarization loads only on macOS 15 or later.")
    }
    let root = try makeSpoolRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let install = FluidAudioDiarizerFactory.installRoot(models: root)
    try FileManager.default.createDirectory(at: install, withIntermediateDirectories: true)
    let local = LocalModelDescriptor(descriptor: try diarizationManifest(), rootURL: install)
    await withOfflineMode(true) {
      await expectFailure(.modelUnavailable, FluidAudioDiarizerFactory(descriptor: local))
    }
    let contents = try FileManager.default.contentsOfDirectory(atPath: install.path)
    XCTAssertTrue(contents.isEmpty, "Nothing was fetched into the model directory")
  }

  func testDiarizerMapsSpeakerIDsQualityAndNormalizedCentroids() throws {
    let result = DiarizationResult(
      segments: [
        .init(
          speakerId: "S1", embedding: [], startTimeSeconds: 0, endTimeSeconds: 2, qualityScore: 0.9),
        .init(
          speakerId: "S2", embedding: [], startTimeSeconds: 1, endTimeSeconds: 3, qualityScore: 0.4),
        .init(
          speakerId: "S3", embedding: [], startTimeSeconds: 4, endTimeSeconds: 4, qualityScore: 1),
      ],
      chunkEmbeddings: [
        .init(
          speakerId: "S1", chunkIndex: 0, speakerIndex: 0, startTimeSeconds: 0, endTimeSeconds: 1,
          embedding256: [3, 0]),
        .init(
          speakerId: "S1", chunkIndex: 1, speakerIndex: 0, startTimeSeconds: 1, endTimeSeconds: 2,
          embedding256: [0, 4]),
      ])
    let mapped = try FluidAudioDiarizer.map(result)
    XCTAssertEqual(mapped.turns.map(\.cluster), [0, 1], "An empty span is dropped")
    XCTAssertEqual(mapped.turns.map(\.quality), [0.9, 0.4])
    XCTAssertEqual(Set(mapped.centroids.keys), [0], "A cluster without chunk embeddings has none")
    let centroid = try XCTUnwrap(mapped.centroids[0])
    XCTAssertEqual(centroid[0], 0.6, accuracy: 1e-6)
    XCTAssertEqual(centroid[1], 0.8, accuracy: 1e-6)
    XCTAssertThrowsError(
      try FluidAudioDiarizer.map(
        DiarizationResult(segments: [
          .init(
            speakerId: "X", embedding: [], startTimeSeconds: 0, endTimeSeconds: 1, qualityScore: 1)
        ])))
  }

  /// Opt-in: set TEST_RUNNER_LOCALFLOW_DIARIZATION_MODEL_SOURCE to a directory holding the
  /// pinned files (e.g. build/model-downloads/speaker-diarization-coreml-<revision>).
  func testOptInDiarizerLoadsFromTheProvisionedLayoutOffline() async throws {
    guard let source = ProcessInfo.processInfo.environment["LOCALFLOW_DIARIZATION_MODEL_SOURCE"],
      !source.isEmpty
    else { throw XCTSkip("Set TEST_RUNNER_LOCALFLOW_DIARIZATION_MODEL_SOURCE explicitly.") }
    guard ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 15 else {
      throw XCTSkip("Diarization loads only on macOS 15 or later.")
    }
    let root = try makeSpoolRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let provisioner = ModelProvisioner(
      descriptor: try diarizationManifest(),
      rootURL: FluidAudioDiarizerFactory.installRoot(models: root))
    _ = try await provisioner.install(from: URL(fileURLWithPath: source, isDirectory: true))
    try await withOfflineMode(true) {
      let lifecycle = ModelLifecycleCoordinator(
        diarizationFactory: {
          try await FluidAudioDiarizerFactory(
            descriptor: provisioner.verifiedLocalDescriptor()
          ).makeRuntime()
        }, factory: { throw DictationFailure.modelUnavailable })
      let lease = try await lifecycle.acquire(session: UUID(), workload: .diarization)
      do {
        let silence = [Float](repeating: 0, count: 16_000 * 12)
        let unconstrained = try await lifecycle.diarize(
          lease, window: .init(samples: silence, numSpeakers: nil))
        XCTAssertTrue(unconstrained.isValid)
        let microphone = try await lifecycle.diarize(
          lease, window: .init(samples: silence, numSpeakers: 1))
        XCTAssertLessThanOrEqual(Set(microphone.turns.map(\.cluster)).count, 1)
        try await lifecycle.finish(lease)
      } catch {
        await lifecycle.cancelAndJoin(lease)
        throw error
      }
      let state = await lifecycle.state
      XCTAssertEqual(state, .unloaded)
    }
  }

  /// FR-036/FR-037 (T073): nothing under the diarization or speakers modules names a
  /// networking symbol. The engine loads from the verified local layout only.
  func testDiarizationSourcesReferenceNoNetworkingSymbols() throws {
    let root = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("LocalFlow")
    let directories = [
      root.appendingPathComponent("Core/Diarization"),
      root.appendingPathComponent("Features/Speakers"),
    ]
    let files = [
      root.appendingPathComponent("Core/DiarizationBoundaries.swift"),
      root.appendingPathComponent("Core/Storage/SpeakerStore.swift"),
    ]
    var sources: [URL] = files
    for directory in directories {
      let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
      sources += names.filter { $0.hasSuffix(".swift") }.map(directory.appendingPathComponent)
    }
    XCTAssertGreaterThan(sources.count, 8)
    let forbidden = ["URLSession", "import Network", "NWConnection", "URLRequest", "CFNetwork"]
    for source in sources {
      let text = try String(contentsOf: source, encoding: .utf8)
      for symbol in forbidden {
        XCTAssertFalse(text.contains(symbol), "\(source.lastPathComponent) references \(symbol)")
      }
    }
  }
}

// MARK: Feature 010 voice embedder loading (T011)

extension RuntimeCompatibilityTests {
  private func embedderManifest() throws -> ModelDescriptor {
    let url = try XCTUnwrap(
      Bundle.main.url(forResource: "speaker-diarization-offline", withExtension: "json"))
    return try JSONDecoder().decode(ModelDescriptor.self, from: Data(contentsOf: url))
  }

  private func expectEmbedderFailure(
    _ expected: IdentificationFailureCategory, _ factory: FluidAudioVoiceEmbedderFactory
  ) async {
    do {
      _ = try await factory.makeRuntime()
      XCTFail("Expected \(expected)")
    } catch { XCTAssertEqual(error as? IdentificationFailureCategory, expected) }
  }

  func testEmbedderRefusesToLoadWhenOfflineModeIsOff() async throws {
    let root = try makeSpoolRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let local = LocalModelDescriptor(
      descriptor: try embedderManifest(),
      rootURL: FluidAudioDiarizerFactory.installRoot(models: root))
    var factory = FluidAudioVoiceEmbedderFactory(descriptor: local)
    factory.offlineMode = { false }
    await expectEmbedderFailure(.modelUnavailable, factory)
  }

  func testEmbedderOnMacOS14IsUnsupportedAndLoadsNothing() async throws {
    let root = try makeSpoolRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let local = LocalModelDescriptor(
      descriptor: try embedderManifest(),
      rootURL: FluidAudioDiarizerFactory.installRoot(models: root))
    var factory = FluidAudioVoiceEmbedderFactory(descriptor: local)
    factory.offlineMode = { true }
    factory.operatingSystem = OperatingSystemVersion(
      majorVersion: 14, minorVersion: 7, patchVersion: 0)
    await expectEmbedderFailure(.osUnsupported, factory)
    XCTAssertFalse(FileManager.default.fileExists(atPath: local.rootURL.path))
  }

  func testMissingEmbedderFilesFailAsModelUnavailableWithoutDownloading() async throws {
    guard ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 15 else {
      throw XCTSkip("Identification loads only on macOS 15 or later.")
    }
    let root = try makeSpoolRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let install = FluidAudioDiarizerFactory.installRoot(models: root)
    try FileManager.default.createDirectory(at: install, withIntermediateDirectories: true)
    let local = LocalModelDescriptor(descriptor: try embedderManifest(), rootURL: install)
    let previous = ModelHub.offlineMode
    ModelHub.offlineMode = true
    defer { ModelHub.offlineMode = previous }
    await expectEmbedderFailure(
      .modelUnavailable, FluidAudioVoiceEmbedderFactory(descriptor: local))
    let contents = try FileManager.default.contentsOfDirectory(atPath: install.path)
    XCTAssertTrue(contents.isEmpty, "Nothing was fetched into the model directory")
  }

  func testEmbedderIdentityMatchesTheManifest() throws {
    let manifest = try embedderManifest()
    let hash = String(repeating: "c", count: 64)
    let identity = FluidAudioVoiceEmbedderFactory.identity(descriptor: manifest, manifestHash: hash)
    XCTAssertEqual(identity.engine, "wespeaker_resnet34lm_256")
    XCTAssertEqual(identity.modelID, manifest.modelID)
    XCTAssertEqual(identity.modelID, FluidAudioDiarizerFactory.modelID)
    XCTAssertEqual(identity.modelRevision, manifest.sourceRevision)
    XCTAssertEqual(identity.modelRevision, FluidAudioDiarizerFactory.revision)
    XCTAssertEqual(identity.manifestHash, hash)
    XCTAssertEqual(identity.dimension, 256)
    XCTAssertTrue(identity.isValid)
    XCTAssertNotNil(IdentificationThresholds.current(for: identity))
    XCTAssertEqual(
      IdentificationThresholds.current(for: identity)?.policyVersion,
      "tiers_v1@wespeaker_resnet34lm_256/\(manifest.sourceRevision.prefix(8))")
  }

  func testEmbedderReducesTheDominantClusterToADurationWeightedUnitVector() throws {
    let result = DiarizationResult(
      segments: [
        .init(
          speakerId: "S1", embedding: [], startTimeSeconds: 0, endTimeSeconds: 3, qualityScore: 0.9),
        .init(
          speakerId: "S2", embedding: [], startTimeSeconds: 3, endTimeSeconds: 4, qualityScore: 0.9),
      ],
      chunkEmbeddings: [
        .init(
          speakerId: "S1", chunkIndex: 0, speakerIndex: 0, startTimeSeconds: 0, endTimeSeconds: 2,
          embedding256: VoiceVectors.unit(axis: 0)),
        .init(
          speakerId: "S1", chunkIndex: 1, speakerIndex: 0, startTimeSeconds: 2, endTimeSeconds: 3,
          embedding256: VoiceVectors.unit(axis: 1)),
        .init(
          speakerId: "S2", chunkIndex: 2, speakerIndex: 1, startTimeSeconds: 3, endTimeSeconds: 4,
          embedding256: VoiceVectors.unit(axis: 7)),
      ])
    let embedding = try XCTUnwrap(FluidAudioVoiceEmbedder.reduce(result))
    XCTAssertTrue(embedding.isValid)
    XCTAssertEqual(embedding.speechSeconds, 3, accuracy: 1e-9)
    // (2, 1, 0…) normalized: the second cluster's chunk does not enter.
    XCTAssertEqual(Double(embedding.vector[0]), 2 / 5.0.squareRoot(), accuracy: 1e-6)
    XCTAssertEqual(Double(embedding.vector[1]), 1 / 5.0.squareRoot(), accuracy: 1e-6)
    XCTAssertEqual(embedding.vector[7], 0)
    XCTAssertNil(FluidAudioVoiceEmbedder.reduce(DiarizationResult(segments: [])))
    XCTAssertNil(
      FluidAudioVoiceEmbedder.reduce(
        DiarizationResult(segments: [
          .init(
            speakerId: "S1", embedding: [], startTimeSeconds: 0, endTimeSeconds: 1, qualityScore: 1)
        ])), "Speech without an embedding is no sample")
  }

  /// Opt-in: set TEST_RUNNER_LOCALFLOW_DIARIZATION_MODEL_SOURCE to a directory holding the
  /// pinned files. The embedder loads from the provisioned diarization directory offline.
  func testOptInEmbedderLoadsFromTheProvisionedLayoutOffline() async throws {
    guard let source = ProcessInfo.processInfo.environment["LOCALFLOW_DIARIZATION_MODEL_SOURCE"],
      !source.isEmpty
    else { throw XCTSkip("Set TEST_RUNNER_LOCALFLOW_DIARIZATION_MODEL_SOURCE explicitly.") }
    guard ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 15 else {
      throw XCTSkip("Identification loads only on macOS 15 or later.")
    }
    let root = try makeSpoolRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let provisioner = ModelProvisioner(
      descriptor: try embedderManifest(),
      rootURL: FluidAudioDiarizerFactory.installRoot(models: root))
    _ = try await provisioner.install(from: URL(fileURLWithPath: source, isDirectory: true))
    let previous = ModelHub.offlineMode
    ModelHub.offlineMode = true
    defer { ModelHub.offlineMode = previous }
    let lifecycle = ModelLifecycleCoordinator(
      voiceEmbeddingFactory: {
        try await FluidAudioVoiceEmbedderFactory(
          descriptor: provisioner.verifiedLocalDescriptor()
        ).makeRuntime()
      }, factory: { throw DictationFailure.modelUnavailable })
    let lease = try await lifecycle.acquire(session: UUID(), workload: .speakerIdentification)
    do {
      var tone = [Float](repeating: 0, count: 16_000 * 6)
      for index in tone.indices { tone[index] = Float(sin(Double(index) * 0.08)) * 0.3 }
      do {
        let embedding = try await lifecycle.embed(lease, region: .init(samples: tone))
        XCTAssertTrue(embedding.isValid)
      } catch VoiceEmbeddingFailure.noSpeech {
        // A tone is not speech; the region is counted as rejected, never as an error.
      }
      try await lifecycle.finish(lease)
    } catch {
      await lifecycle.cancelAndJoin(lease)
      throw error
    }
    let state = await lifecycle.state
    XCTAssertEqual(state, .unloaded)
  }

  /// FR-034/FR-036 (T090): nothing under the identification module names a networking
  /// symbol; the embedder loads from the verified local layout only.
  func testIdentificationSourcesReferenceNoNetworkingSymbols() throws {
    let root = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("LocalFlow")
    let directory = root.appendingPathComponent("Core/Identification")
    var sources = [
      root.appendingPathComponent("Core/IdentificationBoundaries.swift"),
      root.appendingPathComponent("Core/Storage/IdentityStore.swift"),
    ]
    let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
    sources += names.filter { $0.hasSuffix(".swift") }.map(directory.appendingPathComponent)
    XCTAssertGreaterThan(sources.count, 8)
    let forbidden = ["URLSession", "import Network", "NWConnection", "URLRequest", "CFNetwork"]
    for source in sources {
      let text = try String(contentsOf: source, encoding: .utf8)
      for symbol in forbidden {
        XCTAssertFalse(text.contains(symbol), "\(source.lastPathComponent) references \(symbol)")
      }
    }
  }
}
