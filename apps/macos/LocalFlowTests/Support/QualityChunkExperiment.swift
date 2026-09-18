import AVFoundation
import Darwin
import Foundation

@testable import LocalFlow

/// Evaluation-only chunk-geometry experiment. It reuses the frozen corpus and the production
/// `ChunkPlanner` and `TranscriptAssembler`; it changes no acceptance threshold, reference or
/// scorer rule. Audio is read one bounded chunk at a time from the spool, never as a whole
/// recording, and one model instance is used sequentially.
actor ChunkEvidenceRecorder {
  private var windows: [QualityResult.Window] = []
  private var pendingStart = 0
  private var bytes = 0
  func expect(sampleStart: Int) { pendingStart = sampleStart }
  func append(_ evidence: RecognitionEvidence) throws {
    guard windows.count < 32, evidence.text.utf8.count <= 65_536,
      evidence.tokens.count <= 16_384,
      evidence.tokens.reduce(0, { min(65_537, $0 + min(65_537, $1.text.utf8.count)) }) <= 65_536
    else { throw QualityArtifacts.Failure.capacity }
    let window = QualityResult.Window(
      sequence: windows.count, sampleStart: pendingStart, evidence: evidence,
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

private actor ChunkBufferRecorder {
  private var plannerSamples = 0
  func observePlanner(_ count: Int) { plannerSamples = max(plannerSamples, count) }
  func drain() -> Int {
    defer { plannerSamples = 0 }
    return plannerSamples
  }
}

struct QualityChunkExperiment {
  struct Strategy: Sendable {
    let id: String
    let overlapSamples: Int
    /// Zero disables the silence probe and keeps pure fixed-window geometry.
    let silenceSearchStart: Int
    let maximumSpeechProbability: Float?
    /// Runs the production `TranscriptNormalizer` with the explicit empty vocabulary over the
    /// assembled text, so the normalized stage can be scored like the others. Off by default
    /// to keep earlier chunk-planner runs byte-comparable.
    var normalize = false
  }
  struct ChunkRecord: Codable {
    let sequence: Int
    let sampleStart: Int
    let sampleCount: Int
    let boundary: String
  }
  struct Diagnostics: Codable {
    let id: String
    let strategy: String
    let chunks: [ChunkRecord]
    let overlapSamples: Int
    let seams: [TranscriptAssembler.Seam]
    let conflictingEdgeTokens: Int
    let uncertainSeams: Int
    let incomplete: Bool
    let reasons: [String]
    let recognitionSeconds: Double
    let wallSeconds: Double
    let peakRSSBytes: UInt64?
    let maximumAudioBufferSamples: Int
    let maximumPlannerBufferSamples: Int
    let silenceBoundaries: Int
    let fallbackBoundaries: Int
    /// T021 audit: lexical (non-punctuation) tokens discarded at proven seams whose onset
    /// evidence exceeded the 160 ms bound at their own position.
    let discardedLexicalWords: Int
    let unevidencedLexicalDiscards: Int
    let preAnchorLexicalDiscards: Int
    let maximumDiscardedOnsetDelta: Double
  }

  let lifecycle: ModelLifecycleCoordinator
  let recorder: ChunkEvidenceRecorder
  let strategy: Strategy
  /// Bounded silence probe over exactly one search region; returns an absolute cut sample.
  var silence: (@Sendable ([Float], Int) async throws -> ChunkPlanner.BoundaryCandidate?)? = nil

  func run(manifestURL: URL, fixtureRoot: URL, output: URL, config: [String: String]) async throws {
    let manifest = try QualityArtifacts.read(QualityManifest.self, from: manifestURL)
    try manifest.validate(root: fixtureRoot)
    let manifestHash = try QualityArtifacts.hashFile(manifestURL, limit: QualityArtifacts.small)
    let configData = try QualityArtifacts.encode(config, limit: QualityArtifacts.small)
    for fixture in manifest.fixtures {
      let url = try fixture.audioURL(root: fixtureRoot)
      guard try QualityArtifacts.hashFile(url) == fixture.sha256 else {
        throw QualityArtifacts.Failure.invalid
      }
    }
    try QualityArtifacts.directory(output)
    let results = output.appendingPathComponent("results", isDirectory: true)
    let chunks = output.appendingPathComponent("chunks", isDirectory: true)
    try QualityArtifacts.directory(results)
    try QualityArtifacts.directory(chunks)
    var run = QualityRun(
      runId: UUID().uuidString, manifestSha256: manifestHash, config: config,
      configSha256: QualityArtifacts.hash(configData),
      ledger: manifest.fixtures.map { .init(id: $0.id) })
    let ledger = output.appendingPathComponent("run.json")
    try persist(run, to: ledger, replace: false)
    for index in manifest.fixtures.indices {
      let fixture = manifest.fixtures[index]
      run.status = "running"
      run.ledger[index].status = "running"
      try persist(run, to: ledger)
      var lease: ModelLease?
      var spool: AudioSpool?
      var plan: [ChunkRecord] = []
      var assembler = TranscriptAssembler()
      var status = "failed"
      var reasons: [String] = []
      var seconds = 0.0
      let wallClock = ContinuousClock()
      let wallStart = wallClock.now
      var peakRSS = ResourceRecorder.residentBytes()
      let buffers = ChunkBufferRecorder()
      do {
        let activeSpool = try AudioSpool(rootDirectory: output.appendingPathComponent("spool"))
        spool = activeSpool
        let count = try Self.fill(activeSpool, fixture: fixture, root: fixtureRoot)
        let active = try await lifecycle.acquire(session: UUID())
        lease = active
        var planner = ChunkPlanner(
          overlapSamples: strategy.overlapSamples,
          silenceSearchStart: strategy.silenceSearchStart,
          maximumSpeechProbability: strategy.maximumSpeechProbability)
        if strategy.silenceSearchStart > 0, let silence {
          planner.silenceProbe = { start, length in
            let region = try activeSpool.readWindow(
              startSample: start, count: min(length, count - start))
            await buffers.observePlanner(region.count)
            return try await silence(region, start)
          }
        }
        try planner.validate()
        var previous: ChunkPlanner.Chunk?
        let clock = ContinuousClock()
        while let chunk = try await planner.next(after: previous, sampleCount: count) {
          let samples = try activeSpool.readWindow(
            startSample: chunk.sampleStart, count: chunk.sampleCount)
          if let current = ResourceRecorder.residentBytes() {
            peakRSS = max(peakRSS ?? 0, current)
          }
          await recorder.expect(sampleStart: chunk.sampleStart)
          let start = clock.now
          _ = try await lifecycle.transcribe(active, samples: samples)
          let elapsed = start.duration(to: clock.now).components
          seconds += Double(elapsed.seconds) + Double(elapsed.attoseconds) * 1e-18
          if let current = ResourceRecorder.residentBytes() {
            peakRSS = max(peakRSS ?? 0, current)
          }
          plan.append(
            .init(
              sequence: plan.count, sampleStart: chunk.sampleStart,
              sampleCount: chunk.sampleCount, boundary: chunk.boundary))
          previous = chunk
        }
        try await lifecycle.finish(active)
        await lifecycle.releaseIfIdle(generation: active.generation)
        lease = nil
        status = "completed"
      } catch {
        status = "failed"
        reasons = ["decode_failed"]
        if let lease { await lifecycle.cancelAndJoin(lease) }
      }
      try spool?.cleanup()
      let windows = await recorder.drain()
      let plannerBuffer = await buffers.drain()
      if let processPeak = Self.peakResidentBytes() {
        peakRSS = max(peakRSS ?? 0, processPeak)
      }
      let wallDuration = wallStart.duration(to: wallClock.now).components
      let wallSeconds = Double(wallDuration.seconds) + Double(wallDuration.attoseconds) * 1e-18
      if status == "completed" {
        for window in windows { assembler.append(try QualityAssemblyReplay.mappedWindow(window)) }
        if windows.last.map({ $0.sampleStart + $0.evidence.samples }) != fixture.numSamples {
          assembler.stop(.failed)
        }
        reasons = assembler.reasons.map(\.rawValue)
        status = assembler.incomplete ? "failed" : "completed"
      } else {
        assembler.stop(.failed)
        reasons = ["decode_failed"]
      }
      let raw = windows.map(\.text).joined(separator: "\n")
      var normalized = QualityStage(unavailable: "normalization_not_requested")
      var normalizationSeconds: Double?
      var incomplete = assembler.incomplete
      if strategy.normalize, status == "completed" {
        let start = wallClock.now
        let outcome = TranscriptNormalizer(vocabulary: .empty).normalize(assembler.text)
        let elapsed = start.duration(to: wallClock.now).components
        normalizationSeconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) * 1e-18
        normalized = .init(text: outcome.text, identity: TranscriptNormalizer.version)
        for reason in outcome.reasons.map(\.rawValue) where !reasons.contains(reason) {
          reasons.append(reason)
        }
        incomplete = incomplete || !outcome.reasons.isEmpty
      }
      let result = QualityResult(
        id: fixture.id, status: status, incomplete: incomplete,
        reasons: reasons, windows: windows,
        stages: [
          "raw": .init(text: raw, identity: "sdk_windows_lf_overlap"),
          "assembled": .init(text: assembler.text, identity: TranscriptAssembler.version),
          "normalized": normalized,
        ],
        measurements: [
          "chunk_count": .init(value: Double(plan.count), unit: "count", reason: "measured"),
          "recognition_seconds": .init(value: seconds, unit: "seconds", reason: "measured"),
          "normalization_seconds": normalizationSeconds.map {
            .init(value: $0, unit: "seconds", reason: "measured")
          } ?? .init(unit: "seconds", reason: "not_requested"),
          "wall_seconds": .init(value: wallSeconds, unit: "seconds", reason: "measured"),
          "maximum_chunk_samples": .init(
            value: Double(plan.map(\.sampleCount).max() ?? 0), unit: "samples",
            reason: "measured"),
          "rss": peakRSS.map {
            .init(value: Double($0), unit: "bytes", reason: "measured_process_peak")
          }
            ?? .init(unit: "bytes", reason: "measurement_unavailable"),
          "maximum_audio_buffer_samples": .init(
            value: Double(max(plan.map(\.sampleCount).max() ?? 0, plannerBuffer)),
            unit: "samples", reason: "measured"),
          "maximum_planner_buffer_samples": .init(
            value: Double(plannerBuffer), unit: "samples", reason: "measured"),
          "queue_peak": .init(unit: "count", reason: "not_measured"),
        ])
      let data = try QualityArtifacts.encode(result)
      try QualityArtifacts.write(
        data, to: results.appendingPathComponent(fixture.id + ".json"), replace: false)
      let audit = Self.audit(assembler)
      try QualityArtifacts.write(
        QualityArtifacts.encode(
          Diagnostics(
            id: fixture.id, strategy: strategy.id, chunks: plan,
            overlapSamples: strategy.overlapSamples, seams: assembler.seams,
            conflictingEdgeTokens: assembler.seams.filter { $0.basis == "conflicting_edge_token" }
              .count,
            uncertainSeams: assembler.seams.filter { $0.decision == "uncertain_join" }.count,
            incomplete: assembler.incomplete, reasons: reasons, recognitionSeconds: seconds,
            wallSeconds: wallSeconds, peakRSSBytes: peakRSS,
            maximumAudioBufferSamples: max(plan.map(\.sampleCount).max() ?? 0, plannerBuffer),
            maximumPlannerBufferSamples: plannerBuffer,
            silenceBoundaries: plan.filter { $0.boundary == "vad_selected" }.count,
            fallbackBoundaries: plan.filter { $0.boundary == "nominal_fallback" }.count,
            discardedLexicalWords: audit.discarded,
            unevidencedLexicalDiscards: audit.unevidenced,
            preAnchorLexicalDiscards: audit.preAnchor,
            maximumDiscardedOnsetDelta: audit.maximumDelta)),
        to: chunks.appendingPathComponent(fixture.id + ".json"), replace: false)
      run.ledger[index].resultSha256 = QualityArtifacts.hash(data)
      run.ledger[index].status = status
      try persist(run, to: ledger)
    }
    run.status = "complete"
    try persist(run, to: ledger)
  }

  private static func audit(_ assembler: TranscriptAssembler) -> (
    discarded: Int, unevidenced: Int, preAnchor: Int, maximumDelta: Double
  ) {
    var discarded = 0
    var unevidenced = 0
    var preAnchor = 0
    var maximum = 0.0
    for seam in assembler.seams where seam.decision == "proven_overlap" {
      discarded += seam.discardedLexicalWords
      unevidenced += seam.unevidencedLexicalDiscards
      preAnchor += seam.preAnchorLexicalDiscards
      maximum = max(maximum, seam.maximumDiscardedOnsetDelta)
    }
    return (discarded, unevidenced, preAnchor, maximum)
  }

  private static func peakResidentBytes() -> UInt64? {
    var usage = rusage()
    guard getrusage(RUSAGE_SELF, &usage) == 0, usage.ru_maxrss >= 0 else { return nil }
    return UInt64(usage.ru_maxrss)
  }

  private static func fill(_ spool: AudioSpool, fixture: QualityFixture, root: URL) throws -> Int {
    let audio = try AVAudioFile(
      forReading: fixture.audioURL(root: root), commonFormat: .pcmFormatFloat32,
      interleaved: false)
    guard audio.processingFormat.sampleRate == 16_000, audio.processingFormat.channelCount == 1,
      audio.length == fixture.numSamples,
      let buffer = AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: 1600)
    else { throw QualityArtifacts.Failure.invalid }
    var count = 0
    while count < fixture.numSamples {
      try audio.read(
        into: buffer, frameCount: AVAudioFrameCount(min(1600, fixture.numSamples - count)))
      guard buffer.frameLength > 0, let channel = buffer.floatChannelData?[0] else {
        throw QualityArtifacts.Failure.invalid
      }
      try spool.append(
        normalizedSamples: Array(
          UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength))))
      count += Int(buffer.frameLength)
    }
    return count
  }

  private func persist(_ run: QualityRun, to url: URL, replace: Bool = true) throws {
    try QualityArtifacts.write(
      QualityArtifacts.encode(run, limit: QualityArtifacts.small), to: url, replace: replace,
      limit: QualityArtifacts.small)
  }
}
