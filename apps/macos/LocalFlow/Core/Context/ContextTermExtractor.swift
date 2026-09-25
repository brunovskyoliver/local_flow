import Foundation

/// Redaction (research D8) and candidate-term extraction (research D4). Pure and
/// bounded by the part limits of the snapshot.
enum ContextTermExtractor {
  private static let edgePunctuation = CharacterSet(charactersIn: ".,;:!?()[]{}\"'„“”‚‘’«»<>")

  /// Replaces e-mail, URL, IP and number/amount tokens with `[email]`, `[url]`,
  /// `[ip]` and `[number]`. Whitespace and edge punctuation are kept.
  static func redact(_ text: String) -> String {
    var output = ""
    var token = ""
    func flush() {
      guard !token.isEmpty else { return }
      let leading = token.prefix { isEdge($0) }
      let rest = token.dropFirst(leading.count)
      let trailing = String(rest.reversed().prefix { isEdge($0) }.reversed())
      let inner = String(rest.dropLast(trailing.count))
      if let kind = ProtectedLiteralDetector.protectedClass(of: inner) {
        output += leading + "[\(kind.rawValue)]" + trailing
      } else if isNumeric(inner) {
        // Times, dates, ranges and fractions ("15:30", "2025-03-04", "0/3") are
        // numbers too (FR-006); tokens with letters ("k8s") stay.
        output += leading + "[number]" + trailing
      } else {
        output += token
      }
      token = ""
    }
    for character in text {
      if character.isWhitespace {
        flush()
        output.append(character)
      } else {
        token.append(character)
      }
    }
    flush()
    return output
  }

  private static func isNumeric(_ token: String) -> Bool {
    token.contains(where: \.isNumber) && !token.contains(where: \.isLetter)
  }

  private static func isEdge(_ character: Character) -> Bool {
    character.unicodeScalars.allSatisfy { edgePunctuation.contains($0) }
  }

  // MARK: Terms

  private struct Token {
    let text: String
    let start: Int
    let end: Int
    /// Only spaces or tabs separate it from the previous token.
    let joinsPrevious: Bool
    let sentenceStart: Bool
  }

  /// Candidates from the four parts, nearest to the cursor first, deduplicated, at most 40.
  static func terms(windowTitle: String?, before: String?, after: String?, selected: String?)
    -> [ContextTerm]
  {
    var found: [(term: ContextTerm, distance: Int, order: Int)] = []
    let parts: [(ContextPart, String?)] = [
      (.selectedText, selected), (.beforeCursor, before), (.afterCursor, after),
      (.windowTitle, windowTitle),
    ]
    for (part, text) in parts {
      guard let text else { continue }
      let length = text.count
      for (term, start, end) in candidates(in: text, part: part) {
        let distance =
          switch part {
          case .selectedText: start
          case .beforeCursor: length - end
          case .afterCursor: start
          case .windowTitle: 10_000 + start
          }
        found.append((term, distance, found.count))
      }
    }
    var seen = Set<String>()
    var result: [ContextTerm] = []
    let ordered = found.sorted { ($0.distance, $0.order) < ($1.distance, $1.order) }
    for item in ordered where seen.insert(item.term.text).inserted {
      result.append(item.term)
      if result.count == AppContextSnapshot.maximumTerms { break }
    }
    return result
  }

  private static func candidates(in text: String, part: ContextPart)
    -> [(ContextTerm, Int, Int)]
  {
    let tokens = tokenize(text)
    var result: [(ContextTerm, Int, Int)] = []
    func add(_ value: String, _ kind: ContextTerm.Kind, _ start: Int, _ end: Int) {
      guard value.utf8.count <= ContextTerm.maximumBytes else { return }
      result.append((ContextTerm(text: value, source: part, kind: kind), start, end))
    }
    // A title-cased window title makes every word look like a name.
    let titleCased =
      part == .windowTitle
      && tokens.filter { isWordToken($0.text) && $0.text.count >= 3 }.allSatisfy {
        isCapitalized($0.text)
      }
    // Capitalized words that also occur outside a sentence start.
    let capitalizedElsewhere = Set(
      tokens.filter { !$0.sentenceStart && isNameWord($0.text) }.map(\.text))
    var run: [Token] = []
    func closeRun() {
      defer { run = [] }
      // A sentence-initial first word ("Ask Miroslav …") is capitalized by grammar.
      if let first = run.first, first.sentenceStart, run.count >= 2,
        !capitalizedElsewhere.contains(first.text)
      {
        if hasDiacritics(first.text) { add(first.text, .name, first.start, first.end) }
        run.removeFirst()
      }
      guard !run.isEmpty else { return }
      if !titleCased, run.count >= 2, run.count <= 3 {
        add(run.map(\.text).joined(separator: " "), .name, run[0].start, run[run.count - 1].end)
      }
      for (index, token) in run.enumerated() {
        let named =
          !titleCased
          && (index > 0 || run.count >= 2 || !token.sentenceStart
            || capitalizedElsewhere.contains(token.text))
        if named || hasDiacritics(token.text) { add(token.text, .name, token.start, token.end) }
      }
    }
    for token in tokens {
      if isNameWord(token.text) {
        if !run.isEmpty, !token.joinsPrevious { closeRun() }
        run.append(token)
        continue
      }
      closeRun()
      guard token.text.count >= 3, ProtectedLiteralDetector.protectedClass(of: token.text) == nil,
        !isCommon(token.text)
      else { continue }
      if isIdentifier(token.text) {
        add(token.text, .identifier, token.start, token.end)
      } else if isWordToken(token.text), hasDiacritics(token.text) {
        add(token.text, .name, token.start, token.end)
      }
    }
    closeRun()
    return result
  }

  /// Runs of letters, marks and digits; `_`, `-`, `.` stay inside a token but not at its edges.
  private static func tokenize(_ text: String) -> [Token] {
    var tokens: [Token] = []
    var current = ""
    var start = 0
    var gap = ""
    var index = 0
    func isCore(_ character: Character) -> Bool {
      character.isLetter || character.isNumber
        || character.unicodeScalars.allSatisfy { $0.properties.generalCategory == .nonspacingMark }
    }
    func finish() {
      var core = Substring(current)
      var trailing = ""
      while let last = core.last, !isCore(last) {
        trailing = String(last) + trailing
        core = core.dropLast()
      }
      if !core.isEmpty {
        let previousEnd = tokens.last?.end
        tokens.append(
          Token(
            text: String(core), start: start, end: start + core.count,
            joinsPrevious: previousEnd != nil && !gap.isEmpty
              && gap.allSatisfy { $0 == " " || $0 == "\t" },
            sentenceStart: previousEnd == nil || gap.contains { ".!?\n\r".contains($0) }))
        gap = trailing
      } else {
        gap += current
      }
      current = ""
    }
    for character in text {
      if isCore(character) {
        if current.isEmpty { start = index }
        current.append(character)
      } else if !current.isEmpty, "_-.".contains(character) {
        current.append(character)
      } else {
        if !current.isEmpty { finish() }
        gap.append(character)
      }
      index += 1
    }
    if !current.isEmpty { finish() }
    return tokens
  }

  private static func isWordToken(_ text: String) -> Bool {
    text.allSatisfy { $0.isLetter || $0 == "-" }
  }

  private static func isCapitalized(_ text: String) -> Bool { text.first?.isUppercase == true }

  /// Capitalized letters-only word, 3+ characters, not a common word, no inner case change.
  private static func isNameWord(_ text: String) -> Bool {
    text.count >= 3 && isWordToken(text) && isCapitalized(text) && !isCommon(text)
      && !hasInnerCaseChange(text)
  }

  private static func isCommon(_ text: String) -> Bool {
    CorrectionStopwords.commonWords.contains(text.lowercased())
  }

  private static func hasInnerCaseChange(_ text: String) -> Bool {
    let characters = Array(text)
    return characters.indices.dropFirst().contains {
      characters[$0].isUppercase && characters[$0 - 1].isLowercase
    }
  }

  static func isIdentifier(_ text: String) -> Bool {
    let letters = text.contains { $0.isLetter }
    let digits = text.contains { $0.isNumber }
    let innerUnderscore = text.dropFirst().dropLast().contains("_")
    return letters && (hasInnerCaseChange(text) || innerUnderscore || digits)
  }

  private static func hasDiacritics(_ text: String) -> Bool {
    text.decomposedStringWithCanonicalMapping.unicodeScalars.contains {
      $0.properties.generalCategory == .nonspacingMark
    }
  }
}
