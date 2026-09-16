import AVFoundation
import CryptoKit
import XCTest

@testable import LocalFlow

final class RuntimeCompatibilityTests: XCTestCase {
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
          let result = await WindowedTranscriber(lifecycle: lifecycle).transcribe(
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
