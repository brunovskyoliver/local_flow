import Foundation

/// `overlay_match_v1` (research R13): after a regeneration, re-attach each
/// previously matched overlay to at most one new item. The best source-set
/// Jaccard ≥ 0.5 wins; ties break on the token Jaccard of normalized text; with
/// no source overlap a normalized-text similarity ≥ 0.8 is enough; anything
/// else leaves the overlay orphaned. Only overlays of the same item kind can
/// match an item, and an item takes at most one overlay per field — the
/// earliest edit wins a field collision. A previously orphaned overlay is
/// never resurrected: it has no live `item_id` to carry forward and keeps its
/// `orphaned_at`.
enum OverlayMatcher {
  static let version = "overlay_match_v1"

  /// The outcome of a re-match: `matched` maps each re-attached overlay's id to
  /// its new item; `orphaned` lists overlays that found no new item. Overlays
  /// that were already orphaned or target the summary appear in neither; the
  /// caller leaves them untouched.
  static func match(existing: [AnalysisOverlay], newItems: [StoredItem]) -> (
    matched: [UUID: UUID], orphaned: Set<UUID>
  ) {
    var matched: [UUID: UUID] = [:]
    var orphaned: Set<UUID> = []
    var claimed: Set<String> = []  // "\(itemID)|\(field)" — one overlay per field per item
    for overlay in existing.sorted(by: { $0.createdAt < $1.createdAt }) {
      guard overlay.targetKind != .summary, overlay.orphanedAt == nil,
        let itemKind = overlay.itemKind
      else { continue }
      let candidates = newItems.filter { $0.kind == itemKind }
      guard !candidates.isEmpty else {
        orphaned.insert(overlay.id)
        continue
      }
      let overlaySources = Set(
        (overlay.snapshot.sourceKey ?? "").split(separator: ",").map(String.init))
      let overlayText = normalize(overlay.snapshot.itemText ?? "")
      var best: (item: StoredItem, sourceScore: Double, textScore: Double)? = nil
      for item in candidates {
        let itemSources = Set(item.sources.map(\.sortKey))
        let union = overlaySources.union(itemSources).count
        let sourceScore =
          union == 0
          ? 0 : Double(overlaySources.intersection(itemSources).count) / Double(union)
        let textScore = tokenJaccard(overlayText, normalize(item.text))
        guard sourceScore >= 0.5 || textScore >= 0.8 else { continue }
        if let current = best,
          sourceScore < current.sourceScore
            || (sourceScore == current.sourceScore && textScore <= current.textScore)
        {
          continue
        }
        best = (item, sourceScore, textScore)
      }
      guard let winner = best else {
        orphaned.insert(overlay.id)
        continue
      }
      let claim = "\(winner.item.id)|\(overlay.field.rawValue)"
      if claimed.contains(claim) {
        orphaned.insert(overlay.id)
        continue
      }
      claimed.insert(claim)
      matched[overlay.id] = winner.item.id
    }
    return (matched, orphaned)
  }

  /// Lowercased, non-alphanumerics collapsed to single spaces.
  static func normalize(_ text: String) -> String {
    text.lowercased()
      .unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : " " }
      .reduce(into: "") { $0.append($1) }
      .split(separator: " ").joined(separator: " ")
  }

  static func tokenJaccard(_ a: String, _ b: String) -> Double {
    let left = Set(a.split(separator: " "))
    let right = Set(b.split(separator: " "))
    let union = left.union(right).count
    return union == 0 ? 0 : Double(left.intersection(right).count) / Double(union)
  }
}
