import Foundation

struct CorrectionCandidate: Equatable, Sendable {
  let sourceText: String
  let replacementText: String
  var sourceTokens: [String] {
    sourceText.precomposedStringWithCanonicalMapping.split(whereSeparator: \.isWhitespace).map(
      String.init)
  }
  var replacementTokens: [String] {
    replacementText.precomposedStringWithCanonicalMapping.split(whereSeparator: \.isWhitespace).map(
      String.init)
  }
}

enum CorrectionCandidateDisposition: String, Sendable {
  case autoLearn, suggest, ignore
}

struct CorrectionCandidateAssessment: Equatable, Sendable {
  enum Reason: String, Sendable {
    case invalidSpan, protectedLiteral, formattingOnly, functionWords, commonWords
    case ordinaryEdit, lowSimilarity, technicalShape, canonicalMatch, closeSpelling, repeated
  }
  let score: Int
  let disposition: CorrectionCandidateDisposition
  let reasons: [Reason]
}

struct CorrectionCandidateContext: Sendable {
  var canonicalTerms: [String] = []
  var previousObservations: Int = 0
}

protocol CorrectionCandidateScoring: Sendable {
  func assess(_ candidate: CorrectionCandidate, context: CorrectionCandidateContext)
    -> CorrectionCandidateAssessment
}
