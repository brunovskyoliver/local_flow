import Foundation

struct StreamPosition: Sendable {
  let stretchSequence: Int
  let stretchBaseMs: Int64
  let tracks: AnalysisTracks
  var ordinal: Int = 0
}

struct TranscriptSegmenter: Sendable {
  static let version = "segmenter_gap0.8_punct_v1"
  static let gapSeconds = 0.8
  static let minimumWordsBeforePunctuationCut = 3
  static let maximumWords = 40
  private let normalizer: TranscriptNormalizer
  init(vocabulary: VocabularySnapshot = .empty) { normalizer = .init(vocabulary: vocabulary) }

  struct Output: Sendable {
    var segments: [TranscriptSegmentDraft] = []
    var normalizationReasonCounts: [String: Int] = [:]
  }

  func segments(window: AssembledWindow, base: StreamPosition) -> [TranscriptSegmentDraft] {
    process(window: window, base: base).segments
  }

  func process(window: AssembledWindow, base: StreamPosition) -> Output {
    guard !window.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return .init()
    }
    let source = window.window
    let start = base.stretchBaseMs + Int64(source.sampleStart) * 1_000 / 16_000
    let end = max(
      start + 1,
      base.stretchBaseMs + Int64(source.sampleStart + source.sampleCount) * 1_000 / 16_000)
    let cut = window.seam?.discardedPrefixBytes ?? 0
    let bytes = Array(source.text.utf8)
    var previousByte = cut
    var previousTime = -Double.infinity
    let tokens = source.tokens?.filter { $0.utf8End > cut }
    let sourceMapped = source.tokens.flatMap { tokens in
      TranscriptSourceMapper.map(
        text: source.text,
        words: tokens.map {
          .init(text: $0.text, start: $0.startSeconds, end: $0.endSeconds)
        })
    }
    let valid =
      sourceMapped != nil
      && (tokens.map { tokens in
        !tokens.isEmpty
          && tokens.allSatisfy { token in
            defer {
              previousByte = token.utf8End
              previousTime = token.endSeconds
            }
            return token.utf8Start >= previousByte && token.utf8End <= bytes.count
              && token.utf8End > token.utf8Start && token.startSeconds.isFinite
              && token.endSeconds.isFinite && token.startSeconds >= previousTime
              && token.endSeconds > token.startSeconds
              && Array(token.text.utf8) == Array(bytes[token.utf8Start..<token.utf8End])
          }
      } ?? false)
    var result: [TranscriptSegmentDraft] = []
    var reasonCounts: [String: Int] = [:]
    func append(_ text: String, from: Int64, to: Int64, basis: TimingBasis) {
      let normalized = normalizer.normalize(text)
      if text.utf8.count > 4_096 || normalized.text.utf8.count > 4_096 {
        // Split at the last complete word that fits both raw and normalized bounds.
        // Unicode indices retain the received bytes, including decomposed characters.
        let boundaries = text.indices.filter { text[$0].isWhitespace && $0 != text.startIndex }
        if let split = boundaries.last(where: {
          let prefix = String(text[..<$0])
          return prefix.utf8.count <= 4_096 && normalizer.normalize(prefix).text.utf8.count <= 4_096
        }) ?? boundaries.first {
          append(String(text[..<split]), from: from, to: to, basis: basis)
          append(String(text[split...]), from: from, to: to, basis: basis)
          return
        }
      }
      // A single pathological word or expanding vocabulary entry cannot satisfy the
      // storage byte contract. Preserve its received text and let admission report failure.
      for reason in normalized.reasons { reasonCounts[reason.rawValue, default: 0] += 1 }
      result.append(
        .init(
          ordinal: base.ordinal + result.count, stretchSequence: base.stretchSequence,
          startMs: from, endMs: max(from + 1, to), coveredMs: end, windowIndex: source.sequence,
          timingBasis: basis, rawText: text, assembledText: text, normalizedText: normalized.text,
          pipelineVersion: Self.version, analysisTracks: base.tracks))
    }
    if valid, let tokens {
      var first = 0
      for index in tokens.indices {
        let count = index - first + 1
        let hasNext = index + 1 < tokens.count
        let nextWouldOverflow =
          hasNext && tokens[index + 1].utf8End - tokens[first].utf8Start > 4_096
        let gap =
          hasNext && tokens[index + 1].startSeconds - tokens[index].endSeconds >= Self.gapSeconds
        let punctuation =
          count >= Self.minimumWordsBeforePunctuationCut
          && tokens[index].text.last.map { ".?!".contains($0) } == true
        if !hasNext || count >= Self.maximumWords || nextWouldOverflow || gap || punctuation {
          let text = String(
            decoding: bytes[tokens[first].utf8Start..<tokens[index].utf8End], as: UTF8.self)
          let from = min(
            end - 1,
            max(
              start,
              start + Int64(min(Double(end - start), max(0, tokens[first].startSeconds * 1_000)))))
          let to = min(
            end,
            max(
              from + 1,
              start + Int64(min(Double(end - start), max(0, tokens[index].endSeconds * 1_000)))))
          append(text, from: from, to: to, basis: .word)
          first = index + 1
        }
      }
    } else {
      // Missing timings share the window interval; append splits only at word
      // boundaries when the raw or normalized byte limit requires it.
      append(window.text, from: start, to: end, basis: .window)
    }
    return .init(segments: result, normalizationReasonCounts: reasonCounts)
  }
}
