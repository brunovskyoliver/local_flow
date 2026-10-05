import ActivityKit
import Foundation
import os

/// The meeting Live Activity as the app uses it: at most one.
@MainActor
protocol MeetingActivityRequesting: AnyObject {
  var areActivitiesEnabled: Bool { get }
  func request(
    _ attributes: MeetingActivityAttributes, _ state: MeetingActivityAttributes.ContentState)
    throws
  func update(_ state: MeetingActivityAttributes.ContentState)
  /// Ends every meeting activity, including one a previous process left behind.
  func end()
}

/// Requested in the foreground before recording starts; if it cannot be shown nothing is
/// recorded (ADR 0030, research R10). Updated on pause, resume and Stop; ended with the
/// meeting.
@MainActor
final class MeetingActivityController {
  enum Failure: Error { case disabled, requestFailed }

  private let requester: MeetingActivityRequesting
  private var sent: MeetingActivityAttributes.ContentState?
  private static let log = Logger(subsystem: "org.localflow.LocalFlowPhone", category: "activity")

  init(requester: MeetingActivityRequesting) {
    self.requester = requester
  }

  var isShowing: Bool { sent != nil }

  func begin(at start: Date) throws {
    guard requester.areActivitiesEnabled else { throw Failure.disabled }
    requester.end()
    let state = MeetingActivityAttributes.ContentState(phase: .recording, since: start)
    do {
      try requester.request(MeetingActivityAttributes(startedAt: start), state)
    } catch {
      Self.log.error("Meeting activity failed: \(String(describing: error), privacy: .public)")
      throw Failure.requestFailed
    }
    sent = state
  }

  func update(_ state: MeetingActivityAttributes.ContentState) {
    guard sent != nil, state != sent else { return }
    requester.update(state)
    sent = state
  }

  func end() {
    requester.end()
    sent = nil
  }
}

/// `Activity<MeetingActivityAttributes>`; update and end run in call order.
@MainActor
final class SystemMeetingActivityRequester: MeetingActivityRequesting {
  private typealias Live = Activity<MeetingActivityAttributes>
  private var chain: Task<Void, Never>?

  var areActivitiesEnabled: Bool { ActivityAuthorizationInfo().areActivitiesEnabled }

  func request(
    _ attributes: MeetingActivityAttributes, _ state: MeetingActivityAttributes.ContentState
  ) throws {
    _ = try Live.request(attributes: attributes, content: .init(state: state, staleDate: nil))
  }

  func update(_ state: MeetingActivityAttributes.ContentState) {
    let ids = Set(Live.activities.map(\.id))
    enqueue {
      for activity in Live.activities where ids.contains(activity.id) {
        await activity.update(.init(state: state, staleDate: nil))
      }
    }
  }

  func end() {
    let ids = Set(Live.activities.map(\.id))
    enqueue {
      for activity in Live.activities where ids.contains(activity.id) {
        await activity.end(nil, dismissalPolicy: .immediate)
      }
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
