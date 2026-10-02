import ActivityKit
import Foundation

@testable import LocalFlow

/// Records every request, update and end, and keeps at most the activities the app asked
/// for alive.
@MainActor
final class FakeActivityRequester: ActivityRequesting {
  enum Call: Equatable {
    case request(DictationActivityAttributes.Kind, DictationActivityAttributes.ContentState)
    case update(DictationActivityAttributes.ContentState)
    case end(DictationActivityAttributes.ContentState?, ActivityUIDismissalPolicy)
  }

  var areActivitiesEnabled = true
  var requestFails = false
  private(set) var calls: [Call] = []
  var live = 0
  /// Ended with a later dismissal: no longer active, still on screen.
  var lingering = 0
  var isActive: Bool { live > 0 }
  var isShowing: Bool { live + lingering > 0 }

  var requests: [Call] { calls.filter { if case .request = $0 { true } else { false } } }
  var updates: [DictationActivityAttributes.ContentState] {
    calls.compactMap { if case .update(let state) = $0 { state } else { nil } }
  }

  func request(
    _ attributes: DictationActivityAttributes, _ state: DictationActivityAttributes.ContentState
  ) throws {
    if requestFails { throw ActivityAuthorizationError.denied }
    calls.append(.request(attributes.kind, state))
    live += 1
  }

  func update(_ state: DictationActivityAttributes.ContentState) { calls.append(.update(state)) }

  func end(_ state: DictationActivityAttributes.ContentState?, dismissal: ActivityUIDismissalPolicy)
  {
    calls.append(.end(state, dismissal))
    lingering = dismissal == .immediate ? 0 : live + lingering
    live = 0
  }

  /// The system ended the activity (8-hour limit or a swipe).
  func systemEnded() { live = 0 }
}
