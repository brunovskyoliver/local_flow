import Foundation

/// Research R11 (FR-026a): the effective identity of a display root with merged members.
/// A `merged` resolution row wins; otherwise the `self` rows of the root and its members
/// agree, or the root is Unknown with a choice to make. `self` rows are never modified.
public enum MergedIdentityRule {
  public struct IdentityRow: Sendable, Equatable {
    public let state: IdentityState
    public let origin: IdentityOrigin
    public let knownSpeakerID: UUID?
    public var secondKnownSpeakerID: UUID? = nil

    public init(
      state: IdentityState, origin: IdentityOrigin, knownSpeakerID: UUID?,
      secondKnownSpeakerID: UUID? = nil
    ) {
      self.state = state
      self.origin = origin
      self.knownSpeakerID = knownSpeakerID
      self.secondKnownSpeakerID = secondKnownSpeakerID
    }

    public var isLinked: Bool {
      knownSpeakerID != nil && (state == .recognized || state == .confirmed)
    }
  }

  public struct EffectiveIdentity: Sendable, Equatable {
    /// Nil is Unknown with no row.
    public let row: IdentityRow?
    public let needsChoice: Bool

    public init(row: IdentityRow?, needsChoice: Bool) {
      self.row = row
      self.needsChoice = needsChoice
    }
  }

  public static func effective(
    root: IdentityRow?, members: [IdentityRow?], resolution: IdentityRow?
  )
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
