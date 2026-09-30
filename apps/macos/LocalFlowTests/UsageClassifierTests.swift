import XCTest

@testable import LocalFlow
@testable import LocalFlowSpeech

/// Feature 015: every row of `contracts/usage-classification.md` "Required cases".
final class UsageClassifierTests: XCTestCase {
  private let john = DictionaryChange(entryID: "j", keyID: "k1", canonical: "John")
  private let zabbix = DictionaryChange(entryID: "z", keyID: "k2", canonical: "Zabbix")
  private let boost = DictionaryChange(entryID: "k8s", keyID: "boost", canonical: "Kubernetes")

  private func outcomes(
    _ changes: [DictionaryChange], inserted: String, reads: [String], before: String = "",
    leadingCut: Bool = false
  ) -> [UsageOutcome] {
    UsageClassifier.classify(
      changes: changes, inserted: inserted, before: before, leadingCut: leadingCut, reads: reads
    ).map(\.1)
  }

  func testContractCases() {
    XCTAssertEqual(
      outcomes([john], inserted: "Ask John about it.", reads: ["Ask John about it."]), [.kept])
    XCTAssertEqual(
      outcomes([john], inserted: "Ask John about it.", reads: ["Ask jon about it."]), [.reverted])
    XCTAssertEqual(
      outcomes([john], inserted: "Ask John about it.", reads: ["Ask Jonathan Smith about it."]),
      [.reverted])
    XCTAssertEqual(outcomes([john], inserted: "Ask John about it.", reads: [""]), [.unclassified])
    XCTAssertEqual(
      outcomes(
        [john, zabbix], inserted: "Ask John and fix Zabbix.", reads: ["Ask John and fix Zabix."]),
      [.kept, .reverted])
    XCTAssertEqual(
      outcomes([john], inserted: "Ask him about it.", reads: ["Ask him about it."]),
      [.unclassified])
    XCTAssertEqual(
      outcomes([john], inserted: "John met John.", reads: ["John met jon."]), [.reverted])
    XCTAssertEqual(
      outcomes(
        [boost], inserted: "Deploy to Kubernetes now.",
        reads: ["Deploy to Kubernetes now. Thanks"]), [.kept])
  }

  func testTheLatestIntactReadDecides() {
    // Fixed, then the message was sent and the field cleared.
    XCTAssertEqual(
      outcomes([john], inserted: "Ask John about it.", reads: ["Ask jon about it.", ""]),
      [.reverted])
    XCTAssertEqual(outcomes([john], inserted: "Ask John about it.", reads: []), [.unclassified])
  }

  func testPunctuationAddedAroundTheTermIsKept() {
    XCTAssertEqual(
      outcomes([john], inserted: "Ask John about it", reads: ["Ask John, about it"]), [.kept])
  }

  func testAChangeInsideALargerRewriteIsNotAttributed() {
    XCTAssertEqual(
      outcomes(
        [john], inserted: "please ask John about the boat today",
        reads: ["please ask someone else today"]), [.unclassified])
  }

  func testMarginAndLeadingCut() {
    XCTAssertEqual(
      outcomes(
        [john], inserted: "ask John now", reads: ["ar team, ask jon now"], before: "ar team,",
        leadingCut: true), [.reverted])
    // An edit to the text before the insertion means the passage moved.
    XCTAssertEqual(
      outcomes(
        [john], inserted: "ask John now", reads: ["Dear tam, ask jon now"], before: "Dear team,"),
      [.unclassified])
  }

  func testMultiWordCanonical() {
    let wispr = DictionaryChange(entryID: "w", keyID: "k", canonical: "Wispr Flow")
    XCTAssertEqual(
      outcomes([wispr], inserted: "try Wispr Flow today", reads: ["try whisper flow today"]),
      [.reverted])
    XCTAssertEqual(
      outcomes([wispr], inserted: "try Wispr Flow today", reads: ["try Wispr Flow today!"]),
      [.kept])
  }

  func testSizeBound() {
    let long =
      Array(repeating: "word", count: UsageClassifier.maximumWords + 1)
      .joined(separator: " ") + " John"
    XCTAssertEqual(outcomes([john], inserted: long, reads: [long]), [.unclassified])
  }
}
