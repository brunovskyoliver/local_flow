import Foundation
import XCTest

@testable import LocalFlow

/// T057: the resolver's phrase table against a meeting started Sunday
/// 2026-09-20 in Europe/Bratislava (the due-dates fixture's anchor).
final class DueDateResolverTests: XCTestCase {

  private let zone = TimeZone(identifier: "Europe/Bratislava")!

  private var anchor: Date {
    var components = DateComponents(
      year: 2026, month: 9, day: 20, hour: 9, minute: 0, second: 0)
    components.timeZone = zone
    return Calendar(identifier: .gregorian).date(from: components)!
  }

  private func resolve(_ phrase: String, on date: Date? = nil)
    -> DueDateResolver.Resolution?
  {
    DueDateResolver.resolve(phrase, on: date ?? anchor, in: zone)
  }

  // MARK: Relative days

  func testRelativeDayPhrases() {
    let cases: [(String, String)] = [
      ("tomorrow", "2026-09-21"),
      ("Tomorrow", "2026-09-21"),
      ("zajtra", "2026-09-21"),
      ("the day after tomorrow", "2026-09-22"),
      ("pozajtra", "2026-09-22"),
    ]
    for (phrase, expected) in cases {
      let resolution = resolve(phrase)
      XCTAssertEqual(
        resolution?.state, .explicitRelativeResolved, phrase)
      XCTAssertEqual(resolution?.date, expected, phrase)
    }
  }

  // MARK: Weekdays

  func testWeekdayNamesResolveToNextOccurrence() {
    // 2026-09-20 is a Sunday; the next Friday is 2026-09-25.
    let cases: [(String, String)] = [
      ("on Friday", "2026-09-25"),
      ("Friday", "2026-09-25"),
      ("v piatok", "2026-09-25"),
      ("piatok", "2026-09-25"),
      ("on Monday", "2026-09-21"),
      ("v pondelok", "2026-09-21"),
    ]
    for (phrase, expected) in cases {
      let resolution = resolve(phrase)
      XCTAssertEqual(
        resolution?.state, .explicitRelativeResolved, phrase)
      XCTAssertEqual(resolution?.date, expected, phrase)
    }
  }

  func testSameWeekdayRollsToNextWeek() {
    // "on Sunday" said on a Sunday means the next Sunday, not today.
    let resolution = resolve("on Sunday")
    XCTAssertEqual(resolution?.date, "2026-09-27")
  }

  func testNextWeekResolvesToFollowingMonday() {
    for phrase in ["next week", "budúci týždeň", "buduci tyzden"] {
      let resolution = resolve(phrase)
      XCTAssertEqual(
        resolution?.state, .explicitRelativeResolved, phrase)
      XCTAssertEqual(resolution?.date, "2026-09-21", phrase)
    }
  }

  // MARK: Absolute dates

  func testAbsoluteDatePhrases() {
    let cases: [(String, String)] = [
      ("25 September", "2026-09-25"),
      ("September 25", "2026-09-25"),
      ("25. septembra", "2026-09-25"),
      ("2026-09-25", "2026-09-25"),
      ("25.9.", "2026-09-25"),
      ("25.9", "2026-09-25"),
      ("25.09.2026", "2026-09-25"),
    ]
    for (phrase, expected) in cases {
      let resolution = resolve(phrase)
      XCTAssertEqual(resolution?.state, .explicitAbsolute, phrase)
      XCTAssertEqual(resolution?.date, expected, phrase)
    }
  }

  func testPastDateWithoutYearRollsToNextYear() {
    // September 5 already passed on September 20 → 2027.
    let resolution = resolve("5 September")
    XCTAssertEqual(resolution?.state, .explicitAbsolute)
    XCTAssertEqual(resolution?.date, "2027-09-05")
  }

  // MARK: Vague terms

  func testVagueTermsStayUnresolved() {
    for phrase in AnalysisPolicy.vagueTerms {
      let resolution = resolve(phrase)
      XCTAssertEqual(
        resolution, DueDateResolver.Resolution(state: .unresolved), phrase)
    }
  }

  // MARK: Unknown phrases

  func testUnknownPhraseReturnsNil() {
    XCTAssertNil(resolve("whenever it works for you"))
    XCTAssertNil(resolve("by the next board review"))
  }

  // MARK: Time zone

  func testResolutionUsesMeetingZoneNotUTC() {
    // 00:30 on 2026-09-21 in Bratislava is still 2026-09-20 in UTC; "tomorrow"
    // must resolve against the local day.
    var components = DateComponents(
      year: 2026, month: 9, day: 21, hour: 0, minute: 30, second: 0)
    components.timeZone = zone
    let lateEvening = Calendar(identifier: .gregorian).date(from: components)!
    let resolution = resolve("tomorrow", on: lateEvening)
    XCTAssertEqual(resolution?.state, .explicitRelativeResolved)
    XCTAssertEqual(resolution?.date, "2026-09-22")
  }
}
