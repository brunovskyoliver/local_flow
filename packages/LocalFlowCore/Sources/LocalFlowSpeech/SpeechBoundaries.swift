import Foundation

/// Feature 014: the speech types shared by the app and the `flowd-speech` worker, which
/// compiles the app's recognition sources and nothing that brings in meetings, UI or GRDB.

public struct TranscriptionToken: Sendable, Equatable {
  public let text: String
  public let start: Double
  public let end: Double

  public init(text: String, start: Double, end: Double) {
    self.text = text
    self.start = start
    self.end = end
  }
}

public struct TranscriptionWindow: Sendable {
  public let text: String
  public let tokens: [TranscriptionToken]
  public var evidence: RecognitionEvidence? = nil
  /// Feature 013: Dictionary replacements the keyword spotter confirmed for this window.
  /// The raw text stays as recognized; normalization applies these as V002.
  public var boostHints: [VocabularyBoostHint] = []

  public init(
    text: String, tokens: [TranscriptionToken], evidence: RecognitionEvidence? = nil,
    boostHints: [VocabularyBoostHint] = []
  ) {
    self.text = text
    self.tokens = tokens
    self.evidence = evidence
    self.boostHints = boostHints
  }
}

public protocol TranscriptionRuntime: Sendable {
  func transcribe(_ samples: [Float]) async throws -> TranscriptionWindow
  /// `boost` is the dictation's Dictionary; runtimes without a keyword spotter ignore it.
  func transcribe(_ samples: [Float], boost: VocabularyBoostTerms?) async throws
    -> TranscriptionWindow
  func shutdown() async
}

extension TranscriptionRuntime {
  public func transcribe(_ samples: [Float], boost: VocabularyBoostTerms?) async throws
    -> TranscriptionWindow
  {
    try await transcribe(samples)
  }
}

public protocol DictationClock: Sendable {
  func sleep(for duration: Duration) async throws
}

public struct SystemDictationClock: DictationClock {
  public init() {}

  public func sleep(for duration: Duration) async throws {
    try await ContinuousClock().sleep(for: duration)
  }
}

public struct ModelLease: Sendable, Equatable {
  let sessionID: UUID
  let generation: UInt64
  var workload: ModelWorkload = .speechRecognition
}

public enum DictationFailure: Error, Equatable {
  case busy, staleLease, cancelled, invalidAudio, invalidResult, modelUnavailable
}

/// NFC plus locale-independent simple lowercase mapping per scalar, the Dictionary's
/// term folding. No diacritic, compatibility or multi-character folding: `ß` stays
/// distinct from `ss`.
public enum TermFolding {
  public static func fold(_ term: String) -> [Unicode.Scalar] {
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
