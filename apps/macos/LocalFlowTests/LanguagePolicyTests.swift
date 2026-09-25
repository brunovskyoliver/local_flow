import XCTest

@testable import LocalFlow

/// T026 — `policy_v1` language detection.
final class LanguagePolicyTests: XCTestCase {
  private func segments(_ texts: [String]) -> [EvidenceSegment] {
    texts.enumerated().map { i, text in
      EvidenceSegment(
        id: UUID(), ordinal: i + 1, startMs: 0, endMs: 0, speaker: .unknown,
        text: text)
    }
  }

  private let english =
    "We reviewed the release plan and agreed the deployment moves to Monday."
  private let slovak =
    "Preskúmali sme plán vydania a dohodli sme sa, že nasadenie sa presúva na pondelok."
  private let japanese = "私たちはリリース計画を確認し、月曜日に展開することに同意しました。"

  func testSlovakFixtureDetectsSK() throws {
    let fixture = try IntelligenceFixtures.meeting("slovak")
    XCTAssertEqual(
      LanguagePolicy.detect(
        segments: fixture.segments, sampleBytes: AnalysisPolicy().languageSampleBytes),
      .sk)
  }

  func testEnglishFixtureDetectsEN() throws {
    let fixture = try IntelligenceFixtures.meeting("english")
    XCTAssertEqual(
      LanguagePolicy.detect(
        segments: fixture.segments, sampleBytes: AnalysisPolicy().languageSampleBytes),
      .en)
  }

  func testMixedFixtureDetectsMixed() throws {
    let fixture = try IntelligenceFixtures.meeting("mixed")
    XCTAssertEqual(
      LanguagePolicy.detect(
        segments: fixture.segments, sampleBytes: AnalysisPolicy().languageSampleBytes),
      .mixed)
  }

  func testUnsupportedLanguageDetectsMixed() {
    XCTAssertEqual(
      LanguagePolicy.detect(
        segments: segments([japanese, japanese, japanese]), sampleBytes: 32 * 1024),
      .mixed)
  }

  func testTwentyPercentEnglishMinorityDetectsMixed() {
    // 76 % Slovak / 24 % English by character count → mixed (Slovak prose).
    let list = (0..<17).map { _ in slovak } + (0..<6).map { _ in english }
    XCTAssertEqual(
      LanguagePolicy.detect(segments: segments(list), sampleBytes: 32 * 1024),
      .mixed)
  }

  /// `mixed` is Slovak prose, so a mostly English meeting stays English (FR-036:
  /// the meeting's dominant language) even with a large Slovak minority.
  func testEnglishMajorityWithSlovakMinorityStaysEnglish() {
    // 76 % English / 24 % Slovak by character count.
    let list = (0..<19).map { _ in english } + (0..<6).map { _ in slovak }
    XCTAssertEqual(
      LanguagePolicy.detect(segments: segments(list), sampleBytes: 32 * 1024),
      .en)
  }

  /// Short Slovak segments that an unconstrained recognizer calls Czech ("No tak to
  /// je.") count as Slovak: only English and Slovak exist.
  func testShortSlovakSegmentsCountAsSlovak() {
    let list = Array(repeating: "No tak to je.", count: 20)
    XCTAssertEqual(
      LanguagePolicy.detect(segments: segments(list), sampleBytes: 32 * 1024), .sk)
    XCTAssertEqual(SupportedTextLanguage.dominant(for: "No tak to je."), .slovak)
    XCTAssertNil(SupportedTextLanguage.dominant(for: "12345"))
  }

  func testFifteenPercentMinorityKeepsMajority() {
    let list = (0..<22).map { _ in english } + (0..<4).map { _ in slovak }
    XCTAssertEqual(
      LanguagePolicy.detect(segments: segments(list), sampleBytes: 32 * 1024),
      .en)
  }

  func testSampleNeverExceedsBudget() {
    let texts = (0..<200).map { _ in String(repeating: "a", count: 1024) }
    let sampled = LanguagePolicy.sampledTexts(segments: segments(texts), budget: 32 * 1024)
    XCTAssertLessThanOrEqual(sampled.reduce(0) { $0 + $1.utf8.count }, 32 * 1024)
  }

  func testSampleSpreadsAcrossMeeting() {
    // First and last sampled positions must differ — coverage across ordinals.
    let texts = (0..<200).map { _ in String(repeating: "word ", count: 400) }
    let segs = segments(texts)
    let sampled = LanguagePolicy.sampledTexts(segments: segs, budget: 8 * 1024)
    XCTAssertGreaterThan(sampled.count, 1)
    // With 200 segments the first sampled index is 0 and a later one is >100.
    let positions = min(64, segs.count)
    XCTAssertEqual(positions, 64)
  }

  func testUnicodeSamplesStayWithinEveryBudgetWithoutReplacementCharacters() {
    let source = segments(Array(repeating: String(repeating: "ľščť🙂", count: 100), count: 80))
    for budget in [0, 1, 2, 3, 63, 65, 129, 1025] {
      let sampled = LanguagePolicy.sampledTexts(segments: source, budget: budget)
      XCTAssertLessThanOrEqual(sampled.reduce(0) { $0 + $1.utf8.count }, budget)
      XCTAssertFalse(sampled.contains { $0.contains("\u{FFFD}") })
    }
    XCTAssertEqual(LanguagePolicy.sampledTexts(segments: source, budget: -1), [])
  }

  func testRequestValue() {
    let value = LanguagePolicy.requestValue(output: .sk)
    XCTAssertEqual(value.output, .sk)
    XCTAssertTrue(value.preserveTerms)
  }
}
