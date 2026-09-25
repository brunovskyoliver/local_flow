import Foundation

/// `policy_v1` language detection (research R10). `detect` samples at most
/// `sampleBytes` of final segment text, spread evenly across the meeting, runs an
/// English/Slovak-constrained `NLLanguageRecognizer` per sampled segment and tallies
/// characters per language (text with no hypothesis, such as another script, counts
/// as other). A supported language needs ≥ 80 % of sampled characters to win.
/// Below that — or with dominant other text — the result is `mixed` (Slovak prose,
/// English terms kept), except that English with at least twice the Slovak text
/// yields `en`: a clearly English meeting is never summarized in Slovak (FR-036).
enum LanguagePolicy {
  static let version = "policy_v1"

  /// The `language_policy` request value: `{"output": …, "preserve_terms": true}`.
  static func requestValue(output: AnalysisLanguage) -> AnalysisRequest.LanguagePolicyValue {
    AnalysisRequest.LanguagePolicyValue(output: output, preserveTerms: true)
  }

  static func resolve(
    segments: [EvidenceSegment], sampleBytes: Int,
    meetingLanguage: MeetingLanguage?, transcriptPipeline: String?
  ) -> AnalysisLanguage {
    // The language the final pass actually decoded in wins over the meeting's
    // current choice, which may have changed after the transcript was made.
    if let recorded = recordedLanguage(transcriptPipeline) { return recorded }
    switch meetingLanguage {
    case .slovak?: return .sk
    case .english?: return .en
    case .automatic?, nil: break
    }
    return detect(segments: segments, sampleBytes: sampleBytes)
  }

  /// A fixed `lang_<sk|en>_prompt_v<1|2>` tag recorded in the final pass identity.
  static func recordedLanguage(_ transcriptPipeline: String?) -> AnalysisLanguage? {
    let recorded = (transcriptPipeline ?? "").split(separator: "+").filter {
      $0.hasPrefix("lang_")
    }
    guard recorded.count == 1, let tag = recorded.first else { return nil }
    let parts = tag.split(separator: "_")
    guard parts.count == 4, parts[0] == "lang", parts[2] == "prompt",
      parts[3] == "v1" || parts[3] == "v2"
    else { return nil }
    switch parts[1] {
    case "sk": return .sk
    case "en": return .en
    default: return nil
    }
  }

  static func detect(segments: [EvidenceSegment], sampleBytes: Int) -> AnalysisLanguage {
    var english = 0
    var slovak = 0
    var other = 0
    for text in sampledTexts(segments: segments, budget: sampleBytes) {
      let count = text.count
      guard count > 0 else { continue }
      switch SupportedTextLanguage.dominant(for: text) {
      case .english: english += count
      case .slovak: slovak += count
      case nil: other += count
      }
    }
    let total = english + slovak + other
    guard total > 0 else { return .mixed }
    let top = max(english, slovak)
    guard other < top else { return .mixed }  // dominant text has no en/sk hypothesis
    guard Double(top) / Double(total) < 0.8 else { return english >= slovak ? .en : .sk }
    // `mixed` is Slovak prose: a clear English majority (at least twice the Slovak
    // text) keeps English instead; a near-even meeting stays `mixed`.
    return english >= 2 * slovak ? .en : .mixed
  }

  /// Evenly spaced segment texts whose combined byte count stays under
  /// `budget`. With more text than the budget, up to 64 equally spaced
  /// positions are sampled, each truncated to its share.
  static func sampledTexts(segments: [EvidenceSegment], budget: Int) -> [String] {
    guard budget > 0, !segments.isEmpty else { return [] }
    let ordered = segments.sorted { $0.ordinal < $1.ordinal }
    let total = ordered.reduce(0) { $0 + $1.text.utf8.count }
    guard total > budget else { return ordered.map(\.text) }
    let positions = min(64, ordered.count, budget)
    let share = budget / positions
    var out: [String] = []
    for i in 0..<positions {
      let segment = ordered[i * ordered.count / positions]
      var prefix = Array(segment.text.utf8.prefix(share))
      while !prefix.isEmpty, String(bytes: prefix, encoding: .utf8) == nil {
        prefix.removeLast()
      }
      if let text = String(bytes: prefix, encoding: .utf8), !text.isEmpty { out.append(text) }
    }
    return out
  }
}
