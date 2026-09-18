import Foundation
import XCTest

@testable import LocalFlow

final class TranscriptNormalizerTests: XCTestCase {
  func testAuthoredFormattingCasesAndExactSecondPass() throws {
    struct Cases: Decodable {
      struct Case: Decodable {
        struct Expected: Decodable {
          let text: String
          let appliedRuleIds: [String]
          let reason: String?
        }
        let id: String
        let input: String
        let coversRuleIds: [String]
        let expected: Expected
      }
      let cases: [Case]
    }
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    let cases = try decoder.decode(
      Cases.self,
      from: Data(
        contentsOf: root.appendingPathComponent("fixtures/quality/normalization-cases.json")))
    for item in cases.cases where !item.coversRuleIds.contains("V001") {
      let result = TranscriptNormalizer().normalize(item.input)
      XCTAssertEqual(Array(result.text.utf8), Array(item.expected.text.utf8), item.id)
      XCTAssertEqual(result.appliedRuleIDs, item.expected.appliedRuleIds, item.id)
      XCTAssertEqual(result.reason?.rawValue, item.expected.reason, item.id)
      let second = TranscriptNormalizer().normalize(result.text)
      XCTAssertEqual(Array(second.text.utf8), Array(result.text.utf8), item.id)
      XCTAssertTrue(second.appliedRuleIDs.isEmpty, item.id)
    }
  }

  func testPunctuationProtectionAcrossQuotedSpansAndTechnicalTokens() {
    for text in [
      "`hello , world`", "``hello , world``", "```hello , world```", "'don't do , that'",
      "\"hello , world\"", "'hello , world'", "“hello , world”",
      "https://hello , world", "hello , foo_bar", "version2 , next", "foo.bar , next",
      "hello , /path", "x@y.sk , next", "a\\b , next", "hello\n, world",
      "hello ,\nworld", "hello , 1world", "hello , world_name",
    ] {
      XCTAssertEqual(TranscriptNormalizer().normalize(text).text, text)
    }
    XCTAssertEqual(TranscriptNormalizer().normalize("don't , stop").text, "don't, stop")
    XCTAssertEqual(TranscriptNormalizer().normalize("čau , svet").text, "čau, svet")
  }

  func testUnexpectedControlsSurviveAndRequireReview() {
    for scalar in ["\u{0000}", "\u{0001}", "\u{000B}", "\u{007F}", "\u{202E}"] {
      let input = " hello\(scalar) world "
      let result = TranscriptNormalizer().normalize(input)
      XCTAssertEqual(result.text, "hello\(scalar) world")
      XCTAssertEqual(result.reason, .unexpectedControl)
      XCTAssertTrue(result.incomplete)
    }
  }

  func testTextAndNFCExpansionBoundsReturnUnchangedInput() {
    let exact = String(repeating: "a", count: 65_536)
    XCTAssertFalse(TranscriptNormalizer().normalize(exact).incomplete)
    for input in [exact + "a", String(repeating: "\u{0344}", count: 16_385)] {
      let result = TranscriptNormalizer().normalize(input)
      XCTAssertEqual(Array(result.text.utf8), Array(input.utf8))
      XCTAssertEqual(result.reason, .normalizationCapacity)
      XCTAssertTrue(result.appliedRuleIDs.isEmpty)
    }
  }

  func testSpanAndMatchBounds() {
    let exactSpans = Array(repeating: "a", count: 16_384).joined(separator: " ")
    XCTAssertFalse(TranscriptNormalizer().normalize(exactSpans).incomplete)
    let overSpans = exactSpans + " a"
    XCTAssertEqual(TranscriptNormalizer().normalize(overSpans).reason, .normalizationCapacity)
    // Lower limits exercise the same guards without making the text/span bound dominant.
    let normalizer = TranscriptNormalizer(maximumSpans: 20, maximumMatches: 2)
    XCTAssertEqual(normalizer.normalize("a , b , c").text, "a, b, c")
    let overMatches = "a , b , c , d"
    let result = normalizer.normalize(overMatches)
    XCTAssertEqual(result.text, overMatches)
    XCTAssertEqual(result.reason, .normalizationCapacity)
    XCTAssertTrue(result.appliedRuleIDs.isEmpty)
  }

  func testNoCommitWithoutObservedFixedPoint() {
    let result = TranscriptNormalizer(maximumPasses: 1).normalize(" hello  world ")
    XCTAssertEqual(result.text, " hello  world ")
    XCTAssertEqual(result.reason, .normalizationNonconvergent)
    XCTAssertTrue(result.appliedRuleIDs.isEmpty)
    XCTAssertFalse(TranscriptNormalizer(maximumPasses: 1).normalize("hello world").incomplete)
  }
}
