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
}

struct WindowedTranscriber: Sendable {
  let lifecycle: ModelLifecycleCoordinator
  func transcribe(spool: AudioSpool, lease: ModelLease, sampleCount: Int) async
    -> TranscriptionResult
  {
    var assembly = WindowTextAssembler()
    var offset = 0
    var failed = false
    while offset < sampleCount {
      do {
        try Task.checkCancellation()
        let count = min(239_360, sampleCount - offset)
        let samples = try spool.readWindow(startSample: offset, count: count)
        let result = try await lifecycle.transcribe(lease, samples: samples)
        try assembly.append(result, offset: Double(offset) / 16_000)
        if offset + count == sampleCount { break }
        offset += 239_360 - 32_000
      } catch {
        failed = true
        break
      }
    }
    return TranscriptionResult(text: assembly.text, incomplete: failed || assembly.incomplete)
  }
}
