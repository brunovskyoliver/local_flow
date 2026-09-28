import Foundation

/// Feature 014: the speech types shared by the app and the `flowd-speech` worker, which
/// compiles the app's recognition sources and nothing that brings in meetings, UI or GRDB.

struct TranscriptionToken: Sendable, Equatable {
  let text: String
  let start: Double
  let end: Double
}

struct TranscriptionWindow: Sendable {
  let text: String
  let tokens: [TranscriptionToken]
  var evidence: RecognitionEvidence? = nil
  /// Feature 013: Dictionary replacements the keyword spotter confirmed for this window.
  /// The raw text stays as recognized; normalization applies these as V002.
  var boostHints: [VocabularyBoostHint] = []
}

protocol TranscriptionRuntime: Sendable {
  func transcribe(_ samples: [Float]) async throws -> TranscriptionWindow
  /// `boost` is the dictation's Dictionary; runtimes without a keyword spotter ignore it.
  func transcribe(_ samples: [Float], boost: VocabularyBoostTerms?) async throws
    -> TranscriptionWindow
  func shutdown() async
}

extension TranscriptionRuntime {
  func transcribe(_ samples: [Float], boost: VocabularyBoostTerms?) async throws
    -> TranscriptionWindow
  {
    try await transcribe(samples)
  }
}

protocol DictationClock: Sendable {
  func sleep(for duration: Duration) async throws
}

struct SystemDictationClock: DictationClock {
  func sleep(for duration: Duration) async throws {
    try await ContinuousClock().sleep(for: duration)
  }
}

struct ModelLease: Sendable, Equatable {
  let sessionID: UUID
  let generation: UInt64
  var workload: ModelWorkload = .speechRecognition
}

enum DictationFailure: Error, Equatable {
  case busy, staleLease, cancelled, invalidAudio, invalidResult, modelUnavailable
}

/// NFC plus locale-independent simple lowercase mapping per scalar, the Dictionary's
/// term folding. No diacritic, compatibility or multi-character folding: `ß` stays
/// distinct from `ss`.
enum TermFolding {
  static func fold(_ term: String) -> [Unicode.Scalar] {
    var folded: [Unicode.Scalar] = []
    for scalar in term.precomposedStringWithCanonicalMapping.unicodeScalars {
      if scalar.properties.changesWhenLowercased {
        folded.append(contentsOf: scalar.properties.lowercaseMapping.unicodeScalars)
      } else {
        folded.append(scalar)
      }
    }
    return folded
  }
}
