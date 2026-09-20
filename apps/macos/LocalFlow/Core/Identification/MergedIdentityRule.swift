import Foundation

/// Research R11 (FR-026a): the effective identity of a display root with merged members.
/// A `merged` resolution row wins; otherwise the `self` rows of the root and its members
/// agree, or the root is Unknown with a choice to make. `self` rows are never modified.
enum MergedIdentityRule {
  struct IdentityRow: Sendable, Equatable {
    let state: IdentityState
    let origin: IdentityOrigin
    let knownSpeakerID: UUID?
    var secondKnownSpeakerID: UUID? = nil

    var isLinked: Bool {
      knownSpeakerID != nil && (state == .recognized || state == .confirmed)
    }
  }

  struct EffectiveIdentity: Sendable, Equatable {
    /// Nil is Unknown with no row.
    let row: IdentityRow?
    let needsChoice: Bool
  }

  static func effective(root: IdentityRow?, members: [IdentityRow?], resolution: IdentityRow?)
    -> EffectiveIdentity
  {
    if let resolution { return EffectiveIdentity(row: resolution, needsChoice: false) }
    guard !members.isEmpty else { return EffectiveIdentity(row: root, needsChoice: false) }
    let rows = ([root] + members).compactMap { $0 }
    if rows.contains(where: { $0.state == .possible }) {
      return EffectiveIdentity(
        row: IdentityRow(state: .unknown, origin: .keptUnknown, knownSpeakerID: nil),
        needsChoice: true)
    }
    let linked = rows.filter(\.isLinked)
    let distinct = Set(linked.compactMap(\.knownSpeakerID))
    switch distinct.count {
    case 0:
      return EffectiveIdentity(row: root, needsChoice: false)
    case 1:
      let chosen = root.flatMap { $0.isLinked ? $0 : nil } ?? linked[0]
      return EffectiveIdentity(row: chosen, needsChoice: false)
    default:
      return EffectiveIdentity(
        row: IdentityRow(state: .unknown, origin: .keptUnknown, knownSpeakerID: nil),
        needsChoice: true)
    }
  }
}
