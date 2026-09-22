import Foundation
import NaturalLanguage

/// `policy_v1` language detection (research R10). `detect` samples at most
/// `sampleBytes` of final segment text, spread evenly across the meeting, runs
/// `NLLanguageRecognizer` per sampled segment and tallies characters per
/// language. A supported language needs ≥ 80 % of sampled characters to win;
/// a minority at ≥ 20 % — or a dominant unsupported language — yields `mixed`.
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
    if let meetingLanguage {
      switch meetingLanguage {
      case .slovak: return .sk
      case .english: return .en
      case .automatic, .czech: break
      }
    } else {
      let recorded = (transcriptPipeline ?? "").split(separator: "+").filter {
        $0.hasPrefix("lang_")
      }
      if recorded.count == 1, let tag = recorded.first {
        let parts = tag.split(separator: "_")
        if parts.count == 4, parts[0] == "lang", parts[2] == "prompt",
          parts[3] == "v1" || parts[3] == "v2"
        {
          if parts[1] == "sk" { return .sk }
          if parts[1] == "en" { return .en }
        }
      }
    }
    return detect(segments: segments, sampleBytes: sampleBytes)
  }

  static func detect(segments: [EvidenceSegment], sampleBytes: Int) -> AnalysisLanguage {
    var english = 0
    var slovak = 0
    var other = 0
    for text in sampledTexts(segments: segments, budget: sampleBytes) {
      let count = text.count
      guard count > 0 else { continue }
      switch NLLanguageRecognizer.dominantLanguage(for: text) {
      case .english: english += count
      case .slovak: slovak += count
      default: other += count
      }
    }
    let total = english + slovak + other
    guard total > 0 else { return .mixed }
    let top = max(english, slovak)
    guard other < top else { return .mixed }  // dominant language unsupported
    guard Double(top) / Double(total) >= 0.8 else { return .mixed }
    return english >= slovak ? .en : .sk
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
