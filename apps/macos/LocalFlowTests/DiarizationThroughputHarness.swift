@preconcurrency import AVFoundation
import FluidAudio
import XCTest

@testable import LocalFlow

/// Feature 007 delivery step 1 (T015). Runs the real diarizer through
/// `ModelLifecycleCoordinator`, no UI, over each track at each window length, and
/// appends one JSON line per run. Opt-in only; the numbers it writes are evidence for
/// `acceptance/throughput.md` only when collected on the reference machine (T016).
///
/// TEST_RUNNER_LOCALFLOW_DIARIZATION_MODEL_SOURCE  pinned model files
/// TEST_RUNNER_LOCALFLOW_DIARIZATION_HARNESS_TRACKS  `system=/a.wav,microphone=/b.aac`
/// TEST_RUNNER_LOCALFLOW_DIARIZATION_HARNESS_OUTPUT  JSON-lines file to append to
/// TEST_RUNNER_LOCALFLOW_DIARIZATION_HARNESS_WINDOWS  seconds, default `600,1200`
final class DiarizationThroughputHarness: XCTestCase {
  func testOptInThroughputAndMemory() async throws {
    let env = ProcessInfo.processInfo.environment
    guard let source = env["LOCALFLOW_DIARIZATION_MODEL_SOURCE"], !source.isEmpty,
      let trackList = env["LOCALFLOW_DIARIZATION_HARNESS_TRACKS"], !trackList.isEmpty,
      let output = env["LOCALFLOW_DIARIZATION_HARNESS_OUTPUT"], !output.isEmpty
    else { throw XCTSkip("Set the TEST_RUNNER_LOCALFLOW_DIARIZATION_* harness variables.") }
    guard ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 15 else {
      throw XCTSkip("Diarization runs only on macOS 15 or later.")
    }
    let tracks = try trackList.split(separator: ",").map { entry -> (MeetingTrackKind, URL) in
      let parts = entry.split(separator: "=", maxSplits: 1).map(String.init)
      guard parts.count == 2, let kind = MeetingTrackKind(rawValue: parts[0]) else {
        throw XCTSkip("Tracks must be `system=` or `microphone=` paths.")
      }
      return (kind, URL(fileURLWithPath: parts[1]))
    }
    let windows = (env["LOCALFLOW_DIARIZATION_HARNESS_WINDOWS"] ?? "600,1200")
      .split(separator: ",").compactMap { Int($0) }
    let manifestURL = try XCTUnwrap(
      Bundle.main.url(forResource: "speaker-diarization-offline", withExtension: "json"))
    let manifest = try JSONDecoder().decode(
      ModelDescriptor.self, from: Data(contentsOf: manifestURL))
    let root = try makeSpoolRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let provisioner = ModelProvisioner(
      descriptor: manifest, rootURL: FluidAudioDiarizerFactory.installRoot(models: root))
    _ = try await provisioner.install(from: URL(fileURLWithPath: source, isDirectory: true))
    let previous = ModelHub.offlineMode
    ModelHub.offlineMode = true
    defer { ModelHub.offlineMode = previous }

    for windowSeconds in windows {
      for (kind, url) in tracks {
        let line = try await measure(
          kind: kind, url: url, windowSamples: windowSeconds * 16_000,
          provisioner: provisioner, revision: manifest.sourceRevision)
        var data = try JSONSerialization.data(withJSONObject: line, options: [.sortedKeys])
        data.append(0x0A)
        let handle = try openForAppend(output)
        defer { try? handle.close() }
        try handle.write(contentsOf: data)
      }
    }
  }

  private func measure(
    kind: MeetingTrackKind, url: URL, windowSamples: Int, provisioner: ModelProvisioner,
    revision: String
  ) async throws -> [String: Any] {
    let sampler = RSSSampler()
    let sampling = Task { await sampler.run() }
    defer { sampling.cancel() }
    let baseline = ResourceRecorder.residentBytes() ?? 0
    let lifecycle = ModelLifecycleCoordinator(
      diarizationFactory: {
        try await FluidAudioDiarizerFactory(
          descriptor: provisioner.verifiedLocalDescriptor()
        ).makeRuntime()
      }, factory: { throw DictationFailure.modelUnavailable })
    let clock = ContinuousClock()
    let loadStart = clock.now
    let lease = try await lifecycle.acquire(session: UUID(), workload: .diarization)
    let loadSeconds = seconds(loadStart.duration(to: clock.now))
    let loaded = ResourceRecorder.residentBytes() ?? 0
    var windowCount = 0
    var maxClusters = 0
    var audioSamples = 0
    let runStart = clock.now
    do {
      try await decode(url, windowSamples: windowSamples) { window in
        audioSamples += window.count
        windowCount += 1
        let result = try await lifecycle.diarize(
          lease,
          window: .init(samples: window, numSpeakers: kind == .microphone ? 1 : nil))
        maxClusters = max(maxClusters, Set(result.turns.map(\.cluster)).count)
      }
      try await lifecycle.finish(lease)
    } catch {
      await lifecycle.cancelAndJoin(lease)
      throw error
    }
    let runSeconds = seconds(runStart.duration(to: clock.now))
    let released = ResourceRecorder.residentBytes() ?? 0
    sampling.cancel()
    let samples = await sampler.samples
    let os = ProcessInfo.processInfo.operatingSystemVersion
    let audioSeconds = Double(audioSamples) / 16_000
    return [
      "schema_version": 1,
      "track": kind.rawValue,
      "window_seconds": windowSamples / 16_000,
      "audio_seconds": audioSeconds,
      "diarization_seconds": runSeconds,
      "rtf": audioSeconds > 0 ? runSeconds / audioSeconds : 0,
      "model_load_seconds": loadSeconds,
      "baseline_rss_bytes": baseline,
      "model_rss_increase_bytes": Int64(loaded) - Int64(baseline),
      "peak_rss_bytes": max(samples.map(\.1).max() ?? 0, loaded),
      "rss_slope_mb_per_10min": slope(samples),
      "rss_after_release_bytes": released,
      "window_count": windowCount,
      "max_window_speaker_count": maxClusters,
      "hardware": ResourceRecorder.hardwareIdentifier() ?? "unavailable",
      "macos": "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)",
      "build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        ?? "unavailable",
      "model_revision": revision,
      "pipeline_version": DiarizationPipelineVersion.current,
    ]
  }

  /// Streams the file as mono 16 kHz through one reusable window buffer.
  private func decode(
    _ url: URL, windowSamples: Int, body: ([Float]) async throws -> Void
  ) async throws {
    let file = try AVAudioFile(forReading: url)
    let target = try XCTUnwrap(
      AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false))
    let converter = try XCTUnwrap(AVAudioConverter(from: file.processingFormat, to: target))
    let input = try XCTUnwrap(
      AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4_096))
    let output = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: target, frameCapacity: 4_096))
    var window: [Float] = []
    window.reserveCapacity(windowSamples)
    var ended = false
    while !ended {
      output.frameLength = 0
      var error: NSError?
      let status = converter.convert(to: output, error: &error) { _, outStatus in
        do {
          try file.read(into: input, frameCount: 4_096)
        } catch {
          outStatus.pointee = .endOfStream
          return nil
        }
        guard input.frameLength > 0 else {
          outStatus.pointee = .endOfStream
          return nil
        }
        outStatus.pointee = .haveData
        return input
      }
      if let error { throw error }
      ended = status == .endOfStream || status == .error
      let channel = try XCTUnwrap(output.floatChannelData)[0]
      var offset = 0
      let count = Int(output.frameLength)
      while offset < count {
        let take = min(count - offset, windowSamples - window.count)
        window.append(contentsOf: UnsafeBufferPointer(start: channel + offset, count: take))
        offset += take
        if window.count == windowSamples {
          try await body(window)
          window.removeAll(keepingCapacity: true)
        }
      }
    }
    if !window.isEmpty { try await body(window) }
  }

  private func slope(_ samples: [(Double, UInt64)]) -> Double {
    guard samples.count >= 2 else { return 0 }
    let n = Double(samples.count)
    let meanX = samples.reduce(0) { $0 + $1.0 } / n
    let meanY = samples.reduce(0) { $0 + Double($1.1) } / n
    let numerator = samples.reduce(0) { $0 + ($1.0 - meanX) * (Double($1.1) - meanY) }
    let denominator = samples.reduce(0) { $0 + ($1.0 - meanX) * ($1.0 - meanX) }
    guard denominator > 0 else { return 0 }
    return numerator / denominator * 600 / 1_048_576
  }

  private func seconds(_ duration: Duration) -> Double {
    let parts = duration.components
    return Double(parts.seconds) + Double(parts.attoseconds) * 1e-18
  }

  private func openForAppend(_ path: String) throws -> FileHandle {
    if !FileManager.default.fileExists(atPath: path) {
      FileManager.default.createFile(atPath: path, contents: nil)
    }
    let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
    try handle.seekToEnd()
    return handle
  }
}

/// RSS every 10 s, bounded at one day of samples.
private actor RSSSampler {
  private(set) var samples: [(Double, UInt64)] = []

  func run() async {
    let start = ContinuousClock.now
    while !Task.isCancelled, samples.count < 8_640 {
      if let bytes = ResourceRecorder.residentBytes() {
        let elapsed = start.duration(to: .now).components
        samples.append((Double(elapsed.seconds), bytes))
      }
      try? await Task.sleep(for: .seconds(10))
    }
  }
}
