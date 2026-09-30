import LocalFlowSpeech
import UIKit

/// The phone's English-word check for V002 boost decisions, the counterpart of the Mac's
/// `NSSpellChecker` check (research R2, R16).
enum TextCheckerSpelling {
  @MainActor static func englishWords(in words: Set<String>) -> Set<String> {
    let checker = UITextChecker()
    return words.filter { word in
      checker.rangeOfMisspelledWord(
        in: word, range: NSRange(location: 0, length: (word as NSString).length), startingAt: 0,
        wrap: false, language: "en_US"
      ).location == NSNotFound
    }
  }
}

extension FluidAudioEngineFactory {
  init(descriptor: LocalModelDescriptor, boostModel: LocalModelDescriptor?) {
    self.init(
      descriptor: descriptor, boostModel: boostModel,
      englishWords: { TextCheckerSpelling.englishWords(in: $0) })
  }
}
