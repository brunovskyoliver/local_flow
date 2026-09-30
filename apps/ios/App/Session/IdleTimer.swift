import Foundation

/// "End listening after", stored as `session.idleTimeout` (data-model.md, Settings).
enum IdleTimeout: String, CaseIterable, Identifiable, Sendable {
  case afterOne
  case fiveMinutes = "5m"
  case fifteenMinutes = "15m"
  case oneHour = "1h"

  static let key = "session.idleTimeout"
  static let `default` = IdleTimeout.fiveMinutes

  var id: String { rawValue }

  /// `afterOne` ends the session after its dictation; the deadline still bounds a
  /// session in which nothing is dictated.
  var seconds: TimeInterval {
    switch self {
    case .afterOne, .fiveMinutes: 5 * 60
    case .fifteenMinutes: 15 * 60
    case .oneHour: 60 * 60
    }
  }

  var title: String {
    switch self {
    case .afterOne: "After one dictation"
    case .fiveMinutes: "5 minutes"
    case .fifteenMinutes: "15 minutes"
    case .oneHour: "1 hour"
    }
  }

  static func current(_ defaults: UserDefaults = .standard) -> IdleTimeout {
    defaults.string(forKey: key).flatMap(IdleTimeout.init(rawValue:)) ?? .default
  }
}

/// A 1 s tick, so a session ends at most 1 s after its deadline (SC-009 allows 10 s).
@MainActor
final class IdleTimer {
  private var timer: Timer?

  func start(_ tick: @escaping @MainActor () -> Void) {
    timer?.invalidate()
    timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
      MainActor.assumeIsolated { tick() }
    }
  }

  func stop() {
    timer?.invalidate()
    timer = nil
  }
}
