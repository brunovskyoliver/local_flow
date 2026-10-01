import Foundation

/// One line of flowd.log. flowd writes `flowd[ meeting] YYYY/MM/DD HH:MM:SS <subject words>
/// key=value…` (log.LstdFlags, local time; the meeting worker's logger adds the
/// "meeting " prefix before the date). Values are IDs, counts, durations, states and
/// codes, never content. Lines that do not have this shape keep only `raw`.
struct LogLine: Identifiable, Sendable {
  enum Level: String, CaseIterable, Sendable { case info, warning, error }

  enum Service: String, CaseIterable, Sendable {
    case dictation, rewrite, analysis, meeting, live
    case speechWorker = "speech worker"
    case meetingWorker = "meeting worker"
    case channel, flowd, other
  }

  let id: Int
  let raw: String
  let date: Date?
  /// Leading words before the first key=value, e.g. "remote rewrite", "speech window".
  let subject: String
  let fields: [(key: String, value: String)]
  let meeting: Bool

  var parsed: Bool { date != nil }

  subscript(key: String) -> String? { fields.first { $0.key == key }?.value }
  var code: String? { self["code"] }
  var durationMS: Int? { self["duration_ms"].flatMap { Int($0) } }

  init(_ raw: String, id: Int = 0) {
    self.id = id
    self.raw = raw
    var rest = Substring(raw)
    guard rest.hasPrefix("flowd ") else {
      (date, subject, fields, meeting) = (nil, "", [], false)
      return
    }
    rest = rest.dropFirst(6)
    meeting = rest.hasPrefix("meeting ")
    if meeting { rest = rest.dropFirst(8) }
    guard rest.count >= 20, let date = Self.parseDate(rest.prefix(19)) else {
      (self.date, subject, fields) = (nil, "", [])
      return
    }
    self.date = date
    var subject: [Substring] = []
    var fields: [(String, String)] = []
    var tokens = Self.tokens(rest.dropFirst(20))[...]
    while let token = tokens.first, !token.contains("=") {
      subject.append(token)
      tokens = tokens.dropFirst()
    }
    for token in tokens {
      guard let eq = token.firstIndex(of: "=") else {
        // An unquoted value with a space (`worker_build=flowd-speech 1`).
        if let last = fields.popLast() { fields.append((last.0, last.1 + " " + token)) }
        continue
      }
      var value = String(token[token.index(after: eq)...])
      if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
        value = String(value.dropFirst().dropLast())
      }
      fields.append((String(token[..<eq]), value))
    }
    self.subject = subject.joined(separator: " ")
    self.fields = fields
  }

  /// Splits on spaces, keeping a quoted value (Go's %q) with its spaces in one token.
  private static func tokens(_ text: Substring) -> [Substring] {
    var out: [Substring] = []
    var start = text.startIndex
    var quoted = false
    var i = text.startIndex
    while i < text.endIndex {
      let c = text[i]
      if c == "\"" {
        quoted.toggle()
      } else if c == "\\", quoted {
        i = text.index(after: i)
        if i == text.endIndex { break }
      } else if c == " ", !quoted {
        if start < i { out.append(text[start..<i]) }
        start = text.index(after: i)
      }
      i = text.index(after: i)
    }
    if start < text.endIndex { out.append(text[start...]) }
    return out
  }

  private static func parseDate(_ text: Substring) -> Date? {
    // "2026/10/01 22:19:13"
    let digits = text.split(whereSeparator: { "/ :".contains($0) }).compactMap { Int($0) }
    guard digits.count == 6 else { return nil }
    let components = DateComponents(
      year: digits[0], month: digits[1], day: digits[2], hour: digits[3], minute: digits[4],
      second: digits[5])
    return Calendar.current.date(from: components)
  }

  var service: Service {
    let words = subject.split(separator: " ")
    switch words.first {
    case "remote":
      switch words.dropFirst().first {
      case "dictation": return .dictation
      case "rewrite": return .rewrite
      case "analysis": return .analysis
      case "meeting": return .meeting
      case "live": return .live
      default: return .channel
      }
    case "speech", "worker": return meeting ? .meetingWorker : .speechWorker
    case "analysis": return .analysis
    case nil:
      // The HTTP handlers' own lines: analysis lines carry a stage, rewrite lines don't.
      if self["request_id"] != nil { return self["stage"] != nil ? .analysis : .rewrite }
      if self["version"] != nil { return .flowd }
      return .other
    default: return .other
    }
  }

  static let okCodes: Set = ["ok", "succeeded", "closed", "discarded", "cancelled"]
  static let busyCodes: Set = ["busy", "rate_limited", "worker_unavailable", "not_offered"]

  var level: Level {
    if !parsed { return .info }
    if let code {
      if Self.okCodes.contains(code) { return .info }
      return Self.busyCodes.contains(code) ? .warning : .error
    }
    if self["worker_failure"] != nil || subject.hasSuffix("failed")
      || (self["worker_exit"].map { $0 != "0" } ?? false)
    {
      return .error
    }
    if subject.hasSuffix("busy") || subject == "speech worker_unavailable"
      || self["worker_restart_in_ms"] != nil
    {
      return .warning
    }
    if let state = self["worker_state"], state == "restarting" || state == "unavailable" {
      return .warning
    }
    return .info
  }

  /// A speech or meeting worker state line: `speech worker_state=ready`.
  var workerState: String? {
    subject == "speech" ? self["worker_state"] : nil
  }
}
