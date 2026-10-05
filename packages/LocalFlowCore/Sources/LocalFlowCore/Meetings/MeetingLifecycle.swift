import Foundation

/// Pure transition table from `data-model.md`. Every pair not listed is rejected
/// and mutates nothing; the store applies the check inside its write transaction.
public enum MeetingLifecycle {
  public enum Error: Swift.Error, Equatable, Sendable {
    case invalidTransition(from: MeetingState, to: MeetingState)
  }

  private static let table: [MeetingState: Set<MeetingState>] = [
    .created: [.preparing, .failed],
    .preparing: [.recording, .failed, .interrupted],
    .recording: [.paused, .finalizing, .interrupted, .failed],
    .paused: [.recording, .finalizing, .interrupted, .failed],
    .finalizing: [.completed, .interrupted, .failed],
    .completed: [],
    .interrupted: [],
    .failed: [],
  ]

  public static func isAllowed(from: MeetingState, to: MeetingState) -> Bool {
    table[from]?.contains(to) ?? false
  }

  @discardableResult
  public static func transition(from: MeetingState, to: MeetingState) throws -> MeetingState {
    guard isAllowed(from: from, to: to) else { throw Error.invalidTransition(from: from, to: to) }
    return to
  }
}
