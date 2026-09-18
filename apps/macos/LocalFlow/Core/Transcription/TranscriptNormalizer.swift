import Foundation

/// Formatting rules N001–N006 plus explicit vocabulary mapping V001, run to a fixed point.
struct TranscriptNormalizer: Sendable {
  static let version = "formatting-n001-n006-vocabulary-v001-v1"
  static let maximumTextBytes = 65_536
  enum Reason: String, Sendable {
    case unexpectedControl = "unexpected_control"
    case ambiguousVocabulary = "ambiguous_vocabulary"
    case normalizationCapacity = "normalization_capacity"
    case normalizationNonconvergent = "normalization_nonconvergent"
  }
  struct Result: Sendable {
    let text: String
    let appliedRuleIDs: [String]
    let appliedEntryIDs: [String]
    /// Entries whose overlapping candidates were left unchanged; detail only, never logs.
    let ambiguousEntryIDs: [String]
    let reasons: [Reason]
    var reason: Reason? { reasons.first }
    var incomplete: Bool { !reasons.isEmpty }
  }
  private let vocabulary: VocabularySnapshot
  private let maximumSpans: Int
  private let maximumMatches: Int
  private let maximumPasses: Int

  // Reduced bounds allow deterministic guard tests; callers cannot raise production limits.
  init(
    vocabulary: VocabularySnapshot = .empty,
    maximumSpans: Int = 16_384, maximumMatches: Int = 8_192, maximumPasses: Int = 32
  ) {
    self.vocabulary = vocabulary
    self.maximumSpans = min(16_384, max(0, maximumSpans))
    self.maximumMatches = min(8_192, max(0, maximumMatches))
    self.maximumPasses = min(32, max(0, maximumPasses))
  }

  func normalize(_ input: String) -> Result {
    func fallback(_ reason: Reason) -> Result {
      Result(
        text: input, appliedRuleIDs: [], appliedEntryIDs: [], ambiguousEntryIDs: [],
        reasons: [reason])
    }
    guard input.utf8.count <= Self.maximumTextBytes else {
      return fallback(.normalizationCapacity)
    }
    var text = input
    var applied = Set<String>()
    var appliedEntries = Set<String>()
    var ambiguousEntries = Set<String>()
    let unexpectedControl = input.unicodeScalars.contains {
      ($0.properties.generalCategory == .control || $0.properties.generalCategory == .format)
        && $0 != "\r" && $0 != "\n" && $0 != "\t"
    }
    do {
      for _ in 0..<maximumPasses {
        // A full pass with no byte changes proves the fixed point.
        var changed = false
        for rule in 1...5 {
          let next: String
          switch rule {
          case 1: next = try compose(text)
          case 2: next = try lineEndings(text)
          case 3: next = try horizontalWhitespace(text)
          case 4: next = try commas(text)
          default:
            next = try vocabularyTerms(
              text, appliedEntries: &appliedEntries, ambiguousEntries: &ambiguousEntries)
          }
          if !next.utf8.elementsEqual(text.utf8) {
            applied.insert(rule == 5 ? "V001" : "N00\(rule)")
            changed = true
          }
          text = next
        }
        if !changed {
          var reasons: [Reason] = []
          if unexpectedControl { reasons.append(.unexpectedControl) }
          if !ambiguousEntries.isEmpty { reasons.append(.ambiguousVocabulary) }
          return Result(
            text: text, appliedRuleIDs: applied.sorted(), appliedEntryIDs: appliedEntries.sorted(),
            ambiguousEntryIDs: ambiguousEntries.sorted(), reasons: reasons)
        }
      }
      return fallback(.normalizationNonconvergent)
    } catch {
      return fallback(.normalizationCapacity)
    }
  }

  private struct Buffer {
    var text = ""
    var bytes = 0
    mutating func append(_ value: String) throws {
      let count = value.utf8.count
      guard bytes + count <= TranscriptNormalizer.maximumTextBytes else { throw Capacity.full }
      text.append(value)
      bytes += count
    }
    mutating func append(_ scalar: Unicode.Scalar) throws { try append(String(scalar)) }
  }
  private enum Capacity: Error { case full }

  private func compose(_ input: String) throws -> String {
    var output = Buffer()
    // Canonical composition cannot cross an extended grapheme cluster boundary.
    // Bound each cluster's canonical decomposition before Foundation allocates its result.
    for character in input {
      var decompositionBytes = 0
      for scalar in character.unicodeScalars {
        decompositionBytes += String(scalar).decomposedStringWithCanonicalMapping.utf8.count
        guard decompositionBytes <= Self.maximumTextBytes else { throw Capacity.full }
      }
      try output.append(String(character).precomposedStringWithCanonicalMapping)
    }
    return output.text
  }

  private func lineEndings(_ input: String) throws -> String {
    var output = Buffer()
    var previousCR = false
    for scalar in input.unicodeScalars {
      if scalar == "\r" {
        try output.append("\n" as Unicode.Scalar)
      } else if scalar != "\n" || !previousCR {
        try output.append(scalar)
      }
      previousCR = scalar == "\r"
    }
    return output.text
  }

  private func horizontalWhitespace(_ input: String) throws -> String {
    var output = Buffer()
    var pendingSpace = false
    var lineStart = true
    for scalar in input.unicodeScalars {
      if scalar == " " || scalar == "\t" {
        pendingSpace = !lineStart
      } else if scalar == "\n" {
        try output.append(scalar)
        pendingSpace = false
        lineStart = true
      } else {
        if pendingSpace { try output.append(" " as Unicode.Scalar) }
        try output.append(scalar)
        pendingSpace = false
        lineStart = false
      }
    }
    return output.text
  }

  /// One whitespace-delimited span, addressed by scalar offsets. `core` trims enclosing
  /// brackets and trailing sentence punctuation, which are not identifier syntax.
  private struct Span {
    let range: Range<Int>
    let core: Range<Int>
    let quoted: Bool
    let technical: Bool
    let technicalCore: Bool
    /// Comma edits treat any technical or quoted span as protected.
    var protected: Bool { quoted || technical }
    /// Vocabulary may replace a whole term inside brackets or before a period, but never
    /// part of an identifier, URL, number or quoted run.
    var protectedForVocabulary: Bool { quoted || technicalCore }
  }

  private static let technicalScalars = Set("_/:\\@`.=+<>[]{}()|#%$&*~^-".unicodeScalars)
  private static let leadingEdge = Set("([{".unicodeScalars)
  private static let trailingEdge = Set(".,;:!?)]}".unicodeScalars)

  private func isTechnical(_ scalar: Unicode.Scalar) -> Bool {
    scalar.properties.numericType != nil || Self.technicalScalars.contains(scalar)
  }

  /// Quoted runs and backtick code are tracked across spans; technical content per span.
  private func spans(_ scalars: [Unicode.Scalar]) throws -> [Span] {
    var spans: [Span] = []
    var start: Int?
    var quoted = false
    var technical = false
    var quote: Unicode.Scalar?
    func close(_ lower: Int, _ upper: Int) throws {
      guard spans.count < maximumSpans else { throw Capacity.full }
      var core = lower..<upper
      while core.count > 1, Self.leadingEdge.contains(scalars[core.lowerBound]) {
        core = (core.lowerBound + 1)..<core.upperBound
      }
      while core.count > 1, Self.trailingEdge.contains(scalars[core.upperBound - 1]) {
        core = core.lowerBound..<(core.upperBound - 1)
      }
      spans.append(
        Span(
          range: lower..<upper, core: core, quoted: quoted, technical: technical,
          technicalCore: scalars[core].contains(where: isTechnical)))
    }
    for index in scalars.indices {
      let scalar = scalars[index]
      if scalar.properties.isWhitespace {
        if let lower = start {
          try close(lower, index)
          start = nil
        }
        continue
      }
      if start == nil {
        start = index
        quoted = quote != nil
        technical = false
      }
      let apostropheInWord =
        scalar == "'" && index > 0 && index + 1 < scalars.count
        && isLetter(scalars[index - 1]) && isLetter(scalars[index + 1])
      let continuedBacktick = scalar == "`" && index > 0 && scalars[index - 1] == "`"
      if continuedBacktick {
        quoted = true
      } else if let closing = quote {
        quoted = true
        if scalar == closing && !apostropheInWord { quote = nil }
      } else {
        if !apostropheInWord {
          switch scalar {
          case "\"", "'", "`":
            quote = scalar
            quoted = true
          case "\u{201C}":
            quote = "\u{201D}"
            quoted = true
          case "\u{2018}":
            quote = "\u{2019}"
            quoted = true
          default: break
          }
        }
        if isTechnical(scalar) { technical = true }
      }
    }
    if let start { try close(start, scalars.count) }
    return spans
  }

  private func commas(_ input: String) throws -> String {
    let scalars = Array(input.unicodeScalars)
    let spans = try spans(scalars)
    var removals = Set<Int>()
    if spans.count >= 3 {
      for offset in 1..<(spans.count - 1) {
        let left = spans[offset - 1]
        let comma = spans[offset]
        let right = spans[offset + 1]
        guard !left.protected, !comma.protected, !right.protected,
          comma.range.count == 1, scalars[comma.range.lowerBound] == ",",
          left.range.upperBound + 1 == comma.range.lowerBound,
          scalars[left.range.upperBound] == " ",
          comma.range.upperBound + 1 == right.range.lowerBound,
          scalars[comma.range.upperBound] == " ",
          isLetter(scalars[left.range.upperBound - 1]),
          isLetter(scalars[right.range.lowerBound])
        else { continue }
        guard removals.count < maximumMatches else { throw Capacity.full }
        removals.insert(left.range.upperBound)
      }
    }
    var output = Buffer()
    for index in scalars.indices where !removals.contains(index) {
      try output.append(scalars[index])
    }
    return output.text
  }

  private struct Candidate: Hashable {
    let range: Range<Int>
    let entryID: String
    let canonical: String
  }

  /// V001: literal folded whole-term matches against a stable pass input. Overlapping
  /// candidates are never ranked; the whole group stays unchanged and is reported.
  private func vocabularyTerms(
    _ input: String, appliedEntries: inout Set<String>, ambiguousEntries: inout Set<String>
  ) throws -> String {
    ambiguousEntries.removeAll()
    guard !vocabulary.isEmpty else { return input }
    let source = Array(input.unicodeScalars)
    let spans = try spans(source)
    // Lowercase mapping can expand one scalar; origin maps each folded scalar back.
    var folded: [Unicode.Scalar] = []
    var origin: [Int32] = []
    folded.reserveCapacity(source.count)
    origin.reserveCapacity(source.count)
    for (index, scalar) in source.enumerated() {
      for mapped in scalar.properties.lowercaseMapping.unicodeScalars {
        folded.append(mapped)
        origin.append(Int32(index))
      }
    }
    var candidates: [Candidate] = []
    // Same span and same target collapse to one match; anything else overlapping is ambiguous.
    var seen = Set<Candidate>()
    for start in folded.indices {
      guard let keys = vocabulary.keysByFirstScalar[folded[start]] else { continue }
      for key in keys {
        let end = start + key.scalars.count
        guard end <= folded.count, folded[start..<end].elementsEqual(key.scalars) else { continue }
        // The match must cover whole source scalars, then whole terms.
        guard start == 0 || origin[start - 1] != origin[start],
          end == folded.count || origin[end - 1] != origin[end]
        else { continue }
        let sourceRange = Int(origin[start])..<(Int(origin[end - 1]) + 1)
        guard
          sourceRange.lowerBound == 0
            || !VocabularyValidation.isTermScalar(source[sourceRange.lowerBound - 1]),
          sourceRange.upperBound == source.count
            || !VocabularyValidation.isTermScalar(source[sourceRange.upperBound])
        else { continue }
        guard coversProtectedSpans(sourceRange, spans: spans) else { continue }
        // Text already in canonical form carries no alternative meaning; it neither
        // changes nor blocks an adjacent multiword replacement as ambiguous.
        if String(String.UnicodeScalarView(source[sourceRange])).utf8.elementsEqual(
          key.canonical.utf8)
        {
          continue
        }
        let candidate = Candidate(
          range: sourceRange, entryID: key.entryID, canonical: key.canonical)
        guard
          seen.insert(Candidate(range: sourceRange, entryID: "", canonical: key.canonical))
            .inserted
        else { continue }
        guard candidates.count < maximumMatches else { throw Capacity.full }
        candidates.append(candidate)
      }
    }
    candidates.sort {
      $0.range.lowerBound != $1.range.lowerBound
        ? $0.range.lowerBound < $1.range.lowerBound : $0.range.upperBound < $1.range.upperBound
    }
    var selected: [Candidate] = []
    var index = 0
    while index < candidates.count {
      var groupEnd = index + 1
      var reach = candidates[index].range.upperBound
      while groupEnd < candidates.count, candidates[groupEnd].range.lowerBound < reach {
        reach = max(reach, candidates[groupEnd].range.upperBound)
        groupEnd += 1
      }
      if groupEnd - index == 1 {
        selected.append(candidates[index])
      } else {
        for member in candidates[index..<groupEnd] { ambiguousEntries.insert(member.entryID) }
      }
      index = groupEnd
    }
    var output = Buffer()
    var cursor = 0
    var applied = Set<String>()
    for candidate in selected {
      for position in cursor..<candidate.range.lowerBound { try output.append(source[position]) }
      try output.append(candidate.canonical)
      applied.insert(candidate.entryID)
      cursor = candidate.range.upperBound
    }
    for position in cursor..<source.count { try output.append(source[position]) }
    appliedEntries.formUnion(applied)
    return output.text
  }

  /// A protected span may only change when the match covers its entire core.
  private func coversProtectedSpans(_ range: Range<Int>, spans: [Span]) -> Bool {
    var low = 0
    var high = spans.count
    while low < high {
      let middle = (low + high) / 2
      if spans[middle].range.upperBound <= range.lowerBound {
        low = middle + 1
      } else {
        high = middle
      }
    }
    var index = low
    while index < spans.count, spans[index].range.lowerBound < range.upperBound {
      let span = spans[index]
      if span.protectedForVocabulary,
        span.core.lowerBound < range.lowerBound || span.core.upperBound > range.upperBound
      {
        return false
      }
      index += 1
    }
    return true
  }

  private func isLetter(_ scalar: Unicode.Scalar) -> Bool {
    switch scalar.properties.generalCategory {
    case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter: true
    default: false
    }
  }
}
