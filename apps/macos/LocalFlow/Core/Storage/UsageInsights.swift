import Foundation
import GRDB

/// Where a dictation was delivered, grouped the way the Insights page reports it.
enum UsageCategory: String, CaseIterable, Sendable {
  case otherTasks, aiPrompts, personalMessages, emails, workMessages, documents

  var label: String {
    switch self {
    case .otherTasks: "Other tasks"
    case .aiPrompts: "AI prompts"
    case .personalMessages: "Personal messages"
    case .emails: "Emails"
    case .workMessages: "Work messages"
    case .documents: "Documents"
    }
  }

  var symbol: String {
    switch self {
    case .otherTasks: "infinity"
    case .aiPrompts: "cpu"
    case .personalMessages: "bubble.left"
    case .emails: "envelope"
    case .workMessages: "text.bubble"
    case .documents: "doc.text"
    }
  }

  private static let bundles: [String: UsageCategory] = {
    let groups: [(UsageCategory, [String])] = [
      (
        .aiPrompts,
        [
          "com.openai.chat", "com.openai.codex", "com.anthropic.claudefordesktop",
          "com.t3tools.t3code", "com.emanueledipietro.synara", "ai.perplexity.mac",
          "com.google.GeminiMacOS", "com.mistral.lechat",
        ]
      ),
      (
        .personalMessages,
        [
          "com.apple.MobileSMS", "net.whatsapp.WhatsApp", "desktop.WhatsApp",
          "ru.keepcoder.Telegram", "org.telegram.desktop", "org.whispersystems.signal-desktop",
          "com.facebook.archon", "com.hnc.Discord",
        ]
      ),
      (
        .emails,
        [
          "com.apple.mail", "com.microsoft.Outlook", "com.readdle.smartemail-Mac",
          "com.superhuman.electron", "it.bloop.airmail2", "com.mimestream.Mimestream",
          "com.freron.MailMate",
        ]
      ),
      (
        .workMessages,
        [
          "com.tinyspeck.slackmacgap", "com.microsoft.teams", "com.microsoft.teams2",
          "us.zoom.xos",
        ]
      ),
      (
        .documents,
        [
          "com.apple.iWork.Pages", "com.microsoft.Word", "com.apple.Notes", "com.apple.TextEdit",
          "notion.id", "md.obsidian", "com.lukilabs.lukiapp", "net.shinyfrog.bear",
          "com.microsoft.onenote.mac", "com.apple.iWork.Keynote",
        ]
      ),
    ]
    return Dictionary(
      groups.flatMap { category, ids in ids.map { ($0.lowercased(), category) } },
      uniquingKeysWith: { first, _ in first })
  }()

  static func classify(_ bundleID: String?) -> UsageCategory {
    bundleID.flatMap { bundles[$0.lowercased()] } ?? .otherTasks
  }
}

/// Aggregate dictation usage. Built by streaming rows, so memory holds counters,
/// not transcript text.
struct UsageInsights: Sendable, Equatable {
  var dictations = 0
  var totalWords = 0
  /// Words and audio seconds from dictations whose audio length was recorded.
  var timedWords = 0
  var spokenSeconds: Double = 0
  var wordsCorrected = 0
  var dictionaryFixes = 0
  var longestDictationWords = 0
  var appsUsed = 0
  /// Dictations and words per category.
  var categories: [UsageCategory: Int] = [:]
  var categoryWords: [UsageCategory: Int] = [:]
  /// Words per target application bundle identifier.
  var appWords: [String: Int] = [:]
  /// Usage per local calendar day, keyed by start of day.
  var days: [Date: Day] = [:]
  /// Words dictated per local hour of day.
  var hours = [Int](repeating: 0, count: 24)
  /// Dictations and words per target application, per local hour of day.
  var hourDictations = [Int](repeating: 0, count: 24)
  var hourApps = [[String: Int]](repeating: [:], count: 24)

  struct Day: Sendable, Equatable {
    var dictations = 0
    var words = 0
    /// Words per target application on this day.
    var apps: [String: Int] = [:]
    var topApp: String? { apps.max { ($0.value, $1.key) < ($1.value, $0.key) }?.key }
  }

  /// The application with the most words in a category.
  func topApp(in category: UsageCategory) -> String? {
    appWords.filter { UsageCategory.classify($0.key) == category }
      .max { ($0.value, $1.key) < ($1.value, $0.key) }?.key
  }

  var wordsPerMinute: Int? {
    guard spokenSeconds >= 1, timedWords > 0 else { return nil }
    return Int((Double(timedWords) / (spokenSeconds / 60)).rounded())
  }

  var averageWords: Int {
    dictations == 0 ? 0 : Int((Double(totalWords) / Double(dictations)).rounded())
  }

  static func wordCount(_ text: String) -> Int {
    text.split(whereSeparator: \.isWhitespace).count
  }

  /// Words the rewrite replaced or dropped. Surrounding punctuation is ignored so a
  /// moved comma is not counted as a corrected word.
  static func correctedWords(input: String, output: String) -> Int {
    let tokens = { (text: String) in
      text.split(whereSeparator: \.isWhitespace).map {
        $0.trimmingCharacters(in: .punctuationCharacters)
      }.filter { !$0.isEmpty }
    }
    let before = tokens(input)
    let after = tokens(output)
    guard before != after else { return 0 }
    return after.difference(from: before).removals.count
  }

  struct Streaks: Equatable {
    var current: Int
    var longest: Int
    /// Days of the current streak, for the calendar outline.
    var currentDays: Set<Date>
  }

  /// A streak survives until the end of the day after its last dictation.
  static func streaks(days: some Collection<Date>, today: Date, calendar: Calendar) -> Streaks {
    let sorted = Set(days.map { calendar.startOfDay(for: $0) }).sorted()
    var longest = 0
    var run = 0
    var previous: Date?
    for day in sorted {
      if let previous, calendar.date(byAdding: .day, value: 1, to: previous) == day {
        run += 1
      } else {
        run = 1
      }
      longest = max(longest, run)
      previous = day
    }
    let todayStart = calendar.startOfDay(for: today)
    guard let last = sorted.last,
      last == todayStart || calendar.date(byAdding: .day, value: 1, to: last) == todayStart
    else { return Streaks(current: 0, longest: longest, currentDays: []) }
    var currentDays: Set<Date> = [last]
    var cursor = last
    while let earlier = calendar.date(byAdding: .day, value: -1, to: cursor),
      sorted.contains(earlier)
    {
      currentDays.insert(earlier)
      cursor = earlier
    }
    return Streaks(current: currentDays.count, longest: longest, currentDays: currentDays)
  }
}

extension TranscriptionStore {
  func usageInsights(calendar: Calendar = .current) async throws -> UsageInsights {
    try await database.read { db in
      var insights = UsageInsights()
      let rows = try Row.fetchCursor(
        db,
        sql: """
          SELECT t.created_at, t.target_bundle_id, t.text,
            json_extract(q.detail_json, '$.content.provenance.inputDurationSeconds') AS seconds,
            coalesce(json_array_length(q.detail_json, '$.content.appliedEntryIDs'), 0) AS fixes
          FROM transcriptions t
          LEFT JOIN transcription_quality q ON q.transcription_id = t.id
          """)
      while let row = try rows.next() {
        let text: String = row["text"]
        let words = UsageInsights.wordCount(text)
        let bundle: String? = row["target_bundle_id"]
        let date = Date(timeIntervalSince1970: Double(row["created_at"] as Int64) / 1_000)
        insights.dictations += 1
        insights.totalWords += words
        insights.longestDictationWords = max(insights.longestDictationWords, words)
        insights.dictionaryFixes += row["fixes"] as Int
        if let seconds: Double = row["seconds"], seconds > 0 {
          insights.timedWords += words
          insights.spokenSeconds += seconds
        }
        let category = UsageCategory.classify(bundle)
        insights.categories[category, default: 0] += 1
        insights.categoryWords[category, default: 0] += words
        let start = calendar.startOfDay(for: date)
        insights.days[start, default: .init()].dictations += 1
        insights.days[start, default: .init()].words += words
        if let bundle, !bundle.isEmpty {
          insights.appWords[bundle, default: 0] += words
          insights.days[start, default: .init()].apps[bundle, default: 0] += words
        }
        let hour = calendar.component(.hour, from: date)
        insights.hours[hour] += words
        insights.hourDictations[hour] += 1
        if let bundle, !bundle.isEmpty { insights.hourApps[hour][bundle, default: 0] += words }
      }
      insights.appsUsed = insights.appWords.count
      let rewrites = try Row.fetchCursor(
        db,
        sql: """
          SELECT input_text, output_text FROM rewrite_attempts
          WHERE delivered = 1 AND state = 'succeeded' AND unchanged = 0
          """)
      while let row = try rewrites.next() {
        insights.wordsCorrected += UsageInsights.correctedWords(
          input: row["input_text"], output: row["output_text"])
      }
      return insights
    }
  }
}
