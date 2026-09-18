import Foundation

/// Pure, bounded assembly. Received text is never reconstructed from timing tokens.
/// Full original SDK evidence belongs to the caller's immutable result envelope.
struct TranscriptAssembler: Sendable {
  static let version = "anchored_overlap_v3"
  struct Token: Codable, Sendable {
    let text: String
    let utf8Start: Int
    let utf8End: Int
    let startSeconds: Double
    let endSeconds: Double
  }
  struct Window: Codable, Sendable {
    let sequence: Int
    let sampleStart: Int
    let sampleCount: Int
    let paddedSampleCount: Int
    let text: String
    let tokens: [Token]?
  }
  struct RawWindow: Sendable {
    let sequence: Int
    let sampleStart: Int
    let sampleCount: Int
    let text: String
  }
  enum Reason: String, Sendable {
    case uncertainJoin = "uncertain_join"
    case rawCapacity = "raw_capacity"
    case windowCapacity = "window_capacity"
    case mappingCapacity = "mapping_capacity"
    case overlapCapacity = "overlap_capacity"
    case outputCapacity = "output_capacity"
    case invalidResult = "invalid_result"
    case cancelled, failed
  }
  struct Seam: Equatable, Codable, Sendable {
    let window: Int
    let discardedPrefixBytes: Int
    let decision: String
    var basis: String = "physical_adjacency"
    /// Discard audit. Lexical means the token still has text after trailing punctuation.
    var discardedLexicalWords: Int = 0
    /// Chain positions whose own onset evidence exceeded the closed 160 ms bound.
    var unevidencedLexicalDiscards: Int = 0
    /// Lexical tokens discarded before the anchor, justified by overlap geometry alone.
    var preAnchorLexicalDiscards: Int = 0
    var maximumDiscardedOnsetDelta: Double = 0
  }
  struct SourceSpan: Codable, Equatable, Sendable {
    let rawWindowIndex: Int
    let utf8Start: Int
    let utf8End: Int
    let outputUTF8Start: Int
    let separatorBytes: Int
  }
  private(set) var sourceSpans: [SourceSpan] = []
  private(set) var text = ""
  private(set) var rawWindows: [RawWindow] = []
  private(set) var seams: [Seam] = []
  private(set) var reasons: [Reason] = []
  private(set) var stopped = false
  var incomplete: Bool { !reasons.isEmpty }
  private var rawBytes = 0
  private var previous: Window?

  mutating func stop(_ reason: Reason) {
    note(reason)
    stopped = true
    previous = nil
  }

  private mutating func note(_ reason: Reason) {
    // The closed nine-code vocabulary is below the contract's 64-reason ceiling.
    if !reasons.contains(reason) { reasons.append(reason) }
  }

  mutating func append(_ window: Window) {
    guard !stopped else { return }
    guard rawWindows.count < 14 else {
      stop(.windowCapacity)
      return
    }
    let size = window.text.utf8.count
    guard size <= 65_536, rawBytes <= 65_536 - size else {
      stop(.rawCapacity)
      return
    }
    guard window.sequence >= 0, window.sequence <= 13,
      window.sampleStart >= 0, window.sampleStart <= 2_880_000,
      (1...239_360).contains(window.sampleCount),
      window.sampleStart <= 2_880_000 - window.sampleCount,
      window.paddedSampleCount == max(4_800, window.sampleCount)
    else {
      stop(.invalidResult)
      return
    }
    if let tokens = window.tokens {
      guard tokens.count <= 16_384 else {
        stop(.mappingCapacity)
        return
      }
      var bytes = 0
      for token in tokens {
        let count = token.text.utf8.count
        guard count <= 65_536 - bytes else {
          stop(.rawCapacity)
          return
        }
        bytes += count
      }
    }
    rawWindows.append(
      .init(
        sequence: window.sequence, sampleStart: window.sampleStart,
        sampleCount: window.sampleCount, text: window.text))
    rawBytes += size
    var cut = 0
    if let old = previous {
      let contiguous =
        window.sequence == old.sequence + 1
        && window.sampleStart == old.sampleStart + old.sampleCount
      // Any forward overlap is admissible geometry; the stride itself is not evidence.
      let overlapping =
        window.sequence == old.sequence + 1
        && window.sampleStart > old.sampleStart
        && window.sampleStart < old.sampleStart + old.sampleCount
      if contiguous {
        seams.append(.init(window: window.sequence, discardedPrefixBytes: 0, decision: "adjacent"))
      } else if overlapping, let left = Self.validTokens(old), let right = Self.validTokens(window)
      {
        let begin = Double(window.sampleStart) / 16_000
        let end =
          Double(
            min(
              old.sampleStart + old.sampleCount,
              window.sampleStart + window.sampleCount)) / 16_000
        guard
          let l = Self.overlap(
            left, offset: Double(old.sampleStart) / 16_000, begin: begin, end: end),
          let r = Self.overlap(
            right, offset: begin, begin: begin, end: end,
            tokenLimit: 2_048 - l.count,
            byteLimit: 16_384 - Self.spanBytes(l))
        else {
          stop(.overlapCapacity)
          return
        }
        let proof = Self.provenPrefix(
          old: old, new: window, left: l, right: r, oldLastTokenEnd: left.last?.utf8End)
        if let proven = proof.cut {
          cut = proven
          seams.append(
            .init(
              window: window.sequence, discardedPrefixBytes: cut, decision: "proven_overlap",
              basis: proof.basis, discardedLexicalWords: proof.audit.lexical,
              unevidencedLexicalDiscards: proof.audit.unevidenced,
              preAnchorLexicalDiscards: proof.audit.preAnchor,
              maximumDiscardedOnsetDelta: proof.audit.maximumDelta))
        } else {
          uncertain(window.sequence, basis: proof.basis)
        }
      } else {
        uncertain(
          window.sequence,
          basis: overlapping ? "invalid_or_missing_mapping_or_timing" : "invalid_coverage")
      }
    } else if window.sequence != 0 || window.sampleStart != 0 {
      note(.uncertainJoin)
    }
    let suffix = String(decoding: window.text.utf8.dropFirst(cut), as: UTF8.self)
    let separator =
      !text.isEmpty && !suffix.isEmpty
        && !(text.last?.isWhitespace ?? false) && !(suffix.first?.isWhitespace ?? false) ? " " : ""
    guard suffix.utf8.count + separator.utf8.count <= 65_536 - text.utf8.count else {
      stop(.outputCapacity)
      return
    }
    if !suffix.isEmpty {
      sourceSpans.append(
        .init(
          rawWindowIndex: rawWindows.count - 1, utf8Start: cut,
          utf8End: size, outputUTF8Start: text.utf8.count + separator.utf8.count,
          separatorBytes: separator.utf8.count))
    }
    text += separator
    text += suffix
    previous = window
  }

  private mutating func uncertain(_ sequence: Int, basis: String) {
    note(.uncertainJoin)
    seams.append(
      .init(window: sequence, discardedPrefixBytes: 0, decision: "uncertain_join", basis: basis))
  }

  /// All source bytes outside mappings must be whitespace; unaligned punctuation is evidence loss.
  private static func validTokens(_ window: Window) -> [Token]? {
    guard let tokens = window.tokens, !tokens.isEmpty else { return nil }
    let bytes = Array(window.text.utf8)
    var lastByte = 0
    var lastStart = -Double.infinity
    var lastEnd = -Double.infinity
    for token in tokens {
      guard token.utf8Start >= lastByte, token.utf8End > token.utf8Start,
        token.utf8End <= bytes.count,
        !token.text.contains(where: \.isWhitespace),
        lastByte == 0 || token.utf8Start > lastByte,
        Array(token.text.utf8) == Array(bytes[token.utf8Start..<token.utf8End]),
        whitespace(bytes[lastByte..<token.utf8Start]),
        token.startSeconds.isFinite, token.endSeconds.isFinite,
        token.startSeconds >= 0, token.endSeconds >= token.startSeconds,
        token.startSeconds >= lastStart, token.endSeconds >= lastEnd,
        token.endSeconds <= Double(window.sampleCount) / 16_000
      else { return nil }
      lastByte = token.utf8End
      lastStart = token.startSeconds
      lastEnd = token.endSeconds
    }
    guard whitespace(bytes[lastByte...]) else { return nil }
    return tokens
  }

  private static func whitespace(_ bytes: ArraySlice<UInt8>) -> Bool {
    guard let string = String(bytes: bytes, encoding: .utf8) else { return false }
    return string.allSatisfy(\.isWhitespace)
  }

  private static func spanBytes(_ tokens: [Token]) -> Int {
    guard let first = tokens.first, let last = tokens.last else { return 0 }
    return last.utf8End - first.utf8Start
  }

  private static func overlap(
    _ tokens: [Token], offset: Double, begin: Double, end: Double,
    tokenLimit: Int = 2_048, byteLimit: Int = 16_384
  )
    -> [Token]?
  {
    var result: [Token] = []
    for token in tokens
    where token.endSeconds + offset >= begin && token.startSeconds + offset < end {
      guard result.count < tokenLimit,
        token.utf8End - (result.first?.utf8Start ?? token.utf8Start) <= byteLimit
      else { return nil }
      result.append(token)
    }
    return result
  }

  /// A seam is proven by a single text+time occurrence shared by both windows inside the known
  /// overlap, continued position by position to the end of the previous window's mapping.
  /// The previous window's received bytes are always the ones retained.
  struct DiscardAudit: Equatable, Sendable {
    var lexical = 0
    var unevidenced = 0
    var preAnchor = 0
    var maximumDelta = 0.0
  }

  private static func provenPrefix(
    old: Window, new: Window, left: [Token], right: [Token], oldLastTokenEnd: Int?
  ) -> (cut: Int?, basis: String, audit: DiscardAudit) {
    guard !left.isEmpty, !right.isEmpty else { return (nil, "no_mapped_overlap_prefix", .init()) }
    let oldOffset = Double(old.sampleStart) / 16_000
    let newOffset = Double(new.sampleStart) / 16_000
    func agrees(_ left: Double, _ right: Double) -> Bool {
      let a = left + oldOffset
      let b = right + newOffset
      // Preserve the closed 160 ms bound despite rounding in offset addition/subtraction.
      let rounding = max(abs(a), abs(b), 1).ulp * 4
      return abs(a - b) <= 0.16 + rounding
    }
    // Word onsets are the reliable shared evidence; ends drift with chunk-edge decoding.
    func timed(_ a: Token, _ b: Token) -> Bool { agrees(a.startSeconds, b.startSeconds) }
    func matches(_ a: Token, _ b: Token) -> Bool {
      a.text.precomposedStringWithCanonicalMapping
        == b.text.precomposedStringWithCanonicalMapping && timed(a, b)
    }
    /// Punctuation is a decoder artifact of the chunk, not a property of the spoken span, so
    /// trailing punctuation differences do not break an otherwise exact token identity.
    func sameSpokenText(_ a: Token, _ b: Token) -> Bool {
      func stem(_ value: String) -> Substring {
        var text = Substring(value.precomposedStringWithCanonicalMapping)
        while let last = text.last, last.isPunctuation || last.isSymbol { text = text.dropLast() }
        return text
      }
      let x = stem(a.text)
      return !x.isEmpty && x == stem(b.text)
    }
    // A competing same-time occurrence on either side invalidates the anchor.
    var anchor: (Int, Int)?
    for l in left.indices {
      let candidates = right.indices.filter { matches(left[l], right[$0]) }
      guard candidates.count == 1, let r = candidates.first,
        left.indices.filter({ matches(left[$0], right[r]) }).count == 1
      else { continue }
      anchor = (l, r)
      break
    }
    guard let (start, first) = anchor else { return (nil, "missing_or_competing_anchor", .init()) }
    let count = left.count - start
    guard left.last?.utf8End == oldLastTokenEnd, count <= right.count - first else {
      return (nil, "suffix_not_covered", .init())
    }
    // After a unique timed anchor the ordering is fixed, so exact positional token identity
    // is the proof; the anchor alone carries the timing evidence.
    for index in 0..<count where !sameSpokenText(left[start + index], right[first + index]) {
      // The final pair is the chunk edge: both windows heard it, and they disagree. That is
      // insufficient evidence, not a merge opportunity, and both fragments are retained.
      return (
        nil, index == count - 1 ? "conflicting_edge_token" : "nonunique_or_conflicting_alignment",
        .init()
      )
    }
    func lexical(_ token: Token) -> Bool {
      var text = Substring(token.text.precomposedStringWithCanonicalMapping)
      while let last = text.last, last.isPunctuation || last.isSymbol { text = text.dropLast() }
      return !text.isEmpty
    }
    var audit = DiscardAudit()
    for token in right[..<first] where lexical(token) {
      audit.lexical += 1
      audit.preAnchor += 1
    }
    for index in 0..<count where lexical(right[first + index]) {
      audit.lexical += 1
      let delta = abs(
        (left[start + index].startSeconds + oldOffset)
          - (right[first + index].startSeconds
            + newOffset))
      audit.maximumDelta = max(audit.maximumDelta, delta)
      if !agrees(left[start + index].startSeconds, right[first + index].startSeconds) {
        audit.unevidenced += 1
      }
    }
    return (right[first + count - 1].utf8End, "unique_timed_source_suffix", audit)
  }

}

/// Maps already-derived words to exact received bytes. No fuzzy matching or punctuation repair.
/// Original, unclamped timing evidence must be supplied by the adapter.
enum TranscriptSourceMapper {
  static func map(text: String, words: [TranscriptionToken]) -> [TranscriptAssembler.Token]? {
    guard text.utf8.count <= 65_536, words.count <= 16_384 else { return nil }
    var tokenBytes = 0
    for word in words {
      guard word.text.utf8.count <= 65_536 - tokenBytes else { return nil }
      tokenBytes += word.text.utf8.count
    }
    var mapped: [TranscriptAssembler.Token] = []
    var cursor = text.startIndex
    for word in words {
      guard !word.text.isEmpty else { return nil }
      while cursor < text.endIndex && text[cursor].isWhitespace {
        cursor = text.index(after: cursor)
      }
      guard
        let range = text.range(
          of: word.text, options: [.anchored, .literal], range: cursor..<text.endIndex)
      else { return nil }
      guard range.upperBound == text.endIndex || text[range.upperBound].isWhitespace else {
        return nil
      }
      mapped.append(
        .init(
          text: word.text, utf8Start: text[..<range.lowerBound].utf8.count,
          utf8End: text[..<range.upperBound].utf8.count,
          startSeconds: word.start, endSeconds: word.end))
      cursor = range.upperBound
    }
    guard text[cursor...].allSatisfy(\.isWhitespace) else { return nil }
    return mapped
  }
}
