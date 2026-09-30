import Foundation

public struct CorrectionCandidate: Equatable, Sendable {
  let sourceText: String
  let replacementText: String

  public init(sourceText: String, replacementText: String) {
    self.sourceText = sourceText
    self.replacementText = replacementText
  }
  var sourceTokens: [String] {
    sourceText.precomposedStringWithCanonicalMapping.split(whereSeparator: \.isWhitespace).map(
      String.init)
  }
  var replacementTokens: [String] {
    replacementText.precomposedStringWithCanonicalMapping.split(whereSeparator: \.isWhitespace).map(
      String.init)
  }
}

public enum CorrectionCandidateDisposition: String, Sendable {
  case autoLearn, suggest, ignore
}

public struct CorrectionCandidateAssessment: Equatable, Sendable {
  public enum Reason: String, Sendable {
    case invalidSpan, protectedLiteral, formattingOnly, functionWords, commonWords
    case ordinaryEdit, lowSimilarity, technicalShape, canonicalMatch, closeSpelling, repeated
    case firstSighting
  }
  public let score: Int

  public let disposition: CorrectionCandidateDisposition
  let reasons: [Reason]
}

public struct CorrectionCandidateContext: Sendable {
  var canonicalTerms: [String] = []
  var previousObservations: Int = 0

  public init(canonicalTerms: [String] = [], previousObservations: Int = 0) {
    self.canonicalTerms = canonicalTerms
    self.previousObservations = previousObservations
  }
}

public protocol CorrectionCandidateScoring: Sendable {
  func assess(_ candidate: CorrectionCandidate, context: CorrectionCandidateContext)
    -> CorrectionCandidateAssessment
}
