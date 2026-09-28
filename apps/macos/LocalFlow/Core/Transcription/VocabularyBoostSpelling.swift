import AppKit

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
