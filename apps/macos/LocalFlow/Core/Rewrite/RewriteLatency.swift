import Foundation

/// Five monotonic instants per attempt, captured on the main actor. The persisted
/// spans and the metric records are derived here; the raw instants are not stored.
struct RewriteInstants: Sendable, Equatable {
  var committed: ContinuousClock.Instant?
  var sent: ContinuousClock.Instant?
  var firstByte: ContinuousClock.Instant?
  var terminal: ContinuousClock.Instant?
  var handedOff: ContinuousClock.Instant?

  init(
    committed: ContinuousClock.Instant? = nil, sent: ContinuousClock.Instant? = nil,
    firstByte: ContinuousClock.Instant? = nil, terminal: ContinuousClock.Instant? = nil,
    handedOff: ContinuousClock.Instant? = nil
  ) {
    self.committed = committed
    self.sent = sent
    self.firstByte = firstByte
    self.terminal = terminal
    self.handedOff = handedOff
  }

  /// Faithful commit to hand-off, or to the terminal state when nothing was inserted.
  var durationMilliseconds: Int? { Self.milliseconds(from: committed, to: handedOff ?? terminal) }
  var firstByteMilliseconds: Int? { Self.milliseconds(from: sent, to: firstByte) }
  var networkMilliseconds: Int? { Self.milliseconds(from: sent, to: terminal) }

  func spans(requestBytes: Int?, responseBytes: Int?) -> RewriteSpans {
    RewriteSpans(
      durationMilliseconds: durationMilliseconds, firstByteMilliseconds: firstByteMilliseconds,
      networkMilliseconds: networkMilliseconds, requestBytes: requestBytes,
      responseBytes: responseBytes)
  }

  static func milliseconds(from start: ContinuousClock.Instant?, to end: ContinuousClock.Instant?)
    -> Int?
  {
    guard let start, let end, end >= start else { return nil }
    let duration = end - start
    let total =
      Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
    return Int(min(total, Double(Int32.max)).rounded())
  }
}

/// The single bucket definition from `contracts/rewrite-quality.md`: whitespace
/// tokens of the input text, never the output or the audio.
enum RewriteInputBucket: String, Codable, Sendable, CaseIterable {
  case short, ordinary, long

  static func bucket(for text: String) -> RewriteInputBucket {
    bucket(wordCount: wordCount(text))
  }
  static func bucket(wordCount: Int) -> RewriteInputBucket {
    switch wordCount {
    case ...25: return .short
    case 26...90: return .ordinary
    default: return .long
    }
  }
  static func wordCount(_ text: String) -> Int {
    text.split(whereSeparator: \.isWhitespace).count
  }
}

/// One measured attempt for the latency report. Durations in milliseconds.
struct RewriteLatencySample: Sendable, Equatable {
  let bucket: RewriteInputBucket
  let identity: String
  let totalMilliseconds: Int
  var firstByteMilliseconds: Int? = nil
  var networkMilliseconds: Int? = nil
  var backendFirstTokenMilliseconds: Int? = nil
  var backendMilliseconds: Int? = nil
}

/// Groups samples by bucket and `backend_model + prompt_version + shield_version`,
/// prints median and p95 per span, "unmeasured" under five samples, and the
/// SC-011 verdicts. Gates are stated, never relaxed.
enum RewriteLatencyReport {
  static let minimumSamples = 5
  static let shortGateMilliseconds = 1_500
  static let shortTargetMilliseconds = 1_000
  static let ordinaryGateMilliseconds = 3_000

  enum Verdict: String, Sendable, Equatable {
    case pass = "PASS"
    case fail = "FAIL"
    case achieved = "ACHIEVED"
    case notAchieved = "NOT ACHIEVED"
    case unmeasured
  }

  struct Group: Sendable, Equatable {
    let bucket: RewriteInputBucket
    let identity: String
    let count: Int
    let totalMedian: Int?
    let totalP95: Int?
    let firstByteMedian: Int?
    let firstByteP95: Int?
    let backendFirstTokenMedian: Int?
    let backendFirstTokenP95: Int?
    let backendMedian: Int?
    let backendP95: Int?
    var measured: Bool { count >= RewriteLatencyReport.minimumSamples }
    var shortGate: Verdict {
      guard bucket == .short, measured, let totalMedian else { return .unmeasured }
      return totalMedian <= shortGateMilliseconds ? .pass : .fail
    }
    var shortTarget: Verdict {
      guard bucket == .short, measured, let totalMedian else { return .unmeasured }
      return totalMedian <= shortTargetMilliseconds ? .achieved : .notAchieved
    }
    var ordinaryGate: Verdict {
      guard bucket == .ordinary, measured, let totalP95 else { return .unmeasured }
      return totalP95 <= ordinaryGateMilliseconds ? .pass : .fail
    }
    /// The span with the largest median; named when a gate is missed.
    var dominantSpan: String {
      let candidates: [(String, Int?)] = [
        ("first_byte", firstByteMedian), ("backend_first_token", backendFirstTokenMedian),
        ("backend", backendMedian),
      ]
      return candidates.compactMap { name, value in value.map { (name, $0) } }
        .max { $0.1 < $1.1 }?.0 ?? "total"
    }
  }

  static func groups(_ samples: [RewriteLatencySample]) -> [Group] {
    var buckets: [String: [RewriteLatencySample]] = [:]
    for sample in samples {
      buckets["\(sample.bucket.rawValue)|\(sample.identity)", default: []].append(sample)
    }
    return buckets.keys.sorted().map { key in
      let members = buckets[key]!
      let first = members[0]
      let measured = members.count >= minimumSamples
      func stat(_ values: [Int], _ f: ([Int]) -> Int?) -> Int? { measured ? f(values) : nil }
      return Group(
        bucket: first.bucket, identity: first.identity, count: members.count,
        totalMedian: stat(members.map(\.totalMilliseconds), median),
        totalP95: stat(members.map(\.totalMilliseconds), p95),
        firstByteMedian: stat(members.compactMap(\.firstByteMilliseconds), median),
        firstByteP95: stat(members.compactMap(\.firstByteMilliseconds), p95),
        backendFirstTokenMedian: stat(members.compactMap(\.backendFirstTokenMilliseconds), median),
        backendFirstTokenP95: stat(members.compactMap(\.backendFirstTokenMilliseconds), p95),
        backendMedian: stat(members.compactMap(\.backendMilliseconds), median),
        backendP95: stat(members.compactMap(\.backendMilliseconds), p95))
    }
  }

  static func render(_ samples: [RewriteLatencySample]) -> String {
    var lines: [String] = ["rewrite latency (ms) by bucket and backend_model+prompt+shield"]
    if samples.isEmpty { lines.append("  no samples") }
    for group in groups(samples) {
      lines.append("  \(group.bucket.rawValue) \(group.identity) n=\(group.count)")
      guard group.measured else {
        lines.append("    unmeasured (fewer than \(minimumSamples) samples)")
        continue
      }
      lines.append("    total median=\(format(group.totalMedian)) p95=\(format(group.totalP95))")
      lines.append(
        "    first_byte median=\(format(group.firstByteMedian)) p95=\(format(group.firstByteP95))")
      lines.append(
        "    backend_first_token median=\(format(group.backendFirstTokenMedian)) p95=\(format(group.backendFirstTokenP95))"
      )
      lines.append(
        "    backend median=\(format(group.backendMedian)) p95=\(format(group.backendP95))")
      switch group.bucket {
      case .short:
        lines.append(
          "    SC-011 short gate (median <= \(shortGateMilliseconds)): \(group.shortGate.rawValue)"
            + (group.shortGate == .fail ? " dominant span: \(group.dominantSpan)" : ""))
        lines.append(
          "    SC-011 short target (median <= \(shortTargetMilliseconds)): \(group.shortTarget.rawValue)"
        )
      case .ordinary:
        lines.append(
          "    SC-011 ordinary gate (p95 <= \(ordinaryGateMilliseconds)): \(group.ordinaryGate.rawValue)"
            + (group.ordinaryGate == .fail ? " dominant span: \(group.dominantSpan)" : ""))
      case .long:
        lines.append("    no gate for long inputs")
      }
    }
    return lines.joined(separator: "\n")
  }

  private static func format(_ value: Int?) -> String { value.map(String.init) ?? "unmeasured" }

  static func median(_ values: [Int]) -> Int? {
    guard !values.isEmpty else { return nil }
    let sorted = values.sorted()
    let middle = sorted.count / 2
    return sorted.count.isMultiple(of: 2)
      ? (sorted[middle - 1] + sorted[middle] + 1) / 2 : sorted[middle]
  }

  /// Nearest-rank 95th percentile.
  static func p95(_ values: [Int]) -> Int? {
    guard !values.isEmpty else { return nil }
    let sorted = values.sorted()
    let rank = Int((0.95 * Double(sorted.count)).rounded(.up))
    return sorted[max(0, min(sorted.count - 1, rank - 1))]
  }
}
