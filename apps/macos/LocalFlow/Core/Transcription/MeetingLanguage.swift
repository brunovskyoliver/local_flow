import Foundation
import NaturalLanguage

/// The language the final meeting pass decodes in. Whisper detects the language on
/// the first 30 s of every request; on a microphone lane where the echo gate has
/// muted the remote voice, that is a few seconds of speech in two minutes, and
/// Slovak windows came back as Romanian or as English translations. A fixed
/// language skips detection and the two encoder passes it costs per window.
///
/// LocalFlow supports English and Slovak only. Automatic chooses between those two
/// per window (the helper never decodes in any other language), which keeps a mixed
/// English/Slovak meeting in each speaker's own language.
enum MeetingLanguage: String, CaseIterable, Identifiable, Sendable {
  case automatic, slovak, english

  /// The default for new installs, for stored values from removed languages
  /// ("czech"), and for anything else unreadable.
  static let defaultLanguage = MeetingLanguage.automatic

  /// The ISO 639-1 codes whisper may decode or detect in.
  static let supportedCodes: Set<String> = ["en", "sk"]

  /// A stored Settings or database value; a removed or unknown language reads as nil.
  init?(storedValue: String?) {
    guard let storedValue, let language = MeetingLanguage(rawValue: storedValue) else {
      return nil
    }
    self = language
  }

  var id: String { rawValue }

  var title: String {
    switch self {
    case .automatic: "Automatic (English/Slovak)"
    case .slovak: "Slovak"
    case .english: "English"
    }
  }

  /// The code the whisper helper takes: `auto` (English or Slovak per window), or an
  /// ISO 639-1 code.
  var whisperCode: String {
    switch self {
    case .automatic: "auto"
    case .slovak: "sk"
    case .english: "en"
    }
  }

  /// Recorded in the pass's pipeline version, so a resume after a change in
  /// Settings starts a new pass instead of mixing languages. `prompt`: the window
  /// prompt leads with the language's context sentence and the Dictionary terms.
  /// `speech_language_v3`: automatic detection chooses between English and Slovak only.
  var pipelineTag: String {
    "lang_\(whisperCode)_prompt_v1" + (self == .automatic ? "+speech_language_v3" : "")
  }

  static let defaultsKey = "settings.meetingLanguage"

  /// One sentence per language the helper can decode in, sent with every meeting
  /// request; the helper puts the one for the window's language in front of the
  /// Dictionary terms. On the 2026-09-20 call this alone took the stock filler
  /// ("Ďakujem za pozornosť.") from 34 rows to 6 and cut word disagreement with
  /// the Wispr transcript from 23.8 % to 20.3 % (research, 009).
  static let contextSentences: [String: String] = [
    "sk": "Prepis pracovného stretnutia v slovenčine.",
    "en": "Transcript of a work meeting in English.",
  ]
}

/// Text language restricted to what LocalFlow supports. Every recognizer in the app
/// goes through here, so short Slovak text is never reported as Czech, Slovenian or
/// Polish, and nothing reports a language outside English and Slovak.
enum SupportedTextLanguage: String, Sendable, Equatable {
  case english = "en"
  case slovak = "sk"

  /// The English/Slovak hypothesis for `text`, with its share of the two
  /// probabilities; nil for text without a hypothesis (digits, another script).
  static func hypothesis(for text: String) -> (language: Self, confidence: Double)? {
    let recognizer = NLLanguageRecognizer()
    recognizer.languageConstraints = [.english, .slovak]
    recognizer.processString(text)
    let hypotheses = recognizer.languageHypotheses(withMaximum: 2)
    let english = hypotheses[.english] ?? 0
    let slovak = hypotheses[.slovak] ?? 0
    guard english.isFinite, slovak.isFinite, english + slovak > 0 else { return nil }
    return english >= slovak
      ? (.english, english / (english + slovak)) : (.slovak, slovak / (english + slovak))
  }

  /// The more likely of English and Slovak, or nil without a hypothesis.
  static func dominant(for text: String) -> Self? { hypothesis(for: text)?.language }

  /// A language only for substantial prose the recognizer is sure about: at least
  /// `minimumLetters` letters in at least `minimumWords` words, and a share of at
  /// least `minimumConfidence`. Short text, names and identifiers stay nil.
  static func confident(
    _ text: String, minimumLetters: Int, minimumWords: Int, minimumConfidence: Double
  ) -> Self? {
    let words = text.split(whereSeparator: { !$0.isLetter })
    guard words.count >= minimumWords,
      words.reduce(0, { $0 + $1.count }) >= minimumLetters,
      let hypothesis = hypothesis(for: text), hypothesis.confidence >= minimumConfidence
    else { return nil }
    return hypothesis.language
  }
}
