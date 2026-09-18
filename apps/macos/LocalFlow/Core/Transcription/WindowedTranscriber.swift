import Foundation

struct WindowTextAssembler {
  private(set) var text = ""
  private(set) var incomplete = false
  private var tokens: [TranscriptionToken] = []
  private var hasWindow = false

  mutating func append(_ window: TranscriptionWindow, offset: Double) throws {
    guard offset.isFinite, offset >= 0,
      window.text.utf8.count <= 65_536, window.tokens.count <= 16_384,
      window.tokens.reduce(0, { min(65_537, $0 + min(65_537, $1.text.utf8.count)) }) <= 65_536,
      window.tokens.allSatisfy({
        $0.start.isFinite && $0.end.isFinite && $0.start >= 0 && $0.end >= $0.start
      })
    else { throw DictationFailure.invalidResult }
    let incoming = window.tokens.map {
      TranscriptionToken(text: $0.text, start: $0.start + offset, end: $0.end + offset)
    }
    if !hasWindow {
      text = window.text
      tokens = incoming
      hasWindow = true
      return
    }
    var combined = tokens
    var uncertain = false
    if !tokens.isEmpty, !incoming.isEmpty {
      // Time agreement disambiguates repetitions; text-only suffix matching does not.
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
        combined = Array(tokens[..<old]) + incoming[new...]
      } else {
        uncertain = true
        let end = tokens.last?.end ?? offset
        combined += incoming.filter { $0.start >= end }
      }
    } else {
      // No timing evidence is never an ordinary complete seam.
      uncertain = true
    }
    let next: String
    if tokens.isEmpty || incoming.isEmpty {
      next = [text, window.text].filter { !$0.isEmpty }.joined(separator: " ")
    } else {
      next = combined.map(\.text).joined(separator: " ")
    }
    guard next.utf8.count <= 65_536, combined.count <= 16_384 else {
      throw DictationFailure.invalidResult
    }
    text = next
    tokens = combined
    incomplete = incomplete || uncertain
  }
}

struct TranscriptionResult: Sendable {
  let text: String
  let incomplete: Bool
  var detail: TranscriptionQualityDetail? = nil
  var rawWindows: [TranscriptionQualityDetail.RawWindow] = []
  var completionReasons: [TranscriptionQualityDetail.CompletionReason] = []
  var needsNormalization = false

  /// The session's admission-time snapshot decides V001; later edits never reach it.
  func normalizedForDelivery(vocabulary: VocabularySnapshot = .empty) -> Self {
    guard needsNormalization, let detail else { return self }
    let start = ProcessInfo.processInfo.systemUptime
    let normalized = TranscriptNormalizer(vocabulary: vocabulary).normalize(detail.assembledText)
    do {
      let updated = try detail.normalized(
        normalized,
        duration: ProcessInfo.processInfo.systemUptime - start, vocabulary: vocabulary)
      return Self(
        text: normalized.text, incomplete: incomplete || updated.incomplete,
        detail: updated, rawWindows: rawWindows, completionReasons: updated.completionReasons)
    } catch {
      // Keep the entire admitted envelope if formatting metadata cannot be committed.
      // The coordinator adds the terminal failure to its reserved diagnostic space.
      return Self(
        text: text, incomplete: true, detail: detail,
        rawWindows: rawWindows, completionReasons: [.init(.normalizationCapacity)])
    }
  }
}

protocol DictationTranscribing: Sendable {
  func transcribe(spool: AudioSpool, lease: ModelLease, sampleCount: Int) async
    -> TranscriptionResult
}

struct WindowedTranscriber: DictationTranscribing {
  enum Profile: Sendable { case production, historical }
  static let productionAssemblyVersion = "contiguous_fixed239360_preserve_v1"
  let lifecycle: ModelLifecycleCoordinator
  var profile: Profile = .production
  var identity = TranscriptionPipelineIdentity()
  var evidenceObserver: (@Sendable (Int, Int, Bool) async throws -> Void)? = nil
  func transcribe(spool: AudioSpool, lease: ModelLease, sampleCount: Int) async
    -> TranscriptionResult
  {
    if profile == .production {
      return await transcribeProduction(spool: spool, lease: lease, sampleCount: sampleCount)
    }
    var assembly = WindowTextAssembler()
    var admission = RecognitionAdmission()
    var reasons: [TranscriptionQualityDetail.CompletionReason] = []
    guard (0...2_880_000).contains(sampleCount) else {
      return TranscriptionResult(
        text: "", incomplete: true, completionReasons: [.init(.invalidResult)])
    }
    var offset = 0
    var failed = false
    while offset < sampleCount {
      do {
        try Task.checkCancellation()
        let count = min(239_360, sampleCount - offset)
        let samples = try spool.readWindow(startSample: offset, count: count)
        let result = try await lifecycle.transcribe(lease, samples: samples)
        try admission.append(result, sampleStart: offset, sampleCount: count)
        try assembly.append(result, offset: Double(offset) / 16_000)
        try await evidenceObserver?(offset, count, assembly.incomplete)
        if offset + count == sampleCount { break }
        offset += 239_360 - 32_000
      } catch {
        let code: TranscriptionQualityDetail.CompletionReason.Code
        if let failure = error as? RecognitionAdmission.Failure {
          code = failure.reason
        } else if error is CancellationError || error as? DictationFailure == .cancelled {
          code = .cancelled
        } else if error as? DictationFailure == .invalidResult {
          code = .invalidResult
        } else {
          code = .failed
        }
        reasons.append(.init(code, window: admission.windows.count))
        failed = true
        break
      }
    }
    if assembly.incomplete { reasons.append(.init(.uncertainJoin)) }
    return TranscriptionResult(
      text: assembly.text, incomplete: failed || assembly.incomplete,
      rawWindows: admission.windows, completionReasons: reasons)
  }

  private func transcribeProduction(spool: AudioSpool, lease: ModelLease, sampleCount: Int) async
    -> TranscriptionResult
  {
    guard (0...2_880_000).contains(sampleCount) else {
      return .init(text: "", incomplete: true, completionReasons: [.init(.invalidResult)])
    }
    var assembly = TranscriptAssembler()
    // Reserve fixed identity, seam summaries and future terminal diagnostics before raw admission.
    var admission = RecognitionAdmission(strideSamples: 239_360, processingReserveBytes: 24_576)
    var reasons: [TranscriptionQualityDetail.CompletionReason] = []
    var emptyWindows: [Int] = []
    var recognitionSeconds = 0.0
    var assemblySeconds = 0.0
    var retained: TranscriptionQualityDetail
    do {
      retained = try TranscriptionQualityDetail(
        rawWindows: [], assembledText: "", normalizedText: "",
        assemblyVersion: Self.productionAssemblyVersion, normalizationVersion: "identity-v1",
        provenance: identity.provenance(sampleCount: sampleCount, recognition: 0, assembly: 0),
        seams: [])
    } catch {
      return .init(text: "", incomplete: true, completionReasons: [.init(.invalidResult)])
    }
    var offset = 0
    while offset < sampleCount {
      do {
        try Task.checkCancellation()
        let count = min(239_360, sampleCount - offset)
        let samples = try spool.readWindow(startSample: offset, count: count)
        let began = ProcessInfo.processInfo.systemUptime
        let window: TranscriptionWindow
        do {
          window = try await lifecycle.transcribe(lease, samples: samples)
        } catch {
          recognitionSeconds += ProcessInfo.processInfo.systemUptime - began
          throw error
        }
        recognitionSeconds += ProcessInfo.processInfo.systemUptime - began
        try admission.append(window, sampleStart: offset, sampleCount: count)
        let assemblyBegan = ProcessInfo.processInfo.systemUptime
        assembly.append(
          .init(
            sequence: admission.windows.count - 1, sampleStart: offset,
            sampleCount: count, paddedSampleCount: max(4_800, count), text: window.text, tokens: nil
          ))
        assemblySeconds += ProcessInfo.processInfo.systemUptime - assemblyBegan
        if window.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
          emptyWindows.append(admission.windows.count - 1)
        }
        // Admit into the retained envelope only after the entire detail validates.
        // If framing/identity ever exceeds its budget, keep the prior complete envelope.
        retained = try TranscriptionQualityDetail(
          rawWindows: admission.windows,
          assembledText: assembly.text, normalizedText: assembly.text,
          assemblyVersion: Self.productionAssemblyVersion, normalizationVersion: "identity-v1",
          provenance: identity.provenance(
            sampleCount: sampleCount,
            recognition: recognitionSeconds, assembly: assemblySeconds),
          completionReasons: reasons, seams: assembly.seams)
        if assembly.stopped {
          reasons.append(.init(.outputCapacity, window: admission.windows.count - 1))
          break
        }
        try await evidenceObserver?(offset, count, assembly.incomplete)
        offset += count
      } catch {
        let code: TranscriptionQualityDetail.CompletionReason.Code
        if let failure = error as? RecognitionAdmission.Failure {
          code = failure.reason
        } else if error is TranscriptionQualityDetail.Failure {
          code = .metadataCapacity
        } else if error is CancellationError || error as? DictationFailure == .cancelled {
          code = .cancelled
        } else if error as? DictationFailure == .invalidResult {
          code = .invalidResult
        } else {
          code = .failed
        }
        reasons.append(.init(code, window: retained.rawWindows.count))
        break
      }
    }
    if !retained.assembledText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      reasons += emptyWindows.map { .init(.emptyRecognition, window: $0) }
    }
    if Task.isCancelled { reasons.append(.init(.cancelled)) }
    for reason in assembly.reasons {
      reasons.append(
        .init(
          TranscriptionQualityDetail.CompletionReason.Code(rawValue: reason.rawValue) ?? .failed))
    }
    do {
      let detail = try TranscriptionQualityDetail(
        rawWindows: retained.rawWindows,
        assembledText: retained.assembledText, normalizedText: retained.assembledText,
        assemblyVersion: Self.productionAssemblyVersion, normalizationVersion: "identity-v1",
        provenance: identity.provenance(
          sampleCount: sampleCount,
          recognition: recognitionSeconds, assembly: assemblySeconds),
        completionReasons: reasons, seams: retained.seams)
      return .init(
        text: detail.assembledText, incomplete: detail.incomplete, detail: detail,
        rawWindows: detail.rawWindows, completionReasons: detail.completionReasons,
        needsNormalization: true)
    } catch {
      // Retain the valid full envelope, never downgrade accepted raw evidence to a legacy row.
      return .init(
        text: retained.assembledText, incomplete: true, detail: retained,
        rawWindows: retained.rawWindows, completionReasons: [.init(.metadataCapacity)])
    }
  }

}

/// Whole-window evidence admission with explicit geometry and processing metadata headroom.
struct RecognitionAdmission {
  struct Failure: Error {
    let reason: TranscriptionQualityDetail.CompletionReason.Code
  }
  let strideSamples: Int
  let processingReserveBytes: Int
  init(strideSamples: Int = 207_360, processingReserveBytes: Int = 0) {
    self.strideSamples = strideSamples
    self.processingReserveBytes = processingReserveBytes
  }
  private(set) var windows: [TranscriptionQualityDetail.RawWindow] = []
  private var rawBytes = 0
  private var metadataBytes = 2

  mutating func append(_ result: TranscriptionWindow, sampleStart: Int, sampleCount: Int) throws {
    guard [207_360, 239_360].contains(strideSamples),
      (0...24_576).contains(processingReserveBytes)
    else { throw Failure(reason: .invalidResult) }
    guard windows.count < 14 else { throw Failure(reason: .windowCapacity) }
    guard result.text.utf8.count <= 65_536 - rawBytes else { throw Failure(reason: .rawCapacity) }
    guard (1...239_360).contains(sampleCount), sampleStart >= 0,
      sampleStart <= 2_880_000 - sampleCount, sampleStart == windows.count * strideSamples,
      result.tokens.count <= 16_384,
      result.tokens.reduce(0, { min(65_537, $0 + min(65_537, $1.text.utf8.count)) }) <= 65_536,
      result.tokens.allSatisfy({
        $0.start.isFinite && $0.end.isFinite && $0.start >= 0 && $0.end >= $0.start
      })
    else { throw Failure(reason: .invalidResult) }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    var timings: [TranscriptionQualityDetail.TimingToken]?
    var validation: TranscriptionQualityDetail.TimingValidation = .unavailable
    // Prevent a large escaped raw string before allocating serialized metadata.
    var estimate = result.text.utf8.reduce(0) { total, byte in
      total + (byte < 32 ? 5 : ((byte == 34 || byte == 92) ? 1 : 0))
    }
    let budget =
      TranscriptionQualityDetail.maximumMetadataBytes
      - TranscriptionQualityDetail.terminalReserveBytes - processingReserveBytes - metadataBytes
    let assembledEscaping = processingReserveBytes > 0 ? estimate : 0
    estimate += assembledEscaping
    guard estimate <= budget else { throw Failure(reason: .metadataCapacity) }
    if let evidence = result.evidence {
      guard evidence.text.utf8.elementsEqual(result.text.utf8), evidence.samples == sampleCount,
        evidence.paddedSamples == max(4_800, sampleCount), evidence.tokens.count <= 16_384,
        evidence.timingsAvailable || evidence.tokens.isEmpty,
        evidence.tokens.reduce(0, { min(65_537, $0 + min(65_537, $1.text.utf8.count)) }) <= 65_536
      else { throw Failure(reason: .invalidResult) }
      // Check each token's serialized cost before allocating the second token array.
      for token in evidence.tokens {
        estimate += try encoder.encode(token).count + 8
        guard estimate <= budget else { throw Failure(reason: .metadataCapacity) }
      }
      if evidence.timingsAvailable {
        timings = try evidence.tokens.map {
          .init(text: $0.text, start: try Self.timing($0.start), end: try Self.timing($0.end))
        }
        validation = .valid
        var previousStart = -Double.infinity
        for token in timings ?? [] {
          guard let start = token.start.seconds, let end = token.end.seconds,
            start >= 0, start >= previousStart, end >= start, end <= Double(sampleCount) / 16_000
          else {
            validation = .invalid
            continue
          }
          previousStart = start
        }
      }
    }
    let window = TranscriptionQualityDetail.RawWindow(
      sequence: windows.count, sampleStart: sampleStart,
      sampleCount: sampleCount, paddedSampleCount: max(4_800, sampleCount), text: result.text,
      timings: timings, timingValidation: validation)
    let bytes = try encoder.encode(window).count - result.text.utf8.count + 1 + assembledEscaping
    guard bytes <= budget else { throw Failure(reason: .metadataCapacity) }
    windows.append(window)
    rawBytes += result.text.utf8.count
    metadataBytes += bytes
  }

  private static func timing(_ evidence: RecognitionEvidence.Timing) throws
    -> TranscriptionQualityDetail.Timing
  {
    if let value = evidence.value, value.isFinite, evidence.invalid == nil { return .init(value) }
    guard evidence.value == nil else { throw Failure(reason: .invalidResult) }
    switch evidence.invalid {
    case "nan": return .init(.nan)
    case "positive_infinity": return .init(.infinity)
    case "negative_infinity": return .init(-.infinity)
    default: throw Failure(reason: .invalidResult)
    }
  }
}
