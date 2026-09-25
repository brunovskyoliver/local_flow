import Foundation

/// Deterministic protected-literal verification (research R5, FR-027).
/// Extracts literals from model text and checks each against the evidence
/// the item cites: numeric, address and identifier classes match verbatim;
/// proper nouns match by the stem rule so Slovak inflection survives.
/// Participant owner names are excluded — they come from the speaker
/// record, not from model text.
enum ProtectedLiteralDetector {

  /// One literal that does not appear in the checked evidence.
  struct Violation: Equatable, Sendable {
    var literal: String
  }

  /// Literals in `text` absent from `evidence`. `excluding` names (owner
  /// names rendered from the speaker record) are skipped by folded equality
  /// or the stem rule.
  static func violations(
    in text: String, evidence: String, excluding names: Set<String> = []
  ) -> [Violation] {
    let literals = extract(from: text, excluding: names)
    guard !literals.isEmpty else { return [] }
    let haystack = collapseSpaces(evidence)
    let evidenceTokens = wordTokens(of: evidence)
    return literals.compactMap { literal in
      if literal.stem {
        return evidenceTokens.contains { stemMatch(literal.value, $0) }
          ? nil : Violation(literal: literal.value)
      }
      return haystack.contains(literal.value) ? nil : Violation(literal: literal.value)
    }
  }

  /// Shared-prefix stem rule: two tokens match when their common prefix is
  /// at least `max(4, min(length) − 3)` characters. Diacritics stay
  /// significant — matching is case- and accent-sensitive.
  static func stemMatch(_ a: String, _ b: String) -> Bool {
    if a == b { return true }
    let prefix = a.commonPrefix(with: b)
    return prefix.count >= max(4, min(a.count, b.count) - 3)
  }

  /// Whitespace-separated tokens with edge punctuation stripped — the unit
  /// the stem rule and the support check compare.
  static func wordTokens(of text: String) -> [String] {
    text.split(whereSeparator: { $0.isWhitespace }).map {
      String($0).trimmingCharacters(in: edgePunctuation)
    }.filter { !$0.isEmpty }
  }

  /// R6 content tokens: ≥ 4 characters, folded, stopwords removed.
  static func contentTokens(of text: String) -> [String] {
    wordTokens(of: text).map(fold).filter { $0.count >= 4 && !stopWords.contains($0) }
  }

  // MARK: Extraction

  private struct Literal {
    var value: String
    /// Proper nouns verify by stem; every other class verifies verbatim.
    var stem = false
  }

  private static func extract(from text: String, excluding names: Set<String>)
    -> [Literal]
  {
    var literals: [Literal] = []
    var covered: [NSRange] = []
    let nsText = text as NSString

    for regex in Self.multiTokenRegexes {
      for match in regex.matches(in: text, range: NSRange(location: 0, length: nsText.length)) {
        literals.append(
          Literal(value: match.range.length > 0 ? nsText.substring(with: match.range) : ""))
        covered.append(match.range)
      }
    }

    for (token, range) in tokenRanges(of: text)
    where !covered.contains(where: { NSIntersectionRange($0, range).length == range.length }) {
      let inner = token.trimmingCharacters(in: edgePunctuation)
      guard !inner.isEmpty else { continue }
      if Self.tokenClasses.contains(where: { $0(inner) }) {
        literals.append(Literal(value: inner))
      } else if isProperNoun(inner, range: range, text: text) {
        guard !isExcluded(inner, names: names) else { continue }
        literals.append(Literal(value: inner, stem: true))
      }
    }

    var seen: Set<String> = []
    return literals.filter { !$0.value.isEmpty && seen.insert($0.value).inserted }
  }

  private static func isExcluded(_ token: String, names: Set<String>) -> Bool {
    names.contains { name in
      fold(name) == fold(token)
        || name.split(whereSeparator: { $0.isWhitespace }).contains {
          stemMatch(String($0), token)
        }
    }
  }

  /// Capitalized, ≥ 2 characters, not at sentence start, not a stopword.
  private static func isProperNoun(
    _ inner: String, range: NSRange, text: String
  ) -> Bool {
    guard inner.count >= 2, let first = inner.first, first.isUppercase else {
      return false
    }
    guard !stopWords.contains(fold(inner)) else { return false }
    var index = range.location
    let scalars = (text as NSString)
    while index > 0 {
      let character = scalars.character(at: index - 1)
      guard let scalar = Unicode.Scalar(character) else { break }
      if Character(scalar).isWhitespace {
        index -= 1
        continue
      }
      return !".!?".contains(Character(scalar))
    }
    return false  // first token of the text
  }

  // MARK: Classes

  /// The classes Feature 012 redacts from on-screen context (research D8).
  enum ProtectedClass: String, Sendable {
    case email, url, ip, number
  }

  /// The redaction class of one punctuation-stripped token, or nil.
  static func protectedClass(of token: String) -> ProtectedClass? {
    guard !token.isEmpty else { return nil }
    if isIPv4(token) || isIPv6(token) { return .ip }
    if isURL(token) || token.lowercased().hasPrefix("www.") { return .url }
    if isEmail(token) { return .email }
    if isNumber(token) { return .number }
    return nil
  }

  private nonisolated(unsafe) static let isIPv4 = matches(#"^\d{1,3}(\.\d{1,3}){3}$"#)
  // Two or more colons.
  private nonisolated(unsafe) static let isIPv6 = matches(
    #"^([0-9A-Fa-f]{0,4}:){2,}[0-9A-Fa-f]{0,4}$"#)
  private nonisolated(unsafe) static let isURL = matches(#"^(https?|ftp)://\S+$"#)
  private nonisolated(unsafe) static let isEmail = matches(#"^[\w.+-]+@[\w-]+(\.[\w-]+)+$"#)
  /// Plain numbers and amounts: optional sign or currency, digits with separators, optional %.
  private nonisolated(unsafe) static let isNumber = matches(#"^[$€£+-]?\d[\d.,]*(%|€)?$"#)

  /// Single-token classes checked against the punctuation-stripped token.
  /// `nonisolated(unsafe)`: the compiled matchers are immutable.
  private nonisolated(unsafe) static let tokenClasses: [(String) -> Bool] = [
    isIPv4, isIPv6, isURL, isEmail,
    // dotted hostname with a letter TLD
    matches(#"^([\w-]+\.)+[A-Za-z]{2,}$"#),
    // time
    matches(#"^\d{1,2}:\d{2}$"#),
    // version strings
    matches(#"^v\d+(\.\d+)*$"#),
    matches(#"^\d+\.\d+\.\d+$"#),
    // digit-bearing token with at least one letter
    matches(#"^(?=[\w.-]*\d)(?=[\w.-]*[\p{L}])[\w.-]+$"#),
  ]

  /// Multi-token classes matched against the whole text; their ranges also
  /// mask token classes so "GB" inside "3 GB" is not reported twice.
  private static let multiTokenRegexes: [NSRegularExpression] = [
    regex(#"(?<![\w.])[$€£]\s?\d[\d.,]*(?:\s\d{3})*"#),
    regex(
      #"(?<![\w.])\d[\d.,]*(?:\s\d{3})*\s?(?:€|EUR|USD|GBP|CZK|GB|MB|KB|TB|km|kg|cm|mm|%|ms|min)\b"#
    ),
    // Numeric dates, guarded against dotted runs like IPv4 octets.
    regex(
      #"(?<![\w.])(?:\d{4}-\d{2}-\d{2}|\d{1,2}\.\d{1,2}(?:\.\d{2,4})?\.?|\d{1,2}/\d{1,2}/\d{2,4})(?![\w.])"#
    ),
    // Month-name dates in English and Slovak, either order.
    regex(#"\b\d{1,2}\.?\s+(?:"# + Self.monthAlternation + #")\b"#),
    regex(#"\b(?:"# + Self.monthAlternation + #")\s+\d{1,2}\b"#),
  ]

  private static let monthAlternation =
    "january|január|januára|february|február|februára|march|marec|marca|april|apríl|apríla|may|máj|mája|june|jún|júna|july|júl|júla|august|augusta|september|septembra|october|október|októbra|november|novembra|december|decembra"

  // MARK: Helpers

  private static func regex(_ pattern: String) -> NSRegularExpression {
    try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
  }

  private static func matches(_ pattern: String) -> (String) -> Bool {
    let compiled = regex(pattern)
    return { token in
      compiled.firstMatch(
        in: token, range: NSRange(location: 0, length: token.utf16.count)) != nil
    }
  }

  private static let edgePunctuation = CharacterSet(
    charactersIn: ".,;:!?()[]{}\"'„“”‚‘’«»")

  private static let stopWords: Set<String> =
    Set(AnalysisPolicy.stopWords.map(fold))

  private static func fold(_ text: String) -> String {
    text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
  }

  private static func collapseSpaces(_ text: String) -> String {
    text.components(separatedBy: .whitespacesAndNewlines)
      .filter { !$0.isEmpty }
      .joined(separator: " ")
  }

  /// Every maximal non-whitespace run and its NSRange in `text`.
  private static func tokenRanges(of text: String) -> [(String, NSRange)] {
    var result: [(String, NSRange)] = []
    let nsText = text as NSString
    var index = 0
    while index < nsText.length {
      var end = index
      while end < nsText.length,
        let scalar = Unicode.Scalar(nsText.character(at: end)),
        !Character(scalar).isWhitespace
      {
        end += 1
      }
      if end > index {
        result.append(
          (
            nsText.substring(with: NSRange(location: index, length: end - index)),
            NSRange(location: index, length: end - index)
          ))
      }
      index = max(end, index + 1)
    }
    return result
  }
}
