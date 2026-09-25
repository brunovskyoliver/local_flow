import Foundation

/// Copy guard, version 1 (research D9, FR-012). Runs on a validated v2 rewrite
/// result. The screen may inform spelling and tone; it may not add words the
/// speaker did not say. Work is bounded by the snapshot (≤ 8 KiB) and the result
/// (≤ 64 KiB): one hash set of context 4-grams and one pass over the result.
enum ContextCopyGuard {
  static let version = 1
  /// Shortest copied run that is rejected; three-word runs ("thanks for the") are common.
  static let minimumRun = 4
  static let redactionTokens = ["[email]", "[url]", "[ip]", "[number]"]
  private static let maximumTermTokens = 8

  enum Violation: String, Equatable, Sendable {
    /// A run of `minimumRun` or more words from the screen the speaker did not say.
    case copiedRun = "copied_run"
    /// A candidate term from the screen the speaker did not say.
    case unsaidTerm = "unsaid_term"
    /// A redaction placeholder the transcript does not contain.
    case redactionToken = "redaction_token"
  }

  /// Nil when the result may be inserted. `spelledTerms` are replacements made by
  /// local context spelling, which count as said.
  static func check(
    result: String, transcript: String, snapshot: AppContextSnapshot, spelledTerms: [String] = []
  ) -> Violation? {
    let output = tokens(result)
    let said = tokens(transcript)
    let saidCompact = said.joined()
    let saidRuns = grams(said)
    var screenRuns = Set<String>()
    for part in ContextPart.allCases {
      guard let text = snapshot.text(of: part) else { continue }
      screenRuns.formUnion(grams(tokens(text)))
    }
    if !screenRuns.isEmpty, output.count >= minimumRun {
      for start in 0...(output.count - minimumRun) {
        let run = output[start..<(start + minimumRun)]
        let key = run.joined(separator: " ")
        guard screenRuns.contains(key), !saidRuns.contains(key),
          !saidCompact.contains(run.joined())
        else { continue }
        return .copiedRun
      }
    }
    if let violation = unsaidTerm(
      output: output, said: said, terms: snapshot.terms, spelled: spelledTerms)
    {
      return violation
    }
    let lowered = result.lowercased()
    let saidLowered = transcript.lowercased()
    for token in redactionTokens where lowered.contains(token) && !saidLowered.contains(token) {
      return .redactionToken
    }
    return nil
  }

  private static func unsaidTerm(
    output: [String], said: [String], terms: [ContextTerm], spelled: [String]
  ) -> Violation? {
    var keyed: [String: ContextTerm] = [:]
    for term in terms {
      let key = tokens(term.text).joined()
      if !key.isEmpty { keyed[key] = term }
    }
    guard !keyed.isEmpty else { return nil }
    let allowed = Set(spelled.map { tokens($0).joined() })
    let saidSpans = spans(said, keys: nil)
    var saidNames: [String]?
    for key in spans(output, keys: Set(keyed.keys)) where !allowed.contains(key) {
      guard !saidSpans.contains(key), let term = keyed[key] else { continue }
      // The model may correct a name the speaker said, as local spelling does.
      if term.kind == .name, key.count >= 5 {
        saidNames = saidNames ?? Array(saidSpans)
        // Same limits as the speller's near-name match.
        if saidNames!.contains(where: {
          $0.count >= 5 && $0.first == key.first
            && ContextSpeller.levenshtein($0, key, limit: max($0.count, key.count) > 7 ? 2 : 1)
        }) {
          continue
        }
      }
      return .unsaidTerm
    }
    return nil
  }

  /// Folded keys of every run of 1 to `maximumTermTokens` tokens; with `keys`, only
  /// those in the set are kept.
  private static func spans(_ tokens: [String], keys: Set<String>?) -> Set<String> {
    var found = Set<String>()
    for start in tokens.indices {
      var key = ""
      for index in start..<min(tokens.count, start + maximumTermTokens) {
        key += tokens[index]
        if keys?.contains(key) ?? true { found.insert(key) }
      }
    }
    return found
  }

  private static func grams(_ tokens: [String]) -> Set<String> {
    guard tokens.count >= minimumRun else { return [] }
    return Set(
      (0...(tokens.count - minimumRun)).map {
        tokens[$0..<($0 + minimumRun)].joined(separator: " ")
      })
  }

  /// NFC, casefolded and diacritic-folded word tokens; punctuation separates tokens
  /// and apostrophes inside a word are dropped.
  static func tokens(_ text: String) -> [String] {
    var result: [String] = []
    var current = ""
    for character in text.precomposedStringWithCanonicalMapping {
      if character.isLetter || character.isNumber {
        current.append(character)
      } else if character == "'" || character == "’", !current.isEmpty {
        continue
      } else if !current.isEmpty {
        result.append(ContextSpeller.fold(current))
        current = ""
      }
    }
    if !current.isEmpty { result.append(ContextSpeller.fold(current)) }
    return result
  }
}
