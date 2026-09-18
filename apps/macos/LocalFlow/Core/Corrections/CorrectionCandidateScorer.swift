import Foundation

/// Pure, bounded orthographic rules. Hard exclusions cannot be overcome by repetition.
struct CorrectionCandidateScorer: CorrectionCandidateScoring {
  func assess(_ candidate: CorrectionCandidate, context: CorrectionCandidateContext)
    -> CorrectionCandidateAssessment
  {
    typealias Reason = CorrectionCandidateAssessment.Reason
    func ignore(_ reason: Reason) -> CorrectionCandidateAssessment {
      .init(score: 0, disposition: .ignore, reasons: [reason])
    }
    let source = candidate.sourceText.precomposedStringWithCanonicalMapping
    let replacement = candidate.replacementText.precomposedStringWithCanonicalMapping
    guard source.utf8.count <= 256, replacement.utf8.count <= 256,
      (1...3).contains(candidate.sourceTokens.count),
      (1...3).contains(candidate.replacementTokens.count)
    else { return ignore(.invalidSpan) }
    guard !Self.protectedLiteral(source), !Self.protectedLiteral(replacement) else {
      return ignore(.protectedLiteral)
    }
    let left = Self.letters(source)
    let right = Self.letters(replacement)
    guard !left.isEmpty, !right.isEmpty else { return ignore(.formattingOnly) }
    if Self.letters(source, lowercased: false) == Self.letters(replacement, lowercased: false) {
      return ignore(.formattingOnly)
    }
    let tokens = (candidate.sourceTokens + candidate.replacementTokens).map { $0.lowercased() }
    if tokens.allSatisfy(CorrectionStopwords.functionWords.contains) {
      return ignore(.functionWords)
    }
    let replacementWords = candidate.replacementTokens.map { $0.lowercased() }
    // Common targets, including capitalization and inflection edits, are never learned.
    if replacementWords.allSatisfy(CorrectionStopwords.commonWords.contains) {
      return ignore(.commonWords)
    }
    if tokens.contains(where: CorrectionStopwords.functionWords.contains) {
      return ignore(.functionWords)
    }
    let canonical = context.canonicalTerms.prefix(VocabularyStore.maximumEntries).contains {
      $0.utf8.count <= 256 && Self.letters($0) == right
    }
    let shape = candidate.replacementTokens.contains { token in
      let letters = token.filter(\.isLetter)
      return !letters.isEmpty
        && (letters.contains(where: \.isUppercase)
          || token.contains(where: \.isNumber)
          || (token.contains("-") && letters.count >= 4))
    }
    guard shape || canonical else { return ignore(.ordinaryEdit) }
    let similarity = Self.similarity(left, right)
    // Even a name-shaped target must retain some orthographic connection, unless known locally.
    guard similarity >= 0.45 || canonical else { return ignore(.lowSimilarity) }
    var score = 1
    var reasons: [Reason] = []
    if shape {
      score += 3
      reasons.append(.technicalShape)
    }
    if canonical {
      score += 3
      reasons.append(.canonicalMatch)
    }
    if similarity >= 0.625 {
      score += 2
      reasons.append(.closeSpelling)
    }
    if context.previousObservations >= 1 {
      score += 2
      reasons.append(.repeated)
    }
    return .init(score: score, disposition: score >= 6 ? .autoLearn : .suggest, reasons: reasons)
  }

  private static func letters(_ text: String, lowercased: Bool = true) -> String {
    let value = lowercased ? text.lowercased() : text
    return String(value.filter { $0.isLetter || $0.isNumber })
  }

  private static func protectedLiteral(_ text: String) -> Bool {
    // Dots, slashes, colons and @ conservatively exclude domains, IPs, URLs, paths and emails.
    if text.contains(where: { "/\\:@.~".contains($0) }) { return true }
    return !text.contains(where: \.isLetter)
  }

  /// Two rows, at most 256 characters per side; locale-independent Unicode comparison.
  private static func similarity(_ lhs: String, _ rhs: String) -> Double {
    let a = Array(lhs)
    let b = Array(rhs)
    var previous = Array(0...b.count)
    for (i, x) in a.enumerated() {
      var row = [i + 1] + Array(repeating: 0, count: b.count)
      for (j, y) in b.enumerated() {
        row[j + 1] = min(row[j] + 1, previous[j + 1] + 1, previous[j] + (x == y ? 0 : 1))
      }
      previous = row
    }
    return 1 - Double(previous[b.count]) / Double(max(a.count, b.count))
  }
}
