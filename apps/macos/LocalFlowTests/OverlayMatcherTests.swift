import XCTest

@testable import LocalFlow

/// T028 — `overlay_match_v1` re-matching after a regeneration.
final class OverlayMatcherTests: XCTestCase {
  private var seq = 0

  private func item(
    kind: AnalysisItemKind = .actionItem, text: String,
    sources: [SourceRef] = []
  ) -> StoredItem {
    seq += 1
    return StoredItem(
      id: UUID(), kind: kind, ordinal: seq, text: text, sources: sources)
  }

  private func overlay(
    field: OverlayField = .taskText, kind: AnalysisItemKind? = .actionItem,
    target: OverlayTarget? = nil, itemKind: AnalysisItemKind? = nil,
    text: String, sourceKey: String = "", createdAt: Int64 = 0,
    orphanedAt: Int64? = nil
  ) -> AnalysisOverlay {
    let itemID = UUID()
    return AnalysisOverlay(
      id: UUID(), meetingID: UUID(), itemID: itemID,
      targetKind: target ?? .item(itemID),
      itemKind: itemKind ?? kind,
      field: field, value: .text("edited"),
      snapshot: OverlaySnapshot(itemText: text, sourceKey: sourceKey),
      createdAt: createdAt, updatedAt: createdAt, orphanedAt: orphanedAt)
  }

  private func sourceKey(_ refs: [SourceRef]) -> String {
    refs.map(\.sortKey).sorted().joined(separator: ",")
  }

  private let segA = SourceRef.segment(
    UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
  private let segB = SourceRef.segment(
    UUID(uuidString: "00000000-0000-0000-0000-000000000002")!)
  private let segC = SourceRef.segment(
    UUID(uuidString: "00000000-0000-0000-0000-000000000003")!)

  func testSourceJaccardMatch() {
    let item = item(text: "Deploy on Monday", sources: [segA, segB])
    // Overlay source set {A,B} vs {A,B} → Jaccard 1.0.
    let overlay = overlay(
      text: "different text", sourceKey: sourceKey([segA, segB]))
    let result = OverlayMatcher.match(existing: [overlay], newItems: [item])
    XCTAssertEqual(result.matched[overlay.id], item.id)
    XCTAssertTrue(result.orphaned.isEmpty)
  }

  func testSourceJaccardHalfMatches() {
    // {A,B} vs {A,C}: intersection 1, union 3 → 0.33 < 0.5 → falls back to text.
    let narrow = item(text: "completely different words", sources: [segA, segC])
    let overlay = overlay(text: "other words", sourceKey: sourceKey([segA, segB]))
    var result = OverlayMatcher.match(existing: [overlay], newItems: [narrow])
    XCTAssertTrue(result.orphaned.contains(overlay.id))

    // {A,B} vs {A,B,C}: 2/3 ≥ 0.5 → matches even with different text.
    let wider = item(text: "completely different words", sources: [segA, segB, segC])
    result = OverlayMatcher.match(existing: [overlay], newItems: [wider])
    XCTAssertEqual(result.matched[overlay.id], wider.id)
  }

  func testTieBreaksByTokenJaccard() {
    // Both items share the same source set; the one whose text is closer wins.
    let near = item(text: "Ship the release Monday", sources: [segA])
    let far = item(text: "Unrelated words entirely", sources: [segA])
    let overlay = overlay(
      text: "Ship the release on Monday", sourceKey: sourceKey([segA]))
    let result = OverlayMatcher.match(
      existing: [overlay], newItems: [far, near])
    XCTAssertEqual(result.matched[overlay.id], near.id)
  }

  func testTextFallbackWithoutSourceOverlap() {
    // No shared sources, but normalized texts are nearly identical.
    let item = item(
      text: "Deploy the service on Monday morning", sources: [segC])
    let overlay = overlay(
      text: "Deploy the service on Monday morning.", sourceKey: sourceKey([segA]))
    let result = OverlayMatcher.match(existing: [overlay], newItems: [item])
    XCTAssertEqual(result.matched[overlay.id], item.id)
  }

  func testNoMatchOrphans() {
    let item = item(text: "nothing alike", sources: [segC])
    let overlay = overlay(
      text: "Ship the release on Monday", sourceKey: sourceKey([segA]))
    let result = OverlayMatcher.match(existing: [overlay], newItems: [item])
    XCTAssertNil(result.matched[overlay.id])
    XCTAssertTrue(result.orphaned.contains(overlay.id))
  }

  func testKindMismatchOrphans() {
    // A decision-text overlay never attaches to an action item.
    let item = item(kind: .actionItem, text: "Ship it", sources: [segA])
    let overlay = overlay(
      field: .decisionText, kind: .decision, text: "Ship it",
      sourceKey: sourceKey([segA]))
    let result = OverlayMatcher.match(existing: [overlay], newItems: [item])
    XCTAssertTrue(result.orphaned.contains(overlay.id))
  }

  func testOneOverlayPerField() {
    // Two task_text overlays compete for the same item; the earlier wins.
    let item = item(text: "Ship the release", sources: [segA])
    let early = overlay(
      text: "Ship the release", sourceKey: sourceKey([segA]), createdAt: 10)
    let late = overlay(
      text: "Ship the release", sourceKey: sourceKey([segA]), createdAt: 20)
    let result = OverlayMatcher.match(
      existing: [late, early], newItems: [item])
    XCTAssertEqual(result.matched[early.id], item.id)
    XCTAssertTrue(result.orphaned.contains(late.id))
  }

  func testDifferentFieldsShareAnItem() {
    let item = item(text: "Ship the release", sources: [segA])
    let textOverlay = overlay(
      field: .taskText, text: "Ship the release", sourceKey: sourceKey([segA]))
    let ownerOverlay = overlay(
      field: .owner, text: "Ship the release", sourceKey: sourceKey([segA]))
    let result = OverlayMatcher.match(
      existing: [textOverlay, ownerOverlay], newItems: [item])
    XCTAssertEqual(result.matched[textOverlay.id], item.id)
    XCTAssertEqual(result.matched[ownerOverlay.id], item.id)
  }

  func testSummaryOverlayUntouched() {
    let overlay = overlay(
      field: .summaryText, kind: nil, target: .summary, itemKind: nil,
      text: "the summary")
    let result = OverlayMatcher.match(
      existing: [overlay], newItems: [item(text: "x", sources: [segA])])
    XCTAssertNil(result.matched[overlay.id])
    XCTAssertFalse(result.orphaned.contains(overlay.id))
  }

  func testStatusOverlayMatchesLikeText() {
    let item = item(text: "Ship the release", sources: [segA])
    var overlay = overlay(
      field: .status, text: "Ship the release", sourceKey: sourceKey([segA]))
    overlay.value = .status(.dismissed)
    let result = OverlayMatcher.match(existing: [overlay], newItems: [item])
    XCTAssertEqual(result.matched[overlay.id], item.id)
  }

  func testAlreadyOrphanedStaysOrphaned() {
    let item = item(text: "Ship the release", sources: [segA])
    let overlay = overlay(
      text: "Ship the release", sourceKey: sourceKey([segA]), orphanedAt: 5)
    let result = OverlayMatcher.match(existing: [overlay], newItems: [item])
    XCTAssertNil(result.matched[overlay.id])
    XCTAssertFalse(result.orphaned.contains(overlay.id))
  }

  func testEmptyCandidateListOrphans() {
    let overlay = overlay(text: "x", sourceKey: sourceKey([segA]))
    let result = OverlayMatcher.match(existing: [overlay], newItems: [])
    XCTAssertTrue(result.orphaned.contains(overlay.id))
  }

  func testNormalize() {
    XCTAssertEqual(
      OverlayMatcher.normalize("  Deploy: The-Service, Monday!! "),
      "deploy the service monday")
  }
}
