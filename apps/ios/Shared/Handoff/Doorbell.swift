import Foundation

/// The six Darwin notification names of the handoff contract. They carry only a name;
/// the data is in the files, which the sender writes before ringing.
enum Bell: String, CaseIterable, Sendable {
  case request, delivery, ping, pong, session, result

  var name: String { "app.localflow.handoff.\(rawValue)" }
}

/// Posts and observes the bells through the Darwin notify center, one process-wide
/// observer per name. Handlers run on the main actor.
@MainActor
final class Doorbell {
  static let shared = Doorbell()

  private var handlers: [Bell: @MainActor () -> Void] = [:]
  private let center = CFNotificationCenterGetDarwinNotifyCenter()

  nonisolated static func ring(_ bell: Bell) {
    CFNotificationCenterPostNotification(
      CFNotificationCenterGetDarwinNotifyCenter(), CFNotificationName(bell.name as CFString), nil,
      nil, true)
  }

  func observe(_ bell: Bell, _ handler: @escaping @MainActor () -> Void) {
    let first = handlers[bell] == nil
    handlers[bell] = handler
    guard first else { return }
    CFNotificationCenterAddObserver(
      center, Unmanaged.passUnretained(self).toOpaque(),
      { _, _, name, _, _ in
        guard let raw = name?.rawValue as String?,
          let bell = Bell.allCases.first(where: { $0.name == raw })
        else { return }
        DispatchQueue.main.async { MainActor.assumeIsolated { Doorbell.shared.fire(bell) } }
      }, bell.name as CFString, nil, .deliverImmediately)
  }

  func stopObserving(_ bell: Bell) {
    handlers[bell] = nil
    CFNotificationCenterRemoveObserver(
      center, Unmanaged.passUnretained(self).toOpaque(), CFNotificationName(bell.name as CFString),
      nil)
  }

  func fire(_ bell: Bell) { handlers[bell]?() }
}
