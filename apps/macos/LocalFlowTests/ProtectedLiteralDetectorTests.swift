import XCTest

@testable import LocalFlow

/// T063: the protected-literal detector's classes, verbatim matching, the
/// stem rule and the owner-name exclusion (research R5).
final class ProtectedLiteralDetectorTests: XCTestCase {

  private func violations(
    in text: String, evidence: String, excluding names: Set<String> = []
  ) -> [String] {
    ProtectedLiteralDetector.violations(in: text, evidence: evidence, excluding: names)
      .map(\.literal)
  }

  // MARK: Address and identifier classes

  func testAddressLiteralsRequireVerbatimEvidence() {
    let text =
      "Ping 172.19.223.30 or fe80::1, see https://example.com/x and api.internal.example.com, mail ops@example.com."
    XCTAssertTrue(violations(in: text, evidence: "unrelated words").count >= 5)
    let evidence =
      "The server is 172.19.223.30 and fe80::1; docs at https://example.com/x; host api.internal.example.com; contact ops@example.com."
    XCTAssertTrue(violations(in: text, evidence: evidence).isEmpty)
  }

  func testMutatedIPv4OctetFails() {
    let violations = violations(
      in: "Check the server at 172.19.223.20",
      evidence: "The new server is at 172.19.223.30.")
    XCTAssertEqual(violations, ["172.19.223.20"])
  }

  // MARK: Numbers with currency or unit

  func testCurrencyAndUnitNumbersAreVerbatim() {
    let text = "The invoice is 1 200 €, the seat costs $40 and the image takes 3 GB."
    let evidence = "Invoice 1 200 €. Seat $40. The image takes 3 GB."
    XCTAssertTrue(violations(in: text, evidence: evidence).isEmpty)
  }

  func testMutatedPriceFails() {
    let violations = violations(
      in: "The license costs $1,300 per year",
      evidence: "The license costs $1,200 per year.")
    XCTAssertEqual(violations, ["$1,300"])
  }

  // MARK: Dates and times

  func testDateFormsInBothLanguagesAreVerbatim() {
    for literal in ["25 September", "September 25", "25. septembra", "2026-09-25", "25.9."] {
      XCTAssertEqual(
        violations(in: "We ship \(literal)", evidence: "nothing"), [literal], literal)
      XCTAssertTrue(
        violations(in: "We ship \(literal)", evidence: "ships \(literal)").isEmpty, literal)
    }
  }

  func testTimesAndVersionStringsAreVerbatim() {
    let text = "At 14:30 we ship 1.2.3 as v2."
    let found = violations(in: text, evidence: "nothing at all")
    XCTAssertTrue(found.contains("14:30"))
    XCTAssertTrue(found.contains("1.2.3"))
    XCTAssertTrue(found.contains("v2"))
    XCTAssertTrue(violations(in: text, evidence: "At 14:30 we ship 1.2.3 as v2.").isEmpty)
  }

  // MARK: Digit-bearing tokens

  func testDigitBearingTokensAreVerbatim() {
    for literal in ["M6", "PRJ-114", "qwen3.5"] {
      XCTAssertEqual(
        violations(in: "The \(literal) build", evidence: "nothing"), [literal], literal)
      XCTAssertTrue(
        violations(in: "The \(literal) build", evidence: "the \(literal) unit").isEmpty,
        literal)
    }
  }

  // MARK: Proper nouns and the stem rule

  /// A capitalized token not at sentence start and not in the stoplist is a
  /// protected proper noun; Slovak inflection survives through the stem
  /// rule (shared prefix ≥ max(4, length − 3), diacritics preserved).
  func testProperNounStemRule() {
    XCTAssertTrue(
      violations(in: "Pošle to Martinovi.", evidence: "Martin to posle").isEmpty)
    XCTAssertTrue(
      violations(in: "Talked s Odoom about it", evidence: "we use Odoo").isEmpty)
    // "Odoom"/"Odoo" shares 4 chars — the minimum for a 4-letter stem.
    XCTAssertEqual(
      violations(in: "Talked to Odomovici", evidence: "we use Odoo"),
      ["Odomovici"])
  }

  /// A capitalized word at sentence start is not a proper-noun candidate.
  func testSentenceStartIsNotAProperNoun() {
    XCTAssertTrue(
      violations(in: "Deployment moves to Monday.", evidence: "nothing").isEmpty)
  }

  /// Weekdays and function words are in the stoplist, never literals.
  func testStoplistIsNotProtected() {
    XCTAssertTrue(
      violations(in: "It ships on Friday in September.", evidence: "nothing").isEmpty)
    XCTAssertTrue(
      violations(in: "Nasleduje v piatok.", evidence: "nič").isEmpty)
  }

  // MARK: Owner-name exclusion

  /// Participant owner names are rendered from the speaker record, not from
  /// model text — they are never checked.
  func testExcludedOwnerNamesAreSkipped() {
    XCTAssertTrue(
      violations(
        in: "Pošle to Martinovi.", evidence: "nothing",
        excluding: ["Martin"]
      ).isEmpty)
  }
}
