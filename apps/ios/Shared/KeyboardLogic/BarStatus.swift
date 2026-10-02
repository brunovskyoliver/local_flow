import Foundation

/// The keyboard's status strings (FR-014, FR-021). Pure, so the app's tests cover them.
enum BarStatus {
  static let elsewhere = "LocalFlow is recording elsewhere"
  /// The app stops a recording here (016 `duration_limit`); the warning starts 30 s before.
  static let recordingLimit: TimeInterval = 5 * 60
  static let warningFrom: TimeInterval = 4 * 60 + 30

  /// The bar between ☰ and the mic. Nil without a session. `idle_timeout` is compared by
  /// its wire value because `IdleTimeout` lives in the app.
  static func text(session: SessionFile?, hasPending: Bool, now: Date) -> String? {
    guard let session, session.state != .ended else { return nil }
    if session.dictationSource == .control, !hasPending { return elsewhere }
    switch session.idleTimeout {
    case "never": return "Listening · no timeout"
    case "afterOne": return "Listening · after this dictation"
    default:
      guard let deadline = session.idleDeadline else { return "Listening" }
      let left = Double(deadline - Handoff.milliseconds(now)) / 1000
      return "Listening · " + clock(left.rounded(.up))
    }
  }

  /// The listening view's status line, from `recording_started_at`.
  static func listening(startedAt: Date?, now: Date) -> String {
    guard let startedAt else { return "Listening" }
    let elapsed = now.timeIntervalSince(startedAt)
    guard elapsed >= warningFrom else { return "Listening · " + clock(elapsed.rounded(.down)) }
    return "Stops at 5:00 · " + clock((recordingLimit - elapsed).rounded(.up)) + " left"
  }

  /// m:ss, never negative.
  static func clock(_ seconds: TimeInterval) -> String {
    let seconds = max(0, Int(seconds))
    return String(format: "%d:%02d", seconds / 60, seconds % 60)
  }
}
