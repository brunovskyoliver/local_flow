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
    let ordered = segments.sorted { $0.ordinal < $1.ordinal }
    let total = ordered.reduce(0) { $0 + $1.text.utf8.count }
    guard total > budget else { return ordered.map(\.text) }
    let positions = min(64, ordered.count)
    let share = max(1, budget / positions)
    var out: [String] = []
    var bytes = 0
    for i in 0..<positions where bytes < budget {
      let segment = ordered[i * ordered.count / positions]
      let text = String(decoding: segment.text.utf8.prefix(share), as: UTF8.self)
      bytes += text.utf8.count
      out.append(text)
    }
    return out
  }
}
