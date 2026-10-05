import Foundation

@testable import LocalFlow

/// Records every meeting activity request, update and end.
@MainActor
final class FakeMeetingActivityRequester: MeetingActivityRequesting {
  enum Call: Equatable {
    case request(MeetingActivityAttributes.ContentState.Phase)
    case update(MeetingActivityAttributes.ContentState.Phase)
    case end
  }

  var areActivitiesEnabled = true
  var requestFails = false
  private(set) var calls: [Call] = []
  private(set) var live = false

  func request(
    _ attributes: MeetingActivityAttributes, _ state: MeetingActivityAttributes.ContentState
  ) throws {
    if requestFails { throw MeetingActivityController.Failure.requestFailed }
    calls.append(.request(state.phase))
    live = true
  }

  func update(_ state: MeetingActivityAttributes.ContentState) {
    calls.append(.update(state.phase))
  }

  func end() {
    calls.append(.end)
    live = false
  }
}
