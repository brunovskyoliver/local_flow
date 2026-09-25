import SwiftUI

/// Insights page: dictation pace, fixes, volume, where dictation goes, and the
/// daily streak. Layout follows the Wispr Flow Insights reference.
struct InsightsView: View {
  enum Tab: String, CaseIterable, Identifiable {
    case usage = "Your usage"
    case voice = "Your voice"
    var id: Self { self }
  }

  @Environment(\.prototypeCompact) private var compact
  let model: InsightsModel
  @State private var tab: Tab = .usage

  var body: some View {
    PrototypePage(maxWidth: 1142) {
      VStack(alignment: .leading, spacing: 0) {
        Text("Insights").font(.flow(size: 26, weight: .medium)).tracking(-0.4)
        tabs
        if let error = model.loadError {
          Text(error).font(.flow(size: 13)).foregroundStyle(SottoPalette.warning)
            .padding(.top, 24)
        }
        if let insights = model.insights {
          Group {
            switch tab {
            case .usage: usage(insights)
            case .voice: voice(insights)
            }
          }
          .padding(.top, 48)
        }
      }
    }
    .task { await model.refresh() }
  }

  private var tabs: some View {
    HStack(spacing: 16) {
      ForEach(Tab.allCases) { item in
        Button {
          tab = item
        } label: {
          VStack(spacing: 6) {
            Text(item.rawValue)
              .font(.flow(size: 15, weight: tab == item ? .medium : .regular))
              .foregroundStyle(tab == item ? SottoPalette.ink : SottoPalette.muted)
            Rectangle().fill(tab == item ? SottoPalette.ink : .clear).frame(height: 2)
          }
          .fixedSize(horizontal: true, vertical: false)
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(tab == item ? .isSelected : [])
        .accessibilityIdentifier("insights.tab.\(item.id)")
      }
      Spacer(minLength: 0)
    }
    .padding(.top, 26)
    .overlay(alignment: .bottom) { SottoPalette.line.frame(height: 1) }
  }

  // MARK: Your usage

  private func usage(_ insights: UsageInsights) -> some View {
    VStack(spacing: 24) {
      HStack(spacing: 24) {
        HStack(spacing: 24) {
          PaceCard(insights: insights)
          FixesCard(insights: insights)
        }
        .frame(maxWidth: .infinity)
        VolumeCard(insights: insights).frame(maxWidth: .infinity)
      }
      .fixedSize(horizontal: false, vertical: true)
      HStack(spacing: 24) {
        AppUsageCard(insights: insights)
        StreakCard(insights: insights)
      }
      .fixedSize(horizontal: false, vertical: true)
    }
    .insightTipLayer()
  }

  // MARK: Your voice

  private func voice(_ insights: UsageInsights) -> some View {
    VStack(spacing: 24) {
      HStack(spacing: 24) {
        InsightCard {
          StatHeading(value: talkTime(insights.spokenSeconds), label: "Time spoken")
        }
        InsightCard {
          StatHeading(value: "\(insights.averageWords.formatted())", label: "Words per dictation")
        }
        InsightCard {
          StatHeading(
            value: "\(insights.longestDictationWords.formatted())", label: "Longest dictation")
        }
      }
      .fixedSize(horizontal: false, vertical: true)
      HourCard(insights: insights)
    }
    .insightTipLayer()
  }
}

func talkTime(_ seconds: Double) -> String {
  let total = Int(seconds.rounded())
  let hours = total / 3_600
  let minutes = (total % 3_600) / 60
  if hours > 0 { return "\(hours)h \(minutes)m" }
  if minutes > 0 { return "\(minutes)m" }
  return "\(total)s"
}

// MARK: Building blocks

private struct InsightCard<Content: View>: View {
  var padding: CGFloat = 18
  @ViewBuilder var content: Content

  var body: some View {
    VStack(alignment: .leading, spacing: 0) { content }
      .padding(padding)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      .background(SottoPalette.card, in: RoundedRectangle(cornerRadius: 6))
      .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(SottoPalette.cardLine) }
  }
}

private struct StatHeading: View {
  let value: String
  let label: String
  var help: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 9) {
      Text(value).font(.flow(size: 28, weight: .medium)).monospacedDigit().tracking(-0.5)
        .lineLimit(1).minimumScaleFactor(0.7)
      HStack(spacing: 6) {
        CapsLabel(text: label)
        if let help { InfoMark(help: help) }
      }
    }
  }
}

private struct CapsLabel: View {
  let text: String
  var color = SottoPalette.muted
  var size: CGFloat = 11.5

  var body: some View {
    Text(text.uppercased()).font(.flow(size: size, weight: .medium)).tracking(size * 0.12)
      .foregroundStyle(color).lineLimit(1).minimumScaleFactor(0.8)
  }
}

private struct InfoMark: View {
  let help: String

  var body: some View {
    Image(systemName: "info.circle").font(.flow(size: 13))
      .foregroundStyle(SottoPalette.muted).accessibilityLabel(help)
      .insightTip(.note(title: help))
  }
}

private struct Rule: View {
  var body: some View { SottoPalette.rule.opacity(0.6).frame(height: 1).padding(.vertical, 17) }
}

// MARK: Cards

private struct PaceCard: View {
  let insights: UsageInsights
  /// The dial runs to 200 words per minute, a brisk conversational pace.
  private static let dialCeiling = 200.0
  /// Commonly cited average typing speed, used for the comparison in the dial.
  private static let typingPace = 40.0

  private var versusTyping: String {
    guard let pace = insights.wordsPerMinute else { return "–" }
    return (Double(pace) / Self.typingPace).formatted(.number.precision(.fractionLength(1))) + "×"
  }

  var body: some View {
    InsightCard {
      StatHeading(
        value: insights.wordsPerMinute.map { "\($0)" } ?? "–", label: "Words per minute",
        help: "Your dictation pace, against typing at 40 words per minute")
      Dial(fraction: Double(insights.wordsPerMinute ?? 0) / Self.dialCeiling) {
        VStack(spacing: 3) {
          Text("vs typing").font(.flow(size: 15)).foregroundStyle(SottoPalette.muted)
          Text(versusTyping).font(.flow(size: 19, weight: .medium))
            .monospacedDigit()
        }
      }
      .padding(.top, 16)
    }
    .accessibilityIdentifier("insights.pace")
  }
}

private struct Dial<Center: View>: View {
  let fraction: Double
  @ViewBuilder var center: Center
  private let diameter: CGFloat = 156
  private let line: CGFloat = 16
  /// A little over a half circle, so the round caps sit just below the centre line.
  private let sweep = 186.0 / 360

  var body: some View {
    ZStack(alignment: .top) {
      arc(sweep).stroke(SottoPalette.heatEmpty, style: .init(lineWidth: line, lineCap: .round))
      arc(sweep * min(max(fraction, 0), 1))
        .stroke(SottoPalette.dataStrong, style: .init(lineWidth: line, lineCap: .round))
      center.padding(.top, 24)
    }
    .frame(width: diameter - line, height: diameter - line)
    .padding(line / 2)
    .frame(width: diameter, height: diameter / 2 + line / 2 + 4, alignment: .top)
  }

  private func arc(_ length: Double) -> some Shape {
    Circle().trim(from: 0, to: length).rotation(.degrees(177))
  }
}

private struct FixesCard: View {
  let insights: UsageInsights

  var body: some View {
    InsightCard {
      StatHeading(
        value: (insights.wordsCorrected + insights.dictionaryFixes).formatted(),
        label: "Fixes made by LocalFlow")
      Rule()
      VStack(alignment: .leading, spacing: 12) {
        row(
          insights.wordsCorrected, "words corrected",
          help: "Words your rewrites changed before inserting")
        row(
          insights.dictionaryFixes, "dictionary fixes",
          help: "Words spelled from your dictionary")
      }
    }
    .accessibilityIdentifier("insights.fixes")
  }

  private func row(_ value: Int, _ label: String, help: String) -> some View {
    HStack {
      Text("\(value.formatted()) \(label)").font(.flow(size: 14.5)).lineLimit(1)
        .minimumScaleFactor(0.85)
      Spacer(minLength: 6)
      InfoMark(help: help)
    }
  }
}

private struct VolumeCard: View {
  let insights: UsageInsights

  var body: some View {
    InsightCard {
      StatHeading(value: insights.totalWords.formatted(), label: "Total words dictated")
      Rule()
      HStack(alignment: .bottom) {
        VStack(alignment: .leading, spacing: 8) {
          Label("Desktop", systemImage: "desktopcomputer").labelStyle(.titleAndIcon)
          Text("\(insights.totalWords.formatted()) words")
        }
        Spacer(minLength: 8)
        Text("\(insights.dictations.formatted()) dictations").foregroundStyle(SottoPalette.muted)
      }
      .font(.flow(size: 14.5))
    }
    .accessibilityIdentifier("insights.volume")
  }
}

private struct AppUsageCard: View {
  @Environment(\.prototypeCompact) private var compact
  let insights: UsageInsights

  private var rows: [(category: UsageCategory, count: Int)] {
    UsageCategory.allCases.enumerated()
      .map {
        (offset: $0.offset, category: $0.element, count: insights.categories[$0.element] ?? 0)
      }
      .sorted { ($1.count, $0.offset) < ($0.count, $1.offset) }
      .map { ($0.category, $0.count) }
  }

  var body: some View {
    InsightCard {
      HStack(alignment: .firstTextBaseline) {
        Text("Desktop usage").font(.flow(size: 29, weight: .medium)).tracking(-0.6)
          .lineLimit(1)
        Spacer(minLength: 8)
        CapsLabel(text: "Total apps used | \(insights.appsUsed)", color: SottoPalette.ink)
      }
      VStack(alignment: .leading, spacing: 16) {
        ForEach(Array(rows.enumerated()), id: \.element.category) { index, row in
          HStack(spacing: 14) {
            Image(systemName: row.category.symbol).font(.flow(size: 18))
              .frame(width: 24)
            bar(row.count, first: index == 0).insightTip(tip(row.category, count: row.count))
            CapsLabel(
              text: "\(row.count.formatted()) \(row.category.label)", color: SottoPalette.ink,
              size: 12.5)
          }
        }
      }
      .padding(.top, 26)
    }
    .accessibilityIdentifier("insights.apps")
  }

  private func tip(_ category: UsageCategory, count: Int) -> InsightTip? {
    guard count > 0 else { return nil }
    let words = insights.categoryWords[category] ?? 0
    return .note(
      title: "\(words.formatted()) \(words == 1 ? "word" : "words")",
      detail: insights.topApp(in: category).map { "Most in \(AppName.display($0))" })
  }

  private func bar(_ count: Int, first: Bool) -> some View {
    let share = insights.dictations == 0 ? 0 : Double(count) / Double(insights.dictations)
    let fill =
      count == 0
      ? SottoPalette.dataQuiet : (first ? SottoPalette.dataStrong : SottoPalette.dataScale[1])
    return Text("\(Int((share * 100).rounded()))%")
      .font(.flow(size: 12, weight: .medium)).monospacedDigit().tracking(0.7)
      .foregroundStyle(.white)
      .frame(width: max(35, share * (compact ? 150 : 300)), height: 28)
      .background(fill, in: RoundedRectangle(cornerRadius: 4))
  }
}

private struct StreakCard: View {
  let insights: UsageInsights
  @State private var page = 0
  private let weeks = 19
  private let calendar = Calendar.current

  var body: some View {
    let today = calendar.startOfDay(for: .now)
    let streaks = UsageInsights.streaks(
      days: insights.days.keys, today: today, calendar: calendar)
    let columns = weekStarts(today: today)
    InsightCard {
      HStack(alignment: .firstTextBaseline) {
        Text("\(streaks.current) day streak").font(.flow(size: 29, weight: .medium))
          .tracking(-0.6).lineLimit(1)
        Spacer(minLength: 8)
        CapsLabel(
          text: "Longest streak | \(streaks.longest) \(streaks.longest == 1 ? "day" : "days")",
          color: SottoPalette.ink)
      }
      VStack(spacing: 8) {
        monthRow(columns).padding(.bottom, 16)
        ForEach(0..<7, id: \.self) { weekday in
          HStack(spacing: 8) {
            Text(weekdaySymbol(weekday)).font(.flow(size: 11))
              .foregroundStyle(SottoPalette.muted).frame(width: 34, alignment: .leading)
            ForEach(columns, id: \.self) { start in
              cell(day(start, weekday), today: today, streak: streaks.currentDays)
            }
          }
        }
      }
      .padding(.top, 24)
      legend.padding(.top, 26)
    }
    .accessibilityIdentifier("insights.streak")
  }

  private func weekStarts(today: Date) -> [Date] {
    let current = calendar.dateInterval(of: .weekOfYear, for: today)?.start ?? today
    return (0..<weeks).compactMap {
      calendar.date(byAdding: .weekOfYear, value: $0 - (weeks - 1) - page * weeks, to: current)
    }
  }

  private func day(_ weekStart: Date, _ offset: Int) -> Date {
    calendar.date(byAdding: .day, value: offset, to: weekStart) ?? weekStart
  }

  private func weekdaySymbol(_ offset: Int) -> String {
    let symbols = calendar.shortWeekdaySymbols
    return symbols[(calendar.firstWeekday - 1 + offset) % 7]
  }

  private func monthRow(_ columns: [Date]) -> some View {
    let earliest = insights.days.keys.min()
    return HStack(spacing: 8) {
      chevron("chevron.left", enabled: earliest.map { $0 < columns[0] } ?? false) { page += 1 }
        .frame(width: 34, alignment: .leading)
      ForEach(columns, id: \.self) { start in
        Color.clear.frame(maxWidth: .infinity).frame(height: 16)
          .overlay(alignment: .leading) {
            if let label = monthLabel(start) {
              Text(label).font(.flow(size: 11)).foregroundStyle(SottoPalette.muted)
                .fixedSize()
            }
          }
      }
    }
    .overlay(alignment: .trailing) {
      chevron("chevron.right", enabled: page > 0) { page -= 1 }
        .background(SottoPalette.card)
    }
  }

  private func monthLabel(_ weekStart: Date) -> String? {
    guard
      let first = (0..<7).map({ day(weekStart, $0) })
        .first(where: { calendar.component(.day, from: $0) == 1 })
    else { return nil }
    return first.formatted(.dateTime.month(.abbreviated))
  }

  private func chevron(_ symbol: String, enabled: Bool, action: @escaping () -> Void)
    -> some View
  {
    Button(action: action) {
      Image(systemName: symbol).font(.flow(size: 12, weight: .medium))
        .frame(width: 18, height: 18).contentShape(.rect)
    }
    .buttonStyle(.plain).foregroundStyle(SottoPalette.muted).opacity(enabled ? 1 : 0.35)
    .disabled(!enabled)
    .accessibilityLabel(symbol == "chevron.left" ? "Earlier weeks" : "Later weeks")
  }

  private func cell(_ date: Date, today: Date, streak: Set<Date>) -> some View {
    let usage = insights.days[date]
    let count = usage?.words ?? 0
    let fill: Color =
      date > today
      ? SottoPalette.heatEmpty.opacity(0.45)
      : (count == 0 ? SottoPalette.heatEmpty : SottoPalette.dataScale[level(count)])
    return RoundedRectangle(cornerRadius: 3).fill(fill)
      .overlay {
        if streak.contains(date) {
          RoundedRectangle(cornerRadius: 3).strokeBorder(SottoPalette.streakOutline, lineWidth: 1.5)
        }
      }
      .aspectRatio(1, contentMode: .fit)
      .frame(maxWidth: .infinity)
      .insightTip(
        date > today
          ? nil
          : .day(
            date: date, words: count, apps: usage?.apps.count ?? 0, topApp: usage?.topApp))
  }

  /// Quartiles of active days, so one heavy day does not wash out the rest.
  private var thresholds: [Int] {
    let counts = insights.days.values.map(\.words).filter { $0 > 0 }.sorted()
    guard !counts.isEmpty else { return [1, 1, 1] }
    return [0.25, 0.5, 0.75].map { counts[min(counts.count - 1, Int(Double(counts.count) * $0))] }
  }

  private func level(_ count: Int) -> Int {
    let limits = thresholds
    if count > limits[2] { return 0 }
    if count > limits[1] { return 1 }
    if count > limits[0] { return 2 }
    return 3
  }

  private var legend: some View {
    HStack(spacing: 8) {
      Text("More")
      ForEach(0..<4, id: \.self) { index in
        RoundedRectangle(cornerRadius: 3).fill(SottoPalette.dataScale[index])
          .frame(width: 16, height: 16)
      }
      Text("Less")
      Spacer(minLength: 8)
      RoundedRectangle(cornerRadius: 3).strokeBorder(SottoPalette.streakOutline, lineWidth: 1.2)
        .frame(width: 16, height: 16)
      Text("Current streak")
    }
    .font(.flow(size: 13)).foregroundStyle(SottoPalette.muted)
  }
}

private struct HourCard: View {
  let insights: UsageInsights
  @State private var hovered: Int?

  var body: some View {
    let hours = insights.hours
    let peak = max(hours.max() ?? 0, 1)
    InsightCard {
      Text("When you dictate").font(.flow(size: 29, weight: .medium)).tracking(-0.6)
      HStack(alignment: .bottom, spacing: 6) {
        ForEach(0..<24, id: \.self) { hour in
          RoundedRectangle(cornerRadius: 3)
            .fill(fill(hour))
            .frame(height: max(5, 130 * CGFloat(hours[hour]) / CGFloat(peak)))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .onHover { inside in
              if inside {
                hovered = hour
              } else if hovered == hour {
                hovered = nil
              }
            }
            .insightTip(tip(hour))
        }
      }
      .frame(height: 130, alignment: .bottom)
      .animation(.easeOut(duration: 0.12), value: hovered)
      .padding(.top, 26)
      HStack(spacing: 0) {
        ForEach([0, 6, 12, 18], id: \.self) { hour in
          Text(hourLabel(hour)).frame(maxWidth: .infinity, alignment: .leading)
        }
      }
      .font(.flow(size: 12)).foregroundStyle(SottoPalette.muted).padding(.top, 10)
    }
    .accessibilityIdentifier("insights.hours")
  }

  private func fill(_ hour: Int) -> Color {
    if insights.hours[hour] == 0 { return SottoPalette.heatEmpty }
    guard let hovered else { return SottoPalette.dataScale[1] }
    return hovered == hour ? SottoPalette.dataScale[0] : SottoPalette.dataScale[2]
  }

  private func tip(_ hour: Int) -> InsightTip {
    let range = "\(time(hour)) – \(time((hour + 1) % 24))"
    let words = insights.hours[hour]
    guard words > 0 else { return .note(title: "No dictation", detail: range) }
    let dictations = insights.hourDictations[hour]
    var detail =
      "\(range) · \(dictations.formatted()) \(dictations == 1 ? "dictation" : "dictations")"
    if let top = insights.hourApps[hour].max(by: { ($0.value, $1.key) < ($1.value, $0.key) }) {
      detail += "\nMost in \(AppName.display(top.key))"
    }
    return .note(title: "\(words.formatted()) \(words == 1 ? "word" : "words")", detail: detail)
  }

  private func hourLabel(_ hour: Int) -> String {
    let date = Calendar.current.date(bySettingHour: hour, minute: 0, second: 0, of: .now) ?? .now
    return date.formatted(.dateTime.hour())
  }

  private func time(_ hour: Int) -> String {
    let date = Calendar.current.date(bySettingHour: hour, minute: 0, second: 0, of: .now) ?? .now
    return date.formatted(date: .omitted, time: .shortened)
  }
}
