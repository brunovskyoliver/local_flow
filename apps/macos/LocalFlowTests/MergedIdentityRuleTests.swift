import XCTest

@testable import LocalFlow

/// Research R11 (FR-026a): the effective identity of a merged display root.
final class MergedIdentityRuleTests: XCTestCase {
  private let alice = UUID()
  private let bob = UUID()

  private func linked(_ id: UUID, state: IdentityState = .confirmed)
    -> MergedIdentityRule.IdentityRow
  {
    .init(
      state: state, origin: state == .confirmed ? .userConfirmation : .automaticMatch,
      knownSpeakerID: id)
  }
  private var possible: MergedIdentityRule.IdentityRow {
    .init(state: .possible, origin: .automaticMatch, knownSpeakerID: alice)
  }
  private var unknown: MergedIdentityRule.IdentityRow {
    .init(state: .unknown, origin: .automaticMatch, knownSpeakerID: nil)
  }

  func testSameKnownSpeakerOnBothSidesSurvives() {
    let effective = MergedIdentityRule.effective(
      root: linked(alice), members: [linked(alice, state: .recognized)], resolution: nil)
    XCTAssertEqual(effective.row, linked(alice))
    XCTAssertFalse(effective.needsChoice)
  }

  func testOneSideLinkedAndTheOtherAbsentSurvives() {
    let fromMember = MergedIdentityRule.effective(
      root: nil, members: [linked(bob)], resolution: nil)
    XCTAssertEqual(fromMember.row, linked(bob))
    XCTAssertFalse(fromMember.needsChoice)
    let fromRoot = MergedIdentityRule.effective(
      root: linked(alice), members: [nil, unknown], resolution: nil)
    XCTAssertEqual(fromRoot.row, linked(alice))
    XCTAssertFalse(fromRoot.needsChoice)
  }

  func testDifferentKnownSpeakersIsUnknownWithAChoice() {
    let effective = MergedIdentityRule.effective(
      root: linked(alice), members: [linked(bob)], resolution: nil)
    XCTAssertEqual(effective.row?.state, .unknown)
    XCTAssertEqual(effective.row?.origin, .keptUnknown)
    XCTAssertNil(effective.row?.knownSpeakerID)
    XCTAssertTrue(effective.needsChoice)
  }

  func testAPossibleOnEitherSideIsUnknownWithAChoice() {
    let member = MergedIdentityRule.effective(
      root: linked(alice), members: [possible], resolution: nil)
    XCTAssertTrue(member.needsChoice)
    XCTAssertEqual(member.row?.state, .unknown)
    let root = MergedIdentityRule.effective(root: possible, members: [nil], resolution: nil)
    XCTAssertTrue(root.needsChoice)
  }

  func testAResolutionRowWinsAndUnmergeRestoresBothSelfRows() {
    let resolution = linked(bob)
    let effective = MergedIdentityRule.effective(
      root: linked(alice), members: [possible], resolution: resolution)
    XCTAssertEqual(effective.row, resolution)
    XCTAssertFalse(effective.needsChoice)
    // Unmerged: no members and no resolution, each row stands on its own.
    let rootAlone = MergedIdentityRule.effective(root: linked(alice), members: [], resolution: nil)
    XCTAssertEqual(rootAlone.row, linked(alice))
    let memberAlone = MergedIdentityRule.effective(root: possible, members: [], resolution: nil)
    XCTAssertEqual(memberAlone.row, possible)
    XCTAssertFalse(memberAlone.needsChoice)
  }

  func testNothingLinkedIsUnknownWithoutAChoice() {
    let effective = MergedIdentityRule.effective(
      root: unknown, members: [nil], resolution: nil)
    XCTAssertEqual(effective.row, unknown)
    XCTAssertFalse(effective.needsChoice)
    let absent = MergedIdentityRule.effective(root: nil, members: [], resolution: nil)
    XCTAssertNil(absent.row)
  }
}
