import AppKit
import NaturalLanguage

/// Feature 013 (ADR 0027). The Dictionary's enabled canonical terms for one dictation,
/// handed to the speech runtime so its CTC keyword spotter can check them against audio.
struct VocabularyBoostTerms: Sendable, Equatable {
  /// FluidAudio validated its rescorer up to 230 terms without latency loss.
  // ponytail: first 256 enabled entries by ID; rank by use if a Dictionary ever outgrows it.
  static let maximumTerms = 256
  struct Term: Sendable, Equatable {
    let entryID: String
    let canonical: String
  }
  let terms: [Term]
  /// The snapshot hash: the runtime rebuilds its rescorer only when this changes.
  let key: String
  /// Every enabled canonical and alias, folded: V001 already decides these spans.
  let governed: Set<String>

  init?(snapshot: VocabularySnapshot?) {
    guard let snapshot, !snapshot.entries.isEmpty else { return nil }
    terms = snapshot.entries.filter(\.enabled)
      .sorted { $0.id.utf8.lexicographicallyPrecedes($1.id.utf8) }
      .prefix(Self.maximumTerms)
      .map { Term(entryID: $0.id, canonical: $0.canonical) }
    guard !terms.isEmpty else { return nil }
    key = snapshot.hash
    governed = Set(
      snapshot.entries.filter(\.enabled).flatMap { [$0.canonical] + $0.aliases }.map(Self.fold))
  }

  init(terms: [Term], key: String, governed: Set<String> = []) {
    self.terms = terms
    self.key = key
    self.governed = governed
  }

  /// Whether the Dictionary already maps `source` itself (edge punctuation ignored).
  func governs(_ source: String) -> Bool {
    let trimmed = source.trimmingCharacters(in: .punctuationCharacters.union(.symbols))
    return governed.contains(Self.fold(trimmed))
  }

  private static func fold(_ term: String) -> String {
    var view = String.UnicodeScalarView()
    view.append(contentsOf: VocabularyValidation.fold(term))
    return String(view)
  }
}

/// One accepted replacement in a raw window: `source` is the exact space-separated span
/// of the window text the spotter matched, `canonical` the Dictionary spelling.
struct VocabularyBoostHint: Sendable, Equatable {
  let source: String
  let canonical: String
  let entryID: String
}

/// Decides whether a spotter replacement may reach the transcript. Every rule was set
/// by the Feature 013 benchmark: English and Slovak TTS corpora (tuning and held-out)
/// plus the owner's own meeting audio, where no rule set may make any clip worse.
enum VocabularyBoostPolicy {
  static let ruleID = "V002"
  static let version = "ctc110m-v1"
  static let minimumSimilarity = 0.6
  static let slovakMinimumSimilarity = 0.8
  /// Parakeet is sure of what it heard: a confident word is left alone.
  static let maximumConfidence: Float = 0.9

  enum Language: Sendable { case english, slovak }

  struct Candidate: Sendable, Equatable {
    let source: String
    let term: String
    /// Lowest Parakeet token confidence across the source words; nil when unmatched.
    let confidence: Float?
  }

  static func allows(
    _ candidate: Candidate, language: Language, isEnglishWord: (String) -> Bool
  ) -> Bool {
    guard let confidence = candidate.confidence, confidence < maximumConfidence else {
      return false
    }
    let words = candidate.source.split { !$0.isLetter && $0 != "'" }.map(String.init)
    guard !words.isEmpty else { return false }
    // Real words ("network", "database", "long horn") are the Dictionary's job: an
    // alias learned from a correction maps them deliberately.
    if words.allSatisfy(isEnglishWord) { return false }
    // Slovak inflects names and terms; the base form would break the sentence.
    if isInflection(of: candidate.term, candidate.source) { return false }
    switch language {
    case .english:
      return similarity(candidate.source, candidate.term) >= minimumSimilarity
    case .slovak:
      // The spotter is English-only; conversational Slovak needs a near-spelling match
      // and no short function words ("o toho", "s nimi") inside the span.
      if words.contains(where: { $0.count <= 3 && $0 != $0.uppercased() }) { return false }
      return similarity(candidate.source, candidate.term) >= slovakMinimumSimilarity
    }
  }

  /// Correctly spelled English words, per the system spell checker.
  @MainActor static func englishWords(in words: Set<String>) -> Set<String> {
    let checker = NSSpellChecker.shared
    return words.filter {
      checker.checkSpelling(
        of: $0, startingAt: 0, language: "en", wrap: false, inSpellDocumentWithTag: 0,
        wordCount: nil
      ).location == NSNotFound
    }
  }

  /// English or Slovak only; ties and empty text count as English.
  static func language(of text: String) -> Language {
    let recognizer = NLLanguageRecognizer()
    recognizer.languageConstraints = [.english, .slovak]
    recognizer.processString(text)
    let hypotheses = recognizer.languageHypotheses(withMaximum: 2)
    return (hypotheses[.slovak] ?? 0) > (hypotheses[.english] ?? 0) ? .slovak : .english
  }

  /// Letters and digits only, diacritics removed, lowercased.
  static func fold(_ text: String) -> [Character] {
    var output: [Character] = []
    for scalar in text.decomposedStringWithCanonicalMapping.unicodeScalars {
      switch scalar.properties.generalCategory {
      case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
        .decimalNumber, .letterNumber, .otherNumber:
        output.append(contentsOf: String(scalar).lowercased())
      default: continue
      }
    }
    return output
  }

  /// 1 − Levenshtein distance / longer length, on folded text.
  static func similarity(_ a: String, _ b: String) -> Double {
    let x = fold(a)
    let y = fold(b)
    guard !x.isEmpty, !y.isEmpty else { return 0 }
    var row = Array(0...y.count)
    for i in 1...x.count {
      var previous = row[0]
      row[0] = i
      for j in 1...y.count {
        let substitution = previous + (x[i - 1] == y[j - 1] ? 0 : 1)
        previous = row[j]
        row[j] = min(row[j] + 1, row[j - 1] + 1, substitution)
      }
    }
    return 1 - Double(row[y.count]) / Double(max(x.count, y.count))
  }

  /// `source` is the term with a changed or added ending ("Mikuláša" for "Mikuláš").
  static func isInflection(of term: String, _ source: String) -> Bool {
    let t = fold(term)
    let s = fold(source)
    guard s != t, s.count >= t.count else { return false }
    let shared = zip(s, t).prefix { $0 == $1 }.count
    return shared >= 3 && shared >= t.count - 1
  }
}

enum VocabularyBoostApplier {
  /// Applies hints in order, each after the previous one, keeping the punctuation around
  /// the replaced span. A hint whose span is no longer in the text is skipped.
  static func apply(_ hints: [VocabularyBoostHint], to text: String) -> (
    text: String, entryIDs: [String]
  ) {
    guard !hints.isEmpty else { return (text, []) }
    var tokens = text.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
    var cursor = 0
    var applied: [String] = []
    for hint in hints {
      let span = hint.source.split(separator: " ").map(String.init)
      guard !span.isEmpty, cursor + span.count <= tokens.count else { continue }
      guard
        let start = (cursor...(tokens.count - span.count)).first(where: {
          Array(tokens[$0..<($0 + span.count)]) == span
        })
      else { continue }
      let lead = span[0].prefix { !$0.isLetter && !$0.isNumber }
      let trail = String(span[span.count - 1].reversed().prefix { !$0.isLetter && !$0.isNumber })
      tokens.replaceSubrange(
        start..<(start + span.count), with: [lead + hint.canonical + String(trail.reversed())])
      cursor = start + 1
      applied.append(hint.entryID)
    }
    return (tokens.joined(separator: " "), applied)
  }
}
