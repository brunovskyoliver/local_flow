import Foundation

/// "End listening after", stored as `session.idleTimeout` (data-model.md, Settings).
enum IdleTimeout: String, CaseIterable, Identifiable, Sendable {
  case afterOne
  case fiveMinutes = "5m"
  case fifteenMinutes = "15m"
  case oneHour = "1h"
  case never

  static let key = "session.idleTimeout"
  static let `default` = IdleTimeout.fiveMinutes

  var id: String { rawValue }

  /// `afterOne` ends the session after its dictation; the deadline still bounds a
  /// session in which nothing is dictated. `never` has no deadline (research R6).
  var seconds: TimeInterval? {
    switch self {
    case .afterOne, .fiveMinutes: 5 * 60
    case .fifteenMinutes: 15 * 60
    case .oneHour: 60 * 60
    case .never: nil
    }
  }

  var title: String {
    switch self {
    case .afterOne: "After one dictation"
    case .fiveMinutes: "5 minutes"
    case .fifteenMinutes: "15 minutes"
    case .oneHour: "1 hour"
    case .never: "Never"
    }
  }

  static func current(_ defaults: UserDefaults = .standard) -> IdleTimeout {
    defaults.string(forKey: key).flatMap(IdleTimeout.init(rawValue:)) ?? .default
  }
}

/// One cancellable timer for the ready session's idle deadline. Nothing runs while no
/// session waits for one, so an idle app has no periodic wakeup. The fire is allowed 1 s
/// of tolerance, so a session ends at most about 1 s after its deadline (SC-009 allows
/// 10 s). `SessionController.tick` checks the deadline itself and reports it again when
/// a fire arrives early (for example after a wall-clock change).
@MainActor
final class IdleTimer {
  static let tolerance: TimeInterval = 1

  private var timer: Timer?
  private(set) var deadline: Date?

  var isArmed: Bool { timer != nil }

  /// Arms one fire at `deadline`, replacing any earlier one; nil disarms.
  func schedule(at deadline: Date?, _ fire: @escaping @MainActor () -> Void) {
    if deadline == self.deadline, deadline == nil || timer != nil { return }
    stop()
    guard let deadline else { return }
    self.deadline = deadline
    let timer = Timer(fire: deadline, interval: 0, repeats: false) { [weak self] _ in
      MainActor.assumeIsolated {
        self?.timer = nil
        self?.deadline = nil
        fire()
      }
    }
    timer.tolerance = Self.tolerance
    RunLoop.main.add(timer, forMode: .common)
    self.timer = timer
  }

  func stop() {
    timer?.invalidate()
    timer = nil
    deadline = nil
  }
}
