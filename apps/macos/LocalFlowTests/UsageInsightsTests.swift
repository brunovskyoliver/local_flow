import Foundation
import XCTest

@testable import LocalFlow

final class UsageInsightsTests: XCTestCase {
  private var calendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Europe/Bratislava")!
    return calendar
  }

  private func day(_ value: Int) -> Date {
    calendar.date(from: DateComponents(year: 2026, month: 9, day: value, hour: 9))!
  }

  func testStreakCountsThroughYesterdayAndTracksLongestRun() {
    let days = [1, 2, 3, 4, 10, 11, 12].map(day)
    let alive = UsageInsights.streaks(days: days, today: day(13), calendar: calendar)
    XCTAssertEqual(alive.current, 3)
    XCTAssertEqual(alive.longest, 4)
    XCTAssertEqual(alive.currentDays, Set([10, 11, 12].map { calendar.startOfDay(for: day($0)) }))
    let broken = UsageInsights.streaks(days: days, today: day(14), calendar: calendar)
    XCTAssertEqual(broken.current, 0)
    XCTAssertEqual(broken.longest, 4)
    XCTAssertTrue(broken.currentDays.isEmpty)
  }

  func testStreakAcrossDaylightSavingChange() {
    // Europe/Bratislava leaves summer time on 25 October 2026.
    let dates = (24...27).map {
      calendar.date(from: DateComponents(year: 2026, month: 10, day: $0, hour: 12))!
    }
    let streaks = UsageInsights.streaks(days: dates, today: dates[3], calendar: calendar)
    XCTAssertEqual(streaks.current, 4)
  }

  func testEmptyHistoryHasNoStreakOrPace() {
    let streaks = UsageInsights.streaks(days: [Date](), today: day(1), calendar: calendar)
    XCTAssertEqual(streaks, .init(current: 0, longest: 0, currentDays: []))
    XCTAssertNil(UsageInsights().wordsPerMinute)
  }

  func testPaceUsesOnlyTimedWords() {
    var insights = UsageInsights()
    insights.timedWords = 260
    insights.spokenSeconds = 120
    insights.totalWords = 1_000
    XCTAssertEqual(insights.wordsPerMinute, 130)
  }

  func testCategoriesFollowTargetApplication() {
    XCTAssertEqual(UsageCategory.classify("com.openai.codex"), .aiPrompts)
    XCTAssertEqual(UsageCategory.classify("com.apple.MobileSMS"), .personalMessages)
    XCTAssertEqual(UsageCategory.classify("com.apple.mail"), .emails)
    XCTAssertEqual(UsageCategory.classify("com.tinyspeck.slackmacgap"), .workMessages)
    XCTAssertEqual(UsageCategory.classify("com.apple.TextEdit"), .documents)
    XCTAssertEqual(UsageCategory.classify("com.apple.Safari"), .otherTasks)
    XCTAssertEqual(UsageCategory.classify(nil), .otherTasks)
  }

  func testTopAppsPreferMostWords() {
    var insights = UsageInsights()
    insights.appWords = ["com.openai.codex": 40, "com.t3tools.t3code": 90, "com.apple.Safari": 500]
    XCTAssertEqual(insights.topApp(in: .aiPrompts), "com.t3tools.t3code")
    XCTAssertEqual(insights.topApp(in: .otherTasks), "com.apple.Safari")
    XCTAssertNil(insights.topApp(in: .emails))
    let day = UsageInsights.Day(dictations: 3, words: 30, apps: ["a": 10, "b": 20])
    XCTAssertEqual(day.topApp, "b")
  }

  func testCorrectedWordsIgnoresPunctuationOnlyChanges() {
    XCTAssertEqual(UsageInsights.correctedWords(input: "hello there", output: "hello, there."), 0)
    XCTAssertEqual(
      UsageInsights.correctedWords(input: "um send the the file", output: "send the file"), 2)
    XCTAssertEqual(UsageInsights.correctedWords(input: "laitec parsing", output: "LaTeX parsing"), 1)
  }
}
