import Foundation

/// How rewritten text reaches the target. `waitThenInsert` is the shipped case.
/// `insertThenReplace` (background upgrade) was evaluated and rejected for this
/// release; the seam stays visible so the decision can be revisited without
/// restructuring, but selecting it is a startup precondition failure until the
/// four steps in `specs/003-server-rewriting/research.md` are complete.
enum RewriteDeliveryPolicy: String, Sendable, CaseIterable {
  case waitThenInsert
  case insertThenReplace

  static let shipped: RewriteDeliveryPolicy = .waitThenInsert

  struct NotSelectable: Error, Equatable, CustomStringConvertible {
    let policy: RewriteDeliveryPolicy
    let revisitSteps: [String]
    var description: String {
      "\(policy.rawValue) is not selectable until: " + revisitSteps.joined(separator: "; ")
    }
  }

  /// Exact revisit path from research.md, in order.
  static let revisitSteps = [
    "1. a latency report under contracts/client-rewrite.md showing ordinary-input p95 above 3 s on the reference setup after server-side tuning",
    "2. an AX range-replacement spike per target application filed under acceptance/background-replacement-spike.md",
    "3. a coexistence design with CorrectionLearner",
    "4. a clarification round and an ADR superseding docs/adr/0014-no-background-text-replacement.md",
  ]

  func validateSelectable() throws {
    switch self {
    case .waitThenInsert: return
    case .insertThenReplace: throw NotSelectable(policy: self, revisitSteps: Self.revisitSteps)
    }
  }
}
