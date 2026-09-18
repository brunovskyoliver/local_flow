import AVFoundation
import Foundation

@testable import LocalFlow

actor QualityEvidenceRecorder {
  private var windows: [QualityResult.Window] = []
  private var bytes = 0
  func append(_ evidence: RecognitionEvidence) throws {
    guard windows.count < 32, evidence.text.utf8.count <= 65_536,
      evidence.tokens.count <= 16_384,
      evidence.tokens.reduce(0, { min(65_537, $0 + min(65_537, $1.text.utf8.count)) }) <= 65_536
    else { throw QualityArtifacts.Failure.capacity }
    let window = QualityResult.Window(
      sequence: windows.count, sampleStart: windows.count * 207_360, evidence: evidence,
      text: evidence.text, sha256: QualityArtifacts.hash(Data(evidence.text.utf8)),
      tokens: evidence.tokens)
    let size = try QualityArtifacts.encode(window).count
    guard bytes + size <= QualityArtifacts.artifact - 1_048_576 else {
      throw QualityArtifacts.Failure.capacity
    }
    bytes += size
    windows.append(window)
  }
  func drain() -> [QualityResult.Window] {
    defer {
      windows.removeAll(keepingCapacity: false)
      bytes = 0
    }
    return windows
  }
}

/// Sequential test tooling. Runtime construction is exclusively coordinator-owned.
struct QualityEvaluationRunner {
  let lifecycle: ModelLifecycleCoordinator
  let recorder: QualityEvidenceRecorder
  var beforeCommit: (@Sendable (String) throws -> Void)? = nil

  func run(manifestURL: URL, fixtureRoot: URL, output: URL, config: [String: String]) async throws {
    let manifest = try QualityArtifacts.read(QualityManifest.self, from: manifestURL)
    try manifest.validate(root: fixtureRoot)
    let manifestHash = try QualityArtifacts.hashFile(manifestURL, limit: QualityArtifacts.small)
    let configData = try QualityArtifacts.encode(config, limit: QualityArtifacts.small)
    // Preflight every audio file before any runtime is acquired.
    for fixture in manifest.fixtures {
      let url = try fixture.audioURL(root: fixtureRoot)
      guard try QualityArtifacts.hashFile(url) == fixture.sha256 else {
        throw QualityArtifacts.Failure.invalid
      }
      let audio = try AVAudioFile(
        forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
      guard audio.processingFormat.sampleRate == 16_000, audio.processingFormat.channelCount == 1,
        audio.length == fixture.numSamples
      else { throw QualityArtifacts.Failure.invalid }
    }
    try QualityArtifacts.directory(output)
    let results = output.appendingPathComponent("results", isDirectory: true)
    try QualityArtifacts.directory(results)
    var run = QualityRun(
      runId: UUID().uuidString, manifestSha256: manifestHash, config: config,
      configSha256: QualityArtifacts.hash(configData),
      ledger: manifest.fixtures.map { .init(id: $0.id) })
    let ledger = output.appendingPathComponent("run.json")
    try persist(run, to: ledger, replace: false)
    for index in manifest.fixtures.indices {
      if Task.isCancelled {
        for remaining in index..<run.ledger.count { run.ledger[remaining].status = "not_run" }
        run.status = "aborted"
        try persist(run, to: ledger)
        return
      }
      let fixture = manifest.fixtures[index]
      run.status = "running"
      run.ledger[index].status = "running"
      try persist(run, to: ledger)
      var lease: ModelLease?
      var spool: AudioSpool?
      var text = ""
      var incomplete = true
      var status = "failed"
      var reasons: [String] = []
      do {
        let audio = try AVAudioFile(
          forReading: fixture.audioURL(root: fixtureRoot), commonFormat: .pcmFormatFloat32,
          interleaved: false)
        let activeSpool = try AudioSpool(rootDirectory: output.appendingPathComponent("spool"))
        spool = activeSpool
        guard let buffer = AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: 1600)
        else { throw QualityArtifacts.Failure.invalid }
        var count = 0
        while count < fixture.numSamples {
          try Task.checkCancellation()
          try audio.read(
            into: buffer, frameCount: AVAudioFrameCount(min(1600, fixture.numSamples - count)))
          guard buffer.frameLength > 0, let channel = buffer.floatChannelData?[0] else {
            throw QualityArtifacts.Failure.invalid
          }
          try activeSpool.append(
            normalizedSamples: Array(
              UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength))))
          count += Int(buffer.frameLength)
        }
        let active = try await lifecycle.acquire(session: UUID())
        lease = active
        let decoded = await WindowedTranscriber(lifecycle: lifecycle, profile: .historical)
          .transcribe(
            spool: activeSpool, lease: active, sampleCount: count)
        text = decoded.text
        incomplete = decoded.incomplete
        status = Task.isCancelled ? "cancelled" : (incomplete ? "failed" : "completed")
        if incomplete { reasons = ["historical_pipeline_incomplete"] }
        try await lifecycle.finish(active)
        await lifecycle.releaseIfIdle(generation: active.generation)
        lease = nil
      } catch {
        status = Task.isCancelled ? "cancelled" : "failed"
        reasons = [Task.isCancelled ? "cancelled" : "decode_failed"]
        if let lease { await lifecycle.cancelAndJoin(lease) }
      }
      try spool?.cleanup()
      let windows = await recorder.drain()
      let raw = windows.map(\.text).joined(separator: "\n")
      let result = QualityResult(
        id: fixture.id, status: status, incomplete: incomplete,
        reasons: reasons, windows: windows,
        stages: [
          "raw": .init(text: raw, identity: "sdk_windows_lf_overlap"),
          "assembled": .init(text: text, identity: "historical_window_assembly"),
          "normalized": .init(unavailable: "historical_normalization_absent"),
        ],
        measurements: [
          "rss": .init(unit: "bytes", reason: "not_measured"),
          "stage_duration": .init(unit: "seconds", reason: "not_measured"),
          "queue_peak": .init(unit: "count", reason: "not_measured"),
        ])
      let data = try QualityArtifacts.encode(result)
      try beforeCommit?("before_result")
      try QualityArtifacts.write(
        data, to: results.appendingPathComponent(fixture.id + ".json"), replace: false)
      try beforeCommit?("after_result")
      run.ledger[index].resultSha256 = QualityArtifacts.hash(data)
      run.ledger[index].status = status
      try persist(run, to: ledger)
    }
    run.status = "complete"
    try persist(run, to: ledger)
  }

  private func persist(_ run: QualityRun, to url: URL, replace: Bool = true) throws {
    try QualityArtifacts.write(
      QualityArtifacts.encode(run, limit: QualityArtifacts.small), to: url, replace: replace,
      limit: QualityArtifacts.small)
  }

  /// Explicit recovery only; a completed run is never reopened or overwritten.
  static func recover(output: URL) throws {
    let ledger = output.appendingPathComponent("run.json")
    var run = try QualityArtifacts.read(QualityRun.self, from: ledger)
    guard run.schemaVersion == 2, run.status != "complete", run.status != "interrupted",
      run.ledger.count <= 256,
      Set(run.ledger.map(\.id)).count == run.ledger.count
    else { throw QualityArtifacts.Failure.invalid }
    for index in run.ledger.indices {
      try QualityArtifacts.validateID(run.ledger[index].id)
      let url = output.appendingPathComponent("results/" + run.ledger[index].id + ".json")
      if FileManager.default.fileExists(atPath: url.path) {
        let result = try QualityArtifacts.read(
          QualityResult.self, from: url, limit: QualityArtifacts.artifact)
        guard result.id == run.ledger[index].id, result.schemaVersion == 2,
          ["completed", "failed", "cancelled"].contains(result.status)
        else { throw QualityArtifacts.Failure.invalid }
        let hash = try QualityArtifacts.hashFile(url)
        if let expected = run.ledger[index].resultSha256, expected != hash {
          throw QualityArtifacts.Failure.invalid
        }
        run.ledger[index].resultSha256 = hash
        run.ledger[index].status = result.status
      } else if run.ledger[index].status == "running" {
        run.ledger[index].status = "interrupted"
      } else if run.ledger[index].status == "pending" {
        run.ledger[index].status = "not_run"
      } else if run.ledger[index].resultSha256 != nil {
        throw QualityArtifacts.Failure.invalid
      }
    }
    run.status = "interrupted"
    try QualityArtifacts.write(
      QualityArtifacts.encode(run, limit: QualityArtifacts.small), to: ledger, replace: true,
      limit: QualityArtifacts.small)
  }
}
