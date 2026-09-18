import FluidAudio
import Foundation

@testable import LocalFlow

/// Offline replay uses the frozen SDK evidence, never a second recognition pass.
/// The pinned SDK word builder is used without its runtime's timing clamping.
enum QualityAssemblyReplay {
  struct Diagnostics: Codable {
    let seams: [TranscriptAssembler.Seam]
    let sourceSpans: [TranscriptAssembler.SourceSpan]
  }
  static func mappedWindow(_ window: QualityResult.Window) throws -> TranscriptAssembler.Window {
    let evidence = window.evidence
    guard window.text.utf8.count <= 65_536, evidence.tokens.count <= 16_384,
      window.text.utf8.elementsEqual(evidence.text.utf8),
      window.sha256 == QualityArtifacts.hash(Data(window.text.utf8))
    else { throw QualityArtifacts.Failure.invalid }
    var bytes = 0
    var previousStart = 0.0
    var previousEnd = 0.0
    var valid = evidence.timingsAvailable
    for token in evidence.tokens {
      guard token.text.utf8.count <= 65_536 - bytes else { throw QualityArtifacts.Failure.capacity }
      bytes += token.text.utf8.count
      guard let start = token.start.value, let end = token.end.value,
        token.start.invalid == nil, token.end.invalid == nil,
        start.isFinite, end.isFinite, start >= previousStart, end >= previousEnd,
        start >= 0, end >= start, end <= Double(evidence.samples) / 16_000
      else {
        valid = false
        continue
      }
      previousStart = start
      previousEnd = end
    }
    let words: [TranscriptionToken]? =
      valid
      ? buildWordTimings(
        from: evidence.tokens.map {
          TokenTiming(
            token: $0.text, tokenId: 0, startTime: $0.start.value!,
            endTime: $0.end.value!, confidence: 0)
        }
      ).map { .init(text: $0.word, start: $0.startTime, end: $0.endTime) } : nil
    return .init(
      sequence: window.sequence, sampleStart: window.sampleStart,
      sampleCount: evidence.samples, paddedSampleCount: evidence.paddedSamples,
      text: window.text,
      tokens: words.flatMap { TranscriptSourceMapper.map(text: window.text, words: $0) })
  }

  static func run(manifestURL: URL, baseline: URL, output: URL) throws {
    let manifest = try QualityArtifacts.read(QualityManifest.self, from: manifestURL)
    let original = try QualityArtifacts.read(
      QualityRun.self, from: baseline.appendingPathComponent("run.json"))
    guard original.status == "complete", manifest.fixtures.count <= 256,
      original.manifestSha256 == (try QualityArtifacts.hashFile(manifestURL)),
      original.ledger.map(\.id) == manifest.fixtures.map(\.id)
    else { throw QualityArtifacts.Failure.invalid }
    try QualityArtifacts.reserve(count: manifest.fixtures.count)
    var config = original.config
    config["assembly"] = TranscriptAssembler.version
    config["assembly_mapping"] = "exact_source_unclamped_sdk_words_v1"
    var run = QualityRun(
      runId: UUID().uuidString, manifestSha256: original.manifestSha256,
      config: config, configSha256: QualityArtifacts.hash(try QualityArtifacts.encode(config)),
      ledger: manifest.fixtures.map { .init(id: $0.id) })
    try QualityArtifacts.directory(output)
    try QualityArtifacts.directory(output.appendingPathComponent("results"))
    try QualityArtifacts.directory(output.appendingPathComponent("seams"))
    func persist(_ replace: Bool) throws {
      var object =
        try JSONSerialization.jsonObject(with: QualityArtifacts.encode(run)) as! [String: Any]
      object["changed_factors"] = ["assembly", "assembly_mapping"]
      let data = try JSONSerialization.data(
        withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
      try QualityArtifacts.write(
        data, to: output.appendingPathComponent("run.json"), replace: replace,
        limit: QualityArtifacts.small)
    }
    try persist(false)
    for (index, row) in original.ledger.enumerated() {
      try QualityArtifacts.validateID(row.id)
      let source = baseline.appendingPathComponent("results/" + row.id + ".json")
      guard try QualityArtifacts.hashFile(source) == row.resultSha256 else {
        throw QualityArtifacts.Failure.invalid
      }
      var result = try QualityArtifacts.read(
        QualityResult.self, from: source, limit: QualityArtifacts.artifact)
      guard result.id == row.id, result.windows.count <= 32 else {
        throw QualityArtifacts.Failure.invalid
      }
      run.status = "running"
      run.ledger[index].status = "running"
      try persist(true)
      var assembler = TranscriptAssembler()
      for window in result.windows { assembler.append(try mappedWindow(window)) }
      // Historical assembly incompleteness is being reevaluated. Actual recognition failures persist.
      if result.status == "cancelled" { assembler.stop(.cancelled) }
      if result.reasons.contains(where: { $0 != "historical_pipeline_incomplete" })
        || result.windows.last.map({ $0.sampleStart + $0.evidence.samples })
          != manifest.fixtures[index].numSamples
      {
        assembler.stop(.failed)
      }
      result.stages["assembled"] = .init(
        text: assembler.text, identity: TranscriptAssembler.version)
      result.incomplete = assembler.incomplete
      result.reasons = assembler.reasons.map(\.rawValue)
      result.status =
        result.status == "cancelled" ? "cancelled" : (assembler.incomplete ? "failed" : "completed")
      let data = try QualityArtifacts.encode(result)
      try QualityArtifacts.write(
        data, to: output.appendingPathComponent("results/" + row.id + ".json"), replace: false)
      try QualityArtifacts.write(
        QualityArtifacts.encode(
          Diagnostics(seams: assembler.seams, sourceSpans: assembler.sourceSpans)),
        to: output.appendingPathComponent("seams/" + row.id + ".json"), replace: false)
      run.ledger[index].status = result.status
      run.ledger[index].resultSha256 = QualityArtifacts.hash(data)
      try persist(true)
    }
    run.status = "complete"
    try persist(true)
  }
}

/// Step 1 diagnostic: reproduce the pre-T015 production assembly from the same frozen evidence.
/// This replays the historical `WindowTextAssembler` (word timings + time-anchored splice) so the
/// T014/T015 discrepancy is proven rather than inferred. It is evaluation-only and never shipped.
extension QualityAssemblyReplay {
  struct LegacySeam: Codable {
    let window: Int
    let decision: String
    let anchorOldIndex: Int?
    let anchorNewIndex: Int?
    let droppedNewTokens: Int
  }
  struct LegacyDiagnostic: Codable {
    let id: String
    let windowCount: Int
    let windowTexts: [String]
    let windowSampleStarts: [Int]
    let windowSampleCounts: [Int]
    let windowWordTimings: [[String]]
    let legacyText: String
    let legacySha256: String
    let legacyIncomplete: Bool
    let legacySeams: [LegacySeam]
    let legacyTextIsTokenJoined: Bool
    let baselineAssembledSha256: String?
    let reproducesBaseline: Bool
    let candidateText: String?
    let candidateSha256: String?
    let candidateSeams: [TranscriptAssembler.Seam]
    let candidateIncomplete: Bool?
    let reference: String
  }

  /// Rebuild the exact `TranscriptionWindow` the old runtime produced for this evidence.
  static func legacyWindow(_ window: QualityResult.Window) throws -> TranscriptionWindow {
    let evidence = window.evidence
    let timings = try buildWordTimings(
      from: evidence.tokens.map {
        TokenTiming(
          token: $0.text, tokenId: 0, startTime: $0.start.value ?? .nan,
          endTime: $0.end.value ?? .nan, confidence: 0)
      }
    ).map { timing in
      try FluidAudioRuntime.clampedToken(
        text: timing.word, start: timing.startTime, end: timing.endTime,
        sampleCount: evidence.samples)
    }
    return TranscriptionWindow(text: evidence.text, tokens: Array(timings))
  }

  /// Mirror of the historical `WindowTextAssembler` seam decision, for classification only.
  private static func legacySeams(_ windows: [TranscriptionWindow], starts: [Int]) -> (
    [LegacySeam], Bool
  ) {
    var seams: [LegacySeam] = []
    var tokens: [TranscriptionToken] = []
    var joined = false
    for (index, window) in windows.enumerated() {
      let offset = Double(starts[index]) / 16_000
      let incoming = window.tokens.map {
        TranscriptionToken(text: $0.text, start: $0.start + offset, end: $0.end + offset)
      }
      if index == 0 {
        tokens = incoming
        continue
      }
      if !tokens.isEmpty, !incoming.isEmpty {
        joined = true
        var anchor: (Int, Int)?
        for old in tokens.indices where tokens[old].start >= offset - 0.16 {
          let matches = incoming.indices.filter {
            incoming[$0].text == tokens[old].text
              && abs(incoming[$0].start - tokens[old].start) <= 0.16
          }
          if matches.count == 1 {
            anchor = (old, matches[0])
            break
          }
        }
        if let (old, new) = anchor {
          seams.append(
            .init(
              window: index, decision: "time_anchored_splice", anchorOldIndex: old,
              anchorNewIndex: new, droppedNewTokens: new))
          tokens = Array(tokens[..<old]) + incoming[new...]
        } else {
          let end = tokens.last?.end ?? offset
          let kept = incoming.filter { $0.start >= end }
          seams.append(
            .init(
              window: index, decision: "unproven_time_trim", anchorOldIndex: nil,
              anchorNewIndex: nil, droppedNewTokens: incoming.count - kept.count))
          tokens += kept
        }
      } else {
        seams.append(
          .init(
            window: index, decision: "no_timing_concatenation", anchorOldIndex: nil,
            anchorNewIndex: nil, droppedNewTokens: 0))
        tokens = tokens.isEmpty ? incoming : tokens
      }
    }
    return (seams, joined)
  }

  static func diagnose(manifestURL: URL, baseline: URL, candidate: URL, output: URL) throws {
    let manifest = try QualityArtifacts.read(QualityManifest.self, from: manifestURL)
    let original = try QualityArtifacts.read(
      QualityRun.self, from: baseline.appendingPathComponent("run.json"))
    guard original.ledger.map(\.id) == manifest.fixtures.map(\.id) else {
      throw QualityArtifacts.Failure.invalid
    }
    try QualityArtifacts.directory(output)
    var reproduced = 0
    var changed: [String] = []
    for (index, row) in original.ledger.enumerated() {
      try QualityArtifacts.validateID(row.id)
      let old = try QualityArtifacts.read(
        QualityResult.self, from: baseline.appendingPathComponent("results/" + row.id + ".json"),
        limit: QualityArtifacts.artifact)
      let newResult = try? QualityArtifacts.read(
        QualityResult.self, from: candidate.appendingPathComponent("results/" + row.id + ".json"),
        limit: QualityArtifacts.artifact)
      let newSeams = try? QualityArtifacts.read(
        Diagnostics.self, from: candidate.appendingPathComponent("seams/" + row.id + ".json"),
        limit: QualityArtifacts.artifact)
      var assembly = WindowTextAssembler()
      var windows: [TranscriptionWindow] = []
      var failed = false
      for window in old.windows {
        do {
          let built = try legacyWindow(window)
          windows.append(built)
          try assembly.append(built, offset: Double(window.sampleStart) / 16_000)
        } catch {
          failed = true
          break
        }
      }
      let (seams, joined) = legacySeams(windows, starts: old.windows.map(\.sampleStart))
      let hash = QualityArtifacts.hash(Data(assembly.text.utf8))
      let baselineHash = old.stages["assembled"]?.sha256
      let matches = !failed && hash == baselineHash
      if matches { reproduced += 1 }
      let candidateHash = newResult?.stages["assembled"]?.sha256
      if candidateHash != baselineHash { changed.append(row.id) }
      let record = LegacyDiagnostic(
        id: row.id, windowCount: old.windows.count, windowTexts: old.windows.map(\.text),
        windowSampleStarts: old.windows.map(\.sampleStart),
        windowSampleCounts: old.windows.map { $0.evidence.samples },
        windowWordTimings: windows.map { window in
          window.tokens.map { "\($0.text)@\($0.start)-\($0.end)" }
        },
        legacyText: assembly.text, legacySha256: hash,
        legacyIncomplete: failed || assembly.incomplete,
        legacySeams: seams, legacyTextIsTokenJoined: joined,
        baselineAssembledSha256: baselineHash, reproducesBaseline: matches,
        candidateText: newResult?.stages["assembled"]?.text, candidateSha256: candidateHash,
        candidateSeams: newSeams?.seams ?? [], candidateIncomplete: newResult?.incomplete,
        reference: manifest.fixtures[index].reference)
      try QualityArtifacts.write(
        QualityArtifacts.encode(record),
        to: output.appendingPathComponent(row.id + ".json"), replace: false)
    }
    try QualityArtifacts.write(
      QualityArtifacts.encode(
        [
          "fixtures": original.ledger.count, "legacy_reproduced": reproduced,
          "changed_by_candidate": changed.count,
        ]),
      to: output.appendingPathComponent("summary.json"), replace: false)
  }
}
