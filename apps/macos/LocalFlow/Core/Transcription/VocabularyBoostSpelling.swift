import AppKit
import LocalFlowSpeech

extension VocabularyBoostPolicy {
  /// Correctly spelled English words, per the system spell checker. The `flowd-speech`
  /// worker has its own copy that loads the same checker without importing AppKit.
  @MainActor static func englishWords(in words: Set<String>) -> Set<String> {
    let checker = NSSpellChecker.shared
    return words.filter {
      checker.checkSpelling(
        of: $0, startingAt: 0, language: "en", wrap: false, inSpellDocumentWithTag: 0,
        wordCount: nil
      ).location == NSNotFound
    }
  }
}

extension FluidAudioEngineFactory {
  /// The app passes its own English-word check to the shared factory (ADR 0029).
  init(
    descriptor: LocalModelDescriptor,
    evidenceObserver: (@Sendable (RecognitionEvidence) async throws -> Void)? = nil,
    boostModel: LocalModelDescriptor? = nil
  ) {
    self.init(
      descriptor: descriptor, evidenceObserver: evidenceObserver, boostModel: boostModel,
      englishWords: { VocabularyBoostPolicy.englishWords(in: $0) })
  }
}
