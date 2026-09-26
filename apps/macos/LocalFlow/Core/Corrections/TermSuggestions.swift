import Foundation

/// Feature 013. A term the Dictionary might want; nothing changes until the user adds it.
struct TermSuggestion: Equatable, Identifiable, Sendable {
  enum Source: Equatable, Sendable {
    /// The user replaced `alias` with `canonical` in a dictation, but the scorer only
    /// suggested learning it.
    case correction
    /// The term was in the app around the cursor for this many dictations.
    case context
  }
  let canonical: String
  /// The replaced misspelling; empty when there is none.
  let alias: String
  let sightings: Int
  let source: Source
  var id: String { Self.id(canonical: canonical, alias: alias) }

  static func id(canonical: String, alias: String) -> String { canonical + "\u{1F}" + alias }
}

enum TermSuggestionMiner {
  /// A context term needs this many dictations; one correction is the user's own spelling.
  static let minimumContextSightings = 3
  static let maximumShown = 12

  static func suggestions(
    _ contents: TermSuggestionStore.Contents, dictionary: [VocabularyEntry],
    isEnglishWord: (String) -> Bool
  ) -> [TermSuggestion] {
    // Disabled entries count too: the user already decided about those terms.
    let governed = Set(
      dictionary.flatMap { [$0.canonical] + $0.aliases }.map(VocabularyValidation.fold))
    func open(_ canonical: String, _ alias: String) -> Bool {
      !contents.dismissed.contains(TermSuggestion.id(canonical: canonical, alias: alias))
        && !governed.contains(VocabularyValidation.fold(canonical))
        && (alias.isEmpty || !governed.contains(VocabularyValidation.fold(alias)))
        && savable(canonical)
    }
    let corrections = contents.corrections.filter { open($0.canonical, $0.alias) }
      .sorted { ($0.sightings, $1.canonical) > ($1.sightings, $0.canonical) }
      .map {
        TermSuggestion(
          canonical: $0.canonical, alias: $0.alias, sightings: $0.sightings, source: .correction)
      }
    var counts: [String: Int] = [:]
    for terms in contents.contextTerms {
      for term in Set(terms) { counts[term, default: 0] += 1 }
    }
    let context = counts.filter { term, count in
      count >= minimumContextSightings && isTermShaped(term) && open(term, "")
        && !term.split(separator: " ").allSatisfy { isEnglishWord(String($0)) }
    }
    .sorted { ($0.value, $1.key) > ($1.value, $0.key) }
    .map { TermSuggestion(canonical: $0.key, alias: "", sightings: $0.value, source: .context) }
    return Array((corrections + context).prefix(maximumShown))
  }

  /// A name or code term rather than a word: a capital or a digit, no file, path or
  /// snake_case punctuation, and not a hash or UUID.
  static func isTermShaped(_ term: String) -> Bool {
    guard term.contains(where: \.isLetter),
      term.contains(where: { $0.isUppercase || $0.isNumber }),
      !term.contains(where: { "./\\:@~_#".contains($0) })
    else { return false }
    let compact = term.filter { $0 != "-" }
    return !(compact.allSatisfy(\.isHexDigit) && compact.contains(where: \.isNumber))
  }

  /// The Dictionary would reject a canonical spelling the normalizer rewrites.
  private static func savable(_ canonical: String) -> Bool {
    guard VocabularyValidation.termCode(canonical) == nil else { return false }
    let formatted = TranscriptNormalizer().normalize(canonical)
    return formatted.reasons.isEmpty && formatted.text == canonical
  }
}
