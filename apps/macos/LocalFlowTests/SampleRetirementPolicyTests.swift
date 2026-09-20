import XCTest

@testable import LocalFlow

/// `retire_qd_v1` (research R5): the cap, the quality/diversity score and determinism.
final class SampleRetirementPolicyTests: XCTestCase {
  private func entry(_ axis: Int, quality: Double, id: UUID = UUID())
    -> SampleRetirementPolicy.Entry
  {
    .init(id: id, vector: VoiceVectors.unit(axis: axis), qualityScore: quality)
  }

  func testNoRetirementBelowTheCap() {
    let active = (0..<9).map { entry($0, quality: 0.5) }
    let incoming = entry(9, quality: 0.1)
    let outcome = SampleRetirementPolicy.retire(active: active, incoming: [incoming])
    XCTAssertEqual(outcome.retire, [])
    XCTAssertEqual(Set(outcome.keep), Set(active.map(\.id) + [incoming.id]))
    XCTAssertEqual(outcome.keep.count, 10)
  }

  func testTheCapHoldsAfterAddingAndTheLowestScoresGoFirst() {
    // Ten orthogonal samples of equal quality plus two newcomers: the pair that
    // duplicates an existing direction loses diversity and is retired first.
    var active = (0..<10).map { entry($0, quality: 0.6) }
    let duplicate = entry(0, quality: 0.6)
    let weak = entry(11, quality: 0.05)
    let outcome = SampleRetirementPolicy.retire(active: active, incoming: [duplicate, weak])
    XCTAssertEqual(outcome.keep.count, 10)
    XCTAssertEqual(outcome.retire.count, 2)
    XCTAssertTrue(outcome.retire.contains(weak.id), "Lowest quality retires")
    XCTAssertTrue(
      outcome.retire.contains(duplicate.id) || outcome.retire.contains(active[0].id),
      "One of the duplicated pair retires")
    active.append(duplicate)
  }

  func testScoreWeighsQualityAndDiversity() {
    // Identical direction: the lower-quality copy scores 0.6 × q + 0.4 × 0.
    let good = entry(0, quality: 0.9)
    let poor = entry(0, quality: 0.3)
    let others = (1..<10).map { entry($0, quality: 0.5) }
    let outcome = SampleRetirementPolicy.retire(active: others + [good], incoming: [poor])
    XCTAssertEqual(outcome.retire, [poor.id])
    // A distinct direction survives over a duplicate of higher quality.
    let diverse = entry(15, quality: 0.5)
    let duplicateHigh = entry(0, quality: 0.7)
    let second = SampleRetirementPolicy.retire(
      active: others + [good], incoming: [diverse, duplicateHigh])
    XCTAssertEqual(second.retire.count, 2)
    XCTAssertFalse(second.retire.contains(diverse.id))
    XCTAssertTrue(second.retire.contains(duplicateHigh.id) || second.retire.contains(good.id))
  }

  func testTiesRetireDeterministicallyByID() {
    let low = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    let high = UUID(uuidString: "00000000-0000-0000-0000-00000000000F")!
    let active = (2..<11).map { entry($0, quality: 0.5) }
    let outcome = SampleRetirementPolicy.retire(
      active: active + [entry(0, quality: 0.5, id: high)],
      incoming: [entry(0, quality: 0.5, id: low)])
    XCTAssertEqual(outcome.retire, [low])
    let repeated = SampleRetirementPolicy.retire(
      active: (active + [entry(0, quality: 0.5, id: high)]).reversed(),
      incoming: [entry(0, quality: 0.5, id: low)])
    XCTAssertEqual(repeated.retire, [low])
    XCTAssertEqual(repeated.keep, outcome.keep)
  }
}
