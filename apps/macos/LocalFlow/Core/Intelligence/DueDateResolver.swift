import Foundation

/// Client-side due-date phrase resolution (contracts/client-analysis.md).
/// The validator re-resolves every phrase in this table against the meeting's
/// `started_at` in the meeting's `time_zone` and never trusts the server's
/// date blindly: a mismatch marks the item `unresolved` with the original
/// phrase kept; a vague term is `unresolved` even when the server shipped a
/// date; a phrase outside the table returns nil and leaves a consistent
/// server value alone.
enum DueDateResolver {

  /// What a known phrase resolves to: a concrete `YYYY-MM-DD` under an
  /// explicit state, or `unresolved` for a vague term (`date` nil).
  struct Resolution: Equatable, Sendable {
    var state: DueState
    var date: String? = nil
  }

  /// `nil` when the phrase is outside the known table — not an error, just
  /// "the client cannot check this one".
  static func resolve(_ phrase: String, on startedAt: Date, in zone: TimeZone)
    -> Resolution?
  {
    let normalized = normalize(phrase)
    guard !normalized.isEmpty else { return nil }
    if isVagueNormalized(normalized) { return Resolution(state: .unresolved) }

    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = zone
    let base = calendar.startOfDay(for: startedAt)

    if let days = relativeDays[normalized] {
      return relative(days, from: base, calendar: calendar)
    }
    if normalized == "next week" || normalized == "buduci tyzden" {
      return relative(
        daysUntil(weekday: 2, from: base, calendar: calendar),
        from: base, calendar: calendar)
    }
    if let (weekday, extra) = weekdayPhrase(normalized) {
      var delta = daysUntil(weekday: weekday, from: base, calendar: calendar)
      delta += extra
      return relative(delta, from: base, calendar: calendar)
    }
    if let (year, month, day) = absoluteDate(normalized, base: base, calendar: calendar) {
      var components = DateComponents()
      components.year = year
      components.month = month
      components.day = day
      guard let date = calendar.date(from: components) else { return nil }
      return Resolution(state: .explicitAbsolute, date: iso(date, calendar: calendar))
    }
    return nil
  }

  /// The vague-term rule on its own, for callers that only need the check.
  static func isVague(_ phrase: String) -> Bool {
    isVagueNormalized(normalize(phrase))
  }

  // MARK: Tables

  /// Matching folds case and diacritics, so the Slovak forms compare as
  /// `zajtra`, `piatok`, `buduci tyzden`.
  private static func normalize(_ phrase: String) -> String {
    phrase
      .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
      .components(separatedBy: .whitespacesAndNewlines)
      .filter { !$0.isEmpty }
      .joined(separator: " ")
      .trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?"))
  }

  private static func isVagueNormalized(_ normalized: String) -> Bool {
    AnalysisPolicy.vagueTerms.contains { normalize($0) == normalized }
  }

  private static let relativeDays: [String: Int] = [
    "tomorrow": 1,
    "zajtra": 1,
    "the day after tomorrow": 2,
    "day after tomorrow": 2,
    "pozajtra": 2,
  ]

  /// Calendar weekday number (Sunday = 1) by English and Slovak name.
  private static let weekdayNames: [String: Int] = [
    "sunday": 1, "nedela": 1,
    "monday": 2, "pondelok": 2,
    "tuesday": 3, "utorok": 3,
    "wednesday": 4, "streda": 4,
    "thursday": 5, "stvrtok": 5,
    "friday": 6, "piatok": 6,
    "saturday": 7, "sobota": 7,
  ]

  /// English and Slovak (genitive) month names, folded.
  private static let monthNames: [String: Int] = [
    "january": 1, "januara": 1,
    "february": 2, "februara": 2,
    "march": 3, "marca": 3,
    "april": 4, "aprila": 4,
    "may": 5, "maja": 5,
    "june": 6, "juna": 6,
    "july": 7, "jula": 7,
    "august": 8, "augusta": 8,
    "september": 9, "septembra": 9,
    "october": 10, "oktobra": 10,
    "november": 11, "novembra": 11,
    "december": 12, "decembra": 12,
  ]

  // MARK: Phrase parsing

  /// `("on ", "by ", "v ", "vo ", "na ")` weekday, or
  /// `("next ", "buduci ")` weekday — the latter lands a week further out.
  /// Returns the weekday number plus the extra days to add.
  private static func weekdayPhrase(_ normalized: String) -> (Int, Int)? {
    for (prefix, extra) in [("next ", 7), ("buduci ", 7)] where normalized.hasPrefix(prefix) {
      if let weekday = weekdayNames[String(normalized.dropFirst(prefix.count))] {
        return (weekday, extra)
      }
    }
    for prefix in ["on ", "by ", "vo ", "v ", "na "] where normalized.hasPrefix(prefix) {
      if let weekday = weekdayNames[String(normalized.dropFirst(prefix.count))] {
        return (weekday, 0)
      }
    }
    if let weekday = weekdayNames[normalized] { return (weekday, 0) }
    return nil
  }

  /// Strictly-after-the-meeting-day delta in days for `weekday`.
  private static func daysUntil(weekday: Int, from base: Date, calendar: Calendar) -> Int {
    let baseWeekday = calendar.component(.weekday, from: base)
    let delta = (weekday - baseWeekday + 7) % 7
    return delta == 0 ? 7 : delta
  }

  /// `2026-09-25`, `25.9.`/`25.9`/`25.09.2026`, `25 September`,
  /// `September 25`, `25. septembra`. A missing year means the meeting's
  /// year, rolling forward when that date already passed.
  private static func absoluteDate(
    _ normalized: String, base: Date, calendar: Calendar
  ) -> (Int, Int, Int)? {
    let iso = normalized.split(separator: "-")
    if iso.count == 3, iso[0].count == 4,
      let year = Int(iso[0]), let month = Int(iso[1]), let day = Int(iso[2])
    {
      return (year, month, day)
    }

    let dotted = normalized.split(separator: ".", omittingEmptySubsequences: false)
    if dotted.count == 2 || dotted.count == 3,
      let day = Int(dotted[0].trimmingCharacters(in: .whitespaces)),
      let month = Int(dotted[1].trimmingCharacters(in: .whitespaces))
    {
      let year =
        dotted.count == 3
        ? Int(dotted[2].trimmingCharacters(in: .whitespaces))
        : nil
      return rollForward(year: year, month: month, day: day, base: base, calendar: calendar)
    }

    let words = normalized.split(separator: " ")
    guard words.count >= 2, words.count <= 4 else { return nil }
    var month: Int?
    var day: Int?
    for word in words {
      let token = String(word)
      if monthNames[token] != nil {
        month = monthNames[token]
      } else if token == "of" || token == "the" {
        continue
      } else {
        let digits = token.trimmingCharacters(
          in: CharacterSet.decimalDigits.inverted)
        if let value = Int(digits), !digits.isEmpty { day = value }
      }
    }
    guard let month, let day else { return nil }
    return rollForward(year: nil, month: month, day: day, base: base, calendar: calendar)
  }

  /// A year-less date takes the meeting's year, or the next one when that
  /// date already passed in the meeting's zone.
  private static func rollForward(
    year: Int?, month: Int, day: Int, base: Date, calendar: Calendar
  ) -> (Int, Int, Int)? {
    guard (1...12).contains(month), (1...31).contains(day) else { return nil }
    if let year { return (year, month, day) }
    let baseYear = calendar.component(.year, from: base)
    var components = DateComponents()
    components.year = baseYear
    components.month = month
    components.day = day
    guard let candidate = calendar.date(from: components) else { return nil }
    return candidate >= base ? (baseYear, month, day) : (baseYear + 1, month, day)
  }

  private static func relative(_ days: Int, from base: Date, calendar: Calendar)
    -> Resolution
  {
    guard let date = calendar.date(byAdding: .day, value: days, to: base) else {
      return Resolution(state: .unresolved)
    }
    return Resolution(
      state: .explicitRelativeResolved, date: iso(date, calendar: calendar))
  }

  private static func iso(_ date: Date, calendar: Calendar) -> String {
    let components = calendar.dateComponents([.year, .month, .day], from: date)
    return String(
      format: "%04d-%02d-%02d",
      components.year ?? 0, components.month ?? 0, components.day ?? 0)
  }
}
