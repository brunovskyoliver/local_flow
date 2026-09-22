import Foundation

/// The language the final meeting pass decodes in. Whisper detects the language on
/// the first 30 s of every request; on a microphone lane where the echo gate has
/// muted the remote voice, that is a few seconds of speech in two minutes, and
/// Slovak windows came back as Romanian or as English translations. A fixed
/// language skips detection and the two encoder passes it costs per window.
enum MeetingLanguage: String, CaseIterable, Identifiable, Sendable {
  case automatic, slovak, czech, english

  var id: String { rawValue }

  var title: String {
    switch self {
    case .automatic: "Automatic"
    case .slovak: "Slovak"
    case .czech: "Czech"
    case .english: "English"
    }
  }

  /// The code the whisper helper takes: `auto`, or an ISO 639-1 code.
  var whisperCode: String {
    switch self {
    case .automatic: "auto"
    case .slovak: "sk"
    case .czech: "cs"
    case .english: "en"
    }
  }

  /// Recorded in the pass's pipeline version, so a resume after a change in
  /// Settings starts a new pass instead of mixing languages. `prompt`: the window
  /// prompt leads with the language's context sentence and the Dictionary terms.
  var pipelineTag: String {
    "lang_\(whisperCode)_prompt_v1" + (self == .automatic ? "+speech_language_v2" : "")
  }

  static let defaultsKey = "settings.meetingLanguage"

  /// One sentence per language the helper can decode in, sent with every meeting
  /// request; the helper puts the one for the window's language in front of the
  /// Dictionary terms. On the 2026-09-20 call this alone took the stock filler
  /// ("Ďakujem za pozornosť.") from 34 rows to 6 and cut word disagreement with
  /// the Wispr transcript from 23.8 % to 20.3 % (research, 009).
  static let contextSentences: [String: String] = [
    "sk": "Prepis pracovného stretnutia v slovenčine.",
    "cs": "Přepis pracovní schůzky v češtině.",
    "en": "Transcript of a work meeting in English.",
  ]
}
