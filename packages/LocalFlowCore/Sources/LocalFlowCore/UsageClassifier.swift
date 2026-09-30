import Foundation
import LocalFlowSpeech

/// Feature 015, `contracts/usage-classification.md`. Decides whether the user kept or undid
/// each Dictionary change of one insertion, from reads of the field made while the
/// correction learner watched it. Pure; no Accessibility.
public enum UsageClassifier {
  /// Above this many words on either side, nothing is classified.
  static let maximumWords = 1_024

  public static func classify(
    changes: [DictionaryChange], inserted: String, before: String, leadingCut: Bool,
    reads: [String]
  ) -> [(DictionaryChange, UsageOutcome)] {
    let unclassified = changes.map { ($0, UsageOutcome.unclassified) }
    let insertedCores = words(inserted).map(core)
    guard !changes.isEmpty, !insertedCores.isEmpty, insertedCores.count <= maximumWords else {
      return unclassified
    }
    var beforeCores = words(before).map(core)
    if leadingCut, !beforeCores.isEmpty { beforeCores.removeFirst() }
    let needed = (insertedCores.count + 1) / 2
    // The latest read in which the passage is still there decides.
    var aligned: [Bool]?
    for read in reads.reversed() {
      var cores = words(read).map(core)
      if leadingCut {
        guard !cores.isEmpty else { continue }
        cores.removeFirst()
      }
      guard cores.count >= beforeCores.count, Array(cores[..<beforeCores.count]) == beforeCores
      else { continue }
      let rest = Array(cores[beforeCores.count...])
      guard rest.count <= maximumWords * 2 else { continue }
      let matched = alignment(insertedCores, rest)
      if matched.filter({ $0 }).count >= needed {
        aligned = matched
        break
      }
    }
    guard let aligned else { return unclassified }
    return changes.map { change in
      let spans = spans(of: change.canonical, in: insertedCores)
      guard !spans.isEmpty else { return (change, .unclassified) }
      var reverted = false
      for span in spans where span.contains(where: { !aligned[$0] }) {
        let leftAnchored = span.lowerBound == 0 || aligned[span.lowerBound - 1]
        let rightAnchored = span.upperBound == aligned.count || aligned[span.upperBound]
        if leftAnchored && rightAnchored {
          reverted = true
        } else {
          // Changed along with its neighbours: a larger rewrite, not attributable.
          return (change, .unclassified)
        }
      }
      return (change, reverted ? .reverted : .kept)
    }
  }

  static func words(_ text: String) -> [String] {
    text.precomposedStringWithCanonicalMapping.split(whereSeparator: \.isWhitespace)
      .map(String.init)
  }

  /// The word without sentence punctuation at its edges, as `CorrectionDetector` trims;
  /// a word of punctuation only is its own core.
  static func core(_ word: String) -> String {
    let edges = CharacterSet.punctuationCharacters.union(.symbols)
      .subtracting(CharacterSet(charactersIn: "/\\:@~"))
    var scalars = Substring(word).unicodeScalars
    while let first = scalars.first, edges.contains(first) { scalars.removeFirst() }
    while let last = scalars.last, edges.contains(last) { scalars.removeLast() }
    return scalars.isEmpty ? word : String(scalars)
  }

  /// Every run of inserted words whose cores spell `canonical` exactly.
  static func spans(of canonical: String, in cores: [String]) -> [Range<Int>] {
    let target = words(canonical).map(core)
    guard !target.isEmpty, target.count <= cores.count else { return [] }
    return (0...(cores.count - target.count)).compactMap { start in
      Array(cores[start..<(start + target.count)]) == target
        ? start..<(start + target.count) : nil
    }
  }

  /// Which of `a` take part in one longest common subsequence with `b`.
  static func alignment(_ a: [String], _ b: [String]) -> [Bool] {
    let n = a.count
    let m = b.count
    var table = [UInt16](repeating: 0, count: (n + 1) * (m + 1))
    func at(_ i: Int, _ j: Int) -> Int { i * (m + 1) + j }
    for i in stride(from: n - 1, through: 0, by: -1) {
      for j in stride(from: m - 1, through: 0, by: -1) {
        table[at(i, j)] =
          a[i] == b[j]
          ? table[at(i + 1, j + 1)] + 1 : max(table[at(i + 1, j)], table[at(i, j + 1)])
      }
    }
    var aligned = [Bool](repeating: false, count: n)
    var i = 0
    var j = 0
    while i < n, j < m {
      if a[i] == b[j] {
        aligned[i] = true
        i += 1
        j += 1
      } else if table[at(i + 1, j)] >= table[at(i, j + 1)] {
        i += 1
      } else {
        j += 1
      }
    }
    return aligned
  }
}
