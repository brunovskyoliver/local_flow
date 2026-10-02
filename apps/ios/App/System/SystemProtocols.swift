import ActivityKit
import Foundation
import UIKit
import UserNotifications

/// The Live Activity as the app uses it: at most one, ended before a new request.
@MainActor
protocol ActivityRequesting: AnyObject {
  var areActivitiesEnabled: Bool { get }
  /// A LocalFlow activity exists and the system still shows it (the 8-hour limit or a
  /// swipe can end it behind the app's back).
  var isActive: Bool { get }
  func request(
    _ attributes: DictationActivityAttributes, _ state: DictationActivityAttributes.ContentState
  ) throws
  func update(_ state: DictationActivityAttributes.ContentState)
  /// Ends every LocalFlow activity.
  func end(_ state: DictationActivityAttributes.ContentState?, dismissal: ActivityUIDismissalPolicy)
}

@MainActor
protocol Pasteboard: AnyObject {
  /// False when iOS dropped the write (the app was in the background, research R4).
  func setString(_ string: String) -> Bool
}

@MainActor
protocol ResultNotifying: AnyObject {
  func authorizationStatus() async -> UNAuthorizationStatus
  func add(_ request: UNNotificationRequest) async throws
}

/// `Activity<DictationActivityAttributes>`. ActivityKit's update and end are async; they run
/// one after another in call order so a quick end and request cannot reorder.
@MainActor
final class SystemActivityRequester: ActivityRequesting {
  private typealias Live = Activity<DictationActivityAttributes>
  private var chain: Task<Void, Never>?

  var areActivitiesEnabled: Bool { ActivityAuthorizationInfo().areActivitiesEnabled }
  var isActive: Bool { Live.activities.contains { $0.activityState == .active } }

  func request(
    _ attributes: DictationActivityAttributes, _ state: DictationActivityAttributes.ContentState
  ) throws {
    _ = try Live.request(attributes: attributes, content: .init(state: state, staleDate: nil))
  }

  func update(_ state: DictationActivityAttributes.ContentState) {
    let ids = Set(Live.activities.map(\.id))
    enqueue { await Self.update(ids, state) }
  }

  func end(_ state: DictationActivityAttributes.ContentState?, dismissal: ActivityUIDismissalPolicy)
  {
    let ids = Set(Live.activities.map(\.id))
    enqueue { await Self.end(ids, state, dismissal) }
  }

  /// By ID, so an end queued before a request cannot end the newer activity.
  private nonisolated static func update(
    _ ids: Set<String>, _ state: DictationActivityAttributes.ContentState
  ) async {
    for activity in Live.activities where ids.contains(activity.id) {
      await activity.update(.init(state: state, staleDate: nil))
    }
  }

  private nonisolated static func end(
    _ ids: Set<String>, _ state: DictationActivityAttributes.ContentState?,
    _ dismissal: ActivityUIDismissalPolicy
  ) async {
    for activity in Live.activities where ids.contains(activity.id) {
      await activity.end(state.map { .init(state: $0, staleDate: nil) }, dismissalPolicy: dismissal)
    }
  }

  private func enqueue(_ work: @escaping @MainActor () async -> Void) {
    let previous = chain
    chain = Task {
      await previous?.value
      await work()
    }
  }
}

/// `UIPasteboard.general`. A dropped background write leaves `changeCount` unchanged.
@MainActor
final class SystemPasteboard: Pasteboard {
  func setString(_ string: String) -> Bool {
    let pasteboard = UIPasteboard.general
    let before = pasteboard.changeCount
    pasteboard.string = string
    return pasteboard.changeCount != before
  }
}
