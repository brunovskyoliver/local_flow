import Foundation

/// Deterministic protected-literal verification (research R5, FR-027).
/// Extracts literals from model text and checks each against the evidence
/// the item cites: numeric, address and identifier classes match verbatim.
/// Names are not checked: the model sees speaker labels ("Speaker 2",
/// "Lukáš Kocman") the transcript never says, and Slovak inflection and product
/// names made the capitalized-word rule drop correct sentences.
public enum ProtectedLiteralDetector {

  /// One literal that does not appear in the checked evidence.
  public struct Violation: Equatable, Sendable {
    public var literal: String

    public init(literal: String) {
      self.literal = literal
    }
  }

  /// Literals in `text` absent from `evidence`.
  public static func violations(in text: String, evidence: String) -> [Violation] {
    let literals = extract(from: text)
    guard !literals.isEmpty else { return [] }
    let haystack = collapseSpaces(evidence)
    return literals.compactMap {
      haystack.contains($0) ? nil : Violation(literal: $0)
    }
  }

  /// Shared-prefix stem rule: two tokens match when their common prefix is
  /// at least `max(4, min(length) − 3)` characters. Diacritics stay
  /// significant — matching is case- and accent-sensitive.
  public static func stemMatch(_ a: String, _ b: String) -> Bool {
    if a == b { return true }
    let prefix = a.commonPrefix(with: b)
    return prefix.count >= max(4, min(a.count, b.count) - 3)
  }

  /// Whitespace-separated tokens with edge punctuation stripped — the unit
  /// the stem rule and the support check compare.
  public static func wordTokens(of text: String) -> [String] {
    text.split(whereSeparator: { $0.isWhitespace }).map {
      String($0).trimmingCharacters(in: edgePunctuation)
    }.filter { !$0.isEmpty }
  }

  /// R6 content tokens: ≥ 4 characters, folded, stopwords removed.
  public static func contentTokens(of text: String) -> [String] {
    wordTokens(of: text).map(fold).filter { $0.count >= 4 && !stopWords.contains($0) }
  }

  // MARK: Extraction

  private static func extract(from text: String) -> [String] {
    var literals: [String] = []
    var covered: [NSRange] = []
    let nsText = text as NSString

    for regex in Self.multiTokenRegexes {
      for match in regex.matches(in: text, range: NSRange(location: 0, length: nsText.length)) {
        literals.append(match.range.length > 0 ? nsText.substring(with: match.range) : "")
        covered.append(match.range)
      }
    }

    for (token, range) in tokenRanges(of: text)
    where !covered.contains(where: { NSIntersectionRange($0, range).length == range.length }) {
      let inner = token.trimmingCharacters(in: edgePunctuation)
      guard !inner.isEmpty else { continue }
      if Self.tokenClasses.contains(where: { $0(inner) }) { literals.append(inner) }
    }

    var seen: Set<String> = []
    return literals.filter { !$0.isEmpty && seen.insert($0).inserted }
  }

  // MARK: Classes

  /// The classes Feature 012 redacts from on-screen context (research D8).
  public enum ProtectedClass: String, Sendable {
    case email, url, ip, number
  }

  /// The redaction class of one punctuation-stripped token, or nil.
  public static func protectedClass(of token: String) -> ProtectedClass? {
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
