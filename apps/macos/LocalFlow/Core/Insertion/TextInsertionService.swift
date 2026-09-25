import Foundation

public enum InsertionOutcome: Equatable, Sendable {
  case confirmed
  case notInserted(TargetIssue)
  case uncertain(TargetIssue)
}

public actor TextInsertionService {
  private let adapter: any TextAccessibilityAdapter
  private var activeAttempt: UUID?
  private var completedAttempt: UUID?
  private var completedOutcome: InsertionOutcome?

  public init(adapter: any TextAccessibilityAdapter = SystemTextAccessibilityAdapter()) {
    self.adapter = adapter
  }

  public func captureTarget() async -> CapturedTarget? {
    try? await adapter.captureTarget()
  }

  public func evaluate(_ target: CapturedTarget) async -> TargetValidation {
    await adapter.validate(target)
  }

  /// Bounded read for correction learning; never runs while an insertion attempt is active.
  public func readText(on target: CapturedTarget, location: Int, length: Int) async throws
    -> String
  {
    guard activeAttempt == nil else { throw TargetIssue.unsupported }
    return try await adapter.readText(on: target, location: location, length: length)
  }

  public func insertOnce(
    attemptID: UUID, target: CapturedTarget, text: String
  ) async -> InsertionOutcome {
    guard text.utf8.count <= 64 * 1024, !text.isEmpty else {
      return .notInserted(.unsupported)
    }
    if completedAttempt == attemptID, let completedOutcome { return completedOutcome }
    guard activeAttempt == nil else { return .uncertain(.unsupported) }
    activeAttempt = attemptID
    defer { activeAttempt = nil }
    guard !Task.isCancelled else { return .notInserted(.unsupported) }
    switch await adapter.validate(target) {
    case .rejected(let issue):
      return .notInserted(issue)
    case .eligible:
      break
    }
    guard !Task.isCancelled else { return .notInserted(.unsupported) }
    let outcome: InsertionOutcome
    do {
      switch try await adapter.setSelectedText(text, on: target) {
      case .noMutation:
        outcome = .notInserted(.unsupported)
      case .pasted:
        // A terminal paste cannot be read back; it reached the validated window.
        outcome = .confirmed
      case .mutationMayHaveOccurred:
        do {
          let selected = try await adapter.readback(text, on: target)
          outcome = selected == text ? .confirmed : .uncertain(.focusChanged)
        } catch {
          outcome = .uncertain(.unsupported)
        }
      }
    } catch {
      outcome = .uncertain(.unsupported)
    }
    completedAttempt = attemptID
    completedOutcome = outcome
    return outcome
  }
}
